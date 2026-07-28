package group

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"os"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/interrupt"
	"github.com/sagernet/sing-box/common/monitoring"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

func RegisterSelector(registry *outbound.Registry) {
	outbound.Register[option.SelectorOutboundOptions](registry, C.TypeSelector, NewSelector)
}

var (
	_ adapter.OutboundGroup             = (*Selector)(nil)
	_ adapter.ConnectionHandlerEx       = (*Selector)(nil)
	_ adapter.PacketConnectionHandlerEx = (*Selector)(nil)
)

type Selector struct {
	outbound.Adapter
	ctx                          context.Context
	outbound                     adapter.OutboundManager
	connection                   adapter.ConnectionManager
	logger                       logger.ContextLogger
	tags                         []string
	defaultTag                   string
	outbounds                    map[string]adapter.Outbound
	selected                     common.TypedValue[adapter.Outbound]
	interruptGroup               *interrupt.Group
	interruptExternalConnections bool
	sessionGeneration            string
}

func NewSelector(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options option.SelectorOutboundOptions) (adapter.Outbound, error) {
	outbound := &Selector{
		Adapter:                      outbound.NewAdapter(C.TypeSelector, tag, nil, options.Outbounds),
		ctx:                          ctx,
		outbound:                     service.FromContext[adapter.OutboundManager](ctx),
		connection:                   service.FromContext[adapter.ConnectionManager](ctx),
		logger:                       logger,
		tags:                         options.Outbounds,
		defaultTag:                   options.Default,
		outbounds:                    make(map[string]adapter.Outbound),
		interruptGroup:               interrupt.NewGroup(),
		interruptExternalConnections: options.InterruptExistConnections,
		sessionGeneration:            os.Getenv("ZEON_SESSION_GENERATION"),
	}
	if len(outbound.tags) == 0 {
		return nil, E.New("missing tags")
	}
	return outbound, nil
}

func (s *Selector) Network() []string {
	selected := s.selected.Load()
	if selected == nil {
		return []string{N.NetworkTCP, N.NetworkUDP}
	}
	return selected.Network()
}

func (s *Selector) Start() error {
	for i, tag := range s.tags {
		detour, loaded := s.outbound.Outbound(tag)
		if !loaded {
			return E.New("outbound ", i, " not found: ", tag)
		}
		s.outbounds[tag] = detour
	}
	if s.Tag() != "" {
		cacheFile := service.FromContext[adapter.CacheFile](s.ctx)
		if cacheFile != nil {
			selected := cacheFile.LoadSelected(s.Tag())
			if selected != "" {
				detour, loaded := s.outbounds[selected]
				if loaded {
					s.selected.Store(detour)
					return nil
				}
			}
		}
	}

	if s.defaultTag != "" {
		detour, loaded := s.outbounds[s.defaultTag]
		if !loaded {
			return E.New("default outbound not found: ", s.defaultTag)
		}
		s.selected.Store(detour)
		return nil
	}

	s.selected.Store(s.outbounds[s.tags[0]])
	return nil
}

func (s *Selector) PostStart() error {
	s.pingSelected()
	return nil
}

func (s *Selector) Now() string {
	selected := s.selected.Load()
	if selected == nil {
		return s.tags[0]
	}
	return selected.Tag()
}

func (s *Selector) All() []string {
	return s.tags
}

func (s *Selector) SelectOutbound(tag string) bool {
	defer s.pingSelected()
	if !selectorSessionGenerationMatches(s.sessionGeneration) {
		s.logger.Warn("[SelectorStaleResult] session_generation=", s.sessionGeneration, " source=manual_select action=ignored")
		return false
	}
	detour, loaded := s.outbounds[tag]
	if !loaded {
		return false
	}

	previous := s.selected.Swap(detour)
	if previous == detour {
		return true
	}
	if s.Tag() != "" {
		cacheFile := service.FromContext[adapter.CacheFile](s.ctx)
		if cacheFile != nil {
			err := cacheFile.StoreSelected(s.Tag(), tag)
			if err != nil {
				s.logger.Error("store selected: ", err)
			}
		}
	}

	result := s.interruptGroup.Interrupt(false)
	previousTag := ""
	if previous != nil {
		previousTag = previous.Tag()
	}
	s.logger.Warn(
		"[SelectorSwitch] session_generation=", s.sessionGeneration,
		" type=manual reason=user_reselect",
		" old_id=", selectorOpaqueOutboundID(previousTag),
		" new_id=", selectorOpaqueOutboundID(detour.Tag()),
		" interrupt_external=false",
		" configured_interrupt_external=", s.interruptExternalConnections,
		" closed_tcp=", result.ClosedTCP,
		" closed_udp=", result.ClosedUDP,
		" closed_external=", result.ClosedExternal,
		" full_core_restart=false",
	)
	return true
}

func selectorOpaqueOutboundID(tag string) string {
	if tag == "" {
		return "none"
	}
	sum := sha256.Sum256([]byte(tag))
	return hex.EncodeToString(sum[:6])
}

func selectorSessionGenerationMatches(captured string) bool {
	current := os.Getenv("ZEON_SESSION_GENERATION")
	return captured == "" || current == "" || captured == current
}
func (s *Selector) pingSelected() {
	selected := s.selected.Load()
	if selected == nil {
		s.logger.Warn("no outbound selected")
		return
	}
	realTag := RealTag(selected)
	// s.logger.Debug("pinging selected outbound: ", selected.Tag(), " (real tag: ", realTag, ")")
	if r, ok := s.outbound.Outbound(realTag); ok {
		// s.logger.Debug("found real tag: ", selected.Tag(), " (real tag: ", r.Tag(), ")")
		if _, ok := r.(adapter.OutboundGroup); !ok {
			monitoring.Get(s.ctx).TestNow(realTag)
		} else {
			// s.logger.Debug(" real tag: is a group so skipping ping", selected.Tag(), " (real tag: ", r.Tag(), ")")
			monitoring.Get(s.ctx).SignalChange(s.Tag())
		}
	}
}
func (s *Selector) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	selected := s.selected.Load()
	if metadata := adapter.ContextFrom(ctx); metadata != nil && metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(RealTag(selected))
	}
	conn, err := selected.DialContext(ctx, network, destination)
	if err != nil {
		return nil, err
	}
	return s.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
}

func (s *Selector) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	selected := s.selected.Load()
	if metadata := adapter.ContextFrom(ctx); metadata != nil && metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(RealTag(selected))
	}
	conn, err := selected.ListenPacket(ctx, destination)
	if err != nil {
		return nil, err
	}
	return s.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
}

func (s *Selector) NewConnectionEx(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	ctx = interrupt.ContextWithIsExternalConnection(ctx)
	selected := s.selected.Load()
	if metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(RealTag(selected))
	}
	conn = s.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx))
	if outboundHandler, isHandler := selected.(adapter.ConnectionHandlerEx); isHandler {
		outboundHandler.NewConnectionEx(ctx, conn, metadata, onClose)
	} else {
		s.connection.NewConnection(ctx, selected, conn, metadata, onClose)
	}
}

func (s *Selector) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	ctx = interrupt.ContextWithIsExternalConnection(ctx)
	selected := s.selected.Load()
	if metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(RealTag(selected))
	}
	conn = s.interruptGroup.NewSingPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx))
	if outboundHandler, isHandler := selected.(adapter.PacketConnectionHandlerEx); isHandler {
		outboundHandler.NewPacketConnectionEx(ctx, conn, metadata, onClose)
	} else {
		s.connection.NewPacketConnection(ctx, selected, conn, metadata, onClose)
	}
}

func (s *Selector) NewDirectRouteConnection(metadata adapter.InboundContext, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error) {
	selected := s.selected.Load()
	if !common.Contains(selected.Network(), metadata.Network) {
		return nil, E.New(metadata.Network, " is not supported by outbound: ", selected.Tag())
	}
	return selected.(adapter.DirectRouteOutbound).NewDirectRouteConnection(metadata, routeContext, timeout)
}

func RealTag(detour adapter.Outbound) string {
	if group, isGroup := detour.(adapter.OutboundGroup); isGroup {
		return group.Now()
	}
	return detour.Tag()
}
