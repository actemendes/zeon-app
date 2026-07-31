package route

import (
	"github.com/sagernet/sing-box/adapter"
	N "github.com/sagernet/sing/common/network"
)

func zeonOutboundTag(dialer N.Dialer) string {
	if outbound, ok := dialer.(adapter.Outbound); ok {
		return outbound.Tag()
	}
	return ""
}

func zeonOutboundType(dialer N.Dialer) string {
	if outbound, ok := dialer.(adapter.Outbound); ok {
		return outbound.Type()
	}
	return ""
}
