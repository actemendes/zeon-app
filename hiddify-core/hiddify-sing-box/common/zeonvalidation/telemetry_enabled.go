//go:build zeon_route_validation

package zeonvalidation

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing/common/logger"
)

const (
	validationLogPrefix  = "ZEON_ROUTE_VALIDATION "
	sessionGenerationEnv = "ZEON_SESSION_GENERATION"
	maxDNSCorrelations   = 256
	dnsCorrelationTTL    = 10 * time.Minute
)

// This list intentionally names only Stage 2.8 browser-validation services and
// their known first-party/static families. It does not include a broad .ru rule:
// validation telemetry must never become ordinary browsing history.
var validationDomainSuffixes = []string{
	// Government and public infrastructure.
	"gosuslugi.ru",
	"goskey.ru",
	"nalog.gov.ru",
	"nalog.ru",
	"mos.ru",
	"cbr.ru",
	"nspk.ru",

	// Banks.
	"sber.ru",
	"sberbank.ru",
	"tbank.ru",
	"tinkoff.ru",
	"t-static.ru",
	"alfabank.ru",
	"alfacdn.ru",
	"vtb.ru",
	"gazprombank.ru",
	"gpb.ru",
	"raiffeisen.ru",
	"sovcombank.ru",

	// Yandex services and required first-party resource families.
	"ya.ru",
	"yandex.ru",
	"yandex.com",
	"yandex.net",
	"yastatic.net",
	"yandex.st",
	"yandexcloud.net",
	"yandexcloud.ru",
	"kinopoisk.ru",
	"kinopoisk.com",

	// Wildberries services and required first-party resource families.
	"wildberries.ru",
	"wildberries.by",
	"wildberries.kz",
	"wildberries.am",
	"wildberries.uz",
	"wildberries.kg",
	"wb.ru",
	"wbbasket.ru",
	"wbstatic.net",
	"wbcontent.net",
	"rwb.ru",
	"wibes.ru",

	// Marketplaces and classifieds.
	"ozon.ru",
	"ozonusercontent.com",
	"avito.ru",
	"avito.st",
	"megamarket.ru",
	"sbermegamarket.ru",

	// Social, media, maps, and app distribution.
	"vk.com",
	"vk.ru",
	"userapi.com",
	"vk-cdn.net",
	"mail.ru",
	"imgsmail.ru",
	"ok.ru",
	"odnoklassniki.ru",
	"mycdn.me",
	"dzen.ru",
	"2gis.ru",
	"2gis.com",
	"2gis.cloud",
	"rutube.ru",
	"rutube.video",
	"rustore.ru",
	"rustorecdn.ru",

	// Travel, jobs, and news.
	"rzd.ru",
	"aeroflot.ru",
	"hh.ru",
	"hhcdn.ru",
	"ria.ru",
	"lenta.ru",

	// Explicit public-suffix browser acceptance targets. These entries only
	// permit validation telemetry; production routing still comes from the
	// bundled zapret-ru-domains rule set.
	"ripn.su",
	"xn--80aa3ak5a.xn--p1ai",
}

type validationEvent struct {
	Kind              string   `json:"kind"`
	Hostname          string   `json:"hostname"`
	ResolvedIPHash    string   `json:"resolvedIpHash"`
	IPVersion         string   `json:"ipVersion"`
	MatchedRule       string   `json:"matchedRule"`
	MatchedRuleSet    string   `json:"matchedRuleSet"`
	Route             string   `json:"route"`
	DNS               string   `json:"dns"`
	Protocol          string   `json:"protocol"`
	Generation        string   `json:"generation"`
	ValidationFailure string   `json:"validationFailure,omitempty"`
	DNSMatchedRule    string   `json:"dnsMatchedRule,omitempty"`
	DNSMatchedRuleSet string   `json:"dnsMatchedRuleSet,omitempty"`
	CNAMEChain        []string `json:"cnameChain,omitempty"`
}

type dnsCorrelation struct {
	hostname       string
	mode           string
	matchedRule    string
	matchedRuleSet string
	ipHashes       []string
	generation     string
	expiresAt      time.Time
}

type telemetryState struct {
	mu            sync.Mutex
	salt          [sha256.Size]byte
	saltReady     bool
	byHostname    map[string]dnsCorrelation
	hostnameOrder []string
	byIPHash      map[string]map[string]struct{}
	now           func() time.Time
}

var telemetry = newTelemetryState()

func newTelemetryState() *telemetryState {
	state := &telemetryState{
		byHostname: make(map[string]dnsCorrelation),
		byIPHash:   make(map[string]map[string]struct{}),
		now:        time.Now,
	}
	if _, err := rand.Read(state.salt[:]); err == nil {
		state.saltReady = true
	}
	return state
}

// Enabled reports whether validation-only route telemetry is compiled in.
func Enabled() bool {
	return true
}

// RecordRoute emits one structured event per resolved address for an allowlisted
// Stage 2.8 validation host. It never logs a plaintext destination IP.
func RecordRoute(
	ctx context.Context,
	log logger.ContextLogger,
	metadata *adapter.InboundContext,
	rule adapter.Rule,
	ruleIndex int,
	outbound adapter.Outbound,
	blocked bool,
) {
	if metadata == nil {
		return
	}
	addresses := routeAddresses(metadata)
	hostname, decision, allowed := routeHostname(metadata, addresses)
	if !allowed {
		return
	}
	matchedRule, matchedRuleSet := describeRule(rule, ruleIndex)
	route := routeOutcome(rule, outbound, blocked)
	dnsMode := "UNKNOWN"
	dnsMatchedRule := ""
	dnsMatchedRuleSet := ""
	validationFailure := ""
	if decision != nil {
		dnsMode = decision.mode
		dnsMatchedRule = decision.matchedRule
		dnsMatchedRuleSet = decision.matchedRuleSet
	} else {
		// UNKNOWN is never a validation PASS. It usually means the application
		// used its own DoH path or the matching DNS observation was missed.
		validationFailure = "DNS_UNKNOWN_OWN_DOH_OR_UNOBSERVED"
	}
	protocol := routeProtocol(metadata)
	generation := sessionGeneration()
	emitForAddresses(log, ctx, validationEvent{
		Kind:              "route",
		Hostname:          hostname,
		MatchedRule:       matchedRule,
		MatchedRuleSet:    matchedRuleSet,
		Route:             route,
		DNS:               dnsMode,
		Protocol:          protocol,
		Generation:        generation,
		ValidationFailure: validationFailure,
		DNSMatchedRule:    dnsMatchedRule,
		DNSMatchedRuleSet: dnsMatchedRuleSet,
	}, addresses)
}

// RecordDNS records only bounded, in-memory correlation state and emits a
// structured event for an allowlisted Stage 2.8 validation host.
func RecordDNS(
	ctx context.Context,
	log logger.ContextLogger,
	hostname string,
	addresses []netip.Addr,
	cnameChain []string,
	queryType uint16,
	rule adapter.DNSRule,
	ruleIndex int,
	transport adapter.DNSTransport,
	blocked bool,
	failed bool,
) {
	hostname = normalizeHostname(hostname)
	if !isValidationHostname(hostname) {
		return
	}
	matchedRule, matchedRuleSet := describeDNSRule(rule, ruleIndex)
	dnsMode := dnsOutcome(transport, blocked)
	route := "VPN"
	if blocked {
		route = "BLOCK"
	} else if dnsMode == "DIRECT" {
		route = "DIRECT"
	}
	generation := sessionGeneration()
	validationFailure := ""
	if failed {
		validationFailure = "DNS_EXCHANGE_FAILED"
	}
	addresses = uniqueAddresses(addresses)
	telemetry.remember(dnsCorrelation{
		hostname:       hostname,
		mode:           dnsMode,
		matchedRule:    matchedRule,
		matchedRuleSet: matchedRuleSet,
		ipHashes:       hashAddresses(addresses, generation),
		generation:     generation,
		expiresAt:      telemetry.now().Add(dnsCorrelationTTL),
	})
	emitForAddresses(log, ctx, validationEvent{
		Kind:              "dns",
		Hostname:          hostname,
		MatchedRule:       matchedRule,
		MatchedRuleSet:    matchedRuleSet,
		Route:             route,
		DNS:               dnsMode,
		Protocol:          dnsProtocol(queryType),
		Generation:        generation,
		ValidationFailure: validationFailure,
		CNAMEChain:        sanitizeCNAMEChain(cnameChain),
	}, addresses)
}

func sanitizeCNAMEChain(chain []string) []string {
	sanitized := make([]string, 0, len(chain))
	seen := make(map[string]struct{}, len(chain))
	for _, candidate := range chain {
		candidate = normalizeHostname(candidate)
		if candidate == "" || len(candidate) > 253 {
			continue
		}
		if _, err := netip.ParseAddr(candidate); err == nil {
			continue
		}
		if _, loaded := seen[candidate]; loaded {
			continue
		}
		seen[candidate] = struct{}{}
		sanitized = append(sanitized, candidate)
		if len(sanitized) == 16 {
			break
		}
	}
	return sanitized
}

func emitForAddresses(log logger.ContextLogger, ctx context.Context, base validationEvent, addresses []netip.Addr) {
	if len(addresses) == 0 {
		emit(log, ctx, base)
		return
	}
	for _, address := range uniqueAddresses(addresses) {
		event := base
		event.ResolvedIPHash = hashAddress(address, event.Generation)
		if address.Unmap().Is4() {
			event.IPVersion = "IPv4"
		} else if address.Is6() {
			event.IPVersion = "IPv6"
		}
		emit(log, ctx, event)
	}
}

func emit(log logger.ContextLogger, ctx context.Context, event validationEvent) {
	payload, err := json.Marshal(event)
	if err != nil {
		return
	}
	// The mobile bridge subscribes at warning level. Keep this promotion in the
	// validation-tagged implementation so evidence is observable without
	// changing production logging or persisting ordinary browsing history.
	log.WarnContext(ctx, validationLogPrefix, string(payload))
}

func routeHostname(metadata *adapter.InboundContext, addresses []netip.Addr) (string, *dnsCorrelation, bool) {
	var allowedCandidate string
	for _, candidate := range []string{metadata.Domain, metadata.Destination.Fqdn} {
		candidate = normalizeHostname(candidate)
		if isValidationHostname(candidate) {
			if allowedCandidate == "" {
				allowedCandidate = candidate
			}
			if decision, loaded := telemetry.lookupHostname(candidate); loaded {
				return candidate, &decision, true
			}
		}
	}
	generation := sessionGeneration()
	for _, address := range addresses {
		if decision, loaded := telemetry.lookupIPHash(hashAddress(address, generation), generation); loaded {
			return decision.hostname, &decision, true
		}
	}
	if allowedCandidate != "" {
		return allowedCandidate, nil, true
	}
	return "", nil, false
}

func routeAddresses(metadata *adapter.InboundContext) []netip.Addr {
	addresses := make([]netip.Addr, 0, len(metadata.DestinationAddresses)+1)
	if metadata.Destination.Addr.IsValid() {
		addresses = append(addresses, metadata.Destination.Addr)
	}
	addresses = append(addresses, metadata.DestinationAddresses...)
	return uniqueAddresses(addresses)
}

func uniqueAddresses(addresses []netip.Addr) []netip.Addr {
	unique := make([]netip.Addr, 0, len(addresses))
	seen := make(map[netip.Addr]struct{}, len(addresses))
	for _, address := range addresses {
		if !address.IsValid() {
			continue
		}
		address = address.Unmap()
		if _, exists := seen[address]; exists {
			continue
		}
		seen[address] = struct{}{}
		unique = append(unique, address)
	}
	return unique
}

func hashAddresses(addresses []netip.Addr, generation string) []string {
	hashes := make([]string, 0, len(addresses))
	for _, address := range addresses {
		if address.IsValid() {
			hash := hashAddress(address, generation)
			if hash != "" {
				hashes = append(hashes, hash)
			}
		}
	}
	return hashes
}

func hashAddress(address netip.Addr, generation string) string {
	if !address.IsValid() {
		return ""
	}
	if !telemetry.saltReady {
		return ""
	}
	mac := hmac.New(sha256.New, telemetry.salt[:])
	_, _ = mac.Write([]byte(generation))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write(address.Unmap().AsSlice())
	// A 128-bit truncation is sufficient for validation correlation and keeps
	// the log compact; the per-process secret prevents offline IP enumeration.
	return "hmac-sha256:" + hex.EncodeToString(mac.Sum(nil)[:16])
}

func (s *telemetryState) remember(decision dnsCorrelation) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked()
	if existing, loaded := s.byHostname[decision.hostname]; loaded {
		for _, hash := range existing.ipHashes {
			s.removeIPHostnameLocked(hash, decision.hostname)
		}
	} else {
		for len(s.byHostname) >= maxDNSCorrelations && len(s.hostnameOrder) > 0 {
			s.evictOldestLocked()
		}
		s.hostnameOrder = append(s.hostnameOrder, decision.hostname)
	}
	s.byHostname[decision.hostname] = decision
	for _, hash := range decision.ipHashes {
		hostnames := s.byIPHash[hash]
		if hostnames == nil {
			hostnames = make(map[string]struct{})
			s.byIPHash[hash] = hostnames
		}
		hostnames[decision.hostname] = struct{}{}
	}
}

func (s *telemetryState) lookupHostname(hostname string) (dnsCorrelation, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked()
	decision, loaded := s.byHostname[hostname]
	if !loaded || decision.generation != sessionGeneration() {
		return dnsCorrelation{}, false
	}
	return decision, true
}

func (s *telemetryState) lookupIPHash(hash string, generation string) (dnsCorrelation, bool) {
	if hash == "" {
		return dnsCorrelation{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked()
	hostnames, loaded := s.byIPHash[hash]
	if !loaded || len(hostnames) != 1 {
		return dnsCorrelation{}, false
	}
	var hostname string
	for hostname = range hostnames {
	}
	decision, loaded := s.byHostname[hostname]
	if !loaded || decision.generation != generation {
		return dnsCorrelation{}, false
	}
	return decision, true
}

func (s *telemetryState) pruneLocked() {
	now := s.now()
	activeOrder := s.hostnameOrder[:0]
	for _, hostname := range s.hostnameOrder {
		decision, loaded := s.byHostname[hostname]
		if loaded && now.Before(decision.expiresAt) {
			activeOrder = append(activeOrder, hostname)
			continue
		}
		s.removeHostnameLocked(hostname)
	}
	s.hostnameOrder = activeOrder
}

func (s *telemetryState) evictOldestLocked() {
	if len(s.hostnameOrder) == 0 {
		return
	}
	hostname := s.hostnameOrder[0]
	s.hostnameOrder = s.hostnameOrder[1:]
	s.removeHostnameLocked(hostname)
}

func (s *telemetryState) removeHostnameLocked(hostname string) {
	if decision, loaded := s.byHostname[hostname]; loaded {
		for _, hash := range decision.ipHashes {
			s.removeIPHostnameLocked(hash, hostname)
		}
		delete(s.byHostname, hostname)
	}
}

func (s *telemetryState) removeIPHostnameLocked(hash string, hostname string) {
	hostnames := s.byIPHash[hash]
	delete(hostnames, hostname)
	if len(hostnames) == 0 {
		delete(s.byIPHash, hash)
	}
}

func describeRule(rule adapter.Rule, index int) (string, string) {
	if rule == nil {
		return "final", ""
	}
	description := strings.TrimSpace(rule.String())
	matchedRule := "route[" + strconv.Itoa(index) + "]:" + rule.Action().Type()
	return matchedRule, extractRuleSet(description)
}

func describeDNSRule(rule adapter.DNSRule, index int) (string, string) {
	if rule == nil {
		return "dns-final", ""
	}
	description := strings.TrimSpace(rule.String())
	matchedRule := "dns[" + strconv.Itoa(index) + "]:" + rule.Action().Type()
	return matchedRule, extractRuleSet(description)
}

func extractRuleSet(description string) string {
	const marker = "rule_set="
	start := strings.Index(description, marker)
	if start == -1 {
		return ""
	}
	value := description[start+len(marker):]
	if strings.HasPrefix(value, "[") {
		if end := strings.IndexByte(value, ']'); end != -1 {
			return strings.Join(strings.Fields(value[1:end]), ",")
		}
	}
	if end := strings.IndexAny(value, " )"); end != -1 {
		value = value[:end]
	}
	return strings.Trim(value, "[]")
}

func routeOutcome(rule adapter.Rule, outbound adapter.Outbound, blocked bool) string {
	if blocked {
		return "BLOCK"
	}
	if rule != nil && rule.Action().Type() == C.RuleActionTypeBypass {
		return "DIRECT"
	}
	if outbound == nil {
		return "VPN"
	}
	if outbound.Type() == C.TypeDirect {
		return "DIRECT"
	}
	return "VPN"
}

func dnsOutcome(transport adapter.DNSTransport, blocked bool) string {
	if blocked {
		return "BLOCK"
	}
	if transport == nil {
		// A predefined local DNS response has no transport.
		return "DIRECT"
	}
	tag := strings.ToLower(transport.Tag())
	if strings.Contains(tag, "direct") || strings.Contains(tag, "local") {
		return "DIRECT"
	}
	return "REMOTE"
}

func routeProtocol(metadata *adapter.InboundContext) string {
	network := strings.ToUpper(metadata.Network)
	protocol := strings.ToUpper(metadata.Protocol)
	if protocol == "" {
		return network
	}
	if network == "" || protocol == network {
		return protocol
	}
	return protocol + "/" + network
}

func dnsProtocol(queryType uint16) string {
	switch queryType {
	case 1:
		return "DNS/A"
	case 28:
		return "DNS/AAAA"
	case 64:
		return "DNS/SVCB"
	case 65:
		return "DNS/HTTPS"
	default:
		return "DNS/TYPE" + strconv.Itoa(int(queryType))
	}
}

func sessionGeneration() string {
	return os.Getenv(sessionGenerationEnv)
}

func normalizeHostname(hostname string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(hostname)), ".")
}

func isValidationHostname(hostname string) bool {
	hostname = normalizeHostname(hostname)
	if hostname == "" {
		return false
	}
	for _, suffix := range validationDomainSuffixes {
		if hostname == suffix || strings.HasSuffix(hostname, "."+suffix) {
			return true
		}
	}
	return false
}
