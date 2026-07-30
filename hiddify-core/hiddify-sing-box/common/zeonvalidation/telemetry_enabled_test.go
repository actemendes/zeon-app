//go:build zeon_route_validation

package zeonvalidation

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	SBLog "github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"

	mDNS "github.com/miekg/dns"
)

func TestValidationTelemetryEnabledWithBuildTag(t *testing.T) {
	if !Enabled() {
		t.Fatal("validation telemetry must be enabled with zeon_route_validation")
	}
}

func TestMandatoryValidationServicesAreAllowlisted(t *testing.T) {
	testHosts := map[string]string{
		"Gosuslugi":     "www.gosuslugi.ru",
		"ESIA":          "esia.gosuslugi.ru",
		"Nalog":         "lkfl2.nalog.ru",
		"Mos.ru":        "www.mos.ru",
		"CBR":           "www.cbr.ru",
		"SBP":           "sbp.nspk.ru",
		"Sber":          "online.sberbank.ru",
		"T-Bank":        "www.tbank.ru",
		"Alfa-Bank":     "alfabank.ru",
		"VTB":           "www.vtb.ru",
		"Gazprombank":   "gazprombank.ru",
		"Yandex":        "yandex.ru",
		"Yandex Search": "yandex.ru/search",
		"Yandex Maps":   "yandex.ru/maps",
		"Yandex Music":  "music.yandex.ru",
		"Kinopoisk":     "www.kinopoisk.ru",
		"Wildberries":   "www.wildberries.ru",
		"Ozon":          "www.ozon.ru",
		"Avito":         "www.avito.ru",
		"Megamarket":    "megamarket.ru",
		"Yandex Market": "market.yandex.ru",
		"VK":            "vk.com",
		"Mail.ru":       "mail.ru",
		"OK":            "ok.ru",
		"Dzen":          "dzen.ru",
		"2GIS":          "2gis.ru",
		"Rutube":        "rutube.ru",
		"RuStore":       "rustore.ru",
		"RZD":           "rzd.ru",
		"Aeroflot":      "aeroflot.ru",
		"HH":            "hh.ru",
		"RIA":           "ria.ru",
		"Lenta":         "lenta.ru",
	}
	for service, hostOrURL := range testHosts {
		host := strings.Split(hostOrURL, "/")[0]
		if !isValidationHostname(host) {
			t.Errorf("%s host %q is not allowlisted", service, host)
		}
	}
	if isValidationHostname("private.example") {
		t.Fatal("unrelated browsing destination must not be allowlisted")
	}
	if isValidationHostname("yandex.ru.evil.example") {
		t.Fatal("suffix matching must enforce a DNS label boundary")
	}
}

func TestResolvedIPHashIsSaltedAndGenerationScoped(t *testing.T) {
	state := withFreshTelemetry(t)
	address := netip.MustParseAddr("203.0.113.42")
	first := hashAddress(address, "generation-1")
	second := hashAddress(address, "generation-1")
	nextGeneration := hashAddress(address, "generation-2")
	if first != second {
		t.Fatal("hash must be stable within a generation")
	}
	if first == nextGeneration {
		t.Fatal("hash must change between session generations")
	}
	if strings.Contains(first, address.String()) {
		t.Fatal("telemetry hash leaked the plaintext address")
	}
	if !strings.HasPrefix(first, "hmac-sha256:") {
		t.Fatalf("unexpected hash format %q", first)
	}
	state.saltReady = false
	if got := hashAddress(address, "generation-1"); got != "" {
		t.Fatalf("hashing must fail closed without a random salt, got %q", got)
	}
}

func TestDNSCorrelationRecoversAllowlistedHostnameAfterCNAMEReverseMapping(t *testing.T) {
	state := withFreshTelemetry(t)
	t.Setenv(sessionGenerationEnv, "generation-9")
	address := netip.MustParseAddr("2001:db8::7")
	hash := hashAddress(address, sessionGeneration())
	state.remember(dnsCorrelation{
		hostname:       "yandex.ru",
		mode:           "DIRECT",
		matchedRule:    "dns[4]:route",
		matchedRuleSet: "zeon-ru-yandex",
		ipHashes:       []string{hash},
		generation:     sessionGeneration(),
		expiresAt:      state.now().Add(dnsCorrelationTTL),
	})
	metadata := &adapter.InboundContext{
		Domain:      "foreign-cdn.example",
		Destination: M.Socksaddr{Addr: address},
	}
	hostname, decision, allowed := routeHostname(metadata, routeAddresses(metadata))
	if !allowed || hostname != "yandex.ru" {
		t.Fatalf("unexpected correlated hostname: allowed=%v hostname=%q", allowed, hostname)
	}
	if decision == nil || decision.mode != "DIRECT" {
		t.Fatalf("unexpected DNS correlation: %#v", decision)
	}
}

func TestSharedResolvedIPDoesNotMisattributeHostname(t *testing.T) {
	state := withFreshTelemetry(t)
	t.Setenv(sessionGenerationEnv, "generation-shared")
	address := netip.MustParseAddr("198.51.100.18")
	hash := hashAddress(address, sessionGeneration())
	for _, hostname := range []string{"yandex.ru", "wildberries.ru"} {
		state.remember(dnsCorrelation{
			hostname:   hostname,
			mode:       "DIRECT",
			ipHashes:   []string{hash},
			generation: sessionGeneration(),
			expiresAt:  state.now().Add(dnsCorrelationTTL),
		})
	}
	metadata := &adapter.InboundContext{
		Domain:      "shared-cdn.example",
		Destination: M.Socksaddr{Addr: address},
	}
	if hostname, _, allowed := routeHostname(metadata, routeAddresses(metadata)); allowed {
		t.Fatalf("ambiguous shared IP was attributed to %q", hostname)
	}
}

func TestDNSCorrelationIsBoundedAndExpires(t *testing.T) {
	state := withFreshTelemetry(t)
	now := time.Unix(1_700_000_000, 0)
	state.now = func() time.Time { return now }
	for i := 0; i < maxDNSCorrelations+20; i++ {
		hostname := "host-" + strings.Repeat("x", i%7) + "-" + time.Unix(int64(i), 0).Format("150405") + ".yandex.ru"
		state.remember(dnsCorrelation{
			hostname:   hostname,
			generation: "",
			expiresAt:  now.Add(dnsCorrelationTTL),
		})
	}
	if len(state.byHostname) != maxDNSCorrelations {
		t.Fatalf("correlation size=%d, want %d", len(state.byHostname), maxDNSCorrelations)
	}
	now = now.Add(dnsCorrelationTTL + time.Second)
	if _, loaded := state.lookupHostname(state.hostnameOrder[len(state.hostnameOrder)-1]); loaded {
		t.Fatal("expired correlation must not be returned")
	}
	if len(state.byHostname) != 0 || len(state.byIPHash) != 0 {
		t.Fatal("expired correlation state was not removed")
	}
}

func TestStructuredEventContainsRequiredFieldsWithoutPlaintextIP(t *testing.T) {
	event := validationEvent{
		Kind:           "route",
		Hostname:       "wildberries.ru",
		ResolvedIPHash: "hmac-sha256:0123456789abcdef0123456789abcdef",
		IPVersion:      "IPv4",
		MatchedRule:    "route[7]:route",
		MatchedRuleSet: "zeon-ru-wildberries",
		Route:          "DIRECT",
		DNS:            "DIRECT",
		Protocol:       "TLS/TCP",
		Generation:     "generation-12",
	}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		`"hostname"`,
		`"resolvedIpHash"`,
		`"ipVersion"`,
		`"matchedRule"`,
		`"matchedRuleSet"`,
		`"route"`,
		`"dns"`,
		`"protocol"`,
		`"generation"`,
	} {
		if !strings.Contains(string(payload), field) {
			t.Errorf("required field %s missing from %s", field, payload)
		}
	}
	if strings.Contains(string(payload), "203.0.113.42") {
		t.Fatal("structured event leaked a plaintext address")
	}
}

func TestUnknownDNSCorrelationIsEmittedAsValidationFailure(t *testing.T) {
	withFreshTelemetry(t)
	var output bytes.Buffer
	factory := SBLog.NewDefaultFactory(
		context.Background(),
		SBLog.Formatter{DisableColors: true, DisableTimestamp: true},
		&output,
		"",
		nil,
		false,
	)
	t.Cleanup(func() {
		_ = factory.Close()
	})
	RecordRoute(
		context.Background(),
		factory.NewLogger("validation-test"),
		&adapter.InboundContext{
			Network:     "tcp",
			Destination: M.Socksaddr{Fqdn: "yandex.ru", Port: 443},
		},
		nil,
		-1,
		nil,
		false,
	)
	logLine := output.String()
	for _, expected := range []string{
		validationLogPrefix,
		`"dns":"UNKNOWN"`,
		`"validationFailure":"DNS_UNKNOWN_OWN_DOH_OR_UNOBSERVED"`,
	} {
		if !strings.Contains(logLine, expected) {
			t.Fatalf("validation log does not contain %q: %s", expected, logLine)
		}
	}
}

func TestRuleSetExtraction(t *testing.T) {
	if got := extractRuleSet("network=tcp rule_set=zapret-ru-domains"); got != "zapret-ru-domains" {
		t.Fatalf("single rule set = %q", got)
	}
	if got := extractRuleSet("rule_set=[first second] domain=example"); got != "first,second" {
		t.Fatalf("multiple rule sets = %q", got)
	}
}

func TestRouteAndDNSOutcomeClassification(t *testing.T) {
	direct := fakeOutbound{outboundType: C.TypeDirect, tag: "direct §hide§"}
	proxy := fakeOutbound{outboundType: "selector", tag: "select"}
	if got := routeOutcome(nil, direct, false); got != "DIRECT" {
		t.Fatalf("direct outcome = %q", got)
	}
	if got := routeOutcome(nil, proxy, false); got != "VPN" {
		t.Fatalf("proxy outcome = %q", got)
	}
	if got := routeOutcome(nil, proxy, true); got != "BLOCK" {
		t.Fatalf("blocked outcome = %q", got)
	}
	bypassRule := fakeRule{action: fakeAction{actionType: C.RuleActionTypeBypass}}
	if got := routeOutcome(bypassRule, nil, false); got != "DIRECT" {
		t.Fatalf("bypass outcome = %q", got)
	}

	directDNS := &fakeDNSTransport{tag: "dns-direct"}
	remoteDNS := &fakeDNSTransport{tag: "dns-remote"}
	if got := dnsOutcome(directDNS, false); got != "DIRECT" {
		t.Fatalf("direct DNS outcome = %q", got)
	}
	if got := dnsOutcome(remoteDNS, false); got != "REMOTE" {
		t.Fatalf("remote DNS outcome = %q", got)
	}
	if got := dnsOutcome(remoteDNS, true); got != "BLOCK" {
		t.Fatalf("blocked DNS outcome = %q", got)
	}
}

func TestMatchedRuleDoesNotCopyUnrelatedRuleContents(t *testing.T) {
	rule := fakeRule{
		description: "domain=[yandex.ru unrelated-private.example] rule_set=zeon-ru-yandex",
		action:      fakeAction{actionType: "route", description: "route(direct)"},
	}
	matchedRule, matchedRuleSet := describeRule(rule, 17)
	if matchedRule != "route[17]:route" {
		t.Fatalf("matched rule = %q", matchedRule)
	}
	if matchedRuleSet != "zeon-ru-yandex" {
		t.Fatalf("matched rule set = %q", matchedRuleSet)
	}
	if strings.Contains(matchedRule, "unrelated-private.example") {
		t.Fatal("matched rule copied unrelated rule contents")
	}
}

func withFreshTelemetry(t *testing.T) *telemetryState {
	t.Helper()
	previous := telemetry
	state := newTelemetryState()
	for i := range state.salt {
		state.salt[i] = byte(i + 1)
	}
	state.saltReady = true
	telemetry = state
	t.Cleanup(func() {
		telemetry = previous
	})
	return state
}

type fakeRule struct {
	description string
	action      adapter.RuleAction
}

func (r fakeRule) Start() error {
	return nil
}

func (r fakeRule) Close() error {
	return nil
}

func (r fakeRule) Match(*adapter.InboundContext) bool {
	return true
}

func (r fakeRule) String() string {
	return r.description
}

func (r fakeRule) Type() string {
	return "default"
}

func (r fakeRule) Action() adapter.RuleAction {
	return r.action
}

type fakeAction struct {
	actionType  string
	description string
}

func (a fakeAction) Type() string {
	return a.actionType
}

func (a fakeAction) String() string {
	return a.description
}

type fakeOutbound struct {
	outboundType string
	tag          string
}

func (o fakeOutbound) Type() string {
	return o.outboundType
}

func (o fakeOutbound) Tag() string {
	return o.tag
}

func (fakeOutbound) Network() []string {
	return []string{"tcp", "udp"}
}

func (fakeOutbound) Dependencies() []string {
	return nil
}

func (fakeOutbound) DisplayType() string {
	return ""
}

func (fakeOutbound) IsReady() bool {
	return true
}

func (fakeOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, nil
}

func (fakeOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, nil
}

type fakeDNSTransport struct {
	tag string
}

func (*fakeDNSTransport) Start(adapter.StartStage) error {
	return nil
}

func (*fakeDNSTransport) Close() error {
	return nil
}

func (*fakeDNSTransport) Type() string {
	return "https"
}

func (t *fakeDNSTransport) Tag() string {
	return t.tag
}

func (*fakeDNSTransport) Dependencies() []string {
	return nil
}

func (*fakeDNSTransport) Reset() {
}

func (*fakeDNSTransport) Exchange(context.Context, *mDNS.Msg) (*mDNS.Msg, error) {
	return nil, nil
}
