package balancer

import (
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

func TestRoundRobinStillRotatesWhenSelected(t *testing.T) {
	outbounds := []adapter.Outbound{
		newSmartActiveTestOutbound("first"),
		newSmartActiveTestOutbound("second"),
	}
	strategy := NewRoundRobin(outbounds, option.BalancerOutboundOptions{DelayAcceptableRatio: 2})
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"first":  healthyHistory(80),
		"second": healthyHistory(90),
	})
	seen := make(map[string]bool)
	for i := 0; i < 4; i++ {
		selected := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true)
		if selected == nil {
			t.Fatal("round robin returned nil")
		}
		seen[selected.Tag()] = true
	}
	if !seen["first"] || !seen["second"] {
		t.Fatalf("round robin did not preserve rotation: %v", seen)
	}
}

func TestLowestDelayStrategyStillSelectsLowestDelay(t *testing.T) {
	outbounds := []adapter.Outbound{
		newSmartActiveTestOutbound("slow"),
		newSmartActiveTestOutbound("fast"),
	}
	strategy := NewLowestDelay(outbounds, option.BalancerOutboundOptions{})
	if !strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"slow": healthyHistory(300),
		"fast": healthyHistory(50),
	}) {
		t.Fatal("expected lowest-delay selection to change")
	}
	if strategy.Now() != "fast" {
		t.Fatalf("selected %s, want fast", strategy.Now())
	}
}

func TestLowestDelayColdStartPrefersForeignOutbound(t *testing.T) {
	outbounds := []adapter.Outbound{
		newSmartActiveTestOutbound("🇷🇺Россия8 | СВЯЗЬ"),
		newSmartActiveTestOutbound("🇳🇱Нидерланды3 | СВЯЗЬ"),
	}
	strategy := NewLowestDelay(outbounds, option.BalancerOutboundOptions{})
	if got := strategy.Now(); got != "🇳🇱Нидерланды3 | СВЯЗЬ" {
		t.Fatalf("cold start selected %q, want foreign outbound", got)
	}
}
