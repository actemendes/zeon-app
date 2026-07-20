package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

const periodicProbeTestGeneration uint64 = 41

func newPeriodicProbeComparison(
	active *adapter.URLTestHistory,
	candidate *adapter.URLTestHistory,
) (*SmartActive, map[string]*adapter.URLTestHistory) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = active.Time.Add(-time.Second)
	if candidate.Time.Before(active.Time) {
		strategy.startedAt = candidate.Time.Add(-time.Second)
	}
	strategy.selectionGeneration = periodicProbeTestGeneration
	strategy.evidence["candidate"] = &smartEvidence{
		// One fresh GOOD result from the latest full generation is eligible.
		// The two periodic observations below confirm that its advantage over
		// the live active is sustained; waiting for two full generations here
		// would keep a clearly worse active pinned for several minutes.
		successStreak:       1,
		lastScore:           getHealthScore("candidate", candidate),
		lastProbeGeneration: periodicProbeTestGeneration,
		lastProbeTime:       candidate.Time,
		hasCompletedProbe:   true,
	}
	return strategy, histories(active, candidate)
}

func periodicActiveProbe(at time.Time, delay uint16) *adapter.URLTestHistory {
	probe := currentGenerationHealthyHistory(periodicProbeTestGeneration, delay)
	probe.Time = at
	return probe
}

func TestPeriodicActiveProbeScoreAdvantageNeedsTwoStableSamples(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	first := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 250), history)
	if first.changed || strategy.Now() != "active" {
		t.Fatalf("first proactive sample switched early: update=%+v active=%s", first, strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_waiting_better_candidate_confirmation" {
		t.Fatalf("unexpected first-sample decision: %+v", decision)
	}

	second := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 250), history)
	if !second.changed || strategy.Now() != "candidate" {
		t.Fatalf("stable score advantage did not switch: update=%+v active=%s", second, strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_stably_better_candidate" || decision.mode != "active_probe" {
		t.Fatalf("unexpected proactive switch decision: %+v", decision)
	}
}

func TestPeriodicActiveProbeScoreAdvantageWinsEvenWithMinimalDelayDelta(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 90)
	active.VolatilityPenalty = 9
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 85)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	if delta := getHealthScore("candidate", candidate) - getHealthScore("active", active); delta < smartActiveScoreSwitchMargin {
		t.Fatalf("fixture score delta=%d, want at least %d", delta, smartActiveScoreSwitchMargin)
	}
	if delta := int(active.Delay) - int(candidate.Delay); delta > smartActiveMinimalDelayDelta {
		t.Fatalf("fixture delay delta=%d, want at most %d", delta, smartActiveMinimalDelayDelta)
	}
	if state := smartActiveState(active); state != "GOOD" {
		t.Fatalf("fixture active state=%s, want GOOD", state)
	}

	firstProbe := periodicActiveProbe(started, 90)
	firstProbe.VolatilityPenalty = 9
	if update := strategy.UpdateActiveProbe("active", firstProbe, history); update.changed {
		t.Fatalf("first score-advantage sample switched early: %+v", update)
	}
	secondProbe := periodicActiveProbe(started.Add(time.Second), 90)
	secondProbe.VolatilityPenalty = 9
	if update := strategy.UpdateActiveProbe("active", secondProbe, history); !update.changed || strategy.Now() != "candidate" {
		t.Fatalf("score advantage was blocked by minimal delay delta: update=%+v active=%s", update, strategy.Now())
	}
}

func TestPeriodicActiveProbeComparableQualityLargeDelaySwitchesAfterConfirmation(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 149)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 81)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	first := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 149), history)
	if first.changed || strategy.Now() != "active" {
		t.Fatalf("first comparable-quality sample switched early: update=%+v active=%s", first, strategy.Now())
	}
	second := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 149), history)
	if !second.changed || strategy.Now() != "candidate" {
		t.Fatalf("large delay advantage did not switch: update=%+v active=%s", second, strategy.Now())
	}
}

func TestPeriodicActiveProbeMaterialAdvantageOutweighsRelativeStabilityTieBreaker(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 1000)
	active.StabilityPoints = 100
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 50)
	candidate.StabilityPoints = 0
	candidate.VolatilityPenalty = 4
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	for index := range 2 {
		probe := periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 1000)
		probe.StabilityPoints = 100
		update := strategy.UpdateActiveProbe("active", probe, history)
		if index == 0 && update.changed {
			t.Fatalf("first material-advantage sample switched early: %+v", update)
		}
		if index == 1 && (!update.changed || strategy.Now() != "candidate") {
			t.Fatalf("relative stability vetoed an obvious candidate advantage: update=%+v active=%s", update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeMinimalAdvantageKeepsCurrent(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 90)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 85)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	for index := range 3 {
		update := strategy.UpdateActiveProbe(
			"active",
			periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 90),
			history,
		)
		if update.changed || strategy.Now() != "active" {
			t.Fatalf("minimal advantage switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_candidate_advantage_insufficient" {
		t.Fatalf("unexpected minimal-delta decision: %+v", decision)
	}
}

func TestPeriodicActiveProbeAdvantageConfirmationMustBeConsecutive(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 250), history); update.changed {
		t.Fatalf("first advantage sample switched early: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 70), history); update.changed {
		t.Fatalf("recovered active switched: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(2*time.Second), 250), history); update.changed {
		t.Fatalf("non-consecutive advantage samples were combined: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(3*time.Second), 250), history); !update.changed || strategy.Now() != "candidate" {
		t.Fatalf("second consecutive advantage did not switch: update=%+v active=%s", update, strategy.Now())
	}
}

func TestPeriodicActiveProbeNewFullGenerationResetsDisprovedAdvantage(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.rememberFullGeneration(history, periodicProbeTestGeneration)
	started := time.Now().Add(time.Second)

	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 250), history); update.changed {
		t.Fatalf("first proactive sample switched early: %+v", update)
	}
	if strategy.activeProbe.betterStreak != 1 {
		t.Fatalf("advantage streak=%d, want 1", strategy.activeProbe.betterStreak)
	}

	newGeneration := periodicProbeTestGeneration + 1
	refreshed := histories(
		currentGenerationHealthyHistory(newGeneration, 250),
		currentGenerationHealthyHistory(newGeneration, 240),
	)
	if strategy.UpdateOutboundsInfo(refreshed) {
		t.Fatal("new generation with a negligible delta switched active")
	}
	if strategy.activeProbe.betterStreak != 0 || strategy.activeProbe.betterCandidate != "" {
		t.Fatalf("disproved advantage survived full generation: %+v", strategy.activeProbe)
	}
}

func TestPeriodicActiveProbeDiscoversNewestFullGenerationWithoutEvent(t *testing.T) {
	oldActive := currentGenerationHealthyHistory(periodicProbeTestGeneration, 100)
	oldCandidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 110)
	strategy, oldHistory := newPeriodicProbeComparison(oldActive, oldCandidate)
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.rememberFullGeneration(oldHistory, periodicProbeTestGeneration)

	newGeneration := periodicProbeTestGeneration + 1
	latestRanking := histories(
		currentGenerationHealthyHistory(newGeneration, 250),
		currentGenerationHealthyHistory(newGeneration, 80),
	)
	started := time.Now().Add(time.Second)
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 250), latestRanking); update.changed {
		t.Fatalf("first sample against discovered generation switched early: %+v", update)
	}
	if strategy.lastFullGeneration != newGeneration {
		t.Fatalf("last full generation=%d, want %d", strategy.lastFullGeneration, newGeneration)
	}
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 250), latestRanking); !update.changed || strategy.Now() != "candidate" {
		t.Fatalf("newest coherent generation was not used: update=%+v active=%s", update, strategy.Now())
	}
}

func TestPeriodicActiveProbeSuspectOrDegradedSwitchesToStableGood(t *testing.T) {
	tests := []struct {
		name              string
		degradationPoints int
	}{
		{name: "suspect", degradationPoints: 12},
		{name: "degraded", degradationPoints: 35},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
			active.DegradationPoints = test.degradationPoints
			candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
			strategy, history := newPeriodicProbeComparison(active, candidate)
			started := time.Now().Add(time.Second)

			firstProbe := periodicActiveProbe(started, 250)
			firstProbe.DegradationPoints = test.degradationPoints
			if update := strategy.UpdateActiveProbe("active", firstProbe, history); update.changed {
				t.Fatalf("first %s sample switched early: %+v", test.name, update)
			}

			secondProbe := periodicActiveProbe(started.Add(time.Second), 250)
			secondProbe.DegradationPoints = test.degradationPoints
			if update := strategy.UpdateActiveProbe("active", secondProbe, history); !update.changed || strategy.Now() != "candidate" {
				t.Fatalf("stable GOOD candidate did not replace %s active: update=%+v active=%s", test.name, update, strategy.Now())
			}
		})
	}
}

func TestPeriodicActiveProbeSkipsRejectedRankOneCandidate(t *testing.T) {
	strategy := newSmartActiveWithTags("active", "rejected", "eligible")
	strategy.active = strategy.outbounds[0]
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.selectionGeneration = periodicProbeTestGeneration

	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 350)
	rejected := currentGenerationHealthyHistory(periodicProbeTestGeneration, 40)
	rejected.ErrorType = urltest.ErrorTypeTimeout
	eligible := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	strategy.evidence["rejected"] = &smartEvidence{successStreak: 1}
	strategy.evidence["eligible"] = &smartEvidence{successStreak: 1}
	history := map[string]*adapter.URLTestHistory{
		"active":   active,
		"rejected": rejected,
		"eligible": eligible,
	}
	if getHealthScore("rejected", rejected) <= getHealthScore("eligible", eligible) {
		t.Fatal("fixture rejected candidate must rank first before eligibility filtering")
	}

	started := time.Now().Add(time.Second)
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 350), history); update.changed {
		t.Fatalf("first proactive sample switched early: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 350), history); !update.changed || strategy.Now() != "eligible" {
		t.Fatalf("valid rank-two candidate was not selected: update=%+v active=%s", update, strategy.Now())
	}
}

func TestPeriodicActiveProbeAvoidsImmediateReverseSwitch(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	// Pre-switch successes must not count as recovery evidence after this server
	// is placed on the avoid list.
	strategy.evidence["active"] = &smartEvidence{successStreak: smartActiveCleanEvidenceRequired}
	started := time.Now().Add(time.Second)
	strategy.UpdateActiveProbe("active", periodicActiveProbe(started, 250), history)
	if update := strategy.UpdateActiveProbe("active", periodicActiveProbe(started.Add(time.Second), 250), history); !update.changed {
		t.Fatalf("fixture did not perform the initial switch: %+v", update)
	}

	strategy.selectionGeneration = periodicProbeTestGeneration + 1
	history = map[string]*adapter.URLTestHistory{
		"active":    currentGenerationHealthyHistory(periodicProbeTestGeneration+1, 80),
		"candidate": currentGenerationHealthyHistory(periodicProbeTestGeneration+1, 250),
	}
	strategy.rememberFullGeneration(history, periodicProbeTestGeneration+1)
	for index := range 3 {
		probe := currentGenerationHealthyHistory(periodicProbeTestGeneration+1, 250)
		probe.Time = started.Add(time.Duration(index+2) * time.Second)
		update := strategy.UpdateActiveProbe("candidate", probe, history)
		if update.changed || strategy.Now() != "candidate" {
			t.Fatalf("avoid list allowed reverse switch on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeExpiredAvoidAllowsRecoveredBetterServer(t *testing.T) {
	strategy := newSmartActiveWithTags("current", "recovered")
	strategy.active = strategy.outbounds[0]
	strategy.bootstrap = false
	strategy.confirmed = true
	strategy.selectionGeneration = periodicProbeTestGeneration
	strategy.avoidUntil["recovered"] = time.Now().Add(-time.Second)
	strategy.evidence["recovered"] = &smartEvidence{successStreak: 1}
	history := map[string]*adapter.URLTestHistory{
		"current":   currentGenerationHealthyHistory(periodicProbeTestGeneration, 250),
		"recovered": currentGenerationHealthyHistory(periodicProbeTestGeneration, 80),
	}
	strategy.rememberFullGeneration(history, periodicProbeTestGeneration)

	started := time.Now().Add(time.Second)
	if update := strategy.UpdateActiveProbe("current", periodicActiveProbe(started, 250), history); update.changed {
		t.Fatalf("first post-avoid comparison switched early: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("current", periodicActiveProbe(started.Add(time.Second), 250), history); !update.changed || strategy.Now() != "recovered" {
		t.Fatalf("expired avoid kept recovered better server blocked: update=%+v active=%s", update, strategy.Now())
	}
}

func TestPeriodicActiveProbePolicyPreferredForeignCandidateIsReachableFromSuspect(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 55)
	active.PolicyPenalty = urltest.RussianServerPolicyPenalty
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 350)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	if state := smartActiveState(active); state != "SUSPECT" {
		t.Fatalf("fixture active state=%s, want SUSPECT", state)
	}
	if state := smartActiveState(candidate); state != "GOOD" {
		t.Fatalf("fixture candidate state=%s, want GOOD", state)
	}
	if delta := getHealthScore("candidate", candidate) - getHealthScore("active", active); delta < 4 || delta >= 14 {
		t.Fatalf("fixture policy score delta=%d, want [4,14)", delta)
	}

	started := time.Now().Add(time.Second)
	firstProbe := periodicActiveProbe(started, 55)
	firstProbe.PolicyPenalty = urltest.RussianServerPolicyPenalty
	if update := strategy.UpdateActiveProbe("active", firstProbe, history); update.changed {
		t.Fatalf("first policy comparison switched early: %+v", update)
	}
	secondProbe := periodicActiveProbe(started.Add(time.Second), 55)
	secondProbe.PolicyPenalty = urltest.RussianServerPolicyPenalty
	if update := strategy.UpdateActiveProbe("active", secondProbe, history); !update.changed || strategy.Now() != "candidate" {
		t.Fatalf("policy-preferred foreign candidate remained unreachable: update=%+v active=%s decision=%+v", update, strategy.Now(), strategy.LastDecision())
	}
}

func TestPeriodicActiveProbePolicyImprovementOutweighsStabilityTieBreaker(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 55)
	active.PolicyPenalty = urltest.RussianServerPolicyPenalty
	active.StabilityPoints = 100
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate.StabilityPoints = 0
	candidate.VolatilityPenalty = 4
	strategy, history := newPeriodicProbeComparison(active, candidate)
	started := time.Now().Add(time.Second)

	for index := range 2 {
		probe := periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 55)
		probe.PolicyPenalty = urltest.RussianServerPolicyPenalty
		probe.StabilityPoints = 100
		update := strategy.UpdateActiveProbe("active", probe, history)
		if index == 0 && update.changed {
			t.Fatalf("first policy sample switched early: %+v", update)
		}
		if index == 1 && (!update.changed || strategy.Now() != "candidate") {
			t.Fatalf("stability tie-breaker pinned policy-penalized active: update=%+v active=%s", update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeRefreshesSameGenerationFullSnapshot(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.rememberFullGeneration(history, periodicProbeTestGeneration)

	updated := histories(
		cloneSmartActiveHistory(active),
		cloneSmartActiveHistory(candidate),
	)
	updated["candidate"].Time = candidate.Time.Add(time.Second)
	updated["candidate"].UDPReady = true
	updated["candidate"].UDPProbeAvailable = true
	updated["candidate"].UDPPenalty = 15
	strategy.UpdateActiveProbe("active", periodicActiveProbe(time.Now().Add(time.Second), 250), updated)

	if got := strategy.lastFullHistory["candidate"].UDPPenalty; got != 15 {
		t.Fatalf("same-generation UDP update was not saved: penalty=%d", got)
	}
}

func TestPeriodicActiveProbeIgnoresSameGenerationTargetedImprovement(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 300)
	strategy, full := newPeriodicProbeComparison(active, candidate)
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.rememberFullGeneration(full, periodicProbeTestGeneration)

	targeted := histories(cloneSmartActiveHistory(active), cloneSmartActiveHistory(candidate))
	targeted["candidate"].Delay = 50
	targeted["candidate"].Time = candidate.Time.Add(time.Second)
	started := time.Now().Add(2 * time.Second)
	for index := range 3 {
		update := strategy.UpdateActiveProbe(
			"active",
			periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 250),
			targeted,
		)
		if update.changed || strategy.Now() != "active" {
			t.Fatalf("targeted improvement switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeRejectsCandidatesOutsideLatestFullGeneration(t *testing.T) {
	baseCandidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	tests := []struct {
		name      string
		candidate func() *adapter.URLTestHistory
	}{
		{
			name: "stale_generation",
			candidate: func() *adapter.URLTestHistory {
				candidate := *baseCandidate
				candidate.CheckGeneration--
				return &candidate
			},
		},
		{
			name: "newer_partial_generation",
			candidate: func() *adapter.URLTestHistory {
				candidate := *baseCandidate
				candidate.CheckGeneration++
				return &candidate
			},
		},
		{
			name: "cached",
			candidate: func() *adapter.URLTestHistory {
				candidate := *baseCandidate
				candidate.IsFromCache = true
				return &candidate
			},
		},
		{
			name: "incomplete",
			candidate: func() *adapter.URLTestHistory {
				candidate := *baseCandidate
				candidate.CombinedReady = false
				candidate.URLTestStatus = urltest.StatusChecking
				return &candidate
			},
		},
		{
			name: "untested",
			candidate: func() *adapter.URLTestHistory {
				return &adapter.URLTestHistory{
					Time:            time.Now(),
					CheckGeneration: periodicProbeTestGeneration,
					URLTestStatus:   urltest.StatusNotTested,
				}
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
			strategy, history := newPeriodicProbeComparison(active, test.candidate())
			started := time.Now().Add(time.Second)

			for index := range 3 {
				update := strategy.UpdateActiveProbe(
					"active",
					periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 250),
					history,
				)
				if update.changed || strategy.Now() != "active" {
					t.Fatalf("ineligible candidate switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
				}
			}
		})
	}
}

func TestPeriodicActiveProbeDoesNotPromotePartialGenerationWithoutFullSnapshot(t *testing.T) {
	strategy := newSmartActiveForTest()
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.selectionGeneration = periodicProbeTestGeneration
	strategy.evidence["candidate"] = &smartEvidence{successStreak: 2}
	history := histories(
		currentGenerationCheckingHistory(periodicProbeTestGeneration),
		currentGenerationHealthyHistory(periodicProbeTestGeneration, 80),
	)
	started := time.Now().Add(time.Second)
	for index := range 3 {
		update := strategy.UpdateActiveProbe(
			"active",
			periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 250),
			history,
		)
		if update.changed || strategy.Now() != "active" {
			t.Fatalf("partial generation candidate switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_waiting_for_full_generation" {
		t.Fatalf("unexpected partial-generation decision: %+v", decision)
	}
}

func TestPeriodicActiveProbeNewerCandidateFailureVetoesLastFullSuccess(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, fullHistory := newPeriodicProbeComparison(active, candidate)
	strategy.rememberFullGeneration(fullHistory, periodicProbeTestGeneration)

	latest := histories(
		currentGenerationCheckingHistory(periodicProbeTestGeneration+1),
		currentGenerationFailedHistory(periodicProbeTestGeneration+1, urltest.ErrorTypeTimeout),
	)
	started := time.Now().Add(time.Second)
	for index := range 3 {
		update := strategy.UpdateActiveProbe(
			"active",
			periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 250),
			latest,
		)
		if update.changed || strategy.Now() != "active" {
			t.Fatalf("newer failed candidate switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeNewerSameGenerationFailureVetoesLastFullSuccess(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, fullHistory := newPeriodicProbeComparison(active, candidate)
	strategy.startedAt = time.Now().Add(-time.Hour)
	strategy.rememberFullGeneration(fullHistory, periodicProbeTestGeneration)

	failedCandidate := currentGenerationFailedHistory(periodicProbeTestGeneration, urltest.ErrorTypeTimeout)
	failedCandidate.Time = candidate.Time.Add(time.Second)
	failedCandidate.CombinedReady = false
	latest := histories(currentGenerationCheckingHistory(periodicProbeTestGeneration), failedCandidate)
	started := time.Now().Add(2 * time.Second)
	for index := range 3 {
		update := strategy.UpdateActiveProbe(
			"active",
			periodicActiveProbe(started.Add(time.Duration(index)*time.Second), 250),
			latest,
		)
		if update.changed || strategy.Now() != "active" {
			t.Fatalf("same-generation failed candidate switched on sample %d: update=%+v active=%s", index+1, update, strategy.Now())
		}
	}
}

func TestPeriodicActiveProbeFirstFailureStillRequiresConfirmation(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)

	update := strategy.UpdateActiveProbe("active", failedActiveProbe(time.Now().Add(time.Second)), history)
	if update.changed || !update.retry || strategy.Now() != "active" {
		t.Fatalf("first hard failure bypassed confirmation: update=%+v active=%s", update, strategy.Now())
	}
	if decision := strategy.LastDecision(); decision.reason != "active_probe_waiting_failure_confirmation" {
		t.Fatalf("unexpected first-failure decision: %+v", decision)
	}
}

func TestPeriodicActiveProbeConfirmedFailureCanReuseAvoidedOnlyCandidate(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	strategy.avoidUntil["candidate"] = time.Now().Add(time.Minute)
	started := time.Now().Add(time.Second)

	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(started), history); update.changed || !update.retry {
		t.Fatalf("first failure bypassed confirmation: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(started.Add(time.Second)), history); !update.changed || strategy.Now() != "candidate" {
		t.Fatalf("confirmed failure remained pinned by avoid-list: update=%+v active=%s", update, strategy.Now())
	}
	evidence := strategy.evidence["active"]
	if evidence == nil || !evidence.recoveryPending || evidence.failureStreak < smartActiveProbeConfirmations || evidence.successStreak != 0 {
		t.Fatalf("confirmed active failure was not carried into recovery evidence: %+v", evidence)
	}
}

func TestPeriodicActiveProbeConfirmedFailureRejectsStaleCandidate(t *testing.T) {
	active := currentGenerationHealthyHistory(periodicProbeTestGeneration, 250)
	candidate := currentGenerationHealthyHistory(periodicProbeTestGeneration, 80)
	candidate.Time = time.Now().Add(-smartActiveCandidateMaxAge - time.Minute)
	strategy, history := newPeriodicProbeComparison(active, candidate)
	strategy.startedAt = candidate.Time.Add(-time.Minute)
	strategy.rememberFullGeneration(history, periodicProbeTestGeneration)
	started := time.Now().Add(time.Second)

	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(started), history); update.changed || !update.retry {
		t.Fatalf("first failure bypassed confirmation: %+v", update)
	}
	if update := strategy.UpdateActiveProbe("active", failedActiveProbe(started.Add(time.Second)), history); update.changed || !update.refreshCandidates || strategy.Now() != "active" {
		t.Fatalf("stale failover candidate became active: update=%+v active=%s", update, strategy.Now())
	}
}
