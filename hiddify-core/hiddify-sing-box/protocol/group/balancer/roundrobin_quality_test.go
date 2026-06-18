package balancer

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type qualityTestOutbound struct {
	tag string
}

func (o qualityTestOutbound) Type() string           { return "test" }
func (o qualityTestOutbound) Tag() string            { return o.tag }
func (o qualityTestOutbound) Network() []string      { return []string{N.NetworkTCP, N.NetworkUDP} }
func (o qualityTestOutbound) Dependencies() []string { return nil }
func (o qualityTestOutbound) DisplayType() string    { return "test" }
func (o qualityTestOutbound) IsReady() bool          { return true }
func (o qualityTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, nil
}
func (o qualityTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, nil
}

func TestRoundRobinQualityFilterPrefersGoodOverLowDelayBad(t *testing.T) {
	badLowDelay := qualityTestOutbound{tag: "ServerA"}
	goodHigherDelay := qualityTestOutbound{tag: "ServerB"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {badLowDelay, goodHigherDelay},
	}
	history := map[string]*adapter.URLTestHistory{
		"ServerA": {
			Delay:        35,
			QualityScore: 20,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
			LastError:    "i/o timeout",
		},
		"ServerB": {
			Delay:        110,
			QualityScore: 90,
			QualityLevel: monitoring.QualityLevelExcellent,
			AutoAllowed:  true,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one good candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "ServerB" {
		t.Fatalf("expected good server to win, got %s", got)
	}
}

func TestRoundRobinNowReportsCurrentHealthSortedCandidate(t *testing.T) {
	lowPingLowerHealth := qualityTestOutbound{tag: "low-ping-lower-health"}
	higherPingBetterHealth := qualityTestOutbound{tag: "higher-ping-better-health"}
	strategy := NewRoundRobin(
		[]adapter.Outbound{lowPingLowerHealth, higherPingBetterHealth},
		option.BalancerOutboundOptions{DelayAcceptableRatio: 10},
		nil,
	)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"low-ping-lower-health": {
			Delay:               29,
			QualityScore:        80,
			QualityLevel:        monitoring.QualityLevelGood,
			AutoAllowed:         true,
			CombinedHealthScore: 61,
			CombinedHealthLevel: monitoring.HealthLevelMedium,
		},
		"higher-ping-better-health": {
			Delay:               45,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 80,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	})

	if got := strategy.Now(); got != "higher-ping-better-health" {
		t.Fatalf("expected current candidate to be better combined health tag, got %s", got)
	}
}

func TestRoundRobinQualityFilterUsesMediumFallback(t *testing.T) {
	bad := qualityTestOutbound{tag: "bad"}
	medium := qualityTestOutbound{tag: "medium"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {bad, medium},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad": {
			Delay:        30,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
		"medium": {
			Delay:        700,
			QualityLevel: monitoring.QualityLevelMedium,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := filtered[N.NetworkTCP][0].Tag(); got != "medium" {
		t.Fatalf("expected medium fallback, got %s", got)
	}
}

func TestRoundRobinQualityFilterUsesUnknownCompatibilityWithoutKnownBad(t *testing.T) {
	bad := qualityTestOutbound{tag: "bad"}
	unknown := qualityTestOutbound{tag: "unknown"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {bad, unknown},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad": {
			Delay:        30,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected unknown fallback to exclude known bad, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "unknown" {
		t.Fatalf("expected unknown candidate, got %s", got)
	}
}

func TestRoundRobinQualityFilterEmergencyFallbackOnlyWhenNoUsableCandidates(t *testing.T) {
	badA := qualityTestOutbound{tag: "bad-a"}
	badB := qualityTestOutbound{tag: "bad-b"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {badA, badB},
	}
	history := map[string]*adapter.URLTestHistory{
		"bad-a": {
			Delay:        35,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
		"bad-b": {
			Delay:        50,
			QualityLevel: monitoring.QualityLevelBad,
			AutoAllowed:  false,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 2 {
		t.Fatalf("expected emergency fallback to retain all original candidates, got %d", got)
	}
}

func TestRoundRobinHealthFilterExcludesVerySlowWhenGoodExists(t *testing.T) {
	verySlow := qualityTestOutbound{tag: "very-slow"}
	normal := qualityTestOutbound{tag: "normal"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {verySlow, normal},
	}
	history := map[string]*adapter.URLTestHistory{
		"very-slow": {
			Delay:               35,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedScore:          25,
			SpeedLevel:          monitoring.SpeedLevelVerySlow,
			CombinedHealthScore: 25,
			CombinedHealthLevel: monitoring.HealthLevelWeak,
		},
		"normal": {
			Delay:               110,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedScore:          75,
			SpeedLevel:          monitoring.SpeedLevelNormal,
			CombinedHealthScore: 75,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one healthy candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "normal" {
		t.Fatalf("expected normal speed server, got %s", got)
	}
}

func TestRoundRobinHealthFilterUsesQualityFallbackWhenSpeedUnknown(t *testing.T) {
	unknownSpeed := qualityTestOutbound{tag: "unknown-speed"}
	bad := qualityTestOutbound{tag: "bad"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {unknownSpeed, bad},
	}
	history := map[string]*adapter.URLTestHistory{
		"unknown-speed": {
			Delay:        90,
			QualityScore: 90,
			QualityLevel: monitoring.QualityLevelExcellent,
			AutoAllowed:  true,
			SpeedLevel:   monitoring.SpeedLevelUnknown,
		},
		"bad": {
			Delay:               30,
			QualityScore:        20,
			QualityLevel:        monitoring.QualityLevelBad,
			AutoAllowed:         false,
			CombinedHealthLevel: monitoring.HealthLevelBad,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected quality-only compatibility candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "unknown-speed" {
		t.Fatalf("expected unknown speed quality fallback, got %s", got)
	}
}

func TestRoundRobinExternalHealthExcludesCloudflareFastDiscordBad(t *testing.T) {
	russiaLike := qualityTestOutbound{tag: "ru-fast-cdn-bad-discord"}
	stable := qualityTestOutbound{tag: "stable-external"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {russiaLike, stable},
	}
	history := map[string]*adapter.URLTestHistory{
		"ru-fast-cdn-bad-discord": {
			Delay:               28,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedKbps:           20000,
			SpeedScore:          100,
			SpeedLevel:          monitoring.SpeedLevelFast,
			SpeedSource:         "cloudflare",
			ExternalHealthScore: 35,
			ExternalHealthLevel: monitoring.HealthLevelWeak,
			CombinedHealthScore: 35,
			CombinedHealthLevel: monitoring.HealthLevelWeak,
			HealthReason:        "discord-timeout",
		},
		"stable-external": {
			Delay:               110,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedKbps:           8000,
			SpeedScore:          75,
			SpeedLevel:          monitoring.SpeedLevelNormal,
			SpeedSource:         "external-origin",
			ExternalHealthScore: 75,
			ExternalHealthLevel: monitoring.HealthLevelGood,
			CombinedHealthScore: 75,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected one external-healthy candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "stable-external" {
		t.Fatalf("expected stable external server to win, got %s", got)
	}
}

func TestRoundRobinSortsCombinedHealthBeforeDelay(t *testing.T) {
	lowPingLowerHealth := qualityTestOutbound{tag: "low-ping-lower-health"}
	higherPingBetterHealth := qualityTestOutbound{tag: "higher-ping-better-health"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {lowPingLowerHealth, higherPingBetterHealth},
	}
	history := map[string]*adapter.URLTestHistory{
		"low-ping-lower-health": {
			Delay:               25,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 70,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
		"higher-ping-better-health": {
			Delay:               55,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 90,
			CombinedHealthLevel: monitoring.HealthLevelExcellent,
		},
	}

	sorted := sortOutboundsByHealthThenDelay(outbounds, history)
	if got := sorted[N.NetworkTCP][0].Tag(); got != "higher-ping-better-health" {
		t.Fatalf("expected better combined health to sort before lower ping, got %s", got)
	}
}

func TestRoundRobinSortKeepsCheckingBelowReadyAndAboveBad(t *testing.T) {
	ready := qualityTestOutbound{tag: "ready-good"}
	checking := qualityTestOutbound{tag: "checking"}
	bad := qualityTestOutbound{tag: "bad"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {checking, bad, ready},
	}
	history := map[string]*adapter.URLTestHistory{
		"ready-good": {
			Delay:               120,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthScore: 82,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
		"checking": {
			Delay:               45,
			QualityScore:        95,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			CombinedHealthLevel: monitoring.HealthLevelUnknown,
			HealthReason:        "speed-checking",
		},
		"bad": {
			Delay:               30,
			QualityScore:        0,
			QualityLevel:        monitoring.QualityLevelBad,
			AutoAllowed:         false,
			CombinedHealthLevel: monitoring.HealthLevelBad,
		},
	}

	sorted := sortOutboundsByHealthThenDelay(outbounds, history)
	got := []string{sorted[N.NetworkTCP][0].Tag(), sorted[N.NetworkTCP][1].Tag(), sorted[N.NetworkTCP][2].Tag()}
	want := []string{"ready-good", "checking", "bad"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("expected order %v, got %v", want, got)
		}
	}
}

func TestRoundRobinQualityFilterExcludesCloudflareOnlyMediumWhenGoodPublicExists(t *testing.T) {
	cloudflareOnly := qualityTestOutbound{tag: "cloudflare-only"}
	publicGood := qualityTestOutbound{tag: "public-good"}
	outbounds := map[string][]adapter.Outbound{
		N.NetworkTCP: {cloudflareOnly, publicGood},
	}
	history := map[string]*adapter.URLTestHistory{
		"cloudflare-only": {
			Delay:               25,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedSource:         "cloudflare",
			ExternalHealthScore: 69,
			ExternalHealthLevel: monitoring.HealthLevelMedium,
			CombinedHealthScore: 69,
			CombinedHealthLevel: monitoring.HealthLevelMedium,
			HealthReason:        "cloudflare-only",
		},
		"public-good": {
			Delay:               80,
			QualityScore:        90,
			QualityLevel:        monitoring.QualityLevelExcellent,
			AutoAllowed:         true,
			SpeedSource:         "hetzner-fsn1",
			ExternalHealthScore: 80,
			ExternalHealthLevel: monitoring.HealthLevelGood,
			CombinedHealthScore: 80,
			CombinedHealthLevel: monitoring.HealthLevelGood,
		},
	}

	filtered := filterRoundRobinOutboundsByQuality(outbounds, history, nil)
	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected only public-good normal candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != "public-good" {
		t.Fatalf("expected public-good candidate, got %s", got)
	}
}

func TestRoundRobinKeepsCurrentGoodBeforeMinDwell(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-good"}
	best := qualityTestOutbound{tag: "best-excellent"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(80, monitoring.HealthLevelGood, 80, 75, 120),
		best.Tag():    rrHistory(95, monitoring.HealthLevelExcellent, 95, 90, 90),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-90 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != current.Tag() {
		t.Fatalf("expected current good server before min dwell, got %s", got)
	}
}

func TestRoundRobinKeepsCurrentGoodWhenScoreDiffSmall(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-good"}
	best := qualityTestOutbound{tag: "slightly-better"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(80, monitoring.HealthLevelGood, 80, 75, 120),
		best.Tag():    rrHistory(84, monitoring.HealthLevelGood, 84, 75, 90),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-180 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != current.Tag() {
		t.Fatalf("expected current server when score diff is small, got %s", got)
	}
}

func TestRoundRobinSwitchesAfterDwellWhenBestMuchBetter(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-good"}
	best := qualityTestOutbound{tag: "much-better"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(75, monitoring.HealthLevelGood, 75, 75, 120),
		best.Tag():    rrHistory(92, monitoring.HealthLevelExcellent, 92, 90, 90),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-130 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != best.Tag() {
		t.Fatalf("expected switch to much better server after dwell, got %s", got)
	}
}

func TestRoundRobinSwitchesWhenCurrentWorseByAllMetricsAfterCooldown(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-low-ping-lower-health"}
	best := qualityTestOutbound{tag: "best-higher-ping-better-health"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(69, monitoring.HealthLevelMedium, 69, 56, 51),
		best.Tag():    rrHistory(83, monitoring.HealthLevelGood, 83, 90, 68),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-roundRobinSwitchCooldown)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != best.Tag() {
		t.Fatalf("expected switch to best when current is worse by all health metrics after cooldown, got %s", got)
	}
}

func TestRoundRobinSwitchesImmediatelyWhenCurrentBad(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-bad"}
	best := qualityTestOutbound{tag: "best-good"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(10, monitoring.HealthLevelBad, 10, 10, 40),
		best.Tag():    rrHistory(75, monitoring.HealthLevelGood, 75, 75, 120),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-5 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != best.Tag() {
		t.Fatalf("expected immediate switch away from bad server, got %s", got)
	}
}

func TestRoundRobinSwitchesImmediatelyWhenCurrentLiveFailed(t *testing.T) {
	now := time.Now()
	current := qualityTestOutbound{tag: "current-live-failed"}
	best := qualityTestOutbound{tag: "best-good"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	currentHistory := rrHistory(80, monitoring.HealthLevelGood, 90, 80, 80)
	currentHistory.LiveUsabilityStatus = monitoring.LiveUsabilityFailed
	currentHistory.LiveAvoidUntil = now.Add(10 * time.Minute).Unix()
	currentHistory.HealthReason = "live-usability-failed"
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): currentHistory,
		best.Tag():    rrHistory(75, monitoring.HealthLevelGood, 80, 75, 120),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-5 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != best.Tag() {
		t.Fatalf("expected immediate switch away from live failed server, got %s", got)
	}
}

func TestRoundRobinLiveFailedServerTemporarilyExcluded(t *testing.T) {
	now := time.Now()
	failed := qualityTestOutbound{tag: "paper-good-live-failed"}
	good := qualityTestOutbound{tag: "good"}
	outbounds := map[string][]adapter.Outbound{N.NetworkTCP: {failed, good}}
	failedHistory := rrHistory(90, monitoring.HealthLevelExcellent, 90, 90, 40)
	failedHistory.LiveUsabilityStatus = monitoring.LiveUsabilityFailed
	failedHistory.LiveAvoidUntil = now.Add(10 * time.Minute).Unix()
	failedHistory.HealthReason = "live-usability-failed"
	filtered := filterRoundRobinOutboundsByQuality(outbounds, map[string]*adapter.URLTestHistory{
		failed.Tag(): failedHistory,
		good.Tag():   rrHistory(75, monitoring.HealthLevelGood, 75, 75, 120),
	}, nil)

	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected live failed server excluded from auto candidates, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != good.Tag() {
		t.Fatalf("expected good server after live failed exclusion, got %s", got)
	}
	if !containsOutboundTag(outbounds[N.NetworkTCP], failed.Tag()) {
		t.Fatal("live failed server must remain available for manual selection")
	}
}

func TestRoundRobinSwitchesMediumToGoodAfterThreshold(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := qualityTestOutbound{tag: "current-medium"}
	best := qualityTestOutbound{tag: "best-good"}
	strategy := newRoundRobinForAntiFlapTest(now, current, best)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		current.Tag(): rrHistory(55, monitoring.HealthLevelMedium, 72, 50, 160),
		best.Tag():    rrHistory(75, monitoring.HealthLevelGood, 80, 75, 120),
	})
	strategy.currentTag[N.NetworkTCP] = current.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-5 * time.Second)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != best.Tag() {
		t.Fatalf("expected medium server to switch to good after threshold, got %s", got)
	}
}

func TestRoundRobinCandidateOrderStableAfterMinorScoreChanges(t *testing.T) {
	a := qualityTestOutbound{tag: "a"}
	b := qualityTestOutbound{tag: "b"}
	c := qualityTestOutbound{tag: "c"}
	outbounds := map[string][]adapter.Outbound{N.NetworkTCP: {a, b, c}}
	first := sortOutboundsByHealthThenDelay(outbounds, map[string]*adapter.URLTestHistory{
		a.Tag(): rrHistory(82, monitoring.HealthLevelGood, 82, 75, 120),
		b.Tag(): rrHistory(80, monitoring.HealthLevelGood, 80, 75, 120),
		c.Tag(): rrHistory(80, monitoring.HealthLevelGood, 80, 75, 120),
	})
	second := sortOutboundsByHealthThenDelay(outbounds, map[string]*adapter.URLTestHistory{
		a.Tag(): rrHistory(82, monitoring.HealthLevelGood, 82, 75, 120),
		b.Tag(): rrHistory(81, monitoring.HealthLevelGood, 81, 75, 120),
		c.Tag(): rrHistory(80, monitoring.HealthLevelGood, 80, 75, 120),
	})

	if !sameOutboundOrder(first[N.NetworkTCP], second[N.NetworkTCP]) {
		t.Fatalf("expected minor score update to preserve candidate order")
	}
}

func TestRoundRobinKeepsCurrentInsteadOfRotatingToWorseCandidate(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	a := qualityTestOutbound{tag: "a"}
	b := qualityTestOutbound{tag: "b"}
	c := qualityTestOutbound{tag: "c"}
	strategy := newRoundRobinForAntiFlapTest(now, a, b, c)
	history := map[string]*adapter.URLTestHistory{
		a.Tag(): rrHistory(90, monitoring.HealthLevelExcellent, 90, 90, 100),
		b.Tag(): rrHistory(88, monitoring.HealthLevelExcellent, 88, 90, 110),
		c.Tag(): rrHistory(86, monitoring.HealthLevelExcellent, 86, 90, 120),
	}
	strategy.UpdateOutboundsInfo(history)
	strategy.currentTag[N.NetworkTCP] = b.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-roundRobinPreferredDwellTime)

	if got := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag(); got != b.Tag() {
		t.Fatalf("expected current b to stay because it is close to best and better than c, got %s", got)
	}
	history[c.Tag()] = rrHistory(87, monitoring.HealthLevelExcellent, 87, 90, 120)
	strategy.UpdateOutboundsInfo(history)
	if got := strategy.Now(); got != b.Tag() {
		t.Fatalf("expected current tag to survive monitoring update, got %s", got)
	}
}

func TestRoundRobinWeakAndBadNotInNormalRotation(t *testing.T) {
	weak := qualityTestOutbound{tag: "weak"}
	bad := qualityTestOutbound{tag: "bad"}
	good := qualityTestOutbound{tag: "good"}
	outbounds := map[string][]adapter.Outbound{N.NetworkTCP: {weak, bad, good}}
	filtered := filterRoundRobinOutboundsByQuality(outbounds, map[string]*adapter.URLTestHistory{
		weak.Tag(): rrHistory(25, monitoring.HealthLevelWeak, 90, 25, 80),
		bad.Tag():  rrHistory(0, monitoring.HealthLevelBad, 0, 0, 40),
		good.Tag(): rrHistory(75, monitoring.HealthLevelGood, 75, 75, 120),
	}, nil)

	if got := len(filtered[N.NetworkTCP]); got != 1 {
		t.Fatalf("expected only good normal candidate, got %d", got)
	}
	if got := filtered[N.NetworkTCP][0].Tag(); got != good.Tag() {
		t.Fatalf("expected weak/bad excluded from normal rotation, got %s", got)
	}
}

func TestRoundRobinUnknownOnlyStartupCompatibilityFallback(t *testing.T) {
	a := qualityTestOutbound{tag: "unknown-a"}
	b := qualityTestOutbound{tag: "unknown-b"}
	outbounds := map[string][]adapter.Outbound{N.NetworkTCP: {a, b}}
	filtered := filterRoundRobinOutboundsByQuality(outbounds, map[string]*adapter.URLTestHistory{}, nil)

	if got := len(filtered[N.NetworkTCP]); got != 2 {
		t.Fatalf("expected startup unknown compatibility fallback, got %d", got)
	}
}

func TestRoundRobinDestinationAffinityKeepsSameHost(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	a := qualityTestOutbound{tag: "a"}
	b := qualityTestOutbound{tag: "b"}
	strategy := newRoundRobinForAntiFlapTest(now, a, b)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		a.Tag(): rrHistory(90, monitoring.HealthLevelExcellent, 90, 90, 100),
		b.Tag(): rrHistory(88, monitoring.HealthLevelExcellent, 88, 90, 110),
	})
	strategy.currentTag[N.NetworkTCP] = a.Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-roundRobinPreferredDwellTime)
	metadata := adapter.InboundContext{
		Network:     N.NetworkTCP,
		Destination: M.ParseSocksaddrHostPort("discord.com", 443),
	}

	first := strategy.Select(metadata, N.NetworkTCP, true).Tag()
	strategy.selectedAt[N.NetworkTCP] = now.Add(-roundRobinPreferredDwellTime)
	second := strategy.Select(metadata, N.NetworkTCP, true).Tag()
	if first != second {
		t.Fatalf("expected destination affinity to keep same host on %s, got %s then %s", metadata.Destination.Fqdn, first, second)
	}
}

func newRoundRobinForAntiFlapTest(now time.Time, outbounds ...adapter.Outbound) *RoundRobin {
	strategy := NewRoundRobin(outbounds, option.BalancerOutboundOptions{DelayAcceptableRatio: 10}, nil)
	strategy.now = func() time.Time {
		return now
	}
	return strategy
}

func rrHistory(combinedScore int32, combinedLevel string, qualityScore int32, speedScore int32, delay uint16) *adapter.URLTestHistory {
	qualityLevel := monitoring.QualityLevelGood
	if qualityScore >= 85 {
		qualityLevel = monitoring.QualityLevelExcellent
	} else if qualityScore < 40 {
		qualityLevel = monitoring.QualityLevelBad
	} else if qualityScore < 70 {
		qualityLevel = monitoring.QualityLevelMedium
	}
	speedLevel := monitoring.SpeedLevelNormal
	if speedScore >= 90 {
		speedLevel = monitoring.SpeedLevelFast
	} else if speedScore < 40 {
		speedLevel = monitoring.SpeedLevelVerySlow
	} else if speedScore < 70 {
		speedLevel = monitoring.SpeedLevelSlow
	}
	return &adapter.URLTestHistory{
		Delay:               delay,
		QualityScore:        qualityScore,
		QualityLevel:        qualityLevel,
		AutoAllowed:         qualityLevel == monitoring.QualityLevelGood || qualityLevel == monitoring.QualityLevelExcellent,
		SpeedScore:          speedScore,
		SpeedLevel:          speedLevel,
		CombinedHealthScore: combinedScore,
		CombinedHealthLevel: combinedLevel,
	}
}
