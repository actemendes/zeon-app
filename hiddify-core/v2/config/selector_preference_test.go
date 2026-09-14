package config

import (
	"encoding/json"
	"time"

	"github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"testing"
)

func TestPreferredSelectionAppliedAfterSyntheticGroupsAreBuilt(t *testing.T) {
	for _, tc := range []struct {
		name, preferred, want string
		prefer                bool
	}{
		{"baseline", "", "balance", false},
		{"offline Auto", "balance", "balance", true},
		{"offline manual", "two", "two", true},
		{"removed server", "removed", "balance", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			opts := DefaultHiddifyOptions()
			payload, _ := json.Marshal(map[string]string{"preferred-selector-outbound": tc.preferred})
			if err := json.Unmarshal(payload, opts); err != nil {
				t.Fatal(err)
			}
			built, err := BuildConfig(testConfigContext(), opts, &ReadOptions{Content: `{"outbounds":[{"type":"direct","tag":"one"},{"type":"direct","tag":"two"}]}`})
			if err != nil {
				t.Fatal(err)
			}
			for _, outbound := range built.Outbounds {
				if outbound.Tag != OutboundSelectTag {
					continue
				}
				selector := outbound.Options.(*option.SelectorOutboundOptions)
				if selector.Default != tc.want || selector.ZeonPreferDefault != tc.prefer {
					t.Fatalf("default=%s prefer=%v, want %s/%v", selector.Default, selector.ZeonPreferDefault, tc.want, tc.prefer)
				}
				return
			}
			t.Fatal("generated selector missing")
		})
	}
}

func TestIPv6ModeIsPropagatedToMonitoringAndGroups(t *testing.T) {
	opts := DefaultHiddifyOptions()
	opts.IPv6Mode = option.DomainStrategy(constant.DomainStrategyIPv6Only)
	opts.EnableClashApi = false
	built, err := BuildConfig(testConfigContext(), opts, &ReadOptions{Content: `{"outbounds":[{"type":"direct","tag":"one"},{"type":"direct","tag":"two"}]}`})
	if err != nil {
		t.Fatal(err)
	}
	if built.Experimental == nil || built.Experimental.Monitoring == nil {
		t.Fatal("generated IPv6 capability monitoring is missing")
	}
	if built.Experimental.ClashAPI != nil {
		t.Fatal("capability monitoring unexpectedly enabled the Clash API")
	}
	monitoring := built.Experimental.Monitoring
	if monitoring.IPv6Mode != opts.IPv6Mode || monitoring.IPv6CapabilityTTL.Build() != 10*time.Minute {
		t.Fatalf("monitoring IPv6 contract = mode %v ttl %v", monitoring.IPv6Mode, monitoring.IPv6CapabilityTTL.Build())
	}
	seenSelector, seenSmartActive := false, false
	for _, outbound := range built.Outbounds {
		switch outbound.Tag {
		case OutboundSelectTag:
			selector := outbound.Options.(*option.SelectorOutboundOptions)
			seenSelector = selector.IPv6Mode == opts.IPv6Mode && selector.IPv6CapabilityTTL.Build() == 10*time.Minute
		case OutboundRoundRobinTag:
			balancer := outbound.Options.(*option.BalancerOutboundOptions)
			seenSmartActive = balancer.IPv6Mode == opts.IPv6Mode && balancer.IPv6CapabilityTTL.Build() == 10*time.Minute
		}
	}
	if !seenSelector || !seenSmartActive {
		t.Fatalf("IPv6 mode propagation missing: selector=%v smart_active=%v", seenSelector, seenSmartActive)
	}
}
