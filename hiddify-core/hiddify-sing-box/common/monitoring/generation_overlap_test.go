package monitoring

import (
	"context"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/log"
)

func overlappingGenerationMonitor(tag string, outboundGeneration, globalGeneration uint64) *OutboundMonitoring {
	return &OutboundMonitoring{
		ctx:           context.Background(),
		logger:        log.StdLogger(),
		cycleSeq:      globalGeneration,
		normalQueue:   make(chan *testTask, 2),
		priorityQueue: make(chan *testTask, 2),
		outbounds: map[string]*outboundState{
			tag: {history: adapter.URLTestHistory{CheckGeneration: outboundGeneration}},
		},
		groups:  make(map[string]*groupState),
		history: urltest.NewHistoryStorage(),
	}
}

func TestBackgroundGenerationContinuesAfterUnrelatedPartialRefresh(t *testing.T) {
	monitor := overlappingGenerationMonitor("candidate", 1, 2)
	if !monitor.enqueueTask(&testTask{outboundTag: "candidate", cycleID: 1}) {
		t.Fatal("unrelated partial generation canceled the remaining background task")
	}
	if task := <-monitor.normalQueue; task.cycleID != 1 || task.outboundTag != "candidate" {
		t.Fatalf("unexpected queued task: %+v", task)
	}
}

func TestManualGenerationContinuesAfterUnrelatedPartialRefresh(t *testing.T) {
	monitor := overlappingGenerationMonitor("candidate", 1, 2)
	if !monitor.prepareManualRefreshTarget("candidate", 1) {
		t.Fatal("unrelated partial generation canceled the remaining manual target")
	}
}

func TestOlderGenerationStillRejectedForSameOutbound(t *testing.T) {
	monitor := overlappingGenerationMonitor("candidate", 2, 2)
	if monitor.enqueueTask(&testTask{outboundTag: "candidate", cycleID: 1}) {
		t.Fatal("older generation was accepted for an outbound already moved to a newer generation")
	}
}

func TestForcedFullCycleIncludesFreshCachedSuccesses(t *testing.T) {
	now := time.Now()
	monitor := &OutboundMonitoring{
		mainInterval: time.Hour,
		outbounds: map[string]*outboundState{
			"fresh": {history: adapter.URLTestHistory{Time: now, Success: true}},
			"stale": {history: adapter.URLTestHistory{Time: now.Add(-2 * time.Hour), Success: true}},
			"group": {history: adapter.URLTestHistory{Time: now, Success: true}},
		},
		groups: map[string]*groupState{"group": {}},
	}

	regular := monitor.collectCycleTargets(false)
	if len(regular) != 1 || regular[0] != "stale" {
		t.Fatalf("regular targets=%v, want only stale", regular)
	}
	forced := monitor.collectCycleTargets(true)
	forcedSet := make(map[string]bool, len(forced))
	for _, tag := range forced {
		forcedSet[tag] = true
	}
	if len(forced) != 2 || !forcedSet["fresh"] || !forcedSet["stale"] {
		t.Fatalf("forced targets=%v, want every leaf outbound", forced)
	}
}

func TestRankingViewRejectsTargetedSuccessUntilFullCohortResult(t *testing.T) {
	const tag = "candidate"
	state := &outboundState{
		history: adapter.URLTestHistory{
			Time: time.Now(), Delay: 40, Success: true, ErrorType: urltest.ErrorTypeNone,
			URLTestStatus: urltest.StatusSuccess, CheckGeneration: 7, CombinedReady: true,
		},
		lastResultSourceKnown:        true,
		lastResultFromFullGeneration: false,
	}
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{tag: state},
		groups: map[string]*groupState{
			"auto": {outbounds: map[string]struct{}{tag: {}}},
		},
	}

	presentation := monitor.OutboundsHistory("auto")[tag]
	if presentation == nil || !presentation.Success || !presentation.CombinedReady {
		t.Fatalf("targeted result disappeared from presentation: %+v", presentation)
	}
	ranking := monitor.OutboundsRankingHistory("auto")[tag]
	if ranking == nil || ranking.CombinedReady || ranking.URLTestStatus != urltest.StatusChecking {
		t.Fatalf("targeted success remained ranking-eligible: %+v", ranking)
	}

	state.mu.Lock()
	state.lastResultFromFullGeneration = true
	state.mu.Unlock()
	ranking = monitor.OutboundsRankingHistory("auto")[tag]
	if ranking == nil || !ranking.Success || !ranking.CombinedReady || ranking.URLTestStatus != urltest.StatusSuccess {
		t.Fatalf("full-cohort result was not ranking-eligible: %+v", ranking)
	}
}

func TestRankingViewKeepsTargetedFailureAsVetoEvidence(t *testing.T) {
	const tag = "candidate"
	monitor := &OutboundMonitoring{
		outbounds: map[string]*outboundState{
			tag: {
				history: adapter.URLTestHistory{
					Time: time.Now(), Delay: TimeoutDelay, Success: false, ErrorType: urltest.ErrorTypeTimeout,
					URLTestStatus: urltest.StatusFailed, CheckGeneration: 7, CombinedReady: true,
				},
				lastResultSourceKnown:        true,
				lastResultFromFullGeneration: false,
			},
		},
		groups: map[string]*groupState{
			"auto": {outbounds: map[string]struct{}{tag: {}}},
		},
	}
	ranking := monitor.OutboundsRankingHistory("auto")[tag]
	if ranking == nil || ranking.Success || ranking.CombinedReady || ranking.URLTestStatus != urltest.StatusFailed {
		t.Fatalf("targeted failure lost veto eligibility: %+v", ranking)
	}
}

func TestLateTargetedSuccessCannotOverwriteFullResult(t *testing.T) {
	const tag = "candidate"
	fullTime := time.Now()
	monitor := &OutboundMonitoring{
		logger:  log.NewNOPFactory().NewLogger("monitoring-test"),
		history: urltest.NewHistoryStorage(),
		outbounds: map[string]*outboundState{
			tag: {
				history: adapter.URLTestHistory{
					Time: fullTime, Delay: 180, Success: true, ErrorType: urltest.ErrorTypeNone,
					URLTestStatus: urltest.StatusSuccess, CheckGeneration: 7, CombinedReady: true,
				},
				lastResultSourceKnown:        true,
				lastResultFromFullGeneration: true,
			},
		},
		groups: make(map[string]*groupState),
	}
	result := monitor.applyResult(testOutcome{
		outboundTag: tag,
		cycleID:     7,
		history: adapter.URLTestHistory{
			Time: fullTime.Add(time.Second), Delay: 40, Success: true, ErrorType: urltest.ErrorTypeNone,
		},
	})
	if result == nil || result.Delay != 180 || !result.Time.Equal(fullTime) {
		t.Fatalf("late targeted result replaced full history: %+v", result)
	}
	state := monitor.outbounds[tag]
	state.mu.Lock()
	defer state.mu.Unlock()
	if !state.lastResultFromFullGeneration || state.history.Delay != 180 {
		t.Fatalf("full-result source was lost: source=%v history=%+v", state.lastResultFromFullGeneration, state.history)
	}
}

func TestTargetedEnqueuePreservesSettledFullResult(t *testing.T) {
	const tag = "candidate"
	fullTime := time.Now()
	state := &outboundState{
		history: adapter.URLTestHistory{
			Time: fullTime, Delay: 180, Success: true, ErrorType: urltest.ErrorTypeNone,
			URLTestStatus: urltest.StatusSuccess, CheckGeneration: 7, CombinedReady: true,
		},
		lastResultSourceKnown:        true,
		lastResultFromFullGeneration: true,
	}
	monitor := &OutboundMonitoring{
		ctx:           context.Background(),
		logger:        log.NewNOPFactory().NewLogger("monitoring-test"),
		history:       urltest.NewHistoryStorage(),
		priorityQueue: make(chan *testTask, 1),
		outbounds:     map[string]*outboundState{tag: state},
		groups:        make(map[string]*groupState),
	}

	if !monitor.enqueueTask(&testTask{outboundTag: tag, cycleID: 7, priority: true}) {
		t.Fatal("targeted task was not queued")
	}
	state.mu.Lock()
	queuedHistory := state.history
	state.mu.Unlock()
	if queuedHistory.URLTestStatus != urltest.StatusSuccess || !queuedHistory.Time.Equal(fullTime) || queuedHistory.Delay != 180 {
		t.Fatalf("targeted enqueue hid settled full result: %+v", queuedHistory)
	}

	result := monitor.applyResult(testOutcome{
		outboundTag: tag,
		cycleID:     7,
		priority:    true,
		history: adapter.URLTestHistory{
			Time: fullTime.Add(time.Second), Delay: 40, Success: true, ErrorType: urltest.ErrorTypeNone,
		},
	})
	if result == nil || result.Delay != 180 || !result.Time.Equal(fullTime) {
		t.Fatalf("late targeted result replaced full history after enqueue: %+v", result)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.priorityQueued || !state.lastResultFromFullGeneration || state.history.URLTestStatus != urltest.StatusSuccess {
		t.Fatalf("settled full state was not preserved: queued=%v source=%v history=%+v", state.priorityQueued, state.lastResultFromFullGeneration, state.history)
	}
}

func TestTargetedEnqueuePreservesFailureVeto(t *testing.T) {
	const tag = "candidate"
	failureTime := time.Now()
	state := &outboundState{
		history: adapter.URLTestHistory{
			Time: failureTime, Delay: TimeoutDelay, Success: false, ErrorType: urltest.ErrorTypeTimeout,
			URLTestStatus: urltest.StatusFailed, CheckGeneration: 7, CombinedReady: true,
		},
		lastResultSourceKnown:        true,
		lastResultFromFullGeneration: false,
	}
	monitor := &OutboundMonitoring{
		ctx:           context.Background(),
		logger:        log.NewNOPFactory().NewLogger("monitoring-test"),
		history:       urltest.NewHistoryStorage(),
		priorityQueue: make(chan *testTask, 1),
		outbounds:     map[string]*outboundState{tag: state},
		groups:        make(map[string]*groupState),
	}

	if !monitor.enqueueTask(&testTask{outboundTag: tag, cycleID: 7, priority: true}) {
		t.Fatal("targeted task was not queued")
	}
	state.mu.Lock()
	queuedHistory := state.history
	state.mu.Unlock()
	if queuedHistory.URLTestStatus != urltest.StatusFailed || !queuedHistory.Time.Equal(failureTime) {
		t.Fatalf("targeted enqueue erased failure veto: %+v", queuedHistory)
	}

	result := monitor.applyResult(testOutcome{
		outboundTag: tag,
		cycleID:     7,
		priority:    true,
		history: adapter.URLTestHistory{
			Time: failureTime.Add(time.Second), Delay: 35, Success: true, ErrorType: urltest.ErrorTypeNone,
		},
	})
	if result == nil || result.Success || result.URLTestStatus != urltest.StatusFailed || !result.Time.Equal(failureTime) {
		t.Fatalf("targeted success erased failure veto: %+v", result)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.priorityQueued || state.history.Success || state.history.URLTestStatus != urltest.StatusFailed {
		t.Fatalf("failure veto was not preserved: queued=%v history=%+v", state.priorityQueued, state.history)
	}
}

func TestFailedEnqueueRestoresGenerationAndStatus(t *testing.T) {
	const tag = "candidate"
	originalTime := time.Now()
	state := &outboundState{
		history: adapter.URLTestHistory{
			Time: originalTime, Delay: 90, Success: true,
			URLTestStatus: urltest.StatusSuccess,
		},
	}
	monitor := &OutboundMonitoring{
		ctx:         context.Background(),
		logger:      log.NewNOPFactory().NewLogger("monitoring-test"),
		normalQueue: make(chan *testTask),
		outbounds:   map[string]*outboundState{tag: state},
	}

	if monitor.enqueueTask(&testTask{outboundTag: tag, cycleID: 9}) {
		t.Fatal("enqueue unexpectedly succeeded without a queue receiver")
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.queued || state.enqueuedCycle != 0 || state.history.CheckGeneration != 0 ||
		state.history.URLTestStatus != urltest.StatusSuccess || !state.history.Time.Equal(originalTime) {
		t.Fatalf("failed enqueue did not restore state: queued=%v cycle=%d history=%+v", state.queued, state.enqueuedCycle, state.history)
	}
}

func TestCompletedBatchMetadataSurvivesDroppedDirectEvent(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	broadcaster := NewBroadcaster[GroupEvent](ctx)
	observer := broadcaster.Subscribe(1)
	group := &groupState{
		tag:       "auto",
		outbounds: map[string]struct{}{"server": {}},
		observer:  broadcaster,
	}
	monitor := &OutboundMonitoring{
		ctx: ctx,
		outbounds: map[string]*outboundState{
			"server": {
				groupTags: []string{"auto"},
				history:   adapter.URLTestHistory{Time: time.Now()},
			},
		},
		groups: map[string]*groupState{"auto": group},
		logger: log.NewNOPFactory().NewLogger("monitoring-test"),
	}

	// Occupy the one-slot observer buffer so the direct completed-batch event
	// is dropped by the non-blocking broadcaster.
	broadcaster.Publish(GroupEvent{GroupTag: "auto"})
	monitor.publishCompletedBatch(7, 2, []string{"server"})
	<-observer

	// Any later debounced/final snapshot must retain the latest completed batch
	// generation so Smart Active still performs the progressive comparison.
	monitor.emitGroupEventThrottled("auto", time.Time{})
	select {
	case event := <-observer:
		if !event.BatchCompleted || event.Generation != 7 || event.BatchNumber != 2 {
			t.Fatalf("batch metadata lost after dropped direct event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("missing completed-batch backstop event")
	}
}
