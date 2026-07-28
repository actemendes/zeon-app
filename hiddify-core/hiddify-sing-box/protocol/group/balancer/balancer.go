package balancer

import (
	"context"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/conntrack"
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
	sessionGeneration            string

	monitor               *monitoring.OutboundMonitoring
	smartActiveDebugFault smartActiveHistoryFault

	availbleOutbounds []adapter.Outbound
	close             chan struct{}
	closeOnce         sync.Once
	interruptGroup    *interrupt.Group
	strategyUpdate    sync.Mutex
	activeMonitorCtx  context.Context
	activeMonitorStop context.CancelFunc
	activeMonitorWake chan struct{}
	activeMonitorWG   sync.WaitGroup

	lastHandledBatchGeneration uint64
	lastHandledBatchNumber     int
	failedActiveRefreshPending bool
}

func NewLoadBalance(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options option.BalancerOutboundOptions) (adapter.Outbound, error) {
	activeMonitorCtx, activeMonitorStop := context.WithCancel(ctx)
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
		sessionGeneration:            os.Getenv("ZEON_SESSION_GENERATION"),
		options:                      options,
		interruptGroup:               interrupt.NewGroup(),
		close:                        make(chan struct{}),
		activeMonitorCtx:             activeMonitorCtx,
		activeMonitorStop:            activeMonitorStop,
		activeMonitorWake:            make(chan struct{}, 1),
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
		s.logger.Info("[SmartActiveLifecycle] event=vpn_start group=", s.Tag(), " active=pending_verified_batch candidates=", len(outbounds))
	default:
		return E.New("unknown load balance strategy: ", s.options.Strategy)
	}

	return nil
}

func (s *Balancer) PostStart() error {
	go s.worker()
	if s.options.Strategy == StrategySmartActiveAuto && s.monitor != nil {
		// A new Smart Active instance must receive one coherent full generation.
		// Otherwise recently cached successes are skipped by the normal interval
		// filter and startup cannot make a fresh, evidence-based selection.
		s.monitor.RequestFullCycle()
		s.activeMonitorWG.Add(1)
		go s.monitorActiveServer()
	}

	return nil
}

func (s *Balancer) worker() {
	observer, err := s.monitor.SubscribeGroup(s.Tag())
	if err != nil {
		s.logger.Error("failed to observe monitoring group: ", err)
		return
	}
	defer s.monitor.UnsubscribeGroup(s.Tag(), observer)

	// SubscribeGroup intentionally has no replay buffer. A release build can
	// finish the first monitoring cycle before this worker subscribes. Always
	// consume the current snapshot once after subscribing so a fully completed
	// fresh generation can still establish the first active server.
	if s.options.Strategy == StrategySmartActiveAuto {
		s.logger.Info("[SmartActiveLifecycle] event=initial_snapshot group=", s.Tag())
		s.applyMonitoringUpdate(false, 0)
	}

	for {
		select {
		case <-s.close:
			return

		case <-s.ctx.Done():
			return
		case event, ok := <-observer:
			if !ok {
				return
			}
			manualRefresh := false
			if s.options.Strategy == StrategySmartActiveAuto && s.monitor != nil {
				manualRefresh = s.monitor.ConsumeRecentManualRefresh(s.Tag())
				if manualRefresh {
					s.logger.Info("[SmartActiveLifecycle] event=user_refresh group=", s.Tag())
				}
			}
			batchGeneration := uint64(0)
			if event.BatchCompleted && s.consumeCompletedBatch(event.Generation, event.BatchNumber) {
				batchGeneration = event.Generation
			}
			s.applyMonitoringUpdate(manualRefresh, batchGeneration)

		}
	}
}

func (s *Balancer) applyMonitoringUpdate(manualRefresh bool, batchGeneration uint64) {
	s.strategyUpdate.Lock()
	defer s.strategyUpdate.Unlock()
	if !sessionGenerationMatches(s.sessionGeneration) {
		s.logger.Warn("[SelectorStaleResult] session_generation=", s.sessionGeneration, " source=monitoring_update action=ignored")
		return
	}

	outbounds := s.monitor.OutboundsRankingHistory(s.Tag())
	if s.smartActiveDebugFault != nil && s.smartActiveDebugFault.Apply(s.strategyFn.Now(), outbounds) {
		s.logger.Warn("[SmartActiveDebugFault] applied to active=", s.strategyFn.Now())
	}
	previous := s.strategyFn.Now()
	changed := false
	if manualRefresh {
		if strategy, ok := s.strategyFn.(*SmartActive); ok {
			changed = strategy.UpdateOutboundsInfoForManualRefresh(outbounds)
		} else {
			changed = s.strategyFn.UpdateOutboundsInfo(outbounds)
		}
	} else if batchGeneration > 0 {
		if strategy, ok := s.strategyFn.(*SmartActive); ok {
			changed = strategy.UpdateOutboundsInfoForCompletedBatch(outbounds, batchGeneration)
		} else {
			changed = s.strategyFn.UpdateOutboundsInfo(outbounds)
		}
	} else {
		changed = s.strategyFn.UpdateOutboundsInfo(outbounds)
	}
	if s.options.Strategy == StrategySmartActiveAuto {
		s.logSmartActiveDecision(outbounds)
		s.requestFailedActiveRefresh()
	}
	if changed {
		s.logAutoDecision(outbounds)
		s.logger.Warn("[ActiveServerChanged] group=", s.Tag(), " active=", s.strategyFn.Now())
		policy := preserveSwitchPolicy("regular", s.options.Strategy)
		if strategy, ok := s.strategyFn.(*SmartActive); ok {
			policy = strategy.switchInterruptionPolicy()
		} else if s.options.Strategy == StrategyLowestDelay {
			policy = preserveSwitchPolicy("better_score", "lowest_delay_update")
		}
		s.applySwitchInterruption(policy, previous, s.strategyFn.Now())
		s.signalActiveMonitor()
	}
}

func (s *Balancer) requestFailedActiveRefresh() {
	strategy, ok := s.strategyFn.(*SmartActive)
	if !ok || s.monitor == nil {
		return
	}
	generation, history, source := strategy.SelectionDiagnostics()
	current := strategy.Now()
	if current == "" {
		return
	}
	currentHistory := history[current]
	status := strategy.candidateStatus(current, currentHistory, generation)
	if status.ok {
		s.failedActiveRefreshPending = false
		return
	}
	if currentCheckInProgress(currentHistory) || source == "cache" || s.failedActiveRefreshPending {
		return
	}
	s.failedActiveRefreshPending = true
	s.logger.Warn("[SmartActiveRefreshRequested] active=", current,
		" selection_generation=", generation,
		" history_generation=", historyValue64(currentHistory, func(h *adapter.URLTestHistory) uint64 { return h.CheckGeneration }),
		" source=", source, " reason=", status.reason)
	s.monitor.RequestFullCycle()
}

// consumeCompletedBatch preserves the throttled delivery backstop while
// preventing ordinary runtime, UDP and active-presentation events from
// repeatedly re-entering the completed-batch fast path with old metadata.
func (s *Balancer) consumeCompletedBatch(generation uint64, batch int) bool {
	if generation == 0 {
		return false
	}
	if generation < s.lastHandledBatchGeneration ||
		generation == s.lastHandledBatchGeneration && batch <= s.lastHandledBatchNumber {
		return false
	}
	s.lastHandledBatchGeneration = generation
	s.lastHandledBatchNumber = batch
	return true
}

func (s *Balancer) logSmartActiveDecision(history map[string]*adapter.URLTestHistory) {
	strategy, ok := s.strategyFn.(*SmartActive)
	if !ok {
		return
	}
	decision := strategy.LastDecision()
	recovered := strategy.LastRecoveries()
	selectionGeneration, selectionHistory, resultSource := strategy.SelectionDiagnostics()
	if len(selectionHistory) > 0 {
		history = selectionHistory
	}
	current := strategy.Now()
	currentHistory := history[current]
	decisionReason := decision.reason
	if decision.mode == "user_refresh" && decisionReason != "" && !strings.HasPrefix(decisionReason, "user_refresh_") {
		decisionReason = "user_refresh_" + decisionReason
	}
	s.logger.Info("[SmartActiveState] current=", current, " status=", smartActiveState(currentHistory), " mode=", decision.mode,
		" score=", getTagHealthScore(current, history), " degradation=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.DegradationPoints }),
		" runtime_penalty=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.RuntimePenalty }),
		" real_user_penalty=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.RealUserPenalty }),
		" stability=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.StabilityPoints }))
	s.logger.Info("[SmartActiveDecision] action=", decision.action, " reason=", decisionReason, " from=", decision.from, " to=", decision.to, " current=", current, " mode=", decision.mode)
	s.logger.Info("[SmartActiveSelectionSnapshot] active=", current,
		" selection_generation=", selectionGeneration,
		" history_generation=", historyValue64(currentHistory, func(h *adapter.URLTestHistory) uint64 { return h.CheckGeneration }),
		" success=", historyBool(currentHistory, func(h *adapter.URLTestHistory) bool { return h.Success }),
		" delay=", getTagDelay(current, history),
		" health_score=", getTagHealthScore(current, history),
		" stored_health_score=", historyValue(currentHistory, func(h *adapter.URLTestHistory) int { return h.HealthScore }),
		" url_test_status=", historyString(currentHistory, func(h *adapter.URLTestHistory) string { return h.URLTestStatus }),
		" combined_ready=", historyBool(currentHistory, func(h *adapter.URLTestHistory) bool { return h.CombinedReady }),
		" result_time=", historyTime(currentHistory),
		" source=", resultSource,
		" action=", decision.action, " reason=", decisionReason)
	comparisonTag := decision.to
	if comparisonTag == "" {
		for _, tag := range s.topSmartActiveCandidates(history, 0) {
			if tag != current {
				comparisonTag = tag
				break
			}
		}
	}
	s.logSmartActiveComparison(history, decision, current, comparisonTag, decisionReason)
	for rank, tag := range s.topSmartActiveCandidates(history, 0) {
		historyItem := history[tag]
		candidateStatus := strategy.candidateStatus(tag, historyItem, selectionGeneration)
		s.logger.Info("[SmartActiveRanking] rank=", rank+1, " tag=", tag, " score=", getTagHealthScore(tag, history),
			" delay=", getTagDelay(tag, history), " success=", getTagSuccess(tag, history),
			" fresh=", historyItem != nil && !historyItem.IsFromCache,
			" status=", smartActiveState(historyItem),
			" degradation=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.DegradationPoints }),
			" runtime_penalty=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.RuntimePenalty }),
			" real_user_penalty=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.RealUserPenalty }),
			" volatility=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.VolatilityPenalty }),
			" selected=", tag == current)
		s.logger.Info("[SmartActiveCandidate] rank=", rank+1,
			" real_outbound_tag=", tag,
			" display_tag=", tag,
			" delay=", getTagDelay(tag, history),
			" quality_score=", smartActiveQualityScore(tag, historyItem),
			" speed_score=unavailable",
			" combined_score=", getTagHealthScore(tag, history),
			" external_score=unavailable",
			" udp_health=", smartActiveUDPHealth(historyItem),
			" runtime_penalty=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.RuntimePenalty }),
			" real_user_score=", smartActiveRealUserScore(historyItem),
			" freshness=", smartActiveFreshness(historyItem),
			" generation=", historyValue64(historyItem, func(h *adapter.URLTestHistory) uint64 { return h.CheckGeneration }),
			" ping_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.PingReady }),
			" quality_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.QualityReady }),
			" speed_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.SpeedReady }),
			" udp_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.UDPReady }),
			" combined_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.CombinedReady }),
			" health_state=", smartActiveState(historyItem),
			" bucket=", smartActiveBucket(tag, historyItem),
			" final_ranking_score=", smartActiveFinalRankingScore(tag, historyItem),
			" exclude_reason=", candidateStatus.reason,
			" selected=", tag == current)
		s.logger.Info("[SmartActiveSelectionCandidate] active=", current,
			" tag=", tag, " selection_generation=", selectionGeneration,
			" history_generation=", historyValue64(historyItem, func(h *adapter.URLTestHistory) uint64 { return h.CheckGeneration }),
			" success=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.Success }),
			" delay=", getTagDelay(tag, history), " health_score=", getTagHealthScore(tag, history),
			" stored_health_score=", historyValue(historyItem, func(h *adapter.URLTestHistory) int { return h.HealthScore }),
			" url_test_status=", historyString(historyItem, func(h *adapter.URLTestHistory) string { return h.URLTestStatus }),
			" combined_ready=", historyBool(historyItem, func(h *adapter.URLTestHistory) bool { return h.CombinedReady }),
			" result_time=", historyTime(historyItem), " source=", resultSource,
			" eligible=", candidateStatus.ok, " reject_reason=", candidateStatus.reason)
	}
	if decision.action == "switch" {
		if decision.state == "CRITICAL" {
			s.logger.Warn("[SmartActiveEmergency] from=", decision.from, " to=", decision.to, " error=", errorTypeOf(history[decision.from]))
		}
		s.logger.Warn("[SmartActiveSwitch] from=", decision.from, " to=", decision.to, " reason=", decisionReason,
			" activeConnections=", conntrack.Count(), " activeDownloadBps=unavailable videoLikeLongLivedConnections=unavailable")
	} else if decision.action == "confirm" {
		s.logger.Info("[SmartActiveConfirmed] tag=", decision.to, " reason=", decisionReason, " mode=", decision.mode)
	} else if decision.action == "keep" {
		s.logger.Info("[SmartActiveKeep] current=", current, " candidate=", comparisonTag, " reason=", decisionReason,
			" currentDelay=", getTagDelay(current, history), " candidateDelay=", getTagDelay(comparisonTag, history),
			" currentScore=", getTagHealthScore(current, history), " candidateScore=", getTagHealthScore(comparisonTag, history))
	}
	if current != "" && decision.action != "switch" {
		if status := strategy.candidateStatus(current, currentHistory, selectionGeneration); !status.ok && !currentCheckInProgress(currentHistory) {
			s.logger.Warn("[SmartActiveFailedActiveKept] active=", current,
				" selection_generation=", selectionGeneration,
				" history_generation=", historyValue64(currentHistory, func(h *adapter.URLTestHistory) uint64 { return h.CheckGeneration }),
				" source=", resultSource, " reject_reason=", status.reason,
				" decision_reason=", decisionReason, " compared_candidate=", comparisonTag,
				" request_full_cycle=pending_if_not_requested")
		}
	}
	for _, tag := range recovered {
		s.logger.Info("[SmartActiveRecovery] tag=", tag, " restored=true score=", getTagHealthScore(tag, history), " clean_probes=2")
	}
}

func historyString(history *adapter.URLTestHistory, value func(*adapter.URLTestHistory) string) string {
	if history == nil {
		return ""
	}
	return value(history)
}

func historyTime(history *adapter.URLTestHistory) string {
	if history == nil || history.Time.IsZero() {
		return ""
	}
	return history.Time.Format(time.RFC3339Nano)
}

func (s *Balancer) topSmartActiveCandidates(history map[string]*adapter.URLTestHistory, limit int) []string {
	tags := append([]string(nil), s.tags...)
	sort.SliceStable(tags, func(i, j int) bool {
		left, right := tags[i], tags[j]
		leftSuccess, rightSuccess := getTagSuccess(left, history), getTagSuccess(right, history)
		if leftSuccess != rightSuccess {
			return leftSuccess
		}
		leftScore, rightScore := getTagHealthScore(left, history), getTagHealthScore(right, history)
		if leftScore != rightScore {
			return leftScore > rightScore
		}
		return getTagDelay(left, history) < getTagDelay(right, history)
	})
	if limit > 0 && len(tags) > limit {
		return tags[:limit]
	}
	return tags
}

func (s *Balancer) logSmartActiveComparison(history map[string]*adapter.URLTestHistory, decision smartDecision, current, candidate, decisionReason string) {
	if current == "" || candidate == "" {
		return
	}
	currentDelay := getTagDelay(current, history)
	candidateDelay := getTagDelay(candidate, history)
	delayDelta := int(currentDelay) - int(candidateDelay)
	s.logger.Info("[SmartActiveComparison]",
		" current=", current,
		" currentDelay=", currentDelay,
		" currentQuality=", smartActiveQualityScore(current, history[current]),
		" currentScore=", getTagHealthScore(current, history),
		" currentState=", smartActiveState(history[current]),
		" currentBucket=", smartActiveBucket(current, history[current]),
		" candidate=", candidate,
		" candidateDelay=", candidateDelay,
		" candidateQuality=", smartActiveQualityScore(candidate, history[candidate]),
		" candidateScore=", getTagHealthScore(candidate, history),
		" candidateState=", smartActiveState(history[candidate]),
		" candidateBucket=", smartActiveBucket(candidate, history[candidate]),
		" delayDelta=", delayDelta,
		" decision=", decision.action,
		" reason=", decisionReason)
}

func smartActiveQualityScore(tag string, history *adapter.URLTestHistory) int {
	return getHealthScore(tag, history)
}

func smartActiveRealUserScore(history *adapter.URLTestHistory) int {
	if history == nil {
		return 0
	}
	score := 100 - history.RealUserPenalty - history.DegradationPoints/2
	if score < 0 {
		return 0
	}
	return score
}

func smartActiveFreshness(history *adapter.URLTestHistory) string {
	if history == nil {
		return "missing"
	}
	if history.IsFromCache {
		return "cached"
	}
	if history.Time.IsZero() {
		return "unknown"
	}
	return "fresh"
}

func smartActiveBucket(tag string, history *adapter.URLTestHistory) string {
	if history == nil {
		return "unknown"
	}
	if !history.Success {
		if history.ErrorType == "" {
			return "unknown"
		}
		return "bad"
	}
	score := getHealthScore(tag, history)
	switch {
	case score >= 90:
		return "excellent"
	case score >= 75:
		return "good"
	case score >= 60:
		return "medium"
	case score >= 35:
		return "weak"
	default:
		return "bad"
	}
}

func smartActiveUDPHealth(history *adapter.URLTestHistory) string {
	if history == nil {
		return "unknown"
	}
	if !history.UDPProbeAvailable {
		return "unknown"
	}
	if history.UDPPenalty > 0 {
		return "penalized"
	}
	return "ok"
}

func smartActiveFinalRankingScore(tag string, history *adapter.URLTestHistory) int {
	if reason := smartActiveExcludeReason(tag, history); reason != "" {
		return 0
	}
	return getHealthScore(tag, history)
}

func smartActiveExcludeReason(tag string, history *adapter.URLTestHistory) string {
	if history == nil {
		return "missing_history"
	}
	if history.CheckGeneration == 0 {
		return "missing_generation"
	}
	if history.IsFromCache {
		return "stale_cached"
	}
	if history.URLTestStatus == "checking" {
		return "checking"
	}
	if history.CheckGeneration > 0 && !history.CombinedReady {
		return "not_ready_current_generation"
	}
	if !history.Success {
		if history.ErrorType == "" {
			return "failed_unknown"
		}
		return "failed_" + history.ErrorType
	}
	if smartActiveState(history) == "BAD" || smartActiveState(history) == "CRITICAL" {
		return "bad_health_state"
	}
	if history.RuntimePenalty > 0 || history.RealUserPenalty > 0 || history.DegradationPoints > 0 || history.UDPPenalty > 0 {
		return "penalized"
	}
	if getHealthScore(tag, history) < 35 {
		return "score_below_minimum"
	}
	return ""
}

func historyValue(history *adapter.URLTestHistory, get func(*adapter.URLTestHistory) int) int {
	if history == nil {
		return 0
	}
	return get(history)
}

func historyValue64(history *adapter.URLTestHistory, get func(*adapter.URLTestHistory) uint64) uint64 {
	if history == nil {
		return 0
	}
	return get(history)
}

func historyBool(history *adapter.URLTestHistory, get func(*adapter.URLTestHistory) bool) bool {
	return history != nil && get(history)
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
	s.closeOnce.Do(func() {
		close(s.close)
		if s.activeMonitorStop != nil {
			s.activeMonitorStop()
		}
	})
	s.activeMonitorWG.Wait()
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
