package balancer

import (
	"context"
	"net"
	"sort"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/interrupt"
	"github.com/sagernet/sing-box/common/monitoring"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

func RegisterLoadBalance(registry *outbound.Registry) {
	outbound.Register[option.BalancerOutboundOptions](registry, C.TypeBalancer, NewLoadBalance)
}

var _ adapter.OutboundGroup = (*Balancer)(nil)

const (
	StrategyRoundRobin        = "round-robin"
	StrategyConsistentHashing = "consistent-hashing"
	StrategyStickySessions    = "sticky-sessions"
	StrategyLowestDelay       = "lowest-delay"
	StrategySmartActiveAuto   = "smart-active-auto"
)

type Balancer struct {
	outbound.Adapter
	ctx                          context.Context
	router                       adapter.Router
	outbound                     adapter.OutboundManager
	connection                   adapter.ConnectionManager
	logger                       log.ContextLogger
	tags                         []string
	link                         string
	interval                     time.Duration
	tolerance                    uint16
	idleTimeout                  time.Duration
	strategyFn                   Strategy
	options                      option.BalancerOutboundOptions
	interruptExternalConnections bool

	monitor               *monitoring.OutboundMonitoring
	smartActiveDebugFault smartActiveHistoryFault

	availbleOutbounds []adapter.Outbound
	close             chan struct{}
	interruptGroup    *interrupt.Group
}

func NewLoadBalance(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options option.BalancerOutboundOptions) (adapter.Outbound, error) {
	outbound := &Balancer{
		Adapter:                      outbound.NewAdapter(C.TypeBalancer, tag, []string{N.NetworkTCP, N.NetworkUDP}, options.Outbounds),
		ctx:                          ctx,
		router:                       router,
		outbound:                     service.FromContext[adapter.OutboundManager](ctx),
		connection:                   service.FromContext[adapter.ConnectionManager](ctx),
		logger:                       logger,
		tags:                         options.Outbounds,
		tolerance:                    options.Tolerance,
		interruptExternalConnections: options.InterruptExistConnections,
		options:                      options,
		interruptGroup:               interrupt.NewGroup(),
	}
	if len(outbound.tags) == 0 {
		return nil, E.New("missing tags")
	}

	return outbound, nil
}

func (s *Balancer) Strategy() string {
	return s.options.Strategy
}

func (s *Balancer) Start() error {
	s.monitor = monitoring.Get(s.ctx)
	s.logger.Info("starting load balance, monitoring enabled: ", s.monitor != nil)
	s.logger.Info("[AutoStrategy] selected=", s.options.Strategy)
	outbounds := make([]adapter.Outbound, 0, len(s.tags))
	for i, tag := range s.tags {
		detour, loaded := s.outbound.Outbound(tag)
		if !loaded {
			return E.New("outbound ", i, " not found: ", tag)
		}
		outbounds = append(outbounds, detour)
	}
	switch s.options.Strategy {
	case StrategyRoundRobin:
		s.strategyFn = NewRoundRobin(outbounds, s.options)
	case StrategyConsistentHashing:
		s.strategyFn = NewConsistentHashing(outbounds, s.options)
	case StrategyStickySessions:
		s.strategyFn = NewStickySession(outbounds, s.options)
	case StrategyLowestDelay:
		s.strategyFn = NewLowestDelay(outbounds, s.options)
	case StrategySmartActiveAuto:
		s.strategyFn = NewSmartActive(outbounds, s.options)
		s.smartActiveDebugFault = newSmartActiveDebugFault(s.options)
	default:
		return E.New("unknown load balance strategy: ", s.options.Strategy)
	}

	return nil
}

func (s *Balancer) PostStart() error {
	go s.worker()

	return nil
}

func (s *Balancer) worker() {
	observer, err := s.monitor.SubscribeGroup(s.Tag())
	if err != nil {
		s.logger.Error("failed to observe monitoring group: ", err)
		return
	}
	defer s.monitor.UnsubscribeGroup(s.Tag(), observer)

	for {
		select {
		case <-s.close:
			return

		case <-s.ctx.Done():
			return
		case _, ok := <-observer:
			if !ok {
				return
			}
			outbounds := s.monitor.OutboundsHistory(s.Tag())
			if s.smartActiveDebugFault != nil && s.smartActiveDebugFault.Apply(s.strategyFn.Now(), outbounds) {
				s.logger.Warn("[SmartActiveDebugFault] applied to active=", s.strategyFn.Now())
			}
			changed := s.strategyFn.UpdateOutboundsInfo(outbounds)
			if s.options.Strategy == StrategySmartActiveAuto {
				s.logSmartActiveDecision(outbounds)
			}
			if changed {
				s.logAutoDecision(outbounds)
				s.interruptGroup.Interrupt(s.interruptExternalConnections)
			}

		}
	}
}

func (s *Balancer) logSmartActiveDecision(history map[string]*adapter.URLTestHistory) {
	strategy, ok := s.strategyFn.(*SmartActive)
	if !ok {
		return
	}
	decision := strategy.LastDecision()
	recovered := strategy.LastRecoveries()
	current := strategy.Now()
	currentHistory := history[current]
	decisionReason := decision.reason
	if s.monitor != nil && s.monitor.RecentManualRefresh(s.Tag()) && decisionReason != "" {
		decisionReason = "user_refresh_" + decisionReason
	}
	s.logger.Info("[SmartActiveState] current=", current, " status=", smartActiveState(currentHistory),
		" score=", getTagHealthScore(current, history), " degradation=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.DegradationPoints }),
		" runtime_penalty=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.RuntimePenalty }),
		" real_user_penalty=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.RealUserPenalty }),
		" stability=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.StabilityPoints }))
	for _, tag := range s.tags {
		historyItem := history[tag]
		s.logger.Debug("[SmartActiveCandidate] tag=", tag, " score=", getTagHealthScore(tag, history),
			" evidence=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.StabilityPoints }),
			" volatility=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.VolatilityPenalty }),
			" reason=", smartActiveState(historyItem))
	}
	s.logger.Info("[SmartActiveDecision] action=", decision.action, " reason=", decisionReason, " current=", current)
	if decision.action == "switch" {
		if decision.state == "CRITICAL" {
			s.logger.Warn("[SmartActiveEmergency] from=", decision.from, " to=", decision.to, " error=", errorTypeOf(history[decision.from]))
		}
		s.logger.Warn("[SmartActiveSwitch] from=", decision.from, " to=", decision.to, " reason=", decisionReason)
	}
	for _, tag := range recovered {
		s.logger.Info("[SmartActiveRecovery] tag=", tag, " restored=true score=", getTagHealthScore(tag, history), " clean_probes=2")
	}
}

func historyValue(history *adapter.URLTestHistory, get func(*adapter.URLTestHistory) int) int {
	if history == nil {
		return 0
	}
	return get(history)
}

func errorTypeOf(history *adapter.URLTestHistory) string {
	if history == nil {
		return "unknown"
	}
	return history.ErrorType
}

// logAutoDecision records enough information to explain a strategy change
// without logging config secrets or probe credentials. It is emitted only when
// the strategy's selected/acceptable set actually changes.
func (s *Balancer) logAutoDecision(history map[string]*adapter.URLTestHistory) {
	tags := append([]string(nil), s.tags...)
	sort.Strings(tags)
	bestTag := ""
	bestScore := -1
	bestDelay := monitoring.TimeoutDelay
	for _, tag := range tags {
		his := history[tag]
		delay := getTagDelay(tag, history)
		success := getTagSuccess(tag, history)
		score := getTagHealthScore(tag, history)
		runtimePenalty, udpPenalty, freshnessPenalty, fromCache := 0, 0, 0, false
		if his != nil {
			runtimePenalty = his.RuntimePenalty
			udpPenalty = his.UDPPenalty
			freshnessPenalty = his.FreshnessPenalty
			fromCache = his.IsFromCache
		}
		s.logger.Info("[AutoDecisionCandidates] tag=", tag, " name=", tag, " delay=", delay,
			" success=", success, " health_score=", score, " runtime_penalty=", runtimePenalty,
			" udp_penalty=", udpPenalty, " freshness_penalty=", freshnessPenalty,
			" is_from_cache=", fromCache, " selected=", tag == s.strategyFn.Now())
		if success && (score > bestScore || (score == bestScore && delay < bestDelay)) {
			bestTag, bestScore, bestDelay = tag, score, delay
		}
	}
	selectedTag := s.strategyFn.Now()
	selectedScore := getTagHealthScore(selectedTag, history)
	selectedDelay := getTagDelay(selectedTag, history)
	reason := s.options.Strategy
	if s.options.Strategy == StrategyRoundRobin {
		reason += "_acceptable_pool"
	}
	s.logger.Info("[AutoDecision] selected_tag=", selectedTag, " selected_name=", selectedTag,
		" reason=", reason, " best_tag=", bestTag, " best_score=", bestScore,
		" selected_score=", selectedScore, " selected_delay=", selectedDelay)
}
func (s *Balancer) Close() error {
	if s.close != nil {
		close(s.close)
	}
	return nil
}

func (s *Balancer) Now() string {
	if s.strategyFn == nil {
		return ""
	}
	return s.strategyFn.Now()
}

func (s *Balancer) All() []string {
	return s.tags
}

func (s *Balancer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	metadata := adapter.ContextFrom(ctx)
	if metadata == nil {
		metadata = &adapter.InboundContext{}
	}
	outbound := s.strategyFn.Select(*metadata, network, true)
	if outbound == nil {
		return nil, E.New("missing supported outbound")
	}
	if metadata != nil {
		metadata.SetRealOutbound(outbound.Tag())
	}

	conn, err := outbound.DialContext(ctx, network, destination)
	if err == nil {
		return s.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	if s.monitor != nil {
		s.monitor.RecordRuntimeError(outbound.Tag(), err)
		s.monitor.InvalidateTest(outbound.Tag())
	}

	return nil, err
}

func (s *Balancer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	metadata := adapter.ContextFrom(ctx)
	if metadata == nil {
		metadata = &adapter.InboundContext{}
	}
	outbound := s.strategyFn.Select(*metadata, N.NetworkUDP, true)
	if outbound == nil {
		return nil, E.New("missing supported outbound")
	}
	if metadata != nil {
		metadata.SetRealOutbound(outbound.Tag())
	}

	conn, err := outbound.ListenPacket(ctx, destination)
	if err == nil {
		return s.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	if s.monitor != nil {
		s.monitor.RecordRuntimeError(outbound.Tag(), err)
		s.monitor.InvalidateTest(outbound.Tag())
	}
	return nil, err
}

func (s *Balancer) NewConnectionEx(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	ctx = interrupt.ContextWithIsExternalConnection(ctx)
	selected := s.strategyFn.Select(metadata, metadata.Network, true)
	if selected == nil {
		return
	}
	metadata.SetRealOutbound(selected.Tag())
	conn = s.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx))
	if outboundHandler, isHandler := selected.(adapter.ConnectionHandlerEx); isHandler {
		outboundHandler.NewConnectionEx(ctx, conn, metadata, onClose)
	} else {
		s.connection.NewConnection(ctx, selected, conn, metadata, onClose)
	}
}

func (s *Balancer) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	ctx = interrupt.ContextWithIsExternalConnection(ctx)
	selected := s.strategyFn.Select(metadata, metadata.Network, true)
	if selected == nil {
		return
	}
	metadata.SetRealOutbound(selected.Tag())
	conn = s.interruptGroup.NewSingPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx))
	if outboundHandler, isHandler := selected.(adapter.PacketConnectionHandlerEx); isHandler {
		outboundHandler.NewPacketConnectionEx(ctx, conn, metadata, onClose)
	} else {
		s.connection.NewPacketConnection(ctx, selected, conn, metadata, onClose)
	}
}

func (s *Balancer) NewDirectRouteConnection(metadata adapter.InboundContext, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error) {
	selected := s.strategyFn.Select(metadata, metadata.Network, true)
	if selected == nil {
		return nil, E.New(metadata.Network, " is not supported by outbound: ")
	}
	metadata.SetRealOutbound(selected.Tag())
	return selected.(adapter.DirectRouteOutbound).NewDirectRouteConnection(metadata, routeContext, timeout)
}
