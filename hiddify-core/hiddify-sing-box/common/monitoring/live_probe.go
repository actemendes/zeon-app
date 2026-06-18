package monitoring

import (
	"context"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	N "github.com/sagernet/sing/common/network"
)

const (
	LiveUsabilityUnknown  = "unknown"
	LiveUsabilityChecking = "checking"
	LiveUsabilityOK       = "ok"
	LiveUsabilityDegraded = "degraded"
	LiveUsabilityFailed   = "failed"

	liveProbeMinInterval      = 2 * time.Minute
	liveProbeTargetTimeout    = 3 * time.Second
	liveProbeTotalTimeout     = 9 * time.Second
	liveFailureThreshold      = int32(2)
	liveAvoidDuration         = 10 * time.Minute
	liveUsabilityHealthyScore = int32(100)
	liveUsabilityFailedScore  = int32(0)
)

var liveProbeTargets = []struct {
	name string
	url  string
}{
	{name: "gstatic", url: defaultGoogleReachability},
	{name: "cloudflare", url: "https://cp.cloudflare.com/generate_204"},
	{name: "google", url: "https://www.google.com/generate_204"},
}

func (m *OutboundMonitoring) SelectedOutboundLiveProbe(tag string) {
	if m == nil || tag == "" {
		return
	}
	state := m.getState(tag)
	if state == nil {
		return
	}
	now := time.Now()
	state.mu.Lock()
	if state.liveChecking {
		state.mu.Unlock()
		return
	}
	if state.history.LiveCheckedAt > 0 && now.Sub(time.Unix(state.history.LiveCheckedAt, 0)) < liveProbeMinInterval {
		state.mu.Unlock()
		return
	}
	state.liveChecking = true
	outbound := state.outbound
	state.mu.Unlock()

	go m.runSelectedOutboundLiveProbe(tag, outbound)
}

func (m *OutboundMonitoring) runSelectedOutboundLiveProbe(tag string, outbound N.Dialer) {
	state := m.getState(tag)
	if state == nil {
		return
	}
	defer func() {
		state.mu.Lock()
		state.liveChecking = false
		state.mu.Unlock()
	}()

	m.updateLiveStatus(tag, func(history *adapter.URLTestHistory) {
		history.LiveUsabilityStatus = LiveUsabilityChecking
		history.LiveCheckedAt = time.Now().Unix()
	})
	if m.logger != nil {
		m.logger.Info("[LiveProbe] tag=", tag, " status=checking")
	}
	SafeDiagnosticLog("[LiveProbe] tag=", tag, " status=checking")

	parent, cancel := context.WithTimeout(m.ctx, liveProbeTotalTimeout)
	defer cancel()

	successes := 0
	lastReason := "timeout"
	for _, target := range liveProbeTargets {
		ctx, targetCancel := context.WithTimeout(parent, liveProbeTargetTimeout)
		result, err := urltest.MicroReachabilityTest(ctx, target.url, outbound)
		targetCancel()
		if err != nil {
			lastReason = reachabilityErrorReason(err)
			if m.logger != nil {
				m.logger.Info("[LiveProbe] tag=", tag, " target=", target.name, " ok=false error=", lastReason)
			}
			SafeDiagnosticLog("[LiveProbe] tag=", tag, " target=", target.name, " ok=false error=", lastReason)
			continue
		}
		successes++
		if m.logger != nil {
			m.logger.Info("[LiveProbe] tag=", tag, " target=", target.name, " ok=true ttfbMs=", result.TTFBMs)
		}
		SafeDiagnosticLog("[LiveProbe] tag=", tag, " target=", target.name, " ok=true ttfbMs=", result.TTFBMs)
		if successes >= 2 {
			break
		}
	}

	if successes > 0 {
		m.markLiveSuccess(tag, successes)
		return
	}
	m.RecordLiveFailure(tag, lastReason, "live timeout")
}

func (m *OutboundMonitoring) markLiveSuccess(tag string, successes int) {
	m.updateLiveStatus(tag, func(history *adapter.URLTestHistory) {
		history.LiveUsabilityStatus = LiveUsabilityOK
		history.LiveUsabilityScore = liveUsabilityHealthyScore
		history.LiveFailureCount = 0
		history.LiveLastError = ""
		history.LiveCheckedAt = time.Now().Unix()
		history.LiveAvoidUntil = 0
		if history.HealthReason == "live-usability-failed" || history.HealthReason == "live-timeout" || history.HealthReason == "traffic-failed" {
			history.HealthReason = "ok"
		}
	})
	if m.logger != nil {
		m.logger.Info("[LiveProbe] tag=", tag, " status=ok successes=", successes)
	}
	SafeDiagnosticLog("[LiveProbe] tag=", tag, " status=ok successes=", successes)
}

func (m *OutboundMonitoring) RecordLiveFailure(tag string, reason string, healthReason string) {
	if m == nil || tag == "" {
		return
	}
	normalized := NormalizeOutboundError(reason)
	if normalized == "" {
		normalized = reason
	}
	if normalized == "" {
		normalized = "timeout"
	}
	status := LiveUsabilityDegraded
	failures := int32(0)
	avoidUntil := int64(0)
	m.updateLiveStatus(tag, func(history *adapter.URLTestHistory) {
		failures = history.LiveFailureCount + 1
		history.LiveFailureCount = failures
		history.LiveLastError = normalized
		history.LiveCheckedAt = time.Now().Unix()
		history.LiveUsabilityScore = maxInt32(0, liveUsabilityHealthyScore-failures*45)
		if failures >= liveFailureThreshold {
			status = LiveUsabilityFailed
			avoidUntil = time.Now().Add(liveAvoidDuration).Unix()
			history.LiveUsabilityStatus = LiveUsabilityFailed
			history.LiveUsabilityScore = liveUsabilityFailedScore
			history.LiveAvoidUntil = avoidUntil
			history.AutoAllowed = false
			history.CombinedHealthScore = minInt32(history.CombinedHealthScore, 25)
			history.CombinedHealthLevel = HealthLevelWeak
			history.HealthReason = firstNonEmpty(healthReason, "live-usability-failed")
			return
		}
		history.LiveUsabilityStatus = LiveUsabilityDegraded
		if history.HealthReason == "" || history.HealthReason == "ok" {
			history.HealthReason = firstNonEmpty(healthReason, "live-degraded")
		}
	})
	if status == LiveUsabilityFailed {
		if m.logger != nil {
			m.logger.Info("[LiveProbe] tag=", tag, " status=failed failures=", failures, " avoidUntil=", avoidUntil)
			m.logger.Info("[LiveAvoid] tag=", tag, " status=active failures=", failures, " avoidUntil=", avoidUntil, " reason=", normalized)
		}
		SafeDiagnosticLog("[LiveProbe] tag=", tag, " status=failed failures=", failures, " avoidUntil=", avoidUntil)
		SafeDiagnosticLog("[LiveAvoid] tag=", tag, " status=active failures=", failures, " avoidUntil=", avoidUntil, " reason=", normalized)
		return
	}
	if m.logger != nil {
		m.logger.Info("[LiveProbe] tag=", tag, " status=degraded failures=", failures, " error=", normalized)
	}
	SafeDiagnosticLog("[LiveProbe] tag=", tag, " status=degraded failures=", failures, " error=", normalized)
}

func (m *OutboundMonitoring) updateLiveStatus(tag string, update func(*adapter.URLTestHistory)) {
	state := m.getState(tag)
	if state == nil {
		return
	}
	state.mu.Lock()
	update(&state.history)
	history := state.history
	state.mu.Unlock()
	if m.history != nil {
		m.history.StoreURLTestHistory(tag, &history)
	}
	m.cacheDirty.Store(true)
	m.emitGroupEvent(state.groupTags)
}

func LiveUsabilityAvoided(history *adapter.URLTestHistory, now time.Time) bool {
	if history == nil {
		return false
	}
	return history.LiveUsabilityStatus == LiveUsabilityFailed && history.LiveAvoidUntil > now.Unix()
}

func maxInt32(left int32, right int32) int32 {
	if left > right {
		return left
	}
	return right
}

func minInt32(left int32, right int32) int32 {
	if left == 0 || right < left {
		return right
	}
	return left
}
