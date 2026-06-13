package monitoring

import (
	"sort"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

const (
	QualityLevelUnknown   = "unknown"
	QualityLevelBad       = "bad"
	QualityLevelMedium    = "medium"
	QualityLevelGood      = "good"
	QualityLevelExcellent = "excellent"

	SpeedLevelUnknown  = "unknown"
	SpeedLevelVerySlow = "very_slow"
	SpeedLevelSlow     = "slow"
	SpeedLevelNormal   = "normal"
	SpeedLevelFast     = "fast"

	HealthLevelUnknown   = "unknown"
	HealthLevelBad       = "bad"
	HealthLevelWeak      = "weak"
	HealthLevelMedium    = "medium"
	HealthLevelGood      = "good"
	HealthLevelExcellent = "excellent"
)

const runtimeErrorWindow = 15 * time.Minute

type ExternalTargetScore struct {
	Name           string
	Kind           string
	Score          int32
	Level          string
	Weight         float64
	Completed      bool
	Failed         bool
	Reason         string
	PublicDownload bool
	Cloudflare     bool
}

func NormalizeOutboundError(errorText string) string {
	normalized := strings.ToLower(strings.TrimSpace(errorText))
	switch {
	case normalized == "":
		return ""
	case strings.Contains(normalized, "nxdomain"):
		return "NXDOMAIN"
	case strings.Contains(normalized, "connection refused"):
		return "connection refused"
	case strings.Contains(normalized, "authentication handshake failed"):
		return "authentication handshake failed"
	case strings.Contains(normalized, "i/o timeout"):
		return "i/o timeout"
	case strings.Contains(normalized, "context deadline exceeded"):
		return "context deadline exceeded"
	case strings.Contains(normalized, "connection reset by peer"):
		return "connection reset by peer"
	case strings.Contains(normalized, "connection reset"):
		return "connection reset"
	case strings.Contains(normalized, "broken pipe"):
		return "broken pipe"
	case normalized == "eof" || strings.Contains(normalized, ": eof") || strings.Contains(normalized, " eof"):
		return "EOF"
	default:
		return ""
	}
}

func CalculateOutboundQuality(delay uint16, lastError string, urlTestSuccess bool, recentRuntimeErrors []adapter.OutboundRuntimeErrorStats) adapter.OutboundQuality {
	checkedAt := time.Now().Unix()
	normalizedError := NormalizeOutboundError(lastError)
	if delay == 0 && normalizedError == "" && !urlTestSuccess && len(recentRuntimeErrors) == 0 {
		return adapter.OutboundQuality{
			QualityLevel: QualityLevelUnknown,
			AutoAllowed:  true,
			CheckedAt:    checkedAt,
		}
	}

	score := scoreForURLTest(delay, normalizedError, urlTestSuccess)
	score = applyRuntimeErrorPenalties(score, recentRuntimeErrors)
	level := qualityLevel(score)
	return adapter.OutboundQuality{
		QualityScore: score,
		QualityLevel: level,
		AutoAllowed:  level == QualityLevelGood || level == QualityLevelExcellent,
		LastError:    normalizedError,
		CheckedAt:    checkedAt,
	}
}

func CalculateSpeedScore(speedKbps int32, speedError string, durationMs int32) adapter.OutboundSpeed {
	checkedAt := time.Now().Unix()
	if speedKbps <= 0 || NormalizeOutboundError(speedError) != "" || durationMs <= 0 {
		return adapter.OutboundSpeed{
			SpeedLevel:     SpeedLevelUnknown,
			SpeedCheckedAt: checkedAt,
		}
	}

	score := speedScore(speedKbps)
	return adapter.OutboundSpeed{
		SpeedKbps:      speedKbps,
		SpeedScore:     score,
		SpeedLevel:     speedLevel(score),
		SpeedCheckedAt: checkedAt,
	}
}

func CalculateCombinedHealth(qualityScore int32, qualityLevel string, speedScore int32, speedLevel string, autoAllowed bool, lastError string) adapter.OutboundHealth {
	qualityLevel = strings.ToLower(strings.TrimSpace(qualityLevel))
	speedLevel = strings.ToLower(strings.TrimSpace(speedLevel))
	if qualityLevel == "" {
		qualityLevel = QualityLevelUnknown
	}
	if speedLevel == "" {
		speedLevel = SpeedLevelUnknown
	}

	if qualityLevel == QualityLevelBad {
		return adapter.OutboundHealth{
			CombinedHealthScore: clampScore(qualityScore),
			CombinedHealthLevel: HealthLevelBad,
		}
	}
	if qualityLevel == QualityLevelUnknown {
		return adapter.OutboundHealth{
			CombinedHealthLevel: HealthLevelUnknown,
		}
	}
	if speedLevel == SpeedLevelUnknown {
		return adapter.OutboundHealth{
			CombinedHealthLevel: HealthLevelUnknown,
		}
	}

	score := clampScore(minScore(qualityScore, speedScore))
	return adapter.OutboundHealth{
		ExternalHealthScore: speedScore,
		ExternalHealthLevel: externalHealthLevel(speedScore),
		CombinedHealthScore: score,
		CombinedHealthLevel: combinedHealthLevel(score, qualityLevel, speedLevel, lastError),
	}
}

func CalculateExternalHealth(targets []ExternalTargetScore) adapter.OutboundHealth {
	var weighted float64
	var totalWeight float64
	var publicWeighted float64
	var publicTotalWeight float64
	var publicSuccessScores []int32
	var publicFailed int
	var publicVerySlow int
	var cloudflareSuccess bool
	var cloudflareOnly bool
	var capValue int32 = 100
	reason := ""
	for _, target := range targets {
		if !target.Completed || target.Weight <= 0 {
			continue
		}
		score := clampScore(target.Score)
		isPublicDownload := isPublicDownloadTarget(target)
		isCloudflare := isCloudflareTarget(target)
		weighted += float64(score) * target.Weight
		totalWeight += target.Weight
		if isPublicDownload {
			publicTotalWeight += target.Weight
		}
		if target.Failed {
			switch {
			case isPublicDownload:
				publicFailed++
				if publicFailed >= 2 && capValue > 45 {
					capValue = 45
				} else if capValue > 80 {
					capValue = 80
				}
				if reason == "" {
					reason = "public-external-timeout"
				}
			case target.Name == "discord":
				if capValue > 60 {
					capValue = 60
				}
				if reason == "" {
					reason = "discord-timeout"
				}
			case target.Name == "google":
				if capValue > 60 {
					capValue = 60
				}
				if reason == "" {
					reason = "google-timeout"
				}
			}
			continue
		}
		if isCloudflare {
			cloudflareSuccess = true
		}
		if isPublicDownload {
			publicSuccessScores = append(publicSuccessScores, score)
			publicWeighted += float64(score) * target.Weight
			if target.Level == SpeedLevelVerySlow || score < 40 {
				publicVerySlow++
			}
		}
		if isPublicDownload && (target.Level == SpeedLevelVerySlow || score < 40) {
			if publicVerySlow >= 2 && capValue > 45 {
				capValue = 45
			} else if capValue > 50 {
				capValue = 50
			}
			if reason == "" {
				reason = "public-external-slow"
			}
		}
	}
	if totalWeight <= 0 {
		return adapter.OutboundHealth{
			ExternalHealthLevel: HealthLevelUnknown,
			CombinedHealthLevel: HealthLevelUnknown,
			HealthReason:        "external-unknown",
		}
	}
	if len(publicSuccessScores) >= 2 && publicTotalWeight > 0 {
		publicMedian := medianScore(publicSuccessScores)
		weighted = weighted - publicWeighted + float64(publicMedian)*publicTotalWeight
	}
	cloudflareOnly = cloudflareSuccess && len(publicSuccessScores) == 0
	if cloudflareOnly {
		if capValue > 69 {
			capValue = 69
		}
		if reason == "" {
			reason = "cloudflare-only"
		}
	}
	score := clampScore(int32(weighted/totalWeight + 0.5))
	if score > capValue {
		score = capValue
	}
	level := externalHealthLevel(score)
	return adapter.OutboundHealth{
		ExternalHealthScore: score,
		ExternalHealthLevel: level,
		HealthReason:        reason,
	}
}

func isCloudflareTarget(target ExternalTargetScore) bool {
	return target.Cloudflare || target.Name == "cloudflare"
}

func isPublicDownloadTarget(target ExternalTargetScore) bool {
	if target.PublicDownload {
		return true
	}
	if target.Kind != "" && target.Kind != "download" {
		return false
	}
	return target.Name == "external-origin" ||
		strings.HasPrefix(target.Name, "hetzner-") ||
		strings.HasPrefix(target.Name, "ovh-")
}

func medianScore(scores []int32) int32 {
	if len(scores) == 0 {
		return 0
	}
	sorted := append([]int32{}, scores...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}

func CalculateCombinedHealthFromExternal(qualityScore int32, qualityLevel string, autoAllowed bool, lastError string, external adapter.OutboundHealth) adapter.OutboundHealth {
	qualityLevel = strings.ToLower(strings.TrimSpace(qualityLevel))
	if qualityLevel == "" {
		qualityLevel = QualityLevelUnknown
	}
	if qualityLevel == QualityLevelBad {
		return adapter.OutboundHealth{
			ExternalHealthScore: external.ExternalHealthScore,
			ExternalHealthLevel: external.ExternalHealthLevel,
			CombinedHealthScore: clampScore(qualityScore),
			CombinedHealthLevel: HealthLevelBad,
			HealthReason:        firstNonEmpty(NormalizeOutboundError(lastError), external.HealthReason),
		}
	}
	if qualityLevel == QualityLevelUnknown || external.ExternalHealthLevel == "" || external.ExternalHealthLevel == HealthLevelUnknown {
		return adapter.OutboundHealth{
			ExternalHealthScore: external.ExternalHealthScore,
			ExternalHealthLevel: firstNonEmpty(external.ExternalHealthLevel, HealthLevelUnknown),
			CombinedHealthLevel: HealthLevelUnknown,
			HealthReason:        firstNonEmpty(external.HealthReason, "external-unknown"),
		}
	}
	score := clampScore(minScore(qualityScore, external.ExternalHealthScore))
	return adapter.OutboundHealth{
		ExternalHealthScore: external.ExternalHealthScore,
		ExternalHealthLevel: external.ExternalHealthLevel,
		CombinedHealthScore: score,
		CombinedHealthLevel: combinedExternalHealthLevel(score, qualityLevel, external.ExternalHealthLevel),
		HealthReason:        external.HealthReason,
	}
}

func scoreForURLTest(delay uint16, normalizedError string, urlTestSuccess bool) int32 {
	switch normalizedError {
	case "NXDOMAIN", "connection refused":
		return 0
	case "authentication handshake failed", "i/o timeout":
		return 20
	case "context deadline exceeded":
		return 35
	case "connection reset by peer", "connection reset", "EOF", "broken pipe":
		return 45
	}

	if !urlTestSuccess || delay == 0 || delay >= TimeoutDelay {
		return 35
	}

	switch {
	case delay <= 150:
		return 90
	case delay <= 300:
		return 82
	case delay <= 600:
		return 72
	case delay <= 1000:
		return 62
	case delay <= 2000:
		return 52
	default:
		return 42
	}
}

func applyRuntimeErrorPenalties(score int32, recentRuntimeErrors []adapter.OutboundRuntimeErrorStats) int32 {
	for _, stats := range recentRuntimeErrors {
		if stats.Count <= 0 || !isRuntimeErrorFresh(stats) {
			continue
		}
		penalty := runtimeErrorPenalty(stats.ErrorType) * int32(stats.Count)
		score -= penalty
		if capScore, ok := runtimeErrorScoreCap(stats.ErrorType); ok && score > capScore {
			score = capScore
		}
	}
	if score < 0 {
		return 0
	}
	if score > 100 {
		return 100
	}
	return score
}

func isRuntimeErrorFresh(stats adapter.OutboundRuntimeErrorStats) bool {
	if stats.LastSeenAt == 0 {
		return true
	}
	return stats.LastSeenAt >= time.Now().Add(-runtimeErrorWindow).Unix()
}

func runtimeErrorPenalty(errorType string) int32 {
	switch NormalizeOutboundError(errorType) {
	case "NXDOMAIN", "connection refused":
		return 100
	case "authentication handshake failed":
		return 80
	case "i/o timeout":
		return 70
	case "context deadline exceeded":
		return 55
	case "connection reset by peer", "connection reset", "EOF", "broken pipe":
		return 35
	default:
		return 25
	}
}

func runtimeErrorScoreCap(errorType string) (int32, bool) {
	switch NormalizeOutboundError(errorType) {
	case "NXDOMAIN", "connection refused":
		return 0, true
	case "authentication handshake failed":
		return 20, true
	case "i/o timeout":
		return 30, true
	case "context deadline exceeded":
		return 40, true
	case "connection reset by peer", "connection reset", "EOF", "broken pipe":
		return 60, true
	default:
		return 60, true
	}
}

func qualityLevel(score int32) string {
	switch {
	case score >= 85:
		return QualityLevelExcellent
	case score >= 70:
		return QualityLevelGood
	case score >= 40:
		return QualityLevelMedium
	default:
		return QualityLevelBad
	}
}

func speedScore(speedKbps int32) int32 {
	switch {
	case speedKbps >= 20000:
		return 100
	case speedKbps >= 10000:
		return 90
	case speedKbps >= 5000:
		return 75
	case speedKbps >= 1000:
		return 50
	case speedKbps >= 300:
		return 25
	default:
		return 10
	}
}

func speedLevel(score int32) string {
	switch {
	case score >= 90:
		return SpeedLevelFast
	case score >= 70:
		return SpeedLevelNormal
	case score >= 40:
		return SpeedLevelSlow
	case score > 0:
		return SpeedLevelVerySlow
	default:
		return SpeedLevelUnknown
	}
}

func combinedHealthLevel(score int32, qualityLevel string, speedLevel string, lastError string) string {
	if NormalizeOutboundError(lastError) != "" || qualityLevel == QualityLevelBad {
		return HealthLevelBad
	}
	switch speedLevel {
	case SpeedLevelVerySlow:
		return HealthLevelWeak
	case SpeedLevelSlow:
		return HealthLevelMedium
	}
	switch {
	case score >= 85 && qualityLevel == QualityLevelExcellent && speedLevel == SpeedLevelFast:
		return HealthLevelExcellent
	case score >= 70:
		return HealthLevelGood
	case score >= 40:
		return HealthLevelMedium
	default:
		return HealthLevelWeak
	}
}

func externalHealthLevel(score int32) string {
	switch {
	case score >= 85:
		return HealthLevelExcellent
	case score >= 70:
		return HealthLevelGood
	case score >= 40:
		return HealthLevelMedium
	case score > 0:
		return HealthLevelWeak
	default:
		return HealthLevelBad
	}
}

func combinedExternalHealthLevel(score int32, qualityLevel string, externalLevel string) string {
	switch externalLevel {
	case HealthLevelBad:
		return HealthLevelBad
	case HealthLevelWeak:
		return HealthLevelWeak
	case HealthLevelMedium:
		return HealthLevelMedium
	}
	switch {
	case score >= 85 && qualityLevel == QualityLevelExcellent && externalLevel == HealthLevelExcellent:
		return HealthLevelExcellent
	case score >= 70:
		return HealthLevelGood
	case score >= 40:
		return HealthLevelMedium
	default:
		return HealthLevelWeak
	}
}

func reachabilityScore(ttfbMs int32, ok bool) int32 {
	if !ok || ttfbMs <= 0 {
		return 0
	}
	switch {
	case ttfbMs <= 500:
		return 95
	case ttfbMs <= 1000:
		return 85
	case ttfbMs <= 2000:
		return 65
	case ttfbMs <= 4000:
		return 45
	default:
		return 30
	}
}

func minScore(left int32, right int32) int32 {
	if left < right {
		return left
	}
	return right
}

func clampScore(score int32) int32 {
	if score < 0 {
		return 0
	}
	if score > 100 {
		return 100
	}
	return score
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func (m *OutboundMonitoring) RecordRuntimeError(tag string, err error) {
	if m == nil || tag == "" || err == nil {
		return
	}
	errorType := NormalizeOutboundError(err.Error())
	if errorType == "" {
		return
	}
	now := time.Now().Unix()
	m.runtimeErrorsAccess.Lock()
	defer m.runtimeErrorsAccess.Unlock()
	if m.runtimeErrors == nil {
		m.runtimeErrors = make(map[string]map[string]*adapter.OutboundRuntimeErrorStats)
	}
	byType := m.runtimeErrors[tag]
	if byType == nil {
		byType = make(map[string]*adapter.OutboundRuntimeErrorStats)
		m.runtimeErrors[tag] = byType
	}
	stats := byType[errorType]
	if stats == nil {
		stats = &adapter.OutboundRuntimeErrorStats{
			Tag:       tag,
			ErrorType: errorType,
		}
		byType[errorType] = stats
	}
	stats.Count++
	stats.LastSeenAt = now
}

func (m *OutboundMonitoring) recentRuntimeErrorStats(tag string) []adapter.OutboundRuntimeErrorStats {
	if m == nil || tag == "" {
		return nil
	}
	cutoff := time.Now().Add(-runtimeErrorWindow).Unix()
	m.runtimeErrorsAccess.Lock()
	defer m.runtimeErrorsAccess.Unlock()
	byType := m.runtimeErrors[tag]
	if len(byType) == 0 {
		return nil
	}
	stats := make([]adapter.OutboundRuntimeErrorStats, 0, len(byType))
	for errorType, item := range byType {
		if item == nil {
			continue
		}
		if item.LastSeenAt < cutoff {
			delete(byType, errorType)
			continue
		}
		stats = append(stats, *item)
	}
	if len(byType) == 0 {
		delete(m.runtimeErrors, tag)
	}
	return stats
}

func (m *OutboundMonitoring) logRuntimeErrorPenalties(tag string, stats []adapter.OutboundRuntimeErrorStats) {
	if m == nil || len(stats) == 0 {
		return
	}
	for _, item := range stats {
		if item.Count <= 0 || !isRuntimeErrorFresh(item) {
			continue
		}
		penalty := runtimeErrorPenalty(item.ErrorType) * int32(item.Count)
		m.logger.Info("[ServerQualityPenalty] tag=", tag, " error=", NormalizeOutboundError(item.ErrorType), " count=", item.Count, " penalty=", penalty)
	}
}

func applyQualityToHistory(history *adapter.URLTestHistory, quality adapter.OutboundQuality) {
	history.QualityScore = quality.QualityScore
	history.QualityLevel = quality.QualityLevel
	history.AutoAllowed = quality.AutoAllowed
	history.LastError = quality.LastError
	history.CheckedAt = quality.CheckedAt
}

func applySpeedToHistory(history *adapter.URLTestHistory, speed adapter.OutboundSpeed) {
	history.SpeedKbps = speed.SpeedKbps
	history.SpeedScore = speed.SpeedScore
	history.SpeedLevel = speed.SpeedLevel
	history.SpeedSource = speed.SpeedSource
	history.SpeedTestBytes = speed.SpeedTestBytes
	history.SpeedTestDurationMs = speed.SpeedTestDurationMs
	history.SpeedCheckedAt = speed.SpeedCheckedAt
}

func applyCombinedHealthToHistory(history *adapter.URLTestHistory, health adapter.OutboundHealth) {
	history.ExternalHealthScore = health.ExternalHealthScore
	history.ExternalHealthLevel = health.ExternalHealthLevel
	history.CombinedHealthScore = health.CombinedHealthScore
	history.CombinedHealthLevel = health.CombinedHealthLevel
	history.HealthReason = health.HealthReason
}
