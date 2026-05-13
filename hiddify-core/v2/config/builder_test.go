package config

import (
	"context"
	"strings"
	"testing"
	"time"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func withRuleSetCacheStub(
	t *testing.T,
	fn func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error),
) {
	t.Helper()
	prev := ensureRuleSetCachedFunc
	ensureRuleSetCachedFunc = fn
	t.Cleanup(func() {
		ensureRuleSetCachedFunc = prev
	})
}

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

func TestSelectorTuningStableModeDisablesInterruptByDefault(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.RouteOptions.StableTransportMode = true
	input := &option.Options{
		Outbounds: []option.Outbound{
			{Type: C.TypeDirect, Tag: "proxy-a", Options: &option.DirectOutboundOptions{}},
			{Type: C.TypeDirect, Tag: "proxy-b", Options: &option.DirectOutboundOptions{}},
		},
	}
	options := &option.Options{}
	staticIPs := map[string][]string{}
	if err := setOutbounds(options, input, hopt, &staticIPs); err != nil {
		t.Fatalf("setOutbounds failed: %v", err)
	}
	for _, out := range options.Outbounds {
		if out.Tag != OutboundSelectTag && out.Tag != OutboundURLTestTag && out.Tag != OutboundRoundRobinTag {
			continue
		}
		switch opts := out.Options.(type) {
		case *option.SelectorOutboundOptions:
			if opts.InterruptExistConnections {
				t.Fatal("expected selector interrupt=false in stable mode")
			}
		case *option.BalancerOutboundOptions:
			if opts.InterruptExistConnections {
				t.Fatal("expected balancer/urltest interrupt=false in stable mode")
			}
		}
	}
}

func TestSelectorTuningExplicitInterruptOverride(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	override := true
	hopt.RouteOptions.StableTransportMode = true
	hopt.RouteOptions.SelectorInterrupt = &override
	input := &option.Options{
		Outbounds: []option.Outbound{
			{Type: C.TypeDirect, Tag: "proxy-a", Options: &option.DirectOutboundOptions{}},
			{Type: C.TypeDirect, Tag: "proxy-b", Options: &option.DirectOutboundOptions{}},
		},
	}
	options := &option.Options{}
	staticIPs := map[string][]string{}
	if err := setOutbounds(options, input, hopt, &staticIPs); err != nil {
		t.Fatalf("setOutbounds failed: %v", err)
	}
	for _, out := range options.Outbounds {
		if out.Tag != OutboundSelectTag {
			continue
		}
		opts, ok := out.Options.(*option.SelectorOutboundOptions)
		if !ok {
			continue
		}
		if !opts.InterruptExistConnections {
			t.Fatal("expected selector interrupt override to true")
		}
	}
}

func TestSetRoutingOptionsLegacyFallbackKeepsRegionRulesForOldSettings(t *testing.T) {
	withRuleSetCacheStub(t, func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		return ResolvedRuleSet{Tag: source.Tag, LocalPath: "data/rulesets/" + source.Tag + ".srs"}, RuleSetRuntimeMetadata{Tag: source.Tag}, nil
	})
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"

	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if !hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("expected legacy geosite-ru direct route")
	}
	if !hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("expected legacy geoip-ru direct route")
	}
}

func TestSetRoutingOptionsRuRoutingOffDisablesAutoRegionalRules(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.RuRoutingMode = RuRoutingModeOff
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

	if hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("did not expect geosite-ru route when ru-routing-mode=off")
	}
	if hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("did not expect geoip-ru route when ru-routing-mode=off")
	}
	if !hasRouteDomainSuffix(options, "2ip.ru", OutboundMainDetour) {
		t.Fatal("expected explicit 2ip.ru site rule to route through VPN")
	}
}

func TestSetRoutingOptionsRuRoutingGeositeAddsOnlyGeositeAndDirectDNS(t *testing.T) {
	withRuleSetCacheStub(t, func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		return ResolvedRuleSet{Tag: source.Tag, LocalPath: "data/rulesets/" + source.Tag + ".srs"}, RuleSetRuntimeMetadata{Tag: source.Tag}, nil
	})
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.RuRoutingMode = RuRoutingModeGeosite

	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if !hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("expected geosite-ru direct route")
	}
	if hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("did not expect geoip-ru route for geosite mode")
	}
	if hasRouteDomainSuffix(options, ".ru", OutboundDirectTag) {
		t.Fatal("did not expect .ru suffix direct route in geosite mode")
	}
	if !hasDNSRuleSet(options, "geosite-ru", DNSMultiDirectTag) {
		t.Fatal("expected geosite-ru dns-direct rule in geosite mode")
	}
	if got := getRuleSetLocalPathByTag(options, "geosite-ru"); got == "" {
		t.Fatal("expected local ruleset path for geosite-ru")
	}
}

func TestSetRoutingOptionsRuRoutingAggressiveAddsGeositeAndGeoip(t *testing.T) {
	withRuleSetCacheStub(t, func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		return ResolvedRuleSet{Tag: source.Tag, LocalPath: "data/rulesets/" + source.Tag + ".srs"}, RuleSetRuntimeMetadata{Tag: source.Tag}, nil
	})
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.RuRoutingMode = RuRoutingModeGeositeGeoIPAggressive

	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if !hasRouteRuleSet(options, "geosite-ru", OutboundDirectTag) {
		t.Fatal("expected geosite-ru direct route")
	}
	if !hasRouteRuleSet(options, "geoip-ru", OutboundDirectTag) {
		t.Fatal("expected geoip-ru direct route")
	}
	if hasRouteDomainSuffix(options, ".ru", OutboundDirectTag) {
		t.Fatal("did not expect .ru suffix direct route in aggressive mode")
	}
	if !hasDNSRuleSet(options, "geosite-ru", DNSMultiDirectTag) {
		t.Fatal("expected geosite-ru dns-direct rule in aggressive mode")
	}
	if got := getRuleSetLocalPathByTag(options, "geosite-ru"); got == "" {
		t.Fatal("expected local geosite-ru path")
	}
	if got := getRuleSetLocalPathByTag(options, "geoip-ru"); got == "" {
		t.Fatal("expected local geoip-ru path")
	}
}

func TestRoutingInvariantsRemainVPNFirst(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if options.Route == nil || options.Route.Final != OutboundSelectTag {
		t.Fatalf("expected route.final=%q, got %+v", OutboundSelectTag, options.Route)
	}
	if options.DNS == nil || options.DNS.Final != DNSMultiRemoteTag {
		t.Fatalf("expected dns.final=%q, got %+v", DNSMultiRemoteTag, options.DNS)
	}
}

func TestCriticalDomainFallsBackToSelectWhenNoExplicitDirect(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	routeOutbound := firstRouteOutboundForDomain(options, "t.me")
	if routeOutbound != "" {
		t.Fatalf("expected no explicit t.me route with critical fallback disabled, got %q", routeOutbound)
	}
	dnsServer := firstDNSServerForDomain(options, "t.me")
	if dnsServer != "" {
		t.Fatalf("expected no explicit t.me dns with critical fallback disabled, got %q", dnsServer)
	}
	if options.Route.Final != OutboundSelectTag {
		t.Fatalf("expected t.me fallback route.final=%q, got %q", OutboundSelectTag, options.Route.Final)
	}
	if options.DNS.Final != DNSMultiRemoteTag {
		t.Fatalf("expected t.me fallback dns.final=%q, got %q", DNSMultiRemoteTag, options.DNS.Final)
	}
}

func TestExplicitUserDirectOverridesCriticalDomainFallback(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"t.me"},
		},
	}
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	routeOutbound := firstRouteOutboundForDomain(options, "t.me")
	if routeOutbound != OutboundDirectTag {
		t.Fatalf("expected t.me route to %q, got %q", OutboundDirectTag, routeOutbound)
	}
	dnsServer := firstDNSServerForDomain(options, "t.me")
	if dnsServer != DNSMultiDirectTag {
		t.Fatalf("expected t.me dns to %q, got %q", DNSMultiDirectTag, dnsServer)
	}
}

func TestExplicitUserDirectYandexUsesDirectAndDirectDNS(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"yandex.ru"},
		},
	}
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	routeOutbound := firstRouteOutboundForDomain(options, "yandex.ru")
	if routeOutbound != OutboundDirectTag {
		t.Fatalf("expected yandex.ru route to %q, got %q", OutboundDirectTag, routeOutbound)
	}
	dnsServer := firstDNSServerForDomain(options, "yandex.ru")
	if dnsServer != DNSMultiDirectTag {
		t.Fatalf("expected yandex.ru dns to %q, got %q", DNSMultiDirectTag, dnsServer)
	}
}

func TestStableMobileSetsDirectDNSStrategyPreferIPv4(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.RouteOptions.NetworkProfile = NetworkProfileStableMobile
	applyNetworkProfile(hopt)
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"yandex.ru"},
		},
	}
	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}
	got := firstDNSStrategyForDomain(options, "yandex.ru")
	if got != option.DomainStrategy(C.DomainStrategyPreferIPv4).String() {
		t.Fatalf("expected direct DNS strategy prefer_ipv4, got %q", got)
	}
}

func TestDirectIPv4OnlyDiagnosticForcesDirectDNSStrategyIPv4Only(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.RouteOptions.NetworkProfile = NetworkProfileDirectIPv4OnlyDiag
	applyNetworkProfile(hopt)
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"yandex.ru"},
		},
	}
	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}
	if firstRouteOutboundForDomain(options, "yandex.ru") != OutboundDirectTag {
		t.Fatal("expected yandex.ru route to remain direct")
	}
	if firstDNSServerForDomain(options, "yandex.ru") != DNSMultiDirectTag {
		t.Fatal("expected yandex.ru DNS server to remain dns-direct")
	}
	got := firstDNSStrategyForDomain(options, "yandex.ru")
	if got != option.DomainStrategy(C.DomainStrategyIPv4Only).String() {
		t.Fatalf("expected direct DNS strategy ipv4_only, got %q", got)
	}
}

func TestUnknownDomainFallsBackToFinalRouteAndDNS(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if firstRouteOutboundForDomain(options, "unknown.com") != "" {
		t.Fatal("expected no explicit route rule for unknown.com")
	}
	if firstDNSServerForDomain(options, "unknown.com") != "" {
		t.Fatal("expected no explicit dns rule for unknown.com")
	}
	if options.Route.Final != OutboundSelectTag {
		t.Fatalf("expected unknown.com fallback route.final=%q, got %q", OutboundSelectTag, options.Route.Final)
	}
	if options.DNS.Final != DNSMultiRemoteTag {
		t.Fatalf("expected unknown.com fallback dns.final=%q, got %q", DNSMultiRemoteTag, options.DNS.Final)
	}
}

func TestExplicitUserProxyOverridesLegacyRegionalDirect(t *testing.T) {
	withRuleSetCacheStub(t, func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		return ResolvedRuleSet{Tag: source.Tag, LocalPath: "data/rulesets/" + source.Tag + ".srs"}, RuleSetRuntimeMetadata{Tag: source.Tag}, nil
	})
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_proxy,
			DomainSuffixes: []string{"yandex.ru"},
		},
	}
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	routeOutbound := firstRouteOutboundForDomain(options, "yandex.ru")
	if routeOutbound != OutboundMainDetour {
		t.Fatalf("expected yandex.ru route to %q, got %q", OutboundMainDetour, routeOutbound)
	}
	dnsServer := firstDNSServerForDomain(options, "yandex.ru")
	if dnsServer != DNSMultiRemoteTag {
		t.Fatalf("expected yandex.ru dns to %q, got %q", DNSMultiRemoteTag, dnsServer)
	}
}

func TestAppPackageRuleUnaffectedByRuRoutingMode(t *testing.T) {
	withRuleSetCacheStub(t, func(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		return ResolvedRuleSet{Tag: source.Tag, LocalPath: "data/rulesets/" + source.Tag + ".srs"}, RuleSetRuntimeMetadata{Tag: source.Tag}, nil
	})
	hopt := DefaultHiddifyOptions()
	hopt.RuRoutingMode = RuRoutingModeGeositeGeoIPAggressive
	hopt.Rules = []Rule{
		{
			Enabled:      true,
			Outbound:     Outbound_direct,
			PackageNames: []string{"org.example.app"},
		},
	}
	options := newRoutingTestOptions()

	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}

	if !hasRoutePackage(options, "org.example.app", OutboundDirectTag) {
		t.Fatal("expected package_name direct rule to stay active")
	}
}

func TestCriticalDomainFallbackEnabledEmitsRulesBelowExplicitUserRules(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.RouteOptions.CriticalDomainsFallbackEnabled = true
	hopt.Rules = []Rule{
		{
			Enabled:        true,
			Outbound:       Outbound_direct,
			DomainSuffixes: []string{"t.me"},
		},
	}
	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}
	if !hasRouteDomainSuffix(options, "google.com", OutboundMainDetour) {
		t.Fatal("expected critical fallback route rule when enabled")
	}
	if !hasDNSDomainSuffix(options, "google.com", DNSMultiRemoteTag) {
		t.Fatal("expected critical fallback dns rule when enabled")
	}
	if firstRouteOutboundForDomain(options, "t.me") != OutboundDirectTag {
		t.Fatal("expected explicit user direct to win over critical fallback")
	}
	if firstDNSServerForDomain(options, "t.me") != DNSMultiDirectTag {
		t.Fatal("expected explicit user dns-direct to win over critical fallback")
	}
}

func TestCriticalFallbackDisabledDoesNotEmitCriticalRulesForCommonDomains(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}
	for _, domain := range []string{"t.me", "youtube.com", "google.com", "discord.com", "speedtest.net"} {
		if firstRouteOutboundForDomain(options, domain) != "" {
			t.Fatalf("did not expect explicit route rule for %s", domain)
		}
		if firstDNSServerForDomain(options, domain) != "" {
			t.Fatalf("did not expect explicit dns rule for %s", domain)
		}
	}
}

func TestRoutingAddsSniffAndHijackDNS(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	options := newRoutingTestOptions()
	if err := setRoutingOptions(options, hopt); err != nil {
		t.Fatalf("setRoutingOptions failed: %v", err)
	}
	if options.Route == nil || len(options.Route.Rules) < 2 {
		t.Fatal("expected at least sniff and hijack dns rules")
	}
	if options.Route.Rules[0].DefaultOptions.RuleAction.Action != C.RuleActionTypeSniff {
		t.Fatalf("expected first rule action=sniff, got %s", options.Route.Rules[0].DefaultOptions.RuleAction.Action)
	}
	if options.Route.Rules[1].DefaultOptions.RuleAction.Action != C.RuleActionTypeHijackDNS {
		t.Fatalf("expected second rule action=hijack-dns, got %s", options.Route.Rules[1].DefaultOptions.RuleAction.Action)
	}
}

func TestBuildCountryGeositeRuleSetSourceRU(t *testing.T) {
	src := buildCountryGeositeRuleSetSource("ru")
	if src.Tag != "geosite-ru" {
		t.Fatalf("unexpected tag: %s", src.Tag)
	}
	if src.PrimaryURL != "https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geosite-ru.srs" {
		t.Fatalf("unexpected primary URL: %s", src.PrimaryURL)
	}
	if src.Format != C.RuleSetFormatBinary {
		t.Fatalf("unexpected format: %s", src.Format)
	}
	if src.UpdateInterval != badoption.Duration(5*24*time.Hour) {
		t.Fatalf("unexpected update interval: %v", src.UpdateInterval)
	}
	if src.DownloadDetour != OutboundSelectTag {
		t.Fatalf("unexpected download detour: %s", src.DownloadDetour)
	}
}

func TestBuildCountryGeoIPRuleSetSourceRU(t *testing.T) {
	src := buildCountryGeoIPRuleSetSource("ru")
	if src.Tag != "geoip-ru" {
		t.Fatalf("unexpected tag: %s", src.Tag)
	}
	if src.PrimaryURL != "https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geoip-ru.srs" {
		t.Fatalf("unexpected primary URL: %s", src.PrimaryURL)
	}
	if src.Format != C.RuleSetFormatBinary {
		t.Fatalf("unexpected format: %s", src.Format)
	}
	if src.UpdateInterval != badoption.Duration(5*24*time.Hour) {
		t.Fatalf("unexpected update interval: %v", src.UpdateInterval)
	}
	if src.DownloadDetour != OutboundSelectTag {
		t.Fatalf("unexpected download detour: %s", src.DownloadDetour)
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

func hasDNSRuleSet(options *option.Options, ruleSet string, server string) bool {
	if options.DNS == nil {
		return false
	}
	for _, rule := range options.DNS.Rules {
		if rule.DefaultOptions.DNSRuleAction.RouteOptions.Server != server {
			continue
		}
		if contains([]string(rule.DefaultOptions.RawDefaultDNSRule.RuleSet), ruleSet) {
			return true
		}
	}
	return false
}

func hasDNSDomainSuffix(options *option.Options, suffix string, server string) bool {
	if options.DNS == nil {
		return false
	}
	for _, rule := range options.DNS.Rules {
		if rule.DefaultOptions.DNSRuleAction.RouteOptions.Server != server {
			continue
		}
		if contains([]string(rule.DefaultOptions.RawDefaultDNSRule.DomainSuffix), suffix) {
			return true
		}
	}
	return false
}

func hasRoutePackage(options *option.Options, packageName string, outbound string) bool {
	if options.Route == nil {
		return false
	}
	for _, rule := range options.Route.Rules {
		if rule.DefaultOptions.RuleAction.RouteOptions.Outbound != outbound {
			continue
		}
		if contains([]string(rule.DefaultOptions.RawDefaultRule.PackageName), packageName) {
			return true
		}
	}
	return false
}

func getRuleSetURLByTag(options *option.Options, tag string) string {
	if options.Route == nil {
		return ""
	}
	for _, rs := range options.Route.RuleSet {
		if rs.Tag == tag {
			return rs.RemoteOptions.URL
		}
	}
	return ""
}

func getRuleSetLocalPathByTag(options *option.Options, tag string) string {
	if options.Route == nil {
		return ""
	}
	for _, rs := range options.Route.RuleSet {
		if rs.Tag == tag {
			return rs.LocalOptions.Path
		}
	}
	return ""
}

func firstRouteOutboundForDomain(options *option.Options, domain string) string {
	if options.Route == nil {
		return ""
	}
	for _, rule := range options.Route.Rules {
		raw := rule.DefaultOptions.RawDefaultRule
		if domainMatchesRule(raw.Domain, raw.DomainSuffix, domain) {
			return rule.DefaultOptions.RuleAction.RouteOptions.Outbound
		}
	}
	return ""
}

func firstDNSServerForDomain(options *option.Options, domain string) string {
	if options.DNS == nil {
		return ""
	}
	for _, rule := range options.DNS.Rules {
		raw := rule.DefaultOptions.RawDefaultDNSRule
		if domainMatchesRule(raw.Domain, raw.DomainSuffix, domain) {
			return rule.DefaultOptions.DNSRuleAction.RouteOptions.Server
		}
	}
	return ""
}

func firstDNSStrategyForDomain(options *option.Options, domain string) string {
	if options.DNS == nil {
		return ""
	}
	for _, rule := range options.DNS.Rules {
		if !contains(rule.DefaultOptions.RawDefaultDNSRule.DomainSuffix, domain) && !contains(rule.DefaultOptions.RawDefaultDNSRule.Domain, domain) {
			continue
		}
		return rule.DefaultOptions.DNSRuleAction.RouteOptions.Strategy.String()
	}
	return ""
}

func domainMatchesRule(domains []string, suffixes []string, domain string) bool {
	for _, d := range domains {
		if d == domain {
			return true
		}
	}
	for _, s := range suffixes {
		if s == domain {
			return true
		}
		if strings.HasPrefix(s, ".") {
			if strings.HasSuffix(domain, s) {
				return true
			}
			continue
		}
		if strings.HasSuffix(domain, "."+s) {
			return true
		}
	}
	return false
}
