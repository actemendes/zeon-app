package monitoring

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

func TestCalculateOutboundQualityHardFailures(t *testing.T) {
	tests := []struct {
		name  string
		err   string
		score int32
	}{
		{name: "nxdomain", err: "lookup example: NXDOMAIN", score: 0},
		{name: "refused", err: "dial tcp: connection refused", score: 0},
		{name: "auth", err: "authentication handshake failed", score: 0},
		{name: "timeout", err: "i/o timeout", score: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			quality := CalculateOutboundQuality(TimeoutDelay, tt.err, false, nil)
			if quality.QualityScore != tt.score {
				t.Fatalf("expected score %d, got %d", tt.score, quality.QualityScore)
			}
			if quality.QualityLevel != QualityLevelBad {
				t.Fatalf("expected bad quality, got %s", quality.QualityLevel)
			}
			if quality.AutoAllowed {
				t.Fatal("hard failure must not be auto allowed")
			}
		})
	}
}

func TestCalculateOutboundQualitySuccessAndRuntimePenalty(t *testing.T) {
	good := CalculateOutboundQuality(110, "", true, nil)
	if good.QualityLevel != QualityLevelExcellent || !good.AutoAllowed {
		t.Fatalf("expected excellent auto-allowed quality, got level=%s autoAllowed=%v", good.QualityLevel, good.AutoAllowed)
	}

	bad := CalculateOutboundQuality(35, "", true, []adapter.OutboundRuntimeErrorStats{{
		Tag:       "ServerA",
		ErrorType: "i/o timeout",
		Count:     1,
	}})
	if bad.QualityLevel != QualityLevelBad || bad.AutoAllowed {
		t.Fatalf("expected runtime timeout to demote to bad, got level=%s autoAllowed=%v score=%d", bad.QualityLevel, bad.AutoAllowed, bad.QualityScore)
	}
}

func TestCalculateOutboundQualityRefusedWithLowDelayIsBad(t *testing.T) {
	quality := CalculateOutboundQuality(50, "dial tcp: connection refused", false, nil)
	if quality.QualityScore != 0 || quality.QualityLevel != QualityLevelBad || quality.AutoAllowed {
		t.Fatalf("expected refused to be hard bad, got score=%d level=%s autoAllowed=%v", quality.QualityScore, quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateOutboundQualityTimeoutWithLowDelayIsBad(t *testing.T) {
	quality := CalculateOutboundQuality(35, "i/o timeout", false, nil)
	if quality.QualityScore > 30 || quality.QualityLevel != QualityLevelBad || quality.AutoAllowed {
		t.Fatalf("expected timeout with low delay to remain bad, got score=%d level=%s autoAllowed=%v", quality.QualityScore, quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateOutboundQualityManyRuntimeErrorsCannotBeGood(t *testing.T) {
	quality := CalculateOutboundQuality(45, "", true, []adapter.OutboundRuntimeErrorStats{{
		Tag:        "ServerD",
		ErrorType:  "connection reset by peer",
		Count:      3,
		LastSeenAt: time.Now().Unix(),
	}})
	if quality.QualityLevel == QualityLevelGood || quality.QualityLevel == QualityLevelExcellent || quality.AutoAllowed {
		t.Fatalf("expected repeated runtime errors to prevent good quality, got score=%d level=%s autoAllowed=%v", quality.QualityScore, quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateOutboundQualityHigherDelayWithoutErrorsCanBeGood(t *testing.T) {
	quality := CalculateOutboundQuality(600, "", true, nil)
	if quality.QualityLevel != QualityLevelGood || !quality.AutoAllowed {
		t.Fatalf("expected successful higher delay without errors to be good, got score=%d level=%s autoAllowed=%v", quality.QualityScore, quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateOutboundQualityFailedCheckDoesNotRemainUnknown(t *testing.T) {
	quality := CalculateOutboundQuality(TimeoutDelay, "i/o timeout", false, nil)
	if quality.QualityLevel == QualityLevelUnknown || quality.AutoAllowed {
		t.Fatalf("failed check must not remain unknown/allowed, got level=%s autoAllowed=%v", quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateOutboundQualityIgnoresStaleRuntimeErrors(t *testing.T) {
	quality := CalculateOutboundQuality(110, "", true, []adapter.OutboundRuntimeErrorStats{{
		Tag:        "ServerC",
		ErrorType:  "i/o timeout",
		Count:      1,
		LastSeenAt: time.Now().Add(-runtimeErrorWindow - time.Second).Unix(),
	}})
	if quality.QualityLevel != QualityLevelExcellent || !quality.AutoAllowed {
		t.Fatalf("expected stale runtime error to be ignored, got score=%d level=%s autoAllowed=%v", quality.QualityScore, quality.QualityLevel, quality.AutoAllowed)
	}
}

func TestCalculateSpeedScoreLevels(t *testing.T) {
	tests := []struct {
		name      string
		speedKbps int32
		level     string
		score     int32
	}{
		{name: "fast", speedKbps: 20000, level: SpeedLevelFast, score: 100},
		{name: "normal", speedKbps: 5000, level: SpeedLevelNormal, score: 75},
		{name: "slow", speedKbps: 1000, level: SpeedLevelSlow, score: 50},
		{name: "very slow", speedKbps: 300, level: SpeedLevelVerySlow, score: 25},
		{name: "tiny", speedKbps: 100, level: SpeedLevelVerySlow, score: 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			speed := CalculateSpeedScore(tt.speedKbps, "", 100)
			if speed.SpeedLevel != tt.level || speed.SpeedScore != tt.score {
				t.Fatalf("expected %s/%d, got %s/%d", tt.level, tt.score, speed.SpeedLevel, speed.SpeedScore)
			}
		})
	}
}

func TestCalculateCombinedHealthCapsExcellentBySpeed(t *testing.T) {
	tests := []struct {
		name        string
		speedScore  int32
		speedLevel  string
		healthLevel string
	}{
		{name: "excellent fast", speedScore: 100, speedLevel: SpeedLevelFast, healthLevel: HealthLevelExcellent},
		{name: "excellent normal", speedScore: 75, speedLevel: SpeedLevelNormal, healthLevel: HealthLevelGood},
		{name: "excellent slow", speedScore: 50, speedLevel: SpeedLevelSlow, healthLevel: HealthLevelMedium},
		{name: "excellent very slow", speedScore: 25, speedLevel: SpeedLevelVerySlow, healthLevel: HealthLevelWeak},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			health := CalculateCombinedHealth(90, QualityLevelExcellent, tt.speedScore, tt.speedLevel, true, "")
			if health.CombinedHealthLevel != tt.healthLevel {
				t.Fatalf("expected %s, got %s score=%d", tt.healthLevel, health.CombinedHealthLevel, health.CombinedHealthScore)
			}
		})
	}
}

func TestCalculateCombinedHealthBadQualityWins(t *testing.T) {
	health := CalculateCombinedHealth(20, QualityLevelBad, 100, SpeedLevelFast, false, "i/o timeout")
	if health.CombinedHealthLevel != HealthLevelBad || health.CombinedHealthScore != 20 {
		t.Fatalf("expected bad quality to win, got level=%s score=%d", health.CombinedHealthLevel, health.CombinedHealthScore)
	}
}

func TestCalculateCombinedHealthUnknownSpeedIsNotExcellent(t *testing.T) {
	health := CalculateCombinedHealth(90, QualityLevelExcellent, 0, SpeedLevelUnknown, true, "")
	if health.CombinedHealthLevel != HealthLevelUnknown || health.CombinedHealthScore != 0 {
		t.Fatalf("expected unknown health while speed is unknown, got level=%s score=%d", health.CombinedHealthLevel, health.CombinedHealthScore)
	}
}

func TestCalculateExternalHealthCloudflareFastExternalSlowIsNotExcellent(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.15, Completed: true, Cloudflare: true},
		{Name: "hetzner-fsn1", Kind: "download", Score: 25, Level: SpeedLevelVerySlow, Weight: 0.45, Completed: true, PublicDownload: true},
		{Name: "google", Score: 95, Level: HealthLevelExcellent, Weight: 0.20, Completed: true},
		{Name: "discord", Score: 95, Level: HealthLevelExcellent, Weight: 0.20, Completed: true},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthLevel == HealthLevelExcellent || combined.CombinedHealthLevel == HealthLevelGood {
		t.Fatalf("expected external slow to prevent good/excellent, got level=%s score=%d reason=%s", combined.CombinedHealthLevel, combined.CombinedHealthScore, combined.HealthReason)
	}
	if combined.HealthReason != "public-external-slow" {
		t.Fatalf("expected public-external-slow reason, got %s", combined.HealthReason)
	}
}

func TestCalculateExternalHealthCloudflareOnlyIsNotExcellent(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.40, Completed: true, Cloudflare: true},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthLevel == HealthLevelExcellent || combined.CombinedHealthScore > 69 {
		t.Fatalf("expected Cloudflare-only to be capped below excellent, got level=%s score=%d reason=%s", combined.CombinedHealthLevel, combined.CombinedHealthScore, combined.HealthReason)
	}
	if combined.HealthReason != "cloudflare-only" {
		t.Fatalf("expected cloudflare-only reason, got %s", combined.HealthReason)
	}
}

func TestCalculateExternalHealthPublicTimeoutsAreWeak(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.15, Completed: true, Cloudflare: true},
		{Name: "hetzner-fsn1", Kind: "download", Weight: 0.35, Completed: true, Failed: true, Reason: "timeout", PublicDownload: true},
		{Name: "ovh-gra", Kind: "download", Weight: 0.35, Completed: true, Failed: true, Reason: "timeout", PublicDownload: true},
		{Name: "google", Score: 95, Level: HealthLevelExcellent, Weight: 0.075, Completed: true},
		{Name: "discord", Score: 95, Level: HealthLevelExcellent, Weight: 0.075, Completed: true},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthScore > 45 || combined.CombinedHealthLevel == HealthLevelExcellent || combined.CombinedHealthLevel == HealthLevelGood {
		t.Fatalf("expected repeated public timeouts to cap health at weak/medium, got level=%s score=%d reason=%s", combined.CombinedHealthLevel, combined.CombinedHealthScore, combined.HealthReason)
	}
	if combined.HealthReason != "public-external-timeout" {
		t.Fatalf("expected public-external-timeout reason, got %s", combined.HealthReason)
	}
}

func TestCalculateExternalHealthOnePublicFailureIsNotBad(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.15, Completed: true, Cloudflare: true},
		{Name: "hetzner-fsn1", Kind: "download", Score: 75, Level: SpeedLevelNormal, Weight: 0.35, Completed: true, PublicDownload: true},
		{Name: "ovh-gra", Kind: "download", Weight: 0.35, Completed: true, Failed: true, Reason: "timeout", PublicDownload: true},
		{Name: "google", Score: 95, Level: HealthLevelExcellent, Weight: 0.075, Completed: true},
		{Name: "discord", Score: 95, Level: HealthLevelExcellent, Weight: 0.075, Completed: true},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthLevel == HealthLevelBad || combined.CombinedHealthLevel == HealthLevelWeak {
		t.Fatalf("expected one public failure to degrade but not mark bad/weak, got level=%s score=%d", combined.CombinedHealthLevel, combined.CombinedHealthScore)
	}
}

func TestCalculateExternalHealthDiscordTimeoutCapsHealth(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Score: 100, Level: SpeedLevelFast, Weight: 0.40, Completed: true},
		{Name: "google", Score: 95, Level: HealthLevelExcellent, Weight: 0.30, Completed: true},
		{Name: "discord", Score: 0, Weight: 0.30, Completed: true, Failed: true, Reason: "timeout"},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthScore > 60 || combined.CombinedHealthLevel == HealthLevelExcellent || combined.CombinedHealthLevel == HealthLevelGood {
		t.Fatalf("expected Discord timeout to cap health at medium/weak, got level=%s score=%d", combined.CombinedHealthLevel, combined.CombinedHealthScore)
	}
	if combined.HealthReason != "discord-timeout" {
		t.Fatalf("expected discord-timeout reason, got %s", combined.HealthReason)
	}
}

func TestCalculateExternalHealthAllUnknownIsCompatibilityUnknown(t *testing.T) {
	external := CalculateExternalHealth(nil)
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthLevel != HealthLevelUnknown {
		t.Fatalf("expected unknown external health, got %s", combined.CombinedHealthLevel)
	}
}

func TestCalculateExternalHealthFastTargetsCanBeExcellent(t *testing.T) {
	external := CalculateExternalHealth([]ExternalTargetScore{
		{Name: "cloudflare", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.15, Completed: true, Cloudflare: true},
		{Name: "hetzner-fsn1", Kind: "download", Score: 100, Level: SpeedLevelFast, Weight: 0.35, Completed: true, PublicDownload: true},
		{Name: "ovh-gra", Kind: "download", Score: 90, Level: SpeedLevelFast, Weight: 0.35, Completed: true, PublicDownload: true},
		{Name: "google", Score: 95, Level: HealthLevelExcellent, Weight: 0.20, Completed: true},
		{Name: "discord", Score: 95, Level: HealthLevelExcellent, Weight: 0.20, Completed: true},
	})
	combined := CalculateCombinedHealthFromExternal(90, QualityLevelExcellent, true, "", external)
	if combined.CombinedHealthLevel != HealthLevelExcellent {
		t.Fatalf("expected excellent when external/reachability are good, got level=%s score=%d", combined.CombinedHealthLevel, combined.CombinedHealthScore)
	}
}

func TestRuntimeTrafficErrorsIncreaseLiveFailureCount(t *testing.T) {
	tag := "current"
	storage := urltest.NewHistoryStorage()
	m := &OutboundMonitoring{
		history:       storage,
		outbounds:     map[string]*outboundState{tag: {groupTags: []string{""}}},
		groups:        map[string]*groupState{"": {notifyCh: make(chan struct{}, 1)}},
		runtimeErrors: make(map[string]map[string]*adapter.OutboundRuntimeErrorStats),
	}

	m.RecordRuntimeError(tag, errString("i/o timeout"))
	time.Sleep(50 * time.Millisecond)
	m.RecordRuntimeError(tag, errString("i/o timeout"))
	time.Sleep(50 * time.Millisecond)

	history := storage.LoadURLTestHistory(tag)
	if history == nil {
		t.Fatal("expected stored live history")
	}
	if history.LiveFailureCount < 2 {
		t.Fatalf("expected live failures to increase, got %d", history.LiveFailureCount)
	}
	if history.LiveUsabilityStatus != LiveUsabilityFailed {
		t.Fatalf("expected live failed after repeated runtime errors, got %s", history.LiveUsabilityStatus)
	}
	if history.LiveAvoidUntil == 0 || history.AutoAllowed {
		t.Fatalf("expected temporary avoid and auto disallow, avoidUntil=%d autoAllowed=%v", history.LiveAvoidUntil, history.AutoAllowed)
	}
}

func TestUnknownRuntimeTrafficErrorDoesNotPenalizeRandomServer(t *testing.T) {
	tag := "known"
	storage := urltest.NewHistoryStorage()
	m := &OutboundMonitoring{
		history:       storage,
		outbounds:     map[string]*outboundState{tag: {groupTags: []string{""}}},
		groups:        map[string]*groupState{"": {notifyCh: make(chan struct{}, 1)}},
		runtimeErrors: make(map[string]map[string]*adapter.OutboundRuntimeErrorStats),
	}

	m.RecordRuntimeError("", errString("i/o timeout"))
	m.RecordRuntimeError("missing", errString("i/o timeout"))
	time.Sleep(50 * time.Millisecond)

	if history := storage.LoadURLTestHistory(tag); history != nil && history.LiveFailureCount != 0 {
		t.Fatalf("known server should not be penalized by unknown tag, got failures=%d", history.LiveFailureCount)
	}
}

type errString string

func (e errString) Error() string {
	return string(e)
}
