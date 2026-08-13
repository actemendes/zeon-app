package config

import (
	"strings"
	"testing"

	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func TestAndroidProtectCompatibilityRejectsProtectBypass(t *testing.T) {
	bind := badoption.Addr{}
	tests := []struct {
		name    string
		options option.DialerOptions
	}{
		{name: "bind interface", options: option.DialerOptions{BindInterface: "wlan0"}},
		{name: "inet4 bind", options: option.DialerOptions{Inet4BindAddress: &bind}},
		{name: "routing mark", options: option.DialerOptions{RoutingMark: 7}},
		{name: "netns", options: option.DialerOptions{NetNs: "test"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			options := &option.Options{
				Outbounds: []option.Outbound{{
					Type:    "direct",
					Tag:     "opaque",
					Options: &option.DirectOutboundOptions{DialerOptions: test.options},
				}},
			}
			err := validateAndroidProtectCompatibility(options, true)
			if err == nil || !strings.Contains(err.Error(), "android VPN protect conflict") {
				t.Fatalf("error=%v", err)
			}
		})
	}
}

func TestAndroidProtectCompatibilityAllowsOrdinaryPlatformProtect(t *testing.T) {
	options := &option.Options{
		Outbounds: []option.Outbound{{
			Type:    "direct",
			Tag:     "opaque",
			Options: &option.DirectOutboundOptions{},
		}},
	}
	if err := validateAndroidProtectCompatibility(options, true); err != nil {
		t.Fatal(err)
	}
}
