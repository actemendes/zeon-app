package config

import (
	"context"
	"testing"

	"github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestResolveEffectiveTunMTUDynamicByTransport(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.NetworkMtuMode = "dynamic"
	hopt.NetworkTransportType = "cellular"
	hopt.NetworkInterfaceMTU = 0
	if got := resolveEffectiveTunMTU(hopt); got != 1380 {
		t.Fatalf("cellular dynamic mtu = %d, want 1380", got)
	}

	hopt.NetworkTransportType = "wifi"
	if got := resolveEffectiveTunMTU(hopt); got != 1460 {
		t.Fatalf("wifi dynamic mtu = %d, want 1460", got)
	}

	hopt.NetworkTransportType = "unknown"
	if got := resolveEffectiveTunMTU(hopt); got != 1400 {
		t.Fatalf("unknown dynamic mtu = %d, want 1400", got)
	}
}

func TestResolveEffectiveTunMTUManualOverride(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.NetworkMtuMode = "dynamic"
	hopt.NetworkTransportType = "wifi"
	hopt.NetworkInterfaceMTU = 1420
	hopt.MTU = 1500
	if got := resolveEffectiveTunMTU(hopt); got != 1420 {
		t.Fatalf("manual interface mtu should override dynamic value, got %d", got)
	}
}

func TestBuildUserRouteRulesPriorityAndActions(t *testing.T) {
	rules := []Rule{
		{
			ListOrder:      2,
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"direct.example"},
		},
		{
			ListOrder:      1,
			Enabled:        true,
			Outbound:       Outbound_block,
			DomainSuffixes: []string{"block.example"},
		},
		{
			ListOrder:      3,
			Enabled:        false,
			Outbound:       Outbound_proxy,
			DomainSuffixes: []string{"disabled.example"},
		},
	}
	converted := buildUserRouteRules(rules)
	if len(converted) != 2 {
		t.Fatalf("converted user rules length = %d, want 2", len(converted))
	}

	first := converted[0].DefaultOptions
	if len(first.DomainSuffix) == 0 || first.DomainSuffix[0] != "block.example" {
		t.Fatalf("first rule should keep list order priority, got %+v", first.DomainSuffix)
	}
	if first.Action != constant.RuleActionTypeReject {
		t.Fatalf("first rule action = %s, want reject", first.Action)
	}

	second := converted[1].DefaultOptions
	if len(second.DomainSuffix) == 0 || second.DomainSuffix[0] != "direct.example" {
		t.Fatalf("second rule should map direct rule, got %+v", second.DomainSuffix)
	}
	if second.Action != constant.RuleActionTypeRoute {
		t.Fatalf("second rule action = %s, want route", second.Action)
	}
	if second.RouteOptions.Outbound != OutboundDirectTag {
		t.Fatalf("second rule outbound = %s, want %s", second.RouteOptions.Outbound, OutboundDirectTag)
	}
}

func TestSetRoutingOptionsAppliesUserRules(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Rules = []Rule{
		{
			ListOrder:      0,
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"example.com"},
		},
	}
	opts := option.Options{
		DNS: &option.DNSOptions{},
	}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	if opts.Route == nil {
		t.Fatalf("route options should not be nil")
	}
	found := false
	for _, rule := range opts.Route.Rules {
		if len(rule.DefaultOptions.DomainSuffix) == 1 && rule.DefaultOptions.DomainSuffix[0] == "example.com" {
			found = true
			if rule.DefaultOptions.Action != constant.RuleActionTypeRoute {
				t.Fatalf("user rule action = %s, want route", rule.DefaultOptions.Action)
			}
			if rule.DefaultOptions.RouteOptions.Outbound != OutboundDirectTag {
				t.Fatalf("user rule outbound = %s, want %s", rule.DefaultOptions.RouteOptions.Outbound, OutboundDirectTag)
			}
			break
		}
	}
	if !found {
		t.Fatalf("expected user rule to be present in route rules")
	}
}

func TestParseConfigUsesFullConfigFlag(t *testing.T) {
	ctx := context.Background()
	raw := `{
  "outbounds":[{"type":"direct","tag":"d1"}],
  "route":{"final":"d1"}
}`
	withoutFull, err := ParseConfig(ctx, &ReadOptions{Content: raw}, false, DefaultHiddifyOptions(), false)
	if err != nil {
		t.Fatalf("parse without full config failed: %v", err)
	}
	if withoutFull.Route != nil && withoutFull.Route.Final == "d1" {
		t.Fatalf("route should not be preserved when fullConfig is false")
	}

	withFull, err := ParseConfig(ctx, &ReadOptions{Content: raw}, false, DefaultHiddifyOptions(), true)
	if err != nil {
		t.Fatalf("parse with full config failed: %v", err)
	}
	if withFull.Route == nil || withFull.Route.Final != "d1" {
		t.Fatalf("route should be preserved when fullConfig is true")
	}
}

func TestParseConfigWrapsSingleOutboundObject(t *testing.T) {
	ctx := context.Background()
	raw := `{"type":"direct","tag":"d1"}`
	parsed, err := ParseConfig(ctx, &ReadOptions{Content: raw}, false, DefaultHiddifyOptions(), false)
	if err != nil {
		t.Fatalf("parse single outbound object failed: %v", err)
	}
	if len(parsed.Outbounds) != 1 {
		t.Fatalf("outbounds length = %d, want 1", len(parsed.Outbounds))
	}
	if parsed.Outbounds[0].Tag != "d1" {
		t.Fatalf("unexpected outbound tag %q", parsed.Outbounds[0].Tag)
	}
}
