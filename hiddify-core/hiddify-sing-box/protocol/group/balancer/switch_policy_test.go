package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

func TestSwitchInterruptionPolicyPreservesNonEmergencySessions(t *testing.T) {
	freshTimeout := failedPolicyHistory(urltest.ErrorTypeTimeout)
	freshDNS := failedPolicyHistory(urltest.ErrorTypeDNSTimeout)
	freshRefused := failedPolicyHistory(urltest.ErrorTypeRefused)

	tests := []struct {
		name     string
		decision smartDecision
		history  *adapter.URLTestHistory
		streak   int
	}{
		{
			name:     "manual refresh better score",
			decision: smartDecision{action: "switch", reason: "user_refresh_best_fresh_candidate", mode: "user_refresh", state: "GOOD"},
		},
		{
			name:     "regular smart switch",
			decision: smartDecision{action: "switch", reason: "same_quality_significantly_lower_delay", state: "GOOD"},
		},
		{
			name:     "suspect switch",
			decision: smartDecision{action: "switch", reason: "suspect_stably_better_candidate", state: "SUSPECT"},
		},
		{
			name:     "physical network style timeout",
			decision: smartDecision{action: "switch", reason: "active_probe_confirmed_connection_failure", state: "BAD"},
			history:  freshTimeout,
			streak:   2,
		},
		{
			name:     "device DNS failure",
			decision: smartDecision{action: "switch", reason: "active_probe_confirmed_connection_failure", state: "BAD"},
			history:  freshDNS,
			streak:   2,
		},
		{
			name:     "one critical sample",
			decision: smartDecision{action: "switch", reason: "critical_active_failure", state: "CRITICAL"},
			history:  freshRefused,
			streak:   1,
		},
		{
			name:     "UDP probe quality switch",
			decision: smartDecision{action: "switch", reason: "active_probe_confirmed_quality_failure", state: "DEGRADED"},
			history:  &adapter.URLTestHistory{UDPReady: true, UDPProbeAvailable: true, UDPLoss: 100},
			streak:   2,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			policy := smartSwitchInterruptionPolicy(test.decision, test.history, test.streak)
			if policy.interruptExternal {
				t.Fatalf("external sessions would be interrupted: %+v", policy)
			}
		})
	}
}

func TestSwitchInterruptionPolicyAllowsConfirmedOutboundEmergency(t *testing.T) {
	decision := smartDecision{
		action: "switch",
		reason: "active_probe_confirmed_connection_failure",
		state:  "BAD",
		mode:   "active_probe",
	}
	policy := smartSwitchInterruptionPolicy(decision, failedPolicyHistory(urltest.ErrorTypeRefused), 2)
	if !policy.interruptExternal || policy.switchType != "confirmed_emergency" {
		t.Fatalf("confirmed emergency policy=%+v", policy)
	}
}

func TestStaleSessionGenerationIsRejected(t *testing.T) {
	t.Setenv("ZEON_SESSION_GENERATION", "42")
	if sessionGenerationMatches("41") {
		t.Fatal("stale core generation was accepted")
	}
	if !sessionGenerationMatches("42") {
		t.Fatal("current core generation was rejected")
	}
}

func TestOpaqueOutboundIDDoesNotExposeTag(t *testing.T) {
	const tag = "server.example:443"
	id := opaqueOutboundID(tag)
	if id == tag || len(id) != 12 {
		t.Fatalf("unsafe opaque id %q", id)
	}
}

func failedPolicyHistory(errorType string) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           65535,
		Success:         false,
		ErrorType:       errorType,
		URLTestStatus:   urltest.StatusFailed,
		CheckGeneration: 7,
		PingReady:       true,
		QualityReady:    true,
		CombinedReady:   true,
	}
}
