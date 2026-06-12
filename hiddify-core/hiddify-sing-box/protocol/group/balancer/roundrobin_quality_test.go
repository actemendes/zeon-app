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
