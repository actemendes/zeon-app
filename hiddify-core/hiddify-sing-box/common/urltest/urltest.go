package urltest

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
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
	s.updateHook = hook
}

func (s *HistoryStorage) LoadURLTestHistory(tag string) *adapter.URLTestHistory {
	if s == nil {
		return nil
	}
	s.access.RLock()
	defer s.access.RUnlock()
	return s.delayHistory[tag]
}

func (s *HistoryStorage) DeleteURLTestHistory(tag string) {
	s.StoreURLTestHistory(tag, &adapter.URLTestHistory{
		Delay: 65535,
		Time:  time.Now(),
	})
	// s.access.Lock()
	// // delete(s.delayHistory, tag)
	// s.access.Unlock()
	// s.notifyUpdated()
}

func (s *HistoryStorage) StoreURLTestHistory(tag string, history *adapter.URLTestHistory) *adapter.URLTestHistory {
	s.access.Lock()
	if old, ok := s.delayHistory[tag]; ok && history != nil {
		old.Delay = history.Delay
		old.Time = history.Time
		if history.IpInfo != nil {
			old.IpInfo = history.IpInfo
		}
		old.QualityScore = history.QualityScore
		old.QualityLevel = history.QualityLevel
		old.AutoAllowed = history.AutoAllowed
		old.LastError = history.LastError
		old.CheckedAt = history.CheckedAt
		old.SpeedKbps = history.SpeedKbps
		old.SpeedScore = history.SpeedScore
		old.SpeedLevel = history.SpeedLevel
		old.SpeedSource = history.SpeedSource
		old.SpeedTestBytes = history.SpeedTestBytes
		old.SpeedTestDurationMs = history.SpeedTestDurationMs
		old.SpeedCheckedAt = history.SpeedCheckedAt
		old.ExternalHealthScore = history.ExternalHealthScore
		old.ExternalHealthLevel = history.ExternalHealthLevel
		old.CombinedHealthScore = history.CombinedHealthScore
		old.CombinedHealthLevel = history.CombinedHealthLevel
		old.HealthReason = history.HealthReason
	} else {
		s.delayHistory[tag] = history
	}
	history = s.delayHistory[tag]
	s.access.Unlock()
	s.notifyUpdated()
	return history
}

func (s *HistoryStorage) AddOnlyIpToHistory(tag string, history *adapter.URLTestHistory) {
	s.access.Lock()
	if old, ok := s.delayHistory[tag]; ok && history != nil {
		old.IpInfo = history.IpInfo
	} else {
		s.delayHistory[tag] = history
	}
	s.access.Unlock()
	s.notifyUpdated()
}

func (s *HistoryStorage) notifyUpdated() {
	updateHook := s.updateHook
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
		t = uint16(time.Since(second) / time.Millisecond) //to avid timeout in the second call
	}
	return
}

type MicroDownloadResult struct {
	Bytes      int32
	DurationMs int32
	SpeedKbps  int32
}

type MicroReachabilityResult struct {
	TTFBMs int32
}

func MicroDownloadTest(ctx context.Context, link string, detour N.Dialer, maxBytes int) (result MicroDownloadResult, err error) {
	if detour == nil {
		return result, fmt.Errorf("micro download dialer is nil")
	}
	if link == "" {
		return result, fmt.Errorf("micro download link is empty")
	}
	if maxBytes <= 0 {
		return result, fmt.Errorf("micro download max bytes is invalid")
	}
	linkURL, err := url.Parse(link)
	if err != nil {
		return result, err
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

	instance, err := detour.DialContext(ctx, "tcp", M.ParseSocksaddrHostPortStr(hostname, port))
	if err != nil {
		return result, err
	}
	defer instance.Close()

	req, err := http.NewRequest(http.MethodGet, link, nil)
	if err != nil {
		return result, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", maxBytes-1))

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

	start := time.Now()
	resp, err := client.Do(req.WithContext(ctx))
	if err != nil {
		return result, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= http.StatusBadRequest {
		return result, fmt.Errorf("micro download status %d", resp.StatusCode)
	}
	bytesRead, err := io.Copy(io.Discard, io.LimitReader(resp.Body, int64(maxBytes)))
	if err != nil {
		return result, err
	}
	duration := time.Since(start)
	if bytesRead <= 0 {
		return result, fmt.Errorf("micro download returned empty body")
	}
	durationMs := int32(duration / time.Millisecond)
	if durationMs <= 0 {
		durationMs = 1
	}
	speedKbps := int32((bytesRead * 8 * 1000) / int64(durationMs) / 1000)
	if speedKbps < 1 {
		speedKbps = 1
	}
	return MicroDownloadResult{
		Bytes:      int32(bytesRead),
		DurationMs: durationMs,
		SpeedKbps:  speedKbps,
	}, nil
}

func MicroReachabilityTest(ctx context.Context, link string, detour N.Dialer) (result MicroReachabilityResult, err error) {
	if detour == nil {
		return result, fmt.Errorf("micro reachability dialer is nil")
	}
	if link == "" {
		return result, fmt.Errorf("micro reachability link is empty")
	}
	linkURL, err := url.Parse(link)
	if err != nil {
		return result, err
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

	instance, err := detour.DialContext(ctx, "tcp", M.ParseSocksaddrHostPortStr(hostname, port))
	if err != nil {
		return result, err
	}
	defer instance.Close()

	req, err := http.NewRequest(http.MethodGet, link, nil)
	if err != nil {
		return result, err
	}
	req.Header.Set("Range", "bytes=0-0")

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

	start := time.Now()
	resp, err := client.Do(req.WithContext(ctx))
	if err != nil {
		return result, err
	}
	resp.Body.Close()
	if resp.StatusCode >= http.StatusBadRequest {
		return result, fmt.Errorf("micro reachability status %d", resp.StatusCode)
	}
	ttfbMs := int32(time.Since(start) / time.Millisecond)
	if ttfbMs <= 0 {
		ttfbMs = 1
	}
	return MicroReachabilityResult{TTFBMs: ttfbMs}, nil
}
