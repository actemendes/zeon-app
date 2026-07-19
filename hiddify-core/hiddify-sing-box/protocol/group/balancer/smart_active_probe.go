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
)

type smartActiveProbeEvidence struct {
	tag                string
	lastProbeAt        time.Time
	hardFailureStreak  int
	poorQualityStreak  int
	confirmedUnhealthy bool
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

	hardFailure := activeProbeHardFailure(probe)
	poorQuality := !hardFailure && activeProbePoorQuality(probe)
	if !hardFailure && !poorQuality {
		s.activeProbe.hardFailureStreak = 0
		s.activeProbe.poorQualityStreak = 0
		s.activeProbe.confirmedUnhealthy = false
		s.decision = smartDecision{
			action: "keep", reason: "active_probe_healthy", from: tag,
			state: "GOOD", mode: "active_probe",
		}
		return smartActiveProbeUpdate{}
	}

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
	candidate := s.bestActiveFailoverCandidate(tag, history, s.selectionGeneration)
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
	changed := s.switchTo(current, candidate, switchReason, state, history, s.selectionGeneration)
	s.decision.mode = "active_probe"
	if changed {
		s.activeProbe = smartActiveProbeEvidence{tag: candidate.Tag()}
	}
	return smartActiveProbeUpdate{changed: changed}
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
		return getModifiedDelay(history[left.Tag()]) < getModifiedDelay(history[right.Tag()])
	})
	for _, candidate := range candidates {
		tag := candidate.Tag()
		if tag == currentTag || !s.candidateStatus(tag, history[tag], generation).ok {
			continue
		}
		evidence := s.evidence[tag]
		if evidence == nil || evidence.successStreak < 1 || evidence.failureStreak > 0 {
			continue
		}
		if s.isAvoidedCandidate(tag, history[tag], evidence) {
			continue
		}
		return candidate
	}
	return nil
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
