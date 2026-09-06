package monitoring

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
)

func TestSingleServerRefreshPreservesStartingAutoCohort(t *testing.T) {
	// The manual server is pinged immediately after reconnect while Auto's
	// initial full-list check is still running. Auto must retain that cohort.
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: time.Now(), CheckGeneration: 1, URLTestStatus: urltest.StatusChecking,
	})
	monitor.cycleSeq = 1
	monitor.urls = []string{"http://probe.invalid/generate_204"}
	monitor.urlTestTimeout = time.Second
	monitor.outbounds["active"].outbound = newActiveProbeTestOutbound("active")
	monitor.outbounds["candidate"] = &outboundState{
		outbound: newActiveProbeTestOutbound("candidate"), groupTags: []string{""},
		history: adapter.URLTestHistory{
			Time: time.Now(), CheckGeneration: 1, URLTestStatus: urltest.StatusSuccess,
			Success: true, Delay: 30, PingReady: true, QualityReady: true,
			SpeedReady: true, CombinedReady: true,
		},
	}
	monitor.groups[""].outbounds["candidate"] = struct{}{}
	if err := monitor.TestNowAndWait("active", time.Second); err != nil {
		t.Fatalf("single-server refresh failed: %v", err)
	}
	ranking := monitor.OutboundsRankingHistory("")
	if ranking["active"].CheckGeneration != 1 || ranking["candidate"].CheckGeneration != 1 {
		t.Fatalf("manual ping split Auto's initial cohort: active=%d candidate=%d", ranking["active"].CheckGeneration, ranking["candidate"].CheckGeneration)
	}
	if ranking["active"].URLTestStatus != urltest.StatusChecking || ranking["active"].CombinedReady {
		t.Fatal("isolated ping falsely completed the full-list check")
	}
	presentation := monitor.OutboundsHistory("")["active"]
	if !presentation.Success || presentation.Delay == 0 {
		t.Fatal("the manual server's fresh latency was not published")
	}
}

func TestSingleMemberGroupRefreshStillCreatesFullGeneration(t *testing.T) {
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: time.Now(), CheckGeneration: 1, URLTestStatus: urltest.StatusChecking,
	})
	monitor.cycleSeq = 1
	monitor.urls = []string{"http://probe.invalid/generate_204"}
	monitor.urlTestTimeout = time.Second
	monitor.outbounds["active"].outbound = newActiveProbeTestOutbound("active")
	monitor.groups["group"] = monitor.groups[""]
	monitor.groups["group"].tag = "group"
	monitor.outbounds["active"].groupTags = []string{"group"}
	delete(monitor.groups, "")
	if err := monitor.TestNowAndWait("group", time.Second); err != nil {
		t.Fatalf("group refresh failed: %v", err)
	}
	if history := monitor.OutboundsRankingHistory("group")["active"]; history.CheckGeneration != 2 || !history.CombinedReady {
		t.Fatalf("single-member group no longer completes its full generation: %+v", history)
	}
}

func TestFailedSingleServerRefreshPreservesRanking(t *testing.T) {
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: time.Now(), CheckGeneration: 1, URLTestStatus: urltest.StatusChecking,
	})
	monitor.cycleSeq = 1
	monitor.urls = []string{"http://probe.invalid/generate_204"}
	outbound := newActiveProbeTestOutbound("active")
	outbound.fail = true
	monitor.outbounds["active"].outbound = outbound
	if err := monitor.TestNowAndWait("active", time.Second); err == nil {
		t.Fatal("failed single-server probe reported success")
	}
	if history := monitor.OutboundsRankingHistory("")["active"]; history.CheckGeneration != 1 || history.URLTestStatus != urltest.StatusChecking {
		t.Fatalf("failed isolated ping mutated full-generation history: %+v", history)
	}
	if history := monitor.OutboundsHistory("")["active"]; history.Success || history.URLTestStatus != urltest.StatusFailed {
		t.Fatalf("failed probe was not exposed to presentation: %+v", history)
	}
}

func TestAutomaticSelectedServerPingPreservesGeneration(t *testing.T) {
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: time.Now(), CheckGeneration: 1, URLTestStatus: urltest.StatusChecking,
	})
	monitor.cycleSeq = 1
	monitor.urls = []string{"http://probe.invalid/generate_204"}
	monitor.urlTestTimeout = time.Second
	monitor.outbounds["active"].outbound = newActiveProbeTestOutbound("active")
	// Selector.SelectOutbound schedules this non-blocking API after reconnect.
	if err := monitor.TestNow("active"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		if ranking := monitor.OutboundsRankingHistory("")["active"]; ranking.CheckGeneration != 1 || ranking.CombinedReady {
			t.Fatalf("automatic selected-server ping replaced the pending cohort: %+v", ranking)
		}
		if monitor.OutboundsHistory("")["active"].Success {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("automatic selected-server ping did not publish its result")
		}
		time.Sleep(time.Millisecond)
	}
}
