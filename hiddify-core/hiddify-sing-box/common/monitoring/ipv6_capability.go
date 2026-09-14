package monitoring

import (
	"context"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	N "github.com/sagernet/sing/common/network"
)

const (
	IPv6StatusNotTested     = "not_tested"
	IPv6StatusChecking      = "checking"
	IPv6StatusSupported     = "supported"
	IPv6StatusUnavailable   = "unavailable"
	IPv6StatusIndeterminate = "indeterminate"

	DefaultIPv6CapabilityTTL = 10 * time.Minute
)

var defaultIPv6ProbeURLs = []string{
	"https://ipv6.cloudflare.com/cdn-cgi/trace",
	"https://ipv6.google.com/generate_204",
}

type ipv6ProbeResult struct {
	status    string
	checkedAt time.Time
	successes int
	attempts  int
	errorType string
	errorText string
}

func probeIPv6Capability(ctx context.Context, outbound N.Dialer, targets []string) ipv6ProbeResult {
	if len(targets) == 0 {
		targets = defaultIPv6ProbeURLs
	}
	type result struct {
		err error
	}
	results := make(chan result, len(targets))
	for _, target := range targets {
		target := target
		go func() {
			_, err := urltest.IPv6URLTest(ctx, target, outbound)
			results <- result{err: err}
		}()
	}
	probe := ipv6ProbeResult{status: IPv6StatusUnavailable, checkedAt: time.Now(), attempts: len(targets)}
	var errorTypes []string
	var errorTexts []string
	for range targets {
		item := <-results
		if item.err == nil {
			probe.successes++
			continue
		}
		errorType, errorText := urltest.ClassifyProbeError(item.err)
		errorTypes = append(errorTypes, errorType)
		errorTexts = append(errorTexts, errorText)
	}
	if probe.successes > 0 {
		probe.status = IPv6StatusSupported
		return probe
	}
	probe.errorType = strings.Join(errorTypes, ",")
	probe.errorText = strings.Join(errorTexts, "; ")
	if ctx.Err() != nil || allIPv6ProbeErrorsInfrastructure(errorTypes, errorTexts) {
		probe.status = IPv6StatusIndeterminate
	}
	return probe
}

func allIPv6ProbeErrorsInfrastructure(errorTypes, errorTexts []string) bool {
	if len(errorTypes) == 0 {
		return true
	}
	for index, errorType := range errorTypes {
		infrastructure := errorType == urltest.ErrorTypeDNSTimeout || errorType == urltest.ErrorTypeTLSHandshakeFailed
		if errorType == urltest.ErrorTypeUnknown && index < len(errorTexts) {
			text := strings.ToLower(errorTexts[index])
			infrastructure = strings.Contains(text, "dns") || strings.Contains(text, "aaaa")
		}
		if !infrastructure {
			return false
		}
	}
	return true
}

func IPv6CapabilityFresh(history *adapter.URLTestHistory, now time.Time, ttl time.Duration) bool {
	if history == nil || history.IPv6Status != IPv6StatusSupported || history.IPv6CheckedAt.IsZero() {
		return false
	}
	if ttl <= 0 {
		ttl = DefaultIPv6CapabilityTTL
	}
	return !history.IPv6CheckedAt.After(now) && now.Sub(history.IPv6CheckedAt) <= ttl
}

func IPv6ModeRequiresCapability(mode C.DomainStrategy) bool {
	return mode == C.DomainStrategyPreferIPv4 || mode == C.DomainStrategyPreferIPv6 || mode == C.DomainStrategyIPv6Only
}

// IPv6TrafficAllowed applies the family contract to an already resolved flow.
// Domain flows are resolved by the router according to the same IPv6 mode and
// are checked again once their concrete destination reaches a group outbound.
func IPv6TrafficAllowed(mode C.DomainStrategy, metadata adapter.InboundContext, history *adapter.URLTestHistory, now time.Time, ttl time.Duration) bool {
	isIPv4 := metadata.IPVersion == 4 || metadata.Destination.Addr.Is4() || metadata.Destination.Addr.Is4In6()
	isIPv6 := metadata.IPVersion == 6 || metadata.Destination.Addr.Is6() && !metadata.Destination.Addr.Is4In6()
	if mode == C.DomainStrategyIPv4Only {
		return !isIPv6
	}
	if mode == C.DomainStrategyIPv6Only {
		return !isIPv4 && IPv6CapabilityFresh(history, now, ttl)
	}
	if isIPv6 && IPv6ModeRequiresCapability(mode) {
		return IPv6CapabilityFresh(history, now, ttl)
	}
	return true
}
