package balancer

import (
	"fmt"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
)

const smartActiveProbeRetryDelay = 350 * time.Millisecond

var smartActiveProbeStartupOffsets = [...]time.Duration{
	0,
	10 * time.Second,
	20 * time.Second,
	30 * time.Second,
	40 * time.Second,
	50 * time.Second,
	60 * time.Second,
}

type smartActiveProbeSchedule struct {
	activeTag   string
	activeSince time.Time
	probeIndex  int
}

func (s *smartActiveProbeSchedule) observe(tag string, now time.Time) bool {
	if tag == "" || tag == s.activeTag {
		return false
	}
	s.activeTag = tag
	s.activeSince = now
	s.probeIndex = 0
	return true
}

func (s *smartActiveProbeSchedule) deadline() time.Time {
	return s.activeSince.Add(smartActiveProbeOffset(s.probeIndex))
}

func (s *smartActiveProbeSchedule) complete() {
	s.probeIndex++
}

// smartActiveProbeOffset is measured from the moment a server becomes active:
// 0, 10, 20, 30, 40, 50, 60 seconds, then once per minute.
func smartActiveProbeOffset(index int) time.Duration {
	if index <= 0 {
		return 0
	}
	if index < len(smartActiveProbeStartupOffsets) {
		return smartActiveProbeStartupOffsets[index]
	}
	return smartActiveProbeStartupOffsets[len(smartActiveProbeStartupOffsets)-1] +
		time.Duration(index-len(smartActiveProbeStartupOffsets)+1)*time.Minute
}

func (s *Balancer) monitorActiveServer() {
	defer s.activeMonitorWG.Done()

	var schedule smartActiveProbeSchedule
	for {
		current := s.Now()
		if current == "" {
			if !s.waitForActiveMonitorWake(time.Second) {
				return
			}
			continue
		}
		if schedule.observe(current, time.Now()) {
			s.drainActiveMonitorWake()
			s.logger.Info(fmt.Sprintf(
				"[SmartActiveLifecycle] event=active_probe_schedule_reset group=%s active=%s",
				s.Tag(), schedule.activeTag,
			))
		}

		if !s.waitForActiveMonitorDeadline(schedule.deadline()) {
			return
		}
		if s.Now() != schedule.activeTag {
			continue
		}

		s.runScheduledActiveProbe(schedule.activeTag)
		if s.Now() != schedule.activeTag {
			continue
		}
		schedule.complete()
	}
}

func (s *Balancer) runScheduledActiveProbe(tag string) {
	result, err := s.monitor.ProbeActiveOutbound(s.activeMonitorCtx, tag)
	if err != nil && result.History.Time.IsZero() {
		if s.activeMonitorCtx.Err() == nil {
			s.logger.Debug(fmt.Sprintf(
				"[SmartActiveProbe] tag=%s trigger=active_schedule decision=skip reason=%v",
				tag, err,
			))
		}
		return
	}
	if s.activeMonitorCtx.Err() != nil {
		return
	}
	update := s.applyActiveProbe(result)
	if !update.retry || update.changed || s.Now() != tag {
		return
	}

	timer := time.NewTimer(smartActiveProbeRetryDelay)
	defer timer.Stop()
	select {
	case <-s.activeMonitorCtx.Done():
		return
	case <-timer.C:
	}
	if s.Now() != tag {
		return
	}
	confirmation, err := s.monitor.ProbeActiveOutbound(s.activeMonitorCtx, tag)
	if err != nil && confirmation.History.Time.IsZero() {
		if s.activeMonitorCtx.Err() == nil {
			s.logger.Debug(fmt.Sprintf(
				"[SmartActiveProbe] tag=%s trigger=confirmation decision=skip reason=%v",
				tag, err,
			))
		}
		return
	}
	if s.activeMonitorCtx.Err() != nil {
		return
	}
	s.applyActiveProbe(confirmation)
}

func (s *Balancer) applyActiveProbe(result monitoring.ActiveProbeResult) smartActiveProbeUpdate {
	s.strategyUpdate.Lock()
	defer s.strategyUpdate.Unlock()

	strategy, ok := s.strategyFn.(*SmartActive)
	if !ok || strategy.Now() != result.OutboundTag {
		return smartActiveProbeUpdate{}
	}
	if !s.monitor.PublishActiveProbePresentation(result) {
		s.logger.Debug(fmt.Sprintf(
			"[SmartActiveProbe] tag=%s decision=skip reason=stale_presentation_revision",
			result.OutboundTag,
		))
		return smartActiveProbeUpdate{}
	}
	rankingHistory := s.monitor.OutboundsRankingHistory(s.Tag())
	if activeProbeSupersededByRanking(&result.History, rankingHistory[result.OutboundTag]) {
		s.logger.Debug(fmt.Sprintf(
			"[SmartActiveProbe] tag=%s decision=skip reason=newer_ranking_evidence",
			result.OutboundTag,
		))
		return smartActiveProbeUpdate{}
	}
	// Use the exact sample whose ranking revision was just accepted. Reading the
	// presentation map again here would race with a new full cycle invalidating
	// the overlay and could turn a successful probe into a synthetic failure.
	probe := cloneSmartActiveHistory(&result.History)
	update := strategy.UpdateActiveProbe(result.OutboundTag, probe, rankingHistory)
	decision := strategy.LastDecision()
	s.logger.Info(fmt.Sprintf(
		"[SmartActiveDecision] action=%s reason=%s from=%s to=%s current=%s mode=active_probe delay=%d score=%d udp_ready=%t udp_loss=%.4f",
		decision.action, decision.reason, decision.from, decision.to, strategy.Now(),
		result.History.Delay, result.History.HealthScore, result.History.UDPReady, result.History.UDPLoss,
	))

	if update.changed {
		decisionHistory := make(map[string]*adapter.URLTestHistory, len(rankingHistory))
		for tag, item := range rankingHistory {
			decisionHistory[tag] = item
		}
		decisionHistory[result.OutboundTag] = probe
		s.logAutoDecision(decisionHistory)
		s.logger.Warn(fmt.Sprintf(
			"[ActiveServerChanged] group=%s active=%s",
			s.Tag(), s.strategyFn.Now(),
		))
		s.interruptGroup.Interrupt(s.interruptExternalConnections)
		s.signalActiveMonitor()
	}
	if update.refreshCandidates {
		s.logger.Warn(fmt.Sprintf(
			"[SmartActiveProbe] tag=%s decision=request_candidate_refresh reason=%s",
			result.OutboundTag, decision.reason,
		))
		s.monitor.RequestFullCycle()
	}
	return update
}

func activeProbeSupersededByRanking(probe, ranking *adapter.URLTestHistory) bool {
	if probe == nil || ranking == nil {
		return false
	}
	return ranking.Time.After(probe.Time) ||
		(probe.CheckGeneration > 0 && ranking.CheckGeneration > probe.CheckGeneration)
}

func (s *Balancer) signalActiveMonitor() {
	select {
	case s.activeMonitorWake <- struct{}{}:
	default:
	}
}

func (s *Balancer) drainActiveMonitorWake() {
	for {
		select {
		case <-s.activeMonitorWake:
		default:
			return
		}
	}
}

func (s *Balancer) waitForActiveMonitorDeadline(deadline time.Time) bool {
	wait := time.Until(deadline)
	if wait <= 0 {
		return true
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-s.activeMonitorCtx.Done():
		return false
	case <-s.activeMonitorWake:
		return true
	case <-timer.C:
		return true
	}
}

func (s *Balancer) waitForActiveMonitorWake(maxWait time.Duration) bool {
	timer := time.NewTimer(maxWait)
	defer timer.Stop()
	select {
	case <-s.activeMonitorCtx.Done():
		return false
	case <-s.activeMonitorWake:
		return true
	case <-timer.C:
		return true
	}
}
