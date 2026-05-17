package config

import (
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestResolveMTUFixedModeKeepsConfiguredValue(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.MTU = 9000
	h.RouteOptions.NetworkMTUMode = NetworkMTUModeFixed

	mtu := resolveMTU(h)
	if mtu.Value != 9000 {
		t.Fatalf("expected fixed mtu 9000, got %d", mtu.Value)
	}
}

func TestResolveMTUAdaptiveByTransport(t *testing.T) {
	tests := []struct {
		name        string
		transport   string
		ifaceMTU    uint32
		expectedMTU uint32
	}{
		{name: "wifi default", transport: NetworkTransportWiFi, ifaceMTU: 0, expectedMTU: 1500},
		{name: "wifi interface", transport: NetworkTransportWiFi, ifaceMTU: 1492, expectedMTU: 1492},
		{name: "wifi low iface fallback sane", transport: NetworkTransportWiFi, ifaceMTU: 1200, expectedMTU: 1500},
		{name: "ethernet default", transport: NetworkTransportEthernet, ifaceMTU: 0, expectedMTU: 1500},
		{name: "cellular", transport: NetworkTransportCellular, ifaceMTU: 0, expectedMTU: 1380},
		{name: "unknown", transport: NetworkTransportUnknown, ifaceMTU: 0, expectedMTU: 1400},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := DefaultHiddifyOptions()
			h.RouteOptions.NetworkMTUMode = NetworkMTUModeAdaptive
			h.RouteOptions.NetworkTransportType = tt.transport
			h.RouteOptions.NetworkInterfaceMTU = tt.ifaceMTU
			mtu := resolveMTU(h)
			if mtu.Value != tt.expectedMTU {
				t.Fatalf("expected mtu %d, got %d", tt.expectedMTU, mtu.Value)
			}
		})
	}
}

func TestResolveMTUDiagnosticModes(t *testing.T) {
	low := DefaultHiddifyOptions()
	low.RouteOptions.NetworkMTUMode = NetworkMTUModeDiagnosticLow
	if got := resolveMTU(low).Value; got != 1280 {
		t.Fatalf("expected diagnostic low mtu 1280, got %d", got)
	}

	high := DefaultHiddifyOptions()
	high.RouteOptions.NetworkMTUMode = NetworkMTUModeDiagnosticHigh
	if got := resolveMTU(high).Value; got != 1500 {
		t.Fatalf("expected diagnostic high mtu 1500, got %d", got)
	}
}

func TestApplyNetworkProfileStableMobileSelectorAndDNS(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileStableMobile
	h.RouteOptions.NetworkMTUMode = NetworkMTUModeFixed
	h.RouteOptions.NetworkTransportType = NetworkTransportCellular
	h.RouteOptions.SelectorTolerance = 0

	applyNetworkProfile(h)
	if h.RouteOptions.NetworkMTUMode != NetworkMTUModeAdaptive {
		t.Fatalf("expected adaptive mode, got %s", h.RouteOptions.NetworkMTUMode)
	}
	if h.MTU != 1380 {
		t.Fatalf("expected cellular adaptive mtu 1380, got %d", h.MTU)
	}
	if h.RouteOptions.SelectorInterrupt == nil || *h.RouteOptions.SelectorInterrupt {
		t.Fatal("expected selector interrupt override false for stable_mobile")
	}
	if h.RouteOptions.SelectorTolerance < 2 {
		t.Fatalf("expected selector tolerance >=2, got %d", h.RouteOptions.SelectorTolerance)
	}
	if !h.RouteOptions.SelectorUseSticky {
		t.Fatal("expected selector sticky=true for stable_mobile")
	}
	if h.RemoteDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyPreferIPv4) {
		t.Fatalf("expected remote prefer_ipv4, got %s", h.RemoteDnsDomainStrategy)
	}
	if h.DirectDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyPreferIPv4) {
		t.Fatalf("expected direct prefer_ipv4, got %s", h.DirectDnsDomainStrategy)
	}
	if h.DirectDnsAddress != "https://1.1.1.1/dns-query" {
		t.Fatalf("expected stable_mobile direct dns doh, got %s", h.DirectDnsAddress)
	}
}

func TestApplyNetworkProfileIPv4OnlyDiagnostic(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileIPv4OnlyDiagnostic

	applyNetworkProfile(h)
	if h.RemoteDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyIPv4Only) {
		t.Fatalf("expected remote ipv4_only, got %s", h.RemoteDnsDomainStrategy)
	}
	if h.DirectDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyIPv4Only) {
		t.Fatalf("expected direct ipv4_only, got %s", h.DirectDnsDomainStrategy)
	}
	if h.RouteOptions.IPv6Mode != option.DomainStrategy(C.DomainStrategyIPv4Only) {
		t.Fatalf("expected ipv6 mode ipv4_only, got %s", h.RouteOptions.IPv6Mode)
	}
}

func TestApplyNetworkProfileDirectIPv4OnlyDiagnostic(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileDirectIPv4OnlyDiag
	h.RemoteDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyPreferIPv4)

	applyNetworkProfile(h)
	if h.DirectDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyIPv4Only) {
		t.Fatalf("expected direct ipv4_only, got %s", h.DirectDnsDomainStrategy)
	}
	if h.RemoteDnsDomainStrategy != option.DomainStrategy(C.DomainStrategyPreferIPv4) {
		t.Fatalf("expected remote strategy unchanged, got %s", h.RemoteDnsDomainStrategy)
	}
	if h.RouteOptions.SelectorInterrupt == nil || *h.RouteOptions.SelectorInterrupt {
		t.Fatal("expected selector interrupt false for direct ipv4 diagnostic")
	}
	if h.RouteOptions.SelectorTolerance < 2 {
		t.Fatalf("expected selector tolerance >=2, got %d", h.RouteOptions.SelectorTolerance)
	}
	if h.DirectDnsAddress != "https://1.1.1.1/dns-query" {
		t.Fatalf("expected direct ipv4 profile direct dns doh, got %s", h.DirectDnsAddress)
	}
}

func TestNoFragmentProfileDisablesDNSTrickDirect(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileNoFragmentDiag
	h.TLSTricks.EnableFragment = true

	applyNetworkProfile(h)
	if h.TLSTricks.EnableFragment {
		t.Fatal("expected tls fragment disabled for no_fragment_diagnostic")
	}
	if shouldEnableDNSTrickDirect(h) {
		t.Fatal("expected dns trick direct disabled for no_fragment_diagnostic")
	}
}
