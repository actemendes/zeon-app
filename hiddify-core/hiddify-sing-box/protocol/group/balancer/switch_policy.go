package balancer

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

type switchInterruptionPolicy struct {
	switchType        string
	reason            string
	interruptExternal bool
}

func preserveSwitchPolicy(switchType, reason string) switchInterruptionPolicy {
	return switchInterruptionPolicy{
		switchType: switchType,
		reason:     reason,
	}
}

func smartSwitchInterruptionPolicy(
	decision smartDecision,
	activeHistory *adapter.URLTestHistory,
	failureStreak int,
) switchInterruptionPolicy {
	switchType := "regular_smart"
	if decision.mode == "user_refresh" {
		switchType = "better_score"
	} else if strings.Contains(decision.reason, "better") ||
		strings.Contains(decision.reason, "stably") ||
		strings.HasPrefix(decision.reason, "completed_batch_") {
		switchType = "better_score"
	} else if decision.state == "SUSPECT" || decision.state == "DEGRADED" || decision.state == "BAD" {
		switchType = "degraded"
	}
	policy := preserveSwitchPolicy(switchType, decision.reason)
	if decision.action != "switch" {
		return policy
	}

	confirmedByActiveProbe := decision.reason == "active_probe_confirmed_connection_failure"
	confirmedByCohort := decision.state == "CRITICAL" && failureStreak >= smartActiveProbeConfirmations
	if (confirmedByActiveProbe || confirmedByCohort) && confirmedOutboundFailure(activeHistory) {
		policy.switchType = "confirmed_emergency"
		policy.interruptExternal = true
	}
	return policy
}

// confirmedOutboundFailure deliberately excludes timeout, DNS and QUIC/UDP
// evidence because those can be caused by a physical-network transition,
// device DNS state, captive portal or temporary UDP loss. External sessions
// are interrupted only for repeated, fresh, outbound-specific failures while
// a fresh healthy replacement is already available.
func confirmedOutboundFailure(history *adapter.URLTestHistory) bool {
	if history == nil || history.Success || history.IsFromCache ||
		history.CheckGeneration == 0 || history.Time.IsZero() ||
		!history.CombinedReady || history.URLTestStatus != urltest.StatusFailed {
		return false
	}
	switch history.ErrorType {
	case urltest.ErrorTypeRefused,
		urltest.ErrorTypeTLSHandshakeFailed,
		urltest.ErrorTypeUnsupportedCurve:
		return true
	default:
		return false
	}
}

func opaqueOutboundID(tag string) string {
	if tag == "" {
		return "none"
	}
	sum := sha256.Sum256([]byte(tag))
	return hex.EncodeToString(sum[:6])
}

func sessionGenerationMatches(captured string) bool {
	current := os.Getenv("ZEON_SESSION_GENERATION")
	return captured == "" || current == "" || captured == current
}

func (s *SmartActive) switchInterruptionPolicy() switchInterruptionPolicy {
	s.mu.Lock()
	defer s.mu.Unlock()
	decision := s.decision
	history := s.diagnosticHistory[decision.from]
	failureStreak := 0
	if evidence := s.evidence[decision.from]; evidence != nil {
		failureStreak = evidence.failureStreak
	}
	return smartSwitchInterruptionPolicy(decision, history, failureStreak)
}

func (s *Balancer) applySwitchInterruption(policy switchInterruptionPolicy, oldTag, newTag string) {
	interruptExternal := policy.interruptExternal && s.interruptExternalConnections
	result := s.interruptGroup.Interrupt(interruptExternal)
	s.logger.Warn(
		"[SelectorSwitch] session_generation=", s.sessionGeneration,
		" type=", policy.switchType,
		" reason=", policy.reason,
		" old_id=", opaqueOutboundID(oldTag),
		" new_id=", opaqueOutboundID(newTag),
		" interrupt_external=", interruptExternal,
		" closed_tcp=", result.ClosedTCP,
		" closed_udp=", result.ClosedUDP,
		" closed_external=", result.ClosedExternal,
		" full_core_restart=false",
	)
}
