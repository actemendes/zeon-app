package monitoring

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/log"
)

func probeHistory(success bool, errorType string) adapter.URLTestHistory {
	delay := uint16(80)
	if !success {
		delay = TimeoutDelay
	}
	return adapter.URLTestHistory{
		Time:            time.Now(),
		Delay:           delay,
		Success:         success,
		ErrorType:       errorType,
		StabilityPoints: 40,
	}
}

func TestProbeEvidenceSingleEOFIsSmallDegradation(t *testing.T) {
	previous := probeHistory(true, urltest.ErrorTypeNone)
	next := probeHistory(false, urltest.ErrorTypeEOF)
	applyProbeEvidence("server", &next, previous)
	if next.DegradationPoints != 5 || next.VolatilityPenalty != 4 {
		t.Fatalf("single EOF evidence is too aggressive: %+v", next)
	}
	if next.StabilityPoints != 32 {
		t.Fatalf("stability=%d, want 32", next.StabilityPoints)
	}
}

func TestProbeEvidenceRepeatedTimeoutsAccumulate(t *testing.T) {
	previous := probeHistory(true, urltest.ErrorTypeNone)
	for i := 0; i < 4; i++ {
		next := probeHistory(false, urltest.ErrorTypeTimeout)
		applyProbeEvidence("server", &next, previous)
		previous = next
	}
	if previous.DegradationPoints < 55 || previous.VolatilityPenalty == 0 {
		t.Fatalf("repeated timeouts did not accumulate enough evidence: %+v", previous)
	}
}

func TestProbeEvidenceCriticalErrorsAreHeavier(t *testing.T) {
	previous := probeHistory(true, urltest.ErrorTypeNone)
	refused := probeHistory(false, urltest.ErrorTypeRefused)
	tlsFailure := probeHistory(false, urltest.ErrorTypeTLSHandshakeFailed)
	applyProbeEvidence("server", &refused, previous)
	applyProbeEvidence("server", &tlsFailure, previous)
	if refused.DegradationPoints != 28 || tlsFailure.DegradationPoints != 28 {
		t.Fatalf("critical errors must add 28 degradation points: refused=%d tls=%d", refused.DegradationPoints, tlsFailure.DegradationPoints)
	}
}

func TestSuccessfulProbeRecoversGradually(t *testing.T) {
	previous := probeHistory(false, urltest.ErrorTypeTimeout)
	previous.DegradationPoints = 64
	previous.RealUserPenalty = 20
	previous.VolatilityPenalty = 16
	previous.StabilityPoints = 4
	next := probeHistory(true, urltest.ErrorTypeNone)
	applyProbeEvidence("server", &next, previous)
	if next.DegradationPoints != 58 || next.RealUserPenalty != 18 || next.VolatilityPenalty != 14 || next.StabilityPoints != 8 {
		t.Fatalf("unexpected gradual recovery: %+v", next)
	}
	if next.DegradationPoints == 0 || next.RealUserPenalty == 0 {
		t.Fatal("one successful probe must not erase degradation")
	}
}

func TestFailedProbeDoesNotForgiveRealUserPenalty(t *testing.T) {
	previous := probeHistory(true, urltest.ErrorTypeNone)
	previous.RealUserPenalty = 20
	next := probeHistory(false, urltest.ErrorTypeTimeout)
	applyProbeEvidence("server", &next, previous)
	if next.RealUserPenalty != 20 {
		t.Fatalf("failed probe decayed real-user penalty to %d", next.RealUserPenalty)
	}
}

func TestPriorityPartialProbeDoesNotForgiveRealUserPenalty(t *testing.T) {
	previous := probeHistory(true, urltest.ErrorTypeNone)
	previous.RealUserPenalty = 20
	next := probeHistory(true, urltest.ErrorTypeNone)
	applyProbeEvidenceWithRecovery("server", &next, previous, false)
	if next.RealUserPenalty != 20 {
		t.Fatalf("priority partial probe decayed real-user penalty to %d", next.RealUserPenalty)
	}
}

func TestRuntimePenaltyWeightsAndCapsErrors(t *testing.T) {
	stats := &adapter.RuntimePenaltyStats{}
	for i := 0; i < 10; i++ {
		incrementRuntimeStats(stats, urltest.ErrorTypeTimeout)
		incrementRuntimeStats(stats, urltest.ErrorTypeReset)
	}
	if penalty := calculateRuntimePenalty(stats); penalty != 25 {
		t.Fatalf("runtime penalty=%d, want cap 25", penalty)
	}
}

func runtimeHealthMonitor(tag string, history adapter.URLTestHistory) *OutboundMonitoring {
	return &OutboundMonitoring{
		logger:         log.StdLogger(),
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
		outbounds: map[string]*outboundState{
			tag: {history: history},
		},
		groups:  make(map[string]*groupState),
		history: urltest.NewHistoryStorage(),
	}
}

func runtimeHistory(monitor *OutboundMonitoring, tag string) adapter.URLTestHistory {
	state := monitor.outbounds[tag]
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.history
}

func TestRuntimeIdleWithoutTrafficOrErrorsDoesNotDegrade(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	before := runtimeHistory(monitor, "active")
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints != before.DegradationPoints || after.RealUserPenalty != before.RealUserPenalty || after.RuntimePenalty != before.RuntimePenalty {
		t.Fatalf("idle mutated runtime health: before=%+v after=%+v", before, after)
	}
}

func TestRuntimeErrorWithoutRealOutboundTagDoesNotMutateServer(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeError("", errors.New("i/o timeout"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints != 0 || after.RealUserPenalty != 0 || after.RuntimePenalty != 0 {
		t.Fatalf("empty outbound tag mutated active server: %+v", after)
	}
}

func TestRuntimeSingleEOFIsWeakSignal(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeError("active", errors.New("EOF"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints > 10 || after.RealUserPenalty > 5 {
		t.Fatalf("single EOF was too aggressive: %+v", after)
	}
}

func TestRuntimeRepeatedTimeoutsAccelerateDegradation(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeError("active", errors.New("i/o timeout"))
	monitor.RecordRuntimeError("active", errors.New("context deadline exceeded"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints < 55 || after.RealUserPenalty < 20 || after.RuntimePenalty < 14 {
		t.Fatalf("timeout burst did not degrade active enough: %+v", after)
	}
}

func TestRuntimeRefusedBurstQuicklyMarksBad(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeError("active", errors.New("connection refused"))
	monitor.RecordRuntimeError("active", errors.New("connection refused"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints < 75 || after.RealUserPenalty < 20 {
		t.Fatalf("refused burst did not become severe enough: %+v", after)
	}
}

func TestRuntimeTLSHandshakeFailureIsHeavy(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeError("active", errors.New("TLS handshake failed"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints < 55 || after.RealUserPenalty < 12 {
		t.Fatalf("TLS runtime failure did not mark server BAD quickly: %+v", after)
	}
}

func TestRuntimeSuccessGraduallyRecoversPenalties(t *testing.T) {
	history := probeHistory(true, urltest.ErrorTypeNone)
	history.DegradationPoints = 60
	history.RealUserPenalty = 20
	history.StabilityPoints = 10
	monitor := runtimeHealthMonitor("active", history)
	monitor.RecordRuntimeSuccess("active")
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints >= 60 || after.RealUserPenalty >= 20 || after.StabilityPoints <= 10 {
		t.Fatalf("runtime success did not recover gradually: %+v", after)
	}
	if after.DegradationPoints == 0 || after.RealUserPenalty == 0 {
		t.Fatalf("one runtime success recovered too aggressively: %+v", after)
	}
}

func TestRuntimeDownloadTrafficRecoversGradually(t *testing.T) {
	history := probeHistory(true, urltest.ErrorTypeNone)
	history.DegradationPoints = 40
	history.RealUserPenalty = 16
	history.StabilityPoints = 10
	monitor := runtimeHealthMonitor("active", history)
	monitor.RecordRuntimeTraffic("active", 64*1024, true)
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints >= 40 || after.RealUserPenalty >= 16 || after.StabilityPoints <= 10 {
		t.Fatalf("download traffic did not recover gradually: %+v", after)
	}
	if after.DegradationPoints == 0 || after.RealUserPenalty == 0 {
		t.Fatalf("one traffic sample recovered too aggressively: %+v", after)
	}
}

func TestRuntimeUploadOnlyDoesNotImmediatelyPenalize(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeTraffic("active", 4*1024, false)
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints != 0 || after.RealUserPenalty != 0 || after.RuntimePenalty != 0 {
		t.Fatalf("single upload-only sample mutated health: %+v", after)
	}
}

func TestRuntimeUploadOnlyWithRepeatedTimeoutMarksSuspect(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeTraffic("active", 4*1024, false)
	monitor.RecordRuntimeTraffic("active", 4*1024, false)
	monitor.RecordRuntimeError("active", errors.New("i/o timeout"))
	monitor.RecordRuntimeError("active", errors.New("context deadline exceeded"))
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints < 55 || after.RealUserPenalty < 20 || after.RuntimePenalty < 14 {
		t.Fatalf("upload-only timeout evidence did not degrade enough: %+v", after)
	}
}

func TestRuntimeDownloadTrafficClearsUploadOnlyEvidence(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.RecordRuntimeTraffic("active", 4*1024, false)
	monitor.RecordRuntimeTraffic("active", 128*1024, true)
	monitor.RecordRuntimeTraffic("active", 4*1024, false)
	after := runtimeHistory(monitor, "active")
	if after.DegradationPoints != 0 || after.RealUserPenalty != 0 {
		t.Fatalf("fresh download should prevent upload-only stall evidence: %+v", after)
	}
}

func TestRuntimeOldErrorsStopContributingAfterTTL(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.runtimeStats["active"] = &adapter.RuntimePenaltyStats{
		Tag:       "active",
		UpdatedAt: time.Now().Add(-runtimePenaltyTTL - time.Second),
		Penalty:   25,
	}
	if penalty := monitor.runtimePenaltyForTag("active"); penalty != 0 {
		t.Fatalf("expired runtime penalty=%d, want 0", penalty)
	}
}

func TestCheckGenerationResetClearsCurrentBarsAndScores(t *testing.T) {
	history := probeHistory(true, urltest.ErrorTypeNone)
	history.HealthScore = 95
	history.UDPProbeAvailable = true
	history.UDPPenalty = 7
	history.UDPReady = true
	history.CombinedReady = true
	monitor := runtimeHealthMonitor("active", history)

	monitor.beginCheckGeneration(12, []string{"active"}, "manual_refresh")

	after := runtimeHistory(monitor, "active")
	if after.URLTestStatus != urltest.StatusChecking || after.Delay != 0 || after.HealthScore != 0 || after.Success {
		t.Fatalf("generation reset kept displayed health: %+v", after)
	}
	if after.UDPProbeAvailable || after.UDPPenalty != 0 || after.UDPReady || after.CombinedReady || after.PingReady {
		t.Fatalf("generation reset kept stale readiness: %+v", after)
	}
	if after.CheckGeneration != 12 {
		t.Fatalf("generation=%d, want 12", after.CheckGeneration)
	}
}

func TestLateResultPreviousGenerationIsIgnored(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.beginCheckGeneration(11, []string{"active"}, "manual_refresh")

	monitor.applyResult(testOutcome{
		outboundTag: "active",
		cycleID:     10,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 40, Success: true, ErrorType: urltest.ErrorTypeNone, HealthScore: 100,
		},
	})

	after := runtimeHistory(monitor, "active")
	if after.CheckGeneration != 11 || after.URLTestStatus != urltest.StatusChecking || after.HealthScore != 0 || after.Success {
		t.Fatalf("late generation mutated current state: %+v", after)
	}
}

func TestLateOldSuccessCannotRestoreMetricsAfterCurrentFailure(t *testing.T) {
	old := probeHistory(true, urltest.ErrorTypeNone)
	old.CheckGeneration = 20
	old.Delay = 50
	old.HealthScore = 100
	monitor := runtimeHealthMonitor("active", old)
	monitor.beginCheckGeneration(21, []string{"active"}, "background_refresh")

	failedAt := time.Now()
	monitor.applyResult(testOutcome{
		outboundTag:    "active",
		cycleID:        21,
		fullGeneration: true,
		err:            errors.New("connection reset"),
		history: adapter.URLTestHistory{
			Time: failedAt, Delay: TimeoutDelay, Success: false,
			ErrorType: urltest.ErrorTypeReset, URLTestStatus: urltest.StatusFailed,
		},
	})
	monitor.applyResult(testOutcome{
		outboundTag:    "active",
		cycleID:        20,
		fullGeneration: true,
		history: adapter.URLTestHistory{
			Time: failedAt.Add(time.Second), Delay: 50, Success: true,
			ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			HealthScore: 100,
		},
	})

	after := runtimeHistory(monitor, "active")
	if after.CheckGeneration != 21 || after.Success || after.Delay != TimeoutDelay ||
		after.HealthScore != 0 || after.URLTestStatus != urltest.StatusFailed ||
		!after.Time.Equal(failedAt) {
		t.Fatalf("late old success restored stale metrics: %+v", after)
	}
}

func TestCurrentGenerationResultBecomesReady(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.beginCheckGeneration(11, []string{"active"}, "background_refresh")

	monitor.applyResult(testOutcome{
		outboundTag: "active",
		cycleID:     11,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 42, Success: true, ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess, HealthScore: 98,
		},
	})

	after := runtimeHistory(monitor, "active")
	if after.CheckGeneration != 11 || !after.PingReady || !after.QualityReady || !after.SpeedReady || !after.CombinedReady {
		t.Fatalf("current generation did not become ready: %+v", after)
	}
	if after.Delay != 42 || after.HealthScore != 100 || !after.Success {
		t.Fatalf("current generation did not apply result: %+v", after)
	}
}

func TestCurrentGenerationInvalidTerminalTupleBecomesFailure(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.beginCheckGeneration(13, []string{"active"}, "background_refresh")

	monitor.applyResult(testOutcome{
		outboundTag:    "active",
		cycleID:        13,
		fullGeneration: true,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 0, Success: true,
			ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			HealthScore: 100,
		},
	})

	after := runtimeHistory(monitor, "active")
	if after.Success || after.Delay != TimeoutDelay || after.HealthScore != 0 ||
		after.URLTestStatus != urltest.StatusFailed || after.ErrorType == "" ||
		!after.CombinedReady || after.CheckGeneration != 13 {
		t.Fatalf("invalid terminal result remained eligible: %+v", after)
	}
}

func TestFullGenerationFailureIsConsistentInPresentationAndRanking(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.beginCheckGeneration(14, []string{"active"}, "background_refresh")
	failedAt := time.Now()
	monitor.applyResult(testOutcome{
		outboundTag:    "active",
		cycleID:        14,
		fullGeneration: true,
		err:            errors.New("connection reset"),
		history: adapter.URLTestHistory{
			Time: failedAt, Delay: TimeoutDelay, Success: false,
			ErrorType: urltest.ErrorTypeReset, URLTestStatus: urltest.StatusFailed,
		},
	})

	presentation := monitor.getURLTest("active", true)
	ranking := monitor.getURLTest("active", false)
	for name, result := range map[string]*adapter.URLTestHistory{
		"presentation": presentation,
		"ranking":      ranking,
	} {
		if result == nil || result.Success || result.Delay != TimeoutDelay ||
			result.HealthScore != 0 || result.URLTestStatus != urltest.StatusFailed ||
			result.CheckGeneration != 14 || !result.CombinedReady || !result.Time.Equal(failedAt) {
			t.Fatalf("%s diverged from fresh failure: %+v", name, result)
		}
	}
}

func TestNewPingDoesNotReuseOldUDPFromPreviousGeneration(t *testing.T) {
	history := probeHistory(true, urltest.ErrorTypeNone)
	history.UDPProbeAvailable = true
	history.UDPPenalty = 10
	history.UDPReady = true
	monitor := runtimeHealthMonitor("active", history)
	monitor.beginCheckGeneration(21, []string{"active"}, "manual_refresh")

	monitor.applyResult(testOutcome{
		outboundTag: "active",
		cycleID:     21,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 60, Success: true, ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess, HealthScore: 90,
		},
	})

	after := runtimeHistory(monitor, "active")
	if after.UDPProbeAvailable || after.UDPPenalty != 0 || after.UDPReady {
		t.Fatalf("new generation reused old UDP result: %+v", after)
	}
}

func TestTwoQuickRefreshesDoNotMixResults(t *testing.T) {
	monitor := runtimeHealthMonitor("active", probeHistory(true, urltest.ErrorTypeNone))
	monitor.beginCheckGeneration(30, []string{"active"}, "manual_refresh")
	monitor.beginCheckGeneration(31, []string{"active"}, "manual_refresh")

	monitor.applyResult(testOutcome{
		outboundTag: "active",
		cycleID:     30,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 35, Success: true, ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess, HealthScore: 100,
		},
	})
	if after := runtimeHistory(monitor, "active"); after.CheckGeneration != 31 || after.CombinedReady {
		t.Fatalf("older quick refresh result was accepted: %+v", after)
	}

	monitor.applyResult(testOutcome{
		outboundTag: "active",
		cycleID:     31,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 80, Success: true, ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess, HealthScore: 90,
		},
	})
	if after := runtimeHistory(monitor, "active"); after.CheckGeneration != 31 || after.Delay != 80 || !after.CombinedReady {
		t.Fatalf("newer quick refresh result was not accepted: %+v", after)
	}
}

func TestURLTestStatusLifecycleCoversEveryCycledServer(t *testing.T) {
	monitor := &OutboundMonitoring{
		ctx:           context.Background(),
		logger:        log.StdLogger(),
		normalQueue:   make(chan *testTask, 2),
		priorityQueue: make(chan *testTask, 2),
		outbounds: map[string]*outboundState{
			"success": {history: adapter.URLTestHistory{URLTestStatus: urltest.StatusNotTested}},
			"failed":  {history: adapter.URLTestHistory{URLTestStatus: urltest.StatusNotTested}},
		},
		groups:  make(map[string]*groupState),
		history: urltest.NewHistoryStorage(),
	}
	monitor.cycleSeq = 1

	for _, tag := range []string{"success", "failed"} {
		if !monitor.enqueueTask(&testTask{outboundTag: tag, cycleID: 1}) {
			t.Fatalf("failed to enqueue %s", tag)
		}
		if status := monitor.outbounds[tag].history.URLTestStatus; status != urltest.StatusChecking {
			t.Fatalf("%s status=%s, want checking", tag, status)
		}
	}

	monitor.applyResult(testOutcome{
		outboundTag: "success",
		cycleID:     1,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 42, Success: true, ErrorType: urltest.ErrorTypeNone,
		},
	})
	monitor.applyResult(testOutcome{
		outboundTag: "failed",
		err:         errors.New("timeout"),
		cycleID:     1,
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: TimeoutDelay, Success: false, ErrorType: urltest.ErrorTypeTimeout,
		},
	})

	if status := monitor.outbounds["success"].history.URLTestStatus; status != urltest.StatusSuccess {
		t.Fatalf("successful status=%s", status)
	}
	if status := monitor.outbounds["failed"].history.URLTestStatus; status != urltest.StatusFailed {
		t.Fatalf("failed status=%s", status)
	}
	for tag, state := range monitor.outbounds {
		if state.history.URLTestStatus == urltest.StatusNotTested || state.history.URLTestStatus == urltest.StatusChecking {
			t.Fatalf("cycled server %s remained %s", tag, state.history.URLTestStatus)
		}
	}
}

func TestInferURLTestStatusKeepsOnlyUntestedHistoryAsNotTested(t *testing.T) {
	if status := inferURLTestStatus(&adapter.URLTestHistory{}); status != urltest.StatusNotTested {
		t.Fatalf("empty history status=%s", status)
	}
	if status := inferURLTestStatus(&adapter.URLTestHistory{Time: time.Now(), ErrorType: urltest.ErrorTypeTimeout}); status != urltest.StatusFailed {
		t.Fatalf("failed history status=%s", status)
	}
	if status := inferURLTestStatus(&adapter.URLTestHistory{Time: time.Now(), Delay: 50, Success: true, ErrorType: urltest.ErrorTypeNone}); status != urltest.StatusSuccess {
		t.Fatalf("successful history status=%s", status)
	}
}

func TestManualRefreshTargetsExpandNestedGroups(t *testing.T) {
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{
			"select":  {},
			"balance": {},
			"leaf-a":  {},
			"leaf-b":  {},
		},
		groups: map[string]*groupState{
			"select":  {outbounds: map[string]struct{}{"balance": {}}},
			"balance": {outbounds: map[string]struct{}{"leaf-a": {}, "leaf-b": {}}},
		},
	}

	targets := monitor.collectManualRefreshTargets("select")
	if len(targets) != 2 || targets[0] != "leaf-a" || targets[1] != "leaf-b" {
		t.Fatalf("targets=%v, want nested leaves", targets)
	}
}

func TestManualRefreshMarksNestedBalancerGroupForReselect(t *testing.T) {
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{
			"leaf-a": {groupTags: []string{"", "balance", "select"}},
			"leaf-b": {groupTags: []string{"", "balance", "select"}},
		},
		groups: map[string]*groupState{
			"select":  {outbounds: map[string]struct{}{"balance": {}}},
			"balance": {outbounds: map[string]struct{}{"leaf-a": {}, "leaf-b": {}}},
		},
	}

	groups := monitor.markManualRefreshForTargets("select", []string{"leaf-a", "leaf-b"}, time.Now())
	if len(groups) != 2 || groups[0] != "balance" || groups[1] != "select" {
		t.Fatalf("groups=%v, want balance and select", groups)
	}
	if !monitor.ConsumeRecentManualRefresh("balance") {
		t.Fatal("nested balance group did not receive manual refresh marker")
	}
	if monitor.ConsumeRecentManualRefresh("balance") {
		t.Fatal("manual refresh marker should be consumed once")
	}
}

func TestPartialManualRefreshDoesNotMarkWholeBalancerForReselect(t *testing.T) {
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{
			"leaf-a": {groupTags: []string{"", "balance"}},
			"leaf-b": {groupTags: []string{"", "balance"}},
		},
		groups: map[string]*groupState{
			"balance": {outbounds: map[string]struct{}{"leaf-a": {}, "leaf-b": {}}},
		},
	}

	groups := monitor.markManualRefreshForTargets("leaf-a", []string{"leaf-a"}, time.Now())
	if len(groups) != 0 {
		t.Fatalf("partial refresh marked groups=%v, want none", groups)
	}
	if monitor.ConsumeRecentManualRefresh("balance") {
		t.Fatal("partial refresh enabled full-group user-refresh reselect")
	}
}

func TestTimedOutManualRefreshMarksOnlyActuallyCompletedTargets(t *testing.T) {
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{
			"leaf-a": {groupTags: []string{"", "balance"}},
			"leaf-b": {groupTags: []string{"", "balance"}},
		},
		groups: map[string]*groupState{
			"balance": {outbounds: map[string]struct{}{"leaf-a": {}, "leaf-b": {}}},
		},
	}
	report := manualRefreshReport{total: 2}
	report.record(testOutcome{outboundTag: "leaf-a", history: adapter.URLTestHistory{Success: true}})
	report.markTimeout(1)

	groups := monitor.markManualRefreshForTargets("balance", report.completedTargets, time.Now())
	if len(groups) != 0 {
		t.Fatalf("timed-out partial refresh marked groups=%v, want none", groups)
	}
}

func TestManualRefreshCallsAreSerialized(t *testing.T) {
	monitor := &OutboundMonitoring{
		outbounds: make(map[string]*outboundState),
		groups:    make(map[string]*groupState),
	}
	monitor.manualRefreshRun.Lock()

	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		close(started)
		done <- monitor.TestNowAndWait("missing", time.Millisecond)
	}()
	<-started
	select {
	case err := <-done:
		t.Fatalf("parallel refresh bypassed serialization lock: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	monitor.manualRefreshRun.Unlock()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("missing target unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("serialized refresh did not resume after predecessor completed")
	}
}

func TestSignalChangeCoalescesPendingGroupNotification(t *testing.T) {
	notifyCh := make(chan struct{}, 1)
	notifyCh <- struct{}{}
	monitor := &OutboundMonitoring{
		groups: map[string]*groupState{
			"balance": {notifyCh: notifyCh},
		},
	}

	done := make(chan error, 1)
	go func() {
		done <- monitor.SignalChange("balance")
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("SignalChange returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("SignalChange blocked behind an already pending notification")
	}
	if len(notifyCh) != 1 {
		t.Fatalf("pending notifications=%d, want one coalesced event", len(notifyCh))
	}
}

func TestManualRefreshReportCountsCompletedTargets(t *testing.T) {
	report := manualRefreshReport{total: 4}
	report.record(testOutcome{
		outboundTag: "success-a",
		history:     adapter.URLTestHistory{Success: true, Delay: 42, ErrorType: urltest.ErrorTypeNone},
	})
	report.record(testOutcome{
		outboundTag: "success-b",
		history:     adapter.URLTestHistory{Success: true, Delay: 55, ErrorType: urltest.ErrorTypeNone},
	})
	report.record(testOutcome{
		outboundTag: "failed",
		err:         errors.New("i/o timeout"),
		history:     adapter.URLTestHistory{Success: false, Delay: TimeoutDelay, ErrorType: urltest.ErrorTypeTimeout},
	})

	if report.success != 2 || report.failed != 1 || report.completed() != 3 {
		t.Fatalf("report=%+v, want 2 success, 1 failed, 3 completed", report)
	}
}

func TestManualRefreshTimeoutKeepsPendingOutOfFailedCount(t *testing.T) {
	report := manualRefreshReport{total: 88}
	report.record(testOutcome{
		outboundTag: "completed-success",
		history:     adapter.URLTestHistory{Success: true, Delay: 40, ErrorType: urltest.ErrorTypeNone},
	})
	report.record(testOutcome{
		outboundTag: "completed-failed",
		err:         errors.New("connection refused"),
		history:     adapter.URLTestHistory{Success: false, Delay: TimeoutDelay, ErrorType: urltest.ErrorTypeRefused},
	})
	report.markTimeout(86)

	if report.success != 1 || report.failed != 1 || report.pending != 86 || report.cancelled != 86 || !report.timeout {
		t.Fatalf("report=%+v, want partial timeout with pending not counted as failed", report)
	}
	if report.failed == report.total {
		t.Fatalf("pending targets were counted as failed: %+v", report)
	}
}

func TestManualRefreshHardTimeoutFinishesContextIgnoringTarget(t *testing.T) {
	started := time.Now()
	history, err, timedOut := runURLTestWithHardTimeout(context.Background(), 20*time.Millisecond, func(context.Context) (adapter.URLTestHistory, error) {
		time.Sleep(250 * time.Millisecond)
		return adapter.URLTestHistory{Success: true, Delay: 40}, nil
	})

	if !timedOut {
		t.Fatal("context-ignoring target did not hit the hard timeout")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err=%v, want context deadline exceeded", err)
	}
	if history.Success {
		t.Fatalf("timed-out target returned successful history: %+v", history)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("hard timeout returned too late: %s", elapsed)
	}
}

func TestManualRefreshHardTimeoutPreservesCompletedResult(t *testing.T) {
	want := adapter.URLTestHistory{
		Time:      time.Now(),
		Delay:     47,
		Success:   true,
		ErrorType: urltest.ErrorTypeNone,
	}
	got, err, timedOut := runURLTestWithHardTimeout(context.Background(), time.Second, func(context.Context) (adapter.URLTestHistory, error) {
		return want, nil
	})

	if timedOut || err != nil {
		t.Fatalf("completed target timedOut=%v err=%v", timedOut, err)
	}
	if got.Delay != want.Delay || !got.Success {
		t.Fatalf("got=%+v, want=%+v", got, want)
	}
}

func TestManualRefreshAllTargetsReachFinalAccounting(t *testing.T) {
	report := manualRefreshReport{total: 88}
	for i := 0; i < report.total; i++ {
		outcome := testOutcome{
			outboundTag: "target",
			history: adapter.URLTestHistory{
				Success:   i%4 == 0,
				Delay:     TimeoutDelay,
				ErrorType: urltest.ErrorTypeTimeout,
			},
			err: context.DeadlineExceeded,
		}
		if outcome.history.Success {
			outcome.history.Delay = 50
			outcome.history.ErrorType = urltest.ErrorTypeNone
			outcome.err = nil
		}
		report.record(outcome)
	}
	report.pending = report.total - report.completed()

	if report.completed() != 88 || report.pending != 0 || report.cancelled != 0 {
		t.Fatalf("report=%+v, want every target finalized", report)
	}
}
