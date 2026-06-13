package balancer

import (
	"context"
	"net"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type qualityTestOutbound struct {
	tag string
}

func (o qualityTestOutbound) Type() string           { return "test" }
func (o qualityTestOutbound) Tag() string            { return o.tag }
func (o qualityTestOutbound) Network() []string      { return []string{N.NetworkTCP, N.NetworkUDP} }
func (o qualityTestOutbound) Dependencies() []string { return nil }
func (o qualityTestOutbound) DisplayType() string    { return "test" }
func (o qualityTestOutbound) IsReady() bool          { return true }
func (o qualityTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, nil
}
func (o qualityTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, nil
}

func TestRoundRobinQualityFilterPrefersGoodOverLowDelayBad(t *testing.T) {
	badLowDelay := qualityTestOutbound{tag: "ServerA"}
	goodHigherDelay := qualityTestOutbound{tag: "ServerB"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {badLowDelay, goodHigherDelay},
	}
	history := map[string]*adapter.URLTestHistory{
		"ServerA": {
			Delay:        35,
			QualityScore: 20,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
			LastError:    "i/o timeout",
		},
		"ServerB": {
			Delay:        110,
			QualityScore: 90,
			QualityLevel: monitoring.QualityLevelExcellent,
			AutoAllowed:  true,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one good candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "ServerB" {
		t.Fatalf("expected good server to win, got %s", got)
	}
}

func TestRoundRobinQualityFilterUsesMediumFallback(t *testing.T) {
	bad := qualityTestOutbound{tag: "bad"}
	medium := qualityTestOutbound{tag: "medium"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {bad, medium},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad": {
			Delay:        30,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
		"medium": {
			Delay:        700,
			QualityLevel: monitoring.QualityLevelMedium,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := filtered[N.NetworkTCP][0].Tag(); got != "medium" {
		t.Fatalf("expected medium fallback, got %s", got)
	}
}

func TestRoundRobinQualityFilterUsesUnknownCompatibilityWithoutKnownBad(t *testing.T) {
	bad := qualityTestOutbound{tag: "bad"}
	unknown := qualityTestOutbound{tag: "unknown"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {bad, unknown},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad": {
			Delay:        30,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one unknown compatibility candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "unknown" {
		t.Fatalf("expected unknown fallback to exclude known bad, got %s", got)
	}
}

func TestRoundRobinQualityFilterEmergencyFallbackOnlyWhenNoUsableCandidates(t *testing.T) {
	badA := qualityTestOutbound{tag: "bad-a"}
	badB := qualityTestOutbound{tag: "bad-b"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {badA, badB},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad-a": {
			Delay:        35,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
		"bad-b": {
			Delay:        50,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 2 {
		t.Fatalf("expected emergency fallback to retain all original candidates, got %d", got)
	}
}

func TestRoundRobinHealthFilterExcludesVerySlowWhenGoodExists(t *testing.T) {
	verySlow := qualityTestOutbound{tag: "very-slow"}
	normal := qualityTestOutbound{tag: "normal"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {verySlow, normal},
	}
	history := map[string]*adapter.URLTestHistory{
		"very-slow": {
			Delay:               35,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedScore:          25,
			SpeedLevel:          monitoring.SpeedLevelVerySlow,
			CombinedHealthScore: 25,
			CombinedHealthLevel: monitoring.HealthLevelWeak,
		},
		"normal": {
			Delay:               110,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedScore:          75,
			SpeedLevel:          monitoring.SpeedLevelNormal,
			CombinedHealthScore: 75,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one healthy candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "normal" {
		t.Fatalf("expected normal speed server, got %s", got)
	}
}

func TestRoundRobinHealthFilterUsesQualityFallbackWhenSpeedUnknown(t *testing.T) {
	unknownSpeed := qualityTestOutbound{tag: "unknown-speed"}
	bad := qualityTestOutbound{tag: "bad"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {unknownSpeed, bad},
	}
	history := map[string]*adapter.URLTestHistory{
		"unknown-speed": {
			Delay:        90,
			QualityScore: 90,
			QualityLevel: monitoring.QualityLevelExcellent,
			AutoAllowed:  true,
			SpeedLevel:   monitoring.SpeedLevelUnknown,
		},
		"bad": {
			Delay:               30,
			QualityScore:        20,
			QualityLevel:        monitoring.QualityLevelBad,
			AutoAllowed:         false,
			CombinedHealthLevel: monitoring.HealthLevelBad,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected quality-only compatibility candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "unknown-speed" {
		t.Fatalf("expected unknown speed quality fallback, got %s", got)
	}
}

func TestRoundRobinExternalHealthExcludesCloudflareFastDiscordBad(t *testing.T) {
	russiaLike := qualityTestOutbound{tag: "ru-fast-cdn-bad-discord"}
	stable := qualityTestOutbound{tag: "stable-external"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {russiaLike, stable},
	}
	history := map[string]*adapter.URLTestHistory{
		"ru-fast-cdn-bad-discord": {
			Delay:               28,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedKbps:           20000,
			SpeedScore:          100,
			SpeedLevel:          monitoring.SpeedLevelFast,
			SpeedSource:         "cloudflare",
			ExternalHealthScore: 35,
			ExternalHealthLevel: monitoring.HealthLevelWeak,
			CombinedHealthScore: 35,
			CombinedHealthLevel: monitoring.HealthLevelWeak,
			HealthReason:        "discord-timeout",
		},
		"stable-external": {
			Delay:               110,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedKbps:           8000,
			SpeedScore:          75,
			SpeedLevel:          monitoring.SpeedLevelNormal,
			SpeedSource:         "external-origin",
			ExternalHealthScore: 75,
			ExternalHealthLevel: monitoring.HealthLevelGood,
			CombinedHealthScore: 75,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one external-healthy candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "stable-external" {
		t.Fatalf("expected stable external server to win, got %s", got)
	}
}

func TestRoundRobinSortsCombinedHealthBeforeDelay(t *testing.T) {
	lowPingLowerHealth := qualityTestOutbound{tag: "low-ping-lower-health"}
	higherPingBetterHealth := qualityTestOutbound{tag: "higher-ping-better-health"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {lowPingLowerHealth, higherPingBetterHealth},
	}
	history := map[string]*adapter.URLTestHistory{
		"low-ping-lower-health": {
			Delay:               25,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 70,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
		"higher-ping-better-health": {
			Delay:               55,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 90,
			CombinedHealthLevel: monitoring.HealthLevelExcellent,
		},
	}

	sorted := sortOutboundsByHealthThenDelay(outbounds, history)
	if got := sorted[N.NetworkTCP][0].Tag(); got != "higher-ping-better-health" {
		t.Fatalf("expected better combined health to sort before lower ping, got %s", got)
	}
}

func TestRoundRobinQualityFilterExcludesCloudflareOnlyMediumWhenGoodPublicExists(t *testing.T) {
	cloudflareOnly := qualityTestOutbound{tag: "cloudflare-only"}
	publicGood := qualityTestOutbound{tag: "public-good"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {cloudflareOnly, publicGood},
	}
	history := map[string]*adapter.URLTestHistory{
		"cloudflare-only": {
			Delay:               25,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedSource:         "cloudflare",
			ExternalHealthScore: 69,
			ExternalHealthLevel: monitoring.HealthLevelMedium,
			CombinedHealthScore: 69,
			CombinedHealthLevel: monitoring.HealthLevelMedium,
			HealthReason:        "cloudflare-only",
		},
		"public-good": {
			Delay:               80,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedSource:         "hetzner-fsn1",
			ExternalHealthScore: 80,
			ExternalHealthLevel: monitoring.HealthLevelGood,
			CombinedHealthScore: 80,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected only public-good normal candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "public-good" {
		t.Fatalf("expected public-good candidate, got %s", got)
	}
}
