package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

type networkDiagnosticsSnapshot struct {
	GeneratedAt                    string                 `json:"generated_at"`
	SelectedProfile                string                 `json:"selected_profile"`
	NetworkTransportType           string                 `json:"network_transport_type"`
	MTU                            networkMTUDiagnostics  `json:"mtu"`
	DNSStrategy                    dnsStrategyDiagnostics `json:"dns_strategy"`
	DirectIPStrategy               string                 `json:"direct_ip_strategy,omitempty"`
	DirectIPv4SafeEnabled          bool                   `json:"direct_ipv4_safe_enabled"`
	IPv6                           ipv6Diagnostics        `json:"ipv6"`
	TUN                            tunDiagnostics         `json:"tun"`
	Fragment                       fragmentDiagnostics    `json:"fragment"`
	Selector                       selectorDiagnostics    `json:"selector"`
	RuleSetMetadataPath            string                 `json:"rule_set_metadata_path,omitempty"`
	RuleSetMetadataStatus          string                 `json:"rule_set_metadata_status,omitempty"`
	CriticalDomainsFallbackEnabled bool                   `json:"critical_domains_fallback_enabled"`
}

type networkMTUDiagnostics struct {
	Mode         string `json:"mode"`
	Selected     uint32 `json:"selected"`
	Configured   uint32 `json:"configured"`
	InterfaceMTU uint32 `json:"interface_mtu,omitempty"`
	Reason       string `json:"reason"`
}

type dnsStrategyDiagnostics struct {
	Remote string `json:"remote"`
	Direct string `json:"direct"`
}

type ipv6Diagnostics struct {
	Mode string `json:"mode"`
}

type tunDiagnostics struct {
	StrictRoute bool   `json:"strict_route"`
	Stack       string `json:"stack"`
	AutoRoute   bool   `json:"auto_route"`
}

type fragmentDiagnostics struct {
	Mode    string `json:"mode"`
	Enabled bool   `json:"enabled"`
}

type selectorDiagnostics struct {
	InterruptExistConnections bool   `json:"interrupt_exist_connections"`
	Tolerance                 uint32 `json:"tolerance"`
	Sticky                    bool   `json:"sticky"`
}

func runtimeDataDir(hopt *HiddifyOptions) string {
	if hopt == nil || hopt.RuntimeDataDir == "" {
		return "data"
	}
	return hopt.RuntimeDataDir
}

func writeNetworkDiagnosticsSnapshot(hopt *HiddifyOptions, options *option.Options, resolved ResolvedMTU) error {
	if hopt == nil {
		return nil
	}
	dataDir := runtimeDataDir(hopt)
	selInterrupt := !hopt.RouteOptions.StableTransportMode
	if hopt.RouteOptions.SelectorInterrupt != nil {
		selInterrupt = *hopt.RouteOptions.SelectorInterrupt
	}
	snapshot := networkDiagnosticsSnapshot{
		GeneratedAt:          time.Now().UTC().Format(time.RFC3339),
		SelectedProfile:      normalizeProfile(hopt.RouteOptions.NetworkProfile),
		NetworkTransportType: normalizeTransport(hopt.RouteOptions.NetworkTransportType),
		MTU: networkMTUDiagnostics{
			Mode:         resolved.Mode,
			Selected:     resolved.Value,
			Configured:   resolved.ConfiguredMTU,
			InterfaceMTU: resolved.InterfaceMTU,
			Reason:       resolved.Reason,
		},
		DNSStrategy: dnsStrategyDiagnostics{
			Remote: profileDNSStrategySummary(hopt.RemoteDnsDomainStrategy),
			Direct: profileDNSStrategySummary(hopt.DirectDnsDomainStrategy),
		},
		DirectIPStrategy: profileDNSStrategySummary(hopt.DirectDnsDomainStrategy),
		DirectIPv4SafeEnabled: hopt.DirectDnsDomainStrategy == option.DomainStrategy(C.DomainStrategyPreferIPv4) ||
			hopt.DirectDnsDomainStrategy == option.DomainStrategy(C.DomainStrategyIPv4Only),
		IPv6: ipv6Diagnostics{
			Mode: hopt.RouteOptions.IPv6Mode.String(),
		},
		TUN: tunDiagnostics{
			StrictRoute: hopt.StrictRoute,
			Stack:       hopt.TUNStack,
			AutoRoute:   hopt.EnableTun,
		},
		Fragment: fragmentDiagnostics{
			Mode:    normalizeFragmentMode(hopt.RouteOptions.FragmentMode),
			Enabled: hopt.TLSTricks.EnableFragment,
		},
		Selector: selectorDiagnostics{
			InterruptExistConnections: selInterrupt,
			Tolerance:                 hopt.RouteOptions.SelectorTolerance,
			Sticky:                    hopt.RouteOptions.SelectorUseSticky,
		},
		RuleSetMetadataPath:            filepath.Join(dataDir, "rule-set-metadata.json"),
		CriticalDomainsFallbackEnabled: criticalDomainsFallbackEnabled(hopt),
	}
	if _, err := os.Stat(snapshot.RuleSetMetadataPath); err == nil {
		snapshot.RuleSetMetadataStatus = "present"
	} else {
		snapshot.RuleSetMetadataStatus = "missing"
	}
	if options == nil || options.Route == nil {
		snapshot.RuleSetMetadataStatus = "unknown"
	}
	b, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return fmt.Errorf("mkdir diagnostics dir: %w", err)
	}
	if err := writeAtomic(filepath.Join(dataDir, "network-diagnostics.json"), b, 0o644); err != nil {
		return fmt.Errorf("write diagnostics snapshot: %w", err)
	}
	return nil
}
