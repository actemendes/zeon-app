package balancer

import (
	"sort"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

const (
	smartActiveProbeConfirmations = 2
	smartActiveUnusableDelay      = 1500
	smartActiveSevereUDPLoss      = 80
	smartActiveCandidateMaxAge    = 10 * time.Minute
)

type smartActiveProbeEvidence struct {
	tag                string
	lastProbeAt        time.Time
	hardFailureStreak  int
	poorQualityStreak  int
	confirmedUnhealthy bool
	betterCandidate    string
	betterStreak       int
}

type smartActiveProbeUpdate struct {
	changed           bool
	retry             bool
	refreshCandidates bool
}

// UpdateActiveProbe evaluates an isolated sample of the outbound that is
// carrying user traffic. A single bad sample is never enough to switch: the
// caller receives retry=true and performs one small confirmation probe.
func (s *SmartActive) UpdateActiveProbe(tag string, probe *adapter.URLTestHistory, history map[string]*adapter.URLTestHistory) smartActiveProbeUpdate {
	s.mu.Lock()
	defer s.mu.Unlock()

	current := s.active
	if current == nil || tag == "" || current.Tag() != tag || probe == nil || probe.Time.IsZero() {
		return smartActiveProbeUpdate{}
	}
	if s.activeProbe.tag != tag {
		s.activeProbe = smartActiveProbeEvidence{tag: tag}
	}
	if !probe.Time.After(s.activeProbe.lastProbeAt) {
		return smartActiveProbeUpdate{}
	}
	s.activeProbe.lastProbeAt = probe.Time
	decisionHistory, generation := s.activeProbeDecisionHistory(tag, probe, history)
	if decisionHistory == nil {
		// Without a coherent completed generation there are no eligible
		// comparison/failover candidates. In particular, never promote a lone
		// completed member from an in-progress or standalone partial generation.
		decisionHistory = make(map[string]*adapter.URLTestHistory, 1)
		decisionHistory[tag] = cloneSmartActiveHistory(probe)
		generation = 0
	}
	activeHistory := decisionHistory[tag]
	activeState := smartActiveState(activeHistory)
	s.rememberDecisionDiagnostics(decisionHistory, generation, "active_probe")

	hardFailure := activeProbeHardFailure(probe)
	poorQuality := !hardFailure && activeProbePoorQuality(probe)
	if !hardFailure && !poorQuality {
		s.activeProbe.hardFailureStreak = 0
		s.activeProbe.poorQualityStreak = 0
		s.activeProbe.confirmedUnhealthy = false
		candidate, comparisonTag, refreshCandidates := s.bestActiveProbeUpgradeCandidate(tag, decisionHistory, generation, activeState)
		if candidate == nil {
			s.resetActiveProbeAdvantage()
			reason := "active_probe_candidate_advantage_insufficient"
			if generation == 0 {
				reason = "active_probe_waiting_for_full_generation"
			}
			s.decision = smartDecision{
				action: "keep", reason: reason, from: tag, to: comparisonTag,
				state: activeState, mode: "active_probe",
			}
			return smartActiveProbeUpdate{refreshCandidates: refreshCandidates}
		}

		if s.activeProbe.betterCandidate == candidate.Tag() {
			s.activeProbe.betterStreak++
		} else {
			s.activeProbe.betterCandidate = candidate.Tag()
			s.activeProbe.betterStreak = 1
		}
		if s.activeProbe.betterStreak < smartActiveProbeConfirmations {
			s.decision = smartDecision{
				action: "keep", reason: "active_probe_waiting_better_candidate_confirmation", from: tag, to: candidate.Tag(),
				state: activeState, mode: "active_probe",
			}
			return smartActiveProbeUpdate{}
		}

		changed := s.switchTo(current, candidate, "active_probe_stably_better_candidate", activeState, decisionHistory, generation)
		s.decision.mode = "active_probe"
		if changed {
			s.activeProbe = smartActiveProbeEvidence{tag: candidate.Tag()}
		}
		return smartActiveProbeUpdate{changed: changed}
	}
	s.resetActiveProbeAdvantage()

	state := "DEGRADED"
	reason := "active_probe_waiting_quality_confirmation"
	streak := 0
	if hardFailure {
		state = "BAD"
		reason = "active_probe_waiting_failure_confirmation"
		s.activeProbe.hardFailureStreak++
		s.activeProbe.poorQualityStreak = 0
		streak = s.activeProbe.hardFailureStreak
	} else {
		s.activeProbe.poorQualityStreak++
		s.activeProbe.hardFailureStreak = 0
		streak = s.activeProbe.poorQualityStreak
	}

	if streak < smartActiveProbeConfirmations {
		s.decision = smartDecision{
			action: "keep", reason: reason, from: tag,
			state: state, mode: "active_probe",
		}
		return smartActiveProbeUpdate{retry: true}
	}

	s.activeProbe.confirmedUnhealthy = true
	s.markActiveProbeUnhealthy(tag)
	candidate := s.bestActiveFailoverCandidate(tag, decisionHistory, generation)
	if candidate == nil {
		s.decision = smartDecision{
			action: "keep", reason: "active_probe_confirmed_without_fresh_candidate", from: tag,
			state: state, mode: "active_probe",
		}
		return smartActiveProbeUpdate{refreshCandidates: true}
	}

	switchReason := "active_probe_confirmed_quality_failure"
	if hardFailure {
		switchReason = "active_probe_confirmed_connection_failure"
	}
	changed := s.switchTo(current, candidate, switchReason, state, decisionHistory, generation)
	s.decision.mode = "active_probe"
	if changed {
		s.activeProbe = smartActiveProbeEvidence{tag: candidate.Tag()}
	}
	return smartActiveProbeUpdate{changed: changed}
}

func (s *SmartActive) resetActiveProbeAdvantage() {
	s.activeProbe.betterCandidate = ""
	s.activeProbe.betterStreak = 0
}

func (s *SmartActive) markActiveProbeUnhealthy(tag string) {
	evidence := s.evidence[tag]
	if evidence == nil {
		evidence = &smartEvidence{}
		s.evidence[tag] = evidence
	}
	evidence.recoveryPending = true
	evidence.successStreak = 0
	evidence.failureStreak = max(evidence.failureStreak, smartActiveProbeConfirmations)
}

func (s *SmartActive) bestActiveProbeUpgradeCandidate(currentTag string, history map[string]*adapter.URLTestHistory, generation uint64, currentState string) (adapter.Outbound, string, bool) {
	candidate, comparisonTag, _, stale := s.bestSignificantCandidate(
		currentTag,
		history,
		generation,
		currentState,
		1,
		true,
		smartActiveCandidateMaxAge,
	)
	return candidate, comparisonTag, stale
}

func activeProbeHardFailure(probe *adapter.URLTestHistory) bool {
	if probe == nil || !probe.Success || probe.Delay == 0 || probe.Delay >= 65535 {
		return true
	}
	return probe.ErrorType != "" && probe.ErrorType != urltest.ErrorTypeNone
}

func activeProbePoorQuality(probe *adapter.URLTestHistory) bool {
	if probe == nil {
		return true
	}
	if probe.Delay >= smartActiveUnusableDelay {
		return true
	}
	return probe.UDPReady && probe.UDPProbeAvailable && probe.UDPLoss >= smartActiveSevereUDPLoss
}

func (s *SmartActive) bestActiveFailoverCandidate(currentTag string, history map[string]*adapter.URLTestHistory, generation uint64) adapter.Outbound {
	if generation == 0 {
		return nil
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
	var avoidedFallback adapter.Outbound
	for _, candidate := range candidates {
		tag := candidate.Tag()
		if tag == currentTag || !s.candidateStatus(tag, history[tag], generation).ok {
			continue
		}
		if time.Since(history[tag].Time) > smartActiveCandidateMaxAge {
			continue
		}
		evidence := s.evidence[tag]
		if evidence == nil || evidence.successStreak < 1 || evidence.failureStreak > 0 {
			continue
		}
		if s.isAvoidedCandidate(tag, history[tag], evidence) {
			if avoidedFallback == nil {
				avoidedFallback = candidate
			}
			continue
		}
		return candidate
	}
	// A confirmed live failure is an emergency. Prefer a non-avoided server,
	// but reuse a recently active verified server rather than leaving traffic on
	// the failed one when no other candidate exists.
	return avoidedFallback
}

// handleConfirmedActiveProbe lets a recovery full cycle finish finding a
// candidate without forgetting that the live active was already proven bad by
// two isolated samples.
func (s *SmartActive) handleConfirmedActiveProbe(current adapter.Outbound, history map[string]*adapter.URLTestHistory, generation uint64) (bool, bool) {
	if current == nil || !s.activeProbe.confirmedUnhealthy || s.activeProbe.tag != current.Tag() {
		return false, false
	}
	currentHistory := history[current.Tag()]
	if currentHistory != nil && currentHistory.CheckGeneration == generation &&
		currentHistory.Success && currentHistory.CombinedReady &&
		smartActiveState(currentHistory) != "BAD" && smartActiveState(currentHistory) != "CRITICAL" {
		s.activeProbe = smartActiveProbeEvidence{tag: current.Tag()}
		s.decision = smartDecision{
			action: "keep", reason: "active_probe_recovered_during_candidate_refresh", from: current.Tag(),
			state: smartActiveState(currentHistory), mode: "active_probe",
		}
		return false, true
	}
	candidate := s.bestActiveFailoverCandidate(current.Tag(), history, generation)
	if candidate == nil {
		s.decision = smartDecision{
			action: "keep", reason: "active_probe_confirmed_waiting_for_candidate", from: current.Tag(),
			state: "BAD", mode: "active_probe",
		}
		return false, true
	}
	changed := s.switchTo(current, candidate, "active_probe_confirmed_candidate_refreshed", "BAD", history, generation)
	s.decision.mode = "active_probe"
	if changed {
		s.activeProbe = smartActiveProbeEvidence{tag: candidate.Tag()}
	}
	return changed, true
}
