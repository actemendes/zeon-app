package monitoring

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/service"

	"github.com/sagernet/sing-box/hiddify/ipinfo"
	"github.com/sagernet/sing/common/x/list"

	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/json/badoption"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service/pause"
)

const TimeoutDelay uint16 = 65535

var _ adapter.ConnectionTracker = (*OutboundMonitoring)(nil)
var _ adapter.LifecycleService = (*OutboundMonitoring)(nil)
var _ adapter.InterfaceUpdateListener = (*OutboundMonitoring)(nil)

const (
	defaultWorkerCount    = 10
	defaultDebounceWindow = 500 * time.Millisecond
	defaultURLTestTimeout = 5 * time.Second
	defaultIdleTimeout    = 10 * time.Minute
	defaultInterval       = 3 * time.Minute
	defaultURLTest        = "https://www.gstatic.com/generate_204"
	runtimePenaltyTTL     = 90 * time.Second
	runtimeBurstWindow    = 20 * time.Second
	defaultUDPProbe       = "udp-probe.zeon-vps.link:8443"
	defaultUDPProbeTopN   = 3
	defaultUDPCooldown    = 60 * time.Second

	runtimeTrafficStallMinUploadBytes     = 1024
	runtimeTrafficStallNoDownloadWindow   = 8 * time.Second
	runtimeTrafficStallEvidenceThreshold  = 2
	runtimeTrafficValidationProbeCooldown = 30 * time.Second
	runtimeTrafficTTL                     = 10 * time.Minute
)

// func RegisterService(registry *boxService.Registry) {
// 	boxService.Register[option.MonitoringOptions](registry, C.TypeOutboundMonitor, func(ctx context.Context, logger log.ContextLogger, tag string, options option.MonitoringOptions) (adapter.Service, error) {
// 		return NewOutboundMonitoring(ctx, logger, tag, options)
// 	})
// }

func Get(ctx context.Context) *OutboundMonitoring {
	return service.PtrFromContext[OutboundMonitoring](ctx)
}

// OutboundMonitoring orchestrates URL testing and traffic sampling for outbounds.
type OutboundMonitoring struct {
	endpointManager  adapter.EndpointManager
	outboundManager  adapter.OutboundManager
	logger           log.ContextLogger
	cache            adapter.CacheFile
	ctx              context.Context
	cancel           context.CancelFunc
	tag              string
	pause            pause.Manager
	pauseCallback    *list.Element[pause.Callback]
	started          atomic.Bool
	urls             []string
	currentLinkIndex atomic.Uint32
	access           sync.Mutex
	idleTimeout      time.Duration
	lastActive       common.TypedValue[time.Time]
	workersRunning   atomic.Bool
	mainInterval     time.Duration
	debounceWindow   time.Duration
	urlTestTimeout   time.Duration
	workersCount     int
	history          adapter.URLTestHistoryStorage
	mainTicker       *time.Ticker

	priorityQueue chan *testTask
	normalQueue   chan *testTask

	outbounds map[string]*outboundState
	groups    map[string]*groupState

	cacheDirty atomic.Bool

	cycleSeq     uint64
	cycleRunning atomic.Bool
	// fullCycleRequested is set by Smart Active on every VPN start. Cached
	// successes are useful for display, but they must not cause the startup
	// monitor to probe only the previously invalid subset.
	fullCycleRequested atomic.Bool

	runtimeAccess  sync.Mutex
	runtimeStats   map[string]*adapter.RuntimePenaltyStats
	runtimeTraffic map[string]*adapter.RuntimeTrafficStats

	manualRefreshAccess sync.Mutex
	manualRefreshAt     map[string]time.Time
	manualRefreshRun    sync.Mutex

	udpProbeEnabled  bool
	udpProbeEndpoint string
	udpProbeSecret   []byte
	udpProbeOptions  urltest.UDPProbeOptions
	udpProbeCooldown time.Duration
	udpProbeTopN     int
	udpProbeQueue    chan udpProbeTask
	udpProbeAccess   sync.Mutex
	udpProbeQueued   map[string]bool

	workerWG    sync.WaitGroup
	udpProbeWG  sync.WaitGroup
	schedulerWG sync.WaitGroup
	closerOnce  sync.Once
}

// InterfaceUpdated implements [adapter.InterfaceUpdateListener].
func (m *OutboundMonitoring) InterfaceUpdated() {
	m.startCycleOnce()
}

// Name implements [adapter.LifecycleService].
func (m *OutboundMonitoring) Name() string {
	return "outbound-monitoring"
}

// OutboundsHistory returns the presentation view consumed by APIs and UI.
// A fresh active-server probe may overlay its transport result here without
// changing the coherent full-generation history used for ranking.
func (m *OutboundMonitoring) OutboundsHistory(groupTag string) map[string]*adapter.URLTestHistory {
	return m.outboundsHistory(groupTag, true)
}

// OutboundsRankingHistory returns only coherent monitoring-cycle results.
// Selection algorithms must use this view so an isolated active-server probe
// cannot complete or otherwise alter a full generation.
func (m *OutboundMonitoring) OutboundsRankingHistory(groupTag string) map[string]*adapter.URLTestHistory {
	return m.outboundsHistory(groupTag, false)
}

func (m *OutboundMonitoring) outboundsHistory(groupTag string, includeActiveProbe bool) map[string]*adapter.URLTestHistory {
	histories := make(map[string]*adapter.URLTestHistory)

	grp, ok := m.groups[groupTag]
	if !ok {
		return histories
	}
	//m.logger.Debug("collecting history for group ", groupTag, " with ", len(grp.outbounds), " outbounds")
	for outboundTag := range grp.outbounds {
		histories[outboundTag] = m.getURLTest(outboundTag, includeActiveProbe)
		// m.logger.Error("checking history for outbound ", outboundTag)

	}
	return histories
}

func (m *OutboundMonitoring) getUrlTest(outboundTag string) *adapter.URLTestHistory {
	return m.getURLTest(outboundTag, true)
}

func (m *OutboundMonitoring) getURLTest(outboundTag string, includeActiveProbe bool) *adapter.URLTestHistory {
	state, ok := m.outbounds[outboundTag]
	if !ok {
		return nil
	}

	if grp, ok := m.groups[outboundTag]; ok {
		realtag := RealTag(state.outbound)
		//m.logger.Debug("outbound ", outboundTag, " is a group, checking group ", grp.tag, " with real tag ", realtag)
		if realtag != "" && realtag != outboundTag {
			return m.getURLTest(realtag, includeActiveProbe)
		}

		return m.getMinGroupOutboundHistory(grp.tag, includeActiveProbe)

	}
	state.mu.Lock()
	his := state.history
	if !includeActiveProbe && state.lastResultSourceKnown && !state.lastResultFromFullGeneration && his.CheckGeneration > 0 {
		// A priority/targeted retest is presentation and veto evidence only.
		// It must not settle a full cohort before the member's normal/manual task
		// commits. Keep explicit failures visible so Smart Active can invalidate
		// an older success without promoting this partial result.
		his.CombinedReady = false
		if his.Success {
			his.URLTestStatus = urltest.StatusChecking
		}
	}
	if includeActiveProbe && state.activeProbePresentation != nil &&
		state.activeProbePresentation.rankingRevision == state.rankingRevision {
		his = mergeActiveProbePresentation(state.activeProbePresentation.history, his)
	}
	if his.URLTestStatus == "" {
		his.URLTestStatus = inferURLTestStatus(&his)
	}
	if state.activeProbePresentation == nil || !includeActiveProbe ||
		state.activeProbePresentation.rankingRevision != state.rankingRevision {
		his.IsFromCache = state.from_cache
	}
	state.mu.Unlock()
	m.applyDynamicHealth(outboundTag, &his)
	return &his

}

func (m *OutboundMonitoring) getMinGroupOutboundHistory(groupTag string, includeActiveProbe bool) *adapter.URLTestHistory {
	grp, ok := m.groups[groupTag]
	if !ok {
		return nil
	}
	var minHis *adapter.URLTestHistory
	var minHisFromCache *adapter.URLTestHistory
	for outboundTag := range grp.outbounds {
		his := m.getURLTest(outboundTag, includeActiveProbe)
		if his == nil || his.Delay == 0 {
			continue
		}
		if !his.IsFromCache {
			if minHis == nil {
				minHis = his
			} else if preferHistory(his, minHis) {
				minHis = his
			} else if minHis.IpInfo == nil {
				minHis.IpInfo = his.IpInfo
			}
		} else {
			if minHisFromCache == nil {
				minHisFromCache = his
			} else if preferHistory(his, minHisFromCache) {
				minHisFromCache = his
			} else if minHisFromCache.IpInfo == nil {
				minHisFromCache.IpInfo = his.IpInfo
			}
		}
	}

	final := minHis
	if minHis == nil || minHis.Delay >= TimeoutDelay {
		final = minHisFromCache
	} else if minHisFromCache != nil && minHis.IpInfo == nil {
		final.IpInfo = minHisFromCache.IpInfo
	}

	return final

}

func (m *OutboundMonitoring) RoutedConnection(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, matchedRule adapter.Rule, matchOutbound adapter.Outbound) net.Conn {
	m.Touch()
	return conn
}
func (m *OutboundMonitoring) RoutedPacketConnection(ctx context.Context, conn N.PacketConn, metadata adapter.InboundContext, matchedRule adapter.Rule, matchOutbound adapter.Outbound) N.PacketConn {
	m.Touch()
	return conn
}

// NewOutboundMonitoring creates and starts a monitoring instance.
func NewOutboundMonitoring(ctx context.Context, logger log.ContextLogger, options option.MonitoringOptions) (*OutboundMonitoring, error) {
	if options.Interval <= 0 {
		options.Interval = badoption.Duration(defaultInterval)
	}
	if options.Workers <= 0 {
		options.Workers = defaultWorkerCount
	}
	if options.URLTestTimeout <= 0 {
		options.URLTestTimeout = badoption.Duration(defaultURLTestTimeout)
	}
	if options.IdleTimeout <= 0 {
		options.IdleTimeout = badoption.Duration(defaultIdleTimeout)
	}
	if options.DebounceWindow <= 0 {
		options.DebounceWindow = badoption.Duration(defaultDebounceWindow)
	}

	cloned := append([]string(nil), options.URLs...)
	if len(cloned) == 0 {
		cloned = []string{defaultURLTest}
	}

	var history adapter.URLTestHistoryStorage
	if historyFromCtx := service.PtrFromContext[urltest.HistoryStorage](ctx); historyFromCtx != nil {
		history = historyFromCtx
	} else if clashServer := service.FromContext[adapter.ClashServer](ctx); clashServer != nil {
		history = clashServer.HistoryStorage()
	} else {
		history = urltest.NewHistoryStorage()
	}

	ctx, cancel := context.WithCancel(ctx)
	m := &OutboundMonitoring{
		ctx:             ctx,
		cancel:          cancel,
		urls:            cloned,
		pause:           service.FromContext[pause.Manager](ctx),
		logger:          logger,
		outboundManager: service.FromContext[adapter.OutboundManager](ctx),
		endpointManager: service.FromContext[adapter.EndpointManager](ctx),

		history: history,

		mainInterval:   options.Interval.Build(),
		idleTimeout:    options.IdleTimeout.Build(),
		workersCount:   options.Workers,
		urlTestTimeout: options.URLTestTimeout.Build(),
		debounceWindow: options.DebounceWindow.Build(),

		priorityQueue:  make(chan *testTask, 1000),
		normalQueue:    make(chan *testTask, 10000),
		outbounds:      make(map[string]*outboundState),
		groups:         make(map[string]*groupState),
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),

		udpProbeQueued: make(map[string]bool),
	}
	m.configureUDPProbe(options)

	return m, nil
}

func (m *OutboundMonitoring) Start(stage adapter.StartStage) error {
	m.logger.Info("starting outbound monitoring ", stage)
	switch stage {
	case adapter.StartStateInitialize:
		m.cache = service.FromContext[adapter.CacheFile](m.ctx)

		for _, outbound := range m.outboundManager.Outbounds() {
			// if _, ok := outbound.(adapter.OutboundGroup); !ok {
			m.outbounds[outbound.Tag()] = &outboundState{groupTags: []string{}, invalid: true, outbound: outbound, dependencies: outbound.Dependencies(), history: adapter.URLTestHistory{URLTestStatus: urltest.StatusNotTested}}
			// }
			//m.logger.Info("registered outbound for monitoring: ", outbound.Tag())
		}
		for _, outbound := range m.endpointManager.Endpoints() {
			// if _, ok := outbound.(adapter.OutboundGroup); !ok {
			m.outbounds[outbound.Tag()] = &outboundState{groupTags: []string{}, invalid: true, outbound: outbound, dependencies: outbound.Dependencies(), history: adapter.URLTestHistory{URLTestStatus: urltest.StatusNotTested}}
			// }
			//m.logger.Info("registered outbound for monitoring: ", outbound.Tag())
		}
		for tag, outbound := range m.outbounds {
			for _, dep := range outbound.dependencies {
				m.outbounds[dep].dependenciesInverse = append(m.outbounds[dep].dependenciesInverse, tag)
			}
		}

		m.logger.Info("registered ", len(m.outbounds), " outbounds for monitoring")
		grp := m.makeGroup("")
		for tag := range m.outbounds {
			grp.outbounds[tag] = struct{}{}
			m.outbounds[tag].groupTags = append(m.outbounds[tag].groupTags, "")
		}
		for _, outbound := range m.outboundManager.Outbounds() {
			if og, ok := outbound.(adapter.OutboundGroup); ok {
				groupTag := og.Tag()
				grp := m.makeGroup(groupTag)
				for _, tag := range og.All() {
					if _, exists := m.outbounds[tag]; !exists {
						return errors.New("outbound monitoring: outbound not found: " + tag + " in group " + groupTag)
					}
					grp.outbounds[tag] = struct{}{}
					m.outbounds[tag].groupTags = append(m.outbounds[tag].groupTags, groupTag)
				}

				//m.logger.Info("registered outbound group for monitoring: ", groupTag, " with ", len(og.All()), " outbounds")

			}
		}
		m.logger.Info("registered ", len(m.groups), " outbound groups for monitoring")
		m.loadHistory()
	case adapter.StartStatePostStart:
		for i := 0; i < m.workersCount; i++ {
			m.workerWG.Add(1)
			go m.workerLoop()
		}
		if m.udpProbeEnabled {
			m.udpProbeWG.Add(1)
			go m.udpProbeLoop()
		}
		for groupTag := range m.groups {
			m.schedulerWG.Add(1)
			go m.groupNotifierLoop(m.groups[groupTag])
		}

		m.started.Store(true)
		m.Touch()
	}

	return nil
}

func (m *OutboundMonitoring) startTimerWorkers() {
	m.access.Lock()
	defer m.access.Unlock()
	if !m.started.Load() {
		return
	}
	if !m.workersRunning.CompareAndSwap(false, true) {
		return
	}
	ticker := time.NewTicker(m.mainInterval)
	m.mainTicker = ticker

	m.pauseCallback = pause.RegisterTicker(m.pause, ticker, m.mainInterval, nil)
	m.schedulerWG.Add(1)
	go m.scheduleLoop(ticker)
}
func (m *OutboundMonitoring) stopTimerWorkers() {
	m.access.Lock()
	if !m.workersRunning.CompareAndSwap(true, false) {
		m.access.Unlock()
		return
	}
	ticker := m.mainTicker
	callback := m.pauseCallback
	m.mainTicker = nil
	m.pauseCallback = nil
	m.access.Unlock()
	if ticker != nil {
		ticker.Stop()
	}
	if m.cacheDirty.Load() {
		m.saveHistory()
	}

	if callback != nil {
		m.pause.UnregisterCallback(callback)
	}
}

func (m *OutboundMonitoring) SignalChange(outboundTag string) error {
	if grp, ok := m.groups[outboundTag]; ok {
		select {
		case grp.notifyCh <- struct{}{}:
		default:
		}
		return nil
	}
	state := m.getState(outboundTag)
	if state == nil {
		return errors.New("outbound not registered")
	}
	state.mu.Lock()
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	for _, groupTag := range groupTags {
		if grp, ok := m.groups[groupTag]; ok {
			select {
			case grp.notifyCh <- struct{}{}:
			default:
			}
		}
	}
	return nil

}
func (m *OutboundMonitoring) TestNow(outboundTag string) error {
	tags := m.collectManualRefreshTargets(outboundTag)
	if len(tags) == 0 {
		return errors.New("outbound not registered")
	}
	cycleID := atomic.AddUint64(&m.cycleSeq, 1)
	m.beginCheckGeneration(cycleID, tags, "manual_refresh")
	for _, tag := range tags {
		m.testNowWithGenerationSource(tag, cycleID, true, true)
	}
	return nil
}

func (m *OutboundMonitoring) TestNowAndWait(outboundTag string, timeout time.Duration) error {
	m.manualRefreshRun.Lock()
	defer m.manualRefreshRun.Unlock()

	tags := m.collectManualRefreshTargets(outboundTag)
	if len(tags) == 0 {
		return errors.New("outbound not registered")
	}

	cycleID := atomic.AddUint64(&m.cycleSeq, 1)
	m.beginCheckGeneration(cycleID, tags, "manual_refresh")
	if timeout <= 0 {
		workers := m.workersCount
		if workers <= 0 {
			workers = defaultWorkerCount
		}
		batches := (len(tags) + workers - 1) / workers
		perTargetTimeout := m.manualRefreshTargetTimeout()
		timeout = perTargetTimeout*time.Duration(max(1, batches)) + 15*time.Second
		if timeout < 30*time.Second {
			timeout = 30 * time.Second
		}
		if timeout > 3*time.Minute {
			timeout = 3 * time.Minute
		}
	}

	workers := m.workersCount
	if workers <= 0 {
		workers = defaultWorkerCount
	}
	m.logger.Info("[ManualRefresh] started tag=", outboundTag, " targets=", len(tags), " concurrency=", workers,
		" per_target_timeout=", m.manualRefreshTargetTimeout(), " timeout=", timeout)

	report, err := m.runManualRefreshStage(outboundTag, cycleID, tags, timeout)
	refreshedGroups := m.markManualRefreshForTargets(outboundTag, report.completedTargets, time.Now())
	m.logger.Info("[ManualRefresh] reselect_ready tag=", outboundTag, " groups=", strings.Join(refreshedGroups, ","))
	m.emitGroupEvent(refreshedGroups)
	if report.logged {
		m.logCheckGenerationCompleted(cycleID, tags, "manual_refresh")
		if report.timeout && report.completed() > 0 {
			return nil
		}
		return err
	}
	m.logManualRefreshFinished(outboundTag, report)
	m.logCheckGenerationCompleted(cycleID, tags, "manual_refresh")
	if report.timeout && report.completed() > 0 {
		return nil
	}
	return err
}

func (m *OutboundMonitoring) beginCheckGeneration(generation uint64, tags []string, trigger string) {
	if len(tags) == 0 {
		return
	}
	m.logger.Warn("[CheckGenerationStarted] generation=", generation, " trigger=", trigger, " servers=", len(tags))
	for _, tag := range tags {
		m.resetOutboundCheckState(tag, generation)
	}
}

func (m *OutboundMonitoring) resetOutboundCheckState(tag string, generation uint64) {
	state := m.getState(tag)
	if state == nil {
		return
	}
	now := time.Now()
	state.historyPublish.Lock()
	state.mu.Lock()
	previousGeneration := state.history.CheckGeneration
	previousHistory := state.history
	ipInfo := state.history.IpInfo
	runtimePenalty := state.history.RuntimePenalty
	realUserPenalty := state.history.RealUserPenalty
	degradation := state.history.DegradationPoints
	stability := state.history.StabilityPoints
	volatility := state.history.VolatilityPenalty
	policyPenalty := state.history.PolicyPenalty
	groupTags := append([]string(nil), state.groupTags...)
	state.history = adapter.URLTestHistory{
		Time:              now,
		IpInfo:            ipInfo,
		URLTestStatus:     urltest.StatusChecking,
		RuntimePenalty:    runtimePenalty,
		RealUserPenalty:   realUserPenalty,
		DegradationPoints: degradation,
		StabilityPoints:   stability,
		VolatilityPenalty: volatility,
		PolicyPenalty:     policyPenalty,
		CheckGeneration:   generation,
	}
	state.lastResultFromFullGeneration = false
	state.lastResultSourceKnown = true
	state.advanceRankingRevision()
	state.from_cache = false
	state.invalid = false
	state.queued = false
	state.priorityQueued = false
	state.enqueuedCycle = 0
	state.udpProbeLast = time.Time{}
	historySnapshot := state.history
	state.mu.Unlock()

	m.udpProbeAccess.Lock()
	delete(m.udpProbeQueued, tag)
	m.udpProbeAccess.Unlock()
	m.history.StoreURLTestHistory(tag, &historySnapshot)
	state.historyPublish.Unlock()
	m.emitGroupEvent(groupTags)
	m.logger.Info("[OutboundCheckReset] tag=", tag,
		" generation=", generation, " previous_generation=", previousGeneration,
		" source=full_generation",
		" old_success=", previousHistory.Success, " new_success=", historySnapshot.Success,
		" old_delay=", previousHistory.Delay, " new_delay=", historySnapshot.Delay,
		" old_score=", previousHistory.HealthScore, " new_score=", historySnapshot.HealthScore,
		" old_url_status=", previousHistory.URLTestStatus, " new_url_status=", historySnapshot.URLTestStatus,
		" old_time=", previousHistory.Time, " new_time=", historySnapshot.Time,
		" bars=cleared")
}

func (m *OutboundMonitoring) logCheckGenerationCompleted(generation uint64, tags []string, trigger string) {
	ready, failed := 0, 0
	for _, tag := range tags {
		state := m.getState(tag)
		if state == nil {
			continue
		}
		state.mu.Lock()
		history := state.history
		state.mu.Unlock()
		if history.CheckGeneration != generation {
			continue
		}
		switch history.URLTestStatus {
		case urltest.StatusSuccess:
			if history.CombinedReady {
				ready++
			}
		case urltest.StatusFailed:
			failed++
		}
	}
	m.logger.Warn("[CheckGenerationCompleted] generation=", generation, " trigger=", trigger, " ready_servers=", ready, " failed_servers=", failed, " selected=deferred_to_smart_active")
}

func (m *OutboundMonitoring) logManualRefreshFinished(outboundTag string, report manualRefreshReport) {
	if report.timeout {
		m.logger.Warn("[ManualRefresh] finished success=", report.success, " failed=", report.failed, " pending=", report.pending, " cancelled=", report.cancelled, " timeout=true tag=", outboundTag)
	} else {
		m.logger.Info("[ManualRefresh] finished success=", report.success, " failed=", report.failed, " pending=", report.pending, " cancelled=", report.cancelled, " timeout=false tag=", outboundTag)
	}
}

func (m *OutboundMonitoring) runManualRefreshStage(outboundTag string, cycleID uint64, tags []string, timeout time.Duration) (manualRefreshReport, error) {
	stageCtx, cancelStage := context.WithCancel(m.ctx)
	var stageWorkerWG sync.WaitGroup
	var stopStageOnce sync.Once
	stopStage := func() {
		stopStageOnce.Do(func() {
			cancelStage()
			stageWorkerWG.Wait()
		})
	}
	defer stopStage()

	resultCh := make(chan testOutcome, len(tags))
	pending := make(map[string]struct{}, len(tags))
	prepared := make([]string, 0, len(tags))
	report := manualRefreshReport{total: len(tags)}

	for _, tag := range tags {
		if m.prepareManualRefreshTarget(tag, cycleID) {
			pending[tag] = struct{}{}
			prepared = append(prepared, tag)
		} else {
			report.cancelled++
			m.logger.Warn("[ManualRefreshTarget] tag=", tag, " status=cancelled reason=not_registered")
		}
	}

	if len(pending) == 0 {
		report.pending = report.total
		return report, nil
	}

	workers := m.workersCount
	if workers <= 0 {
		workers = defaultWorkerCount
	}
	outcomes := make([]testOutcome, 0, len(pending))
	defer func() {
		m.scheduleUDPProbesFromOutcomes(outcomes)
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for start, batchNumber := 0, 1; start < len(prepared); start, batchNumber = start+workers, batchNumber+1 {
		end := min(start+workers, len(prepared))
		batchTags := prepared[start:end]
		batchPending := make(map[string]struct{}, len(batchTags))
		for _, tag := range batchTags {
			batchPending[tag] = struct{}{}
			stageWorkerWG.Add(1)
			go func(target string) {
				defer stageWorkerWG.Done()
				outcome := m.executeManualRefreshTarget(stageCtx, cycleID, target)
				select {
				case resultCh <- outcome:
				case <-stageCtx.Done():
				}
			}(tag)
		}

		for len(batchPending) > 0 {
			select {
			case <-m.ctx.Done():
				report.markTimeout(len(pending))
				stopStage()
				m.cancelManualRefreshTargets(cycleID, pending)
				m.logManualRefreshFinished(outboundTag, report)
				report.logged = true
				m.logManualRefreshCancelledTargets(pending, "context_done")
				return report, m.ctx.Err()
			case outcome := <-resultCh:
				if _, ok := batchPending[outcome.outboundTag]; !ok {
					continue
				}
				delete(batchPending, outcome.outboundTag)
				delete(pending, outcome.outboundTag)
				outcomes = append(outcomes, outcome)
				report.record(outcome)
				m.logManualRefreshOutcome(outcome)
			case <-timer.C:
				report.markTimeout(len(pending))
				stopStage()
				m.cancelManualRefreshTargets(cycleID, pending)
				m.logManualRefreshFinished(outboundTag, report)
				report.logged = true
				m.logManualRefreshCancelledTargets(pending, "global_timeout")
				return report, errors.New("manual refresh timed out")
			}
		}
		m.publishCompletedBatch(cycleID, batchNumber, batchTags)
	}

	report.pending = report.total - report.completed()
	return report, nil
}

func (m *OutboundMonitoring) prepareManualRefreshTarget(tag string, cycleID uint64) bool {
	select {
	case <-m.ctx.Done():
		return false
	default:
	}
	state := m.getState(tag)
	if state == nil {
		return false
	}
	// cycleSeq is only an allocator. Partial refreshes intentionally advance it
	// for a subset of outbounds while an older full-list cycle is still active.
	// Freshness must therefore be checked against this outbound's generation,
	// not against the latest globally allocated number.
	state.mu.Lock()
	if state.history.CheckGeneration != cycleID {
		currentGeneration := state.history.CheckGeneration
		state.mu.Unlock()
		m.logger.Warn("[OutboundCheckIgnored] tag=", tag, " result_generation=", cycleID, " current_generation=", currentGeneration, " stage=prepare reason=stale_generation")
		return false
	}
	state.enqueuedCycle = cycleID
	state.queued = true
	state.history.URLTestStatus = urltest.StatusChecking
	state.history.Time = time.Now()
	state.history.CheckGeneration = cycleID
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	m.logger.Info("[ManualRefreshTarget] tag=", tag, " status=queued generation=", cycleID)
	m.logger.Info("[OutboundCheckStage] tag=", tag, " generation=", cycleID, " stage=ping state=checking")
	m.emitGroupEvent(groupTags)
	return true
}

func (m *OutboundMonitoring) executeManualRefreshTarget(parent context.Context, cycleID uint64, tag string) testOutcome {
	state := m.getState(tag)
	if state == nil {
		outcome := m.newTaskErrorOutcome(tag, cycleID, false, true, errors.New("outbound not registered"))
		outcome.deferNotify = true
		return outcome
	}

	state.mu.Lock()
	state.testing = true
	state.testingCycle = cycleID
	state.queued = false
	state.enqueuedCycle = 0
	state.mu.Unlock()
	startedAt := time.Now()
	m.logger.Info("[ManualRefreshTarget] tag=", tag, " status=started stage=urltest")
	defer func() {
		state.mu.Lock()
		if state.testingCycle == cycleID {
			state.testing = false
			state.testingCycle = 0
		}
		state.mu.Unlock()
	}()

	if !state.outbound.IsReady() {
		m.logger.Info("outbound ", tag, " is not ready, marking URL test failed")
		outcome := m.newTaskErrorOutcome(tag, cycleID, false, true, errors.New("outbound is not ready"))
		outcome.deferNotify = true
		m.applyResult(outcome)
		return outcome
	}

	targetTimeout := m.manualRefreshTargetTimeout()
	history, err, timedOut := runURLTestWithHardTimeout(parent, targetTimeout, func(ctx context.Context) (adapter.URLTestHistory, error) {
		return m.tester(ctx, tag)
	})
	if timedOut {
		m.logger.Warn("[ManualRefreshTarget] tag=", tag, " status=timeout stage=urltest duration=", time.Since(startedAt))
		outcome := m.newTaskErrorOutcome(tag, cycleID, false, true, err)
		outcome.deferNotify = true
		if parent.Err() != nil {
			return outcome
		}
		m.applyResult(outcome)
		return outcome
	}
	outcome := testOutcome{
		outboundTag:    tag,
		history:        history,
		err:            err,
		cycleID:        cycleID,
		priority:       false,
		fullGeneration: true,
		deferNotify:    true,
	}
	m.applyResult(outcome)
	return outcome
}

func (m *OutboundMonitoring) manualRefreshTargetTimeout() time.Duration {
	timeout := m.urlTestTimeout
	if timeout <= 0 {
		timeout = defaultURLTestTimeout
	}
	return timeout
}

func runURLTestWithHardTimeout(parent context.Context, timeout time.Duration, test func(context.Context) (adapter.URLTestHistory, error)) (adapter.URLTestHistory, error, bool) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	type targetResult struct {
		history adapter.URLTestHistory
		err     error
	}
	resultCh := make(chan targetResult, 1)
	go func() {
		history, err := test(ctx)
		resultCh <- targetResult{history: history, err: err}
	}()

	select {
	case result := <-resultCh:
		return result.history, result.err, false
	case <-ctx.Done():
		return adapter.URLTestHistory{}, ctx.Err(), true
	}
}

func (m *OutboundMonitoring) logManualRefreshOutcome(outcome testOutcome) {
	if outcome.err == nil && outcome.history.Success {
		m.logger.Info("[ManualRefreshTarget] tag=", outcome.outboundTag, " status=success delay=", outcome.history.Delay)
		return
	}
	errorType := outcome.history.ErrorType
	if errorType == "" {
		errorType = urltest.ErrorTypeUnknown
	}
	m.logger.Warn("[ManualRefreshTarget] tag=", outcome.outboundTag, " status=failed error_type=", errorType)
}

func (m *OutboundMonitoring) logManualRefreshCancelledTargets(pending map[string]struct{}, reason string) {
	const maxCancelledTargetLogs = 20
	logged := 0
	for tag := range pending {
		if logged >= maxCancelledTargetLogs {
			break
		}
		state := m.getState(tag)
		if state != nil {
			state.mu.Lock()
			started := state.testing
			startedAt := state.history.Time
			state.mu.Unlock()
			if started {
				m.logger.Warn("[ManualRefreshTarget] tag=", tag, " status=stuck duration=", time.Since(startedAt), " stage=urltest reason=", reason)
			} else {
				m.logger.Warn("[ManualRefreshTarget] tag=", tag, " status=cancelled stage=queued reason=", reason)
			}
		} else {
			m.logger.Warn("[ManualRefreshTarget] tag=", tag, " status=cancelled stage=unknown reason=", reason)
		}
		logged++
	}
	if omitted := len(pending) - logged; omitted > 0 {
		m.logger.Warn("[ManualRefreshTarget] status=cancelled reason=", reason, " omitted=", omitted)
	}
}

func (m *OutboundMonitoring) cancelManualRefreshTargets(cycleID uint64, pending map[string]struct{}) {
	for tag := range pending {
		state := m.getState(tag)
		if state == nil {
			continue
		}
		state.mu.Lock()
		if state.history.CheckGeneration == cycleID {
			state.queued = false
			state.priorityQueued = false
			state.enqueuedCycle = 0
			if state.testingCycle == cycleID {
				state.testing = false
				state.testingCycle = 0
			}
		}
		state.mu.Unlock()
	}
}

type manualRefreshReport struct {
	total            int
	success          int
	failed           int
	pending          int
	cancelled        int
	timeout          bool
	logged           bool
	completedTargets []string
}

func (r *manualRefreshReport) record(outcome testOutcome) {
	r.completedTargets = append(r.completedTargets, outcome.outboundTag)
	if outcome.err == nil && outcome.history.Success {
		r.success++
		return
	}
	r.failed++
}

func (r manualRefreshReport) completed() int {
	return r.success + r.failed
}

func (r *manualRefreshReport) markTimeout(pending int) {
	r.timeout = true
	r.cancelled += pending
	r.pending = r.total - r.completed()
}

func (m *OutboundMonitoring) collectManualRefreshTargets(outboundTag string) []string {
	seen := make(map[string]bool)
	var result []string
	var walk func(string)
	walk = func(tag string) {
		if tag == "" || seen[tag] {
			return
		}
		seen[tag] = true
		if grp, ok := m.groups[tag]; ok {
			for child := range grp.outbounds {
				walk(child)
			}
			return
		}
		if _, ok := m.outbounds[tag]; ok {
			result = append(result, tag)
		}
	}
	walk(outboundTag)
	sort.Strings(result)
	return result
}

func (m *OutboundMonitoring) markManualRefresh(groupTag string, at time.Time) {
	m.manualRefreshAccess.Lock()
	if m.manualRefreshAt == nil {
		m.manualRefreshAt = make(map[string]time.Time)
	}
	m.manualRefreshAt[groupTag] = at
	m.manualRefreshAccess.Unlock()
}

func (m *OutboundMonitoring) markManualRefreshForTargets(requestedTag string, tags []string, at time.Time) []string {
	refreshed := make(map[string]struct{}, len(tags))
	for _, tag := range tags {
		refreshed[tag] = struct{}{}
	}
	groups := make(map[string]struct{})
	if _, ok := m.groups[requestedTag]; ok {
		groups[requestedTag] = struct{}{}
	}
	for _, tag := range tags {
		state := m.getState(tag)
		if state == nil {
			continue
		}
		state.mu.Lock()
		for _, groupTag := range state.groupTags {
			if groupTag != "" {
				groups[groupTag] = struct{}{}
			}
		}
		state.mu.Unlock()
	}
	result := make([]string, 0, len(groups))
	for groupTag := range groups {
		groupTargets := m.collectManualRefreshTargets(groupTag)
		if len(groupTargets) == 0 {
			continue
		}
		fullyRefreshed := true
		for _, tag := range groupTargets {
			if _, ok := refreshed[tag]; !ok {
				fullyRefreshed = false
				break
			}
		}
		if !fullyRefreshed {
			continue
		}
		m.markManualRefresh(groupTag, at)
		result = append(result, groupTag)
	}
	sort.Strings(result)
	return result
}

func (m *OutboundMonitoring) RecentManualRefresh(groupTag string) bool {
	m.manualRefreshAccess.Lock()
	defer m.manualRefreshAccess.Unlock()
	if m.manualRefreshAt == nil {
		return false
	}
	at := m.manualRefreshAt[groupTag]
	return !at.IsZero() && time.Since(at) <= 30*time.Second
}

func (m *OutboundMonitoring) ConsumeRecentManualRefresh(groupTag string) bool {
	m.manualRefreshAccess.Lock()
	defer m.manualRefreshAccess.Unlock()
	if m.manualRefreshAt == nil {
		return false
	}
	at := m.manualRefreshAt[groupTag]
	if at.IsZero() || time.Since(at) > 30*time.Second {
		return false
	}
	delete(m.manualRefreshAt, groupTag)
	return true
}

func (m *OutboundMonitoring) testNow(outboundTag string, priority bool) error {
	return m.testNowWithGeneration(outboundTag, atomic.LoadUint64(&m.cycleSeq), priority)
}

func (m *OutboundMonitoring) testNowWithGeneration(outboundTag string, generation uint64, priority bool) error {
	return m.testNowWithGenerationSource(outboundTag, generation, priority, false)
}

func (m *OutboundMonitoring) testNowWithGenerationSource(outboundTag string, generation uint64, priority bool, fullGeneration bool) error {
	m.logger.Info("testing outbound ", outboundTag, " with priority: ", priority)
	if grp, ok := m.groups[outboundTag]; ok {
		for tag := range grp.outbounds {
			m.testNowWithGenerationSource(tag, generation, false, fullGeneration)
		}
	} else {
		state := m.getState(outboundTag)
		if state == nil {
			return errors.New("outbound not registered")
		}

		task := &testTask{
			outboundTag:    outboundTag,
			cycleID:        generation,
			priority:       priority,
			fullGeneration: fullGeneration,
		}

		if !m.enqueueTask(task) {
			// return errors.New("test already queued")
		}
	}
	return nil
}

func (m *OutboundMonitoring) testParents(outboundTag string, first bool) {
	state := m.getState(outboundTag)
	if state == nil {
		return
	}
	if _, ok := m.groups[outboundTag]; !ok && !first {
		m.logger.Info("testing outbound ", outboundTag)
		m.testNow(outboundTag, true)
	}
	for _, dep := range state.dependenciesInverse {
		m.logger.Info("testing parent outbound ", dep, " of ", outboundTag)
		m.testParents(dep, false)
	}
}

// InvalidateTest marks the cached test result as invalid so it will be retested.
func (m *OutboundMonitoring) InvalidateTest(outboundTag string) error {
	state := m.getState(outboundTag)
	if state == nil {
		return errors.New("outbound not registered")
	}
	state.mu.Lock()
	state.invalid = true
	state.mu.Unlock()

	m.enqueueTask(&testTask{
		outboundTag: outboundTag,
		cycleID:     atomic.LoadUint64(&m.cycleSeq),
		priority:    true,
	})

	return nil
}

func (m *OutboundMonitoring) RecordRuntimeError(outboundTag string, err error) {
	if outboundTag == "" || err == nil {
		return
	}
	errorType, errorText := urltest.ClassifyProbeError(err)
	if !urltest.ShouldApplyRuntimePenalty(errorType, false) {
		return
	}

	state := m.getState(outboundTag)
	if state == nil {
		return
	}

	now := time.Now()
	m.runtimeAccess.Lock()
	if m.runtimeStats == nil {
		m.runtimeStats = make(map[string]*adapter.RuntimePenaltyStats)
	}
	stats := m.runtimeStats[outboundTag]
	if stats == nil || now.Sub(stats.UpdatedAt) > runtimePenaltyTTL {
		stats = &adapter.RuntimePenaltyStats{Tag: outboundTag}
		m.runtimeStats[outboundTag] = stats
	}
	incrementRuntimeStats(stats, errorType)
	burstScore := updateRuntimeBurst(stats, errorType, now)
	stats.UpdatedAt = now
	stats.Penalty = calculateRuntimePenalty(stats)
	penalty := stats.Penalty
	m.runtimeAccess.Unlock()

	degradationPoints, realUserPenalty := 0, 0
	state.mu.Lock()
	degradationDelta := runtimeDegradationForError(errorType) + runtimeBurstDegradationBoost(burstScore)
	realUserDelta := runtimeRealUserPenaltyForError(errorType) + runtimeBurstRealUserBoost(burstScore)
	state.history.DegradationPoints = clampHealthPoints(state.history.DegradationPoints + degradationDelta)
	state.history.RealUserPenalty = clampHealthPenalty(state.history.RealUserPenalty + realUserDelta)
	state.history.StabilityPoints = clampStability(state.history.StabilityPoints - runtimeStabilityLossForError(errorType))
	state.history.VolatilityPenalty = clampHealthPenalty(state.history.VolatilityPenalty + 2)
	state.history.RuntimePenalty = penalty
	refreshHealthScore(outboundTag, &state.history, state.from_cache)
	state.invalid = true
	history := state.history
	degradationPoints = state.history.DegradationPoints
	realUserPenalty = state.history.RealUserPenalty
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	m.history.StoreURLTestHistory(outboundTag, &history)
	m.emitGroupEvent(groupTags)

	m.logger.Warn("[RuntimeHealth] tag=", outboundTag, " error_type=", errorType, " penalty=", penalty,
		" degradation=", degradationPoints, " real_user_penalty=", realUserPenalty, " burst_score=", burstScore,
		" score=", getRuntimeHistoryScore(state))
	m.logger.Warn("[RealUserHealth] tag=", outboundTag, " bytes=unavailable error=", errorType,
		" runtime_penalty=", penalty, " real_user_penalty=", realUserPenalty, " degradation=", degradationPoints,
		" score=", getRuntimeHistoryScore(state), " text=", errorText)
	m.logger.Warn("[SmartActiveTrafficHealth] tag=", outboundTag, " event=runtime_error error_type=", errorType,
		" runtime_penalty=", penalty, " real_user_penalty=", realUserPenalty, " degradation=", degradationPoints,
		" score=", getRuntimeHistoryScore(state))
	m.maybeQueueRuntimeValidationProbe(outboundTag, "runtime_error_"+errorType)
}

// RecordRuntimeSuccess is intentionally fed only by successful transport
// handshakes.  This is the real-user signal: it observes connectivity, not
// traffic contents.  Good sessions gradually forgive earlier transient
// failures instead of making a server permanently sticky or permanently bad.
func (m *OutboundMonitoring) RecordRuntimeSuccess(outboundTag string) {
	if outboundTag == "" {
		return
	}
	state := m.getState(outboundTag)
	if state == nil {
		return
	}
	state.mu.Lock()
	previousRealUserPenalty := state.history.RealUserPenalty
	previousDegradation := state.history.DegradationPoints
	state.history.RealUserPenalty = clampHealthPenalty(state.history.RealUserPenalty - 2)
	state.history.DegradationPoints = clampHealthPoints(state.history.DegradationPoints - 3)
	state.history.StabilityPoints = clampStability(state.history.StabilityPoints + 2)
	state.history.VolatilityPenalty = clampHealthPenalty(state.history.VolatilityPenalty - 1)
	refreshHealthScore(outboundTag, &state.history, state.from_cache)
	history := state.history
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	if previousRealUserPenalty == history.RealUserPenalty && previousDegradation == history.DegradationPoints {
		return
	}
	m.history.StoreURLTestHistory(outboundTag, &history)
	m.emitGroupEvent(groupTags)
	m.logger.Debug("[RealUserHealth] tag=", outboundTag, " successful_connection=true bytes=unavailable penalty=", history.RealUserPenalty, " degradation=", history.DegradationPoints, " score=", history.HealthScore)
}

// RecordRuntimeTraffic receives aggregate byte counts from the tunnel copy
// loop. It never observes payloads, domains, URLs, or application data.
func (m *OutboundMonitoring) RecordRuntimeTraffic(outboundTag string, bytes int64, download bool) {
	if outboundTag == "" || bytes <= 0 {
		return
	}
	state := m.getState(outboundTag)
	if state == nil {
		return
	}
	now := time.Now()
	uploadOnlySamples := 0
	cleanSamples := 0
	shouldValidate := false
	direction := "upload"
	if download {
		direction = "download"
	}

	m.runtimeAccess.Lock()
	if m.runtimeTraffic == nil {
		m.runtimeTraffic = make(map[string]*adapter.RuntimeTrafficStats)
	}
	m.pruneRuntimeTrafficLocked(now)
	traffic := m.runtimeTraffic[outboundTag]
	if traffic == nil {
		traffic = &adapter.RuntimeTrafficStats{Tag: outboundTag}
		m.runtimeTraffic[outboundTag] = traffic
	}
	traffic.UpdatedAt = now
	if download {
		traffic.DownloadBytes += bytes
		traffic.LastDownloadAt = now
		traffic.UploadOnlySamples = 0
		traffic.CleanSamples++
		cleanSamples = traffic.CleanSamples
	} else {
		traffic.UploadBytes += bytes
		traffic.LastUploadAt = now
		if bytes >= runtimeTrafficStallMinUploadBytes &&
			(traffic.LastDownloadAt.IsZero() || now.Sub(traffic.LastDownloadAt) >= runtimeTrafficStallNoDownloadWindow) {
			traffic.UploadOnlySamples++
			uploadOnlySamples = traffic.UploadOnlySamples
			shouldValidate = traffic.UploadOnlySamples >= runtimeTrafficStallEvidenceThreshold
		} else {
			uploadOnlySamples = traffic.UploadOnlySamples
		}
	}
	m.runtimeAccess.Unlock()

	if !download && shouldValidate {
		state.mu.Lock()
		state.history.DegradationPoints = clampHealthPoints(state.history.DegradationPoints + 12)
		state.history.RealUserPenalty = clampHealthPenalty(state.history.RealUserPenalty + 6)
		state.history.VolatilityPenalty = clampHealthPenalty(state.history.VolatilityPenalty + 2)
		state.invalid = true
		refreshHealthScore(outboundTag, &state.history, state.from_cache)
		history := state.history
		groupTags := append([]string(nil), state.groupTags...)
		state.mu.Unlock()
		m.history.StoreURLTestHistory(outboundTag, &history)
		m.emitGroupEvent(groupTags)
		m.logger.Warn("[SmartActiveTrafficHealth] tag=", outboundTag, " event=stalled_candidate direction=", direction,
			" upload_bytes_delta=", bytes, " download_bytes_delta=0 upload_only_samples=", uploadOnlySamples,
			" runtime_penalty=", history.RuntimePenalty, " real_user_penalty=", history.RealUserPenalty,
			" degradation=", history.DegradationPoints, " score=", history.HealthScore)
		m.maybeQueueRuntimeValidationProbe(outboundTag, "upload_without_recent_download")
		return
	}

	if !download {
		m.logger.Debug("[SmartActiveTrafficHealth] tag=", outboundTag, " event=traffic_sample direction=", direction,
			" upload_bytes_delta=", bytes, " download_bytes_delta=0 upload_only_samples=", uploadOnlySamples)
		return
	}

	state.mu.Lock()
	previousRealUserPenalty := state.history.RealUserPenalty
	previousDegradation := state.history.DegradationPoints
	state.history.RealUserPenalty = clampHealthPenalty(state.history.RealUserPenalty - 2)
	state.history.DegradationPoints = clampHealthPoints(state.history.DegradationPoints - 2)
	state.history.StabilityPoints = clampStability(state.history.StabilityPoints + 1)
	refreshHealthScore(outboundTag, &state.history, state.from_cache)
	history := state.history
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	if previousRealUserPenalty == history.RealUserPenalty && previousDegradation == history.DegradationPoints {
		m.logger.Debug("[RealUserHealth] tag=", outboundTag, " bytes=", bytes, " direction=", direction, " errors=0 penalty=", history.RealUserPenalty, " degradation=", history.DegradationPoints, " score=", history.HealthScore)
		m.logger.Debug("[SmartActiveTrafficHealth] tag=", outboundTag, " event=clean_download direction=", direction,
			" download_bytes_delta=", bytes, " clean_samples=", cleanSamples, " real_user_penalty=", history.RealUserPenalty,
			" degradation=", history.DegradationPoints, " score=", history.HealthScore)
		return
	}
	m.history.StoreURLTestHistory(outboundTag, &history)
	m.emitGroupEvent(groupTags)
	m.logger.Debug("[RealUserHealth] tag=", outboundTag, " bytes=", bytes, " direction=", direction, " errors=0 penalty=", history.RealUserPenalty, " degradation=", history.DegradationPoints, " score=", history.HealthScore)
	m.logger.Debug("[SmartActiveRecovery] tag=", outboundTag, " event=clean_download direction=", direction,
		" download_bytes_delta=", bytes, " clean_samples=", cleanSamples, " real_user_penalty=", history.RealUserPenalty,
		" degradation=", history.DegradationPoints, " score=", history.HealthScore)
}

func (m *OutboundMonitoring) maybeQueueRuntimeValidationProbe(outboundTag string, reason string) {
	if outboundTag == "" || m.ctx == nil || m.priorityQueue == nil {
		return
	}
	select {
	case <-m.ctx.Done():
		return
	default:
	}
	now := time.Now()
	m.runtimeAccess.Lock()
	if m.runtimeTraffic == nil {
		m.runtimeTraffic = make(map[string]*adapter.RuntimeTrafficStats)
	}
	m.pruneRuntimeTrafficLocked(now)
	traffic := m.runtimeTraffic[outboundTag]
	if traffic == nil {
		traffic = &adapter.RuntimeTrafficStats{Tag: outboundTag}
		m.runtimeTraffic[outboundTag] = traffic
	}
	traffic.UpdatedAt = now
	if !traffic.LastProbeAt.IsZero() && now.Sub(traffic.LastProbeAt) < runtimeTrafficValidationProbeCooldown {
		m.runtimeAccess.Unlock()
		m.logger.Debug("[SmartActiveProbe] tag=", outboundTag, " trigger=", reason, " decision=skip reason=probe_cooldown")
		return
	}
	traffic.LastProbeAt = now
	m.runtimeAccess.Unlock()
	if err := m.InvalidateTest(outboundTag); err != nil {
		m.logger.Debug("[SmartActiveProbe] tag=", outboundTag, " trigger=", reason, " decision=skip reason=", err)
		return
	}
	m.logger.Warn("[SmartActiveProbe] tag=", outboundTag, " trigger=", reason, " decision=queued validation=bounded_urltest")
}

func (m *OutboundMonitoring) pruneRuntimeTrafficLocked(now time.Time) {
	for tag, stats := range m.runtimeTraffic {
		if stats == nil || now.Sub(stats.UpdatedAt) > runtimeTrafficTTL {
			delete(m.runtimeTraffic, tag)
			continue
		}
		if _, ok := m.outbounds[tag]; !ok {
			delete(m.runtimeTraffic, tag)
		}
	}
}

func getRuntimeHistoryScore(state *outboundState) int {
	if state == nil {
		return 0
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.history.HealthScore
}

func (m *OutboundMonitoring) configureUDPProbe(options option.MonitoringOptions) {
	enabled := options.UDPProbeEnabled || parseBoolEnv("ZEON_UDP_PROBE_ENABLED")
	secretText := strings.TrimSpace(options.UDPProbeSecret)
	if secretText == "" {
		secretText = strings.TrimSpace(os.Getenv("ZEON_UDP_PROBE_SECRET"))
	}
	endpoint := strings.TrimSpace(options.UDPProbeEndpoint)
	if endpoint == "" {
		endpoint = defaultUDPProbe
	}

	probeOptions := urltest.DefaultUDPProbeOptions()
	if options.UDPProbeCount > 0 {
		probeOptions.Count = options.UDPProbeCount
	}
	if options.UDPProbeSize > 0 {
		probeOptions.Size = options.UDPProbeSize
	}
	if options.UDPProbeInterval > 0 {
		probeOptions.Interval = options.UDPProbeInterval.Build()
	}
	if options.UDPProbeTimeout > 0 {
		probeOptions.Timeout = options.UDPProbeTimeout.Build()
	}

	cooldown := defaultUDPCooldown
	if options.UDPProbeCooldown > 0 {
		cooldown = options.UDPProbeCooldown.Build()
	}
	topN := options.UDPProbeTopN
	if topN <= 0 {
		topN = defaultUDPProbeTopN
	}
	if topN > 5 {
		topN = 5
	}

	m.udpProbeEndpoint = endpoint
	m.udpProbeOptions = probeOptions
	m.udpProbeCooldown = cooldown
	m.udpProbeTopN = topN
	m.udpProbeQueue = make(chan udpProbeTask, 64)

	if !enabled {
		return
	}
	secret, err := urltest.ParseUDPProbeSecret(secretText)
	if err != nil {
		m.logger.Warn("[UDPProbe] disabled: ", err)
		return
	}
	m.udpProbeSecret = secret
	m.udpProbeEnabled = true
	m.logger.Info("[UDPProbe] enabled endpoint=", endpoint, " count=", probeOptions.Count, " size=", probeOptions.Size, " cooldown=", cooldown, " top_n=", topN)
}

func parseBoolEnv(key string) bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	return value == "1" || value == "true" || value == "yes" || value == "on"
}

func (m *OutboundMonitoring) scheduleUDPProbesFromOutcomes(outcomes []testOutcome) {
	if !m.udpProbeEnabled || len(outcomes) == 0 {
		return
	}
	candidates := make([]testOutcome, 0, len(outcomes))
	for _, outcome := range outcomes {
		if outcome.err != nil || !outcome.history.Success {
			continue
		}
		state := m.getState(outcome.outboundTag)
		if state == nil || !m.isUDPProbeCandidate(state.outbound) {
			continue
		}
		state.mu.Lock()
		currentGeneration := state.history.CheckGeneration
		currentReady := state.history.CombinedReady
		state.mu.Unlock()
		if currentGeneration != outcome.cycleID || !currentReady {
			m.logger.Warn("[OutboundCheckIgnored] tag=", outcome.outboundTag, " result_generation=", outcome.cycleID, " current_generation=", currentGeneration, " stage=udp_schedule reason=stale_generation")
			continue
		}
		candidates = append(candidates, outcome)
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		left := candidates[i].history.HealthScore
		right := candidates[j].history.HealthScore
		if left != right {
			return left > right
		}
		return candidates[i].history.Delay < candidates[j].history.Delay
	})
	if len(candidates) > m.udpProbeTopN {
		candidates = candidates[:m.udpProbeTopN]
	}
	for _, candidate := range candidates {
		m.enqueueUDPProbe(candidate.outboundTag, candidate.cycleID)
	}
}

func (m *OutboundMonitoring) isUDPProbeCandidate(outbound adapter.Outbound) bool {
	if outbound == nil {
		return false
	}
	switch outbound.Type() {
	case C.TypeDirect, C.TypeBlock, C.TypeDNS:
		return false
	}
	return common.Contains(outbound.Network(), N.NetworkUDP)
}

func (m *OutboundMonitoring) enqueueUDPProbe(tag string, generation uint64) {
	state := m.getState(tag)
	if state == nil {
		return
	}
	now := time.Now()
	state.mu.Lock()
	if state.history.CheckGeneration != generation {
		currentGeneration := state.history.CheckGeneration
		state.mu.Unlock()
		m.logger.Warn("[OutboundCheckIgnored] tag=", tag, " result_generation=", generation, " current_generation=", currentGeneration, " stage=udp_enqueue reason=stale_generation")
		return
	}
	if state.udpProbeRunning || (!state.udpProbeLast.IsZero() && now.Sub(state.udpProbeLast) < m.udpProbeCooldown) {
		state.mu.Unlock()
		return
	}
	state.udpProbeRunning = true
	state.mu.Unlock()

	m.udpProbeAccess.Lock()
	if m.udpProbeQueued[tag] {
		m.udpProbeAccess.Unlock()
		state.mu.Lock()
		state.udpProbeRunning = false
		state.mu.Unlock()
		return
	}
	m.udpProbeQueued[tag] = true
	m.udpProbeAccess.Unlock()

	select {
	case m.udpProbeQueue <- udpProbeTask{tag: tag, generation: generation}:
		m.logger.Info("[OutboundCheckStage] tag=", tag, " generation=", generation, " stage=udp state=checking")
	case <-m.ctx.Done():
		m.clearUDPProbeQueued(tag)
	default:
		m.logger.Warn("[UDPProbe] queue full tag=", tag)
		m.clearUDPProbeQueued(tag)
	}
}

func (m *OutboundMonitoring) clearUDPProbeQueued(tag string) {
	m.udpProbeAccess.Lock()
	delete(m.udpProbeQueued, tag)
	m.udpProbeAccess.Unlock()
	if state := m.getState(tag); state != nil {
		state.mu.Lock()
		state.udpProbeRunning = false
		state.mu.Unlock()
	}
}

func (m *OutboundMonitoring) udpProbeLoop() {
	defer m.udpProbeWG.Done()
	for {
		select {
		case <-m.ctx.Done():
			return
		case task := <-m.udpProbeQueue:
			m.udpProbeAccess.Lock()
			delete(m.udpProbeQueued, task.tag)
			m.udpProbeAccess.Unlock()
			m.runUDPProbe(task)
		}
	}
}

func (m *OutboundMonitoring) runUDPProbe(task udpProbeTask) {
	tag := task.tag
	state := m.getState(tag)
	if state == nil {
		return
	}
	state.mu.Lock()
	if state.history.CheckGeneration != task.generation {
		currentGeneration := state.history.CheckGeneration
		state.udpProbeRunning = false
		state.mu.Unlock()
		m.logger.Warn("[OutboundCheckIgnored] tag=", tag, " result_generation=", task.generation, " current_generation=", currentGeneration, " stage=udp reason=stale_generation")
		return
	}
	outbound := state.outbound
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()

	totalTimeout := time.Duration(m.udpProbeOptions.Count)*(m.udpProbeOptions.Timeout+m.udpProbeOptions.Interval) + time.Second
	ctx, cancel := context.WithTimeout(m.ctx, totalTimeout)
	defer cancel()

	result := urltest.RunUDPProbeThroughOutbound(ctx, outbound, m.udpProbeEndpoint, m.udpProbeSecret, m.udpProbeOptions)

	state.historyPublish.Lock()
	state.mu.Lock()
	if state.history.CheckGeneration != task.generation {
		currentGeneration := state.history.CheckGeneration
		state.udpProbeRunning = false
		state.mu.Unlock()
		state.historyPublish.Unlock()
		m.logger.Warn("[OutboundCheckIgnored] tag=", tag, " result_generation=", task.generation, " current_generation=", currentGeneration, " stage=udp reason=stale_generation")
		return
	}
	state.udpProbeRunning = false
	state.udpProbeLast = result.UpdatedAt
	state.history.UDPProbeAvailable = result.Available
	state.history.UDPPenalty = result.Penalty
	state.history.UDPLoss = result.Loss
	state.history.UDPJitterMs = result.JitterMs
	state.history.UDPReady = true
	refreshHealthScore(tag, &state.history, state.from_cache)
	state.advanceRankingRevision()
	history := state.history
	state.mu.Unlock()

	m.history.StoreURLTestHistory(tag, &history)
	state.historyPublish.Unlock()
	m.cacheDirty.Store(true)
	m.emitGroupEvent(groupTags)

	if result.Available {
		m.logger.Warn("[UDPProbe] tag=", tag, " sent=", result.Sent, " recv=", result.Received, " loss=", fmt.Sprintf("%.1f", result.Loss), " jitter=", result.JitterMs, " penalty=", result.Penalty, " score=", history.HealthScore)
	} else {
		m.logger.Warn("[UDPProbe] tag=", tag, " unavailable reason=", result.ErrorType, " text=", result.ErrorText)
	}
	m.logger.Info("[OutboundCheckStage] tag=", tag, " generation=", task.generation, " stage=udp state=completed available=", result.Available, " penalty=", result.Penalty)
}

func (m *OutboundMonitoring) SubscribeGroup(groupTag string) (observer <-chan GroupEvent, err error) {

	if g, ok := m.groups[groupTag]; ok {
		return g.observer.Subscribe(1), nil
	}
	return nil, E.New("group not found ", groupTag)
}
func (m *OutboundMonitoring) UnsubscribeGroup(groupTag string, observer <-chan GroupEvent) (err error) {
	if g, ok := m.groups[groupTag]; ok {
		g.observer.Unsubscribe(observer)
		return nil
	}
	return E.New("group not found ", groupTag)
}

func (m *OutboundMonitoring) Close() error {
	m.closerOnce.Do(func() {
		m.started.Store(false)
		m.stopTimerWorkers()

		// close(m.priorityQueue)
		// close(m.normalQueue)
		for _, g := range m.groups {
			if g.observer != nil {
				g.observer.Close()
			}
		}
		m.cancel()
		m.workerWG.Wait()
		m.udpProbeWG.Wait()
		m.schedulerWG.Wait()

	})
	return nil
}

func (m *OutboundMonitoring) scheduleLoop(ticker *time.Ticker) {
	m.logger.Info("outbound monitoring schedule loop started")
	m.startCycleOnce()
	for {
		select {
		case <-m.ctx.Done():
			m.schedulerWG.Done()
			return
		case <-ticker.C:
			if time.Since(m.lastActive.Load()) > m.idleTimeout {
				m.schedulerWG.Done()
				m.stopTimerWorkers()
				return
			}
			m.startCycleOnce()
		}
	}
}

func (m *OutboundMonitoring) workerLoop() {

	defer m.workerWG.Done()
	for {

		select {
		case <-m.ctx.Done():
			return
		case task := <-m.priorityQueue:
			m.executeTask(task) //for prioritising tasks, we execute them immediately
		default:
			select {
			case <-m.ctx.Done():
				return
			case task := <-m.priorityQueue:
				m.executeTask(task)
			case task := <-m.normalQueue:
				m.executeTask(task)
			}
		}
	}
}

func (m *OutboundMonitoring) executeTask(task *testTask) {
	select {
	case <-m.ctx.Done():
		return
	default:
	}

	state := m.outbounds[task.outboundTag]
	if state == nil {
		m.finishTaskWithError(task, errors.New("outbound not registered"))
		return
	}

	state.mu.Lock()
	state.testing = true
	state.testingCycle = task.cycleID
	state.mu.Unlock()
	if task.manual {
		m.logger.Info("[ManualRefreshTarget] tag=", task.outboundTag, " status=started")
	}
	defer func() {
		state.mu.Lock()
		if state.testingCycle == task.cycleID {
			state.testing = false
			state.testingCycle = 0
		}
		state.mu.Unlock()
	}()
	state.mu.Lock()
	state.mu.Unlock()

	if !state.outbound.IsReady() {
		m.logger.Info("outbound ", task.outboundTag, " is not ready, marking URL test failed")
		m.finishTaskWithError(task, errors.New("outbound is not ready"))
		return
	}
	// Some protocol dialers do not reliably return when their context expires.
	// Without a hard boundary, enough such outbounds can occupy every worker and
	// leave the rest of the server list in the checking state forever.
	targetTimeout := m.urlTestTimeout
	if targetTimeout <= 0 {
		targetTimeout = defaultURLTestTimeout
	}
	history, err, timedOut := runURLTestWithHardTimeout(m.ctx, targetTimeout, func(ctx context.Context) (adapter.URLTestHistory, error) {
		return m.tester(ctx, task.outboundTag)
	})
	if timedOut {
		m.logger.Warn("[OutboundCheckStage] tag=", task.outboundTag, " generation=", task.cycleID, " stage=ping state=timeout duration=", targetTimeout)
		m.finishTaskWithError(task, err)
		return
	}

	outcome := testOutcome{
		outboundTag:    task.outboundTag,
		history:        history,
		err:            err,
		cycleID:        task.cycleID,
		priority:       task.priority,
		fullGeneration: task.fullGeneration,
		deferNotify:    task.deferNotify,
	}
	m.applyResult(outcome)
	if task.resultCh != nil {
		select {
		case task.resultCh <- outcome:
		case <-m.ctx.Done():
		default:
		}
	}

}

func (m *OutboundMonitoring) finishTaskWithError(task *testTask, err error) {
	outcome := m.newTaskErrorOutcome(task.outboundTag, task.cycleID, task.priority, task.fullGeneration, err)
	outcome.deferNotify = task.deferNotify
	m.applyResult(outcome)
	if task.resultCh != nil {
		select {
		case task.resultCh <- outcome:
		case <-m.ctx.Done():
		default:
		}
	}
}

func (m *OutboundMonitoring) newTaskErrorOutcome(outboundTag string, cycleID uint64, priority bool, fullGeneration bool, err error) testOutcome {
	if err == nil {
		err = errors.New("URL test failed")
	}
	errorType, errorText := urltest.ClassifyProbeError(err)
	if errorType == "" || errorType == urltest.ErrorTypeNone {
		errorType = urltest.ErrorTypeUnknown
	}
	history := adapter.URLTestHistory{
		Time:           time.Now(),
		Delay:          TimeoutDelay,
		Success:        false,
		ErrorType:      errorType,
		ErrorText:      errorText,
		RuntimePenalty: m.runtimePenaltyForTag(outboundTag),
		URLTestStatus:  urltest.StatusFailed,
	}
	refreshHealthScore(outboundTag, &history, false)
	return testOutcome{
		outboundTag:    outboundTag,
		history:        history,
		err:            err,
		cycleID:        cycleID,
		priority:       priority,
		fullGeneration: fullGeneration,
	}
}

func (m *OutboundMonitoring) tester(parent context.Context, tag string) (adapter.URLTestHistory, error) {
	out, ok := m.outbounds[tag]
	if !ok {
		return adapter.URLTestHistory{Delay: 0}, errors.New("outbound not registered")
	}

	out.mu.Lock()
	previousIPInfo := out.history.IpInfo
	fromCache := out.from_cache
	testedOutbound := out.outbound
	out.mu.Unlock()

	idx := m.currentLinkIndex.Load()

	ctx, cancel := context.WithTimeout(parent, m.urlTestTimeout)
	defer cancel()

	delay, err := urltest.URLTest(ctx, m.urls[idx], testedOutbound)
	if err == nil && delay == 0 {
		err = errors.New("URL test returned empty delay")
	}

	errorType, errorText := urltest.ClassifyProbeError(err)
	runtimePenalty := m.runtimePenaltyForTag(tag)
	his := adapter.URLTestHistory{
		Time:           time.Now(),
		Delay:          delay,
		Success:        err == nil && delay > 0 && delay < TimeoutDelay,
		ErrorType:      errorType,
		ErrorText:      errorText,
		RuntimePenalty: runtimePenalty,
		URLTestStatus:  urltest.ResultStatus(err == nil && delay > 0 && delay < TimeoutDelay),
	}
	if err != nil || delay == 0 || delay >= TimeoutDelay {
		his.Delay = TimeoutDelay
		his.Success = false
		if his.ErrorType == "" || his.ErrorType == urltest.ErrorTypeNone {
			his.ErrorType = urltest.ErrorTypeTimeout
		}
		refreshHealthScore(tag, &his, false)
		m.logger.Warn("outbound ", tag, " URL test failed: ", err)
		m.logger.Warn("[HealthScore] tag=", tag, " delay=", his.Delay, " success=", his.Success, " error=", his.ErrorType, " policy=", his.PolicyPenalty, " score=", his.HealthScore)
		return his, err
	}
	select {
	case <-parent.Done():
		return his, parent.Err()
	default:
	}
	if previousIPInfo == nil || fromCache {

		ctx, cancel2 := context.WithTimeout(parent, m.urlTestTimeout)
		defer cancel2()

		newip, t, err := ipinfo.GetIpInfo(m.logger, ctx, testedOutbound)
		if err == nil {
			his.IpInfo = mergeIpInfo(previousIPInfo, newip)
			if t < his.Delay {
				his.Delay = t
			}
		}
	}
	refreshHealthScore(tag, &his, false)
	m.logger.Warn("[HealthScore] tag=", tag, " delay=", his.Delay, " success=", his.Success, " error=", his.ErrorType, " policy=", his.PolicyPenalty, " score=", his.HealthScore)
	if his.IpInfo != nil {
		m.logger.Info("outbound ", tag, " IP ", fmt.Sprint(his.IpInfo), " (", his.Delay, "ms): ", err)
	} else {
		m.logger.Info("outbound ", tag, " , IP: -          (", his.Delay, "ms)")
	}
	return his, nil
}

func (m *OutboundMonitoring) startCycleOnce() bool {
	if !m.cycleRunning.CompareAndSwap(false, true) {
		return false
	}
	go func() {
		for {
			m.logger.Info("starting regular outbound monitoring cycle")
			m.runCycle()
			m.cycleRunning.Store(false)
			// A full-cycle request may arrive while another cycle is finishing.
			// Re-acquire ownership here so that request cannot be lost in the
			// transition between runCycle and cycleRunning=false.
			if !m.fullCycleRequested.Load() || !m.cycleRunning.CompareAndSwap(false, true) {
				return
			}
		}
	}()
	return true
}

// RequestFullCycle makes the next monitoring cycle include every leaf
// outbound, even when a recent cached result would normally skip it.
func (m *OutboundMonitoring) RequestFullCycle() {
	m.fullCycleRequested.Store(true)
	m.startCycleOnce()
}

func (m *OutboundMonitoring) runCycle() {
	cycleID := atomic.AddUint64(&m.cycleSeq, 1)
	forceAll := m.fullCycleRequested.Swap(false)
	tags := m.collectCycleTargets(forceAll)

	if len(tags) == 0 {
		return
	}
	m.beginCheckGeneration(cycleID, tags, "background_refresh")
	defer func() {
		if m.cacheDirty.Swap(false) {
			m.saveHistory()
		}
	}()

	for idx, _ := range m.urls {
		outcomes := m.runStage(cycleID, tags)
		success := 0
		for _, result := range outcomes {
			if result.err == nil {
				success++
			}
		}
		if success > 0 || idx == len(m.urls)-1 {
			m.logCheckGenerationCompleted(cycleID, tags, "background_refresh")
			// Direct batch events are intentionally non-blocking. Publish one
			// debounced final snapshot as a delivery backstop if a busy subscriber
			// dropped the last completed-batch event.
			m.emitGroupEventsForOutbounds(tags)
			return
		}
		m.currentLinkIndex.Store((m.currentLinkIndex.Load() + 1) % uint32(len(m.urls)))
		// A retry against another URL is a new complete cohort. Reusing the
		// generation would make its successful ping indistinguishable from a
		// one-server priority retest and could let partial evidence replace the
		// last coherent Smart Active ranking.
		cycleID = atomic.AddUint64(&m.cycleSeq, 1)
		m.beginCheckGeneration(cycleID, tags, "background_retry")
	}
}

func (m *OutboundMonitoring) runStage(cycleID uint64, tags []string) []testOutcome {
	batchSize := m.workersCount
	if batchSize <= 0 {
		batchSize = defaultWorkerCount
	}
	results := make([]testOutcome, 0, len(tags))
	for start, batchNumber := 0, 1; start < len(tags); start, batchNumber = start+batchSize, batchNumber+1 {
		end := min(start+batchSize, len(tags))
		batchTags := tags[start:end]
		resultCh := make(chan testOutcome, len(batchTags))
		expected := 0
		for _, tag := range batchTags {
			if m.getState(tag) == nil {
				continue
			}
			task := &testTask{
				outboundTag:    tag,
				cycleID:        cycleID,
				priority:       false,
				fullGeneration: true,
				resultCh:       resultCh,
				deferNotify:    true,
			}
			if m.enqueueTask(task) {
				expected++
			}
		}

		batchResults := make([]testOutcome, 0, expected)
		for expected > 0 {
			select {
			case <-m.ctx.Done():
				return results
			case result := <-resultCh:
				batchResults = append(batchResults, result)
				expected--
			}
		}
		results = append(results, batchResults...)
		m.publishCompletedBatch(cycleID, batchNumber, batchTags)
	}
	m.scheduleUDPProbesFromOutcomes(results)
	return results
}

func (m *OutboundMonitoring) enqueueTask(task *testTask) bool {

	select {
	case <-m.ctx.Done():
		return false
	default:
	}
	state, ok := m.outbounds[task.outboundTag]
	if !ok {
		return false
	}
	// A newer generation for another outbound must not cancel this task. The
	// per-outbound check below still prevents an old task from overwriting a
	// newer result for the same server.
	state.mu.Lock()
	if state.history.CheckGeneration > 0 && state.history.CheckGeneration != task.cycleID {
		currentGeneration := state.history.CheckGeneration
		state.mu.Unlock()
		m.logger.Warn("[OutboundCheckIgnored] tag=", task.outboundTag, " result_generation=", task.cycleID, " current_generation=", currentGeneration, " stage=enqueue reason=stale_generation")
		return false
	}
	if task.priority {
		if state.priorityQueued {
			state.mu.Unlock()
			return false
		}
		state.priorityQueued = true
	} else {
		if state.enqueuedCycle == task.cycleID {
			state.mu.Unlock()
			return false
		}
		state.enqueuedCycle = task.cycleID
		state.queued = true
	}
	previousStatus := state.history.URLTestStatus
	previousTime := state.history.Time
	previousGeneration := state.history.CheckGeneration
	preserveTerminalEvidence := state.history.URLTestStatus == urltest.StatusFailed ||
		(!task.fullGeneration && state.lastResultSourceKnown && state.lastResultFromFullGeneration)
	if !preserveTerminalEvidence {
		state.history.URLTestStatus = urltest.StatusChecking
		state.history.Time = time.Now()
		state.history.CheckGeneration = task.cycleID
	}
	groupTags := append([]string(nil), state.groupTags...)

	enqueued := false
	if task.priority {
		select {
		case m.priorityQueue <- task:
			enqueued = true
		default:
		}
	} else {
		select {
		case m.normalQueue <- task:
			enqueued = true
		default:
		}
	}

	if !enqueued {
		state.history.URLTestStatus = previousStatus
		state.history.Time = previousTime
		state.history.CheckGeneration = previousGeneration
		if task.priority {
			state.priorityQueued = false
		} else {
			state.queued = false
			state.enqueuedCycle = 0
		}
		state.mu.Unlock()
		return false
	}
	state.mu.Unlock()
	if !task.deferNotify {
		m.emitGroupEvent(groupTags)
	}
	m.logger.Info("[OutboundCheckStage] tag=", task.outboundTag, " generation=", task.cycleID, " stage=ping state=checking")
	return true
}

func (m *OutboundMonitoring) applyResult(outcome testOutcome) *adapter.URLTestHistory {
	if m.ctx != nil {
		select {
		case <-m.ctx.Done():
			return nil
		default:
		}
	}
	state, ok := m.outbounds[outcome.outboundTag]
	if !ok {
		return nil
	}
	state.historyPublish.Lock()
	state.mu.Lock()

	if state.history.CheckGeneration > 0 && outcome.cycleID != state.history.CheckGeneration {
		m.logger.Warn("[OutboundCheckIgnored] tag=", outcome.outboundTag, " result_generation=", outcome.cycleID, " current_generation=", state.history.CheckGeneration, " stage=ping reason=stale_generation")
		state.mu.Unlock()
		state.historyPublish.Unlock()
		return nil
	}
	if !outcome.fullGeneration && outcome.history.Success &&
		(state.lastResultFromFullGeneration || state.history.URLTestStatus == urltest.StatusFailed) {
		// A late targeted success must not replace a normal full result (or erase
		// a targeted failure) from the same generation. Only a new full-cohort
		// result may improve that terminal ranking evidence.
		if outcome.priority {
			state.priorityQueued = false
		} else {
			state.queued = false
			state.enqueuedCycle = 0
		}
		historySnapshot := state.history
		state.mu.Unlock()
		state.historyPublish.Unlock()
		m.logger.Info("[OutboundCheckIgnored] tag=", outcome.outboundTag, " generation=", outcome.cycleID, " stage=ping reason=partial_success_after_terminal_full")
		return &historySnapshot
	}
	outcome.history = normalizeTerminalHistory(outcome.outboundTag, outcome.history, outcome.err)
	state.queued = false
	state.priorityQueued = false
	state.enqueuedCycle = 0
	state.invalid = outcome.err != nil
	state.lastURL = outcome.url
	if (outcome.history.Delay != state.history.Delay) || state.history.IpInfo == nil || (outcome.history.IpInfo != nil) || (outcome.history.HealthScore != state.history.HealthScore) || (outcome.history.ErrorType != state.history.ErrorType) {
		m.cacheDirty.Store(true)
	}
	previousHistory := state.history
	udpAvailable := state.history.UDPProbeAvailable
	udpPenalty := state.history.UDPPenalty
	udpLoss := state.history.UDPLoss
	udpJitter := state.history.UDPJitterMs
	state.history.Delay = outcome.history.Delay
	state.history.Time = outcome.history.Time
	state.history.IsFromCache = false
	state.history.Success = outcome.history.Success
	state.history.ErrorType = outcome.history.ErrorType
	state.history.ErrorText = outcome.history.ErrorText
	state.history.URLTestStatus = urltest.ResultStatus(outcome.history.Success)
	state.history.HealthScore = outcome.history.HealthScore
	state.history.RuntimePenalty = outcome.history.RuntimePenalty
	state.history.FreshnessPenalty = outcome.history.FreshnessPenalty
	state.history.PolicyPenalty = outcome.history.PolicyPenalty
	state.history.CheckGeneration = outcome.cycleID
	state.history.PingReady = true
	state.history.QualityReady = true
	state.history.SpeedReady = true
	state.history.CombinedReady = true
	state.lastResultFromFullGeneration = outcome.fullGeneration
	state.lastResultSourceKnown = true
	applyProbeEvidenceWithRecovery(outcome.outboundTag, &state.history, previousHistory, outcome.fullGeneration)
	if state.udpProbeLast.IsZero() || time.Since(state.udpProbeLast) > m.udpProbeCooldown*3 {
		state.history.UDPProbeAvailable = false
		state.history.UDPPenalty = 0
		state.history.UDPLoss = 0
		state.history.UDPJitterMs = 0
		state.history.UDPReady = false
	} else {
		state.history.UDPProbeAvailable = udpAvailable
		state.history.UDPPenalty = udpPenalty
		state.history.UDPLoss = udpLoss
		state.history.UDPJitterMs = udpJitter
		state.history.UDPReady = true
		refreshHealthScore(outcome.outboundTag, &state.history, false)
	}
	state.from_cache = false
	if outcome.history.IpInfo != nil {
		state.history.IpInfo = outcome.history.IpInfo
	}
	state.advanceRankingRevision()
	historySnapshot := state.history
	groupTags := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	m.history.StoreURLTestHistory(outcome.outboundTag, &historySnapshot)
	state.historyPublish.Unlock()

	if !outcome.deferNotify {
		m.emitGroupEvent(groupTags)
	}
	stageState := "completed"
	if !outcome.history.Success {
		stageState = "failed"
	}
	m.logger.Info("[OutboundCheckStage] tag=", outcome.outboundTag, " generation=", outcome.cycleID, " stage=ping state=", stageState, " delay=", historySnapshot.Delay)
	m.logger.Info("[OutboundCheckStage] tag=", outcome.outboundTag, " generation=", outcome.cycleID, " stage=quality state=", stageState, " score=", historySnapshot.HealthScore)
	m.logger.Info("[SmartActiveFreshness] tag=", outcome.outboundTag, " generation=", outcome.cycleID,
		" ping_ready=", historySnapshot.PingReady, " quality_ready=", historySnapshot.QualityReady,
		" speed_ready=", historySnapshot.SpeedReady, " udp_ready=", historySnapshot.UDPReady,
		" ranking_eligible=", historySnapshot.Success && historySnapshot.CombinedReady)
	m.logger.Info("[OutboundResultCommit] tag=", outcome.outboundTag,
		" generation=", outcome.cycleID, " source=", monitoringResultSource(outcome),
		" old_success=", previousHistory.Success, " new_success=", historySnapshot.Success,
		" old_delay=", previousHistory.Delay, " new_delay=", historySnapshot.Delay,
		" old_score=", previousHistory.HealthScore, " new_score=", historySnapshot.HealthScore,
		" old_url_status=", previousHistory.URLTestStatus, " new_url_status=", historySnapshot.URLTestStatus,
		" old_generation=", previousHistory.CheckGeneration, " new_generation=", historySnapshot.CheckGeneration,
		" result_time=", historySnapshot.Time, " combined_ready=", historySnapshot.CombinedReady)
	return &historySnapshot
}

func normalizeTerminalHistory(tag string, history adapter.URLTestHistory, resultErr error) adapter.URLTestHistory {
	statusSuccess := history.URLTestStatus == "" || history.URLTestStatus == urltest.StatusSuccess
	errorFree := history.ErrorType == "" || history.ErrorType == urltest.ErrorTypeNone
	validDelay := history.Delay > 0 && history.Delay < TimeoutDelay
	if resultErr == nil && history.Success && statusSuccess && errorFree && validDelay {
		history.Success = true
		history.ErrorType = urltest.ErrorTypeNone
		history.ErrorText = ""
		history.URLTestStatus = urltest.StatusSuccess
		return history
	}

	history.Success = false
	history.URLTestStatus = urltest.StatusFailed
	history.Delay = TimeoutDelay
	if history.ErrorType == "" || history.ErrorType == urltest.ErrorTypeNone {
		errorType, errorText := urltest.ClassifyProbeError(resultErr)
		if errorType == "" || errorType == urltest.ErrorTypeNone {
			errorType = urltest.ErrorTypeUnknown
		}
		history.ErrorType = errorType
		if history.ErrorText == "" {
			history.ErrorText = errorText
		}
	}
	refreshHealthScore(tag, &history, false)
	return history
}

func monitoringResultSource(outcome testOutcome) string {
	if outcome.fullGeneration {
		return "full_generation"
	}
	return "targeted_retest"
}

func mergeIpInfo(old, new *ipinfo.IpInfo) *ipinfo.IpInfo {
	if old == nil {
		return new
	}
	if new == nil {
		return old
	}
	new2 := *new // copy
	if new2.CountryCode == "" {
		new2.CountryCode = old.CountryCode
	}
	if new2.Org == "" {
		new2.Org = old.Org
	}
	return &new2
}

func refreshHealthScore(tag string, history *adapter.URLTestHistory, isFromCache bool) {
	if history == nil {
		return
	}
	countryCode := ""
	if history.IpInfo != nil {
		countryCode = history.IpInfo.CountryCode
	}
	history.FreshnessPenalty = urltest.CalculateFreshnessPenalty(isFromCache, history.Time)
	history.PolicyPenalty = urltest.CalculatePolicyPenalty(tag, countryCode)
	history.HealthScore = urltest.CalculateHealthScoreWithEvidence(
		history.Delay,
		history.Success,
		history.ErrorType,
		isFromCache,
		history.Time,
		history.RuntimePenalty,
		history.RealUserPenalty,
		history.VolatilityPenalty,
		history.UDPPenalty,
		history.PolicyPenalty,
	)
}

func applyProbeEvidence(tag string, history *adapter.URLTestHistory, previous adapter.URLTestHistory) {
	applyProbeEvidenceWithRecovery(tag, history, previous, true)
}

func applyProbeEvidenceWithRecovery(tag string, history *adapter.URLTestHistory, previous adapter.URLTestHistory, allowRealUserRecovery bool) {
	if history == nil {
		return
	}
	// Preserve the accumulated runtime evidence across a new probe result.
	history.RealUserPenalty = previous.RealUserPenalty
	history.VolatilityPenalty = previous.VolatilityPenalty
	history.StabilityPoints = previous.StabilityPoints
	history.DegradationPoints = previous.DegradationPoints
	if !history.Success {
		history.DegradationPoints = clampHealthPoints(history.DegradationPoints + degradationForError(history.ErrorType))
		history.StabilityPoints = clampStability(history.StabilityPoints - stabilityLossForError(history.ErrorType))
		history.VolatilityPenalty = clampHealthPenalty(history.VolatilityPenalty + 4)
		refreshHealthScore(tag, history, history.IsFromCache)
		return
	}

	history.DegradationPoints = clampHealthPoints(history.DegradationPoints - 6)
	history.VolatilityPenalty = clampHealthPenalty(history.VolatilityPenalty - 2)
	// An inactive server cannot earn runtime-success evidence because it carries
	// no user traffic. Let fresh successful full probes decay the accumulated
	// real-user penalty slowly, using the same small step as one runtime success,
	// so a recovered route is not quarantined forever. Failures never forgive it.
	if allowRealUserRecovery {
		history.RealUserPenalty = clampHealthPenalty(history.RealUserPenalty - 2)
	}
	if previous.Success && previous.Delay > 0 && previous.Delay < TimeoutDelay {
		delta := absInt(int(history.Delay) - int(previous.Delay))
		stableLimit := max(25, int(previous.Delay)/3)
		if delta <= stableLimit {
			history.StabilityPoints = clampStability(history.StabilityPoints + 6)
		} else {
			history.StabilityPoints = clampStability(history.StabilityPoints - 3)
			history.VolatilityPenalty = clampHealthPenalty(history.VolatilityPenalty + min(8, delta/100+2))
		}
	} else {
		history.StabilityPoints = clampStability(history.StabilityPoints + 4)
	}
	refreshHealthScore(tag, history, history.IsFromCache)
}

func degradationForError(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 5
	case urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return 10
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline:
		return 16
	case urltest.ErrorTypeRefused, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve, urltest.ErrorTypeQUICTimeout:
		return 28
	default:
		return 10
	}
}

func realUserPenaltyForError(errorType string) int {
	if urltest.IsCriticalProbeError(errorType) {
		return 12
	}
	if errorType == urltest.ErrorTypeEOF {
		return 3
	}
	return 6
}

func stabilityLossForError(errorType string) int {
	if urltest.IsCriticalProbeError(errorType) {
		return 18
	}
	return 8
}

func runtimeDegradationForError(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 5
	case urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return 14
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline:
		return 24
	case urltest.ErrorTypeRefused, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeQUICTimeout:
		return 38
	case urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve:
		return 55
	default:
		return degradationForError(errorType)
	}
}

func runtimeRealUserPenaltyForError(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 2
	case urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return 5
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeRefused, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeQUICTimeout:
		return 8
	case urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve:
		return 12
	default:
		return realUserPenaltyForError(errorType)
	}
}

func runtimeStabilityLossForError(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 5
	case urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return 10
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeRefused, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeQUICTimeout:
		return 16
	case urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve:
		return 22
	default:
		return stabilityLossForError(errorType)
	}
}

func updateRuntimeBurst(stats *adapter.RuntimePenaltyStats, errorType string, now time.Time) int {
	if stats.WindowStartedAt.IsZero() || now.Sub(stats.WindowStartedAt) > runtimeBurstWindow {
		stats.WindowStartedAt = now
		stats.BurstScore = 0
	}
	stats.BurstScore += runtimeBurstWeight(errorType)
	return stats.BurstScore
}

func runtimeBurstWeight(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 0
	case urltest.ErrorTypeReset, urltest.ErrorTypeBrokenPipe:
		return 1
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeRefused, urltest.ErrorTypeDNSTimeout, urltest.ErrorTypeQUICTimeout:
		return 2
	case urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve:
		return 3
	default:
		return 1
	}
}

func runtimeBurstDegradationBoost(burstScore int) int {
	switch {
	case burstScore >= 6:
		return 18
	case burstScore >= 4:
		return 12
	case burstScore >= 3:
		return 6
	default:
		return 0
	}
}

func runtimeBurstRealUserBoost(burstScore int) int {
	switch {
	case burstScore >= 6:
		return 6
	case burstScore >= 4:
		return 4
	case burstScore >= 3:
		return 2
	default:
		return 0
	}
}

func clampHealthPoints(value int) int  { return min(100, max(0, value)) }
func clampHealthPenalty(value int) int { return min(30, max(0, value)) }
func clampStability(value int) int     { return min(100, max(0, value)) }
func absInt(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func preferHistory(candidate, current *adapter.URLTestHistory) bool {
	if current == nil {
		return true
	}
	if candidate == nil {
		return false
	}
	candidateScore := candidate.HealthScore
	currentScore := current.HealthScore
	if candidateScore > 0 || currentScore > 0 {
		if candidate.Success != current.Success {
			return candidate.Success
		}
		if candidateScore != currentScore {
			return candidateScore > currentScore
		}
	}
	return candidate.Delay < current.Delay
}

func (m *OutboundMonitoring) applyDynamicHealth(tag string, his *adapter.URLTestHistory) {
	if his == nil {
		return
	}
	if his.CheckGeneration > 0 && !his.CombinedReady {
		his.Delay = 0
		his.Success = false
		his.ErrorType = ""
		his.ErrorText = ""
		his.HealthScore = 0
		his.UDPProbeAvailable = false
		his.UDPPenalty = 0
		his.UDPLoss = 0
		his.UDPJitterMs = 0
		return
	}
	if his.Delay > 0 && his.Delay < TimeoutDelay && his.ErrorType == "" {
		his.Success = true
		his.ErrorType = urltest.ErrorTypeNone
	}
	if his.ErrorType == "" {
		his.ErrorType = urltest.ErrorTypeUnknown
	}
	his.RuntimePenalty = m.runtimePenaltyForTag(tag)
	refreshHealthScore(tag, his, his.IsFromCache)
}

func inferURLTestStatus(history *adapter.URLTestHistory) string {
	if history == nil || (history.Time.IsZero() && history.Delay == 0 && history.ErrorType == "") {
		return urltest.StatusNotTested
	}
	if history.Success && history.Delay > 0 && history.Delay < TimeoutDelay &&
		(history.ErrorType == "" || history.ErrorType == urltest.ErrorTypeNone) {
		return urltest.StatusSuccess
	}
	return urltest.StatusFailed
}

func (m *OutboundMonitoring) runtimePenaltyForTag(tag string) int {
	m.runtimeAccess.Lock()
	defer m.runtimeAccess.Unlock()
	stats := m.runtimeStats[tag]
	if stats == nil {
		return 0
	}
	if time.Since(stats.UpdatedAt) > runtimePenaltyTTL {
		delete(m.runtimeStats, tag)
		return 0
	}
	return stats.Penalty
}

func incrementRuntimeStats(stats *adapter.RuntimePenaltyStats, errorType string) {
	switch errorType {
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline:
		stats.TimeoutCount++
	case urltest.ErrorTypeReset:
		stats.ResetCount++
	case urltest.ErrorTypeRefused:
		stats.RefusedCount++
	case urltest.ErrorTypeEOF:
		stats.EOFCount++
	case urltest.ErrorTypeBrokenPipe:
		stats.BrokenPipeCount++
	case urltest.ErrorTypeDNSTimeout:
		stats.DNSErrorCount++
	case urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeUnsupportedCurve:
		stats.TLSErrorCount++
	case urltest.ErrorTypeQUICTimeout:
		stats.QUICErrorCount++
	}
}

func calculateRuntimePenalty(stats *adapter.RuntimePenaltyStats) int {
	penalty := 0
	penalty += min(stats.EOFCount*2, 6)
	penalty += min(stats.RefusedCount*4, 10)
	penalty += min(stats.ResetCount*5, 15)
	penalty += min(stats.BrokenPipeCount*5, 15)
	penalty += min(stats.TimeoutCount*7, 20)
	penalty += min(stats.DNSErrorCount*8, 20)
	penalty += min(stats.TLSErrorCount*8, 20)
	penalty += min(stats.QUICErrorCount*7, 20)
	if penalty > 25 {
		return 25
	}
	return penalty
}

func (m *OutboundMonitoring) collectCycleTargets(forceAll bool) []string {

	tags := make([]string, 0, len(m.outbounds))

	delays := make(map[string]uint16, len(tags))

	for tag, state := range m.outbounds {
		if _, ok := m.groups[tag]; ok {
			continue
		}
		state.mu.Lock()
		if state.testing || state.queued || state.priorityQueued {
			state.mu.Unlock()
			continue
		}
		if forceAll || state.invalid || time.Since(state.history.Time) >= m.mainInterval {
			tags = append(tags, tag)
			delays[tag] = state.history.Delay
		}
		state.mu.Unlock()
	}

	sort.SliceStable(tags, func(i, j int) bool {
		return delays[tags[i]] < delays[tags[j]]
	})
	return tags
}

func (m *OutboundMonitoring) makeGroup(tag string) *groupState {
	grp, ok := m.groups[tag]
	if ok {
		return grp
	}

	grp = &groupState{
		tag:       tag,
		outbounds: make(map[string]struct{}),
		observer:  NewBroadcaster[GroupEvent](m.ctx),
		notifyCh:  make(chan struct{}, 1),
	}
	m.groups[tag] = grp
	return grp
}

func (m *OutboundMonitoring) Touch() {
	if !m.started.Load() {
		return
	}
	m.lastActive.Store(time.Now())
	m.startTimerWorkers()
}

func (m *OutboundMonitoring) emitGroupEvent(groupTags []string) {
	for _, groupTag := range groupTags {
		grp, ok := m.groups[groupTag]
		if !ok || grp.observer == nil {
			continue
		}

		select {
		case grp.notifyCh <- struct{}{}:
		default:
		}
	}
}

func (m *OutboundMonitoring) publishCompletedBatch(generation uint64, batchNumber int, outboundTags []string) {
	groups := make(map[string][]string)
	for _, tag := range outboundTags {
		state := m.getState(tag)
		if state == nil {
			continue
		}
		state.mu.Lock()
		groupTags := append([]string(nil), state.groupTags...)
		state.mu.Unlock()
		for _, groupTag := range groupTags {
			groups[groupTag] = append(groups[groupTag], tag)
		}
	}
	now := time.Now()
	for groupTag, tags := range groups {
		grp := m.groups[groupTag]
		if grp == nil || grp.observer == nil {
			continue
		}
		grp.batchAccess.Lock()
		if generation > grp.completedGeneration || (generation == grp.completedGeneration && batchNumber > grp.completedBatch) {
			grp.completedGeneration = generation
			grp.completedBatch = batchNumber
		}
		grp.batchAccess.Unlock()
		grp.observer.Publish(GroupEvent{
			GroupTag:       groupTag,
			From:           now,
			To:             now,
			BatchCompleted: true,
			Generation:     generation,
			BatchNumber:    batchNumber,
			tags:           tags,
		})
	}
	m.logger.Info("[MonitoringBatchCompleted] generation=", generation, " batch=", batchNumber, " servers=", len(outboundTags))
}

func (m *OutboundMonitoring) emitGroupEventsForOutbounds(outboundTags []string) {
	groupSet := make(map[string]struct{})
	for _, tag := range outboundTags {
		state := m.getState(tag)
		if state == nil {
			continue
		}
		state.mu.Lock()
		for _, groupTag := range state.groupTags {
			groupSet[groupTag] = struct{}{}
		}
		state.mu.Unlock()
	}
	groupTags := make([]string, 0, len(groupSet))
	for groupTag := range groupSet {
		groupTags = append(groupTags, groupTag)
	}
	m.emitGroupEvent(groupTags)
}

func (m *OutboundMonitoring) emitGroupEventThrottled(groupTag string, since time.Time) {

	grp, ok := m.groups[groupTag]
	if !ok || grp.observer == nil {
		return
	}
	tags := make([]string, 0, len(grp.outbounds))
	for tag := range grp.outbounds {
		state := m.outbounds[tag]
		if state == nil {
			continue
		}
		state.mu.Lock()
		if !state.history.Time.Before(since) {
			tags = append(tags, tag)
		}
		state.mu.Unlock()
	}
	grp.batchAccess.Lock()
	completedGeneration := grp.completedGeneration
	completedBatch := grp.completedBatch
	grp.batchAccess.Unlock()
	grp.observer.Publish(GroupEvent{
		GroupTag:       groupTag,
		From:           since,
		To:             time.Now(),
		BatchCompleted: completedGeneration > 0,
		Generation:     completedGeneration,
		BatchNumber:    completedBatch,
		tags:           tags,
	})
}

// func (m *OutboundMonitoring) OutboundsHistories() map[string]adapter.URLTestHistory {

//		histories := make(map[string]adapter.URLTestHistory)
//		outbounds := m.outbounds
//		for outboundTag, state := range outbounds {
//			state.mu.Lock()
//			histories[outboundTag] = state.history
//			state.mu.Unlock()
//		}
//		return histories
//	}
func RealTag(detour adapter.Outbound) string {
	if group, isGroup := detour.(adapter.OutboundGroup); isGroup {
		tag := group.Now()
		if tag != "" {
			return tag
		}
	}
	return detour.Tag()
}

func (m *OutboundMonitoring) groupNotifierLoop(grp *groupState) {

	defer m.schedulerWG.Done()

	var (
		timer   *time.Timer
		timerCh <-chan time.Time
		since   time.Time
	)

	for {
		select {
		case <-m.ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case <-grp.notifyCh:
			// if !m.cacheDirty.Load() {
			// 	continue
			// }
			if timer == nil {
				timer = time.NewTimer(m.debounceWindow)
				timerCh = timer.C
			}
		case <-timerCh:
			m.emitGroupEventThrottled(grp.tag, since)
			since = time.Now()
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer = nil
			timerCh = nil
		}
	}
}

func (m *OutboundMonitoring) getState(tag string) *outboundState {
	return m.outbounds[tag]
}

type testTask struct {
	outboundTag    string
	cycleID        uint64
	priority       bool
	fullGeneration bool
	resultCh       chan<- testOutcome
	manual         bool
	deferNotify    bool
}

type testOutcome struct {
	outboundTag    string
	url            string
	history        adapter.URLTestHistory
	err            error
	cycleID        uint64
	priority       bool
	fullGeneration bool
	deferNotify    bool
}

type udpProbeTask struct {
	tag        string
	generation uint64
}

type outboundState struct {
	mu sync.Mutex

	// historyPublish serializes a ranking revision commit with its storage
	// write against an isolated active-presentation publication. state.mu is
	// never held while storage hooks run; the lock order is historyPublish,
	// then state.mu.
	historyPublish sync.Mutex

	outbound            adapter.Outbound
	groupTags           []string
	dependenciesInverse []string
	dependencies        []string
	lastURL             string

	invalid                      bool
	queued                       bool
	priorityQueued               bool
	testing                      bool
	testingCycle                 uint64
	enqueuedCycle                uint64
	from_cache                   bool
	lastResultFromFullGeneration bool
	lastResultSourceKnown        bool

	udpProbeRunning    bool
	udpProbeLast       time.Time
	activeProbeRunning bool

	history                 adapter.URLTestHistory
	rankingRevision         uint64
	activeProbePresentation *activeProbePresentation
}

type activeProbePresentation struct {
	history         adapter.URLTestHistory
	rankingRevision uint64
}

// advanceRankingRevision invalidates any isolated presentation sample. The
// caller must hold outboundState.mu and invoke this whenever a new generation
// starts or a newer full monitoring result is committed.
func (s *outboundState) advanceRankingRevision() {
	s.rankingRevision++
	s.activeProbePresentation = nil
}

type GroupEvent struct {
	GroupTag       string
	From           time.Time
	To             time.Time
	BatchCompleted bool
	Generation     uint64
	BatchNumber    int
	tags           []string
}

type groupState struct {
	tag       string
	outbounds map[string]struct{}

	observer            *Broadcaster[GroupEvent]
	notifyCh            chan struct{}
	bestDelay           uint16
	batchAccess         sync.Mutex
	completedGeneration uint64
	completedBatch      int
}

type History struct {
	OutboundData map[string]*adapter.URLTestHistory `json:"outbound_data"`
}

func (m *OutboundMonitoring) saveHistory() error {
	if m.cache == nil {
		return nil
	}
	history := &History{
		OutboundData: make(map[string]*adapter.URLTestHistory),
	}
	for tag, state := range m.outbounds {
		state.mu.Lock()
		h := state.history
		state.mu.Unlock()
		history.OutboundData[tag] = &h
	}
	content, err := json.Marshal(history)
	if err != nil {
		m.logger.Error("failed to marshal outbound monitoring history: ", err)
		return err
	}
	m.cache.SaveBinary("outbound_monitoring_history", &adapter.SavedBinary{
		LastUpdated: time.Now(),
		Content:     content,
	})
	return nil
}
func (m *OutboundMonitoring) loadHistory() *History {
	history := &History{}
	if m.cache == nil {
		return history
	}
	saved := m.cache.LoadBinary("outbound_monitoring_history")
	if saved == nil {
		return history
	}
	err := json.Unmarshal(saved.Content, history)
	if err != nil {
		m.logger.Error("failed to unmarshal outbound monitoring history: ", err)
		return history
	}
	for tag, his := range history.OutboundData {
		if state, ok := m.outbounds[tag]; ok && his != nil {
			if _, ok := m.groups[tag]; ok {
				continue
			}
			if his.Delay >= TimeoutDelay {
				his.Delay = 0
			}
			his.Delay = 0
			his.Success = false
			his.ErrorType = ""
			his.ErrorText = ""
			his.URLTestStatus = urltest.StatusNotTested
			his.HealthScore = 0
			his.RuntimePenalty = 0
			his.RealUserPenalty = 0
			his.FreshnessPenalty = 0
			his.VolatilityPenalty = 0
			his.StabilityPoints = 0
			his.DegradationPoints = 0
			his.UDPProbeAvailable = false
			his.UDPPenalty = 0
			his.UDPLoss = 0
			his.UDPJitterMs = 0
			his.CheckGeneration = 0
			his.PingReady = false
			his.QualityReady = false
			his.SpeedReady = false
			his.UDPReady = false
			his.CombinedReady = false
			state.mu.Lock()
			state.history = *his
			state.from_cache = true
			state.mu.Unlock()
			m.logger.Info("[OutboundResultLoaded] tag=", tag,
				" source=cache generation=0 success=false delay=0 health_score=0",
				" url_test_status=", his.URLTestStatus, " result_time=", his.Time,
				" ranking_eligible=false")
		}
	}
	return history
}
