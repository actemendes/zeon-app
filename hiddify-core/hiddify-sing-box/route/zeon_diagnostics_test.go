package route

import (
	"bytes"
	"context"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	healthmonitoring "github.com/sagernet/sing-box/common/monitoring"
	boxlog "github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

func TestZeonDestinationForLogDoesNotExposeDomain(t *testing.T) {
	metadata := adapter.InboundContext{
		Destination: M.ParseSocksaddr("video.example:443"),
	}

	destinationIP, destinationHash, dnsType := zeonDestinationForLog(metadata)
	if destinationIP != "" {
		t.Fatalf("domain destination leaked as ip: %q", destinationIP)
	}
	if destinationHash == "" || destinationHash == "video.example" {
		t.Fatalf("domain hash not sanitized: %q", destinationHash)
	}
	if dnsType != "unknown" {
		t.Fatalf("dns type = %q, want unknown without resolved addresses", dnsType)
	}
}

func TestZeonTrafficDiagnosticFlagsRespectMonitoringOptions(t *testing.T) {
	if zeonTrafficHooksDisabled(context.Background()) {
		t.Fatalf("traffic hooks should be enabled by default")
	}
	if zeonTrafficTraceEnabled(context.Background()) {
		t.Fatalf("traffic trace should be disabled by default")
	}

	monitor, err := healthmonitoring.NewOutboundMonitoring(
		context.Background(),
		boxlog.NewNOPFactory().Logger(),
		option.MonitoringOptions{DisableTrafficHooks: true, TraceTrafficRoute: true},
	)
	if err != nil {
		t.Fatalf("new monitoring: %v", err)
	}
	defer monitor.Close()
	ctx := service.ContextWithPtr(context.Background(), monitor)
	if zeonTrafficHooksDisabled(context.Background()) {
		t.Fatalf("plain context should keep hooks enabled")
	}
	if !zeonTrafficHooksDisabled(ctx) {
		t.Fatalf("traffic hooks option flag not honored")
	}
	if !zeonTrafficTraceEnabled(ctx) {
		t.Fatalf("traffic trace option flag not honored")
	}
}

func TestConnectionCopyIsTransparentWhenTrafficHooksDisabled(t *testing.T) {
	sourceRead, sourceWrite := net.Pipe()
	destinationRead, destinationWrite := net.Pipe()
	defer sourceRead.Close()
	defer sourceWrite.Close()
	defer destinationRead.Close()
	defer destinationWrite.Close()

	payload := bytes.Repeat([]byte("zeon-stream-"), 8192)
	metadata := adapter.InboundContext{
		Destination: M.ParseSocksaddr("203.0.113.10:443"),
	}
	metadata.SetRealOutbound("manual-leaf")
	monitor, err := healthmonitoring.NewOutboundMonitoring(
		context.Background(),
		boxlog.NewNOPFactory().Logger(),
		option.MonitoringOptions{DisableTrafficHooks: true},
	)
	if err != nil {
		t.Fatalf("new monitoring: %v", err)
	}
	defer monitor.Close()
	ctx := adapter.WithContext(service.ContextWithPtr(context.Background(), monitor), &metadata)

	manager := NewConnectionManager(boxlog.NewNOPFactory().Logger())
	var done atomic.Bool
	copyDone := make(chan struct{})
	go func() {
		manager.connectionCopy(ctx, sourceRead, destinationWrite, false, &done, func(error) {}, 1, nil)
		close(copyDone)
	}()

	writeDone := make(chan error, 1)
	go func() {
		_, err := sourceWrite.Write(payload)
		_ = sourceWrite.Close()
		writeDone <- err
	}()

	got := make([]byte, len(payload))
	if _, err := io.ReadFull(destinationRead, got); err != nil {
		t.Fatalf("read copied payload: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("copied payload changed")
	}
	if err := <-writeDone; err != nil {
		t.Fatalf("write payload: %v", err)
	}

	select {
	case <-copyDone:
	case <-time.After(time.Second):
		t.Fatalf("copy did not finish after source close")
	}
}

func resetZeonCompatibilityForTest() {
	zeonCompatibility.mu.Lock()
	defer zeonCompatibility.mu.Unlock()
	zeonCompatibility.quicFallback = make(map[string]zeonCompatibilityEntry)
	zeonCompatibility.quicEvidence = make(map[string]int)
	zeonCompatibility.ipv4Fallback = make(map[string]zeonCompatibilityEntry)
	zeonCompatibility.ipv6Failures = make(map[string]int)
	zeonCompatibility.ipv4Succeeded = make(map[string]bool)
}

func TestAdaptiveQuicFallbackNeedsRepeatedEvidence(t *testing.T) {
	resetZeonCompatibilityForTest()
	metadata := adapter.InboundContext{
		Network:     "udp",
		Destination: M.ParseSocksaddr("203.0.113.10:443"),
	}
	metadata.SetRealOutbound("manual-leaf")
	ctx := adapter.WithContext(context.Background(), &metadata)

	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, metadata, 8*1024, 0, 6*time.Second)
	if err := zeonRejectByAdaptiveQUICFallback(boxlog.NewNOPFactory().Logger(), ctx, metadata); err != nil {
		t.Fatalf("single evidence enabled QUIC fallback: %v", err)
	}

	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, metadata, 8*1024, 0, 6*time.Second)
	if err := zeonRejectByAdaptiveQUICFallback(boxlog.NewNOPFactory().Logger(), ctx, metadata); err == nil {
		t.Fatalf("repeated QUIC stall did not enable fallback")
	}
}

func TestAdaptiveQuicFallbackIsDestinationScoped(t *testing.T) {
	resetZeonCompatibilityForTest()
	first := adapter.InboundContext{Network: "udp", Destination: M.ParseSocksaddr("203.0.113.10:443")}
	first.SetRealOutbound("manual-leaf")
	second := adapter.InboundContext{Network: "udp", Destination: M.ParseSocksaddr("203.0.113.11:443")}
	second.SetRealOutbound("manual-leaf")
	ctx := context.Background()

	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, first, 8*1024, 0, 6*time.Second)
	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, first, 8*1024, 0, 6*time.Second)

	if err := zeonRejectByAdaptiveQUICFallback(boxlog.NewNOPFactory().Logger(), ctx, first); err == nil {
		t.Fatalf("first destination should be in QUIC fallback")
	}
	if err := zeonRejectByAdaptiveQUICFallback(boxlog.NewNOPFactory().Logger(), ctx, second); err != nil {
		t.Fatalf("fallback leaked to another destination: %v", err)
	}
}

func TestAdaptiveQuicFallbackRecoversOnDownload(t *testing.T) {
	resetZeonCompatibilityForTest()
	metadata := adapter.InboundContext{Network: "udp", Destination: M.ParseSocksaddr("203.0.113.10:443")}
	metadata.SetRealOutbound("manual-leaf")
	ctx := context.Background()

	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, metadata, 8*1024, 0, 6*time.Second)
	zeonObserveTrafficProgress(boxlog.NewNOPFactory().Logger(), ctx, metadata, 8*1024, 0, 6*time.Second)
	zeonObserveTrafficDownload(boxlog.NewNOPFactory().Logger(), ctx, metadata)

	if err := zeonRejectByAdaptiveQUICFallback(boxlog.NewNOPFactory().Logger(), ctx, metadata); err != nil {
		t.Fatalf("successful QUIC download should clear fallback: %v", err)
	}
}

func BenchmarkTrafficHookTrackerAdd(b *testing.B) {
	metadata := adapter.InboundContext{Network: "udp", Destination: M.ParseSocksaddr("203.0.113.10:443")}
	metadata.SetRealOutbound("manual-leaf")
	tracker := &zeonTrafficTracker{
		ctx:          context.Background(),
		connectionID: 1,
		metadata:     metadata,
		startedAt:    time.Now(),
		done:         make(chan struct{}),
	}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		tracker.add(false, 1200)
		tracker.add(true, 1200)
	}
}
