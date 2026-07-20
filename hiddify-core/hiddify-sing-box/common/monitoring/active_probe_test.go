package monitoring

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	adapterOutbound "github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/observable"
)

type activeProbeTestOutbound struct {
	adapterOutbound.Adapter
	dials atomic.Int32
	fail  bool
}

func newActiveProbeTestOutbound(tag string) *activeProbeTestOutbound {
	return &activeProbeTestOutbound{Adapter: adapterOutbound.NewAdapter("test", tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)}
}

func (o *activeProbeTestOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	o.dials.Add(1)
	if o.fail {
		return nil, context.DeadlineExceeded
	}
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			return
		}
		request.Body.Close()
		time.Sleep(2 * time.Millisecond)
		_, _ = io.WriteString(server, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
	}()
	return client, nil
}

func (*activeProbeTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("UDP disabled in this test")
}

func TestLightweightActiveUDPOptionsStaySmall(t *testing.T) {
	options := lightweightActiveUDPOptions(urltest.UDPProbeOptions{
		Count:    10,
		Size:     1200,
		Interval: 200 * time.Millisecond,
		Timeout:  2 * time.Second,
	})
	if options.Count != activeUDPProbeCount || options.Size != activeUDPProbeSize {
		t.Fatalf("active UDP payload is not bounded: %+v", options)
	}
	if options.Interval != activeUDPProbeGap || options.Timeout != activeUDPProbeWait {
		t.Fatalf("active UDP timing is not bounded: %+v", options)
	}
}

func TestLightweightActiveUDPOptionsKeepSmallerConfiguration(t *testing.T) {
	want := urltest.UDPProbeOptions{
		Count:    2,
		Size:     96,
		Interval: 10 * time.Millisecond,
		Timeout:  250 * time.Millisecond,
	}
	if got := lightweightActiveUDPOptions(want); got != want {
		t.Fatalf("smaller configured probe changed: got=%+v want=%+v", got, want)
	}
}

func TestActiveURLProbeHardTimeoutReturnsWithoutWaitingForDialer(t *testing.T) {
	started := time.Now()
	_, err, timedOut := runActiveURLTestWithHardTimeout(context.Background(), 20*time.Millisecond, func(context.Context) (uint16, error) {
		time.Sleep(250 * time.Millisecond)
		return 0, errors.New("late failure")
	})
	if !timedOut || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timedOut=%v err=%v, want hard timeout", timedOut, err)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("active URL probe returned too late: %v", elapsed)
	}
}

func TestActiveProbeUsesOnlyRequestedOutboundAndKeepsRankingHistoryIsolated(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	active := newActiveProbeTestOutbound("active")
	other := newActiveProbeTestOutbound("other")
	// Use the production formatter here: unlike the NOP logger it rejects raw
	// float values and therefore guards the Android logging path from panics.
	strictLogger := log.NewDefaultFactory(ctx, log.Formatter{}, io.Discard, "", nil, false).NewLogger("active-probe-test")
	monitor := &OutboundMonitoring{
		ctx:            ctx,
		logger:         strictLogger,
		urls:           []string{"http://probe.invalid/generate_204"},
		urlTestTimeout: time.Second,
		history:        urltest.NewHistoryStorage(),
		outbounds: map[string]*outboundState{
			"active": {
				outbound:  active,
				groupTags: []string{""},
				history: adapter.URLTestHistory{
					Time: time.Now(), Delay: 777, Success: true, ErrorType: urltest.ErrorTypeNone,
					URLTestStatus: urltest.StatusSuccess, HealthScore: 55, CheckGeneration: 4,
					PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
				},
			},
			"other": {
				outbound:  other,
				groupTags: []string{""},
				history: adapter.URLTestHistory{
					Time: time.Now(), Delay: 888, Success: true, ErrorType: urltest.ErrorTypeNone,
					URLTestStatus: urltest.StatusSuccess, HealthScore: 45, CheckGeneration: 4,
					PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
				},
			},
		},
		groups: map[string]*groupState{
			"": {
				tag:       "",
				outbounds: map[string]struct{}{"active": {}, "other": {}},
				observer:  NewBroadcaster[GroupEvent](ctx),
				notifyCh:  make(chan struct{}, 1),
			},
		},
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
	}

	result, err := monitor.ProbeActiveOutbound(ctx, "active")
	if err != nil || !result.History.Success || result.History.Delay == 0 {
		t.Fatalf("active probe result=%+v err=%v", result, err)
	}
	if !monitor.PublishActiveProbePresentation(result) {
		t.Fatal("active probe presentation was rejected")
	}
	if active.dials.Load() != 1 || other.dials.Load() != 0 {
		t.Fatalf("dial counts active=%d other=%d", active.dials.Load(), other.dials.Load())
	}
	if monitor.outbounds["active"].history.Delay != 777 || monitor.outbounds["other"].history.Delay != 888 {
		t.Fatal("isolated active probe mutated full-generation ranking history")
	}
	ranking := monitor.OutboundsRankingHistory("")
	if ranking["active"].Delay != 777 || ranking["active"].CheckGeneration != 4 || ranking["other"].Delay != 888 {
		t.Fatalf("ranking view was mutated: active=%+v other=%+v", ranking["active"], ranking["other"])
	}
	presentation := monitor.OutboundsHistory("")
	if presentation["active"].Delay != result.History.Delay ||
		presentation["active"].HealthScore != result.History.HealthScore ||
		presentation["active"].CheckGeneration != 0 {
		t.Fatalf("active presentation was not refreshed: result=%+v presentation=%+v", result.History, presentation["active"])
	}
	if presentation["other"].Delay != 888 || presentation["other"].CheckGeneration != 4 {
		t.Fatalf("non-active presentation changed: %+v", presentation["other"])
	}
	stored := monitor.history.LoadURLTestHistory("active")
	if stored == nil || stored.Delay != result.History.Delay || stored.HealthScore != result.History.HealthScore {
		t.Fatalf("active presentation was not published to history storage: %+v", stored)
	}
	select {
	case <-monitor.groups[""].notifyCh:
	default:
		t.Fatal("active presentation did not schedule a group event")
	}
}

func TestActiveProbePresentationMergesLatestRealUserEvidence(t *testing.T) {
	now := time.Now()
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: now, Delay: 400, Success: true, ErrorType: urltest.ErrorTypeNone,
		URLTestStatus: urltest.StatusSuccess, HealthScore: 70, CheckGeneration: 7,
		PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
		RealUserPenalty: 18, DegradationPoints: 34, StabilityPoints: 22, VolatilityPenalty: 9,
	})
	state := monitor.outbounds["active"]
	result := ActiveProbeResult{
		OutboundTag: "active",
		History: adapter.URLTestHistory{
			Time: now.Add(time.Second), Delay: 42, Success: true, ErrorType: urltest.ErrorTypeNone,
			URLTestStatus: urltest.StatusSuccess, HealthScore: 100,
		},
		rankingRevision: state.rankingRevision,
	}
	if !monitor.PublishActiveProbePresentation(result) {
		t.Fatal("fresh active probe presentation was rejected")
	}

	presentation := monitor.OutboundsHistory("")["active"]
	if presentation.Delay != 42 || !presentation.Success || presentation.URLTestStatus != urltest.StatusSuccess {
		t.Fatalf("transport sample missing from presentation: %+v", presentation)
	}
	if presentation.RealUserPenalty != 18 || presentation.DegradationPoints != 34 ||
		presentation.StabilityPoints != 22 || presentation.VolatilityPenalty != 9 {
		t.Fatalf("latest real-user evidence was overwritten: %+v", presentation)
	}
	if presentation.HealthScore >= 100 {
		t.Fatalf("health score ignored accumulated evidence: %+v", presentation)
	}
	ranking := monitor.OutboundsRankingHistory("")["active"]
	if ranking.Delay != 400 || ranking.CheckGeneration != 7 || ranking.RealUserPenalty != 18 {
		t.Fatalf("ranking history changed while publishing presentation: %+v", ranking)
	}
}

func TestActiveProbeFailureIsPublishedWithoutCompletingGeneration(t *testing.T) {
	now := time.Now()
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: now, URLTestStatus: urltest.StatusChecking, CheckGeneration: 9,
	})
	state := monitor.outbounds["active"]
	result := ActiveProbeResult{
		OutboundTag: "active",
		History: adapter.URLTestHistory{
			Time: now.Add(time.Second), Delay: TimeoutDelay, Success: false,
			ErrorType: urltest.ErrorTypeTimeout, URLTestStatus: urltest.StatusFailed,
			PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
		},
		rankingRevision: state.rankingRevision,
	}
	if !monitor.PublishActiveProbePresentation(result) {
		t.Fatal("active failure presentation was rejected")
	}

	presentation := monitor.OutboundsHistory("")["active"]
	if presentation.Success || presentation.URLTestStatus != urltest.StatusFailed ||
		presentation.ErrorType != urltest.ErrorTypeTimeout || presentation.Delay != TimeoutDelay {
		t.Fatalf("active failure was not exposed: %+v", presentation)
	}
	ranking := monitor.OutboundsRankingHistory("")["active"]
	if ranking.CheckGeneration != 9 || ranking.URLTestStatus != urltest.StatusChecking || ranking.CombinedReady {
		t.Fatalf("isolated failure completed an in-flight generation: %+v", ranking)
	}
}

func TestActiveProbePresentationIsInvalidatedByNewGenerationAndFullResult(t *testing.T) {
	now := time.Now()
	t.Run("new generation", func(t *testing.T) {
		monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
			Time: now, Delay: 300, Success: true, ErrorType: urltest.ErrorTypeNone,
			URLTestStatus: urltest.StatusSuccess, CheckGeneration: 3,
			PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
		})
		state := monitor.outbounds["active"]
		if !monitor.PublishActiveProbePresentation(ActiveProbeResult{
			OutboundTag: "active",
			History: adapter.URLTestHistory{
				Time: now.Add(time.Second), Delay: 35, Success: true,
				ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			},
			rankingRevision: state.rankingRevision,
		}) {
			t.Fatal("active presentation was rejected")
		}

		monitor.resetOutboundCheckState("active", 4)
		presentation := monitor.OutboundsHistory("")["active"]
		if presentation.CheckGeneration != 4 || presentation.URLTestStatus != urltest.StatusChecking || presentation.Delay != 0 {
			t.Fatalf("new generation did not invalidate active overlay: %+v", presentation)
		}
	})

	t.Run("newer full result", func(t *testing.T) {
		monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
			Time: now, Delay: 300, Success: true, ErrorType: urltest.ErrorTypeNone,
			URLTestStatus: urltest.StatusSuccess, CheckGeneration: 5,
			PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
		})
		state := monitor.outbounds["active"]
		if !monitor.PublishActiveProbePresentation(ActiveProbeResult{
			OutboundTag: "active",
			History: adapter.URLTestHistory{
				Time: now.Add(time.Second), Delay: 35, Success: true,
				ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			},
			rankingRevision: state.rankingRevision,
		}) {
			t.Fatal("active presentation was rejected")
		}

		full := monitor.applyResult(testOutcome{
			outboundTag: "active",
			cycleID:     5,
			history: adapter.URLTestHistory{
				Time: now.Add(2 * time.Second), Delay: 91, Success: true,
				ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			},
		})
		if full == nil {
			t.Fatal("full result was unexpectedly rejected")
		}
		presentation := monitor.OutboundsHistory("")["active"]
		if presentation.Delay != 91 || presentation.CheckGeneration != 5 || presentation.URLTestStatus != urltest.StatusSuccess {
			t.Fatalf("newer full result did not replace active overlay: %+v", presentation)
		}
	})
}

func TestLateActiveProbeDoesNotCoverNewerRankingRevision(t *testing.T) {
	now := time.Now()
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: now, Delay: 300, Success: true, ErrorType: urltest.ErrorTypeNone,
		URLTestStatus: urltest.StatusSuccess, CheckGeneration: 2,
		PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
	})
	state := monitor.outbounds["active"]
	staleRevision := state.rankingRevision
	monitor.resetOutboundCheckState("active", 3)

	published := monitor.PublishActiveProbePresentation(ActiveProbeResult{
		OutboundTag: "active",
		History: adapter.URLTestHistory{
			Time: now.Add(time.Second), Delay: 25, Success: true,
			ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
		},
		rankingRevision: staleRevision,
	})
	if published {
		t.Fatal("late active probe covered a newer ranking revision")
	}
	presentation := monitor.OutboundsHistory("")["active"]
	if presentation.CheckGeneration != 3 || presentation.URLTestStatus != urltest.StatusChecking || presentation.Delay != 0 {
		t.Fatalf("late probe leaked into presentation: %+v", presentation)
	}
}

func TestActiveProbePresentationCannotOverwriteNewerFullStorage(t *testing.T) {
	now := time.Now()
	monitor := newActiveProbePresentationTestMonitor(t, adapter.URLTestHistory{
		Time: now, Delay: 300, Success: true, ErrorType: urltest.ErrorTypeNone,
		URLTestStatus: urltest.StatusSuccess, CheckGeneration: 5,
		PingReady: true, QualityReady: true, SpeedReady: true, CombinedReady: true,
	})
	storage := newActiveProbePublicationBarrierStorage()
	// Exercise the production hook path too. Subscriber.Emit is non-blocking;
	// neither it nor the group notification may run while state.mu is held.
	storage.SetHook(observable.NewSubscriber[struct{}](1))
	monitor.history = storage

	state := monitor.outbounds["active"]
	publishDone := make(chan bool, 1)
	go func() {
		publishDone <- monitor.PublishActiveProbePresentation(ActiveProbeResult{
			OutboundTag: "active",
			History: adapter.URLTestHistory{
				Time: now.Add(time.Second), Delay: 35, Success: true,
				ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			},
			rankingRevision: state.rankingRevision,
		})
	}()

	released := false
	defer func() {
		if !released {
			close(storage.releaseFirstStore)
		}
	}()
	select {
	case <-storage.firstStoreEntered:
	case <-time.After(time.Second):
		t.Fatal("active presentation did not reach storage barrier")
	}

	fullDone := make(chan *adapter.URLTestHistory, 1)
	fullStarted := make(chan struct{})
	go func() {
		close(fullStarted)
		fullDone <- monitor.applyResult(testOutcome{
			outboundTag: "active",
			cycleID:     5,
			history: adapter.URLTestHistory{
				Time: now.Add(2 * time.Second), Delay: 91, Success: true,
				ErrorType: urltest.ErrorTypeNone, URLTestStatus: urltest.StatusSuccess,
			},
		})
	}()
	<-fullStarted

	// Without publication serialization, applyResult commits revision 1 and
	// completes the second storage write while the older presentation is still
	// stopped at the first barrier. Releasing it then deterministically leaves
	// the stale delay in storage.
	fullOvertookPresentation := false
	select {
	case <-storage.secondStoreCompleted:
		fullOvertookPresentation = true
	case <-time.After(100 * time.Millisecond):
	}
	close(storage.releaseFirstStore)
	released = true

	select {
	case published := <-publishDone:
		if !published {
			t.Fatal("active presentation was unexpectedly rejected")
		}
	case <-time.After(time.Second):
		t.Fatal("active presentation deadlocked in storage hook/event path")
	}
	select {
	case full := <-fullDone:
		if full == nil {
			t.Fatal("newer full result was unexpectedly rejected")
		}
	case <-time.After(time.Second):
		t.Fatal("newer full result deadlocked behind active publication")
	}

	if fullOvertookPresentation {
		t.Fatal("newer full storage write overtook an in-flight older active presentation")
	}
	stored := storage.LoadURLTestHistory("active")
	if stored == nil || stored.Delay != 91 || stored.CheckGeneration != 5 {
		t.Fatalf("older active presentation overwrote newer full storage: %+v", stored)
	}
	presentation := monitor.OutboundsHistory("")["active"]
	if presentation.Delay != 91 || presentation.CheckGeneration != 5 {
		t.Fatalf("newer full result did not invalidate presentation overlay: %+v", presentation)
	}
}

type activeProbePublicationBarrierStorage struct {
	*urltest.HistoryStorage
	storeCalls           atomic.Int32
	firstStoreEntered    chan struct{}
	releaseFirstStore    chan struct{}
	secondStoreCompleted chan struct{}
}

func newActiveProbePublicationBarrierStorage() *activeProbePublicationBarrierStorage {
	return &activeProbePublicationBarrierStorage{
		HistoryStorage:       urltest.NewHistoryStorage(),
		firstStoreEntered:    make(chan struct{}),
		releaseFirstStore:    make(chan struct{}),
		secondStoreCompleted: make(chan struct{}),
	}
}

func (s *activeProbePublicationBarrierStorage) StoreURLTestHistory(tag string, history *adapter.URLTestHistory) *adapter.URLTestHistory {
	call := s.storeCalls.Add(1)
	if call == 1 {
		close(s.firstStoreEntered)
		<-s.releaseFirstStore
	}
	stored := s.HistoryStorage.StoreURLTestHistory(tag, history)
	if call == 2 {
		close(s.secondStoreCompleted)
	}
	return stored
}

func newActiveProbePresentationTestMonitor(t *testing.T, history adapter.URLTestHistory) *OutboundMonitoring {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return &OutboundMonitoring{
		ctx:     ctx,
		logger:  log.NewNOPFactory().NewLogger("active-probe-presentation-test"),
		history: urltest.NewHistoryStorage(),
		outbounds: map[string]*outboundState{
			"active": {
				groupTags: []string{""},
				history:   history,
			},
		},
		groups: map[string]*groupState{
			"": {
				tag:       "",
				outbounds: map[string]struct{}{"active": {}},
				observer:  NewBroadcaster[GroupEvent](ctx),
				notifyCh:  make(chan struct{}, 1),
			},
		},
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
	}
}

func TestActiveProbeFailureReturnsDecisionEvidence(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	active := newActiveProbeTestOutbound("active")
	active.fail = true
	monitor := &OutboundMonitoring{
		ctx:            ctx,
		logger:         log.NewNOPFactory().NewLogger("active-probe-test"),
		urls:           []string{"http://probe.invalid/generate_204"},
		urlTestTimeout: time.Second,
		outbounds: map[string]*outboundState{
			"active": {outbound: active, history: adapter.URLTestHistory{CheckGeneration: 4}},
		},
		groups:         make(map[string]*groupState),
		runtimeStats:   make(map[string]*adapter.RuntimePenaltyStats),
		runtimeTraffic: make(map[string]*adapter.RuntimeTrafficStats),
	}

	result, err := monitor.ProbeActiveOutbound(ctx, "active")
	if err == nil {
		t.Fatal("failing outbound returned nil error")
	}
	if result.History.Time.IsZero() || result.History.Success || result.History.ErrorType == "" || result.History.ErrorType == urltest.ErrorTypeNone {
		t.Fatalf("failure did not return usable decision evidence: %+v", result)
	}
}
