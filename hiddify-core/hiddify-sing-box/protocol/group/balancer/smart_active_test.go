package balancer

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	adapterOutbound "github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type smartActiveTestOutbound struct {
	adapterOutbound.Adapter
}

func newSmartActiveTestOutbound(tag string) adapter.Outbound {
	return &smartActiveTestOutbound{Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)}
}

func (*smartActiveTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, errors.New("test outbound does not dial")
}

func (*smartActiveTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("test outbound does not listen")
}

func newSmartActiveForTest() *SmartActive {
	return NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("active"),
		newSmartActiveTestOutbound("candidate"),
	}, option.BalancerOutboundOptions{})
}

func TestSmartActiveColdStartPrefersForeignOutbound(t *testing.T) {
	strategy := NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("🇷🇺Россия11 | СВЯЗЬ"),
		newSmartActiveTestOutbound("🇳🇱Нидерланды3 | СВЯЗЬ"),
	}, option.BalancerOutboundOptions{})
	if got := strategy.Now(); got != "🇳🇱Нидерланды3 | СВЯЗЬ" {
		t.Fatalf("cold start selected %q, want foreign outbound", got)
	}
}

func TestSmartActiveColdStartFallsBackToRussiaWhenOnlyRussiaExists(t *testing.T) {
	strategy := NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("🇷🇺Россия11 | СВЯЗЬ"),
	}, option.BalancerOutboundOptions{})
	if got := strategy.Now(); got != "🇷🇺Россия11 | СВЯЗЬ" {
		t.Fatalf("cold start selected %q, want only available outbound", got)
	}
}

func healthyHistory(delay uint16) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           delay,
		Success:         true,
		ErrorType:       urltest.ErrorTypeNone,
		StabilityPoints: 40,
	}
}

func failedHistory(errorType string) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           65535,
		Success:         false,
		ErrorType:       errorType,
		StabilityPoints: 40,
	}
}

func histories(active, candidate *adapter.URLTestHistory) map[string]*adapter.URLTestHistory {
	return map[string]*adapter.URLTestHistory{"active": active, "candidate": candidate}
}

func requireDecision(t *testing.T, strategy *SmartActive, action, active string) {
	t.Helper()
	decision := strategy.LastDecision()
	if decision.action != action || strategy.Now() != active {
		t.Fatalf("decision=%+v active=%s, want action=%s active=%s", decision, strategy.Now(), action, active)
	}
}

func TestSmartActiveStateRequiresEvidenceBeforeSwitching(t *testing.T) {
	good := healthyHistory(90)
	if state := smartActiveState(good); state != "GOOD" {
		t.Fatalf("expected GOOD, got %s", state)
	}

	suspect := *good
	suspect.DegradationPoints = 12
	if state := smartActiveState(&suspect); state != "SUSPECT" {
		t.Fatalf("expected SUSPECT, got %s", state)
	}

	degraded := *good
	degraded.RuntimePenalty = 12
	degraded.RealUserPenalty = 8
	if state := smartActiveState(&degraded); state != "DEGRADED" {
		t.Fatalf("expected DEGRADED, got %s", state)
	}

	if state := smartActiveState(failedHistory(urltest.ErrorTypeTLSHandshakeFailed)); state != "CRITICAL" {
		t.Fatalf("expected CRITICAL, got %s", state)
	}
}

func TestSmartActiveGoodKeepsSlightlyBetterCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(90)    // score 90, GOOD
	candidate := healthyHistory(80) // score 100
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if getHealthScore("active", active) != 90 || getHealthScore("candidate", candidate) != 100 {
		t.Fatalf("unexpected fixture scores: active=%d candidate=%d", getHealthScore("active", active), getHealthScore("candidate", candidate))
	}
}

func TestSmartActiveGoodDoesNotSwitchOnScoreAlone(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(250) // score 75, still GOOD without runtime or real-user errors
	candidate := healthyHistory(80)
	candidate.RuntimePenalty = 2 // score 98
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "active_good" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActivePolicyPenaltySwitchesAwayFromRussia(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(55)
	active.PolicyPenalty = urltest.RussianServerPolicyPenalty // score 55, policy-penalized SUSPECT
	candidate := healthyHistory(91)                           // score 90, foreign and healthy
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	if strategy.Now() != "active" {
		t.Fatal("policy switch must wait for confirmed candidate evidence")
	}
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected policy-preferred switch from Russian active to healthy foreign candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "suspect_stably_better_candidate" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveSuspectObservesBetterCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(90)
	active.DegradationPoints = 12
	history := histories(active, healthyHistory(80))
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "suspect_collecting_evidence" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveSingleEOFIsSuspectAndDoesNotSwitchImmediately(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := failedHistory(urltest.ErrorTypeEOF)
	active.DegradationPoints = 5
	history := histories(active, healthyHistory(80))
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.state != "SUSPECT" {
		t.Fatalf("single EOF must be observed as SUSPECT: %+v", decision)
	}
}

func TestSmartActiveDegradedSwitchesToClearlyBetterHealthyCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(90)
	active.DegradationPoints = 35
	history := histories(active, healthyHistory(80))
	strategy.UpdateOutboundsInfo(history) // first clean candidate probe is evidence only
	if strategy.Now() != "active" {
		t.Fatal("candidate switched before it had two clean probes")
	}
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected switch from DEGRADED active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.state != "DEGRADED" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveBadSwitchesWithOneConfirmedCandidateProbe(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := failedHistory(urltest.ErrorTypeReset)
	active.DegradationPoints = 55
	if !strategy.UpdateOutboundsInfo(histories(active, healthyHistory(80))) {
		t.Fatal("expected switch from BAD active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "bad_active_confirmed_candidate" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveRuntimeErrorsCurrentBadSwitchesToHealthyCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(90)
	active.RuntimePenalty = 21
	active.RealUserPenalty = 20
	active.DegradationPoints = 60
	if !strategy.UpdateOutboundsInfo(histories(active, healthyHistory(80))) {
		t.Fatal("expected switch from runtime-degraded active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "runtime_errors_current_bad" {
		t.Fatalf("unexpected runtime error switch decision: %+v", decision)
	}
}

func TestSmartActiveCriticalSwitchesWithoutExtraLiveValidationGate(t *testing.T) {
	strategy := newSmartActiveForTest()
	candidate := healthyHistory(200)
	candidate.StabilityPoints = 0 // successful URLTest is enough; no extra live-validation gate here.
	if !strategy.UpdateOutboundsInfo(histories(failedHistory(urltest.ErrorTypeTLSHandshakeFailed), candidate)) {
		t.Fatal("expected critical switch to successful candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "critical_active_failure" {
		t.Fatalf("unexpected critical decision: %+v", decision)
	}
}

func TestSmartActiveAllFailedFallsBackWithoutPanic(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := failedHistory(urltest.ErrorTypeTimeout)
	candidate := failedHistory(urltest.ErrorTypeEOF)
	candidate.Delay = 500
	if !strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("expected delay fallback to the least-bad outbound")
	}
	requireDecision(t, strategy, "fallback", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "health_unavailable_delay_fallback" {
		t.Fatalf("unexpected fallback decision: %+v", decision)
	}
}

func TestSmartActiveMissingHealthUsesLowestDelayFallback(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := map[string]*adapter.URLTestHistory{
		"active":    {Delay: 300},
		"candidate": {Delay: 100},
	}
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected lowest-delay fallback")
	}
	requireDecision(t, strategy, "fallback", "candidate")
}

func TestSmartActiveSelectAlwaysReturnsSingleActive(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(healthyHistory(90), healthyHistory(80))
	strategy.UpdateOutboundsInfo(history)
	for i := 0; i < 20; i++ {
		selected := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true)
		if selected == nil || selected.Tag() != strategy.Now() || selected.Tag() != "active" {
			t.Fatalf("selection %d returned %v while active=%s", i, selected, strategy.Now())
		}
	}
}

func TestSmartActiveCriticalEmergencySwitchesImmediately(t *testing.T) {
	for _, errorType := range []string{urltest.ErrorTypeTimeout, urltest.ErrorTypeRefused, urltest.ErrorTypeTLSHandshakeFailed} {
		t.Run(errorType, func(t *testing.T) {
			strategy := newSmartActiveForTest()
			if !strategy.UpdateOutboundsInfo(histories(failedHistory(errorType), healthyHistory(80))) {
				t.Fatal("expected emergency switch from CRITICAL active")
			}
			requireDecision(t, strategy, "switch", "candidate")
			if decision := strategy.LastDecision(); decision.state != "CRITICAL" || decision.reason != "critical_active_failure" {
				t.Fatalf("unexpected emergency decision: %+v", decision)
			}
		})
	}
}

func TestSmartActiveRecoveryNeedsMultipleCleanProbes(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(failedHistory(urltest.ErrorTypeTimeout), healthyHistory(80))
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "switch", "candidate")

	// The previous active has one successful URLTest, but remains quarantined.
	history["active"] = healthyHistory(120)
	strategy.UpdateOutboundsInfo(history)
	if recovered := strategy.LastRecoveries(); len(recovered) != 0 {
		t.Fatalf("server recovered after one clean probe: %v", recovered)
	}
	if strategy.Now() != "candidate" {
		t.Fatal("server returned to selection after one clean probe")
	}

	// The second clean result allows recovery and emits the recovery event.
	strategy.UpdateOutboundsInfo(history)
	if recovered := strategy.LastRecoveries(); len(recovered) != 1 || recovered[0] != "active" {
		t.Fatalf("expected active recovery after two clean probes, got %v", recovered)
	}
	if strategy.Now() != "candidate" {
		t.Fatal("recovered but worse server should not displace healthy active")
	}
}
