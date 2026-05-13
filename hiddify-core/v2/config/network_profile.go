package config

import (
	"fmt"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	dns "github.com/sagernet/sing-dns"
)

const (
	NetworkProfileDefault            = "default"
	NetworkProfileStableMobile       = "stable_mobile"
	NetworkProfileWiFiHighMTU        = "wifi_high_mtu"
	NetworkProfileLowMTUDiagnostic   = "low_mtu_diagnostic"
	NetworkProfileDirectIPv4OnlyDiag = "direct_ipv4_only_diagnostic"
	NetworkProfileIPv4OnlyDiagnostic = "ipv4_only_diagnostic"
	NetworkProfileNoFragmentDiag     = "no_fragment_diagnostic"
	NetworkProfileLANFriendly        = "lan_friendly"
)

const (
	NetworkMTUModeFixed          = "fixed"
	NetworkMTUModeAdaptive       = "adaptive"
	NetworkMTUModeDiagnosticLow  = "diagnostic_low"
	NetworkMTUModeDiagnosticHigh = "diagnostic_high"
)

const (
	NetworkTransportUnknown  = "unknown"
	NetworkTransportWiFi     = "wifi"
	NetworkTransportCellular = "cellular"
	NetworkTransportEthernet = "ethernet"
)

const (
	FragmentModeDefault = "default"
	FragmentModeOff     = "off"
)

const (
	ProfileDNSDefault  = "default"
	ProfileDNSPreferV4 = "prefer_ipv4"
	ProfileDNSIPv4Only = "ipv4_only"
)

type ResolvedMTU struct {
	Value         uint32
	Mode          string
	Profile       string
	Transport     string
	Reason        string
	InterfaceMTU  uint32
	ConfiguredMTU uint32
	FallbackUsed  bool
}

func normalizeProfile(s string) string {
	switch strings.TrimSpace(strings.ToLower(s)) {
	case NetworkProfileStableMobile, NetworkProfileWiFiHighMTU, NetworkProfileLowMTUDiagnostic, NetworkProfileDirectIPv4OnlyDiag, NetworkProfileIPv4OnlyDiagnostic, NetworkProfileNoFragmentDiag, NetworkProfileLANFriendly:
		return strings.TrimSpace(strings.ToLower(s))
	default:
		return NetworkProfileDefault
	}
}

func normalizeMTUMode(s string) string {
	switch strings.TrimSpace(strings.ToLower(s)) {
	case NetworkMTUModeAdaptive, NetworkMTUModeDiagnosticLow, NetworkMTUModeDiagnosticHigh:
		return strings.TrimSpace(strings.ToLower(s))
	default:
		return NetworkMTUModeFixed
	}
}

func normalizeTransport(s string) string {
	switch strings.TrimSpace(strings.ToLower(s)) {
	case NetworkTransportWiFi, NetworkTransportCellular, NetworkTransportEthernet:
		return strings.TrimSpace(strings.ToLower(s))
	default:
		return NetworkTransportUnknown
	}
}

func normalizeFragmentMode(s string) string {
	switch strings.TrimSpace(strings.ToLower(s)) {
	case FragmentModeOff:
		return FragmentModeOff
	default:
		return FragmentModeDefault
	}
}

func resolveMTU(hopt *HiddifyOptions) ResolvedMTU {
	profile := normalizeProfile(hopt.RouteOptions.NetworkProfile)
	mode := normalizeMTUMode(hopt.RouteOptions.NetworkMTUMode)
	transport := normalizeTransport(hopt.RouteOptions.NetworkTransportType)
	configured := hopt.MTU
	interfaceMTU := hopt.RouteOptions.NetworkInterfaceMTU

	selected := configured
	reason := "fixed/manual"
	fallback := false

	switch mode {
	case NetworkMTUModeDiagnosticLow:
		selected = 1280
		reason = "diagnostic_low"
	case NetworkMTUModeDiagnosticHigh:
		selected = 1500
		reason = "diagnostic_high"
	case NetworkMTUModeAdaptive:
		switch transport {
		case NetworkTransportWiFi, NetworkTransportEthernet:
			if interfaceMTU >= 1280 && interfaceMTU <= 9000 {
				if interfaceMTU > 1500 {
					selected = 1500
					reason = "adaptive interface mtu capped at 1500"
				} else {
					selected = interfaceMTU
					reason = "adaptive interface mtu"
				}
			} else {
				selected = 1500
				reason = "adaptive transport default 1500"
			}
		case NetworkTransportCellular:
			selected = 1380
			reason = "adaptive cellular default 1380"
		default:
			selected = 1400
			reason = "adaptive unknown default 1400"
		}
	default:
		if selected == 0 {
			selected = 1500
			reason = "fixed fallback to 1500"
			fallback = true
		}
	}

	if mode != NetworkMTUModeFixed && selected > 1500 {
		selected = 1500
		reason = reason + " (adaptive clamp max 1500)"
	}
	if selected < 1280 {
		selected = 1280
		reason = reason + " (clamp min 1280)"
		fallback = true
	}
	// IPv6 minimum safety.
	if hopt.RouteOptions.IPv6Mode != option.DomainStrategy(C.DomainStrategyIPv4Only) && selected < 1280 {
		selected = 1280
		reason = reason + " (ipv6 minimum 1280)"
		fallback = true
	}

	return ResolvedMTU{
		Value:         selected,
		Mode:          mode,
		Profile:       profile,
		Transport:     transport,
		Reason:        reason,
		InterfaceMTU:  interfaceMTU,
		ConfiguredMTU: configured,
		FallbackUsed:  fallback,
	}
}

func applyNetworkProfile(hopt *HiddifyOptions) ResolvedMTU {
	profile := normalizeProfile(hopt.RouteOptions.NetworkProfile)
	hopt.RouteOptions.NetworkProfile = profile
	hopt.RouteOptions.NetworkMTUMode = normalizeMTUMode(hopt.RouteOptions.NetworkMTUMode)
	hopt.RouteOptions.NetworkTransportType = normalizeTransport(hopt.RouteOptions.NetworkTransportType)
	hopt.RouteOptions.FragmentMode = normalizeFragmentMode(hopt.RouteOptions.FragmentMode)

	mtu := resolveMTU(hopt)
	hopt.MTU = mtu.Value

	explicitRemoteStrategy := hopt.RemoteDnsDomainStrategy != option.DomainStrategy(dns.DomainStrategyAsIS)
	explicitDirectStrategy := hopt.DirectDnsDomainStrategy != option.DomainStrategy(dns.DomainStrategyAsIS)

	switch profile {
	case NetworkProfileStableMobile:
		if hopt.RouteOptions.NetworkMTUMode == NetworkMTUModeFixed {
			hopt.RouteOptions.NetworkMTUMode = NetworkMTUModeAdaptive
			mtu = resolveMTU(hopt)
			hopt.MTU = mtu.Value
		}
		if !explicitRemoteStrategy {
			hopt.RemoteDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyPreferIPv4)
		}
		if !explicitDirectStrategy {
			hopt.DirectDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyPreferIPv4)
		}
		if hopt.RouteOptions.SelectorInterrupt == nil {
			v := false
			hopt.RouteOptions.SelectorInterrupt = &v
		}
		if hopt.RouteOptions.SelectorTolerance < 2 {
			hopt.RouteOptions.SelectorTolerance = 2
		}
		hopt.RouteOptions.SelectorUseSticky = true
		if hopt.RouteOptions.FragmentMode == FragmentModeOff {
			hopt.TLSTricks.EnableFragment = false
		}
	case NetworkProfileIPv4OnlyDiagnostic:
		hopt.RemoteDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyIPv4Only)
		hopt.DirectDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyIPv4Only)
		hopt.RouteOptions.IPv6Mode = option.DomainStrategy(C.DomainStrategyIPv4Only)
		if hopt.RouteOptions.NetworkMTUMode == NetworkMTUModeFixed {
			hopt.RouteOptions.NetworkMTUMode = NetworkMTUModeDiagnosticLow
			mtu = resolveMTU(hopt)
			hopt.MTU = mtu.Value
		}
	case NetworkProfileDirectIPv4OnlyDiag:
		// Keep default VPN-first routing and remote DNS behavior intact.
		// Only force direct-domain DNS answers to IPv4 to avoid broken direct IPv6 paths.
		hopt.DirectDnsDomainStrategy = option.DomainStrategy(C.DomainStrategyIPv4Only)
		if hopt.RouteOptions.NetworkMTUMode == NetworkMTUModeFixed {
			hopt.RouteOptions.NetworkMTUMode = NetworkMTUModeDiagnosticLow
			mtu = resolveMTU(hopt)
			hopt.MTU = mtu.Value
		}
		if hopt.RouteOptions.SelectorInterrupt == nil {
			v := false
			hopt.RouteOptions.SelectorInterrupt = &v
		}
		if hopt.RouteOptions.SelectorTolerance < 2 {
			hopt.RouteOptions.SelectorTolerance = 2
		}
	case NetworkProfileLowMTUDiagnostic:
		hopt.RouteOptions.NetworkMTUMode = NetworkMTUModeDiagnosticLow
		mtu = resolveMTU(hopt)
		hopt.MTU = mtu.Value
		if hopt.RouteOptions.SelectorInterrupt == nil {
			v := false
			hopt.RouteOptions.SelectorInterrupt = &v
		}
		if hopt.RouteOptions.SelectorTolerance < 2 {
			hopt.RouteOptions.SelectorTolerance = 2
		}
	case NetworkProfileWiFiHighMTU:
		if hopt.RouteOptions.NetworkMTUMode == NetworkMTUModeFixed {
			hopt.RouteOptions.NetworkMTUMode = NetworkMTUModeAdaptive
			mtu = resolveMTU(hopt)
			hopt.MTU = mtu.Value
		}
	case NetworkProfileNoFragmentDiag:
		hopt.RouteOptions.FragmentMode = FragmentModeOff
		hopt.TLSTricks.EnableFragment = false
	case NetworkProfileLANFriendly:
		hopt.BypassLAN = true
	}
	return mtu
}

func shouldEnableDNSTrickDirect(hopt *HiddifyOptions) bool {
	return normalizeFragmentMode(hopt.RouteOptions.FragmentMode) != FragmentModeOff
}

func profileDNSStrategySummary(strategy option.DomainStrategy) string {
	switch strategy {
	case option.DomainStrategy(C.DomainStrategyPreferIPv4):
		return ProfileDNSPreferV4
	case option.DomainStrategy(C.DomainStrategyIPv4Only):
		return ProfileDNSIPv4Only
	default:
		return ProfileDNSDefault
	}
}

func profileSummary(hopt *HiddifyOptions, resolved ResolvedMTU) string {
	return fmt.Sprintf("profile=%s mtu_mode=%s transport=%s mtu=%d reason=%s",
		normalizeProfile(hopt.RouteOptions.NetworkProfile),
		resolved.Mode,
		resolved.Transport,
		resolved.Value,
		resolved.Reason,
	)
}
