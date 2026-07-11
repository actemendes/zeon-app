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
	smartActiveSignificantDelayDelta = 80
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
		evidence:   make(map[string]*smartEvidence),
		avoidUntil: make(map[string]time.Time),
	}
	// Before the first monitoring cycle there is no evidence. Keep the legacy
	// fallback available so a cold start can still connect, but prefer a
	// non-policy-penalized outbound when the profile starts with RU servers.
	if len(outbounds) > 0 {
		strategy.active = firstPolicyPreferredOutbound(outbounds)
		strategy.decision = smartDecision{action: "fallback", reason: "cold_start_no_health", to: strategy.active.Tag(), state: "SUSPECT", mode: "vpn_start"}
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

	s.updateEvidence(history)
	current := s.active
	// Profiles created by older cores may have delay-only history. Until a
	// structured result arrives, retain the old lowest-delay fallback instead
	// of treating missing Success/ErrorType as proof that every server is bad.
	if !hasUsableHealth(history) {
		if current != nil && currentCheckInProgress(history[current.Tag()]) && !runtimeCriticalActiveIssue(history[current.Tag()]) {
			s.decision = smartDecision{action: "keep", reason: "current_temporarily_kept_during_refresh", from: current.Tag(), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		fallback := s.delayFallback(history)
		if fallback != nil && (current == nil || fallback.Tag() != current.Tag()) {
			from := ""
			if current != nil {
				from = current.Tag()
			}
			s.active = fallback
			s.decision = smartDecision{action: "fallback", reason: "health_unavailable_delay_fallback", from: from, to: fallback.Tag(), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
			return true
		}
		if current != nil {
			s.decision = smartDecision{action: "keep", reason: "health_unavailable_delay_fallback", from: current.Tag(), state: "SUSPECT", mode: decisionMode(mode, s.bootstrap)}
		}
		return false
	}

	forcedMode := mode
	if forcedMode == "" && s.bootstrap && hasFreshUsableHealth(history) {
		forcedMode = "vpn_start"
	}
	if forcedMode != "" {
		candidate := s.bestFreshCandidate(history)
		if candidate != nil {
			if current == nil {
				s.active = candidate
				s.bootstrap = false
				s.decision = smartDecision{action: "switch", reason: forcedMode + "_initial_fresh_candidate", to: candidate.Tag(), state: "GOOD", mode: forcedMode}
				return true
			}
			if forcedMode == "user_refresh" {
				return s.applyUserRefreshDecision(current, candidate, history)
			}
			if s.shouldForceSwitch(current.Tag(), candidate.Tag(), history, forcedMode) {
				s.switchTo(current, candidate, forcedMode+"_fresh_best_candidate", smartActiveState(history[current.Tag()]))
				s.decision.mode = forcedMode
				s.bootstrap = false
				return true
			}
			s.bootstrap = false
			s.decision = smartDecision{action: "keep", reason: forcedMode + "_current_best_or_close", from: current.Tag(), to: candidate.Tag(), state: smartActiveState(history[current.Tag()]), mode: forcedMode}
			return false
		}
	}
	if s.bootstrap && hasFreshUsableHealth(history) {
		s.bootstrap = false
	}

	if current == nil {
		candidate := s.bestCandidate(history, true)
		if candidate == nil {
			candidate = s.delayFallback(history)
		}
		if candidate == nil {
			s.decision = smartDecision{action: "fallback", reason: "no_outbound", mode: decisionMode(mode, s.bootstrap)}
			return false
		}
		s.active = candidate
		s.decision = smartDecision{action: "switch", reason: "initial_healthy_candidate", to: candidate.Tag(), state: "GOOD", mode: decisionMode(mode, s.bootstrap)}
		return true
	}

	currentHistory := history[current.Tag()]
	state := smartActiveState(currentHistory)
	candidate := s.bestCandidate(history, state == "BAD" || state == "CRITICAL")
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
			s.switchTo(current, candidate, reason, state)
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		fallback := s.delayFallback(history)
		if fallback != nil && fallback.Tag() != current.Tag() {
			s.active = fallback
			s.decision = smartDecision{action: "fallback", reason: "critical_delay_fallback", from: current.Tag(), to: fallback.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
			return true
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
			s.switchTo(current, candidate, reason, state)
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		s.decision = smartDecision{action: "keep", reason: "bad_without_confirmed_candidate", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if state == "DEGRADED" {
		if candidate != nil && candidate.Tag() != current.Tag() && s.betterEnough(current.Tag(), candidate.Tag(), history, 8) {
			reason := "degraded_active_better_candidate"
			if runtimeDrivenActiveIssue(currentHistory) {
				reason = "runtime_errors_current_degraded"
			}
			s.switchTo(current, candidate, reason, state)
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		s.decision = smartDecision{action: "keep", reason: "degraded_collecting_evidence", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if state == "SUSPECT" {
		if candidate != nil && candidate.Tag() != current.Tag() && s.betterEnough(current.Tag(), candidate.Tag(), history, 14) {
			s.switchTo(current, candidate, "suspect_stably_better_candidate", state)
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
		}
		s.decision = smartDecision{action: "keep", reason: "suspect_collecting_evidence", from: current.Tag(), state: state, mode: decisionMode(mode, s.bootstrap)}
		return false
	}
	if candidate != nil && candidate.Tag() != current.Tag() && s.policyPreferredCandidate(current.Tag(), candidate.Tag(), history) {
		s.switchTo(current, candidate, "policy_preferred_foreign_candidate", state)
		s.decision.mode = decisionMode(mode, s.bootstrap)
		return true
	}
	if candidate != nil && candidate.Tag() != current.Tag() {
		shouldSwitch, reason := s.shouldSwitchHealthyActive(current.Tag(), candidate.Tag(), history)
		if shouldSwitch {
			s.switchTo(current, candidate, reason, state)
			s.decision.mode = decisionMode(mode, s.bootstrap)
			return true
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

func (s *SmartActive) switchTo(from, to adapter.Outbound, reason, state string) {
	fromTag := ""
	toTag := ""
	if from != nil {
		fromTag = from.Tag()
	}
	if to != nil {
		toTag = to.Tag()
	}
	if fromTag != "" && toTag != "" && fromTag != toTag {
		s.avoidUntil[fromTag] = time.Now().Add(smartActiveAvoidAfterSwitch)
	}
	s.active = to
	s.decision = smartDecision{action: "switch", reason: reason, from: fromTag, to: toTag, state: state}
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
		state := smartActiveState(h)
		cleanSuccess := h != nil && h.Success && (h.ErrorType == "" || h.ErrorType == urltest.ErrorTypeNone)
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

func (s *SmartActive) bestCandidate(history map[string]*adapter.URLTestHistory, emergency bool) adapter.Outbound {
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
		if h == nil || !h.Success || h.ErrorType != "" && h.ErrorType != urltest.ErrorTypeNone {
			continue
		}
		if h.CheckGeneration > 0 && !h.CombinedReady {
			continue
		}
		if getHealthScore(tag, h) < 35 {
			continue
		}
		// A previously bad server must prove recovery with multiple clean probes.
		requiredSuccesses := 2
		if emergency {
			requiredSuccesses = 1
		}
		if e == nil || e.successStreak < requiredSuccesses || e.failureStreak > 0 {
			continue
		}
		if s.isAvoidedCandidate(tag, h, e) {
			continue
		}
		return candidate
	}
	return nil
}

func (s *SmartActive) bestFreshCandidate(history map[string]*adapter.URLTestHistory) adapter.Outbound {
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
		if h == nil || h.IsFromCache || !h.Success || h.ErrorType != "" && h.ErrorType != urltest.ErrorTypeNone {
			continue
		}
		if h.CheckGeneration > 0 && !h.CombinedReady {
			continue
		}
		if getHealthScore(tag, h) < 35 || smartActiveState(h) == "BAD" || smartActiveState(h) == "CRITICAL" {
			continue
		}
		if s.isAvoidedCandidate(tag, h, s.evidence[tag]) {
			continue
		}
		return candidate
	}
	return nil
}

func (s *SmartActive) applyUserRefreshDecision(current, candidate adapter.Outbound, history map[string]*adapter.URLTestHistory) bool {
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
	if !isFreshSuccessfulCandidate(candidateTag, candidateHistory) {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_not_fresh_success", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}
	if currentHistory == nil || !currentHistory.Success || currentHistory.IsFromCache || currentState == "BAD" || currentState == "CRITICAL" {
		s.switchTo(current, candidate, "user_refresh_best_fresh_candidate", currentState)
		s.decision.mode = "user_refresh"
		return true
	}
	if userRefreshCandidatePenalized(candidateHistory) {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_penalized", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}
	if userRefreshMinimalTie(currentTag, candidateTag, history) {
		s.decision = smartDecision{action: "keep", reason: "user_refresh_candidate_tie_minimal_delta", from: currentTag, to: candidateTag, state: currentState, mode: "user_refresh"}
		return false
	}

	s.switchTo(current, candidate, "user_refresh_best_fresh_candidate", currentState)
	s.decision.mode = "user_refresh"
	return true
}

func (s *SmartActive) delayFallback(history map[string]*adapter.URLTestHistory) adapter.Outbound {
	var selected adapter.Outbound
	for _, outbound := range s.outbounds {
		if selected == nil || preferFallbackOutbound(outbound, selected, history) {
			selected = outbound
		}
	}
	return selected
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

func (s *SmartActive) betterEnough(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, margin int) bool {
	current, candidate := history[currentTag], history[candidateTag]
	if candidate == nil || !candidate.Success {
		return false
	}
	if current == nil || !current.Success {
		return true
	}
	return getHealthScore(candidateTag, candidate) >= getHealthScore(currentTag, current)+margin &&
		candidate.StabilityPoints >= current.StabilityPoints-10 &&
		candidate.VolatilityPenalty <= current.VolatilityPenalty+4
}

func (s *SmartActive) shouldSwitchHealthyActive(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory) (bool, string) {
	current, candidate := history[currentTag], history[candidateTag]
	if !isFreshSuccessfulCandidate(candidateTag, candidate) {
		return false, "candidate_not_fresh_success"
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

func (s *SmartActive) policyPreferredCandidate(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory) bool {
	current, candidate := history[currentTag], history[candidateTag]
	if current == nil || candidate == nil || !candidate.Success {
		return false
	}
	if getPolicyPenalty(currentTag, current) == 0 || getPolicyPenalty(candidateTag, candidate) > 0 {
		return false
	}
	return s.betterEnough(currentTag, candidateTag, history, 4)
}

func isFreshSuccessfulCandidate(tag string, h *adapter.URLTestHistory) bool {
	if h == nil || h.IsFromCache || !h.Success || h.ErrorType != "" && h.ErrorType != urltest.ErrorTypeNone {
		return false
	}
	if h.CheckGeneration > 0 && !h.CombinedReady {
		return false
	}
	if getHealthScore(tag, h) < 35 {
		return false
	}
	state := smartActiveState(h)
	return state != "BAD" && state != "CRITICAL"
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

func (s *SmartActive) shouldForceSwitch(currentTag, candidateTag string, history map[string]*adapter.URLTestHistory, mode string) bool {
	if currentTag == "" || candidateTag == "" || currentTag == candidateTag {
		return false
	}
	current, candidate := history[currentTag], history[candidateTag]
	if candidate == nil || !candidate.Success {
		return false
	}
	if current == nil || !current.Success || current.IsFromCache {
		return true
	}
	state := smartActiveState(current)
	if state == "BAD" || state == "CRITICAL" {
		return true
	}
	candidateScore := getHealthScore(candidateTag, candidate)
	currentScore := getHealthScore(currentTag, current)
	if candidateScore >= currentScore+5 {
		return true
	}
	if candidateScore >= currentScore && int(getModifiedDelay(current))-int(getModifiedDelay(candidate)) >= smartActiveSignificantDelayDelta {
		return true
	}
	return mode == "vpn_start" && candidateScore > currentScore
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
