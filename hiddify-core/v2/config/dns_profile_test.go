package config

import (
	"testing"

	"github.com/sagernet/sing-box/option"
)

func TestSetDnsNoFragmentProfileDisablesDNSTrickDirectServer(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileNoFragmentDiag
	applyNetworkProfile(h)

	options := newRoutingTestOptions()
	static := map[string][]string{}
	if err := setDns(options, h, &static); err != nil {
		t.Fatalf("setDns failed: %v", err)
	}

	for _, server := range options.DNS.Servers {
		if server.Tag == DNSTricksDirectTag {
			t.Fatal("did not expect dns-trick-direct server in no_fragment_diagnostic profile")
		}
	}
}

func TestSetDnsDefaultProfileKeepsDNSTrickDirectServer(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileDefault
	applyNetworkProfile(h)

	options := newRoutingTestOptions()
	static := map[string][]string{}
	if err := setDns(options, h, &static); err != nil {
		t.Fatalf("setDns failed: %v", err)
	}

	found := false
	for _, server := range options.DNS.Servers {
		if server.Tag == DNSTricksDirectTag {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected dns-trick-direct server in default profile")
	}
}

func TestSetDnsNoFragmentProfileDirectDNSHasNoFragmentDetour(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileNoFragmentDiag
	h.DirectDnsAddress = "https://1.1.1.1/dns-query"
	applyNetworkProfile(h)

	options := newRoutingTestOptions()
	static := map[string][]string{}
	if err := setDns(options, h, &static); err != nil {
		t.Fatalf("setDns failed: %v", err)
	}

	for _, server := range options.DNS.Servers {
		if server.Tag == DNSDirectTag {
			if ro, ok := server.Options.(*option.RemoteHTTPSDNSServerOptions); ok {
				if ro.Detour != "" {
					t.Fatalf("expected empty detour for direct dns in no_fragment profile, got %q", ro.Detour)
				}
			}
		}
	}
}
