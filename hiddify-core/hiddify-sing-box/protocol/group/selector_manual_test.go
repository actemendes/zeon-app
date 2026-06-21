package group

import (
	"context"
	"errors"
	"net"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	adapterOutbound "github.com/sagernet/sing-box/adapter/outbound"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type selectorTestOutbound struct {
	adapterOutbound.Adapter
}

func newSelectorTestOutbound(tag string) adapter.Outbound {
	return &selectorTestOutbound{Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)}
}

func (*selectorTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, errors.New("test outbound does not dial")
}

func (*selectorTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("test outbound does not listen")
}

func TestManualSelectorKeepsExplicitSelection(t *testing.T) {
	automatic := newSelectorTestOutbound("balance")
	manual := newSelectorTestOutbound("manual-server")
	selector := &Selector{
		tags:      []string{automatic.Tag(), manual.Tag()},
		outbounds: map[string]adapter.Outbound{automatic.Tag(): automatic, manual.Tag(): manual},
	}
	selector.selected.Store(manual)

	for i := 0; i < 20; i++ {
		if selected := selector.Now(); selected != manual.Tag() {
			t.Fatalf("manual selector changed on read %d: got %s", i, selected)
		}
	}
}
