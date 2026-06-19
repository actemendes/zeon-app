package urltest

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestClassifyProbeError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "none", err: nil, want: ErrorTypeNone},
		{name: "deadline", err: context.DeadlineExceeded, want: ErrorTypeDeadline},
		{name: "timeout", err: errors.New("dial tcp: i/o timeout"), want: ErrorTypeTimeout},
		{name: "reset", err: errors.New("read: connection reset by peer"), want: ErrorTypeReset},
		{name: "refused", err: errors.New("connect: connection refused"), want: ErrorTypeRefused},
		{name: "eof", err: errors.New("EOF"), want: ErrorTypeEOF},
		{name: "broken pipe", err: errors.New("write: broken pipe"), want: ErrorTypeBrokenPipe},
		{name: "dns timeout", err: errors.New("DNS lookup timeout"), want: ErrorTypeDNSTimeout},
		{name: "tls", err: errors.New("tls: handshake failure"), want: ErrorTypeTLSHandshakeFailed},
		{name: "unsupported curve", err: errors.New("tls: CurvePreferences includes unsupported curve"), want: ErrorTypeUnsupportedCurve},
		{name: "quic timeout", err: errors.New("quic open timeout"), want: ErrorTypeQUICTimeout},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, _ := ClassifyProbeError(tt.err)
			if got != tt.want {
				t.Fatalf("ClassifyProbeError() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHealthScorePrefersStableServer(t *testing.T) {
	now := time.Now()
	stable := CalculateHealthScore(90, true, ErrorTypeNone, false, now, 0)
	timeout := CalculateHealthScore(40, false, ErrorTypeTimeout, false, now, 0)
	reset := CalculateHealthScore(40, false, ErrorTypeReset, false, now, 0)
	tlsFailed := CalculateHealthScore(40, false, ErrorTypeTLSHandshakeFailed, false, now, 0)

	for name, score := range map[string]int{
		"timeout":    timeout,
		"reset":      reset,
		"tls_failed": tlsFailed,
	} {
		if stable <= score {
			t.Fatalf("stable score %d should be greater than %s score %d", stable, name, score)
		}
	}
}

func TestHealthScoreAppliesSoftUDPPenalty(t *testing.T) {
	now := time.Now()
	withoutUDP := CalculateHealthScoreWithUDPPenalty(90, true, ErrorTypeNone, false, now, 0, 0)
	withUDP := CalculateHealthScoreWithUDPPenalty(90, true, ErrorTypeNone, false, now, 0, 15)

	if withoutUDP-withUDP != 15 {
		t.Fatalf("expected UDP penalty to reduce score softly by 15, got %d -> %d", withoutUDP, withUDP)
	}
	if withUDP <= CalculateHealthScoreWithUDPPenalty(40, false, ErrorTypeTimeout, false, now, 0, 0) {
		t.Fatalf("successful server with UDP penalty should still beat timeout server")
	}
}

func TestCalculateUDPPenaltyIsCapped(t *testing.T) {
	if penalty := CalculateUDPPenalty(100, 200); penalty != 15 {
		t.Fatalf("expected capped penalty 15, got %d", penalty)
	}
	if penalty := CalculateUDPPenalty(0, 10); penalty != 0 {
		t.Fatalf("expected clean UDP route penalty 0, got %d", penalty)
	}
}

func TestFreshnessAndRuntimePenaltiesAreBounded(t *testing.T) {
	old := time.Now().Add(-30 * time.Minute)
	score := CalculateHealthScore(70, true, ErrorTypeNone, true, old, 100)
	if score < 0 || score > 100 {
		t.Fatalf("score = %d, want 0..100", score)
	}
	if score >= CalculateHealthScore(70, true, ErrorTypeNone, false, time.Now(), 0) {
		t.Fatalf("stale cached score should be lower than fresh score")
	}
}
