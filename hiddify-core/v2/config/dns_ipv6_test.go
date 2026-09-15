package config

import (
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestIPv6OnlyRemoteDNSAddressUsesProviderIPv6Peer(t *testing.T) {
	tests := map[string]string{
		"tcp://8.8.8.8":                        "tcp://[2001:4860:4860::8888]",
		"https://1.1.1.1/dns-query":            "https://[2606:4700:4700::1111]/dns-query",
		"1.0.0.1":                              "udp://[2606:4700:4700::1001]",
		"tcp://[2606:4700:4700::1111]":         "tcp://[2606:4700:4700::1111]",
		"https://dns.cloudflare.com/dns-query": "https://dns.cloudflare.com/dns-query",
	}
	for input, want := range tests {
		t.Run(input, func(t *testing.T) {
			got, err := ipv6OnlyRemoteDNSAddress(input)
			if err != nil {
				t.Fatal(err)
			}
			if got != want {
				t.Fatalf("address=%q want %q", got, want)
			}
		})
	}
}

func TestIPv6OnlyRemoteDNSAddressFailsClosedForIPv4OnlyResolver(t *testing.T) {
	for _, input := range []string{"local", "tcp://4.4.2.2"} {
		if _, err := ipv6OnlyRemoteDNSAddress(input); err == nil {
			t.Fatalf("address %q unexpectedly accepted", input)
		}
	}
}

func TestSetDNSUsesIPv6TransportForStrictMode(t *testing.T) {
	opts := DefaultHiddifyOptions()
	opts.IPv6Mode = option.DomainStrategy(C.DomainStrategyIPv6Only)
	opts.RemoteDnsAddress = "tcp://8.8.8.8"
	var built option.Options
	staticIPs := map[string][]string{}
	if err := setDns(&built, opts, &staticIPs); err != nil {
		t.Fatal(err)
	}
	servers := map[string]string{}
	for _, server := range built.DNS.Servers {
		switch dnsOptions := server.Options.(type) {
		case *option.RemoteDNSServerOptions:
			servers[server.Tag] = dnsOptions.Server
		case *option.RemoteHTTPSDNSServerOptions:
			servers[server.Tag] = dnsOptions.Server
		}
	}
	if got := servers[DNSRemoteTag]; got != "2001:4860:4860::8888" {
		t.Fatalf("strict primary DNS=%q want IPv6 Google endpoint", got)
	}
	if got := servers[DNSRemoteTagFallback]; got != "2001:4860:4860::8888" {
		t.Fatalf("strict fallback DNS=%q want IPv6 Google endpoint", got)
	}
	if got := servers[DNSRemoteNoWarpTag]; got != "2001:4860:4860::8888" {
		t.Fatalf("strict no-WARP DNS=%q want IPv6 Google endpoint", got)
	}
}

func TestSetDNSResolvesNamedStrictEndpointAsIPv6Only(t *testing.T) {
	opts := DefaultHiddifyOptions()
	opts.IPv6Mode = option.DomainStrategy(C.DomainStrategyIPv6Only)
	opts.RemoteDnsAddress = "https://dns.cloudflare.com/dns-query"
	var built option.Options
	staticIPs := map[string][]string{}
	if err := setDns(&built, opts, &staticIPs); err != nil {
		t.Fatal(err)
	}
	for _, server := range built.DNS.Servers {
		if server.Tag != DNSRemoteTag {
			continue
		}
		dnsOptions, ok := server.Options.(*option.RemoteHTTPSDNSServerOptions)
		if !ok || dnsOptions.DomainResolver == nil {
			t.Fatal("strict named DNS endpoint has no bootstrap resolver")
		}
		if got := dnsOptions.DomainResolver.Strategy; got != option.DomainStrategy(C.DomainStrategyIPv6Only) {
			t.Fatalf("strict named DNS bootstrap strategy=%v want IPv6Only", got)
		}
		return
	}
	t.Fatal("strict remote DNS server missing")
}
