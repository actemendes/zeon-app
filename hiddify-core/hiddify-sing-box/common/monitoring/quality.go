package monitoring

import (
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
)

const runtimeErrorWindow = 15 * time.Minute

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
