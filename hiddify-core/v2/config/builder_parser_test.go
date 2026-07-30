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

func TestRussiaPresetUsesPinnedLocalRussianRuleSets(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	expectedPaths := map[string]string{
		BundledRUDomainsRuleSetTag: BundledRUDomainsRuleSetPath,
		BundledRUIPRuleSetTag:      BundledRUIPRuleSetPath,
	}
	for _, ruleSet := range opts.Route.RuleSet {
		expectedPath, expected := expectedPaths[ruleSet.Tag]
		if !expected {
			if ruleSet.Tag == "geosite-ru" || ruleSet.Tag == "geoip-ru" {
				t.Fatalf("Russia preset contains mutable legacy rule set: %+v", ruleSet)
			}
			continue
		}
		if ruleSet.Type != constant.RuleSetTypeLocal ||
			ruleSet.Format != constant.RuleSetFormatBinary ||
			ruleSet.LocalOptions.Path != expectedPath {
			t.Fatalf("%s local rule set = %+v", ruleSet.Tag, ruleSet)
		}
		delete(expectedPaths, ruleSet.Tag)
	}
	if len(expectedPaths) != 0 {
		t.Fatalf("missing pinned local rule sets: %v", expectedPaths)
	}

	for _, tag := range []string{BundledRUDomainsRuleSetTag, BundledRUIPRuleSetTag} {
		if indexRouteRuleSet(opts.Route.Rules, tag, OutboundDirectTag) < 0 {
			t.Fatalf("%s has no DIRECT route rule", tag)
		}
	}
	if indexDNSRuleSet(opts.DNS.Rules, BundledRUDomainsRuleSetTag, DNSMultiDirectTag) < 0 {
		t.Fatalf("%s has no DIRECT DNS rule", BundledRUDomainsRuleSetTag)
	}
	for _, rule := range opts.DNS.Rules {
		if containsString(rule.DefaultOptions.RuleSet, BundledRUIPRuleSetTag) {
			t.Fatalf("%s must not be used before DNS resolution", BundledRUIPRuleSetTag)
		}
	}
}

func assertRussiaServicePolicy(t *testing.T, tag string, expectedOutbound string, expectedDNSServer string) {
	t.Helper()
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	serviceIndex := -1
	directIndex := indexRouteRuleSet(
		opts.Route.Rules,
		BundledRUDomainsRuleSetTag,
		OutboundDirectTag,
	)
	for index, rule := range opts.Route.Rules {
		candidate := rule.DefaultOptions
		if candidate.Action != constant.RuleActionTypeRoute {
			continue
		}
		if candidate.RouteOptions.Outbound == expectedOutbound &&
			containsString(candidate.RuleSet, tag) {
			serviceIndex = index
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
			(containsString(candidate.RuleSet, BundledRUDomainsRuleSetTag) ||
				containsString(candidate.RuleSet, BundledRUIPRuleSetTag) ||
				containsString(candidate.RuleSet, "geosite-ru") ||
				containsString(candidate.RuleSet, "geoip-ru")) {
			t.Fatalf("Global preset unexpectedly contains RU direct rule: %+v", candidate)
		}
	}
	for _, ruleSet := range opts.Route.RuleSet {
		if ruleSet.Tag == BundledRUDomainsRuleSetTag || ruleSet.Tag == BundledRUIPRuleSetTag {
			t.Fatalf("Global preset unexpectedly installs local RU rule set: %+v", ruleSet)
		}
	}
}

func TestRussiaDestinationRulePriority(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	// The Russia preset must keep LAN direct even if the general UI toggle is
	// disabled. Explicit user rules still remain above this rule.
	hopt.BypassLAN = false
	hopt.BlockAds = true
	hopt.RouteOptions.BlockQuic = true
	hopt.Rules = []Rule{
		{
			ListOrder:      0,
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"user-priority.example"},
		},
	}
	hopt.ProfileRules = []Rule{
		{
			ListOrder:      0,
			Enabled:        true,
			Outbound:       Outbound_proxy,
			DomainSuffixes: []string{"explicit-global-vpn.example"},
		},
	}
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	indexes := map[string]int{
		"internal":    indexRouteIPCIDR(opts.Route.Rules, "10.10.34.0/24"),
		"user":        indexRouteDomainSuffix(opts.Route.Rules, "user-priority.example"),
		"LAN":         indexPrivateRoute(opts.Route.Rules),
		"ad block":    indexRejectedRuleSet(opts.Route.Rules, RUAdListHardcodedRuleSetTag),
		"QUIC block":  indexRejectedProtocol(opts.Route.Rules, constant.ProtocolQUIC),
		"Yandex":      indexRouteRuleSet(opts.Route.Rules, RUYandexRuleSetTag, OutboundDirectTag),
		"Wildberries": indexRouteRuleSet(opts.Route.Rules, RUWildberriesRuleSetTag, OutboundDirectTag),
		"RU domains":  indexRouteRuleSet(opts.Route.Rules, BundledRUDomainsRuleSetTag, OutboundDirectTag),
		"RU IP":       indexRouteRuleSet(opts.Route.Rules, BundledRUIPRuleSetTag, OutboundDirectTag),
		"global VPN":  indexRouteDomainSuffix(opts.Route.Rules, "explicit-global-vpn.example"),
	}
	for name, index := range indexes {
		if index < 0 {
			t.Fatalf("missing %s rule; indexes=%v", name, indexes)
		}
	}
	if !(indexes["internal"] < indexes["user"] &&
		indexes["user"] < indexes["LAN"] &&
		indexes["LAN"] < indexes["ad block"] &&
		indexes["LAN"] < indexes["QUIC block"] &&
		indexes["ad block"] < indexes["Yandex"] &&
		indexes["QUIC block"] < indexes["Yandex"] &&
		indexes["Yandex"] < indexes["RU domains"] &&
		indexes["Wildberries"] < indexes["RU domains"] &&
		indexes["RU domains"] < indexes["RU IP"]) {
		t.Fatalf("invalid Russia destination priority: %v", indexes)
	}
	if indexes["RU IP"] >= indexes["global VPN"] {
		t.Fatalf("global VPN rule must follow RU IP: %v", indexes)
	}
	ruDomainDNS := indexDNSRuleSet(opts.DNS.Rules, BundledRUDomainsRuleSetTag, DNSMultiDirectTag)
	globalVPNDNS := indexDNSDomainSuffix(opts.DNS.Rules, "explicit-global-vpn.example", DNSMultiRemoteTag)
	if ruDomainDNS < 0 || globalVPNDNS < 0 || ruDomainDNS >= globalVPNDNS {
		t.Fatalf("global VPN DNS index=%d must follow RU domain DNS index=%d", globalVPNDNS, ruDomainDNS)
	}
	if opts.Route.Final != OutboundMainDetour {
		t.Fatalf("Russia final = %s, want VPN %s", opts.Route.Final, OutboundMainDetour)
	}
}

func TestUserDomainRuleControlsDNSBeforeRussiaServiceRules(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.Rules = []Rule{
		{
			ListOrder:      0,
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"yandex.ru"},
		},
	}
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	userDNS := indexDNSDomainSuffix(opts.DNS.Rules, "yandex.ru", DNSMultiDirectTag)
	serviceDNS := indexDNSRuleSet(opts.DNS.Rules, RUYandexRuleSetTag, DNSMultiDirectTag)
	if userDNS < 0 || serviceDNS < 0 || userDNS >= serviceDNS {
		t.Fatalf("user DNS index=%d must precede Yandex service DNS index=%d", userDNS, serviceDNS)
	}
}

func TestRussiaDNSPreservesReverseMappingWithoutChangingGlobal(t *testing.T) {
	staticIPs := map[string][]string{}

	russia := DefaultHiddifyOptions()
	russia.Region = "ru"
	var russiaOptions option.Options
	if err := setDns(&russiaOptions, russia, &staticIPs); err != nil {
		t.Fatalf("setDns Russia returned error: %v", err)
	}
	if russiaOptions.DNS == nil || !russiaOptions.DNS.ReverseMapping {
		t.Fatalf("Russia DNS must preserve domain-to-address reverse mapping")
	}

	global := DefaultHiddifyOptions()
	global.Region = "other"
	var globalOptions option.Options
	if err := setDns(&globalOptions, global, &staticIPs); err != nil {
		t.Fatalf("setDns Global returned error: %v", err)
	}
	if globalOptions.DNS == nil || globalOptions.DNS.ReverseMapping {
		t.Fatalf("Global DNS reverse mapping policy changed unexpectedly")
	}
}

func TestRussiaDisablesFakeDNSWithoutChangingGlobal(t *testing.T) {
	staticIPs := map[string][]string{}

	russia := DefaultHiddifyOptions()
	russia.Region = "ru"
	russia.EnableFakeDNS = true
	var russiaOptions option.Options
	if err := setDns(&russiaOptions, russia, &staticIPs); err != nil {
		t.Fatalf("setDns Russia returned error: %v", err)
	}
	if err := setRoutingOptions(&russiaOptions, russia); err != nil {
		t.Fatalf("setRoutingOptions Russia returned error: %v", err)
	}
	if hasDNSServerTag(russiaOptions.DNS, DNSFakeTag) || hasDNSRuleServer(russiaOptions.DNS, DNSFakeTag) {
		t.Fatal("Russia must disable FakeDNS so zapret-ru-ip sees resolved IPv4/IPv6 destinations")
	}

	global := DefaultHiddifyOptions()
	global.Region = "other"
	global.EnableFakeDNS = true
	var globalOptions option.Options
	if err := setDns(&globalOptions, global, &staticIPs); err != nil {
		t.Fatalf("setDns Global returned error: %v", err)
	}
	if err := setRoutingOptions(&globalOptions, global); err != nil {
		t.Fatalf("setRoutingOptions Global returned error: %v", err)
	}
	if !hasDNSServerTag(globalOptions.DNS, DNSFakeTag) || !hasDNSRuleServer(globalOptions.DNS, DNSFakeTag) {
		t.Fatal("Global FakeDNS behavior changed unexpectedly")
	}
}

func hasDNSServerTag(options *option.DNSOptions, tag string) bool {
	if options == nil {
		return false
	}
	for _, server := range options.Servers {
		if server.Tag == tag {
			return true
		}
	}
	return false
}

func hasDNSRuleServer(options *option.DNSOptions, server string) bool {
	if options == nil {
		return false
	}
	for _, rule := range options.Rules {
		if rule.DefaultOptions.Action == constant.RuleActionTypeRoute &&
			rule.DefaultOptions.RouteOptions.Server == server {
			return true
		}
	}
	return false
}

func indexRouteRuleSet(rules []option.Rule, tag string, outbound string) int {
	for index, rule := range rules {
		candidate := rule.DefaultOptions
		if candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Outbound == outbound &&
			containsString(candidate.RuleSet, tag) {
			return index
		}
	}
	return -1
}

func indexRouteIPCIDR(rules []option.Rule, cidr string) int {
	for index, rule := range rules {
		if containsString(rule.DefaultOptions.IPCIDR, cidr) {
			return index
		}
	}
	return -1
}

func indexRouteDomainSuffix(rules []option.Rule, suffix string) int {
	for index, rule := range rules {
		if containsString(rule.DefaultOptions.DomainSuffix, suffix) {
			return index
		}
	}
	return -1
}

func indexPrivateRoute(rules []option.Rule) int {
	for index, rule := range rules {
		if rule.DefaultOptions.IPIsPrivate &&
			rule.DefaultOptions.Action == constant.RuleActionTypeRoute &&
			rule.DefaultOptions.RouteOptions.Outbound == OutboundDirectTag {
			return index
		}
	}
	return -1
}

func indexRejectedRuleSet(rules []option.Rule, tag string) int {
	for index, rule := range rules {
		if rule.DefaultOptions.Action == constant.RuleActionTypeReject &&
			containsString(rule.DefaultOptions.RuleSet, tag) {
			return index
		}
	}
	return -1
}

func indexRejectedProtocol(rules []option.Rule, protocol string) int {
	for index, rule := range rules {
		if rule.DefaultOptions.Action == constant.RuleActionTypeReject &&
			containsString(rule.DefaultOptions.Protocol, protocol) {
			return index
		}
	}
	return -1
}

func indexDNSRuleSet(rules []option.DNSRule, tag string, server string) int {
	for index, rule := range rules {
		candidate := rule.DefaultOptions
		if candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Server == server &&
			containsString(candidate.RuleSet, tag) {
			return index
		}
	}
	return -1
}

func indexDNSDomainSuffix(rules []option.DNSRule, suffix string, server string) int {
	for index, rule := range rules {
		candidate := rule.DefaultOptions
		if candidate.Action == constant.RuleActionTypeRoute &&
			candidate.RouteOptions.Server == server &&
			containsString(candidate.DomainSuffix, suffix) {
			return index
		}
	}
	return -1
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
