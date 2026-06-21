package option

import "github.com/sagernet/sing/common/json/badoption"

type MonitoringOptions struct {
	Interval         badoption.Duration `json:"interval,omitempty"`
	URLs             []string           `json:"urls,omitempty"` //H
	Workers          int                `json:"workers,omitempty"`
	DebounceWindow   badoption.Duration `json:"debounce_window,omitempty"`
	URLTestTimeout   badoption.Duration `json:"url_test_timeout,omitempty"`
	IdleTimeout      badoption.Duration `json:"idle_timeout,omitempty"`
	UDPProbeEnabled  bool               `json:"udp_probe_enabled,omitempty"`
	UDPProbeEndpoint string             `json:"udp_probe_endpoint,omitempty"`
	UDPProbeSecret   string             `json:"udp_probe_secret,omitempty"`
	UDPProbeCount    int                `json:"udp_probe_count,omitempty"`
	UDPProbeSize     int                `json:"udp_probe_size,omitempty"`
	UDPProbeInterval badoption.Duration `json:"udp_probe_interval,omitempty"`
	UDPProbeTimeout  badoption.Duration `json:"udp_probe_timeout,omitempty"`
	UDPProbeCooldown badoption.Duration `json:"udp_probe_cooldown,omitempty"`
	UDPProbeTopN     int                `json:"udp_probe_top_n,omitempty"`
}
