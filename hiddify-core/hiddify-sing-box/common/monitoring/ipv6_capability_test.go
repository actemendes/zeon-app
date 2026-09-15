package monitoring

import (
	"net/netip"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	M "github.com/sagernet/sing/common/metadata"
)

func TestIPv6CapabilityFreshRequiresCurrentSupportedProof(t *testing.T) {
	now := time.Now()
	history := &adapter.URLTestHistory{IPv6Status: IPv6StatusSupported, IPv6CheckedAt: now.Add(-time.Minute)}
	if !IPv6CapabilityFresh(history, now, 2*time.Minute) {
		t.Fatal("fresh supported proof was rejected")
	}
	if IPv6CapabilityFresh(history, now, 30*time.Second) {
		t.Fatal("expired proof was accepted")
	}
	history.IPv6Status = IPv6StatusUnavailable
	if IPv6CapabilityFresh(history, now, 2*time.Minute) {
		t.Fatal("failed proof was accepted")
	}
}

func TestIPv6CapabilityFreshForModeRequiresAllTargetsOnlyInStrictMode(t *testing.T) {
	now := time.Now()
	partial := &adapter.URLTestHistory{
		IPv6Status:        IPv6StatusSupported,
		IPv6CheckedAt:     now,
		IPv6TargetSuccess: 1,
		IPv6TargetCount:   2,
	}
	if !IPv6CapabilityFreshForMode(partial, C.DomainStrategyPreferIPv6, now, time.Minute) {
		t.Fatal("prefer_ipv6 rejected a fresh partial capability proof")
	}
	if IPv6CapabilityFreshForMode(partial, C.DomainStrategyIPv6Only, now, time.Minute) {
		t.Fatal("ipv6_only accepted a partial capability proof")
	}
	partial.IPv6TargetSuccess = 2
	if !IPv6CapabilityFreshForMode(partial, C.DomainStrategyIPv6Only, now, time.Minute) {
		t.Fatal("ipv6_only rejected a complete capability proof")
	}
}

func TestIPv6CapabilityPresentationMarksPartialStrictProofUnavailable(t *testing.T) {
	partial := ipv6ProbeResult{status: IPv6StatusSupported, successes: 1, attempts: 2}
	if got := ipv6CapabilityStatusForMode(partial, C.DomainStrategyIPv6Only); got != IPv6StatusUnavailable {
		t.Fatalf("strict partial status = %q, want unavailable", got)
	}
	if got := ipv6CapabilityStatusForMode(partial, C.DomainStrategyPreferIPv6); got != IPv6StatusSupported {
		t.Fatalf("preferred-mode partial status = %q, want supported", got)
	}
	complete := ipv6ProbeResult{status: IPv6StatusSupported, successes: 2, attempts: 2}
	if got := ipv6CapabilityStatusForMode(complete, C.DomainStrategyIPv6Only); got != IPv6StatusSupported {
		t.Fatalf("strict complete status = %q, want supported", got)
	}
}

func TestIPv6ProbeTargetLabelUsesOnlyHostname(t *testing.T) {
	if got := ipv6ProbeTargetLabel("https://IPv6.Example.test/private/path?secret=value"); got != "ipv6.example.test" {
		t.Fatalf("target label = %q", got)
	}
}

func TestIPv6TrafficAllowedAppliesFourModeContract(t *testing.T) {
	now := time.Now()
	proof := &adapter.URLTestHistory{
		IPv6Status:        IPv6StatusSupported,
		IPv6CheckedAt:     now,
		IPv6TargetSuccess: 2,
		IPv6TargetCount:   2,
	}
	ipv4 := adapter.InboundContext{IPVersion: 4, Destination: M.SocksaddrFrom(netip.MustParseAddr("192.0.2.1"), 443)}
	ipv6 := adapter.InboundContext{IPVersion: 6, Destination: M.SocksaddrFrom(netip.MustParseAddr("2001:db8::1"), 443)}

	if IPv6TrafficAllowed(C.DomainStrategyIPv4Only, ipv6, proof, now, time.Minute) {
		t.Fatal("ipv4_only accepted IPv6 traffic")
	}
	if !IPv6TrafficAllowed(C.DomainStrategyPreferIPv4, ipv4, nil, now, time.Minute) {
		t.Fatal("prefer_ipv4 rejected IPv4 fallback")
	}
	if IPv6TrafficAllowed(C.DomainStrategyPreferIPv4, ipv6, nil, now, time.Minute) {
		t.Fatal("prefer_ipv4 accepted IPv6 without capability")
	}
	if !IPv6TrafficAllowed(C.DomainStrategyPreferIPv6, ipv6, proof, now, time.Minute) {
		t.Fatal("prefer_ipv6 rejected verified IPv6 traffic")
	}
	if IPv6TrafficAllowed(C.DomainStrategyIPv6Only, ipv4, proof, now, time.Minute) {
		t.Fatal("ipv6_only accepted IPv4 fallback")
	}
	partialProof := *proof
	partialProof.IPv6TargetSuccess = 1
	if IPv6TrafficAllowed(C.DomainStrategyIPv6Only, ipv6, &partialProof, now, time.Minute) {
		t.Fatal("ipv6_only accepted IPv6 traffic with a partial capability proof")
	}
	if !IPv6TrafficAllowed(C.DomainStrategyIPv6Only, ipv6, proof, now, time.Minute) {
		t.Fatal("ipv6_only rejected verified IPv6 traffic")
	}
}

func TestInfrastructureProbeClassificationIsIndeterminate(t *testing.T) {
	if !allIPv6ProbeErrorsInfrastructure([]string{"dns_timeout", "tls_handshake_failed"}, []string{"", ""}) {
		t.Fatal("common DNS/TLS failure must stay indeterminate")
	}
	if allIPv6ProbeErrorsInfrastructure([]string{"timeout", "refused"}, []string{"", ""}) {
		t.Fatal("two transport failures should classify the leaf as unavailable")
	}
	if allIPv6ProbeErrorsInfrastructure([]string{"unknown", "unknown"}, []string{"network unreachable", "no route to host"}) {
		t.Fatal("unknown transport routing failures should classify the leaf as unavailable")
	}
}
