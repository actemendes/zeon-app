package monitoring

import (
	"context"
	"testing"

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
