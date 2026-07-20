package balancer

import (
	"sort"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
)

// SmartActive keeps one outbound for the whole balancer.  Probes still run for
// every member, but a probe result is only evidence; it never sends production
// traffic through a background candidate.
type SmartActive struct {
	outbounds []adapter.Outbound

	mu        sync.Mutex
	active    adapter.Outbound
	bootstrap bool
	// selectionGeneration is the full cohort currently being ranked. A newer
	// one-server ping must not replace this with a partial generation.
	selectionGeneration uint64
	// lastFullHistory is the last coherently completed full generation. The
	// monitoring state is reset in-place when a new cycle starts, so keeping the
	// snapshot here lets an active-only probe compare its live result with the
	// last verified candidates without treating a partial generation as ready.
	lastFullGeneration uint64
	lastFullHistory    map[string]*adapter.URLTestHistory
	confirmed          bool
	startedAt          time.Time
	evidence           map[string]*smartEvidence
	avoidUntil         map[string]time.Time
	decision           smartDecision
	recovered          []string
	activeProbe        smartActiveProbeEvidence
}

type smartEvidence struct {
	successStreak       int
	failureStreak       int
	lastScore           int
	recoveryPending     bool
	lastProbeGeneration uint64
	lastProbeTime       time.Time
	hasCompletedProbe   bool
}

type smartDecision struct {
	action string
	reason string
	from   string
	to     string
	state  string
	mode   string
}

const (
	smartActiveMinimalDelayDelta     = 10
	smartActiveSignificantDelayDelta = 50
	smartActiveScoreSwitchMargin     = 8
	smartActiveComparableScoreDelta  = 5
	smartActiveCleanEvidenceRequired = 2
	smartActiveAvoidAfterSwitch      = 2 * time.Minute
)

var _ Strategy = (*SmartActive)(nil)

func NewSmartActive(outbounds []adapter.Outbound, _ option.BalancerOutboundOptions) *SmartActive {
	return &SmartActive{
		outbounds:       outbounds,
		bootstrap:       true,
		startedAt:       time.Now(),
		evidence:        make(map[string]*smartEvidence),
		avoidUntil:      make(map[string]time.Time),
		lastFullHistory: make(map[string]*adapter.URLTestHistory),
		decision: smartDecision{
			action: "wait",
			reason: "startup_waiting_for_verified_batch",
			state:  "SUSPECT",
			mode:   "vpn_start",
		},
	}
}

func (s *SmartActive) Now() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active == nil {
		return ""
	}
	return s.active.Tag()
}

func (s *SmartActive) Select(_ adapter.InboundContext, _ string, _ bool) adapter.Outbound {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

func (s *SmartActive) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	return s.updateOutboundsInfo(history, "", 0)
}

func (s *SmartActive) UpdateOutboundsInfoForManualRefresh(history map[string]*adapter.URLTestHistory) bool {
	return s.updateOutboundsInfo(history, "user_refresh", 0)
}

func (s *SmartActive) UpdateOutboundsInfoForCompletedBatch(history map[string]*adapter.URLTestHistory, generation uint64) bool {
	return s.updateOutboundsInfo(history, "completed_batch", generation)
}

func (s *SmartActive) updateOutboundsInfo(history map[string]*adapter.URLTestHistory, mode string, batchGeneration uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	observedGeneration := s.currentGeneration(history)
	if observedGeneration > s.selectionGeneration && s.generationCoversAll(history, observedGeneration) {
		s.selectionGeneration = observedGeneration
	}
	generation := s.selectionGeneration
	fullGenerationChanged := false
	if generation != 0 && s.generationSettled(history, generation) {
		fullGenerationChanged = s.rememberFullGeneration(history, generation)
	}
	s.updateEvidence(history)
	current := s.active
	decisionHistory := history
	if !s.bootstrap && generation != 0 && generation == s.lastFullGeneration {
		decisionHistory = s.fullGenerationDecisionHistory(candidateTag(current), history)
	}
	if fullGenerationChanged {
		s.reconcileActiveProbeAdvantage(decisionHistory, generation)
	}

	if s.bootstrap {
		// beginCheckGeneration assigns the generation to every member before the
		// workers start. That lets startup distinguish a full cohort (where we may
		// select from completed batches) from a one-server/partial ping
		// (which must never re-rank the group against older results).
		if generation == 0 {
			reason := "startup_waiting_for_full_generation"
			if observedGeneration != 0 {
				reason = "partial_generation_ignored_during_startup"
			}
			s.decision = smartDecision{action: pendingAction(current), reason: reason, from: candidateTag(current), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		if mode == "completed_batch" && batchGeneration != generation {
			s.decision = smartDecision{action: pendingAction(current), reason: "partial_batch_generation_ignored", from: candidateTag(current), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		if mode != "completed_batch" && mode != "user_refresh" && !s.bootstrapGenerationSettled(history, generation) {
			s.decision = smartDecision{action: pendingAction(current), reason: "startup_waiting_for_completed_batch", from: candidateTag(current), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
			return false
		}

		candidate := s.bestBootstrapCandidate(history, generation)
		if candidate != nil {
			reason := "first_confirmed_current_generation_candidate"
			if s.confirmed {
				reason = "startup_progressively_better_candidate"
			}
			changed := false
			if !s.confirmed || current == nil || candidate.Tag() != current.Tag() {
				// Startup switches intentionally do not populate avoidUntil. Every new
				// result belongs to the same fresh cohort, so the best-so-far route is
				// allowed to improve more than once before the cycle settles.
				changed = s.confirmActive(current, candidate, reason, decisionMode(mode, s.bootstrap))
			} else {
				s.decision = smartDecision{action: "keep", reason: "startup_current_is_best_so_far", from: current.Tag(), to: candidate.Tag(), state: smartActiveState(history[current.Tag()]), mode: decisionMode(mode, s.bootstrap)}
			}
			if s.bootstrapGenerationSettled(history, generation) {
				s.bootstrap = false
			}
			return changed
		}
		tag, reason := s.bestRejectedCandidate(history, generation)
		if reason == "" {
			if generation == 0 {
				reason = "startup_waiting_for_first_generation"
			} else {
				reason = "startup_waiting_for_current_generation_ready"
			}
		} else {
			reason = "candidate_rejected_" + reason
		}
		s.decision = smartDecision{action: pendingAction(current), reason: reason, from: candidateTag(current), to: tag, state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if current == nil {
		s.decision = smartDecision{action: "wait", reason: "waiting_for_verified_candidate", state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		return false
	}

	if !s.confirmed {
		candidate := s.bestCandidate(history, true, false, generation)
		if candidate != nil {
			return s.confirmActive(current, candidate, "first_confirmed_current_generation_candidate", decisionMode(mode, s.bootstrap))
		}
		s.decision = smartDecision{action: "keep", reason: "waiting_for_confirmed_candidate", from: current.Tag(), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		return false
	}

	currentHistory := history[current.Tag()]
	state := smartActiveState(currentHistory)
	if mode == "completed_batch" && batchGeneration != generation {
		s.decision = smartDecision{action: "keep", reason: "partial_batch_generation_ignored", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if mode != "user_refresh" && mode != "completed_batch" && !s.generationSettled(history, generation) {
		if generation != s.lastFullGeneration || len(s.lastFullHistory) == 0 {
			s.decision = smartDecision{action: "keep", reason: "current_generation_incomplete", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
			return false
		}
	}
	history = decisionHistory
	currentHistory = history[current.Tag()]
	state = smartActiveState(currentHistory)
	if changed, handled := s.handleConfirmedActiveProbe(current, history, generation); handled {
		return changed
	}
	if mode == "user_refresh" {
		candidate := s.bestCandidate(history, true, false, generation)
		if candidate != nil {
			return s.applyUserRefreshDecision(current, candidate, history, generation)
		}
		tag, reason := s.bestRejectedCandidate(history, generation)
		if reason == "" {
			reason = "user_refresh_without_confirmed_candidate"
		} else {
			reason = "user_refresh_candidate_rejected_" + reason
		}
		s.decision = smartDecision{action: "keep", reason: reason, from: current.Tag(), to: tag, state: state, mode: "user_refresh"}
		return false
	}
	if mode == "completed_batch" {
		requiredSuccesses := smartActiveCleanEvidenceRequired
		if state == "BAD" || state == "CRITICAL" {
			requiredSuccesses = 1
		}
		var candidate adapter.Outbound
		comparisonTag := ""
		reason := "completed_batch_without_confirmed_candidate"
		if state == "BAD" || state == "CRITICAL" {
			candidate = s.bestCandidate(history, true, true, generation)
		} else {
			candidate, comparisonTag, reason, _ = s.bestSignificantCandidate(
				current.Tag(), history, generation, state, requiredSuccesses, state != "GOOD", smartActiveCandidateMaxAge,
			)
		}
		if candidate == nil {
			s.decision = smartDecision{action: "keep", reason: reason, from: current.Tag(), to: comparisonTag, state: state, mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		changed := s.switchTo(current, candidate, "completed_batch_better_candidate", state, history, generation)
		s.decision.mode = decisionMode(mode, s.bootstrap)
		return changed
	}

	emergencyCandidate := s.bestCandidate(history, state == "BAD" || state == "CRITICAL", true, generation)
	if currentCheckInProgress(currentHistory) && !runtimeCriticalActiveIssue(currentHistory) {
		s.decision = smartDecision{action: "keep", reason: "current_temporarily_kept_during_refresh", from: current.Tag(), to: candidateTag(emergencyCandidate), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}

	if state == "CRITICAL" {
		if emergencyCandidate != nil && emergencyCandidate.Tag() != current.Tag() {
			reason := "critical_active_failure"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_critical"
			}
			if s.switchTo(current, emergencyCandidate, reason, state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "fallback", reason: "critical_without_healthy_candidate", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if state == "BAD" {
		if emergencyCandidate != nil && emergencyCandidate.Tag() != current.Tag() {
			reason := "bad_active_confirmed_candidate"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_bad"
			}
			if s.switchTo(current, emergencyCandidate, reason, state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "keep", reason: "bad_without_confirmed_candidate", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	candidate, comparisonTag, assessmentReason, _ := s.bestSignificantCandidate(
		current.Tag(), history, generation, state, smartActiveCleanEvidenceRequired, state != "GOOD", smartActiveCandidateMaxAge,
	)
	if state == "DEGRADED" {
		if candidate != nil {
			reason := "degraded_active_better_candidate"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_degraded"
			}
			if s.switchTo(current, candidate, reason, state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "keep", reason: "degraded_collecting_evidence", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if state == "SUSPECT" {
		if candidate != nil {
			if s.switchTo(current, candidate, "suspect_stably_better_candidate", state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "keep", reason: "suspect_collecting_evidence", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if candidate != nil {
		if s.switchTo(current, candidate, assessmentReason, state, history, generation) {
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		s.decision.mode = decisionMode(mode, s.bootstrap)
		return false
	}
	if comparisonTag != "" {
		s.decision = smartDecision{action: "keep", reason: assessmentReason, from: current.Tag(), to: comparisonTag, state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	// A healthy active is sticky by design, but only inside a narrow hysteresis
	// window where the candidate has no meaningful numeric advantage.
	s.decision = smartDecision{action: "keep", reason: "active_good_no_better_candidate", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
	return false
}

func (s *SmartActive) LastDecision() smartDecision {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.decision
}

func (s *SmartActive) LastRecoveries() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.recovered...)
}

func (s *SmartActive) confirmActive(from, to adapter.Outbound, reason, mode string) bool {
	fromTag := ""
	if from != nil {
		fromTag = from.Tag()
	}
	toTag := ""
	if to != nil {
		toTag = to.Tag()
	}
	if to == nil {
		s.decision = smartDecision{action: "keep", reason: "blocked_confirm_nil_target", from: fromTag, state: "SUSPECT", mode: mode}
		return false
	}
	s.active = to
	s.confirmed = true
	action := "confirm"
	if fromTag != "" && fromTag != toTag {
		action = "switch"
	}
	s.decision = smartDecision{action: action, reason: reason, from: fromTag, to: toTag, state: "GOOD", mode: mode}
	return fromTag != toTag
}

func (s *SmartActive) switchTo(from, to adapter.Outbound, reason, state string, history map[string]*adapter.URLTestHistory, generation uint64) bool {
	fromTag := ""
	toTag := ""
	if from != nil {
		fromTag = from.Tag()
	}
	if to != nil {
		toTag = to.Tag()
	}
	if status := s.candidateStatus(toTag, history[toTag], generation); !status.ok {
		s.decision = smartDecision{action: "keep", reason: "blocked_invalid_switch_" + status.reason, from: fromTag, to: toTag, state: state}
		return false
	}
	if fromTag != "" && toTag != "" && fromTag != toTag {
		s.avoidUntil[fromTag] = time.Now().Add(smartActiveAvoidAfterSwitch)
		if evidence := s.evidence[fromTag]; evidence != nil {
			// Pre-switch successes must not count as recovery evidence. Once the
			// cooldown expires, the old route needs a genuinely newer clean probe
			// before it can participate again.
			evidence.successStreak = 0
		}
	}
	s.active = to
	s.confirmed = true
	s.decision = smartDecision{action: "switch", reason: reason, from: fromTag, to: toTag, state: state}
	return true
}

func (s *SmartActive) updateEvidence(history map[string]*adapter.URLTestHistory) {
	s.recovered = s.recovered[:0]
	now := time.Now()
	for tag, until := range s.avoidUntil {
		if now.After(until) {
			delete(s.avoidUntil, tag)
		}
	}
	for _, outbound := range s.outbounds {
		tag := outbound.Tag()
		h := history[tag]
		e := s.evidence[tag]
		if e == nil {
			e = &smartEvidence{}
			s.evidence[tag] = e
		}
		if h != nil {
			e.lastScore = getHealthScore(tag, h)
		}
		if !s.isNewCompletedProbe(h, e) {
			continue
		}
		newGeneration := !e.hasCompletedProbe || h.CheckGeneration > e.lastProbeGeneration
		e.lastProbeGeneration = h.CheckGeneration
		e.lastProbeTime = h.Time
		e.hasCompletedProbe = true

		state := smartActiveState(h)
		cleanSuccess := s.cleanCompletedProbe(tag, h)
		if state == "BAD" || state == "CRITICAL" {
			e.recoveryPending = true
			if newGeneration {
				e.failureStreak++
			} else {
				e.failureStreak = max(e.failureStreak, 1)
			}
			e.successStreak = 0
		} else if cleanSuccess {
			if e.recoveryPending && state != "GOOD" {
				// Recovery quarantine is released only by consecutive fully GOOD
				// generations. A merely successful but still penalized probe keeps
				// the route out of proactive selection.
				e.successStreak = 0
				e.failureStreak = 0
				continue
			}
			if !newGeneration {
				continue
			}
			e.successStreak++
			e.failureStreak = 0
			if e.recoveryPending && e.successStreak >= 2 {
				e.recoveryPending = false
				s.recovered = append(s.recovered, tag)
			}
		} else if h != nil {
			if newGeneration {
				e.failureStreak++
			} else {
				e.failureStreak = max(e.failureStreak, 1)
			}
			e.successStreak = 0
		}
	}
}

func (s *SmartActive) isNewCompletedProbe(h *adapter.URLTestHistory, evidence *smartEvidence) bool {
	if h == nil || h.CheckGeneration == 0 || h.Time.IsZero() || h.Time.Before(s.startedAt) || h.IsFromCache || !h.CombinedReady {
		return false
	}
	if h.URLTestStatus != "" && h.URLTestStatus != urltest.StatusSuccess && h.URLTestStatus != urltest.StatusFailed {
		return false
	}
	if h.URLTestStatus == "" && !h.Success && (h.ErrorType == "" || h.ErrorType == urltest.ErrorTypeNone) {
		return false
	}
	if !evidence.hasCompletedProbe {
		return true
	}
	if h.CheckGeneration < evidence.lastProbeGeneration {
		return false
	}
	if h.CheckGeneration == evidence.lastProbeGeneration && !h.Time.After(evidence.lastProbeTime) {
		return false
	}
	return true
}

func (s *SmartActive) cleanCompletedProbe(tag string, h *adapter.URLTestHistory) bool {
	if h == nil || !h.Success || (h.ErrorType != "" && h.ErrorType != urltest.ErrorTypeNone) {
		return false
	}
	if h.URLTestStatus != "" && h.URLTestStatus != urltest.StatusSuccess {
		return false
	}
	if getPolicyPenalty(tag, h) >= 50 || getHealthScore(tag, h) < 35 {
		return false
	}
	state := smartActiveState(h)
	return state != "BAD" && state != "CRITICAL"
}

func (s *SmartActive) bestCandidate(history map[string]*adapter.URLTestHistory, emergency bool, requireEvidence bool, generation uint64) adapter.Outbound {
	candidates := append([]adapter.Outbound(nil), s.outbounds...)
	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := history[candidates[i].Tag()], history[candidates[j].Tag()]
		leftScore, rightScore := getHealthScore(candidates[i].Tag(), left), getHealthScore(candidates[j].Tag(), right)
		if leftScore != rightScore {
			return leftScore > rightScore
		}
		leftDelay, rightDelay := getModifiedDelay(left), getModifiedDelay(right)
		if leftDelay != rightDelay {
			return leftDelay < rightDelay
		}
		return candidates[i].Tag() < candidates[j].Tag()
	})
	var avoidedFallback adapter.Outbound
	for _, candidate := range candidates {
		tag := candidate.Tag()
		h := history[tag]
		e := s.evidence[tag]
		if !s.candidateStatus(tag, h, generation).ok {
			continue
		}
		if time.Since(h.Time) > smartActiveCandidateMaxAge {
			continue
		}
		// A previously bad server must prove recovery with multiple clean probes.
		requiredSuccesses := 2
		if emergency {
			requiredSuccesses = 1
		}
		if requireEvidence && (e == nil || e.successStreak < requiredSuccesses || e.failureStreak > 0) {
			continue
		}
		if s.isAvoidedCandidate(tag, h, e) {
			if emergency && avoidedFallback == nil {
				avoidedFallback = candidate
			}
			continue
		}
		return candidate
	}
	// Avoidance prevents routine ping-pong, but it must not strand a failed
	// active when the recently used server is the only verified recovery path.
	return avoidedFallback
}

// bestSignificantCandidate walks the whole ranking instead of letting an
// unsuitable score leader hide a lower-ranked candidate that has a material,
// policy-aware advantage over the live active.
func (s *SmartActive) bestSignificantCandidate(
	currentTag string,
	history map[string]*adapter.URLTestHistory,
	generation uint64,
	currentState string,
	minimumSuccesses int,
	requireGood bool,
	maxAge time.Duration,
) (adapter.Outbound, string, string, bool) {
	if generation == 0 {
		return nil, "", "missing_full_generation", false
	}
	candidates := append([]adapter.Outbound(nil), s.outbounds...)
	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := candidates[i], candidates[j]
		leftScore := getHealthScore(left.Tag(), history[left.Tag()])
		rightScore := getHealthScore(right.Tag(), history[right.Tag()])
		if leftScore != rightScore {
			return leftScore > rightScore
		}
		leftDelay := getModifiedDelay(history[left.Tag()])
		rightDelay := getModifiedDelay(history[right.Tag()])
		if leftDelay != rightDelay {
			return leftDelay < rightDelay
		}
		return left.Tag() < right.Tag()
	})

	comparisonTag := ""
	rejectionReason := "candidate_advantage_insufficient"
	staleCandidate := false
	for _, candidate := range candidates {
		candidateTag := candidate.Tag()
		if candidateTag == currentTag {
			continue
		}
		candidateHistory := history[candidateTag]
		if !s.candidateStatus(candidateTag, candidateHistory, generation).ok {
			continue
		}
		if maxAge > 0 && time.Since(candidateHistory.Time) > maxAge {
			staleCandidate = true
			continue
		}
		if comparisonTag == "" {
			comparisonTag = candidateTag
		}
		if requireGood && smartActiveState(candidateHistory) != "GOOD" {
			rejectionReason = "candidate_not_stably_good"
			continue
		}
		evidence := s.evidence[candidateTag]
		requiredSuccesses := minimumSuccesses
		if evidence != nil && evidence.recoveryPending {
			requiredSuccesses = max(requiredSuccesses, smartActiveCleanEvidenceRequired)
		}
		if evidence == nil || evidence.successStreak < requiredSuccesses || evidence.failureStreak > 0 {
			rejectionReason = "candidate_waiting_for_clean_evidence"
			continue
		}
		if s.isAvoidedCandidate(candidateTag, candidateHistory, evidence) {
			rejectionReason = "candidate_recently_avoided_waiting_recovery"
			continue
		}
		better, reason := significantSmartActiveAdvantage(currentTag, candidateTag, history, currentState)
		if better {
			return candidate, comparisonTag, reason, false
		}
		rejectionReason = reason
	}
	return nil, comparisonTag, rejectionReason, staleCandidate
}

func (s *SmartActive) bestBootstrapCandidate(history map[string]*adapter.URLTestHistory, generation uint64) adapter.Outbound {
	return s.bestProgressiveBatchCandidate(history, generation, 0)
}

func (s *SmartActive) bestProgressiveBatchCandidate(history map[string]*adapter.URLTestHistory, generation uint64, requiredSuccesses int) adapter.Outbound {
	eligible := make([]adapter.Outbound, 0, len(s.outbounds))
	bestScore := 0
	for _, candidate := range s.outbounds {
		tag := candidate.Tag()
		if !s.candidateStatus(tag, history[tag], generation).ok {
			continue
		}
		if requiredSuccesses > 0 {
			evidence := s.evidence[tag]
			if evidence == nil || evidence.successStreak < requiredSuccesses || evidence.failureStreak > 0 {
				continue
			}
		}
		eligible = append(eligible, candidate)
		bestScore = max(bestScore, getHealthScore(tag, history[tag]))
	}
	if len(eligible) == 0 {
		return nil
	}

	// A small quality-score difference must not pin the route to a dramatically
	// slower early-batch winner. Start with the highest-quality candidate, then
	// allow a comparable-quality candidate to win only for a significant delay
	// improvement. Policy and genuine health penalties are part of the score.
	// Exact ties keep a confirmed active; before the first selection, the tag is
	// the deterministic tie-breaker so profile list order has no effect.
	sort.SliceStable(eligible, func(i, j int) bool {
		left, right := eligible[i], eligible[j]
		leftScore := getHealthScore(left.Tag(), history[left.Tag()])
		rightScore := getHealthScore(right.Tag(), history[right.Tag()])
		if leftScore != rightScore {
			return leftScore > rightScore
		}
		leftDelay := getModifiedDelay(history[left.Tag()])
		rightDelay := getModifiedDelay(history[right.Tag()])
		if leftDelay != rightDelay {
			return leftDelay < rightDelay
		}
		activeTag := candidateTag(s.active)
		if left.Tag() == activeTag || right.Tag() == activeTag {
			return left.Tag() == activeTag
		}
		return left.Tag() < right.Tag()
	})
	qualityWinner := eligible[0]
	qualityWinnerDelay := getModifiedDelay(history[qualityWinner.Tag()])
	selected := qualityWinner
	selectedDelay := qualityWinnerDelay
	for _, candidate := range eligible[1:] {
		score := getHealthScore(candidate.Tag(), history[candidate.Tag()])
		if score < bestScore-smartActiveComparableScoreDelta {
			continue
		}
		delay := getModifiedDelay(history[candidate.Tag()])
		if score < bestScore && int(qualityWinnerDelay)-int(delay) < smartActiveSignificantDelayDelta {
			continue
		}
		if delay < selectedDelay {
			selected = candidate
			selectedDelay = delay
		}
	}
	return selected
}

func (s *SmartActive) bestRejectedCandidate(history map[string]*adapter.URLTestHistory, generation uint64) (string, string) {
	candidates := append([]adapter.Outbound(nil), s.outbounds...)
	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := history[candidates[i].Tag()], history[candidates[j].Tag()]
		leftScore, rightScore := getHealthScore(candidates[i].Tag(), left), getHealthScore(candidates[j].Tag(), right)
		if leftScore != rightScore {
			return leftScore > rightScore
		}
		return getModifiedDelay(left) < getModifiedDelay(right)
	})
	for _, candidate := range candidates {
		tag := candidate.Tag()
		status := s.candidateStatus(tag, history[tag], generation)
		if !status.ok {
			return tag, status.reason
		}
	}
	return "", ""
}

func (s *SmartActive) applyUserRefreshDecision(current, candidate adapter.Outbound, history map[string]*adapter.URLTestHistory, generation uint64) bool {
	s.bootstrap = false
	currentTag := current.Tag()
	candidateTag := candidate.Tag()
	currentHistory := history[currentTag]
	candidateHistory := history[candidateTag]
	currentState := smartActiveState(currentHistory)

	if currentTag == candidateTag {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_current_is_rank1", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}
	if status := s.candidateStatus(candidateTag, candidateHistory, generation); !status.ok {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_rejected_" + status.reason, from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}
	if currentHistory == nil || !currentHistory.Success || currentHistory.IsFromCache || currentState == "BAD" || currentState == "CRITICAL" {
		if s.switchTo(current, candidate, "user_refresh_best_fresh_candidate", currentState, history, generation) {
			s.decision.mode = "user_refresh"
			return true
		}
		s.decision.mode = "user_refresh"
		return false
	}
	if userRefreshCandidatePenalized(candidateHistory) {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_penalized", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}
	if userRefreshMinimalTie(currentTag, candidateTag, history) {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_tie_minimal_delta", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}

	if s.switchTo(current, candidate, "user_refresh_best_fresh_candidate", currentState, history, generation) {
		s.decision.mode = "user_refresh"
		return true
	}
	s.decision.mode = "user_refresh"
	return false
}

func firstPolicyPreferredOutbound(outbounds []adapter.Outbound) adapter.Outbound {
	if len(outbounds) == 0 {
		return nil
	}
	for _, outbound := range outbounds {
		if getPolicyPenalty(outbound.Tag(), nil) == 0 {
			return outbound
		}
	}
	return outbounds[0]
}

func preferFallbackOutbound(candidate, current adapter.Outbound, history map[string]*adapter.URLTestHistory) bool {
	candidateTag := candidate.Tag()
	currentTag := current.Tag()
	candidateHistory := history[candidateTag]
	currentHistory := history[currentTag]

	candidateSuccess := candidateHistory != nil && candidateHistory.Success
	currentSuccess := currentHistory != nil && currentHistory.Success
	if candidateSuccess != currentSuccess {
		return candidateSuccess
	}
	if candidateSuccess && currentSuccess {
		candidateScore := getHealthScore(candidateTag, candidateHistory)
		currentScore := getHealthScore(currentTag, currentHistory)
		if candidateScore != currentScore {
			return candidateScore > currentScore
		}
	}

	candidatePenalty := getPolicyPenalty(candidateTag, candidateHistory)
	currentPenalty := getPolicyPenalty(currentTag, currentHistory)
	if candidatePenalty != currentPenalty {
		return candidatePenalty < currentPenalty
	}

	return getModifiedDelay(candidateHistory) < getModifiedDelay(currentHistory)
}

func significantSmartActiveAdvantage(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, currentState string) (bool, string) {
	current, candidate := history[currentTag], history[candidateTag]
	if current == nil || !current.Success {
		return true, "current_unhealthy_candidate_fresh"
	}
	if candidate == nil {
		return false, "candidate_missing"
	}
	currentScore := getHealthScore(currentTag, current)
	candidateScore := getHealthScore(candidateTag, candidate)
	currentDelay := getModifiedDelay(current)
	candidateDelay := getModifiedDelay(candidate)
	delayDelta := int(currentDelay) - int(candidateDelay)
	scoreDelta := candidateScore - currentScore
	penaltyAdvantage := smartActiveEvidencePenalty(current) - smartActiveEvidencePenalty(candidate)
	currentPolicyPenalty := getPolicyPenalty(currentTag, current)
	candidatePolicyPenalty := getPolicyPenalty(candidateTag, candidate)
	if candidatePolicyPenalty > currentPolicyPenalty {
		return false, "candidate_policy_worse_than_current"
	}
	if currentPolicyPenalty-candidatePolicyPenalty >= urltest.RussianServerPolicyPenalty && scoreDelta >= 4 {
		return true, "policy_preferred_foreign_candidate"
	}
	if currentRealUserAdvantage(current, candidate, scoreDelta, delayDelta) {
		return false, "current_real_traffic_stable_and_candidate_advantage_insufficient"
	}

	if currentState == "DEGRADED" {
		if scoreDelta >= 4 || candidateScore >= currentScore-smartActiveComparableScoreDelta && delayDelta >= smartActiveSignificantDelayDelta ||
			candidateScore >= currentScore-smartActiveComparableScoreDelta && int(candidateDelay) <= int(currentDelay)+smartActiveMinimalDelayDelta {
			return true, "degraded_active_stable_good_candidate"
		}
		return false, "degraded_candidate_advantage_insufficient"
	}
	if currentState == "SUSPECT" {
		if scoreDelta >= smartActiveScoreSwitchMargin || candidateScore >= currentScore-smartActiveComparableScoreDelta && delayDelta >= smartActiveSignificantDelayDelta ||
			candidateScore >= currentScore && int(candidateDelay) <= int(currentDelay)+smartActiveMinimalDelayDelta {
			return true, "suspect_active_stable_good_candidate"
		}
		return false, "suspect_candidate_advantage_insufficient"
	}
	if candidateScore >= currentScore-smartActiveComparableScoreDelta && delayDelta >= smartActiveSignificantDelayDelta {
		return true, "same_quality_significantly_lower_delay"
	}
	if scoreDelta >= smartActiveScoreSwitchMargin &&
		(delayDelta > smartActiveMinimalDelayDelta || penaltyAdvantage >= smartActiveScoreSwitchMargin) &&
		int(candidateDelay) <= int(currentDelay)+smartActiveSignificantDelayDelta {
		return true, "candidate_score_better_with_clean_evidence"
	}
	if delayDelta <= smartActiveMinimalDelayDelta {
		return false, "delay_delta_minimal_current_stable"
	}
	return false, "candidate_advantage_insufficient"
}

func smartActiveEvidencePenalty(history *adapter.URLTestHistory) int {
	if history == nil {
		return 0
	}
	return history.RuntimePenalty + history.RealUserPenalty + history.VolatilityPenalty +
		history.UDPPenalty + history.PolicyPenalty + history.DegradationPoints/2
}

func currentRealUserAdvantage(current, candidate *adapter.URLTestHistory, scoreDelta, delayDelta int) bool {
	if current == nil || candidate == nil {
		return false
	}
	currentPenalty := current.RuntimePenalty + current.RealUserPenalty + current.DegradationPoints + current.UDPPenalty
	candidatePenalty := candidate.RuntimePenalty + candidate.RealUserPenalty + candidate.DegradationPoints + candidate.UDPPenalty
	// Small penalties are already priced into HealthScore and must not veto a
	// large delay/quality win. Reserve this hard guard for materially worse
	// real-traffic evidence.
	if candidatePenalty >= currentPenalty+16 {
		return true
	}
	// Relative stability is a tie-breaker inside the hysteresis window, not an
	// absolute veto against an otherwise clearly healthier/faster candidate.
	return scoreDelta < smartActiveScoreSwitchMargin && delayDelta < smartActiveSignificantDelayDelta &&
		current.StabilityPoints >= candidate.StabilityPoints+30 && candidate.VolatilityPenalty >= current.VolatilityPenalty+4
}

func (s *SmartActive) isAvoidedCandidate(tag string, h *adapter.URLTestHistory, e *smartEvidence) bool {
	until, avoided := s.avoidUntil[tag]
	if !avoided || time.Now().After(until) {
		if avoided {
			delete(s.avoidUntil, tag)
		}
		return false
	}
	return true
}

func userRefreshCandidatePenalized(h *adapter.URLTestHistory) bool {
	return h != nil && (h.RuntimePenalty > 0 || h.RealUserPenalty > 0 || h.DegradationPoints > 0 || h.VolatilityPenalty > 0 || h.UDPPenalty > 0)
}

func userRefreshMinimalTie(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory) bool {
	current, candidate := history[currentTag], history[candidateTag]
	if current == nil || candidate == nil || !current.Success || !candidate.Success {
		return false
	}
	if getHealthScore(currentTag, current) != getHealthScore(candidateTag, candidate) {
		return false
	}
	currentDelay := getModifiedDelay(current)
	candidateDelay := getModifiedDelay(candidate)
	if currentDelay > candidateDelay {
		return currentDelay-candidateDelay <= smartActiveMinimalDelayDelta
	}
	return candidateDelay-currentDelay <= smartActiveMinimalDelayDelta
}

func decisionMode(requested string, bootstrap bool) string {
	if requested != "" {
		return requested
	}
	if bootstrap {
		return "vpn_start"
	}
	return "background"
}

func smartActiveState(h *adapter.URLTestHistory) string {
	if h == nil {
		return "SUSPECT"
	}
	if h.CheckGeneration > 0 && h.URLTestStatus == urltest.StatusChecking {
		if urltest.IsCriticalProbeError(h.ErrorType) || h.DegradationPoints >= 75 || (!h.Success && h.RealUserPenalty >= 20) {
			return "CRITICAL"
		}
		return "SUSPECT"
	}
	if urltest.IsCriticalProbeError(h.ErrorType) || h.DegradationPoints >= 75 || (!h.Success && h.RealUserPenalty >= 20) {
		return "CRITICAL"
	}
	if !h.Success && isTransientSmartActiveError(h.ErrorType) && h.DegradationPoints < 30 && h.RealUserPenalty < 12 {
		return "SUSPECT"
	}
	score := getHealthScore("", h)
	if !h.Success || h.DegradationPoints >= 55 || score < 25 {
		return "BAD"
	}
	if h.DegradationPoints >= 30 || h.RuntimePenalty+h.RealUserPenalty >= 18 || score < 45 {
		return "DEGRADED"
	}
	if h.DegradationPoints >= 10 || h.RuntimePenalty+h.RealUserPenalty >= 8 || score < 60 || h.VolatilityPenalty >= 10 {
		return "SUSPECT"
	}
	return "GOOD"
}

func isTransientSmartActiveError(errorType string) bool {
	switch errorType {
	case urltest.ErrorTypeEOF, urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return true
	default:
		return false
	}
}

func runtimeDrivenActiveIssue(h *adapter.URLTestHistory) bool {
	return h != nil && (h.RuntimePenalty > 0 || h.RealUserPenalty > 0)
}

func runtimeCriticalActiveIssue(h *adapter.URLTestHistory) bool {
	return h != nil && (h.DegradationPoints >= 75 || h.RealUserPenalty >= 20 || h.RuntimePenalty >= 20 || urltest.IsCriticalProbeError(h.ErrorType))
}

func currentCheckInProgress(h *adapter.URLTestHistory) bool {
	return h != nil && h.CheckGeneration > 0 && h.URLTestStatus == urltest.StatusChecking && !h.CombinedReady
}

func candidateTag(candidate adapter.Outbound) string {
	if candidate == nil {
		return ""
	}
	return candidate.Tag()
}

func pendingAction(current adapter.Outbound) string {
	if current == nil {
		return "wait"
	}
	return "keep"
}

func cloneSmartActiveHistory(history *adapter.URLTestHistory) *adapter.URLTestHistory {
	if history == nil {
		return nil
	}
	cloned := *history
	if history.IpInfo != nil {
		ipInfo := *history.IpInfo
		cloned.IpInfo = &ipInfo
	}
	return &cloned
}

func (s *SmartActive) rememberFullGeneration(history map[string]*adapter.URLTestHistory, generation uint64) bool {
	if generation == 0 || generation < s.lastFullGeneration {
		return false
	}
	if generation == s.lastFullGeneration {
		updated := make(map[string]*adapter.URLTestHistory, len(s.lastFullHistory))
		for _, outbound := range s.outbounds {
			tag := outbound.Tag()
			saved := cloneSmartActiveHistory(s.lastFullHistory[tag])
			incoming := history[tag]
			if saved == nil || incoming == nil || incoming.CheckGeneration != generation {
				return false
			}
			mergeSmartActiveWorseningEvidence(saved, incoming)
			if newerSmartActiveFailure(incoming, saved) {
				applySmartActiveFailure(saved, incoming)
			}
			updated[tag] = saved
		}
		if smartActiveSnapshotsEqual(updated, s.lastFullHistory) {
			return false
		}
		s.lastFullHistory = updated
		return true
	}
	snapshot := make(map[string]*adapter.URLTestHistory, len(s.outbounds))
	for _, outbound := range s.outbounds {
		tag := outbound.Tag()
		item := history[tag]
		if item == nil || item.CheckGeneration != generation {
			return false
		}
		snapshot[tag] = cloneSmartActiveHistory(item)
	}
	s.lastFullGeneration = generation
	s.lastFullHistory = snapshot
	return true
}

// fullGenerationDecisionHistory keeps transport ranking anchored to the last
// complete cohort. A same-generation targeted retest may veto/worsen a saved
// candidate, but only a newer complete generation may improve its base ping or
// terminal status. The active's runtime evidence is kept current because it is
// backed by real traffic rather than candidate promotion.
func (s *SmartActive) fullGenerationDecisionHistory(activeTag string, current map[string]*adapter.URLTestHistory) map[string]*adapter.URLTestHistory {
	history := make(map[string]*adapter.URLTestHistory, len(s.lastFullHistory))
	for tag, saved := range s.lastFullHistory {
		item := cloneSmartActiveHistory(saved)
		latest := current[tag]
		mergeSmartActiveWorseningEvidence(item, latest)
		if tag == activeTag {
			mergeSmartActiveDynamicEvidence(item, latest)
		}
		if newerSmartActiveFailure(latest, saved) {
			applySmartActiveFailure(item, latest)
		}
		history[tag] = item
	}
	return history
}

func smartActiveSnapshotsEqual(left, right map[string]*adapter.URLTestHistory) bool {
	if len(left) != len(right) {
		return false
	}
	for tag, leftHistory := range left {
		rightHistory := right[tag]
		if leftHistory == nil || rightHistory == nil {
			if leftHistory != nil || rightHistory != nil {
				return false
			}
			continue
		}
		leftValue, rightValue := *leftHistory, *rightHistory
		// IpInfo is presentation metadata; PolicyPenalty already carries the only
		// part of it that affects Smart Active ranking. Clone allocation alone
		// must not make an otherwise identical snapshot look newer.
		leftValue.IpInfo = nil
		rightValue.IpInfo = nil
		if leftValue != rightValue {
			return false
		}
	}
	return true
}

// activeProbeDecisionHistory combines the current active's isolated live
// sample with candidates from the last coherent full generation. Dynamic
// runtime/real-user evidence is overlaid on the saved candidates, while their
// verified delay, readiness, timestamp and generation remain unchanged.
func (s *SmartActive) activeProbeDecisionHistory(tag string, probe *adapter.URLTestHistory, current map[string]*adapter.URLTestHistory) (map[string]*adapter.URLTestHistory, uint64) {
	// The throttled event is only a wake-up mechanism. If it was dropped or is
	// still queued, recover the newest coherent generation directly from the
	// ranking snapshot supplied by monitoring.
	observedGeneration := s.currentGeneration(current)
	if observedGeneration >= s.lastFullGeneration && observedGeneration != 0 && s.generationSettled(current, observedGeneration) {
		s.selectionGeneration = max(s.selectionGeneration, observedGeneration)
		if s.rememberFullGeneration(current, observedGeneration) {
			s.updateEvidence(current)
			s.reconcileActiveProbeAdvantage(s.fullGenerationDecisionHistory(tag, current), observedGeneration)
		}
	}
	if s.lastFullGeneration == 0 || len(s.lastFullHistory) == 0 {
		return nil, 0
	}

	decisionHistory := make(map[string]*adapter.URLTestHistory, len(s.lastFullHistory))
	for candidateTag, saved := range s.lastFullHistory {
		candidate := cloneSmartActiveHistory(saved)
		latest := current[candidateTag]
		mergeSmartActiveWorseningEvidence(candidate, latest)
		// A newer partial success cannot promote a server, but a newer terminal
		// failure must veto the older positive snapshot immediately. This closes
		// the race where the active probe finishes before the normal observer has
		// updated the candidate's failure streak.
		if newerSmartActiveFailure(latest, saved) {
			applySmartActiveFailure(candidate, latest)
		}
		decisionHistory[candidateTag] = candidate
	}
	active := cloneSmartActiveHistory(probe)
	if active == nil {
		return nil, 0
	}
	mergeSmartActiveDynamicEvidence(active, current[tag])
	active.CheckGeneration = s.lastFullGeneration
	active.IsFromCache = false
	decisionHistory[tag] = active
	return decisionHistory, s.lastFullGeneration
}

func (s *SmartActive) reconcileActiveProbeAdvantage(history map[string]*adapter.URLTestHistory, generation uint64) {
	if s.activeProbe.betterCandidate == "" || s.active == nil || generation == 0 {
		return
	}
	candidate, _, _, _ := s.bestSignificantCandidate(
		s.active.Tag(),
		history,
		generation,
		smartActiveState(history[s.active.Tag()]),
		1,
		true,
		smartActiveCandidateMaxAge,
	)
	if candidate == nil || candidate.Tag() != s.activeProbe.betterCandidate {
		s.resetActiveProbeAdvantage()
	}
}

func newerSmartActiveFailure(latest, saved *adapter.URLTestHistory) bool {
	if latest == nil || saved == nil || latest.CheckGeneration < saved.CheckGeneration {
		return false
	}
	if latest.CheckGeneration == saved.CheckGeneration && !latest.Time.After(saved.Time) {
		return false
	}
	if latest.URLTestStatus == urltest.StatusFailed {
		return true
	}
	if !latest.CombinedReady {
		return false
	}
	return !latest.Success && latest.ErrorType != "" && latest.ErrorType != urltest.ErrorTypeNone
}

func applySmartActiveFailure(target, latest *adapter.URLTestHistory) {
	if target == nil || latest == nil {
		return
	}
	target.Success = false
	target.Delay = latest.Delay
	target.ErrorType = latest.ErrorType
	target.ErrorText = latest.ErrorText
	target.URLTestStatus = urltest.StatusFailed
}

func mergeSmartActiveWorseningEvidence(target, latest *adapter.URLTestHistory) {
	if target == nil || latest == nil {
		return
	}
	target.RuntimePenalty = max(target.RuntimePenalty, latest.RuntimePenalty)
	target.RealUserPenalty = max(target.RealUserPenalty, latest.RealUserPenalty)
	target.VolatilityPenalty = max(target.VolatilityPenalty, latest.VolatilityPenalty)
	target.DegradationPoints = max(target.DegradationPoints, latest.DegradationPoints)
	target.StabilityPoints = min(target.StabilityPoints, latest.StabilityPoints)
	target.PolicyPenalty = max(target.PolicyPenalty, latest.PolicyPenalty)
	if latest.UDPReady && latest.UDPPenalty >= target.UDPPenalty {
		target.UDPReady = true
		target.UDPProbeAvailable = latest.UDPProbeAvailable
		target.UDPPenalty = latest.UDPPenalty
		target.UDPLoss = latest.UDPLoss
		target.UDPJitterMs = latest.UDPJitterMs
	}
}

func mergeSmartActiveDynamicEvidence(target, latest *adapter.URLTestHistory) {
	if target == nil || latest == nil {
		return
	}
	target.RuntimePenalty = latest.RuntimePenalty
	target.RealUserPenalty = latest.RealUserPenalty
	target.VolatilityPenalty = latest.VolatilityPenalty
	target.StabilityPoints = latest.StabilityPoints
	target.DegradationPoints = latest.DegradationPoints
	if latest.PolicyPenalty > 0 {
		target.PolicyPenalty = latest.PolicyPenalty
	}
}

type smartCandidateStatus struct {
	ok     bool
	reason string
}

func (s *SmartActive) currentGeneration(history map[string]*adapter.URLTestHistory) uint64 {
	var newest uint64
	for _, outbound := range s.outbounds {
		h := history[outbound.Tag()]
		if h == nil || h.CheckGeneration == 0 || h.Time.IsZero() || h.Time.Before(s.startedAt) || h.IsFromCache {
			continue
		}
		if h.CheckGeneration > newest {
			newest = h.CheckGeneration
		}
	}
	return newest
}

func (s *SmartActive) generationSettled(history map[string]*adapter.URLTestHistory, generation uint64) bool {
	if generation == 0 || len(s.outbounds) == 0 {
		return false
	}
	for _, outbound := range s.outbounds {
		h := history[outbound.Tag()]
		if h == nil || h.CheckGeneration != generation || h.Time.IsZero() || h.Time.Before(s.startedAt) || h.IsFromCache || !h.CombinedReady {
			return false
		}
		switch h.URLTestStatus {
		case urltest.StatusSuccess, urltest.StatusFailed:
		case "":
			if !h.Success && (h.ErrorType == "" || h.ErrorType == urltest.ErrorTypeNone) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func (s *SmartActive) generationCoversAll(history map[string]*adapter.URLTestHistory, generation uint64) bool {
	if generation == 0 || len(s.outbounds) == 0 {
		return false
	}
	for _, outbound := range s.outbounds {
		h := history[outbound.Tag()]
		if h == nil || h.CheckGeneration != generation || h.Time.IsZero() || h.Time.Before(s.startedAt) || h.IsFromCache {
			return false
		}
	}
	return true
}

func (s *SmartActive) bootstrapGenerationSettled(history map[string]*adapter.URLTestHistory, generation uint64) bool {
	if generation == 0 || len(s.outbounds) == 0 {
		return false
	}
	for _, outbound := range s.outbounds {
		h := history[outbound.Tag()]
		// A partial probe may supersede this outbound's task after the full
		// cohort started. Its newer terminal result closes the pending slot, but
		// bestBootstrapCandidate still excludes it from generation's ranking.
		if h == nil || h.CheckGeneration < generation || h.Time.IsZero() || h.Time.Before(s.startedAt) || h.IsFromCache || !h.CombinedReady {
			return false
		}
		switch h.URLTestStatus {
		case urltest.StatusSuccess, urltest.StatusFailed:
		case "":
			if !h.Success && (h.ErrorType == "" || h.ErrorType == urltest.ErrorTypeNone) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func (s *SmartActive) hasOutbound(tag string) bool {
	for _, outbound := range s.outbounds {
		if outbound.Tag() == tag {
			return true
		}
	}
	return false
}

func (s *SmartActive) candidateStatus(tag string, h *adapter.URLTestHistory, generation uint64) smartCandidateStatus {
	if tag == "" || !s.hasOutbound(tag) {
		return smartCandidateStatus{reason: "unknown_outbound"}
	}
	if h == nil {
		return smartCandidateStatus{reason: "missing_history"}
	}
	if generation == 0 {
		return smartCandidateStatus{reason: "missing_current_generation"}
	}
	if h.CheckGeneration == 0 {
		return smartCandidateStatus{reason: "missing_generation"}
	}
	if h.CheckGeneration != generation {
		return smartCandidateStatus{reason: "stale_generation"}
	}
	if h.Time.IsZero() || h.Time.Before(s.startedAt) {
		return smartCandidateStatus{reason: "stale_timestamp"}
	}
	if h.IsFromCache {
		return smartCandidateStatus{reason: "cached_history"}
	}
	if !h.Success {
		if h.ErrorType != "" {
			return smartCandidateStatus{reason: "failed_" + h.ErrorType}
		}
		return smartCandidateStatus{reason: "failed"}
	}
	if h.ErrorType != "" && h.ErrorType != urltest.ErrorTypeNone {
		return smartCandidateStatus{reason: "error_" + h.ErrorType}
	}
	if h.URLTestStatus != "" && h.URLTestStatus != urltest.StatusSuccess {
		return smartCandidateStatus{reason: "status_" + h.URLTestStatus}
	}
	if !h.CombinedReady {
		return smartCandidateStatus{reason: "combined_not_ready"}
	}
	if getPolicyPenalty(tag, h) >= 50 {
		return smartCandidateStatus{reason: "policy_blocked"}
	}
	if getHealthScore(tag, h) < 35 {
		return smartCandidateStatus{reason: "score_below_minimum"}
	}
	state := smartActiveState(h)
	if state == "BAD" || state == "CRITICAL" {
		return smartCandidateStatus{reason: "bad_health_state"}
	}
	return smartCandidateStatus{ok: true}
}
