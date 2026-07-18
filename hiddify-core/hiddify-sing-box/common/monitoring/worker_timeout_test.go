package monitoring

import (
	"context"
	"errors"
	"net"
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
}

func newBlockingMonitoringTestOutbound(tag string, release <-chan struct{}) adapter.Outbound {
	return &blockingMonitoringTestOutbound{
		Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP}, nil),
		release: release,
	}
}

func (o *blockingMonitoringTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	<-o.release
	return nil, errors.New("released blocking test outbound")
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
