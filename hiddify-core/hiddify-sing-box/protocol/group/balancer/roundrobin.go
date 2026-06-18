package balancer

import (
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

var _ Strategy = (*RoundRobin)(nil)

type RoundRobin struct {
	outbounds map[string][]adapter.Outbound

	sortedOutbounds map[string][]adapter.Outbound
	history         map[string]*adapter.URLTestHistory

	maxAcceptableIndex   map[string]int
	idx                  map[string]int
	currentTag           map[string]string
	selectedAt           map[string]time.Time
	affinity             map[string]roundRobinAffinity
	lastDecisionLog      map[string]time.Time
	mu                   sync.Mutex
	delayAcceptableRatio float64
	logger               log.ContextLogger
	now                  func() time.Time
}

const (
	roundRobinMinDwellTime        = 120 * time.Second
	roundRobinPreferredDwellTime  = 300 * time.Second
	roundRobinSwitchCooldown      = 30 * time.Second
	roundRobinAffinityTTL         = 10 * time.Minute
	roundRobinSwitchThreshold     = int32(15)
	roundRobinKeepCurrentMargin   = int32(10)
	roundRobinDecisionLogInterval = 10 * time.Second
)

type roundRobinAffinity struct {
	tag       string
	expiresAt time.Time
}

func NewRoundRobin(outbounds []adapter.Outbound, options option.BalancerOutboundOptions, logger log.ContextLogger) *RoundRobin {
	cOutbounds := convertOutbounds(outbounds)
	acceptable := map[string]int{}
	idx := map[string]int{}
	currentTag := map[string]string{}
	for net, outs := range cOutbounds {
		acceptable[net] = len(outs) - 1
		idx[net] = 0
		if len(outs) > 0 {
			currentTag[net] = outs[0].Tag()
		}
	}
	return &RoundRobin{
		outbounds: cOutbounds,

		sortedOutbounds:      cOutbounds,
		history:              map[string]*adapter.URLTestHistory{},
		maxAcceptableIndex:   acceptable,
		delayAcceptableRatio: options.DelayAcceptableRatio,
		idx:                  idx,
		currentTag:           currentTag,
		selectedAt:           map[string]time.Time{},
		affinity:             map[string]roundRobinAffinity{},
		lastDecisionLog:      map[string]time.Time{},
		logger:               logger,
		now:                  time.Now,
	}
}

func (s *RoundRobin) Now() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if current := s.currentTag[N.NetworkTCP]; current != "" {
		return current
	}
	outs := s.sortedOutbounds[N.NetworkTCP]
	if len(outs) == 0 {
		return ""
	}
	index := s.idx[N.NetworkTCP]
	if maxIndex, ok := s.maxAcceptableIndex[N.NetworkTCP]; ok && maxIndex >= 0 && index > maxIndex {
		index = maxIndex
	}
	if index < 0 || index >= len(outs) {
		index = 0
	}
	return outs[index].Tag()
}

func (s *RoundRobin) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	filteredOutbounds := filterRoundRobinOutboundsByQuality(s.outbounds, history, s.logger)
	sortedOutbounds := sortOutboundsByHealthThenDelay(filteredOutbounds, history)
	acceptableIndex := getAcceptableIndex(sortedOutbounds, history, s.delayAcceptableRatio)

	s.mu.Lock()
	defer s.mu.Unlock()
	interruptExisting := false
	for net := range sortedOutbounds {
		current := s.currentTag[net]
		if current == "" {
			current = tagAtIndex(s.sortedOutbounds[net], s.idx[net])
		}
		currentLevel, currentKnown := normalizedCombinedHealth(history[current])
		now := time.Now()
		currentAuto := CalculateAutoScore(history[current], now)
		if current != "" {
			currentMissing := !containsOutboundTag(sortedOutbounds[net], current)
			best := tagAtIndex(sortedOutbounds[net], 0)
			activeFor := now.Sub(s.selectedAt[net])
			if s.selectedAt[net].IsZero() {
				activeFor = roundRobinPreferredDwellTime
			}
			if currentMissing && (isBadRoundRobinLevel(currentLevel, currentKnown) || currentAuto.LiveFailed) {
				interruptExisting = true
			}
			currentGood := currentLevel == monitoring.HealthLevelExcellent || currentLevel == monitoring.HealthLevelGood
			if best != "" && best != current && !currentGood && currentWorseByAllMetrics(history[current], history[best]) && activeFor >= roundRobinSwitchCooldown {
				interruptExisting = true
			}
		}
	}

	s.history = cloneHistoryMap(history)
	s.sortedOutbounds = sortedOutbounds
	s.maxAcceptableIndex = acceptableIndex
	for net, current := range s.currentTag {
		if s.selectedAt[net].IsZero() && len(s.sortedOutbounds[net]) > 0 {
			s.currentTag[net] = s.sortedOutbounds[net][0].Tag()
			s.idx[net] = 0
			continue
		}
		if current == "" {
			continue
		}
		if index, ok := indexOfOutboundTag(s.sortedOutbounds[net], current); ok {
			s.idx[net] = index
			continue
		}
		if s.idx[net] >= len(s.sortedOutbounds[net]) {
			s.idx[net] = 0
		}
	}
	return interruptExisting
}

func (s *RoundRobin) Select(metadata adapter.InboundContext, net string, touch bool) adapter.Outbound {
	s.mu.Lock()
	defer s.mu.Unlock()
	if net != N.NetworkTCP && net != N.NetworkUDP {
		net = N.NetworkTCP
	}
	candidates := s.selectableOutboundsLocked(net)
	if len(candidates) == 0 {
		return nil
	}
	now := s.now()
	if affinityKey := getKey(&metadata); affinityKey != "" {
		if entry, ok := s.affinity[affinityKey]; ok {
			if now.Before(entry.expiresAt) {
				if proxy := outboundByTag(candidates, entry.tag); proxy != nil {
					bestTag := candidates[0].Tag()
					affinityScore := CalculateAutoScore(s.history[entry.tag], now)
					bestScore := CalculateAutoScore(s.history[bestTag], now)
					if !affinityScore.LiveFailed && affinityScore.Score >= bestScore.Score-roundRobinKeepCurrentMargin {
						s.logCandidatesLocked(now, candidates, proxy.Tag(), bestTag, "affinity")
						s.logDecisionLocked(now, "keep", net, s.currentTag[net], entry.tag, bestTag, "affinity", 0, bestScore.Score-affinityScore.Score)
						return proxy
					}
					delete(s.affinity, affinityKey)
				}
			}
			delete(s.affinity, affinityKey)
		}
	}

	current := s.currentTag[net]
	if current == "" {
		current = tagAtIndex(s.sortedOutbounds[net], s.idx[net])
	}
	selected, action, reason, bestTag, diff := s.chooseLocked(net, current, candidates, now)
	if touch {
		s.commitSelectionLocked(net, selected.Tag(), now)
		if affinityKey := getKey(&metadata); affinityKey != "" {
			s.affinity[affinityKey] = roundRobinAffinity{
				tag:       selected.Tag(),
				expiresAt: now.Add(roundRobinAffinityTTL),
			}
			s.cleanupAffinityLocked(now)
		}
	}
	s.logCandidatesLocked(now, candidates, selected.Tag(), bestTag, reason)
	s.logDecisionLocked(now, action, net, current, selected.Tag(), bestTag, reason, now.Sub(s.selectedAt[net]), diff)
	return selected

}

func (s *RoundRobin) chooseLocked(net string, current string, candidates []adapter.Outbound, now time.Time) (adapter.Outbound, string, string, string, int32) {
	best := candidates[0]
	bestTag := best.Tag()
	currentOutbound := outboundByTag(candidates, current)
	if currentOutbound == nil {
		currentOutbound = outboundByTag(s.outbounds[net], current)
	}
	currentAuto := CalculateAutoScore(s.history[current], now)
	bestAuto := CalculateAutoScore(s.history[bestTag], now)
	diff := bestAuto.Score - currentAuto.Score
	if currentOutbound == nil {
		return best, "switch", "no-current", bestTag, diff
	}
	activeFor := now.Sub(s.selectedAt[net])
	if s.selectedAt[net].IsZero() {
		activeFor = roundRobinPreferredDwellTime
	}
	currentLevel, currentKnown := normalizedCombinedHealth(s.history[current])
	if currentAuto.LiveFailed {
		return best, "switch", "live-usability-failed", bestTag, diff
	}
	if isBadRoundRobinLevel(currentLevel, currentKnown) {
		return best, "switch", "current-bad", bestTag, diff
	}
	if currentOutboundNotInCandidates := outboundByTag(candidates, current) == nil; currentOutboundNotInCandidates {
		return best, "switch", "current-not-usable", bestTag, diff
	}
	if bestTag == current {
		return currentOutbound, "keep", "best-current", bestTag, diff
	}
	if activeFor < roundRobinMinDwellTime && currentAuto.Score >= bestAuto.Score-roundRobinKeepCurrentMargin {
		return currentOutbound, "keep", "min-dwell-current-good-enough", bestTag, diff
	}
	currentGood := currentLevel == monitoring.HealthLevelExcellent || currentLevel == monitoring.HealthLevelGood
	if !currentGood && currentWorseByAllMetrics(s.history[current], s.history[bestTag]) && activeFor >= roundRobinSwitchCooldown {
		return best, "switch", "current-worse-all-metrics", bestTag, diff
	}
	if diff >= roundRobinSwitchThreshold && activeFor >= roundRobinMinDwellTime {
		return best, "switch", "score-threshold", bestTag, diff
	}
	if currentAuto.Score >= bestAuto.Score-roundRobinKeepCurrentMargin {
		return currentOutbound, "keep", "current-good-enough", bestTag, diff
	}
	if activeFor < roundRobinPreferredDwellTime {
		return currentOutbound, "keep", "preferred-dwell", bestTag, diff
	}
	return best, "switch", "best-auto-score", bestTag, diff
}

func (s *RoundRobin) selectableOutboundsLocked(net string) []adapter.Outbound {
	outs := s.sortedOutbounds[net]
	if len(outs) == 0 {
		return nil
	}
	maxIndex := s.maxAcceptableIndex[net]
	if maxIndex < 0 {
		return nil
	}
	if maxIndex >= len(outs) {
		maxIndex = len(outs) - 1
	}
	return outs[:maxIndex+1]
}

func (s *RoundRobin) commitSelectionLocked(net string, tag string, now time.Time) {
	if s.currentTag[net] != tag || s.selectedAt[net].IsZero() {
		s.currentTag[net] = tag
		s.selectedAt[net] = now
	}
	if index, ok := indexOfOutboundTag(s.sortedOutbounds[net], tag); ok {
		s.idx[net] = index
	}
}

func isBadRoundRobinLevel(level string, known bool) bool {
	return known && (level == monitoring.HealthLevelBad || level == monitoring.HealthLevelWeak)
}

func (s *RoundRobin) cleanupAffinityLocked(now time.Time) {
	for key, entry := range s.affinity {
		if !now.Before(entry.expiresAt) {
			delete(s.affinity, key)
		}
	}
}

func (s *RoundRobin) logCandidatesLocked(now time.Time, candidates []adapter.Outbound, selected string, best string, selectedReason string) {
	if s.logger == nil {
		return
	}
	for idx, candidate := range candidates {
		tag := candidate.Tag()
		auto := CalculateAutoScore(s.history[tag], now)
		reason := auto.Reason
		if tag == selected {
			if tag == best {
				reason = "best"
			} else if selectedReason != "" {
				reason = selectedReason
			}
		}
		message := []any{"[AutoDecisionCandidates] rank=", idx + 1, " tag=", tag, " autoScore=", auto.Score, " combined=", auto.Combined, " quality=", auto.Quality, " speed=", auto.Third, " delay=", auto.Delay, " bucket=", auto.BucketName, " reason=", reason}
		s.logger.Info(message...)
		monitoring.SafeDiagnosticLog(message...)
	}
}

func (s *RoundRobin) logDecisionLocked(now time.Time, action string, net string, current string, next string, best string, reason string, activeFor time.Duration, diff int32) {
	if s.logger == nil {
		return
	}
	key := net + "|" + action + "|" + current + "|" + next + "|" + best + "|" + reason
	if last := s.lastDecisionLog[key]; !last.IsZero() && now.Sub(last) < roundRobinDecisionLogInterval {
		return
	}
	s.lastDecisionLog[key] = now
	currentScore := CalculateAutoScore(s.history[current], now).Score
	bestScore := CalculateAutoScore(s.history[best], now).Score
	args := []any{"[AutoDecision] action=", action, " current=", current, " selected=", next, " reason=", reason, " currentScore=", currentScore, " bestScore=", bestScore, " scoreDiff=", diff, " activeFor=", int(activeFor.Seconds()), "s"}
	if best != "" {
		args = append(args, " best=", best)
	}
	s.logger.Info(args...)
	monitoring.SafeDiagnosticLog(args...)
}

func currentWorseByAllMetrics(current *adapter.URLTestHistory, best *adapter.URLTestHistory) bool {
	if current == nil || best == nil {
		return false
	}
	currentCombined, currentCombinedKnown := getCombinedHealthScore(current)
	bestCombined, bestCombinedKnown := getCombinedHealthScore(best)
	currentQuality, currentQualityKnown := getQualityScore(current)
	bestQuality, bestQualityKnown := getQualityScore(best)
	currentSpeed, currentSpeedKnown := getSpeedScore(current)
	bestSpeed, bestSpeedKnown := getSpeedScore(best)
	if !currentCombinedKnown || !bestCombinedKnown || !currentQualityKnown || !bestQualityKnown || !currentSpeedKnown || !bestSpeedKnown {
		return false
	}
	return currentCombined < bestCombined &&
		currentQuality < bestQuality &&
		currentSpeed < bestSpeed &&
		getModifiedDelay(current) > getModifiedDelay(best)
}
