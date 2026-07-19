package monitoring

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

const (
	activeURLTestTimeout = 3 * time.Second
	activeUDPProbeCount  = 3
	activeUDPProbeSize   = 128
	activeUDPProbeWait   = 750 * time.Millisecond
	activeUDPProbeGap    = 40 * time.Millisecond
)

var errActiveProbeAlreadyRunning = errors.New("active outbound probe already running")

// ActiveProbeResult is an isolated, lightweight health sample for the outbound
// that currently carries user traffic. It deliberately does not replace the
// full-generation history used to rank the whole balancer cohort.
type ActiveProbeResult struct {
	OutboundTag  string
	History      adapter.URLTestHistory
	UDPAttempted bool
	UDPErrorType string
}

// ProbeActiveOutbound sends one tiny HTTP probe and, when the authenticated UDP
// probe is configured, at most three small UDP packets through exactly tag.
// Unlike a normal monitoring cycle it does not fetch IP metadata or touch any
// other outbound.
func (m *OutboundMonitoring) ProbeActiveOutbound(parent context.Context, tag string) (ActiveProbeResult, error) {
	if parent == nil {
		parent = context.Background()
	}
	result := ActiveProbeResult{OutboundTag: tag}
	state := m.getState(tag)
	if state == nil {
		return result, errors.New("outbound not registered")
	}

	state.mu.Lock()
	if state.activeProbeRunning {
		state.mu.Unlock()
		return result, errActiveProbeAlreadyRunning
	}
	state.activeProbeRunning = true
	outbound := state.outbound
	previous := state.history
	state.mu.Unlock()
	defer func() {
		state.mu.Lock()
		state.activeProbeRunning = false
		state.mu.Unlock()
	}()

	if outbound == nil || !outbound.IsReady() {
		err := errors.New("outbound is not ready")
		result.History = m.newActiveProbeFailure(tag, previous, err)
		return result, err
	}

	baseCtx := m.ctx
	if baseCtx == nil {
		baseCtx = parent
	}
	probeCtx, cancel := context.WithCancel(baseCtx)
	stopParentCancel := context.AfterFunc(parent, cancel)
	defer func() {
		stopParentCancel()
		cancel()
	}()

	probeURL := defaultURLTest
	if len(m.urls) > 0 {
		urlIndex := m.currentLinkIndex.Load()
		if int(urlIndex) >= len(m.urls) {
			urlIndex = 0
		}
		probeURL = m.urls[urlIndex]
	}
	timeout := m.urlTestTimeout
	if timeout <= 0 || timeout > activeURLTestTimeout {
		timeout = activeURLTestTimeout
	}

	delay, err, timedOut := runActiveURLTestWithHardTimeout(probeCtx, timeout, func(ctx context.Context) (uint16, error) {
		return urltest.URLTest(ctx, probeURL, outbound)
	})
	if timedOut {
		err = context.DeadlineExceeded
	}
	if err == nil && (delay == 0 || delay >= TimeoutDelay) {
		err = errors.New("active outbound URL test returned invalid delay")
	}
	if err != nil {
		result.History = m.newActiveProbeFailure(tag, previous, err)
		return result, err
	}

	history := adapter.URLTestHistory{
		Time:              time.Now(),
		Delay:             delay,
		IpInfo:            previous.IpInfo,
		Success:           true,
		ErrorType:         urltest.ErrorTypeNone,
		URLTestStatus:     urltest.StatusSuccess,
		RuntimePenalty:    m.runtimePenaltyForTag(tag),
		RealUserPenalty:   previous.RealUserPenalty,
		VolatilityPenalty: previous.VolatilityPenalty,
		StabilityPoints:   previous.StabilityPoints,
		DegradationPoints: previous.DegradationPoints,
		PolicyPenalty:     previous.PolicyPenalty,
		CheckGeneration:   previous.CheckGeneration,
		PingReady:         true,
		QualityReady:      true,
		SpeedReady:        true,
		CombinedReady:     true,
	}

	if m.udpProbeEnabled && m.isUDPProbeCandidate(outbound) {
		result.UDPAttempted = true
		udpOptions := lightweightActiveUDPOptions(m.udpProbeOptions)
		udpTimeout := time.Duration(udpOptions.Count)*(udpOptions.Timeout+udpOptions.Interval) + time.Second
		udpCtx, cancelUDP := context.WithTimeout(probeCtx, udpTimeout)
		udpResult := urltest.RunUDPProbeThroughOutbound(udpCtx, outbound, m.udpProbeEndpoint, m.udpProbeSecret, udpOptions)
		cancelUDP()
		history.UDPProbeAvailable = udpResult.Available
		history.UDPPenalty = udpResult.Penalty
		history.UDPLoss = udpResult.Loss
		history.UDPJitterMs = udpResult.JitterMs
		history.UDPReady = true
		result.UDPErrorType = udpResult.ErrorType
	}

	refreshHealthScore(tag, &history, false)
	result.History = history
	m.logger.Info(fmt.Sprintf(
		"[SmartActiveProbe] tag=%s trigger=active_schedule status=completed delay=%d score=%d udp_attempted=%t udp_ready=%t udp_loss=%.4f",
		tag, history.Delay, history.HealthScore, result.UDPAttempted, history.UDPReady, history.UDPLoss,
	))
	return result, nil
}

func (m *OutboundMonitoring) newActiveProbeFailure(tag string, previous adapter.URLTestHistory, err error) adapter.URLTestHistory {
	errorType, errorText := urltest.ClassifyProbeError(err)
	if errorType == "" || errorType == urltest.ErrorTypeNone {
		errorType = urltest.ErrorTypeUnknown
	}
	history := adapter.URLTestHistory{
		Time:              time.Now(),
		Delay:             TimeoutDelay,
		IpInfo:            previous.IpInfo,
		Success:           false,
		ErrorType:         errorType,
		ErrorText:         errorText,
		URLTestStatus:     urltest.StatusFailed,
		RuntimePenalty:    m.runtimePenaltyForTag(tag),
		RealUserPenalty:   previous.RealUserPenalty,
		VolatilityPenalty: previous.VolatilityPenalty,
		StabilityPoints:   previous.StabilityPoints,
		DegradationPoints: previous.DegradationPoints,
		PolicyPenalty:     previous.PolicyPenalty,
		CheckGeneration:   previous.CheckGeneration,
		PingReady:         true,
		QualityReady:      true,
		SpeedReady:        true,
		CombinedReady:     true,
	}
	refreshHealthScore(tag, &history, false)
	m.logger.Warn(fmt.Sprintf(
		"[SmartActiveProbe] tag=%s trigger=active_schedule status=failed error=%s",
		tag, history.ErrorType,
	))
	return history
}

func lightweightActiveUDPOptions(options urltest.UDPProbeOptions) urltest.UDPProbeOptions {
	defaults := urltest.DefaultUDPProbeOptions()
	if options.Count <= 0 {
		options.Count = defaults.Count
	}
	if options.Count > activeUDPProbeCount {
		options.Count = activeUDPProbeCount
	}
	if options.Size <= 0 {
		options.Size = defaults.Size
	}
	if options.Size > activeUDPProbeSize {
		options.Size = activeUDPProbeSize
	}
	if options.Interval <= 0 || options.Interval > activeUDPProbeGap {
		options.Interval = activeUDPProbeGap
	}
	if options.Timeout <= 0 || options.Timeout > activeUDPProbeWait {
		options.Timeout = activeUDPProbeWait
	}
	return options
}

func runActiveURLTestWithHardTimeout(parent context.Context, timeout time.Duration, run func(context.Context) (uint16, error)) (uint16, error, bool) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	type result struct {
		delay uint16
		err   error
	}
	resultCh := make(chan result, 1)
	go func() {
		delay, err := run(ctx)
		resultCh <- result{delay: delay, err: err}
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-parent.Done():
		return 0, parent.Err(), false
	case value := <-resultCh:
		return value.delay, value.err, false
	case <-timer.C:
		cancel()
		return 0, context.DeadlineExceeded, true
	}
}
