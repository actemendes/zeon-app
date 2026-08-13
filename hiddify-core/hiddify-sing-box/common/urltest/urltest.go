package urltest

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/hiddify/ipinfo"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/ntp"
	"github.com/sagernet/sing/common/observable"
)

var _ adapter.URLTestHistoryStorage = (*HistoryStorage)(nil)

type HistoryStorage struct {
	access       sync.RWMutex
	delayHistory map[string]*adapter.URLTestHistory
	updateHook   *observable.Subscriber[struct{}]
}

func NewHistoryStorage() *HistoryStorage {
	return &HistoryStorage{
		delayHistory: make(map[string]*adapter.URLTestHistory),
	}
}

func (s *HistoryStorage) SetHook(hook *observable.Subscriber[struct{}]) {
	s.access.Lock()
	defer s.access.Unlock()
	s.updateHook = hook
}

func (s *HistoryStorage) LoadURLTestHistory(tag string) *adapter.URLTestHistory {
	if s == nil {
		return nil
	}
	s.access.RLock()
	defer s.access.RUnlock()
	return cloneURLTestHistory(s.delayHistory[tag])
}

func (s *HistoryStorage) DeleteURLTestHistory(tag string) {
	s.StoreURLTestHistory(tag, &adapter.URLTestHistory{
		Delay:         65535,
		Time:          time.Now(),
		Success:       false,
		ErrorType:     ErrorTypeUnknown,
		URLTestStatus: StatusFailed,
		HealthScore:   0,
	})
	// s.access.Lock()
	// // delete(s.delayHistory, tag)
	// s.access.Unlock()
	// s.notifyUpdated()
}

func (s *HistoryStorage) StoreURLTestHistory(tag string, history *adapter.URLTestHistory) *adapter.URLTestHistory {
	s.access.Lock()
	if old, ok := s.delayHistory[tag]; ok && history != nil {
		updated := cloneURLTestHistory(old)
		mergeURLTestHistory(updated, history)
		if history.IpInfo != nil {
			updated.IpInfo = cloneIPInfo(history.IpInfo)
		}
		s.delayHistory[tag] = updated
	} else {
		s.delayHistory[tag] = cloneURLTestHistory(history)
	}
	history = cloneURLTestHistory(s.delayHistory[tag])
	s.access.Unlock()
	s.notifyUpdated()
	return history
}

// cloneURLTestHistory makes storage ownership explicit: callers receive an
// immutable snapshot and storage never retains a pointer owned by its caller.
// This prevents a later StoreURLTestHistory call from mutating an object that
// has already been published to UI/ranking readers.
func cloneURLTestHistory(history *adapter.URLTestHistory) *adapter.URLTestHistory {
	if history == nil {
		return nil
	}
	cloned := *history
	cloned.IpInfo = cloneIPInfo(history.IpInfo)
	return &cloned
}

func cloneIPInfo(info *ipinfo.IpInfo) *ipinfo.IpInfo {
	if info == nil {
		return nil
	}
	cloned := *info
	return &cloned
}

func mergeURLTestHistory(old *adapter.URLTestHistory, history *adapter.URLTestHistory) {
	old.Delay = history.Delay
	old.Time = history.Time
	old.IsFromCache = history.IsFromCache
	old.Success = history.Success
	old.ErrorType = history.ErrorType
	old.ErrorText = history.ErrorText
	old.URLTestStatus = history.URLTestStatus
	old.HealthScore = history.HealthScore
	old.RuntimePenalty = history.RuntimePenalty
	old.RealUserPenalty = history.RealUserPenalty
	old.FreshnessPenalty = history.FreshnessPenalty
	old.VolatilityPenalty = history.VolatilityPenalty
	old.StabilityPoints = history.StabilityPoints
	old.DegradationPoints = history.DegradationPoints
	old.PolicyPenalty = history.PolicyPenalty
	old.UDPProbeAvailable = history.UDPProbeAvailable
	old.UDPPenalty = history.UDPPenalty
	old.UDPLoss = history.UDPLoss
	old.UDPJitterMs = history.UDPJitterMs
	old.CheckGeneration = history.CheckGeneration
	old.PingReady = history.PingReady
	old.QualityReady = history.QualityReady
	old.SpeedReady = history.SpeedReady
	old.UDPReady = history.UDPReady
	old.CombinedReady = history.CombinedReady
}

func (s *HistoryStorage) AddOnlyIpToHistory(tag string, history *adapter.URLTestHistory) {
	s.access.Lock()
	if old, ok := s.delayHistory[tag]; ok && history != nil {
		updated := cloneURLTestHistory(old)
		updated.IpInfo = cloneIPInfo(history.IpInfo)
		s.delayHistory[tag] = updated
	} else {
		s.delayHistory[tag] = cloneURLTestHistory(history)
	}
	s.access.Unlock()
	s.notifyUpdated()
}

func (s *HistoryStorage) notifyUpdated() {
	s.access.RLock()
	updateHook := s.updateHook
	s.access.RUnlock()
	if updateHook != nil {
		updateHook.Emit(struct{}{})
	}
}

func (s *HistoryStorage) Close() error {
	s.access.Lock()
	defer s.access.Unlock()
	s.updateHook = nil
	return nil
}

func URLTest(ctx context.Context, link string, detour N.Dialer) (t uint16, err error) {
	if detour == nil {
		err = fmt.Errorf("urltest dialer is nil")
		return
	}
	if link == "" {
		link = "https://www.gstatic.com/generate_204"
	}
	linkURL, err := url.Parse(link)
	if err != nil {
		return
	}
	hostname := linkURL.Hostname()
	port := linkURL.Port()
	if port == "" {
		switch linkURL.Scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		}
	}

	start := time.Now()
	instance, err := detour.DialContext(ctx, "tcp", M.ParseSocksaddrHostPortStr(hostname, port))
	if err != nil {
		return
	}
	defer instance.Close()
	if N.NeedHandshakeForWrite(instance) {
		start = time.Now()
	}
	req, err := http.NewRequest(http.MethodHead, link, nil)
	if err != nil {
		return
	}
	select {
	case <-ctx.Done():
		return
	default:
	}
	client := http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return instance, nil
			},
			TLSClientConfig: &tls.Config{
				Time:    ntp.TimeFuncFromContext(ctx),
				RootCAs: adapter.RootPoolFromContext(ctx),
			},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: C.TCPTimeout,
	}
	defer client.CloseIdleConnections()
	select {
	case <-ctx.Done():
		return
	default:
	}
	resp, err := client.Do(req.WithContext(ctx))
	if err != nil {
		return
	}
	resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusBadRequest {
		err = fmt.Errorf("bad status: %s", resp.Status)
		return
	}

	t = uint16(time.Since(start) / time.Millisecond)

	if IsUnifiedDelayFromContext(ctx) {
		select {
		case <-ctx.Done():
			return
		default:
		}
		second := time.Now()
		resp, err = client.Do(req)
		if err != nil {
			return
		}
		resp.Body.Close()
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusBadRequest {
			err = fmt.Errorf("bad status: %s", resp.Status)
			return
		}
		t = uint16(time.Since(second) / time.Millisecond) //to avid timeout in the second call
	}
	return
}
