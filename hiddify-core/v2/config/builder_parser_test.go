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

func TestResolveEffectiveMTUMobileDefaults(t *testing.T) {
	if got := resolveEffectiveMTU("android", nil, nil, "prefer_ipv4"); got != 1400 {
		t.Fatalf("android default mtu = %d, want 1400", got)
	}
	if got := resolveEffectiveMTU("ios", nil, nil, "prefer_ipv4"); got != 1400 {
		t.Fatalf("ios default mtu = %d, want 1400", got)
	}
}

func TestResolveEffectiveMTUUserOverrideAndInvalidFallback(t *testing.T) {
	user := 1380
	upstream := 1400
	if got := resolveEffectiveMTU("android", &user, &upstream, "prefer_ipv4"); got != 1380 {
		t.Fatalf("user override mtu = %d, want 1380", got)
	}
	invalid := 1200
	if got := resolveEffectiveMTU("android", &invalid, &upstream, "prefer_ipv4"); got != 1400 {
		t.Fatalf("invalid dual-stack override mtu = %d, want upstream 1400", got)
	}
	if got := resolveEffectiveMTU("android", &invalid, nil, "ipv4_only"); got != 1200 {
		t.Fatalf("ipv4-only override mtu = %d, want 1200", got)
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

func containsString(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}

func containsUint16(items []uint16, target uint16) bool {
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

func TestBuildConfigPreservesManualLeafCriticalNetworkFields(t *testing.T) {
	ctx := testConfigContext()
	packetEncoding := "xudp"
	input := &option.Options{
		Outbounds: []option.Outbound{
			{
				Type: constant.TypeVLESS,
				Tag:  "manual-leaf",
				Options: &option.VLESSOutboundOptions{
					ServerOptions: option.ServerOptions{
						Server:     "server.example",
						ServerPort: 443,
					},
					UUID: "00000000-0000-0000-0000-000000000000",
					Flow: "xtls-rprx-vision",
					OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{
						TLS: &option.OutboundTLSOptions{
							Enabled: true,
							UTLS: &option.OutboundUTLSOptions{
								Enabled:     true,
								Fingerprint: "chrome",
							},
							Reality: &option.OutboundRealityOptions{
								Enabled:   true,
								PublicKey: "test-public-key",
								ShortID:   "abcd",
							},
						},
					},
					Transport: &option.V2RayTransportOptions{
						Type: constant.V2RayTransportTypeGRPC,
						GRPCOptions: option.V2RayGRPCOptions{
							ServiceName: "svc",
						},
					},
					PacketEncoding: &packetEncoding,
				},
			},
		},
	}
	hopt := DefaultHiddifyOptions()
	built, err := BuildConfig(ctx, hopt, &ReadOptions{Options: input})
	if err != nil {
		t.Fatalf("BuildConfig failed: %v", err)
	}

	var leaf *option.VLESSOutboundOptions
	for _, outbound := range built.Outbounds {
		if outbound.Tag == "manual-leaf" {
			var ok bool
			leaf, ok = outbound.Options.(*option.VLESSOutboundOptions)
			if !ok {
				t.Fatalf("manual-leaf options type = %T, want *VLESSOutboundOptions", outbound.Options)
			}
			break
		}
	}
	if leaf == nil {
		t.Fatalf("manual leaf not found in built config")
	}
	if leaf.PacketEncoding == nil || *leaf.PacketEncoding != packetEncoding {
		t.Fatalf("packet_encoding = %v, want %s", leaf.PacketEncoding, packetEncoding)
	}
	if leaf.Flow != "xtls-rprx-vision" {
		t.Fatalf("flow = %q", leaf.Flow)
	}
	if leaf.Transport == nil || leaf.Transport.Type != constant.V2RayTransportTypeGRPC || leaf.Transport.GRPCOptions.ServiceName != "svc" {
		t.Fatalf("transport not preserved: %+v", leaf.Transport)
	}
	if leaf.TLS == nil || !leaf.TLS.Enabled || leaf.TLS.UTLS == nil || leaf.TLS.UTLS.Fingerprint != "chrome" || leaf.TLS.Reality == nil || !leaf.TLS.Reality.Enabled {
		t.Fatalf("tls/reality/fingerprint not preserved: %+v", leaf.TLS)
	}
}

func TestBuildConfigDiagnosticFlagsDoNotChangePingInterval(t *testing.T) {
	ctx := testConfigContext()
	input := &option.Options{Outbounds: []option.Outbound{{Type: constant.TypeDirect, Tag: "manual-leaf", Options: &option.DirectOutboundOptions{}}}}
	hopt := DefaultHiddifyOptions()
	hopt.URLTestInterval = DurationInSeconds(180)
	hopt.DebugDisableTrafficHooks = true
	hopt.DebugTraceTrafficRoute = true
	built, err := BuildConfig(ctx, hopt, &ReadOptions{Options: input})
	if err != nil {
		t.Fatalf("BuildConfig failed: %v", err)
	}
	if built.Experimental == nil || built.Experimental.Monitoring == nil {
		t.Fatalf("monitoring options should be present")
	}
	monitoring := built.Experimental.Monitoring
	if !monitoring.DisableTrafficHooks || !monitoring.TraceTrafficRoute {
		t.Fatalf("debug flags not propagated: %+v", monitoring)
	}
	if got := monitoring.Interval.Build(); got != hopt.URLTestInterval.Duration() {
		t.Fatalf("monitoring interval changed: got %s want %s", got, hopt.URLTestInterval.Duration())
	}
}

func TestBuildConfigHiddifyCompatibleNetworkDefaults(t *testing.T) {
	ctx := testConfigContext()
	input := &option.Options{Outbounds: []option.Outbound{{Type: constant.TypeDirect, Tag: "manual-leaf", Options: &option.DirectOutboundOptions{}}}}
	hopt := DefaultHiddifyOptions()
	hopt.EnableTun = true

	built, err := BuildConfig(ctx, hopt, &ReadOptions{Options: input})
	if err != nil {
		t.Fatalf("BuildConfig failed: %v", err)
	}

	if hopt.BlockQuic {
		t.Fatalf("QUIC should be enabled by default")
	}
	if hopt.IPv6Mode != option.DomainStrategy(constant.DomainStrategyPreferIPv4) {
		t.Fatalf("IPv6 mode = %s, want prefer_ipv4", hopt.IPv6Mode)
	}
	if built.Route == nil || built.Route.Final != OutboundMainDetour {
		t.Fatalf("route final = %+v, want main detour", built.Route)
	}
	if built.Route.DefaultDomainResolver == nil || built.Route.DefaultDomainResolver.Server != DNSMultiRemoteTag {
		t.Fatalf("default domain resolver = %+v, want remote DNS", built.Route.DefaultDomainResolver)
	}
	for _, outbound := range built.Outbounds {
		switch opts := outbound.Options.(type) {
		case *option.SelectorOutboundOptions:
			if opts.InterruptExistConnections {
				t.Fatalf("selector %s interrupts existing connections", outbound.Tag)
			}
		case *option.BalancerOutboundOptions:
			if opts.InterruptExistConnections {
				t.Fatalf("balancer %s interrupts existing connections", outbound.Tag)
			}
		}
	}
}

func TestBuildConfigRemoteDNSUsesProxyDetour(t *testing.T) {
	ctx := testConfigContext()
	input := &option.Options{Outbounds: []option.Outbound{{Type: constant.TypeDirect, Tag: "manual-leaf", Options: &option.DirectOutboundOptions{}}}}
	hopt := DefaultHiddifyOptions()
	hopt.RemoteDnsAddress = "https://dns.cloudflare.com/dns-query"

	built, err := BuildConfig(ctx, hopt, &ReadOptions{Options: input})
	if err != nil {
		t.Fatalf("BuildConfig failed: %v", err)
	}
	var remoteDetour string
	var remoteResolver string
	var bootstrapFound bool
	for _, server := range built.DNS.Servers {
		if server.Tag == DNSBootstrapTag {
			bootstrapFound = true
		}
		if server.Tag == DNSRemoteTag {
			remoteDetour, remoteResolver, _ = dnsServerRouteInfo(server)
		}
	}
	if !bootstrapFound {
		t.Fatalf("dns-bootstrap server not found")
	}
	if remoteDetour == "" {
		t.Fatalf("dns-remote server not found")
	}
	if remoteDetour != OutboundMainDetour {
		t.Fatalf("dns-remote detour = %q, want %q", remoteDetour, OutboundMainDetour)
	}
	if remoteResolver != DNSBootstrapTag {
		t.Fatalf("dns-remote resolver = %q, want dns-bootstrap", remoteResolver)
	}
}

func TestBuildConfigDoesNotInterceptUserUDP443ForUDPProbe(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.UDPProbeEnabled = true
	hopt.UDPProbeSecret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	for _, rule := range opts.Route.Rules {
		if containsString(rule.DefaultOptions.Network, "udp") && containsUint16(rule.DefaultOptions.Port, 443) {
			t.Fatalf("UDP probe must not install a generic user UDP/443 route rule: %+v", rule.DefaultOptions)
		}
		if containsString(rule.DefaultOptions.Protocol, constant.ProtocolQUIC) && rule.DefaultOptions.Action == constant.RuleActionTypeReject {
			t.Fatalf("QUIC reject appeared without block-quic=true")
		}
	}
}

func TestBuildConfigBlockQuicAddsOnlyQUICRejectRule(t *testing.T) {
	hopt := DefaultHiddifyOptions()
	hopt.BlockQuic = true
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	found := false
	for _, rule := range opts.Route.Rules {
		if len(rule.DefaultOptions.Protocol) == 1 && rule.DefaultOptions.Protocol[0] == constant.ProtocolQUIC {
			found = true
			if rule.DefaultOptions.Action != constant.RuleActionTypeReject {
				t.Fatalf("quic rule action = %s, want reject", rule.DefaultOptions.Action)
			}
		}
	}
	if !found {
		t.Fatalf("expected QUIC reject rule")
	}
}

func TestBuildConfigIPv4OnlyDoesNotAdvertiseTunIPv6Address(t *testing.T) {
	ctx := testConfigContext()
	input := &option.Options{Outbounds: []option.Outbound{{Type: constant.TypeDirect, Tag: "manual-leaf", Options: &option.DirectOutboundOptions{}}}}
	hopt := DefaultHiddifyOptions()
	hopt.EnableTun = true
	hopt.IPv6Mode = option.DomainStrategy(constant.DomainStrategyIPv4Only)

	built, err := BuildConfig(ctx, hopt, &ReadOptions{Options: input})
	if err != nil {
		t.Fatalf("BuildConfig failed: %v", err)
	}

	for _, inbound := range built.Inbounds {
		tunOptions, ok := inbound.Options.(*option.TunInboundOptions)
		if !ok {
			continue
		}
		for _, address := range tunOptions.Address {
			if address.Addr().Is6() {
				t.Fatalf("ipv4_only tun address contains IPv6 prefix: %s", address)
			}
		}
		return
	}
	t.Fatalf("tun inbound not found")
}
