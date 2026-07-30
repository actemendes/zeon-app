package config

import (
	"context"
	"testing"

	"github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
)

func testConfigContext() context.Context {
	return include.Context(context.Background())
}

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

func TestSetRoutingOptionsAddsHardcodedRUAdListWhenBlockAdsEnabled(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.BlockAds = true
	opts := option.Options{
		DNS: &option.DNSOptions{},
	}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	if opts.Route == nil {
		t.Fatalf("route options should not be nil")
	}

	foundRuleSet := false
	for _, ruleSet := range opts.Route.RuleSet {
		if ruleSet.Tag != RUAdListHardcodedRuleSetTag {
			continue
		}
		foundRuleSet = true
		if ruleSet.Type != constant.RuleSetTypeInline {
			t.Fatalf("RU adlist rule-set type = %s, want inline", ruleSet.Type)
		}
		if len(ruleSet.InlineOptions.Rules) != 1 {
			t.Fatalf("RU adlist inline rules length = %d, want 1", len(ruleSet.InlineOptions.Rules))
		}
		rule := ruleSet.InlineOptions.Rules[0].DefaultOptions
		if !containsString(rule.Domain, "adfox.ru") {
			t.Fatalf("RU adlist domains should include adfox.ru")
		}
		if !containsString(rule.DomainSuffix, ".adfox.ru") {
			t.Fatalf("RU adlist domain suffixes should include .adfox.ru")
		}
		break
	}
	if !foundRuleSet {
		t.Fatalf("expected %s rule-set to be present", RUAdListHardcodedRuleSetTag)
	}

	foundRouteReject := false
	for _, rule := range opts.Route.Rules {
		if !containsString(rule.DefaultOptions.RuleSet, RUAdListHardcodedRuleSetTag) {
			continue
		}
		foundRouteReject = true
		if rule.DefaultOptions.Action != constant.RuleActionTypeReject {
			t.Fatalf("RU adlist route action = %s, want reject", rule.DefaultOptions.Action)
		}
		break
	}
	if !foundRouteReject {
		t.Fatalf("expected route reject rule for %s", RUAdListHardcodedRuleSetTag)
	}

	foundDNSReject := false
	for _, rule := range opts.DNS.Rules {
		if !containsString(rule.DefaultOptions.RuleSet, RUAdListHardcodedRuleSetTag) {
			continue
		}
		foundDNSReject = true
		if rule.DefaultOptions.Action != constant.RuleActionTypePredefined {
			t.Fatalf("RU adlist DNS action = %s, want predefined reject", rule.DefaultOptions.Action)
		}
		break
	}
	if !foundDNSReject {
		t.Fatalf("expected DNS reject rule for %s", RUAdListHardcodedRuleSetTag)
	}
}

func TestRussiaPresetHasExplicitRussianPublicSuffixes(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	var routeSuffixes []string
	for _, rule := range opts.Route.Rules {
		candidate := rule.DefaultOptions
		if candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Outbound == OutboundDirectTag &&
			containsString(candidate.DomainSuffix, ".ru") {
			routeSuffixes = candidate.DomainSuffix
			break
		}
	}
	for _, suffix := range []string{".ru", ".su", ".xn--p1ai"} {
		if !containsString(routeSuffixes, suffix) {
			t.Fatalf("Russia direct suffix rule = %v, missing %s", routeSuffixes, suffix)
		}
	}
}

func TestRussiaYandexDirectPolicyIsIndependent(t *testing.T) {
	assertRussiaServicePolicy(
		t,
		RUYandexRuleSetTag,
		OutboundDirectTag,
		DNSMultiDirectTag,
	)
}

func TestRussiaWildberriesProxyPolicyIsIndependent(t *testing.T) {
	assertRussiaServicePolicy(
		t,
		RUWildberriesRuleSetTag,
		OutboundMainDetour,
		DNSMultiRemoteTag,
	)
}

func assertRussiaServicePolicy(t *testing.T, tag string, expectedOutbound string, expectedDNSServer string) {
	t.Helper()
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	serviceIndex, directIndex := -1, -1
	for index, rule := range opts.Route.Rules {
		candidate := rule.DefaultOptions
		if candidate.Action != constant.RuleActionTypeRoute {
			continue
		}
		if candidate.RouteOptions.Outbound == expectedOutbound &&
			containsString(candidate.RuleSet, tag) {
			serviceIndex = index
		}
		if candidate.RouteOptions.Outbound == OutboundDirectTag &&
			containsString(candidate.DomainSuffix, ".ru") {
			directIndex = index
		}
	}
	if serviceIndex < 0 || directIndex < 0 || serviceIndex >= directIndex {
		t.Fatalf("%s route index=%d must precede RU direct index=%d", tag, serviceIndex, directIndex)
	}

	foundDNSRule := false
	for _, rule := range opts.DNS.Rules {
		candidate := rule.DefaultOptions
		if containsString(candidate.RuleSet, tag) &&
			candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Server == expectedDNSServer {
			foundDNSRule = true
			break
		}
	}
	if !foundDNSRule {
		t.Fatalf("%s has no DNS route through %s", tag, expectedDNSServer)
	}

	for _, ruleSet := range opts.Route.RuleSet {
		if ruleSet.Tag == tag && ruleSet.Type == constant.RuleSetTypeInline {
			return
		}
	}
	t.Fatalf("%s has no independent inline rule set", tag)
}

func TestGlobalPresetDoesNotInstallRussiaDirectRules(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "other"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	for _, rule := range opts.Route.Rules {
		candidate := rule.DefaultOptions
		if candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Outbound == OutboundDirectTag &&
			(containsString(candidate.DomainSuffix, ".ru") ||
				containsString(candidate.RuleSet, "geosite-ru") ||
				containsString(candidate.RuleSet, "geoip-ru")) {
			t.Fatalf("Global preset unexpectedly contains RU direct rule: %+v", candidate)
		}
	}
}

func containsString(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}

func TestParseConfigUsesFullConfigFlag(t *testing.T) {
	ctx := testConfigContext()
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
	ctx := testConfigContext()
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
