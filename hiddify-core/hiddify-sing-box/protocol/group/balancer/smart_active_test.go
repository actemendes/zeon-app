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
	strategy.active = strategy.outbounds[0]
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

func TestSmartActiveColdStartHasNoUnverifiedActive(t *testing.T) {
	strategy := newSmartActiveWithTags("first", "second")
	if got := strategy.Now(); got != "" {
		t.Fatalf("cold start selected unverified outbound %q", got)
	}
	if selected := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true); selected != nil {
		t.Fatalf("cold start returned unverified outbound %q", selected.Tag())
	}
	requireDecision(t, strategy, "wait", "")
}

func TestSmartActiveColdStartProgressivelyImprovesWithinFullGeneration(t *testing.T) {
	strategy := newSmartActiveWithTags("a", "b", "c")
	if got := strategy.Now(); got != "" {
		t.Fatalf("initial active=%s, want no selection", got)
	}
	if strategy.confirmed {
		t.Fatal("cold start must not be confirmed")
	}

	untested := map[string]*adapter.URLTestHistory{
		"a": {Delay: 300},
		"b": {Delay: 100},
		"c": {Delay: 50},
	}
	if strategy.UpdateOutboundsInfo(untested) {
		t.Fatal("selected an active server while every server was untested")
	}
	requireDecision(t, strategy, "wait", "")

	untested["b"].Delay = 30
	untested["c"].Delay = 20
	if strategy.UpdateOutboundsInfo(untested) {
		t.Fatal("selected an active server based on unverified delays")
	}
	requireDecision(t, strategy, "wait", "")

	ready := map[string]*adapter.URLTestHistory{
		"a": currentGenerationCheckingHistory(11),
		"b": currentGenerationHealthyHistory(11, 190),
		"c": currentGenerationCheckingHistory(11),
	}
	if strategy.UpdateOutboundsInfo(ready) {
		t.Fatal("ordinary in-progress snapshot selected a server before its batch completed")
	}
	requireDecision(t, strategy, "wait", "")
	if !strategy.UpdateOutboundsInfoForCompletedBatch(ready, 11) {
		t.Fatal("first completed batch did not establish a verified active server")
	}
	requireDecision(t, strategy, "confirm", "b")
	if !strategy.confirmed || !strategy.bootstrap {
		t.Fatal("first completed server must be confirmed while startup remains progressive")
	}

	ready["a"] = currentGenerationHealthyHistory(11, 180)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(ready, 11) {
		t.Fatal("better result from the same startup generation did not improve the active server")
	}
	requireDecision(t, strategy, "switch", "a")
	if !strategy.bootstrap {
		t.Fatal("startup stopped being progressive before the generation settled")
	}

	ready["c"] = currentGenerationHealthyHistory(11, 60)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(ready, 11) {
		t.Fatal("final better result did not become active")
	}
	requireDecision(t, strategy, "switch", "c")
	if !strategy.confirmed || strategy.bootstrap {
		t.Fatal("settled generation must leave the final best server confirmed")
	}
}

func TestSmartActiveColdStartTieDoesNotDependOnListOrder(t *testing.T) {
	for _, tags := range [][]string{{"bravo", "alpha"}, {"alpha", "bravo"}} {
		strategy := newSmartActiveWithTags(tags...)
		history := map[string]*adapter.URLTestHistory{
			"alpha": currentGenerationHealthyHistory(12, 80),
			"bravo": currentGenerationHealthyHistory(12, 80),
		}
		if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 12) {
			t.Fatalf("order %v did not establish an active server", tags)
		}
		requireDecision(t, strategy, "confirm", "alpha")
	}
}

func TestSmartActiveColdStartAllFailedKeepsNoActive(t *testing.T) {
	strategy := newSmartActiveWithTags("first", "second")
	history := map[string]*adapter.URLTestHistory{
		"first":  currentGenerationFailedHistory(13, urltest.ErrorTypeTimeout),
		"second": currentGenerationFailedHistory(13, urltest.ErrorTypeRefused),
	}
	if strategy.UpdateOutboundsInfoForCompletedBatch(history, 13) {
		t.Fatal("failed startup batch established an active server")
	}
	requireDecision(t, strategy, "wait", "")
	if selected := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true); selected != nil {
		t.Fatalf("failed startup batch returned outbound %q", selected.Tag())
	}
}

func TestSmartActiveColdStartIgnoresStandalonePartialGeneration(t *testing.T) {
	strategy := newSmartActiveWithTags("a", "b", "c")
	history := map[string]*adapter.URLTestHistory{
		"a": currentGenerationHealthyHistory(2, 30),
		"b": currentGenerationHealthyHistory(1, 60),
		"c": currentGenerationHealthyHistory(1, 70),
	}

	if strategy.UpdateOutboundsInfoForCompletedBatch(history, 2) {
		t.Fatal("one-server partial generation changed the cold-start route")
	}
	requireDecision(t, strategy, "wait", "")
	if strategy.confirmed {
		t.Fatal("standalone partial generation must not confirm the group")
	}
}

func TestSmartActiveFirstListedResultDoesNotPinStartupSelection(t *testing.T) {
	strategy := newSmartActiveWithTags("poland", "netherlands", "latvia")
	history := map[string]*adapter.URLTestHistory{
		"poland":      currentGenerationHealthyHistory(9, 116),
		"netherlands": currentGenerationCheckingHistory(9),
		"latvia":      currentGenerationCheckingHistory(9),
	}

	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 9) {
		t.Fatal("completed result did not establish the first verified active server")
	}
	requireDecision(t, strategy, "confirm", "poland")
	if !strategy.confirmed || !strategy.bootstrap {
		t.Fatal("first listed result must be usable without ending progressive startup")
	}

	history["netherlands"] = currentGenerationHealthyHistory(9, 51)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 9) {
		t.Fatal("later faster server did not replace the first completed server")
	}
	requireDecision(t, strategy, "switch", "netherlands")

	history["latvia"] = currentGenerationHealthyHistory(9, 58)
	if strategy.UpdateOutboundsInfoForCompletedBatch(history, 9) {
		t.Fatal("slower final result replaced the best-so-far server")
	}
	requireDecision(t, strategy, "keep", "netherlands")
	if strategy.bootstrap {
		t.Fatal("startup remained open after every server reached a final state")
	}
}

func TestSmartActivePartialProbeDoesNotDisplaceRunningStartupCohort(t *testing.T) {
	strategy := newSmartActiveWithTags("poland", "netherlands", "latvia")
	history := map[string]*adapter.URLTestHistory{
		"poland":      currentGenerationHealthyHistory(9, 116),
		"netherlands": currentGenerationCheckingHistory(9),
		"latvia":      currentGenerationCheckingHistory(9),
	}
	strategy.UpdateOutboundsInfoForCompletedBatch(history, 9)
	if strategy.selectionGeneration != 9 {
		t.Fatalf("startup cohort=%d, want 9", strategy.selectionGeneration)
	}

	// A standalone ping supersedes only Poland. The remaining results still
	// belong to the running full cohort and must be allowed to improve it.
	history["poland"] = currentGenerationHealthyHistory(10, 110)
	history["netherlands"] = currentGenerationHealthyHistory(9, 51)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 9) {
		t.Fatal("partial probe prevented a better full-cohort result from switching")
	}
	requireDecision(t, strategy, "switch", "netherlands")
	if strategy.selectionGeneration != 9 {
		t.Fatalf("partial probe displaced startup cohort with generation %d", strategy.selectionGeneration)
	}

	history["latvia"] = currentGenerationHealthyHistory(9, 58)
	strategy.UpdateOutboundsInfoForCompletedBatch(history, 9)
	requireDecision(t, strategy, "keep", "netherlands")
	if strategy.bootstrap {
		t.Fatal("newer terminal partial result left the full startup cohort permanently open")
	}
}

func TestSmartActiveStaleGenerationDoesNotConfirmAfterRestart(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	old := histories(staleGenerationHistory(99, 40), nil)
	if strategy.UpdateOutboundsInfo(old) {
		t.Fatal("stale previous-run history established an active server")
	}
	requireDecision(t, strategy, "wait", "")
	if strategy.confirmed {
		t.Fatal("stale previous-run history confirmed active")
	}

	current := histories(currentGenerationFailedHistory(1, urltest.ErrorTypeTimeout), currentGenerationHealthyHistory(1, 120))
	if !strategy.UpdateOutboundsInfo(current) {
		t.Fatal("current generation candidate did not establish an active server")
	}
	requireDecision(t, strategy, "confirm", "candidate")
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
	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 3) {
		t.Fatal("completed server in a full in-progress generation was not selected")
	}
	requireDecision(t, strategy, "confirm", "b")
	if !strategy.bootstrap {
		t.Fatal("incomplete full generation must remain in progressive startup mode")
	}
	history["a"] = currentGenerationFailedHistory(3, urltest.ErrorTypeTimeout)
	strategy.UpdateOutboundsInfoForCompletedBatch(history, 3)
	requireDecision(t, strategy, "keep", "b")
	if strategy.bootstrap {
		t.Fatal("settled full generation did not finish startup")
	}
}

func TestSmartActiveOptionalSpeedAndUDPDisabledDoNotBlockConfirmed(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	candidate := currentGenerationHealthyHistory(7, 90)
	candidate.SpeedReady = false
	candidate.UDPReady = false
	candidate.UDPProbeAvailable = false
	candidate.CombinedReady = true

	if !strategy.UpdateOutboundsInfo(histories(currentGenerationFailedHistory(7, urltest.ErrorTypeTimeout), candidate)) {
		t.Fatal("combined-ready candidate should confirm even when optional speed/udp flags are false")
	}
	requireDecision(t, strategy, "confirm", "candidate")
	if !strategy.confirmed {
		t.Fatal("combined-ready candidate should become confirmed active")
	}
}

func TestSmartActiveDelayedSpeedWaitsOnlyUntilCombinedReady(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate")
	candidate := currentGenerationHealthyHistory(8, 90)
	candidate.SpeedReady = false
	candidate.CombinedReady = false

	active := currentGenerationCheckingHistory(8)
	if strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("candidate should wait while combined readiness is incomplete")
	}
	requireDecision(t, strategy, "wait", "")
	if strategy.confirmed {
		t.Fatal("candidate confirmed before combined readiness")
	}

	candidate.SpeedReady = true
	candidate.CombinedReady = true
	active = currentGenerationFailedHistory(8, urltest.ErrorTypeTimeout)
	if !strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("candidate should confirm once combined readiness is complete")
	}
	requireDecision(t, strategy, "confirm", "candidate")
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

func currentGenerationFailedHistory(generation uint64, errorType string) *adapter.URLTestHistory {
	history := failedHistory(errorType)
	history.CheckGeneration = generation
	return history
}

func histories(active, candidate *adapter.URLTestHistory) map[string]*adapter.URLTestHistory {
	return map[string]*adapter.URLTestHistory{"active": active, "candidate": candidate}
}

func advanceCompletedProbe(history map[string]*adapter.URLTestHistory) {
	for _, item := range history {
		if item == nil || item.CheckGeneration == 0 {
			continue
		}
		item.CheckGeneration++
		item.Time = time.Now()
	}
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
	advanceCompletedProbe(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if getHealthScore("active", active) != 90 || getHealthScore("candidate", candidate) != 100 {
		t.Fatalf("unexpected fixture scores: active=%d candidate=%d", getHealthScore("active", active), getHealthScore("candidate", candidate))
	}
}

func TestSmartActiveGoodAllowsMinorCandidatePenaltyForLargeDelayGain(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(250) // score 75, still GOOD without runtime or real-user errors
	candidate := healthyHistory(80)
	candidate.RuntimePenalty = 2 // score 98
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	advanceCompletedProbe(history)
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("a tiny candidate penalty blocked a substantially faster GOOD server")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "same_quality_significantly_lower_delay" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveGoodDoesNotSwitchToWorsePolicyCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := healthyHistory(400)
	candidate := healthyHistory(50)
	candidate.PolicyPenalty = urltest.RussianServerPolicyPenalty
	if state := smartActiveState(active); state != "GOOD" {
		t.Fatalf("fixture active state=%s, want GOOD", state)
	}
	if state := smartActiveState(candidate); state != "SUSPECT" {
		t.Fatalf("fixture candidate state=%s, want SUSPECT", state)
	}
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	advanceCompletedProbe(history)
	if strategy.UpdateOutboundsInfo(history) || strategy.Now() != "active" {
		t.Fatalf("worse-policy candidate displaced healthy active: decision=%+v active=%s", strategy.LastDecision(), strategy.Now())
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
	advanceCompletedProbe(history)
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("expected switch from 300 ms active to fresh 100 ms candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "same_quality_significantly_lower_delay" {
		t.Fatalf("unexpected decision: %+v", decision)
	}
}

func TestSmartActiveSameGenerationTargetedSuccessCannotReplaceFullRanking(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.selectionGeneration = smartActiveTestGeneration
	full := histories(
		currentGenerationHealthyHistory(smartActiveTestGeneration, 250),
		currentGenerationHealthyHistory(smartActiveTestGeneration, 300),
	)
	strategy.evidence["candidate"] = &smartEvidence{
		successStreak:       2,
		lastProbeGeneration: smartActiveTestGeneration,
		lastProbeTime:       full["candidate"].Time,
		hasCompletedProbe:   true,
	}
	strategy.rememberFullGeneration(full, smartActiveTestGeneration)

	targeted := histories(
		cloneSmartActiveHistory(full["active"]),
		cloneSmartActiveHistory(full["candidate"]),
	)
	targeted["candidate"].Delay = 50
	targeted["candidate"].Time = full["candidate"].Time.Add(time.Second)
	if strategy.UpdateOutboundsInfo(targeted) || strategy.Now() != "active" {
		t.Fatalf("targeted same-generation success replaced full ranking: decision=%+v active=%s", strategy.LastDecision(), strategy.Now())
	}
	if got := strategy.lastFullHistory["candidate"].Delay; got != 300 {
		t.Fatalf("saved full delay=%d, want 300", got)
	}
}

func TestSmartActiveKeepsCurrentWhileGenerationIsChecking(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := currentGenerationCheckingHistory(12)
	candidate := currentGenerationHealthyHistory(12, 80)
	history := histories(active, candidate)
	strategy.UpdateOutboundsInfo(history)
	advanceCompletedProbe(history)
	strategy.UpdateOutboundsInfo(history)
	requireDecision(t, strategy, "keep", "active")
	if decision := strategy.LastDecision(); decision.reason != "current_generation_incomplete" {
		t.Fatalf("unexpected decision during refresh: %+v", decision)
	}
}

func TestSmartActiveConfirmedWaitsForWholeGenerationBeforeReselect(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate", "pending")
	strategy.active = strategy.outbounds[0]
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.evidence["candidate"] = &smartEvidence{successStreak: 2}
	history := map[string]*adapter.URLTestHistory{
		"active":    currentGenerationHealthyHistory(15, 300),
		"candidate": currentGenerationHealthyHistory(15, 80),
		"pending":   currentGenerationCheckingHistory(15),
	}

	if strategy.UpdateOutboundsInfo(history) {
		t.Fatal("partial generation triggered reselect before every result completed")
	}
	requireDecision(t, strategy, "keep", "active")
	history["pending"] = currentGenerationFailedHistory(15, urltest.ErrorTypeTimeout)
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("settled generation did not apply its better candidate")
	}
	requireDecision(t, strategy, "switch", "candidate")
}

func TestSmartActiveConfirmedReselectsAfterCompletedBatch(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate", "pending")
	strategy.active = strategy.outbounds[0]
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.evidence["candidate"] = &smartEvidence{successStreak: 2}
	history := map[string]*adapter.URLTestHistory{
		"active":    currentGenerationHealthyHistory(16, 300),
		"candidate": currentGenerationHealthyHistory(16, 80),
		"pending":   currentGenerationCheckingHistory(16),
	}

	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 16) {
		t.Fatal("completed batch did not apply its better candidate while later batch was pending")
	}
	requireDecision(t, strategy, "switch", "candidate")
}

func TestSmartActiveCompletedBatchesProgressOnlyToBetterServer(t *testing.T) {
	strategy := newSmartActiveWithTags("first", "second", "third")
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.active = strategy.outbounds[0]
	strategy.evidence["first"] = &smartEvidence{successStreak: 2}
	strategy.evidence["second"] = &smartEvidence{successStreak: 2}
	strategy.evidence["third"] = &smartEvidence{successStreak: 2}
	history := map[string]*adapter.URLTestHistory{
		"first":  currentGenerationHealthyHistory(21, 150),
		"second": currentGenerationHealthyHistory(21, 100),
		"third":  currentGenerationCheckingHistory(21),
	}

	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 21) {
		t.Fatal("first completed batch did not choose its best server")
	}
	requireDecision(t, strategy, "switch", "second")

	history["third"] = currentGenerationHealthyHistory(21, 50)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 21) {
		t.Fatal("later batch did not replace incumbent with a better server")
	}
	requireDecision(t, strategy, "switch", "third")

	history["first"] = currentGenerationHealthyHistory(21, 200)
	if strategy.UpdateOutboundsInfoForCompletedBatch(history, 21) {
		t.Fatal("later slower result replaced the best-so-far server")
	}
	requireDecision(t, strategy, "keep", "third")
}

func TestSmartActiveCompletedBatchPrefersMuchLowerDelayWithinComparableQuality(t *testing.T) {
	strategy := newSmartActiveWithTags("poland", "netherlands", "pending")
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.active = strategy.outbounds[0]
	strategy.evidence["poland"] = &smartEvidence{successStreak: 2}
	strategy.evidence["netherlands"] = &smartEvidence{successStreak: 2}

	poland := currentGenerationHealthyHistory(22, 189)
	netherlands := currentGenerationHealthyHistory(22, 83)
	// Reproduce a small quality disadvantage from historical volatility. The
	// old exact-score ordering kept Poland (score 75) even at 189 ms because
	// Netherlands scored one point less despite its 83 ms fresh probe.
	netherlands.VolatilityPenalty = 16
	if got, want := getHealthScore("poland", poland), 75; got != want {
		t.Fatalf("poland score=%d, want %d", got, want)
	}
	if got, want := getHealthScore("netherlands", netherlands), 74; got != want {
		t.Fatalf("netherlands score=%d, want %d", got, want)
	}
	history := map[string]*adapter.URLTestHistory{
		"poland":      poland,
		"netherlands": netherlands,
		"pending":     currentGenerationCheckingHistory(22),
	}

	if !strategy.UpdateOutboundsInfoForCompletedBatch(history, 22) {
		t.Fatal("completed batch kept a dramatically slower server for a one-point quality difference")
	}
	requireDecision(t, strategy, "switch", "netherlands")
}

func TestSmartActiveCompletedBatchKeepsHigherQualityForMinimalDelayDelta(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "candidate", "pending")
	strategy.active = strategy.outbounds[0]
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.evidence["active"] = &smartEvidence{successStreak: 2}
	strategy.evidence["candidate"] = &smartEvidence{successStreak: 2}

	active := currentGenerationHealthyHistory(23, 189)
	candidate := currentGenerationHealthyHistory(23, 180)
	candidate.VolatilityPenalty = 1
	history := map[string]*adapter.URLTestHistory{
		"active":    active,
		"candidate": candidate,
		"pending":   currentGenerationCheckingHistory(23),
	}

	if strategy.UpdateOutboundsInfoForCompletedBatch(history, 23) {
		t.Fatal("minimal delay improvement displaced the higher-quality active server")
	}
	requireDecision(t, strategy, "keep", "active")
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

func TestSmartActivePartialNewGenerationRejectsOlderReadyCandidates(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := failedHistory(urltest.ErrorTypeTimeout)
	active.CheckGeneration = 2
	candidate := currentGenerationHealthyHistory(1, 40)
	history := histories(active, candidate)

	if generation := strategy.currentGeneration(history); generation != 2 {
		t.Fatalf("selected generation=%d, want newest generation=2", generation)
	}
	if strategy.UpdateOutboundsInfo(history) {
		t.Fatal("older-generation candidate replaced a newer failed active")
	}
	requireDecision(t, strategy, "keep", "active")
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
	advanceCompletedProbe(history)
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
	if decision := strategy.LastDecision(); decision.reason != "current_generation_incomplete" {
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
	candidate := healthyHistory(80)
	if !strategy.UpdateOutboundsInfo(histories(active, candidate)) {
		t.Fatal("expected startup to establish the best fresh candidate")
	}
	requireDecision(t, strategy, "confirm", "candidate")
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
	advanceCompletedProbe(history)
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

func TestSmartActiveCompletedEOFFailureSwitchesToFreshCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	active := failedHistory(urltest.ErrorTypeEOF)
	active.DegradationPoints = 5
	history := histories(active, healthyHistory(80))
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("completed EOF result kept an ineligible active")
	}
	requireDecision(t, strategy, "switch", "candidate")
	if decision := strategy.LastDecision(); decision.reason != "current_terminal_result_ineligible" {
		t.Fatalf("unexpected terminal failure decision: %+v", decision)
	}
}

func TestSmartActiveOld50FailureCurrentGenerationSwitchesToFresh120(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	const oldGeneration = uint64(40)
	old := histories(
		currentGenerationHealthyHistory(oldGeneration, 50),
		currentGenerationHealthyHistory(oldGeneration, 240),
	)
	old["active"].HealthScore = 100
	if !strategy.rememberFullGeneration(old, oldGeneration) {
		t.Fatal("old coherent generation was not stored")
	}
	strategy.selectionGeneration = oldGeneration

	const newGeneration = oldGeneration + 1
	current := histories(
		currentGenerationFailedHistory(newGeneration, urltest.ErrorTypeEOF),
		currentGenerationHealthyHistory(newGeneration, 120),
	)
	current["active"].HealthScore = 0
	current["candidate"].HealthScore = 95
	if !strategy.UpdateOutboundsInfoForCompletedBatch(current, newGeneration) {
		t.Fatalf("fresh successful candidate did not replace failed active: %+v", strategy.LastDecision())
	}
	requireDecision(t, strategy, "switch", "candidate")
}

func TestSmartActiveComparesCurrent300ToCurrent120(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	old := histories(
		currentGenerationHealthyHistory(50, 50),
		currentGenerationHealthyHistory(50, 260),
	)
	strategy.UpdateOutboundsInfo(old)
	requireDecision(t, strategy, "keep", "active")

	current := histories(
		currentGenerationHealthyHistory(51, 300),
		currentGenerationHealthyHistory(51, 120),
	)
	current["active"].HealthScore = 70
	current["candidate"].HealthScore = 95
	if !strategy.UpdateOutboundsInfoForCompletedBatch(current, 51) {
		t.Fatalf("current 300ms active was compared using its old 50ms result: %+v", strategy.LastDecision())
	}
	requireDecision(t, strategy, "switch", "candidate")
	generation, decisionHistory, source := strategy.SelectionDiagnostics()
	if generation != 51 || source != "full_generation" ||
		decisionHistory["active"].Delay != 300 || decisionHistory["candidate"].Delay != 120 {
		t.Fatalf("selection used incoherent data: generation=%d source=%s history=%+v", generation, source, decisionHistory)
	}
}

func TestSmartActiveFailureOverlayReplacesWholeSuccessfulSnapshot(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	const generation = uint64(60)
	full := histories(
		currentGenerationHealthyHistory(generation, 50),
		currentGenerationHealthyHistory(generation, 120),
	)
	full["active"].HealthScore = 100
	strategy.selectionGeneration = generation
	if !strategy.rememberFullGeneration(full, generation) {
		t.Fatal("full snapshot was not stored")
	}

	failedAt := full["active"].Time.Add(time.Second)
	latest := cloneSmartActiveHistoryMap(full)
	latest["active"] = currentGenerationFailedHistory(generation, urltest.ErrorTypeReset)
	latest["active"].Time = failedAt
	latest["active"].HealthScore = 0
	strategy.UpdateOutboundsInfo(latest)

	saved := strategy.lastFullHistory["active"]
	if saved.Success || saved.Delay != 65535 || saved.HealthScore != 0 ||
		saved.URLTestStatus != urltest.StatusFailed || !saved.Time.Equal(failedAt) ||
		saved.CheckGeneration != generation || !saved.CombinedReady {
		t.Fatalf("failure was layered over stale successful fields: %+v", saved)
	}
}

func TestSmartActivePendingNewGenerationDoesNotRestoreOldSuccess(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	const fullGeneration = uint64(70)
	full := histories(
		currentGenerationHealthyHistory(fullGeneration, 50),
		currentGenerationHealthyHistory(fullGeneration, 120),
	)
	strategy.selectionGeneration = fullGeneration
	strategy.rememberFullGeneration(full, fullGeneration)

	partial := cloneSmartActiveHistoryMap(full)
	partial["active"] = currentGenerationCheckingHistory(fullGeneration + 1)
	if strategy.UpdateOutboundsInfo(partial) {
		t.Fatal("in-progress partial generation switched active")
	}
	_, decisionHistory, _ := strategy.SelectionDiagnostics()
	active := decisionHistory["active"]
	if active == nil || active.Success || active.Delay != 0 || active.HealthScore != 0 ||
		active.URLTestStatus != urltest.StatusChecking || active.CombinedReady {
		t.Fatalf("old successful metrics resurfaced while active was checking: %+v", active)
	}
}

func TestSmartActiveRetainsFailedRouteWithoutCandidateThenSwitchesNextBatch(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)

	failedBatch := histories(
		currentGenerationFailedHistory(80, urltest.ErrorTypeEOF),
		currentGenerationFailedHistory(80, urltest.ErrorTypeTimeout),
	)
	if strategy.UpdateOutboundsInfoForCompletedBatch(failedBatch, 80) {
		t.Fatal("all-failed batch switched to another failed server")
	}
	requireDecision(t, strategy, "keep", "active")
	_, keptHistory, _ := strategy.SelectionDiagnostics()
	kept := keptHistory["active"]
	if kept.Success || kept.URLTestStatus != urltest.StatusFailed || kept.HealthScore != 0 ||
		kept.Delay != 65535 || !kept.CombinedReady {
		t.Fatalf("retained route recovered stale successful metrics: %+v", kept)
	}

	recoveryBatch := histories(
		currentGenerationFailedHistory(81, urltest.ErrorTypeEOF),
		currentGenerationHealthyHistory(81, 120),
	)
	if !strategy.UpdateOutboundsInfoForCompletedBatch(recoveryBatch, 81) {
		t.Fatalf("next completed batch did not switch to fresh candidate: %+v", strategy.LastDecision())
	}
	requireDecision(t, strategy, "switch", "candidate")
}

func TestSmartActiveCacheFromPreviousRunCannotEnterCurrentComparison(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	cachedActive := currentGenerationHealthyHistory(90, 50)
	cachedActive.IsFromCache = true
	freshCandidate := currentGenerationHealthyHistory(91, 120)

	if strategy.UpdateOutboundsInfo(histories(cachedActive, freshCandidate)) {
		t.Fatal("partial current generation compared against cached active")
	}
	requireDecision(t, strategy, "keep", "active")
	if strategy.selectionGeneration != 0 || strategy.LastDecision().reason != "current_generation_incomplete" {
		t.Fatalf("cache affected selection generation or decision: generation=%d decision=%+v", strategy.selectionGeneration, strategy.LastDecision())
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
	advanceCompletedProbe(history)
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

func TestSmartActiveMissingHealthKeepsExistingUnconfirmedActive(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.confirmed = false
	history := map[string]*adapter.URLTestHistory{
		"active":    {Delay: 300},
		"candidate": {Delay: 100},
	}
	if strategy.UpdateOutboundsInfo(history) {
		t.Fatal("did not expect unconfirmed active to switch on missing health")
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
	advanceCompletedProbe(history)
	strategy.UpdateOutboundsInfo(history)
	if recovered := strategy.LastRecoveries(); len(recovered) != 0 {
		t.Fatalf("server recovered after one clean probe: %v", recovered)
	}
	if strategy.Now() != "candidate" {
		t.Fatal("server returned to selection after one clean probe")
	}

	// The second clean result allows recovery and emits the recovery event.
	advanceCompletedProbe(history)
	strategy.UpdateOutboundsInfo(history)
	if recovered := strategy.LastRecoveries(); len(recovered) != 1 || recovered[0] != "active" {
		t.Fatalf("expected active recovery after two clean probes, got %v", recovered)
	}
	if strategy.Now() != "candidate" {
		t.Fatal("recovered but worse server should not displace healthy active")
	}
}

func TestSmartActiveDegradedSuccessDoesNotClearRecoveryQuarantine(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.active = strategy.outbounds[1]
	strategy.avoidUntil["active"] = time.Now().Add(time.Minute)
	strategy.evidence["active"] = &smartEvidence{recoveryPending: true, failureStreak: 2}
	penalized := healthyHistory(80)
	penalized.RealUserPenalty = 20
	history := histories(penalized, healthyHistory(100))

	for range 2 {
		strategy.UpdateOutboundsInfo(history)
		if recovered := strategy.LastRecoveries(); len(recovered) != 0 {
			t.Fatalf("DEGRADED successes cleared recovery quarantine: %v", recovered)
		}
		advanceCompletedProbe(history)
	}
	evidence := strategy.evidence["active"]
	if evidence == nil || !evidence.recoveryPending || evidence.successStreak != 0 {
		t.Fatalf("DEGRADED route left quarantine: %+v", evidence)
	}
}

func TestSmartActiveRepeatedSnapshotDoesNotCountAsSecondCleanProbe(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(healthyHistory(300), healthyHistory(100))

	strategy.UpdateOutboundsInfo(history)
	for range 5 {
		strategy.UpdateOutboundsInfo(history)
	}

	if strategy.Now() != "active" {
		t.Fatal("replayed observer snapshot was counted as multiple clean probes")
	}
	if streak := strategy.evidence["candidate"].successStreak; streak != 1 {
		t.Fatalf("candidate success streak=%d, want exactly one unique completed probe", streak)
	}

	advanceCompletedProbe(history)
	if !strategy.UpdateOutboundsInfo(history) {
		t.Fatal("a genuinely new second clean probe did not unlock the switch")
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
