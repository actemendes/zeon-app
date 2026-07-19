package monitoring

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
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

type activeProbeTestOutbound struct {
	adapterOutbound.Adapter
	dials atomic.Int32
	fail  bool
}

func newActiveProbeTestOutbound(tag string) *activeProbeTestOutbound {
	return &activeProbeTestOutbound{Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)}
}

func (o *activeProbeTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	o.dials.Add(1)
	if o.fail {
		return nil, context.DeadlineExceeded
	}
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			return
		}
		request.Body.Close()
		time.Sleep(2 * time.Millisecond)
		_, _ = io.WriteString(server, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
	}()
	return client, nil
}

func (*activeProbeTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("UDP disabled in this test")
}

func TestLightweightActiveUDPOptionsStaySmall(t *testing.T) {
	options := lightweightActiveUDPOptions(urltest.UDPProbeOptions{
		Count:    10,
		Size:     1200,
		Interval: 200 * time.Millisecond,
		Timeout:  2 * time.Second,
	})
	if options.Count != activeUDPProbeCount || options.Size != activeUDPProbeSize {
		t.Fatalf("active UDP payload is not bounded: %+v", options)
	}
	if options.Interval != activeUDPProbeGap || options.Timeout != activeUDPProbeWait {
		t.Fatalf("active UDP timing is not bounded: %+v", options)
	}
}

func TestLightweightActiveUDPOptionsKeepSmallerConfiguration(t *testing.T) {
	want := urltest.UDPProbeOptions{
		Count:    2,
		Size:     96,
		Interval: 10 * time.Millisecond,
		Timeout:  250 * time.Millisecond,
	}
	if got := lightweightActiveUDPOptions(want); got != want {
		t.Fatalf("smaller configured probe changed: got=%+v want=%+v", got, want)
	}
}

func TestActiveURLProbeHardTimeoutReturnsWithoutWaitingForDialer(t *testing.T) {
	started := time.Now()
	_, err, timedOut := runActiveURLTestWithHardTimeout(context.Background(), 20*time.Millisecond, func(context.Context) (uint16, error) {
		time.Sleep(250 * time.Millisecond)
		return 0, errors.New("late failure")
	})
	if !timedOut || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timedOut=%v err=%v, want hard timeout", timedOut, err)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("active URL probe returned too late: %v", elapsed)
	}
}

func TestActiveProbeUsesOnlyRequestedOutboundAndKeepsRankingHistoryIsolated(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	active := newActiveProbeTestOutbound("active")
	other := newActiveProbeTestOutbound("other")
	// Use the production formatter here: unlike the NOP logger it rejects raw
	// float values and therefore guards the Android logging path from panics.
	strictLogger := log.NewDefaultFactory(ctx, log.Formatter{}, io.Discard, "", nil, false).NewLogger("active-probe-test")
	monitor := &OutboundMonitoring{
		ctx:            ctx,
		logger:         strictLogger,
		urls:           []string{"http://probe.invalid/generate_204"},
		urlTestTimeout: time.Second,
		outbounds: map[string]*outboundState{
			"active": {outbound: active, history: adapter.URLTestHistory{Delay: 777, CheckGeneration: 4}},
			"other":  {outbound: other, history: adapter.URLTestHistory{Delay: 888, CheckGeneration: 4}},
		},
		groups:         make(map[string]*groupState),
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
	}

	result, err := monitor.ProbeActiveOutbound(ctx, "active")
	if err != nil || !result.History.Success || result.History.Delay == 0 {
		t.Fatalf("active probe result=%+v err=%v", result, err)
	}
	if active.dials.Load() != 1 || other.dials.Load() != 0 {
		t.Fatalf("dial counts active=%d other=%d", active.dials.Load(), other.dials.Load())
	}
	if monitor.outbounds["active"].history.Delay != 777 || monitor.outbounds["other"].history.Delay != 888 {
		t.Fatal("isolated active probe mutated full-generation ranking history")
	}
}

func TestActiveProbeFailureReturnsDecisionEvidence(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	active := newActiveProbeTestOutbound("active")
	active.fail = true
	monitor := &OutboundMonitoring{
		ctx:            ctx,
		logger:         log.NewNOPFactory().NewLogger("active-probe-test"),
		urls:           []string{"http://probe.invalid/generate_204"},
		urlTestTimeout: time.Second,
		outbounds: map[string]*outboundState{
			"active": {outbound: active, history: adapter.URLTestHistory{CheckGeneration: 4}},
		},
		groups:         make(map[string]*groupState),
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
	}

	result, err := monitor.ProbeActiveOutbound(ctx, "active")
	if err == nil {
		t.Fatal("failing outbound returned nil error")
	}
	if result.History.Time.IsZero() || result.History.Success || result.History.ErrorType == "" || result.History.ErrorType == urltest.ErrorTypeNone {
		t.Fatalf("failure did not return usable decision evidence: %+v", result)
	}
}
