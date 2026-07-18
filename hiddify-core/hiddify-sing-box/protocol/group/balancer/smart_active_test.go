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

const smartActiveTestGeneration uint64 = 1

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
	strategy := NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("active"),
		newSmartActiveTestOutbound("candidate"),
	}, option.BalancerOutboundOptions{})
	strategy.bootstrap = false
	strategy.confirmed = true
	return strategy
}

func newSmartActiveWithTags(tags ...string) *SmartActive {
	outbounds := make([]adapter.Outbound, 0, len(tags))
	for _, tag := range tags {
		outbounds = append(outbounds, newSmartActiveTestOutbound(tag))
	}
	return NewSmartActive(outbounds, option.BalancerOutboundOptions{})
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

func TestSmartActiveColdStartUsesSingleProvisionalUntilFirstReadyCandidate(t *testing.T) {
	strategy := newSmartActiveWithTags("a", "b", "c")
	if got := strategy.Now(); got != "a" {
		t.Fatalf("initial provisional=%s, want a", got)
	}
	if strategy.confirmed {
		t.Fatal("cold start provisional must not be confirmed")
	}

	untested := map[string]*adapter.URLTestHistory{
		"a": {Delay: 300},
		"b": {Delay: 100},
		"c": {Delay: 50},
	}
	if strategy.UpdateOutboundsInfo(untested) {
		t.Fatal("provisional switched while every server was untested")
	}
	if got := strategy.Now(); got != "a" {
		t.Fatalf("provisional switched to %s", got)
	}

	untested["b"].Delay = 30
	untested["c"].Delay = 20
	if strategy.UpdateOutboundsInfo(untested) {
		t.Fatal("provisional switched between untested servers")
	}
	if got := strategy.Now(); got != "a" {
		t.Fatalf("provisional switched to %s", got)
	}

	ready := map[string]*adapter.URLTestHistory{
		"a": currentGenerationCheckingHistory(11),
		"b": currentGenerationHealthyHistory(11, 90),
		"c": currentGenerationCheckingHistory(11),
	}
	if !strategy.UpdateOutboundsInfo(ready) {
		t.Fatal("first current-generation ready server did not become confirmed active")
	}
	requireDecision(t, strategy, "switch", "b")
	if !strategy.confirmed {
		t.Fatal("first ready server must confirm active")
	}
}

func TestSmartActiveStaleGenerationDoesNotConfirmAfterRestart(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	old := histories(staleGenerationHistory(99, 40), nil)
	if strategy.UpdateOutboundsInfo(old) {
		t.Fatal("stale previous-run history changed provisional active")
	}
	requireDecision(t, strategy, "keep", "active")
	if strategy.confirmed {
		t.Fatal("stale previous-run history confirmed active")
	}

	current := histories(staleGenerationHistory(99, 40), currentGenerationHealthyHistory(1, 120))
	if !strategy.UpdateOutboundsInfo(current) {
		t.Fatal("current generation candidate did not replace stale previous active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if !strategy.confirmed {
		t.Fatal("current generation candidate should confirm active")
	}
}

func TestSmartActivePartialPingDoesNotBeatCombinedReady(t *testing.T) {
	strategy := newSmartActiveWithTags("a", "b")
	history := map[string]*adapter.URLTestHistory{
		"a": partialPingHistory(3, 30),
		"b": currentGenerationHealthyHistory(3, 120),
	}
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("combined-ready server should become first confirmed active")
	}
	requireDecision(t, strategy, "switch", "b")
}

func TestSmartActiveOptionalSpeedAndUDPDisabledDoNotBlockConfirmed(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	candidate := currentGenerationHealthyHistory(7, 90)
	candidate.SpeedReady = false
	candidate.UDPReady = false
	candidate.UDPProbeAvailable = false
	candidate.CombinedReady = true

	if !strategy.UpdateOutboundsInfo(histories(nil, candidate)) {
		t.Fatal("combined-ready candidate should confirm even when optional speed/udp flags are false")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if !strategy.confirmed {
		t.Fatal("combined-ready candidate should become confirmed active")
	}
}

func TestSmartActiveDelayedSpeedWaitsOnlyUntilCombinedReady(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	candidate := currentGenerationHealthyHistory(8, 90)
	candidate.SpeedReady = false
	candidate.CombinedReady = false

	if strategy.UpdateOutboundsInfo(histories(nil, candidate)) {
		t.Fatal("candidate should wait while combined readiness is incomplete")
	}
	requireDecision(t, strategy, "keep", "active")
	if strategy.confirmed {
		t.Fatal("candidate confirmed before combined readiness")
	}

	candidate.SpeedReady = true
	candidate.CombinedReady = true
	if !strategy.UpdateOutboundsInfo(histories(nil, candidate)) {
		t.Fatal("candidate should confirm once combined readiness is complete")
	}
	requireDecision(t, strategy, "switch", "candidate")
}

func healthyHistory(delay uint16) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           delay,
		Success:         true,
		ErrorType:       urltest.ErrorTypeNone,
		URLTestStatus:   urltest.StatusSuccess,
		StabilityPoints: 40,
		CheckGeneration: smartActiveTestGeneration,
		PingReady:       true,
		QualityReady:    true,
		SpeedReady:      true,
		CombinedReady:   true,
	}
}

func currentGenerationHealthyHistory(generation uint64, delay uint16) *adapter.URLTestHistory {
	history := healthyHistory(delay)
	history.CheckGeneration = generation
	history.PingReady = true
	history.QualityReady = true
	history.SpeedReady = true
	history.CombinedReady = true
	history.URLTestStatus = urltest.StatusSuccess
	return history
}

func currentGenerationCheckingHistory(generation uint64) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		URLTestStatus:   urltest.StatusChecking,
		CheckGeneration: generation,
		StabilityPoints: 40,
	}
}

func failedHistory(errorType string) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           65535,
		Success:         false,
		ErrorType:       errorType,
		URLTestStatus:   urltest.StatusFailed,
		StabilityPoints: 40,
		CheckGeneration: smartActiveTestGeneration,
		PingReady:       true,
		QualityReady:    true,
		SpeedReady:      true,
		CombinedReady:   true,
	}
}

func histories(active, candidate *adapter.URLTestHistory) map[string]*adapter.URLTestHistory {
	return map[string]*adapter.URLTestHistory{"active": active, "candidate": candidate}
}

func staleGenerationHistory(generation uint64, delay uint16) *adapter.URLTestHistory {
	history := currentGenerationHealthyHistory(generation, delay)
	history.Time = time.Now().Add(-time.Hour)
	return history
}

func partialPingHistory(generation uint64, delay uint16) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           delay,
		Success:         true,
		ErrorType:       urltest.ErrorTypeNone,
		URLTestStatus:   urltest.StatusChecking,
		StabilityPoints: 40,
		CheckGeneration: generation,
		PingReady:       true,
	}
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
	if decision := strategy.LastDecision(); decision.reason != "candidate_runtime_or_udp_penalized" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveGoodSwitchesSameQualitySignificantlyLowerDelay(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(300)
	candidate := healthyHistory(100)
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	if strategy.Now() != "active" {
		t.Fatal("candidate switched before two clean probes")
	}
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected switch from 300 ms active to fresh 100 ms candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "same_quality_significantly_lower_delay" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveKeepsCurrentWhileGenerationIsChecking(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := currentGenerationCheckingHistory(12)
	candidate := currentGenerationHealthyHistory(12, 80)
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "current_temporarily_kept_during_refresh" {
		t.Fatalf("unexpected decision during refresh: %+v", decision)
	}
}

func TestSmartActiveDoesNotRankCheckingCandidateWithOldScore(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := currentGenerationHealthyHistory(12, 180)
	candidate := currentGenerationCheckingHistory(12)
	candidate.Delay = 40
	candidate.HealthScore = 100
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if strategy.Now() != "active" {
		t.Fatal("checking candidate with stale score became active")
	}
}

func TestSmartActiveLateOldGenerationResultDoesNotSwitch(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := currentGenerationHealthyHistory(2, 220)
	candidate := currentGenerationHealthyHistory(1, 40)
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if strategy.Now() != "active" {
		t.Fatal("late old-generation candidate became active")
	}
}

func TestSmartActiveGoodKeepsCurrentWhenRealUserHealthIsBetter(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(300)
	active.StabilityPoints = 90
	candidate := healthyHistory(100)
	candidate.RealUserPenalty = 12
	candidate.DegradationPoints = 12
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "current_real_traffic_stable_and_candidate_advantage_insufficient" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveGoodDoesNotUseStaleBetterCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(180)
	candidate := healthyHistory(50)
	candidate.IsFromCache = true
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "active_good_no_better_candidate" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveFailedCandidateDoesNotWin(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(180)
	candidate := failedHistory(urltest.ErrorTypeTimeout)
	candidate.Delay = 50
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
}

func TestSmartActiveConfirmedActiveRejectsUntestedCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(300)
	candidate := &adapter.URLTestHistory{Delay: 40}
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if strategy.Now() != "active" {
		t.Fatal("untested candidate became active after confirmed active existed")
	}
}

func TestSmartActiveStartupReevaluatesFreshBestCandidate(t *testing.T) {
	strategy := NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("active"),
		newSmartActiveTestOutbound("candidate"),
	}, option.BalancerOutboundOptions{})
	active := healthyHistory(250)
	active.IsFromCache = true
	candidate := healthyHistory(80)
	if !strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("expected startup fresh candidate to replace cached fallback active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.mode != "vpn_start" || decision.reason != "first_confirmed_current_generation_candidate" {
		t.Fatalf("unexpected startup decision: %+v", decision)
	}
}

func TestSmartActiveManualRefreshSwitchesFromGoodToFreshBetterCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(250)
	candidate := healthyHistory(80)
	if !strategy.UpdateOutboundsInfoForManualRefresh(histories(active, candidate)) {
		t.Fatal("expected user refresh to switch to fresh better candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.mode != "user_refresh" || decision.reason != "user_refresh_best_fresh_candidate" {
		t.Fatalf("unexpected manual refresh decision: %+v", decision)
	}
}

func TestSmartActiveManualRefreshSwitchesToRankOneFreshCandidateWithEqualScore(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(76)
	candidate := healthyHistory(52)
	if getHealthScore("active", active) != getHealthScore("candidate", candidate) {
		t.Fatalf("fixture must have equal scores: active=%d candidate=%d", getHealthScore("active", active), getHealthScore("candidate", candidate))
	}
	if !strategy.UpdateOutboundsInfoForManualRefresh(histories(active, candidate)) {
		t.Fatal("expected user refresh to switch to the best fresh candidate when delay delta is meaningful")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.mode != "user_refresh" || decision.reason != "user_refresh_best_fresh_candidate" {
		t.Fatalf("unexpected manual refresh decision: %+v", decision)
	}
}

func TestSmartActiveManualRefreshKeepsCurrentOnMinimalEqualScoreDelta(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(56)
	candidate := healthyHistory(52)
	if strategy.UpdateOutboundsInfoForManualRefresh(histories(active, candidate)) {
		t.Fatal("did not expect user refresh to switch for a minimal equal-score delay delta")
	}
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.mode != "user_refresh" || decision.reason != "user_refresh_candidate_tie_minimal_delta" {
		t.Fatalf("unexpected manual refresh decision: %+v", decision)
	}
}

func TestSmartActiveManualRefreshKeepsCurrentWhenRankOneCandidatePenalized(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(250)
	candidate := healthyHistory(52)
	candidate.RuntimePenalty = 2
	if getHealthScore("candidate", candidate) <= getHealthScore("active", active) {
		t.Fatalf("fixture candidate must still rank above current: active=%d candidate=%d", getHealthScore("active", active), getHealthScore("candidate", candidate))
	}
	if strategy.UpdateOutboundsInfoForManualRefresh(histories(active, candidate)) {
		t.Fatal("did not expect user refresh to switch to a penalized rank-one candidate while current is healthy")
	}
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.mode != "user_refresh" || decision.reason != "user_refresh_candidate_penalized" {
		t.Fatalf("unexpected manual refresh decision: %+v", decision)
	}
}

func TestSmartActiveManualRefreshRejectsCachedOrUntestedCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(250)
	cached := healthyHistory(60)
	cached.IsFromCache = true
	if strategy.UpdateOutboundsInfoForManualRefresh(histories(active, cached)) {
		t.Fatal("did not expect user refresh to switch to cached candidate")
	}
	requireDecision(t, strategy, "keep", "active")

	untested := &adapter.URLTestHistory{Delay: 40}
	if strategy.UpdateOutboundsInfoForManualRefresh(histories(active, untested)) {
		t.Fatal("did not expect user refresh to switch to untested candidate")
	}
	requireDecision(t, strategy, "keep", "active")
}

func TestSmartActiveManualRefreshKeepsCurrentWhenStillBest(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(80)
	candidate := healthyHistory(250)
	if strategy.UpdateOutboundsInfoForManualRefresh(histories(active, candidate)) {
		t.Fatal("did not expect user refresh to leave the best active server")
	}
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.mode != "user_refresh" || decision.reason != "user_refresh_current_is_rank1" {
		t.Fatalf("unexpected manual refresh decision: %+v", decision)
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
	if strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("did not expect switch to another failed outbound")
	}
	requireDecision(t, strategy, "fallback", "active")
	if decision := strategy.LastDecision(); decision.reason != "critical_without_healthy_candidate" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveMissingHealthKeepsSingleProvisional(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.confirmed = false
	history := map[string]*adapter.URLTestHistory{
		"active":    {Delay: 300},
		"candidate": {Delay: 100},
	}
	if strategy.UpdateOutboundsInfo(history) {
		t.Fatal("did not expect provisional to switch on missing health")
	}
	requireDecision(t, strategy, "keep", "active")
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
		udpSelected := strategy.Select(adapter.InboundContext{}, N.NetworkUDP, true)
		if udpSelected == nil || udpSelected.Tag() != strategy.Now() || udpSelected.Tag() != "active" {
			t.Fatalf("udp selection %d returned %v while active=%s", i, udpSelected, strategy.Now())
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

func TestSmartActiveAvoidsRecentlySwitchedServer(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(failedHistory(urltest.ErrorTypeTimeout), healthyHistory(100))
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected switch away from failed active")
	}
	requireDecision(t, strategy, "switch", "candidate")

	history["active"] = healthyHistory(70)
	history["candidate"] = healthyHistory(100)
	strategy.UpdateOutboundsInfo(history)
	if strategy.Now() != "candidate" {
		t.Fatal("recently failed server returned before clean recovery evidence")
	}
}
