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

	mu         sync.Mutex
	active     adapter.Outbound
	bootstrap  bool
	confirmed  bool
	startedAt  time.Time
	evidence   map[string]*smartEvidence
	avoidUntil map[string]time.Time
	decision   smartDecision
	recovered  []string
}

type smartEvidence struct {
	successStreak   int
	failureStreak   int
	lastScore       int
	recoveryPending bool
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
	strategy := &SmartActive{
		outbounds:  outbounds,
		bootstrap:  true,
		startedAt:  time.Now(),
		evidence:   make(map[string]*smartEvidence),
		avoidUntil: make(map[string]time.Time),
	}
	// Before the first monitoring cycle there is no evidence. Keep the legacy
	// fallback available so a cold start can still connect, but prefer a
	// non-policy-penalized outbound when the profile starts with RU servers.
	if len(outbounds) > 0 {
		strategy.active = firstPolicyPreferredOutbound(outbounds)
		strategy.decision = smartDecision{action: "keep", reason: "provisional_cold_start_no_health", from: strategy.active.Tag(), state: "SUSPECT", mode: "vpn_start"}
	}
	return strategy
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
	return s.updateOutboundsInfo(history, "")
}

func (s *SmartActive) UpdateOutboundsInfoForManualRefresh(history map[string]*adapter.URLTestHistory) bool {
	return s.updateOutboundsInfo(history, "user_refresh")
}

func (s *SmartActive) updateOutboundsInfo(history map[string]*adapter.URLTestHistory, mode string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	generation := s.currentGeneration(history)
	s.updateEvidence(history, generation)
	current := s.active

	if current == nil {
		current = firstPolicyPreferredOutbound(s.outbounds)
		if current == nil {
			s.decision = smartDecision{action: "fallback", reason: "no_outbound", mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		s.active = current
		s.decision = smartDecision{action: "keep", reason: "provisional_selected", from: current.Tag(), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		return true
	}

	if !s.confirmed {
		candidate := s.bestCandidate(history, true, false, generation)
		if candidate != nil {
			changed := s.confirmActive(current, candidate, "first_confirmed_current_generation_candidate", decisionMode(mode, s.bootstrap))
			s.bootstrap = false
			return changed
		}
		tag, reason := s.bestRejectedCandidate(history, generation)
		if reason == "" {
			if generation == 0 {
				reason = "provisional_waiting_for_first_generation"
			} else {
				reason = "provisional_waiting_for_current_generation_ready"
			}
		} else {
			reason = "candidate_rejected_" + reason
		}
		s.decision = smartDecision{action: "keep", reason: reason, from: current.Tag(), to: tag, state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		return false
	}

	currentHistory := history[current.Tag()]
	state := smartActiveState(currentHistory)
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

	candidate := s.bestCandidate(history, state == "BAD" || state == "CRITICAL", true, generation)
	if currentCheckInProgress(currentHistory) && !runtimeCriticalActiveIssue(currentHistory) {
		s.decision = smartDecision{action: "keep", reason: "current_temporarily_kept_during_refresh", from: current.Tag(), to: candidateTag(candidate), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}

	if state == "CRITICAL" {
		if candidate != nil && candidate.Tag() != current.Tag() {
			reason := "critical_active_failure"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_critical"
			}
			if s.switchTo(current, candidate, reason, state, history, generation) {
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
		if candidate != nil && candidate.Tag() != current.Tag() {
			reason := "bad_active_confirmed_candidate"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_bad"
			}
			if s.switchTo(current, candidate, reason, state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "keep", reason: "bad_without_confirmed_candidate", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if state == "DEGRADED" {
		if candidate != nil && candidate.Tag() != current.Tag() && s.betterEnough(current.Tag(), candidate.Tag(), history, generation, 8) {
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
		if candidate != nil && candidate.Tag() != current.Tag() && s.betterEnough(current.Tag(), candidate.Tag(), history, generation, 14) {
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
	if candidate != nil && candidate.Tag() != current.Tag() && s.policyPreferredCandidate(current.Tag(), candidate.Tag(), history, generation) {
		if s.switchTo(current, candidate, "policy_preferred_foreign_candidate", state, history, generation) {
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		s.decision.mode = decisionMode(mode, s.bootstrap)
		return false
	}
	if candidate != nil && candidate.Tag() != current.Tag() {
		shouldSwitch, reason := s.shouldSwitchHealthyActive(current.Tag(), candidate.Tag(), history, generation)
		if shouldSwitch {
			if s.switchTo(current, candidate, reason, state, history, generation) {
				s.decision.mode = decisionMode(mode, s.bootstrap)
				return true
			}
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return false
		}
		s.decision = smartDecision{action: "keep", reason: reason, from: current.Tag(), to: candidate.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
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
	if fromTag != toTag {
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
	}
	s.active = to
	s.confirmed = true
	s.decision = smartDecision{action: "switch", reason: reason, from: fromTag, to: toTag, state: state}
	return true
}

func (s *SmartActive) updateEvidence(history map[string]*adapter.URLTestHistory, generation uint64) {
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
		state := smartActiveState(h)
		cleanSuccess := s.candidateStatus(tag, h, generation).ok
		if state == "BAD" || state == "CRITICAL" {
			e.recoveryPending = true
			e.failureStreak++
			e.successStreak = 0
		} else if cleanSuccess {
			e.successStreak++
			e.failureStreak = 0
			if e.recoveryPending && e.successStreak >= 2 {
				e.recoveryPending = false
				s.recovered = append(s.recovered, tag)
			}
		} else if h != nil {
			e.failureStreak++
			e.successStreak = 0
		}
		if h != nil {
			e.lastScore = getHealthScore(tag, h)
		}
	}
}

func (s *SmartActive) bestCandidate(history map[string]*adapter.URLTestHistory, emergency bool, requireEvidence bool, generation uint64) adapter.Outbound {
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
		h := history[tag]
		e := s.evidence[tag]
		if !s.candidateStatus(tag, h, generation).ok {
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
			continue
		}
		return candidate
	}
	return nil
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

func (s *SmartActive) betterEnough(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, generation uint64, margin int) bool {
	current, candidate := history[currentTag], history[candidateTag]
	if !s.candidateStatus(candidateTag, candidate, generation).ok {
		return false
	}
	if current == nil || !current.Success {
		return true
	}
	return getHealthScore(candidateTag, candidate) >= getHealthScore(currentTag, current)+margin &&
		candidate.StabilityPoints >= current.StabilityPoints-10 &&
		candidate.VolatilityPenalty <= current.VolatilityPenalty+4
}

func (s *SmartActive) shouldSwitchHealthyActive(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, generation uint64) (bool, string) {
	current, candidate := history[currentTag], history[candidateTag]
	if status := s.candidateStatus(candidateTag, candidate, generation); !status.ok {
		return false, "candidate_rejected_" + status.reason
	}
	if s.isAvoidedCandidate(candidateTag, candidate, s.evidence[candidateTag]) {
		return false, "candidate_recently_avoided_waiting_recovery"
	}
	if current == nil || !current.Success {
		return true, "current_unhealthy_candidate_fresh"
	}
	if currentRealUserAdvantage(current, candidate) {
		return false, "current_real_traffic_stable_and_candidate_advantage_insufficient"
	}
	if userRefreshCandidatePenalized(candidate) {
		return false, "candidate_runtime_or_udp_penalized"
	}
	e := s.evidence[candidateTag]
	if e == nil || e.successStreak < smartActiveCleanEvidenceRequired || e.failureStreak > 0 {
		return false, "candidate_waiting_for_clean_evidence"
	}

	currentScore := getHealthScore(currentTag, current)
	candidateScore := getHealthScore(candidateTag, candidate)
	currentDelay := getModifiedDelay(current)
	candidateDelay := getModifiedDelay(candidate)
	delayDelta := int(currentDelay) - int(candidateDelay)
	if delayDelta <= smartActiveMinimalDelayDelta {
		return false, "delay_delta_minimal_current_stable"
	}
	if candidateScore >= currentScore-smartActiveComparableScoreDelta && delayDelta >= smartActiveSignificantDelayDelta {
		return true, "same_quality_significantly_lower_delay"
	}
	if candidateScore >= currentScore+smartActiveScoreSwitchMargin {
		return true, "candidate_score_better_with_clean_evidence"
	}
	return false, "candidate_advantage_insufficient"
}

func currentRealUserAdvantage(current, candidate *adapter.URLTestHistory) bool {
	if current == nil || candidate == nil {
		return false
	}
	currentPenalty := current.RuntimePenalty + current.RealUserPenalty + current.DegradationPoints + current.UDPPenalty
	candidatePenalty := candidate.RuntimePenalty + candidate.RealUserPenalty + candidate.DegradationPoints + candidate.UDPPenalty
	if candidatePenalty >= currentPenalty+8 {
		return true
	}
	return current.StabilityPoints >= candidate.StabilityPoints+30 && candidate.VolatilityPenalty >= current.VolatilityPenalty+4
}

func (s *SmartActive) isAvoidedCandidate(tag string, h *adapter.URLTestHistory, e *smartEvidence) bool {
	until, avoided := s.avoidUntil[tag]
	if !avoided || time.Now().After(until) {
		if avoided {
			delete(s.avoidUntil, tag)
		}
		return false
	}
	if h == nil || h.IsFromCache || smartActiveState(h) != "GOOD" {
		return true
	}
	return e == nil || e.successStreak < smartActiveCleanEvidenceRequired || e.failureStreak > 0
}

func (s *SmartActive) policyPreferredCandidate(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, generation uint64) bool {
	current, candidate := history[currentTag], history[candidateTag]
	if current == nil || !s.candidateStatus(candidateTag, candidate, generation).ok {
		return false
	}
	if getPolicyPenalty(currentTag, current) == 0 || getPolicyPenalty(candidateTag, candidate) > 0 {
		return false
	}
	return s.betterEnough(currentTag, candidateTag, history, generation, 4)
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

type smartCandidateStatus struct {
	ok     bool
	reason string
}

func (s *SmartActive) currentGeneration(history map[string]*adapter.URLTestHistory) uint64 {
	var generation uint64
	for _, outbound := range s.outbounds {
		h := history[outbound.Tag()]
		if h != nil && h.CheckGeneration > generation && !h.Time.IsZero() && !h.Time.Before(s.startedAt) && !h.IsFromCache {
			generation = h.CheckGeneration
		}
	}
	return generation
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
