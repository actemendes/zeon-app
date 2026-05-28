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

func TestSetDnsDefaultProfileWithoutTLSFragmentDisablesDNSTrickDirectServer(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileDefault
	h.TLSTricks.EnableFragment = false
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
	if found {
		t.Fatal("did not expect dns-trick-direct server when tls fragment is disabled")
	}
}

func TestSetDnsDefaultProfileWithTLSFragmentKeepsDNSTrickDirectServer(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileDefault
	h.TLSTricks.EnableFragment = true
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
		t.Fatal("expected dns-trick-direct server when tls fragment is enabled")
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

func TestSetDnsDefaultProfileWithoutTLSFragmentDirectDNSHasNoFragmentDetour(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RouteOptions.NetworkProfile = NetworkProfileDefault
	h.DirectDnsAddress = "https://1.1.1.1/dns-query"
	h.TLSTricks.EnableFragment = false
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
					t.Fatalf("expected empty detour for direct dns when tls fragment is disabled, got %q", ro.Detour)
				}
			}
		}
	}
}
