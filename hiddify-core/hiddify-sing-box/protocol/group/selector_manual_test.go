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
	"github.com/sagernet/sing/service"
)

type selectorTestManager struct {
	adapter.OutboundManager
	items map[string]adapter.Outbound
}

func (m selectorTestManager) Outbound(tag string) (adapter.Outbound, bool) {
	value, ok := m.items[tag]
	return value, ok
}

type selectorTestCache struct {
	adapter.CacheFile
	selected string
}

func (c selectorTestCache) LoadSelected(string) string { return c.selected }

func TestStartupSelectionHonorsExplicitChoiceAndOtherwiseKeepsCache(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		prefer                   bool
		configured, cached, want string
		wantError                bool
	}{
		{"baseline cache", false, "balance", "manual-server", "manual-server", false},
		{"explicit Auto", true, "balance", "manual-server", "balance", false},
		{"explicit manual", true, "manual-server", "balance", "manual-server", false},
		{"removed server", true, "removed", "balance", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			items := map[string]adapter.Outbound{"balance": newSelectorTestOutbound("balance"), "manual-server": newSelectorTestOutbound("manual-server")}
			ctx := service.ContextWith[adapter.CacheFile](context.Background(), selectorTestCache{selected: tc.cached})
			s := &Selector{Adapter: adapterOutbound.NewAdapter("selector", "select", nil, nil), ctx: ctx,
				outbound: selectorTestManager{items: items}, tags: []string{"balance", "manual-server"},
				outbounds: make(map[string]adapter.Outbound), defaultTag: tc.configured, preferDefault: tc.prefer}
			err := s.Start()
			if tc.wantError {
				if err == nil {
					t.Fatal("invalid explicit choice accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got := s.Now(); got != tc.want {
				t.Fatalf("runtime=%s want=%s", got, tc.want)
			}
		})
	}
}

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

func TestManualSelectorStoresRealOutboundForTCPAndUDP(t *testing.T) {
	manual := newSelectorTestOutbound("manual-server")
	selector := &Selector{
		tags:      []string{manual.Tag()},
		outbounds: map[string]adapter.Outbound{manual.Tag(): manual},
	}
	selector.selected.Store(manual)

	tcpMetadata := &adapter.InboundContext{}
	tcpCtx := adapter.WithContext(context.Background(), tcpMetadata)
	_, _ = selector.DialContext(tcpCtx, N.NetworkTCP, M.ParseSocksaddr("example.com:443"))
	if got := tcpMetadata.GetRealOutbound(); got != manual.Tag() {
		t.Fatalf("tcp real outbound = %q, want %q", got, manual.Tag())
	}

	udpMetadata := &adapter.InboundContext{}
	udpCtx := adapter.WithContext(context.Background(), udpMetadata)
	_, _ = selector.ListenPacket(udpCtx, M.ParseSocksaddr("example.com:443"))
	if got := udpMetadata.GetRealOutbound(); got != manual.Tag() {
		t.Fatalf("udp real outbound = %q, want %q", got, manual.Tag())
	}
}
