//go:build !zeon_route_validation

package zeonvalidation

import (
	"context"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/logger"
)

func BeginConnection(
	ctx context.Context,
	_ logger.ContextLogger,
	_ *adapter.InboundContext,
	_ string,
	_ string,
	_ string,
) context.Context {
	return ctx
}

func RecordConnectionDialResult(context.Context, logger.ContextLogger, error) {}

func RecordConnectionHandshakeResult(context.Context, logger.ContextLogger, error) {}

func RecordConnectionTransferEnd(context.Context, logger.ContextLogger, bool, int64, error) {}
