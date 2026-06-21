//go:build smart_active_debug

package balancer

import (
	"testing"

	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
)

func TestSmartActiveDebugFaultInjectsCriticalActiveAndHealthyCandidate(t *testing.T) {
	fault := newSmartActiveDebugFault(option.BalancerOutboundOptions{
		SmartActiveDebugForceStatus:    "CRITICAL",
		SmartActiveDebugForceCandidate: "candidate",
		SmartActiveDebugCandidateScore: 95,
	})
	history := histories(healthyHistory(90), failedHistory(urltest.ErrorTypeTimeout))
	if fault == nil || !fault.Apply("active", history) {
		t.Fatal("expected debug fault to be applied")
	}
	if state := smartActiveState(history["active"]); state != "CRITICAL" {
		t.Fatalf("active status=%s, want CRITICAL", state)
	}
	candidate := history["candidate"]
	if !candidate.Success || candidate.ErrorType != urltest.ErrorTypeNone || getHealthScore("candidate", candidate) != 95 {
		t.Fatalf("candidate was not made healthy with requested score: %+v score=%d", candidate, getHealthScore("candidate", candidate))
	}
}

func TestSmartActiveDebugFaultSupportsRequestedErrors(t *testing.T) {
	for _, errorType := range []string{
		urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeRefused,
		urltest.ErrorTypeReset, urltest.ErrorTypeEOF, urltest.ErrorTypeDNSTimeout,
		urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeQUICTimeout,
	} {
		t.Run(errorType, func(t *testing.T) {
			fault := newSmartActiveDebugFault(option.BalancerOutboundOptions{SmartActiveDebugForceError: errorType})
			history := histories(healthyHistory(90), healthyHistory(80))
			fault.Apply("active", history)
			if history["active"].Success || history["active"].ErrorType != errorType {
				t.Fatalf("error was not injected: %+v", history["active"])
			}
			if history["active"].DegradationPoints == 0 || history["active"].RuntimePenalty == 0 {
				t.Fatalf("error evidence was not injected: %+v", history["active"])
			}
		})
	}
}

func TestSmartActiveDebugForcedStatusesDriveExpectedDecisions(t *testing.T) {
	tests := []struct {
		status    string
		errorType string
		updates   int
		action    string
		active    string
		state     string
	}{
		{status: "GOOD", updates: 2, action: "keep", active: "active", state: "GOOD"},
		{status: "DEGRADED", updates: 2, action: "switch", active: "candidate", state: "DEGRADED"},
		{status: "BAD", updates: 1, action: "switch", active: "candidate", state: "BAD"},
		{status: "CRITICAL", errorType: urltest.ErrorTypeRefused, updates: 1, action: "switch", active: "candidate", state: "CRITICAL"},
	}
	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			strategy := newSmartActiveForTest()
			fault := newSmartActiveDebugFault(option.BalancerOutboundOptions{
				SmartActiveDebugForceStatus:    tt.status,
				SmartActiveDebugForceError:     tt.errorType,
				SmartActiveDebugForceCandidate: "candidate",
				SmartActiveDebugCandidateScore: 95,
			})
			for i := 0; i < tt.updates; i++ {
				history := histories(healthyHistory(90), healthyHistory(80))
				fault.Apply(strategy.Now(), history)
				strategy.UpdateOutboundsInfo(history)
			}
			requireDecision(t, strategy, tt.action, tt.active)
			if decision := strategy.LastDecision(); decision.state != tt.state {
				t.Fatalf("unexpected decision: %+v", decision)
			}
		})
	}
}

func TestSmartActiveDebugFaultDrivesEmergencySwitchWithoutNetwork(t *testing.T) {
	strategy := newSmartActiveForTest()
	fault := newSmartActiveDebugFault(option.BalancerOutboundOptions{
		SmartActiveDebugForceStatus:    "CRITICAL",
		SmartActiveDebugForceCandidate: "candidate",
		SmartActiveDebugCandidateScore: 95,
	})
	history := histories(healthyHistory(90), healthyHistory(80))
	fault.Apply(strategy.Now(), history)
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected debug fault to cause an emergency switch")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.state != "CRITICAL" {
		t.Fatalf("unexpected decision: %+v", decision)
	}

	// The fault remains pinned to the original server and must not follow the
	// newly active candidate, otherwise a static debug flag would cause churn.
	nextHistory := histories(healthyHistory(90), healthyHistory(80))
	fault.Apply(strategy.Now(), nextHistory)
	strategy.UpdateOutboundsInfo(nextHistory)
	requireDecision(t, strategy, "keep", "candidate")
	if smartActiveState(nextHistory["active"]) != "CRITICAL" || smartActiveState(nextHistory["candidate"]) != "GOOD" {
		t.Fatalf("fault moved to the new active: old=%s new=%s", smartActiveState(nextHistory["active"]), smartActiveState(nextHistory["candidate"]))
	}
}
