package urltest

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

const (
	ErrorTypeNone               = "none"
	ErrorTypeTimeout            = "timeout"
	ErrorTypeDeadline           = "deadline"
	ErrorTypeReset              = "reset"
	ErrorTypeRefused            = "refused"
	ErrorTypeEOF                = "eof"
	ErrorTypeBrokenPipe         = "broken_pipe"
	ErrorTypeDNSTimeout         = "dns_timeout"
	ErrorTypeTLSHandshakeFailed = "tls_handshake_failed"
	ErrorTypeQUICTimeout        = "quic_timeout"
	ErrorTypeBadStatus          = "bad_status"
	ErrorTypeUnsupportedCurve   = "unsupported_curve"
	ErrorTypeUnknown            = "unknown"
)

const maxErrorTextLength = 240

const RussianServerPolicyPenalty = 15

func ClassifyProbeError(err error) (errorType string, errorText string) {
	if err == nil {
		return ErrorTypeNone, ""
	}

	errorText = shortenErrorText(err.Error())
	lower := strings.ToLower(errorText)

	var netErr net.Error
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return ErrorTypeDeadline, errorText
	case errors.Is(err, io.EOF):
		return ErrorTypeEOF, errorText
	case errors.As(err, &netErr) && netErr.Timeout():
		if strings.Contains(lower, "dns") {
			return ErrorTypeDNSTimeout, errorText
		}
		return ErrorTypeTimeout, errorText
	case strings.Contains(lower, "unsupported curve"):
		return ErrorTypeUnsupportedCurve, errorText
	case strings.Contains(lower, "quic") && strings.Contains(lower, "timeout"):
		return ErrorTypeQUICTimeout, errorText
	case strings.Contains(lower, "dns") && strings.Contains(lower, "timeout"):
		return ErrorTypeDNSTimeout, errorText
	case strings.Contains(lower, "tls handshake failed") || strings.Contains(lower, "tls:"):
		return ErrorTypeTLSHandshakeFailed, errorText
	case strings.Contains(lower, "context deadline exceeded"):
		return ErrorTypeDeadline, errorText
	case strings.Contains(lower, "i/o timeout") || strings.Contains(lower, "timeout"):
		return ErrorTypeTimeout, errorText
	case strings.Contains(lower, "connection reset"):
		return ErrorTypeReset, errorText
	case strings.Contains(lower, "connection refused"):
		return ErrorTypeRefused, errorText
	case strings.Contains(lower, "broken pipe"):
		return ErrorTypeBrokenPipe, errorText
	case lower == "eof" || strings.Contains(lower, ": eof") || strings.Contains(lower, " eof"):
		return ErrorTypeEOF, errorText
	case strings.Contains(lower, "bad status") || strings.Contains(lower, "unexpected status"):
		return ErrorTypeBadStatus, errorText
	default:
		return ErrorTypeUnknown, errorText
	}
}

func CalculateHealthScore(delay uint16, success bool, errorType string, isFromCache bool, updatedAt time.Time, runtimePenalty int) int {
	return CalculateHealthScoreWithUDPPenalty(delay, success, errorType, isFromCache, updatedAt, runtimePenalty, 0)
}

func CalculateHealthScoreWithUDPPenalty(delay uint16, success bool, errorType string, isFromCache bool, updatedAt time.Time, runtimePenalty int, udpPenalty int) int {
	return CalculateHealthScoreWithPenalties(delay, success, errorType, isFromCache, updatedAt, runtimePenalty, udpPenalty, 0)
}

func CalculateHealthScoreWithPenalties(delay uint16, success bool, errorType string, isFromCache bool, updatedAt time.Time, runtimePenalty int, udpPenalty int, policyPenalty int) int {
	score := delayScore(delay)
	freshnessPenalty := CalculateFreshnessPenalty(isFromCache, updatedAt)
	if runtimePenalty < 0 {
		runtimePenalty = 0
	}
	if runtimePenalty > 25 {
		runtimePenalty = 25
	}
	if udpPenalty < 0 {
		udpPenalty = 0
	}
	if udpPenalty > 15 {
		udpPenalty = 15
	}
	if policyPenalty < 0 {
		policyPenalty = 0
	}
	if policyPenalty > 25 {
		policyPenalty = 25
	}

	if !success {
		score = min(score, errorScoreCap(errorType))
	}
	score -= freshnessPenalty + runtimePenalty + udpPenalty + policyPenalty
	return clamp(score, 0, 100)
}

func CalculatePolicyPenalty(tag string, countryCode string) int {
	if isRussianServer(tag, countryCode) {
		return RussianServerPolicyPenalty
	}
	return 0
}

func CalculateFreshnessPenalty(isFromCache bool, updatedAt time.Time) int {
	penalty := 0
	if isFromCache {
		penalty += 10
	}
	if updatedAt.IsZero() {
		return clamp(penalty+20, 0, 30)
	}
	age := time.Since(updatedAt)
	switch {
	case age <= 3*time.Minute:
	case age <= 5*time.Minute:
		penalty += 5
	case age <= 15*time.Minute:
		penalty += 12
	default:
		penalty += 20
	}
	return clamp(penalty, 0, 30)
}

func IsCriticalProbeError(errorType string) bool {
	switch errorType {
	case ErrorTypeTimeout, ErrorTypeDeadline, ErrorTypeDNSTimeout, ErrorTypeTLSHandshakeFailed, ErrorTypeUnsupportedCurve, ErrorTypeQUICTimeout, ErrorTypeRefused:
		return true
	default:
		return false
	}
}

func ShouldApplyRuntimePenalty(errorType string, strict bool) bool {
	switch errorType {
	case ErrorTypeNone, ErrorTypeUnknown, ErrorTypeBadStatus:
		return false
	case ErrorTypeEOF, ErrorTypeRefused:
		return !strict
	default:
		return true
	}
}

func NewURLTestHistory(delay uint16, err error, runtimePenalty int) *adapter.URLTestHistory {
	errorType, errorText := ClassifyProbeError(err)
	success := err == nil && delay > 0 && delay < 65535
	if !success {
		delay = 65535
		if errorType == "" || errorType == ErrorTypeNone {
			errorType = ErrorTypeTimeout
		}
	}
	now := time.Now()
	return &adapter.URLTestHistory{
		Time:             now,
		Delay:            delay,
		Success:          success,
		ErrorType:        errorType,
		ErrorText:        errorText,
		HealthScore:      CalculateHealthScore(delay, success, errorType, false, now, runtimePenalty),
		RuntimePenalty:   runtimePenalty,
		FreshnessPenalty: CalculateFreshnessPenalty(false, now),
	}
}

func isRussianServer(tag string, countryCode string) bool {
	if strings.EqualFold(strings.TrimSpace(countryCode), "RU") {
		return true
	}
	lowerTag := strings.ToLower(tag)
	return strings.Contains(lowerTag, "🇷🇺") ||
		strings.Contains(lowerTag, "россия") ||
		strings.Contains(lowerTag, "russia") ||
		strings.Contains(lowerTag, "russian")
}

func delayScore(delay uint16) int {
	switch {
	case delay == 0 || delay >= 65535:
		return 0
	case delay <= 80:
		return 100
	case delay <= 150:
		return 90
	case delay <= 250:
		return 75
	case delay <= 400:
		return 60
	case delay <= 700:
		return 40
	case delay <= 1000:
		return 25
	default:
		return 10
	}
}

func errorScoreCap(errorType string) int {
	switch errorType {
	case ErrorTypeTimeout, ErrorTypeDeadline, ErrorTypeDNSTimeout, ErrorTypeQUICTimeout:
		return 25
	case ErrorTypeTLSHandshakeFailed:
		return 20
	case ErrorTypeUnsupportedCurve:
		return 15
	case ErrorTypeRefused:
		return 25
	case ErrorTypeReset, ErrorTypeBrokenPipe:
		return 40
	case ErrorTypeEOF:
		return 45
	case ErrorTypeBadStatus:
		return 55
	default:
		return 45
	}
}

func shortenErrorText(text string) string {
	text = strings.TrimSpace(text)
	if len(text) <= maxErrorTextLength {
		return text
	}
	return text[:maxErrorTextLength]
}

func clamp(value, minValue, maxValue int) int {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}
