package monitoring

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

func TestCalculateOutboundQualityHardFailures(t *testing.T) {
	tests := []struct {
		name  string
		err   string
		score int32
	}{
		{name: "nxdomain", err: "lookup example: NXDOMAIN", score: 0},
		{name: "refused", err: "dial tcp: connection refused", score: 0},
		{name: "auth", err: "authentication handshake failed", score: 20},
		{name: "timeout", err: "i/o timeout", score: 20},
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
