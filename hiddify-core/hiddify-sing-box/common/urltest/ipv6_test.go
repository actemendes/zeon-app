package urltest

import (
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"

	"github.com/miekg/dns"
	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type ipv6TestDNSRouter struct {
	address       netip.Addr
	bootstrapSeen bool
}

func (*ipv6TestDNSRouter) Start(adapter.StartStage) error { return nil }
func (*ipv6TestDNSRouter) Close() error                   { return nil }
func (*ipv6TestDNSRouter) Exchange(context.Context, *dns.Msg, adapter.DNSQueryOptions) (*dns.Msg, error) {
	return nil, fmt.Errorf("not used")
}
func (r *ipv6TestDNSRouter) Lookup(ctx context.Context, _ string, _ adapter.DNSQueryOptions) ([]netip.Addr, error) {
	r.bootstrapSeen = IsIPv6CapabilityBootstrap(ctx)
	return []netip.Addr{r.address}, nil
}
func (*ipv6TestDNSRouter) ClearCache()                                    {}
func (*ipv6TestDNSRouter) LookupReverseMapping(netip.Addr) (string, bool) { return "", false }
func (*ipv6TestDNSRouter) ResetNetwork()                                  {}

type ipv6TestCertificateStore struct{ pool *x509.CertPool }

func (*ipv6TestCertificateStore) Name() string                   { return "test-certificates" }
func (*ipv6TestCertificateStore) Start(adapter.StartStage) error { return nil }
func (*ipv6TestCertificateStore) Close() error                   { return nil }
func (s *ipv6TestCertificateStore) Pool() *x509.CertPool         { return s.pool }

type ipv6TestDialer struct {
	serverAddress string
	dialedIPv6    bool
	bootstrapSeen bool
}

func (d *ipv6TestDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	d.bootstrapSeen = IsIPv6CapabilityBootstrap(ctx)
	if destination.Addr.Is6() && !destination.Addr.Is4In6() {
		d.dialedIPv6 = true
	} else {
		return nil, fmt.Errorf("probe did not use a fixed IPv6 destination: %s", destination)
	}
	return (&net.Dialer{}).DialContext(ctx, network, d.serverAddress)
}

func (*ipv6TestDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, fmt.Errorf("not used")
}

func TestIPv6URLTestUsesFixedIPv6AndValidatesTLSHostname(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	certificate, err := x509.ParseCertificate(server.TLS.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(certificate.DNSNames) == 0 {
		t.Fatal("test certificate has no DNS name")
	}
	pool := x509.NewCertPool()
	pool.AddCert(certificate)
	dnsRouter := &ipv6TestDNSRouter{address: netip.MustParseAddr("2001:db8::42")}
	ctx := service.ContextWith[adapter.DNSRouter](context.Background(), dnsRouter)
	ctx = service.ContextWith[adapter.CertificateStore](ctx, &ipv6TestCertificateStore{pool: pool})
	dialer := &ipv6TestDialer{serverAddress: server.Listener.Addr().String()}
	_, port, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	probeURL := "https://" + net.JoinHostPort(certificate.DNSNames[0], port) + "/"
	if _, err = IPv6URLTest(ctx, probeURL, dialer); err != nil {
		t.Fatalf("strict IPv6 HTTPS probe failed: %v", err)
	}
	if !dialer.dialedIPv6 {
		t.Fatal("probe did not dial the resolved IPv6 address")
	}
	if !dnsRouter.bootstrapSeen {
		t.Fatal("AAAA lookup was not marked as IPv6 capability bootstrap control-plane traffic")
	}
	if dialer.bootstrapSeen {
		t.Fatal("bootstrap marker leaked from DNS lookup into the HTTPS capability proof")
	}

	untrustedCtx := service.ContextWith[adapter.DNSRouter](context.Background(), &ipv6TestDNSRouter{address: netip.MustParseAddr("2001:db8::42")})
	if _, err = IPv6URLTest(untrustedCtx, probeURL, &ipv6TestDialer{serverAddress: server.Listener.Addr().String()}); err == nil {
		t.Fatal("probe bypassed normal TLS certificate validation")
	}
}
