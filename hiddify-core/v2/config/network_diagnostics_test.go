package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/option"
)

func TestWriteNetworkDiagnosticsSnapshotSanitized(t *testing.T) {
	tmp := t.TempDir()

	h := DefaultHiddifyOptions()
	h.RuntimeDataDir = filepath.Join(tmp, "data")
	h.RouteOptions.NetworkProfile = NetworkProfileStableMobile
	h.RouteOptions.NetworkTransportType = NetworkTransportCellular
	h.RouteOptions.NetworkMTUMode = NetworkMTUModeAdaptive
	resolved := applyNetworkProfile(h)

	if err := writeNetworkDiagnosticsSnapshot(h, &option.Options{}, resolved); err != nil {
		t.Fatalf("write diagnostics failed: %v", err)
	}

	path := filepath.Join(h.RuntimeDataDir, "network-diagnostics.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read diagnostics failed: %v", err)
	}

	var snap map[string]any
	if err := json.Unmarshal(raw, &snap); err != nil {
		t.Fatalf("invalid diagnostics json: %v", err)
	}
	if _, ok := snap["selected_profile"]; !ok {
		t.Fatal("expected selected_profile in diagnostics snapshot")
	}
	if v, ok := snap["direct_ip_strategy"]; !ok || v == "" {
		t.Fatalf("expected direct_ip_strategy in diagnostics snapshot, got %#v", v)
	}
	if v, ok := snap["direct_ipv4_safe_enabled"]; !ok {
		t.Fatal("expected direct_ipv4_safe_enabled in diagnostics snapshot")
	} else if vb, ok := v.(bool); !ok || !vb {
		t.Fatalf("expected direct_ipv4_safe_enabled=true for stable_mobile, got %#v", v)
	}
	if v, ok := snap["critical_domains_fallback_enabled"]; !ok {
		t.Fatal("expected critical_domains_fallback_enabled in diagnostics snapshot")
	} else if vb, ok := v.(bool); !ok || vb {
		t.Fatalf("expected critical_domains_fallback_enabled=false by default, got %#v", v)
	}
	if strings.Contains(strings.ToLower(string(raw)), "ssid") {
		t.Fatal("diagnostics must not contain ssid")
	}
	if strings.Contains(strings.ToLower(string(raw)), "bssid") {
		t.Fatal("diagnostics must not contain bssid")
	}
}
