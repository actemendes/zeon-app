package option

import "github.com/sagernet/sing/common/json/badoption"

type SelectorOutboundOptions struct {
	Outbounds                 []string           `json:"outbounds"`
	Default                   string             `json:"default,omitempty"`
	ZeonPreferDefault         bool               `json:"zeon_prefer_default,omitempty"`
	InterruptExistConnections bool               `json:"interrupt_exist_connections,omitempty"`
	IPv6Mode                  DomainStrategy     `json:"ipv6_mode,omitempty"`
	IPv6CapabilityTTL         badoption.Duration `json:"ipv6_capability_ttl,omitempty"`
}

type URLTestOutboundOptions struct {
	Outbounds                 []string           `json:"outbounds"`
	URL                       string             `json:"url,omitempty"`
	URLs                      []string           `json:"urls,omitempty"` //H
	Interval                  badoption.Duration `json:"interval,omitempty"`
	Tolerance                 uint16             `json:"tolerance,omitempty"`
	IdleTimeout               badoption.Duration `json:"idle_timeout,omitempty"`
	InterruptExistConnections bool               `json:"interrupt_exist_connections,omitempty"`
}
