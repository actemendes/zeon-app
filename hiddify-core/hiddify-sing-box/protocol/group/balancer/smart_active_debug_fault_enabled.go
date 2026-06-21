//go:build smart_active_debug

package balancer

import (
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
)

type smartActiveDebugFault struct {
	targetActive     string
	forceStatus      string
	forceError       string
	forceDegradation int
	runtimePenalty   int
	realUserPenalty  int
	forceCandidate   string
	candidateScore   int
}

func newSmartActiveDebugFault(options option.BalancerOutboundOptions) smartActiveHistoryFault {
	fault := &smartActiveDebugFault{
		forceStatus:      strings.ToUpper(strings.TrimSpace(options.SmartActiveDebugForceStatus)),
		forceError:       strings.ToLower(strings.TrimSpace(options.SmartActiveDebugForceError)),
		forceDegradation: options.SmartActiveDebugForceDegradation,
		runtimePenalty:   options.SmartActiveDebugRuntimePenalty,
		realUserPenalty:  options.SmartActiveDebugRealUserPenalty,
		forceCandidate:   strings.TrimSpace(options.SmartActiveDebugForceCandidate),
		candidateScore:   options.SmartActiveDebugCandidateScore,
	}
	if fault.empty() {
		return nil
	}
	return fault
}

func (f *smartActiveDebugFault) empty() bool {
	return f.forceStatus == "" && f.forceError == "" && f.forceDegradation == 0 &&
		f.runtimePenalty == 0 && f.realUserPenalty == 0 && f.forceCandidate == "" && f.candidateScore == 0
}

func (f *smartActiveDebugFault) Apply(activeTag string, history map[string]*adapter.URLTestHistory) bool {
	if f.targetActive == "" {
		f.targetActive = activeTag
	}
	activeHistory, ok := history[f.targetActive]
	if !ok || activeHistory == nil {
		return false
	}
	changed := false
	if f.forceStatus != "" {
		if applyForcedStatus(activeHistory, f.forceStatus) {
			changed = true
		}
	}
	if f.forceError != "" && isDebugProbeError(f.forceError) {
		applyForcedError(activeHistory, f.forceError)
		changed = true
	}
	if f.forceDegradation > 0 {
		activeHistory.DegradationPoints = f.forceDegradation
		changed = true
	}
	if f.runtimePenalty > 0 {
		activeHistory.RuntimePenalty = f.runtimePenalty
		changed = true
	}
	if f.realUserPenalty > 0 {
		activeHistory.RealUserPenalty = f.realUserPenalty
		changed = true
	}
	if f.forceCandidate != "" && f.forceCandidate != f.targetActive {
		if candidateHistory, ok := history[f.forceCandidate]; ok && candidateHistory != nil {
			makeHealthy(candidateHistory)
			if f.candidateScore > 0 {
				setSyntheticScore(candidateHistory, f.candidateScore)
			}
			changed = true
		}
	}
	// Report the injection only while its original target is the active server.
	// The old target remains quarantined after a switch, without log spam that
	// could misleadingly name the newly active server.
	return changed && activeTag == f.targetActive
}

func applyForcedStatus(history *adapter.URLTestHistory, status string) bool {
	switch status {
	case "GOOD":
		makeHealthy(history)
		return true
	case "SUSPECT":
		makeHealthy(history)
		history.DegradationPoints = 12
	case "DEGRADED":
		makeHealthy(history)
		history.DegradationPoints = 35
		history.RuntimePenalty = 20
	case "BAD":
		makeHealthy(history)
		applyForcedError(history, urltest.ErrorTypeReset)
		history.DegradationPoints = 55
	case "CRITICAL":
		makeHealthy(history)
		applyForcedError(history, urltest.ErrorTypeTimeout)
	default:
		return false
	}
	return true
}

func applyForcedError(history *adapter.URLTestHistory, errorType string) {
	history.Success = false
	history.ErrorType = errorType
	history.ErrorText = "smart_active_debug fault injection"
	history.URLTestStatus = urltest.StatusFailed
	history.Delay = 65535
	history.Time = time.Now()
	history.DegradationPoints = max(history.DegradationPoints, debugErrorDegradation(errorType))
	history.RuntimePenalty = max(history.RuntimePenalty, debugErrorRuntimePenalty(errorType))
}

func debugErrorDegradation(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 5
	case urltest.ErrorTypeReset:
		return 10
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline:
		return 16
	default:
		return 28
	}
}

func debugErrorRuntimePenalty(errorType string) int {
	switch errorType {
	case urltest.ErrorTypeEOF:
		return 2
	case urltest.ErrorTypeRefused:
		return 4
	case urltest.ErrorTypeReset:
		return 5
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeQUICTimeout:
		return 7
	default:
		return 8
	}
}

func makeHealthy(history *adapter.URLTestHistory) {
	history.Time = time.Now()
	history.Delay = 80
	history.IsFromCache = false
	history.Success = true
	history.ErrorType = urltest.ErrorTypeNone
	history.ErrorText = ""
	history.URLTestStatus = urltest.StatusSuccess
	history.RuntimePenalty = 0
	history.RealUserPenalty = 0
	history.FreshnessPenalty = 0
	history.VolatilityPenalty = 0
	history.DegradationPoints = 0
	history.PolicyPenalty = 0
	history.UDPPenalty = 0
	history.StabilityPoints = 40
}

// setSyntheticScore makes the normal health-score function produce the
// requested score without introducing a special decision-path override.
func setSyntheticScore(history *adapter.URLTestHistory, score int) {
	if score < 1 {
		score = 1
	}
	if score > 100 {
		score = 100
	}
	baseScore := 100
	switch {
	case score >= 90:
		history.Delay = 80
	case score >= 75:
		baseScore = 90
		history.Delay = 90
	case score >= 60:
		baseScore = 75
		history.Delay = 200
	case score >= 40:
		baseScore = 60
		history.Delay = 350
	case score >= 25:
		baseScore = 40
		history.Delay = 600
	case score >= 10:
		baseScore = 25
		history.Delay = 900
	default:
		baseScore = 10
		history.Delay = 1200
	}
	penalty := baseScore - score
	applyPenalty := func(target *int, maximum int) {
		value := penalty
		if value > maximum {
			value = maximum
		}
		*target = value
		penalty -= value
	}
	applyPenalty(&history.RuntimePenalty, 14)
	applyPenalty(&history.RealUserPenalty, 14)
	applyPenalty(&history.VolatilityPenalty, 14)
	applyPenalty(&history.UDPPenalty, 15)
	applyPenalty(&history.PolicyPenalty, 25)
}

func isDebugProbeError(errorType string) bool {
	switch errorType {
	case urltest.ErrorTypeTimeout, urltest.ErrorTypeDeadline, urltest.ErrorTypeRefused,
		urltest.ErrorTypeReset, urltest.ErrorTypeEOF, urltest.ErrorTypeDNSTimeout,
		urltest.ErrorTypeTLSHandshakeFailed, urltest.ErrorTypeQUICTimeout:
		return true
	default:
		return false
	}
}
