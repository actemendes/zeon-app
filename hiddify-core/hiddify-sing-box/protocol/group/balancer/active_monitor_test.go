package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

func TestSmartActiveProbeScheduleUsesRequestedRamp(t *testing.T) {
	want := []time.Duration{
		0,
		10 * time.Second,
		20 * time.Second,
		30 * time.Second,
		40 * time.Second,
		50 * time.Second,
		60 * time.Second,
		120 * time.Second,
		180 * time.Second,
	}
	for index, expected := range want {
		if got := smartActiveProbeOffset(index); got != expected {
			t.Fatalf("offset[%d]=%v, want %v", index, got, expected)
		}
	}
}

func TestSmartActiveProbeScheduleResetsForNewServer(t *testing.T) {
	started := time.Unix(100, 0)
	var schedule smartActiveProbeSchedule
	if !schedule.observe("first", started) {
		t.Fatal("first active did not initialize schedule")
	}
	for i := 0; i < 5; i++ {
		schedule.complete()
	}
	changedAt := started.Add(37 * time.Second)
	if !schedule.observe("second", changedAt) {
		t.Fatal("new active did not reset schedule")
	}
	if schedule.probeIndex != 0 || schedule.deadline() != changedAt {
		t.Fatalf("reset schedule=%+v deadline=%v, want immediate at %v", schedule, schedule.deadline(), changedAt)
	}
	if schedule.observe("second", changedAt.Add(time.Second)) {
		t.Fatal("unchanged active reset schedule")
	}
}

func primedActiveProbeStrategy() (*SmartActive, map[string]*adapter.URLTestHistory) {
	strategy := newSmartActiveForTest()
	history := histories(healthyHistory(80), healthyHistory(100))
	strategy.UpdateOutboundsInfo(history)
	return strategy, history
}

func failedActiveProbe(at time.Time) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{
		Time:            at,
		Delay:           65535,
		Success:         false,
		ErrorType:       urltest.ErrorTypeTimeout,
		URLTestStatus:   urltest.StatusFailed,
		PingReady:       true,
		QualityReady:    true,
		CombinedReady:   true,
		CheckGeneration: smartActiveTestGeneration,
	}
}

func TestSmartActiveProbeSingleFailureDoesNotSwitch(t *testing.T) {
	strategy, history := primedActiveProbeStrategy()
	update := strategy.UpdateActiveProbe("active", failedActiveProbe(time.Now()), history)
	if update.changed || !update.retry || strategy.Now() != "active" {
		t.Fatalf("single failure update=%+v active=%s", update, strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_waiting_failure_confirmation" {
		t.Fatalf("unexpected decision after one failure: %+v", decision)
	}
}

func TestSmartActiveProbeConfirmedFailureSwitches(t *testing.T) {
	strategy, history := primedActiveProbeStrategy()
	firstAt := time.Now()
	first := strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt), history)
	second := strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt.Add(time.Millisecond)), history)
	if !first.retry || !second.changed || strategy.Now() != "candidate" {
		t.Fatalf("first=%+v second=%+v active=%s", first, second, strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_confirmed_connection_failure" {
		t.Fatalf("unexpected confirmed failure decision: %+v", decision)
	}
}

func TestSmartActiveProbeTemporaryFailureRecoversWithoutSwitch(t *testing.T) {
	strategy, history := primedActiveProbeStrategy()
	firstAt := time.Now()
	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt), history); !update.retry {
		t.Fatalf("first failure did not request confirmation: %+v", update)
	}
	healthy := *healthyHistory(85)
	healthy.Time = firstAt.Add(time.Millisecond)
	if update := strategy.UpdateActiveProbe("active", &healthy, history); update.changed || update.retry {
		t.Fatalf("healthy confirmation changed active: %+v", update)
	}
	if strategy.Now() != "active" {
		t.Fatalf("temporary failure switched to %s", strategy.Now())
	}
	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt.Add(2*time.Millisecond)), history); update.changed || !update.retry {
		t.Fatalf("failure streak did not reset after recovery: %+v", update)
	}
}

func TestSmartActiveProbeSinglePacketLossDoesNotSwitch(t *testing.T) {
	strategy, history := primedActiveProbeStrategy()
	probe := *healthyHistory(85)
	probe.Time = time.Now()
	probe.UDPReady = true
	probe.UDPProbeAvailable = true
	probe.UDPLoss = 33
	probe.UDPPenalty = 9
	update := strategy.UpdateActiveProbe("active", &probe, history)
	if update.changed || update.retry || strategy.Now() != "active" {
		t.Fatalf("one lost packet changed active: update=%+v active=%s", update, strategy.Now())
	}
}

func TestSmartActiveProbePoorLatencyNeedsConfirmation(t *testing.T) {
	strategy, history := primedActiveProbeStrategy()
	firstAt := time.Now()
	poor := *healthyHistory(smartActiveUnusableDelay)
	poor.Time = firstAt
	first := strategy.UpdateActiveProbe("active", &poor, history)
	poor.Time = firstAt.Add(time.Millisecond)
	second := strategy.UpdateActiveProbe("active", &poor, history)
	if !first.retry || !second.changed || strategy.Now() != "candidate" {
		t.Fatalf("first=%+v second=%+v active=%s", first, second, strategy.Now())
	}
}

func TestSmartActiveProbeConfirmedFailureUsesFreshRecoveryCandidate(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(healthyHistory(80), failedHistory(urltest.ErrorTypeTimeout))
	strategy.UpdateOutboundsInfo(history)
	firstAt := time.Now()
	strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt), history)
	update := strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt.Add(time.Millisecond)), history)
	if !update.refreshCandidates || update.changed {
		t.Fatalf("confirmed failure did not request candidate refresh: %+v", update)
	}

	history = histories(
		currentGenerationFailedHistory(2, urltest.ErrorTypeTimeout),
		currentGenerationHealthyHistory(2, 90),
	)
	if !strategy.UpdateOutboundsInfo(history) || strategy.Now() != "candidate" {
		t.Fatalf("fresh recovery candidate was not selected: decision=%+v active=%s", strategy.LastDecision(), strategy.Now())
	}
}

func TestSmartActiveProbeCandidateRefreshKeepsRecoveredActive(t *testing.T) {
	strategy := newSmartActiveForTest()
	history := histories(healthyHistory(80), failedHistory(urltest.ErrorTypeTimeout))
	strategy.UpdateOutboundsInfo(history)
	firstAt := time.Now()
	strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt), history)
	strategy.UpdateActiveProbe("active", failedActiveProbe(firstAt.Add(time.Millisecond)), history)

	history = histories(
		currentGenerationHealthyHistory(2, 85),
		currentGenerationHealthyHistory(2, 90),
	)
	if strategy.UpdateOutboundsInfo(history) || strategy.Now() != "active" {
		t.Fatalf("recovered active was replaced: decision=%+v active=%s", strategy.LastDecision(), strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_recovered_during_candidate_refresh" {
		t.Fatalf("unexpected recovery decision: %+v", decision)
	}
}
