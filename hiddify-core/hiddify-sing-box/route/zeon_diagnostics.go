package route

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	healthmonitoring "github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
)

const zeonTrafficProgressInterval = 5 * time.Second

func zeonEnvEnabled(name string) bool {
	return false
}

func zeonTrafficHooksDisabled(ctx context.Context) bool {
	if monitor := healthmonitoring.Get(ctx); monitor != nil && monitor.RuntimeTrafficHooksDisabled() {
		return true
	}
	return false
}

func zeonTrafficTraceEnabled(ctx context.Context) bool {
	if monitor := healthmonitoring.Get(ctx); monitor != nil && monitor.TraceTrafficRouteEnabled() {
		return true
	}
	return false
}

func zeonOutboundTag(dialer N.Dialer) string {
	if outbound, ok := dialer.(adapter.Outbound); ok {
		return outbound.Tag()
	}
	return ""
}

func zeonShortHash(value string) string {
	if value == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:12]
}

func zeonProtocol(metadata adapter.InboundContext) string {
	if metadata.Protocol != "" {
		return metadata.Protocol
	}
	if metadata.Network == N.NetworkUDP && metadata.Destination.Port == 443 {
		return "quic"
	}
	if metadata.Network == N.NetworkTCP && metadata.Destination.Port == 443 {
		return "tls"
	}
	if protocol := C.PortProtocols[metadata.Destination.Port]; protocol != "" {
		return protocol
	}
	return ""
}

func zeonDestinationForLog(metadata adapter.InboundContext) (destinationIP string, destinationHash string, dnsType string) {
	if metadata.Destination.IsIP() {
		destinationIP = metadata.Destination.Addr.String()
	}
	if metadata.Destination.Fqdn != "" {
		destinationHash = zeonShortHash(metadata.Destination.Fqdn)
	}
	var hasA, hasAAAA bool
	for _, addr := range metadata.DestinationAddresses {
		if addr.Is4() {
			hasA = true
		} else if addr.Is6() {
			hasAAAA = true
		}
	}
	if !hasA && !hasAAAA && metadata.Destination.IsIP() {
		hasA = metadata.Destination.Addr.Is4()
		hasAAAA = metadata.Destination.Addr.Is6()
	}
	switch {
	case hasA && hasAAAA:
		dnsType = "A+AAAA"
	case hasA:
		dnsType = "A"
	case hasAAAA:
		dnsType = "AAAA"
	default:
		dnsType = "unknown"
	}
	return
}

func zeonIPVersionForLog(metadata adapter.InboundContext) string {
	if metadata.Destination.IsIP() {
		if metadata.Destination.Addr.Is4() {
			return "ipv4"
		}
		if metadata.Destination.Addr.Is6() {
			return "ipv6"
		}
	}
	var has4, has6 bool
	for _, addr := range metadata.DestinationAddresses {
		has4 = has4 || addr.Is4()
		has6 = has6 || addr.Is6()
	}
	switch {
	case has4 && has6:
		return "mixed"
	case has4:
		return "ipv4"
	case has6:
		return "ipv6"
	default:
		return "unknown"
	}
}

type zeonTrafficLogFields struct {
	event           string
	connectionID    uint64
	metadata        adapter.InboundContext
	selected        string
	leaf            string
	routeRule       string
	reason          string
	bytes           int64
	uploadBytes     int64
	downloadBytes   int64
	connectDuration time.Duration
	timeToFirstByte time.Duration
	duration        time.Duration
	lastDownloadAgo time.Duration
	err             error
}

func zeonDurationMillis(duration time.Duration) int64 {
	if duration <= 0 {
		return -1
	}
	return duration.Milliseconds()
}

func zeonLogTrafficEvent(logger logger.ContextLogger, ctx context.Context, category string, fields zeonTrafficLogFields) {
	if !zeonTrafficTraceEnabled(ctx) || logger == nil {
		return
	}
	leaf := fields.leaf
	if leaf == "" {
		leaf = fields.metadata.GetRealOutbound()
	}
	destinationIP, destinationHash, dnsType := zeonDestinationForLog(fields.metadata)
	errorType := ""
	if fields.err != nil {
		errorType, _ = urltest.ClassifyProbeError(fields.err)
	}
	logger.InfoContext(ctx, category,
		" event=", fields.event,
		" connection=", fields.connectionID,
		" inbound=", fields.metadata.Inbound,
		" network=", fields.metadata.Network,
		" destination_ip=", destinationIP,
		" destination_hash=", destinationHash,
		" port=", fields.metadata.Destination.Port,
		" protocol=", zeonProtocol(fields.metadata),
		" selected=", fields.selected,
		" leaf=", leaf,
		" route_rule=", fields.routeRule,
		" dns_type=", dnsType,
		" ip_version=", zeonIPVersionForLog(fields.metadata),
		" connect_duration_ms=", zeonDurationMillis(fields.connectDuration),
		" time_to_first_byte_ms=", zeonDurationMillis(fields.timeToFirstByte),
		" duration_ms=", zeonDurationMillis(fields.duration),
		" upload_bytes=", fields.uploadBytes,
		" download_bytes=", fields.downloadBytes,
		" bytes=", fields.bytes,
		" last_download_ago_ms=", zeonDurationMillis(fields.lastDownloadAgo),
		" reason=", fields.reason,
		" error_type=", errorType,
	)
}

func zeonLogTrafficRoute(logger logger.ContextLogger, ctx context.Context, fields zeonTrafficLogFields) {
	zeonLogTrafficEvent(logger, ctx, "[TrafficRoute]", fields)
}

func zeonLogTrafficConnect(logger logger.ContextLogger, ctx context.Context, fields zeonTrafficLogFields) {
	zeonLogTrafficEvent(logger, ctx, "[TrafficConnect]", fields)
}

func zeonRouteRuleLabel(selectedRule adapter.Rule) string {
	if selectedRule == nil {
		return "final"
	}
	action := selectedRule.Action()
	if action == nil {
		return selectedRule.Type()
	}
	return selectedRule.Type() + ":" + action.Type()
}

func zeonTraceRouteSelected(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, selectedRule adapter.Rule, selectedOutbound adapter.Outbound) {
	if selectedOutbound == nil {
		return
	}
	leaf := metadata.GetRealOutbound()
	if leaf == "" {
		if group, ok := selectedOutbound.(adapter.OutboundGroup); ok {
			leaf = group.Now()
		}
	}
	zeonLogTrafficRoute(logger, ctx, zeonTrafficLogFields{
		event:         "route_selected",
		metadata:      metadata,
		selected:      selectedOutbound.Tag(),
		leaf:          leaf,
		routeRule:     zeonRouteRuleLabel(selectedRule),
		uploadBytes:   -1,
		downloadBytes: -1,
	})
}

type zeonCountingReader struct {
	io.Reader
	counter N.CountFunc
}

func (r zeonCountingReader) UnwrapReader() (io.Reader, []N.CountFunc) {
	return r.Reader, []N.CountFunc{r.counter}
}

type zeonCountingPacketReader struct {
	N.PacketReader
	counter N.CountFunc
}

func (r zeonCountingPacketReader) UnwrapPacketReader() (N.PacketReader, []N.CountFunc) {
	return r.PacketReader, []N.CountFunc{r.counter}
}

type zeonTrafficTracker struct {
	logger          logger.ContextLogger
	ctx             context.Context
	connectionID    uint64
	metadata        adapter.InboundContext
	startedAt       time.Time
	done            chan struct{}
	closeOnce       sync.Once
	directionClosed atomic.Int32
	uploadBytes     atomic.Int64
	downloadBytes   atomic.Int64
	firstDownloadAt atomic.Int64
	lastDownloadAt  atomic.Int64
}

func zeonNewTrafficTracker(logger logger.ContextLogger, ctx context.Context, connectionID uint64, metadata adapter.InboundContext) *zeonTrafficTracker {
	if logger == nil {
		return nil
	}
	if !zeonTrafficTraceEnabled(ctx) && (!zeonCompatibilityEnabled(ctx) || !zeonIsQUICLike(metadata)) {
		return nil
	}
	tracker := &zeonTrafficTracker{
		logger:       logger,
		ctx:          ctx,
		connectionID: connectionID,
		metadata:     metadata,
		startedAt:    time.Now(),
		done:         make(chan struct{}),
	}
	go tracker.progressLoop()
	return tracker
}

func (t *zeonTrafficTracker) countFunc(download bool) N.CountFunc {
	if t == nil {
		return func(int64) {}
	}
	return func(n int64) {
		t.add(download, n)
	}
}

func (t *zeonTrafficTracker) add(download bool, n int64) {
	if t == nil || n <= 0 {
		return
	}
	now := time.Now()
	if download {
		t.downloadBytes.Add(n)
		nowUnix := now.UnixNano()
		t.lastDownloadAt.Store(nowUnix)
		if t.firstDownloadAt.CompareAndSwap(0, nowUnix) {
			zeonObserveTrafficDownload(t.logger, t.ctx, t.metadata)
			zeonLogTrafficEvent(t.logger, t.ctx, "[TrafficFirstByte]", zeonTrafficLogFields{
				event:           "first_download_byte",
				connectionID:    t.connectionID,
				metadata:        t.metadata,
				duration:        now.Sub(t.startedAt),
				timeToFirstByte: now.Sub(t.startedAt),
				uploadBytes:     t.uploadBytes.Load(),
				downloadBytes:   t.downloadBytes.Load(),
			})
		}
		return
	}
	t.uploadBytes.Add(n)
}

func (t *zeonTrafficTracker) progressLoop() {
	ticker := time.NewTicker(zeonTrafficProgressInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			t.logProgress()
		case <-t.done:
			return
		case <-t.ctx.Done():
			t.close("context_done", t.ctx.Err())
			return
		}
	}
}

func (t *zeonTrafficTracker) logProgress() {
	now := time.Now()
	lastDownloadAgo := time.Duration(-1)
	if last := t.lastDownloadAt.Load(); last > 0 {
		lastDownloadAgo = now.Sub(time.Unix(0, last))
	} else if t.uploadBytes.Load() > 0 {
		lastDownloadAgo = now.Sub(t.startedAt)
	}
	zeonLogTrafficEvent(t.logger, t.ctx, "[TrafficProgress]", zeonTrafficLogFields{
		event:           "progress",
		connectionID:    t.connectionID,
		metadata:        t.metadata,
		duration:        now.Sub(t.startedAt),
		uploadBytes:     t.uploadBytes.Load(),
		downloadBytes:   t.downloadBytes.Load(),
		lastDownloadAgo: lastDownloadAgo,
	})
	zeonObserveTrafficProgress(t.logger, t.ctx, t.metadata, t.uploadBytes.Load(), t.downloadBytes.Load(), now.Sub(t.startedAt))
}

func (t *zeonTrafficTracker) closeDirection(download bool, bytes int64, err error) {
	if t == nil {
		return
	}
	reason := "upload_closed"
	if download {
		reason = "download_closed"
	}
	if err != nil || t.directionClosed.Add(1) >= 2 {
		t.close(reason, err)
	}
}

func (t *zeonTrafficTracker) close(reason string, err error) {
	if t == nil {
		return
	}
	t.closeOnce.Do(func() {
		close(t.done)
		now := time.Now()
		lastDownloadAgo := time.Duration(-1)
		if last := t.lastDownloadAt.Load(); last > 0 {
			lastDownloadAgo = now.Sub(time.Unix(0, last))
		}
		firstByte := time.Duration(-1)
		if first := t.firstDownloadAt.Load(); first > 0 {
			firstByte = time.Unix(0, first).Sub(t.startedAt)
		}
		zeonLogTrafficEvent(t.logger, t.ctx, "[TrafficClose]", zeonTrafficLogFields{
			event:           "closed",
			connectionID:    t.connectionID,
			metadata:        t.metadata,
			duration:        now.Sub(t.startedAt),
			timeToFirstByte: firstByte,
			uploadBytes:     t.uploadBytes.Load(),
			downloadBytes:   t.downloadBytes.Load(),
			lastDownloadAgo: lastDownloadAgo,
			reason:          reason,
			err:             err,
		})
		zeonObserveTrafficClose(t.logger, t.ctx, t.metadata, t.uploadBytes.Load(), t.downloadBytes.Load(), now.Sub(t.startedAt), err)
	})
}
