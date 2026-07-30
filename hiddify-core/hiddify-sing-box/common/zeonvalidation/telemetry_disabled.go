//go:build !zeon_route_validation

package zeonvalidation

import (
	"context"
	"net/netip"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/logger"
)

// Enabled reports whether validation-only route telemetry is compiled in.
func Enabled() bool {
	return false
}

// RecordRoute is intentionally empty in production builds.
func RecordRoute(
	context.Context,
	logger.ContextLogger,
	*adapter.InboundContext,
	adapter.Rule,
	int,
	adapter.Outbound,
	bool,
) {
}

// RecordDNS is intentionally empty in production builds.
func RecordDNS(
	context.Context,
	logger.ContextLogger,
	string,
	[]netip.Addr,
	[]string,
	uint16,
	adapter.DNSRule,
	int,
	adapter.DNSTransport,
	bool,
	bool,
) {
}
