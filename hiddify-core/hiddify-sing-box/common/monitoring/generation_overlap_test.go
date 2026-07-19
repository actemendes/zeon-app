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
