package route

import (
	"context"
	"fmt"
	"net/netip"
	"sort"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
)

const (
	zeonQuicFallbackTTL           = 10 * time.Minute
	zeonIPFamilyFallbackTTL       = 10 * time.Minute
	zeonQuicStallEvidenceNeeded   = 2
	zeonIPv6FailureEvidenceNeeded = 3
	zeonQuicStallMinUploadBytes   = 4 * 1024
	zeonQuicStallMinDuration      = 5 * time.Second
)

type zeonCompatibilityEntry struct {
	expiresAt time.Time
	evidence  int
	leaf      string
}

type zeonNetworkCompatibilityManager struct {
	mu            sync.Mutex
	quicFallback  map[string]zeonCompatibilityEntry
	quicEvidence  map[string]int
	ipv4Fallback  map[string]zeonCompatibilityEntry
	ipv6Failures  map[string]int
	ipv4Succeeded map[string]bool
}

var zeonCompatibility = &zeonNetworkCompatibilityManager{
	quicFallback:  make(map[string]zeonCompatibilityEntry),
	quicEvidence:  make(map[string]int),
	ipv4Fallback:  make(map[string]zeonCompatibilityEntry),
	ipv6Failures:  make(map[string]int),
	ipv4Succeeded: make(map[string]bool),
}

func zeonCompatibilityEnabled(ctx context.Context) bool {
	return !zeonTrafficHooksDisabled(ctx)
}

func zeonIsQUICLike(metadata adapter.InboundContext) bool {
	return metadata.Network == N.NetworkUDP && metadata.Destination.Port == 443 &&
		(metadata.Protocol == "" || metadata.Protocol == C.ProtocolQUIC || metadata.Protocol == "quic")
}

func zeonCompatibilityDestinationHash(metadata adapter.InboundContext) string {
	if metadata.Destination.Fqdn != "" {
		return zeonShortHash(metadata.Destination.Fqdn)
	}
	if metadata.Destination.IsIP() {
		return zeonShortHash(metadata.Destination.Addr.String())
	}
	return "unknown"
}

func zeonCompatibilityKey(metadata adapter.InboundContext) string {
	return zeonCompatibilityDestinationHash(metadata) + "|" + fmt.Sprint(metadata.Destination.Port)
}

func zeonTemporaryQuicRejectError(metadata adapter.InboundContext) error {
	return E.New("adaptive QUIC fallback: temporary UDP/443 reject for destination ", zeonCompatibilityDestinationHash(metadata))
}

func zeonRejectByAdaptiveQUICFallback(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext) error {
	if !zeonCompatibilityEnabled(ctx) || !zeonIsQUICLike(metadata) {
		return nil
	}
	if !zeonCompatibility.quicFallbackActive(zeonCompatibilityKey(metadata), time.Now()) {
		return nil
	}
	hash := zeonCompatibilityDestinationHash(metadata)
	if logger != nil {
		logger.WarnContext(ctx, "[AdaptiveQuicFallback] destination_hash=", hash,
			" leaf=", metadata.GetRealOutbound(),
			" evidence=active_ttl",
			" action=temporary_udp443_reject ttl=active")
	}
	return zeonTemporaryQuicRejectError(metadata)
}

func (m *zeonNetworkCompatibilityManager) quicFallbackActive(key string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, ok := m.quicFallback[key]
	if !ok {
		return false
	}
	if now.After(entry.expiresAt) {
		delete(m.quicFallback, key)
		delete(m.quicEvidence, key)
		return false
	}
	return true
}

func zeonObserveTrafficDownload(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext) {
	if !zeonCompatibilityEnabled(ctx) || !zeonIsQUICLike(metadata) {
		return
	}
	zeonCompatibility.clearQUICFallback(logger, ctx, metadata, "successful_quic_download")
}

func zeonObserveTrafficProgress(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, uploadBytes int64, downloadBytes int64, duration time.Duration) {
	if !zeonCompatibilityEnabled(ctx) || !zeonIsQUICLike(metadata) {
		return
	}
	if uploadBytes < zeonQuicStallMinUploadBytes || downloadBytes > 0 || duration < zeonQuicStallMinDuration {
		return
	}
	zeonCompatibility.recordQUICStall(logger, ctx, metadata, "upload_without_download")
}

func zeonObserveTrafficClose(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, uploadBytes int64, downloadBytes int64, duration time.Duration, err error) {
	if !zeonCompatibilityEnabled(ctx) || !zeonIsQUICLike(metadata) {
		return
	}
	if downloadBytes > 0 {
		zeonCompatibility.clearQUICFallback(logger, ctx, metadata, "successful_quic_close")
		return
	}
	if uploadBytes < zeonQuicStallMinUploadBytes || duration < zeonQuicStallMinDuration {
		return
	}
	if err == nil {
		return
	}
	errorType, _ := urltest.ClassifyProbeError(err)
	switch errorType {
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeQUICTimeout, urltest.ErrorTypeEOF, urltest.ErrorTypeReset:
		zeonCompatibility.recordQUICStall(logger, ctx, metadata, "close_"+errorType)
	}
}

func (m *zeonNetworkCompatibilityManager) recordQUICStall(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, evidence string) {
	key := zeonCompatibilityKey(metadata)
	now := time.Now()
	hash := zeonCompatibilityDestinationHash(metadata)
	leaf := metadata.GetRealOutbound()

	m.mu.Lock()
	m.pruneLocked(now)
	if entry, ok := m.quicFallback[key]; ok && now.Before(entry.expiresAt) {
		m.mu.Unlock()
		return
	}
	m.quicEvidence[key]++
	count := m.quicEvidence[key]
	if count < zeonQuicStallEvidenceNeeded {
		m.mu.Unlock()
		return
	}
	m.quicFallback[key] = zeonCompatibilityEntry{
		expiresAt: now.Add(zeonQuicFallbackTTL),
		evidence:  count,
		leaf:      leaf,
	}
	m.mu.Unlock()

	if logger != nil {
		logger.WarnContext(ctx, "[AdaptiveQuicFallback] destination_hash=", hash,
			" leaf=", leaf,
			" evidence=", evidence,
			" attempts=", count,
			" action=temporary_udp443_reject ttl=", zeonQuicFallbackTTL)
	}
}

func (m *zeonNetworkCompatibilityManager) clearQUICFallback(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, reason string) {
	key := zeonCompatibilityKey(metadata)
	m.mu.Lock()
	_, hadFallback := m.quicFallback[key]
	delete(m.quicFallback, key)
	delete(m.quicEvidence, key)
	m.mu.Unlock()
	if hadFallback && logger != nil {
		logger.InfoContext(ctx, "[AdaptiveQuicFallback] destination_hash=", zeonCompatibilityDestinationHash(metadata),
			" leaf=", metadata.GetRealOutbound(),
			" evidence=successful_quic",
			" action=recovered reason=", reason)
	}
}

func zeonApplyIPFamilyFallback(logger logger.ContextLogger, ctx context.Context, metadata *adapter.InboundContext) {
	if metadata == nil || !zeonCompatibilityEnabled(ctx) {
		return
	}
	key := zeonCompatibilityKey(*metadata)
	if !zeonCompatibility.ipv4FallbackActive(key, time.Now()) {
		return
	}
	if len(metadata.DestinationAddresses) < 2 {
		return
	}
	sort.SliceStable(metadata.DestinationAddresses, func(i, j int) bool {
		left := metadata.DestinationAddresses[i]
		right := metadata.DestinationAddresses[j]
		if left.Is4() != right.Is4() {
			return left.Is4()
		}
		return false
	})
	if logger != nil {
		logger.WarnContext(ctx, "[IPFamilyFallback] destination_hash=", zeonCompatibilityDestinationHash(*metadata),
			" leaf=", metadata.GetRealOutbound(),
			" action=prefer_ipv4_temporarily ttl=active")
	}
}

func (m *zeonNetworkCompatibilityManager) ipv4FallbackActive(key string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, ok := m.ipv4Fallback[key]
	if !ok {
		return false
	}
	if now.After(entry.expiresAt) {
		delete(m.ipv4Fallback, key)
		delete(m.ipv6Failures, key)
		delete(m.ipv4Succeeded, key)
		return false
	}
	return true
}

func zeonObserveConnectFailure(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, err error) {
	if !zeonCompatibilityEnabled(ctx) || err == nil {
		return
	}
	if !zeonConnectionWasIPv6(metadata) {
		return
	}
	errorType, _ := urltest.ClassifyProbeError(err)
	switch errorType {
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeQUICTimeout:
	default:
		return
	}
	zeonCompatibility.recordIPv6Failure(logger, ctx, metadata)
}

func zeonObserveConnectSuccess(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext) {
	if !zeonCompatibilityEnabled(ctx) {
		return
	}
	if zeonConnectionWasIPv4(metadata) {
		zeonCompatibility.recordIPv4Success(logger, ctx, metadata)
		return
	}
	if zeonConnectionWasIPv6(metadata) {
		zeonCompatibility.clearIPv4Fallback(logger, ctx, metadata, "ipv6_success")
	}
}

func zeonConnectionWasIPv4(metadata adapter.InboundContext) bool {
	if metadata.Destination.IsIP() {
		return metadata.Destination.Addr.Is4()
	}
	for _, address := range metadata.DestinationAddresses {
		if address.Is4() {
			return true
		}
	}
	return false
}

func zeonConnectionWasIPv6(metadata adapter.InboundContext) bool {
	if metadata.Destination.IsIP() {
		return metadata.Destination.Addr.Is6()
	}
	has6 := false
	has4 := false
	for _, address := range metadata.DestinationAddresses {
		has4 = has4 || address.Is4()
		has6 = has6 || address.Is6()
	}
	return has6 && !has4
}

func (m *zeonNetworkCompatibilityManager) recordIPv4Success(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext) {
	key := zeonCompatibilityKey(metadata)
	m.mu.Lock()
	m.ipv4Succeeded[key] = true
	failures := m.ipv6Failures[key]
	if failures >= zeonIPv6FailureEvidenceNeeded {
		m.ipv4Fallback[key] = zeonCompatibilityEntry{
			expiresAt: time.Now().Add(zeonIPFamilyFallbackTTL),
			evidence:  failures,
			leaf:      metadata.GetRealOutbound(),
		}
	}
	m.mu.Unlock()
}

func (m *zeonNetworkCompatibilityManager) recordIPv6Failure(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext) {
	key := zeonCompatibilityKey(metadata)
	now := time.Now()
	hash := zeonCompatibilityDestinationHash(metadata)
	leaf := metadata.GetRealOutbound()

	m.mu.Lock()
	m.pruneLocked(now)
	m.ipv6Failures[key]++
	failures := m.ipv6Failures[key]
	ipv4Success := m.ipv4Succeeded[key]
	if failures < zeonIPv6FailureEvidenceNeeded || !ipv4Success {
		m.mu.Unlock()
		return
	}
	m.ipv4Fallback[key] = zeonCompatibilityEntry{
		expiresAt: now.Add(zeonIPFamilyFallbackTTL),
		evidence:  failures,
		leaf:      leaf,
	}
	m.mu.Unlock()

	if logger != nil {
		logger.WarnContext(ctx, "[IPFamilyFallback] destination_hash=", hash,
			" leaf=", leaf,
			" ipv6_failures=", failures,
			" ipv4_success=", ipv4Success,
			" action=prefer_ipv4_temporarily ttl=", zeonIPFamilyFallbackTTL)
	}
}

func (m *zeonNetworkCompatibilityManager) clearIPv4Fallback(logger logger.ContextLogger, ctx context.Context, metadata adapter.InboundContext, reason string) {
	key := zeonCompatibilityKey(metadata)
	m.mu.Lock()
	_, hadFallback := m.ipv4Fallback[key]
	delete(m.ipv4Fallback, key)
	delete(m.ipv6Failures, key)
	delete(m.ipv4Succeeded, key)
	m.mu.Unlock()
	if hadFallback && logger != nil {
		logger.InfoContext(ctx, "[IPFamilyFallback] destination_hash=", zeonCompatibilityDestinationHash(metadata),
			" leaf=", metadata.GetRealOutbound(),
			" action=recovered reason=", reason)
	}
}

func (m *zeonNetworkCompatibilityManager) pruneLocked(now time.Time) {
	for key, entry := range m.quicFallback {
		if now.After(entry.expiresAt) {
			delete(m.quicFallback, key)
			delete(m.quicEvidence, key)
		}
	}
	for key, entry := range m.ipv4Fallback {
		if now.After(entry.expiresAt) {
			delete(m.ipv4Fallback, key)
			delete(m.ipv6Failures, key)
			delete(m.ipv4Succeeded, key)
		}
	}
}

func zeonTestAddr(value string) netip.Addr {
	addr, _ := netip.ParseAddr(value)
	return addr
}
