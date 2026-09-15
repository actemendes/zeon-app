package urltest

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/ntp"
	"github.com/sagernet/sing/service"
)

type ipv6CapabilityBootstrapKey struct{}

const ipv6CapabilityBootstrapDNSTag = "dns-ipv6-capability-bootstrap"

// ContextWithIPv6CapabilityBootstrap marks only the DNS control-plane work
// needed to resolve an IPv6 probe target. IPv6-only data-plane gates may let
// this lookup reach the configured resolver before any leaf has proof; the
// actual HTTPS probe still dials the concrete leaf without this marker.
func ContextWithIPv6CapabilityBootstrap(ctx context.Context) context.Context {
	return context.WithValue(ctx, ipv6CapabilityBootstrapKey{}, true)
}

func IsIPv6CapabilityBootstrap(ctx context.Context) bool {
	bootstrap, _ := ctx.Value(ipv6CapabilityBootstrapKey{}).(bool)
	return bootstrap
}

// IPv6URLTest proves HTTPS egress through one concrete outbound. DNS is
// resolved with an AAAA-only query, the outbound dials the resulting IPv6
// address, and TLS still validates the original hostname through normal SNI
// and root certificate handling.
func IPv6URLTest(ctx context.Context, link string, detour N.Dialer) (uint16, error) {
	if detour == nil {
		return 0, fmt.Errorf("ipv6 urltest dialer is nil")
	}
	linkURL, err := url.Parse(link)
	if err != nil {
		return 0, err
	}
	if linkURL.Scheme != "https" {
		return 0, fmt.Errorf("ipv6 urltest requires https")
	}
	hostname := linkURL.Hostname()
	if hostname == "" {
		return 0, fmt.Errorf("ipv6 urltest hostname is empty")
	}
	port := linkURL.Port()
	if port == "" {
		port = "443"
	}
	portNumber, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return 0, fmt.Errorf("invalid ipv6 urltest port: %w", err)
	}
	dnsRouter := service.FromContext[adapter.DNSRouter](ctx)
	if dnsRouter == nil {
		return 0, fmt.Errorf("ipv6 urltest DNS router is unavailable")
	}
	lookupCtx := ContextWithIPv6CapabilityBootstrap(ctx)
	queryOptions := adapter.DNSQueryOptions{
		Strategy:     C.DomainStrategyIPv6Only,
		DisableCache: true,
	}
	if transportManager := service.FromContext[adapter.DNSTransportManager](ctx); transportManager != nil {
		if bootstrapTransport, loaded := transportManager.Transport(ipv6CapabilityBootstrapDNSTag); loaded {
			queryOptions.Transport = bootstrapTransport
		}
	}
	addresses, err := dnsRouter.Lookup(lookupCtx, hostname, queryOptions)
	if err != nil {
		return 0, fmt.Errorf("ipv6 urltest AAAA lookup: %w", err)
	}
	var lastErr error
	for _, address := range addresses {
		if !address.Is6() || address.Is4In6() {
			continue
		}
		startedAt := time.Now()
		instance, dialErr := detour.DialContext(ctx, N.NetworkTCP, M.SocksaddrFrom(address, uint16(portNumber)))
		if dialErr != nil {
			lastErr = dialErr
			continue
		}
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodHead, link, nil)
		if requestErr != nil {
			instance.Close()
			return 0, requestErr
		}
		client := http.Client{
			Transport: &http.Transport{
				DialContext: func(context.Context, string, string) (net.Conn, error) { return instance, nil },
				TLSClientConfig: &tls.Config{
					ServerName: hostname,
					Time:       ntp.TimeFuncFromContext(ctx),
					RootCAs:    adapter.RootPoolFromContext(ctx),
				},
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
		response, requestErr := client.Do(request)
		client.CloseIdleConnections()
		instance.Close()
		if requestErr != nil {
			lastErr = requestErr
			continue
		}
		response.Body.Close()
		if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusBadRequest {
			lastErr = fmt.Errorf("bad status: %s", response.Status)
			continue
		}
		delay := uint16(time.Since(startedAt) / time.Millisecond)
		if delay == 0 {
			delay = 1
		}
		return delay, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("ipv6 urltest AAAA lookup returned no IPv6 address")
	}
	return 0, lastErr
}
