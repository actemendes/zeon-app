package monitoring

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	adapterOutbound "github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type blockingMonitoringTestOutbound struct {
	adapterOutbound.Adapter
	release <-chan struct{}
	started *atomic.Int32
}

func newBlockingMonitoringTestOutbound(tag string, release <-chan struct{}) adapter.Outbound {
	return &blockingMonitoringTestOutbound{
		Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP}, nil),
		release: release,
	}
}

func (o *blockingMonitoringTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	if o.started != nil {
		o.started.Add(1)
	}
	<-o.release
	return nil, errors.New("released blocking test outbound")
}

func newCountingBlockingMonitoringTestOutbound(tag string, release <-chan struct{}, started *atomic.Int32) adapter.Outbound {
	return &blockingMonitoringTestOutbound{
		Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP}, nil),
		release: release,
		started: started,
	}
}

func (*blockingMonitoringTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("packet connections are not supported")
}

func TestBackgroundWorkerHardTimeoutReleasesStuckOutbound(t *testing.T) {
	const tag = "stuck"
	release := make(chan struct{})
	defer close(release)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	outbound := newBlockingMonitoringTestOutbound(tag, release)
	monitor := &OutboundMonitoring{
		ctx:              ctx,
		logger:           log.NewNOPFactory().NewLogger("monitoring-test"),
		urls:             []string{defaultURLTest},
		urlTestTimeout:   25 * time.Millisecond,
		history:          urltest.NewHistoryStorage(),
		outbounds:        map[string]*outboundState{tag: {outbound: outbound, history: adapter.URLTestHistory{CheckGeneration: 1, URLTestStatus: urltest.StatusChecking}}},
		groups:           make(map[string]*groupState),
		runtimeStats:     make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic:   make(map[string]*adapter.RuntimeTrafficStats),
		udpProbeCooldown: defaultUDPCooldown,
	}
	resultCh := make(chan testOutcome, 1)
	task := &testTask{outboundTag: tag, cycleID: 1, resultCh: resultCh}

	startedAt := time.Now()
	monitor.executeTask(task)
	if elapsed := time.Since(startedAt); elapsed > 500*time.Millisecond {
		t.Fatalf("worker remained blocked for %v after its hard timeout", elapsed)
	}

	select {
	case outcome := <-resultCh:
		if outcome.err == nil {
			t.Fatal("timed-out outbound returned a successful outcome")
		}
	case <-time.After(time.Second):
		t.Fatal("worker did not report the timed-out outcome")
	}

	state := monitor.outbounds[tag]
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.testing || state.queued || state.priorityQueued {
		t.Fatal("timed-out outbound kept worker state marked as active")
	}
	if state.history.URLTestStatus != urltest.StatusFailed || !state.history.CombinedReady {
		t.Fatalf("timeout history status=%q combined_ready=%v, want failed and complete", state.history.URLTestStatus, state.history.CombinedReady)
	}
}

func TestTimedOutManualStageStopsBeforeNextSerializedRefresh(t *testing.T) {
	release := make(chan struct{})
	defer close(release)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var started atomic.Int32
	tags := []string{"first", "second"}
	monitor := &OutboundMonitoring{
		ctx:              ctx,
		logger:           log.NewNOPFactory().NewLogger("monitoring-test"),
		urls:             []string{defaultURLTest},
		urlTestTimeout:   time.Second,
		workersCount:     1,
		history:          urltest.NewHistoryStorage(),
		outbounds:        make(map[string]*outboundState),
		groups:           make(map[string]*groupState),
		runtimeStats:     make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic:   make(map[string]*adapter.RuntimeTrafficStats),
		udpProbeCooldown: defaultUDPCooldown,
	}
	for _, tag := range tags {
		monitor.outbounds[tag] = &outboundState{
			outbound: newCountingBlockingMonitoringTestOutbound(tag, release, &started),
			history:  adapter.URLTestHistory{CheckGeneration: 1, URLTestStatus: urltest.StatusChecking},
		}
	}

	report, err := monitor.runManualRefreshStage("group", 1, tags, 25*time.Millisecond)
	if err == nil || !report.timeout {
		t.Fatalf("report=%+v err=%v, want stage timeout", report, err)
	}
	if got := started.Load(); got != 1 {
		t.Fatalf("started targets=%d, want one; cancelled stage continued dequeuing", got)
	}
	for _, tag := range tags {
		state := monitor.outbounds[tag]
		state.mu.Lock()
		testing, queued := state.testing, state.queued
		state.mu.Unlock()
		if testing || queued {
			t.Fatalf("target %s remained active after stage cancellation: testing=%v queued=%v", tag, testing, queued)
		}
	}
}

func TestBackgroundStageDoesNotStartNextTenServerBatchEarly(t *testing.T) {
	const (
		workers = 10
		total   = 11
	)
	release := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	var started atomic.Int32
	monitor := &OutboundMonitoring{
		ctx:              ctx,
		logger:           log.NewNOPFactory().NewLogger("monitoring-test"),
		urls:             []string{defaultURLTest},
		urlTestTimeout:   2 * time.Second,
		workersCount:     workers,
		history:          urltest.NewHistoryStorage(),
		outbounds:        make(map[string]*outboundState),
		groups:           make(map[string]*groupState),
		runtimeStats:     make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic:   make(map[string]*adapter.RuntimeTrafficStats),
		priorityQueue:    make(chan *testTask, total),
		normalQueue:      make(chan *testTask, total),
		udpProbeCooldown: defaultUDPCooldown,
	}
	tags := make([]string, 0, total)
	for i := 0; i < total; i++ {
		tag := fmt.Sprintf("server-%02d", i)
		tags = append(tags, tag)
		monitor.outbounds[tag] = &outboundState{
			outbound: newCountingBlockingMonitoringTestOutbound(tag, release, &started),
			history:  adapter.URLTestHistory{CheckGeneration: 1, URLTestStatus: urltest.StatusChecking},
		}
	}
	for i := 0; i < workers; i++ {
		monitor.workerWG.Add(1)
		go monitor.workerLoop()
	}
	defer func() {
		cancel()
		select {
		case <-release:
		default:
			close(release)
		}
		monitor.workerWG.Wait()
	}()

	done := make(chan []testOutcome, 1)
	go func() { done <- monitor.runStage(1, tags) }()
	deadline := time.Now().Add(time.Second)
	for started.Load() < workers && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := started.Load(); got != workers {
		t.Fatalf("started=%d, want exactly first batch of %d", got, workers)
	}
	time.Sleep(30 * time.Millisecond)
	if got := started.Load(); got != workers {
		t.Fatalf("next batch started before first completed: dial starts=%d", got)
	}

	close(release)
	select {
	case outcomes := <-done:
		if len(outcomes) != total {
			t.Fatalf("outcomes=%d, want %d", len(outcomes), total)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("batched stage did not finish after releasing workers")
	}
}
