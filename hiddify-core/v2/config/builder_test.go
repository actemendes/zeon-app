package config

import (
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestDefaultHiddifyOptionsAllowsBalancerMode(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	if hopt.RouteOptions.PinMainOutbound {
		t.Fatal("expected pin-main-outbound to be disabled by default so balance/lowest groups are visible")
	}
}

func TestSetOutboundsAddsBalanceWhenMainOutboundIsNotPinned(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.BalancerStrategy = "round-robin"

	input := &option.Options{
		Outbounds: []option.Outbound{
			{
				Type:    C.TypeDirect,
				Tag:     "proxy-a",
				Options: &option.DirectOutboundOptions{},
			},
			{
				Type:    C.TypeDirect,
				Tag:     "proxy-b",
				Options: &option.DirectOutboundOptions{},
			},
		},
	}
	options := &option.Options{}
	staticIPs := map[string][]string{}

	if err := setOutbounds(options, input, hopt, &staticIPs); err != nil {
		t.Fatalf("setOutbounds failed: %v", err)
	}

	if !hasOutboundTag(options, OutboundRoundRobinTag) {
		t.Fatal("expected balance outbound to be present")
	}
	if !selectorContains(options, OutboundSelectTag, OutboundRoundRobinTag) {
		t.Fatal("expected main selector to include balance")
	}
}

func TestSetRoutingOptionsKeepsRegionRulesForLegacySettings(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"

	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if !hasRouteDomainSuffix(options, ".ru", OutboundDirectTag) {
		t.Fatal("expected legacy .ru direct route")
	}
	if !hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("expected legacy geosite-ru direct route")
	}
	if !hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("expected legacy geoip-ru direct route")
	}
}

func TestSetRoutingOptionsSkipsRegionRulesWhenSiteRoutingModeIsPresent(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.SiteRoutingMode = "exclude"
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_proxy,
			DomainSuffixes: []string{"2ip.ru"},
		},
	}

	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if hasRouteDomainSuffix(options, ".ru", OutboundDirectTag) {
		t.Fatal("did not expect broad .ru direct route with explicit site routing mode")
	}
	if hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("did not expect broad geosite-ru direct route with explicit site routing mode")
	}
	if hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("did not expect broad geoip-ru direct route with explicit site routing mode")
	}
	if !hasRouteDomainSuffix(options, "2ip.ru", OutboundMainDetour) {
		t.Fatal("expected explicit 2ip.ru site rule to route through VPN")
	}
}

func newRoutingTestOptions() *option.Options {
	return &option.Options{
		DNS: &option.DNSOptions{},
	}
}

func hasOutboundTag(options *option.Options, tag string) bool {
	for _, outbound := range options.Outbounds {
		if outbound.Tag == tag {
			return true
		}
	}
	return false
}

func selectorContains(options *option.Options, selectorTag string, candidateTag string) bool {
	for _, outbound := range options.Outbounds {
		if outbound.Tag != selectorTag {
			continue
		}
		selectorOptions, ok := outbound.Options.(*option.SelectorOutboundOptions)
		if !ok {
			return false
		}
		return contains(selectorOptions.Outbounds, candidateTag)
	}
	return false
}

func hasRouteDomainSuffix(options *option.Options, suffix string, outbound string) bool {
	if options.Route == nil {
		return false
	}
	for _, rule := range options.Route.Rules {
		if rule.DefaultOptions.RuleAction.RouteOptions.Outbound != outbound {
			continue
		}
		if contains([]string(rule.DefaultOptions.RawDefaultRule.DomainSuffix), suffix) {
			return true
		}
	}
	return false
}

func hasRouteRuleSet(options *option.Options, ruleSet string, outbound string) bool {
	if options.Route == nil {
		return false
	}
	for _, rule := range options.Route.Rules {
		if rule.DefaultOptions.RuleAction.RouteOptions.Outbound != outbound {
			continue
		}
		if contains([]string(rule.DefaultOptions.RawDefaultRule.RuleSet), ruleSet) {
			return true
		}
	}
	return false
}
