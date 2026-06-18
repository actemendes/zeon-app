package balancer

import (
	"fmt"
	"net"
	"net/netip"
	"sort"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing/common"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/net/publicsuffix"
)

const roundRobinNormalMinScore int32 = 70

const (
	autoCandidateBucketNormal = iota
	autoCandidateBucketMedium
	autoCandidateBucketUnknown
	autoCandidateBucketWeak
	autoCandidateBucketBad
	autoCandidateBucketEmergency
)

const autoScoreFreshnessWindow = 15 * time.Minute

type AutoScore struct {
	Score       int32
	Bucket      int
	BucketName  string
	Reason      string
	Combined    int32
	Quality     int32
	Third       int32
	Delay       uint16
	Stale       bool
	LiveFailed  bool
	AutoAllowed bool
}

func getKey(metadata *adapter.InboundContext) string {
	if metadata == nil {
		return ""
	}

	var metadataHost string
	if metadata.Destination.IsFqdn() {
		metadataHost = metadata.Destination.Fqdn
	} else {
		metadataHost = metadata.Domain
	}

	if metadataHost != "" {
		// ip host
		if ip := net.ParseIP(metadataHost); ip != nil {
			return metadataHost
		}

		if etld, err := publicsuffix.EffectiveTLDPlusOne(metadataHost); err == nil {
			return etld
		}
	}

	var destinationAddr netip.Addr
	if len(metadata.DestinationAddresses) > 0 {
		destinationAddr = metadata.DestinationAddresses[0]
	} else {
		destinationAddr = metadata.Destination.Addr
	}

	if !destinationAddr.IsValid() {
		return ""
	}

	return destinationAddr.String()
}

func getKeyWithSrcAndDst(metadata *adapter.InboundContext) string {
	dst := getKey(metadata)
	src := ""
	if metadata != nil {
		src = metadata.Source.Addr.String()
	}

	return fmt.Sprintf("%s%s", src, dst)
}

func jumpHash(key uint64, buckets int32) int32 {
	var b, j int64

	for j < int64(buckets) {
		b = j
		key = key*2862933555777941757 + 1
		j = int64(float64(b+1) * (float64(int64(1)<<31) / float64((key>>33)+1)))
	}

	return int32(b)
}

func getModifiedDelay(his *adapter.URLTestHistory) uint16 {
	if his == nil {
		return monitoring.TimeoutDelay
	}
	delay := his.Delay
	if delay == 0 {
		delay = monitoring.TimeoutDelay
	}
	if his.IsFromCache && delay < 20000 {
		// if the history is from cache, we can not trust the delay
		delay += 20000
	}
	return delay
}
func getTagDelay(tag string, history map[string]*adapter.URLTestHistory) uint16 {
	if his, ok := history[tag]; ok && his != nil {
		return getModifiedDelay(his)
	}
	return monitoring.TimeoutDelay
}

func filterOutbounds(outbounds []adapter.Outbound, network string) []adapter.Outbound {
	res := []adapter.Outbound{}
	for _, out := range outbounds {
		if !common.Contains(out.Network(), network) {
			continue
		}
		res = append(res, out)
	}
	if len(res) == 0 {
		return outbounds
	}
	return res
}
func convertOutbounds(outbounds []adapter.Outbound) map[string][]adapter.Outbound {
	return map[string][]adapter.Outbound{
		N.NetworkTCP: filterOutbounds(outbounds, N.NetworkTCP),
		N.NetworkUDP: filterOutbounds(outbounds, N.NetworkUDP),
	}
}

func sortOutboundsByDelay(outbounds map[string][]adapter.Outbound, history map[string]*adapter.URLTestHistory) map[string][]adapter.Outbound {
	res := map[string][]adapter.Outbound{}
	for net, outs := range outbounds {
		res[net] = append([]adapter.Outbound{}, outs...)
		sort.SliceStable(res[net], func(i, j int) bool {
			var delayi uint16 = getTagDelay(res[net][i].Tag(), history)
			var delayj uint16 = getTagDelay(res[net][j].Tag(), history)
			return delayi < delayj
		})
	}

	return res
}

func sortOutboundsByHealthThenDelay(outbounds map[string][]adapter.Outbound, history map[string]*adapter.URLTestHistory) map[string][]adapter.Outbound {
	res := map[string][]adapter.Outbound{}
	now := time.Now()
	for net, outs := range outbounds {
		originalOrder := originalOutboundOrder(outs)
		res[net] = append([]adapter.Outbound{}, outs...)
		sort.SliceStable(res[net], func(i, j int) bool {
			leftTag := res[net][i].Tag()
			rightTag := res[net][j].Tag()
			left := CalculateAutoScore(history[leftTag], now)
			right := CalculateAutoScore(history[rightTag], now)
			if left.Bucket != right.Bucket {
				return left.Bucket < right.Bucket
			}
			if left.Score != right.Score {
				return left.Score > right.Score
			}
			if left.Combined != right.Combined {
				return left.Combined > right.Combined
			}
			if left.Quality != right.Quality {
				return left.Quality > right.Quality
			}
			if left.Third != right.Third {
				return left.Third > right.Third
			}
			if left.Delay != right.Delay {
				return left.Delay < right.Delay
			}
			return originalOrder[leftTag] < originalOrder[rightTag]
		})
	}
	return res
}

func healthSortBucket(his *adapter.URLTestHistory) int {
	return CalculateAutoScore(his, time.Now()).Bucket
}

func filterRoundRobinOutboundsByQuality(outbounds map[string][]adapter.Outbound, history map[string]*adapter.URLTestHistory, logger log.ContextLogger) map[string][]adapter.Outbound {
	res := map[string][]adapter.Outbound{}
	now := time.Now()
	for net, outs := range outbounds {
		goodCandidates := make([]adapter.Outbound, 0, len(outs))
		mediumCandidates := make([]adapter.Outbound, 0, len(outs))
		unknownCandidates := make([]adapter.Outbound, 0, len(outs))
		weakCandidates := make([]adapter.Outbound, 0, len(outs))
		counts := roundRobinCandidateCounts{}
		excludedBad := 0
		for _, out := range outs {
			his := history[out.Tag()]
			auto := CalculateAutoScore(his, now)
			countRoundRobinCandidate(&counts, auto.Bucket)
			switch auto.Bucket {
			case autoCandidateBucketNormal:
				goodCandidates = append(goodCandidates, out)
			case autoCandidateBucketMedium:
				mediumCandidates = append(mediumCandidates, out)
			case autoCandidateBucketUnknown:
				unknownCandidates = append(unknownCandidates, out)
			case autoCandidateBucketWeak:
				weakCandidates = append(weakCandidates, out)
			default:
				excludedBad++
			}
		}

		switch {
		case len(goodCandidates) > 0:
			res[net] = goodCandidates
			logRoundRobinCandidates(logger, counts)
			logBalanceQuality(logger, "mode=good candidates=", len(goodCandidates), " excludedBad=", excludedBad)
		case len(mediumCandidates) > 0:
			res[net] = mediumCandidates
			logRoundRobinCandidates(logger, counts)
			logBalanceQuality(logger, "fallback=medium candidates=", len(mediumCandidates), " reason=no-good-candidates excludedBad=", excludedBad)
		case len(unknownCandidates) > 0:
			res[net] = unknownCandidates
			logRoundRobinCandidates(logger, counts)
			logBalanceQuality(logger, "compatibilityFallback=true reason=checking-or-unknown candidates=", len(unknownCandidates), " excludedBad=", excludedBad)
		case len(weakCandidates) > 0:
			res[net] = weakCandidates
			logRoundRobinCandidates(logger, counts)
			logBalanceQuality(logger, "fallback=weak candidates=", len(weakCandidates), " reason=no-usable-candidates excludedBad=", excludedBad)
		default:
			res[net] = outs
			logRoundRobinCandidates(logger, counts)
			logBalanceQuality(logger, "emergencyFallback=true reason=no-quality-candidates candidates=", len(outs), " excludedBad=", excludedBad)
		}
	}
	return res
}

type roundRobinCandidateCounts struct {
	normal  int
	medium  int
	weak    int
	bad     int
	unknown int
}

func countRoundRobinCandidate(counts *roundRobinCandidateCounts, bucket int) {
	switch bucket {
	case autoCandidateBucketNormal:
		counts.normal++
	case autoCandidateBucketMedium:
		counts.medium++
	case autoCandidateBucketWeak:
		counts.weak++
	case autoCandidateBucketBad, autoCandidateBucketEmergency:
		counts.bad++
	default:
		counts.unknown++
	}
}

func CalculateAutoScore(his *adapter.URLTestHistory, now time.Time) AutoScore {
	auto := AutoScore{
		Bucket:      autoCandidateBucketUnknown,
		BucketName:  "unknown",
		Reason:      "candidate-unknown",
		Delay:       getModifiedDelay(his),
		AutoAllowed: true,
	}
	if his == nil {
		auto.Score = 0
		return auto
	}
	auto.AutoAllowed = his.AutoAllowed
	auto.Combined, _ = getCombinedHealthScore(his)
	auto.Quality, _ = getQualityScore(his)
	speed, _ := getSpeedScore(his)
	external, _ := getExternalHealthScore(his)
	auto.Third = maxScore(speed, external)
	auto.Stale = isStaleAutoHistory(his, now)
	auto.LiveFailed = monitoring.LiveUsabilityAvoided(his, now)

	score := auto.Combined
	if score == 0 {
		score = auto.Quality - 15
	}
	if auto.Quality > 0 && auto.Quality < score {
		score -= (score - auto.Quality) / 4
	}
	if auto.Third > 0 && auto.Third < score {
		score -= (score - auto.Third) / 5
	}
	if his.LiveUsabilityStatus == monitoring.LiveUsabilityDegraded {
		score -= 10 + his.LiveFailureCount*5
	}
	if auto.LiveFailed {
		score -= 80
	}
	if auto.Stale {
		score -= 15
	}
	if his.IsFromCache {
		score -= 25
	}
	auto.Score = clampAutoScore(score)

	level, known := normalizedCombinedHealth(his)
	qualityLevel, qualityAllowed, qualityKnown := normalizedQuality(his)
	switch {
	case auto.LiveFailed:
		auto.Bucket = autoCandidateBucketBad
		auto.BucketName = "bad"
		auto.Reason = "live-usability-failed"
	case !his.AutoAllowed && known:
		auto.Bucket = autoCandidateBucketBad
		auto.BucketName = "bad"
		auto.Reason = "auto-not-allowed"
	case qualityKnown && !qualityAllowed && qualityLevel == monitoring.QualityLevelBad:
		auto.Bucket = autoCandidateBucketBad
		auto.BucketName = "bad"
		auto.Reason = firstNonEmpty(his.LastError, "quality-not-usable")
	case qualityKnown && qualityLevel == monitoring.QualityLevelMedium && !known:
		auto.Bucket = autoCandidateBucketMedium
		auto.BucketName = "medium"
		auto.Reason = firstNonEmpty(his.HealthReason, "quality-medium")
	case qualityKnown && (qualityLevel == monitoring.QualityLevelExcellent || qualityLevel == monitoring.QualityLevelGood) && !known:
		auto.Bucket = autoCandidateBucketUnknown
		auto.BucketName = "unknown"
		auto.Reason = "combined-checking"
	case known && auto.Stale:
		auto.Bucket = autoCandidateBucketUnknown
		auto.BucketName = "unknown"
		auto.Reason = "candidate-stale"
	case known && auto.Combined >= roundRobinNormalMinScore && (level == monitoring.HealthLevelExcellent || level == monitoring.HealthLevelGood):
		auto.Bucket = autoCandidateBucketNormal
		auto.BucketName = level
		auto.Reason = "normal"
	case known && level == monitoring.HealthLevelMedium:
		auto.Bucket = autoCandidateBucketMedium
		auto.BucketName = "medium"
		auto.Reason = firstNonEmpty(his.HealthReason, "fallback-medium")
	case known && level == monitoring.HealthLevelWeak:
		auto.Bucket = autoCandidateBucketWeak
		auto.BucketName = "weak"
		auto.Reason = firstNonEmpty(his.HealthReason, "fallback-weak")
	case known && level == monitoring.HealthLevelBad:
		auto.Bucket = autoCandidateBucketBad
		auto.BucketName = "bad"
		auto.Reason = firstNonEmpty(his.HealthReason, his.LastError, "bad")
	case isCheckingHealth(his):
		auto.Bucket = autoCandidateBucketUnknown
		auto.BucketName = "checking"
		auto.Reason = his.HealthReason
	default:
		auto.Bucket = autoCandidateBucketUnknown
		auto.BucketName = "unknown"
		auto.Reason = firstNonEmpty(his.HealthReason, "candidate-unknown")
	}
	return auto
}

func normalizedQuality(his *adapter.URLTestHistory) (level string, autoAllowed bool, known bool) {
	if his == nil || his.QualityLevel == "" || his.QualityLevel == monitoring.QualityLevelUnknown {
		return monitoring.QualityLevelUnknown, true, false
	}
	return his.QualityLevel, his.AutoAllowed, true
}

func normalizedCombinedHealth(his *adapter.URLTestHistory) (level string, known bool) {
	if his == nil || his.CombinedHealthLevel == "" || his.CombinedHealthLevel == monitoring.HealthLevelUnknown {
		return monitoring.HealthLevelUnknown, false
	}
	return his.CombinedHealthLevel, true
}

func getCombinedHealthScore(his *adapter.URLTestHistory) (score int32, known bool) {
	if his == nil || his.CombinedHealthLevel == "" || his.CombinedHealthLevel == monitoring.HealthLevelUnknown {
		return 0, false
	}
	if his.CombinedHealthScore > 0 {
		return his.CombinedHealthScore, true
	}
	switch his.CombinedHealthLevel {
	case monitoring.HealthLevelExcellent:
		return 90, true
	case monitoring.HealthLevelGood:
		return 75, true
	case monitoring.HealthLevelMedium:
		return 55, true
	case monitoring.HealthLevelWeak:
		return 25, true
	case monitoring.HealthLevelBad:
		return 0, true
	default:
		return 0, false
	}
}

func getQualityScore(his *adapter.URLTestHistory) (score int32, known bool) {
	if his == nil || his.QualityLevel == "" || his.QualityLevel == monitoring.QualityLevelUnknown {
		return 0, false
	}
	if his.QualityScore > 0 {
		return his.QualityScore, true
	}
	switch his.QualityLevel {
	case monitoring.QualityLevelExcellent:
		return 90, true
	case monitoring.QualityLevelGood:
		return 75, true
	case monitoring.QualityLevelMedium:
		return 55, true
	case monitoring.QualityLevelBad:
		return 0, true
	default:
		return 0, false
	}
}

func getSpeedScore(his *adapter.URLTestHistory) (score int32, known bool) {
	if his == nil || his.SpeedLevel == "" || his.SpeedLevel == monitoring.SpeedLevelUnknown {
		return 0, false
	}
	if his.SpeedScore > 0 {
		return his.SpeedScore, true
	}
	switch his.SpeedLevel {
	case monitoring.SpeedLevelFast:
		return 90, true
	case monitoring.SpeedLevelNormal:
		return 75, true
	case monitoring.SpeedLevelSlow:
		return 50, true
	case monitoring.SpeedLevelVerySlow:
		return 25, true
	default:
		return 0, false
	}
}

func getExternalHealthScore(his *adapter.URLTestHistory) (score int32, known bool) {
	if his == nil || his.ExternalHealthLevel == "" || his.ExternalHealthLevel == monitoring.HealthLevelUnknown {
		return 0, false
	}
	if his.ExternalHealthScore > 0 {
		return his.ExternalHealthScore, true
	}
	switch his.ExternalHealthLevel {
	case monitoring.HealthLevelExcellent:
		return 90, true
	case monitoring.HealthLevelGood:
		return 75, true
	case monitoring.HealthLevelMedium:
		return 55, true
	case monitoring.HealthLevelWeak:
		return 25, true
	case monitoring.HealthLevelBad:
		return 0, true
	default:
		return 0, false
	}
}

func isStaleAutoHistory(his *adapter.URLTestHistory, now time.Time) bool {
	if his == nil || his.Time.IsZero() {
		return false
	}
	return now.Sub(his.Time) > autoScoreFreshnessWindow
}

func isCheckingHealth(his *adapter.URLTestHistory) bool {
	if his == nil {
		return false
	}
	switch his.HealthReason {
	case "ping-checking", "quality-checking", "speed-checking":
		return true
	default:
		return false
	}
}

func clampAutoScore(score int32) int32 {
	if score < 0 {
		return 0
	}
	if score > 100 {
		return 100
	}
	return score
}

func maxScore(left int32, right int32) int32 {
	if left > right {
		return left
	}
	return right
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func logBalanceQuality(logger log.ContextLogger, args ...any) {
	if logger == nil {
		monitoring.SafeDiagnosticLog(append([]any{"[BalanceQuality] "}, args...)...)
		return
	}
	message := append([]any{"[BalanceQuality] "}, args...)
	logger.Info(message...)
	monitoring.SafeDiagnosticLog(message...)
}

func logRoundRobinCandidates(logger log.ContextLogger, counts roundRobinCandidateCounts) {
	message := []any{"[RoundRobinCandidates] normal=", counts.normal, " medium=", counts.medium, " weak=", counts.weak, " bad=", counts.bad, " unknown=", counts.unknown}
	if logger != nil {
		logger.Info(message...)
	}
	monitoring.SafeDiagnosticLog(message...)
}

func sameOutboundOrder(left []adapter.Outbound, right []adapter.Outbound) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i].Tag() != right[i].Tag() {
			return false
		}
	}
	return true
}

func getAcceptableIndex(sortedOutbounds map[string][]adapter.Outbound, _ map[string]*adapter.URLTestHistory, _ float64) map[string]int {
	res := map[string]int{}
	for net, outs := range sortedOutbounds {
		if len(outs) == 0 {
			res[net] = -1
			continue
		}
		res[net] = len(outs) - 1
	}
	return res

}

func originalOutboundOrder(outbounds []adapter.Outbound) map[string]int {
	order := make(map[string]int, len(outbounds))
	for i, outbound := range outbounds {
		order[outbound.Tag()] = i
	}
	return order
}

func cloneHistoryMap(history map[string]*adapter.URLTestHistory) map[string]*adapter.URLTestHistory {
	cloned := make(map[string]*adapter.URLTestHistory, len(history))
	for tag, item := range history {
		if item == nil {
			continue
		}
		copied := *item
		cloned[tag] = &copied
	}
	return cloned
}

func tagAtIndex(outbounds []adapter.Outbound, index int) string {
	if index < 0 || index >= len(outbounds) {
		return ""
	}
	return outbounds[index].Tag()
}

func indexOfOutboundTag(outbounds []adapter.Outbound, tag string) (int, bool) {
	for i, outbound := range outbounds {
		if outbound.Tag() == tag {
			return i, true
		}
	}
	return 0, false
}

func containsOutboundTag(outbounds []adapter.Outbound, tag string) bool {
	_, ok := indexOfOutboundTag(outbounds, tag)
	return ok
}

func outboundByTag(outbounds []adapter.Outbound, tag string) adapter.Outbound {
	for _, outbound := range outbounds {
		if outbound.Tag() == tag {
			return outbound
		}
	}
	return nil
}

func getMinDelay(outbounds map[string][]adapter.Outbound, history map[string]*adapter.URLTestHistory) (map[string]adapter.Outbound, map[string]uint16) {
	delays := map[string]uint16{}
	bestOuts := map[string]adapter.Outbound{}
	for net, outs := range outbounds {
		minDelay := monitoring.TimeoutDelay
		var minOut adapter.Outbound
		for _, out := range outs {

			d := getTagDelay(out.Tag(), history)
			if d <= minDelay {
				minDelay = d
				minOut = out
			}
		}
		delays[net] = minDelay
		bestOuts[net] = minOut
	}
	return bestOuts, delays

}

func getDelayMap(history map[string]*adapter.URLTestHistory) map[string]uint16 {
	delayMap := make(map[string]uint16)
	for tag, his := range history {
		if his != nil {
			delayMap[tag] = his.Delay
		} else {
			delayMap[tag] = monitoring.TimeoutDelay
		}
	}

	return delayMap

}
