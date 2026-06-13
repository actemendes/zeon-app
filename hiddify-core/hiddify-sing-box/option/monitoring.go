package option

import "github.com/sagernet/sing/common/json/badoption"

type MonitoringOptions struct {
	Interval                 badoption.Duration `json:"interval,omitempty"`
	URLs                     []string           `json:"urls,omitempty"` //H
	Workers                  int                `json:"workers,omitempty"`
	DebounceWindow           badoption.Duration `json:"debounce_window,omitempty"`
	URLTestTimeout           badoption.Duration `json:"url_test_timeout,omitempty"`
	IdleTimeout              badoption.Duration `json:"idle_timeout,omitempty"`
	ExternalSpeedTestURL     string             `json:"external_speed_test_url,omitempty"`
	ExternalSpeedTestBytes   int                `json:"external_speed_test_bytes,omitempty"`
	ExternalSpeedTestEnabled *bool              `json:"external_speed_test_enabled,omitempty"`
}
