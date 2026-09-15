package balancer

import (
	"net/netip"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
)

func ipv6History(delay uint16, supported bool) *adapter.URLTestHistory {
	history := healthyHistory(delay)
	history.IPv6Generation = history.CheckGeneration
	history.IPv6CheckedAt = time.Now()
	if supported {
		history.IPv6Status = monitoring.IPv6StatusSupported
		history.IPv6TargetSuccess = 2
		history.IPv6TargetCount = 2
	} else {
		history.IPv6Status = monitoring.IPv6StatusUnavailable
		history.IPv6TargetCount = 2
	}
	return history
}

func newIPv6SmartActive(mode C.DomainStrategy) *SmartActive {
	return NewSmartActive([]adapter.Outbound{
		newSmartActiveTestOutbound("fast-v4"),
		newSmartActiveTestOutbound("slower-v6"),
	}, option.BalancerOutboundOptions{IPv6Mode: option.DomainStrategy(mode)})
}

func TestSmartActivePreferIPv6UsesConfirmedPoolFirst(t *testing.T) {
	strategy := newIPv6SmartActive(C.DomainStrategyPreferIPv6)
	history := map[string]*adapter.URLTestHistory{
		"fast-v4":   ipv6History(20, false),
		"slower-v6": ipv6History(100, true),
	}
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "slower-v6" {
		t.Fatalf("prefer_ipv6 selected %q, want confirmed IPv6 leaf", got)
	}
}

func TestSmartActivePreferIPv6FallsBackInsideVPN(t *testing.T) {
	strategy := newIPv6SmartActive(C.DomainStrategyPreferIPv6)
	history := map[string]*adapter.URLTestHistory{
		"fast-v4":   ipv6History(20, false),
		"slower-v6": ipv6History(100, false),
	}
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "fast-v4" {
		t.Fatalf("prefer_ipv6 fallback selected %q, want normal best VPN leaf", got)
	}
}

func TestSmartActiveIPv6OnlyHasNoHiddenIPv4Fallback(t *testing.T) {
	strategy := newIPv6SmartActive(C.DomainStrategyIPv6Only)
	history := map[string]*adapter.URLTestHistory{
		"fast-v4":   ipv6History(20, false),
		"slower-v6": ipv6History(100, false),
	}
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "" {
		t.Fatalf("ipv6_only selected unverified leaf %q", got)
	}

	history["slower-v6"] = ipv6History(100, true)
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "slower-v6" {
		t.Fatalf("ipv6_only selected %q after proof", got)
	}
	metadata4 := adapter.InboundContext{IPVersion: 4, Destination: M.SocksaddrFrom(netip.MustParseAddr("192.0.2.1"), 443)}
	if selected := strategy.Select(metadata4, "tcp", true); selected != nil {
		t.Fatalf("ipv6_only exposed IPv4 fallback through %q", selected.Tag())
	}
}

func TestSmartActiveIPv6OnlyRejectsPartialCapabilityProof(t *testing.T) {
	strategy := newIPv6SmartActive(C.DomainStrategyIPv6Only)
	partial := ipv6History(25, true)
	partial.IPv6TargetSuccess = 1
	history := map[string]*adapter.URLTestHistory{
		"fast-v4":   ipv6History(20, false),
		"slower-v6": partial,
	}
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "" {
		t.Fatalf("ipv6_only selected partial-proof leaf %q", got)
	}

	partial.IPv6TargetSuccess = partial.IPv6TargetCount
	strategy.UpdateOutboundsInfoForCompletedBatch(history, smartActiveTestGeneration)
	if got := strategy.Now(); got != "slower-v6" {
		t.Fatalf("ipv6_only selected %q after complete proof", got)
	}
}
