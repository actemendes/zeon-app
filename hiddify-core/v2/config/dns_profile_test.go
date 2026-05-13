package config

import "testing"

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
