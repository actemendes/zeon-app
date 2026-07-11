package adapter

import (
	"bytes"
	"context"
	"encoding/binary"
	"time"

	"github.com/sagernet/sing-box/hiddify/ipinfo"
	"github.com/sagernet/sing/common/observable"
	"github.com/sagernet/sing/common/varbin"
)

type ClashServer interface {
	LifecycleService
	ConnectionTracker
	Mode() string
	ModeList() []string
	SetModeUpdateHook(hook *observable.Subscriber[struct{}])
	HistoryStorage() URLTestHistoryStorage
}

type URLTestHistory struct {
	Time              time.Time      `json:"time"`
	Delay             uint16         `json:"delay"`
	IpInfo            *ipinfo.IpInfo `json:"ipinfo"`
	IsFromCache       bool           `json:"from_cache"`
	Success           bool           `json:"success,omitempty"`
	ErrorType         string         `json:"error_type,omitempty"`
	ErrorText         string         `json:"error_text,omitempty"`
	URLTestStatus     string         `json:"url_test_status,omitempty"`
	HealthScore       int            `json:"health_score,omitempty"`
	RuntimePenalty    int            `json:"runtime_penalty,omitempty"`
	RealUserPenalty   int            `json:"real_user_penalty,omitempty"`
	FreshnessPenalty  int            `json:"freshness_penalty,omitempty"`
	VolatilityPenalty int            `json:"volatility_penalty,omitempty"`
	StabilityPoints   int            `json:"stability_points,omitempty"`
	DegradationPoints int            `json:"degradation_points,omitempty"`
	PolicyPenalty     int            `json:"policy_penalty,omitempty"`
	UDPProbeAvailable bool           `json:"udp_probe_available,omitempty"`
	UDPPenalty        int            `json:"udp_penalty,omitempty"`
	UDPLoss           float64        `json:"udp_loss,omitempty"`
	UDPJitterMs       int            `json:"udp_jitter_ms,omitempty"`
	CheckGeneration   uint64         `json:"check_generation,omitempty"`
	PingReady         bool           `json:"ping_ready,omitempty"`
	QualityReady      bool           `json:"quality_ready,omitempty"`
	SpeedReady        bool           `json:"speed_ready,omitempty"`
	UDPReady          bool           `json:"udp_ready,omitempty"`
	CombinedReady     bool           `json:"combined_ready,omitempty"`
}

type RuntimePenaltyStats struct {
	Tag             string    `json:"tag"`
	TimeoutCount    int       `json:"timeout_count"`
	ResetCount      int       `json:"reset_count"`
	RefusedCount    int       `json:"refused_count"`
	EOFCount        int       `json:"eof_count"`
	BrokenPipeCount int       `json:"broken_pipe_count"`
	DNSErrorCount   int       `json:"dns_error_count"`
	TLSErrorCount   int       `json:"tls_error_count"`
	QUICErrorCount  int       `json:"quic_error_count"`
	WindowStartedAt time.Time `json:"window_started_at,omitempty"`
	BurstScore      int       `json:"burst_score,omitempty"`
	UpdatedAt       time.Time `json:"updated_at"`
	Penalty         int       `json:"penalty"`
}

type RuntimeTrafficStats struct {
	Tag               string
	UploadBytes       int64
	DownloadBytes     int64
	LastUploadAt      time.Time
	LastDownloadAt    time.Time
	UpdatedAt         time.Time
	LastProbeAt       time.Time
	UploadOnlySamples int
	CleanSamples      int
}

type URLTestHistoryStorage interface {
	SetHook(hook *observable.Subscriber[struct{}])
	LoadURLTestHistory(tag string) *URLTestHistory
	DeleteURLTestHistory(tag string)
	StoreURLTestHistory(tag string, history *URLTestHistory) *URLTestHistory
	AddOnlyIpToHistory(tag string, history *URLTestHistory)
	Close() error
}

type V2RayServer interface {
	LifecycleService
	StatsService() ConnectionTracker
}

type CacheFile interface {
	LifecycleService

	StoreFakeIP() bool
	FakeIPStorage

	StoreRDRC() bool
	RDRCStore

	StoreWARPConfig() bool

	LoadMode() string
	StoreMode(mode string) error
	LoadSelected(group string) string
	StoreSelected(group string, selected string) error
	LoadGroupExpand(group string) (isExpand bool, loaded bool)
	StoreGroupExpand(group string, expand bool) error
	LoadRuleSet(tag string) *SavedBinary
	SaveRuleSet(tag string, set *SavedBinary) error
	LoadBinary(tag string) *SavedBinary
	SaveBinary(tag string, set *SavedBinary) error
}

type SavedBinary struct {
	Content     []byte
	LastUpdated time.Time
	LastEtag    string
}

func (s *SavedBinary) MarshalBinary() ([]byte, error) {
	var buffer bytes.Buffer
	err := binary.Write(&buffer, binary.BigEndian, uint8(1))
	if err != nil {
		return nil, err
	}
	err = varbin.Write(&buffer, binary.BigEndian, s.Content)
	if err != nil {
		return nil, err
	}
	err = binary.Write(&buffer, binary.BigEndian, s.LastUpdated.Unix())
	if err != nil {
		return nil, err
	}
	err = varbin.Write(&buffer, binary.BigEndian, s.LastEtag)
	if err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func (s *SavedBinary) UnmarshalBinary(data []byte) error {
	reader := bytes.NewReader(data)
	var version uint8
	err := binary.Read(reader, binary.BigEndian, &version)
	if err != nil {
		return err
	}
	err = varbin.Read(reader, binary.BigEndian, &s.Content)
	if err != nil {
		return err
	}
	var lastUpdated int64
	err = binary.Read(reader, binary.BigEndian, &lastUpdated)
	if err != nil {
		return err
	}
	s.LastUpdated = time.Unix(lastUpdated, 0)
	err = varbin.Read(reader, binary.BigEndian, &s.LastEtag)
	if err != nil {
		return err
	}
	return nil
}

type OutboundGroup interface {
	Outbound
	Now() string
	All() []string
}

type URLTestGroup interface {
	OutboundGroup
	URLTest(ctx context.Context) (map[string]uint16, error)
}

func OutboundTag(detour Outbound) string {
	if group, isGroup := detour.(OutboundGroup); isGroup {
		return group.Now()
	}
	return detour.Tag()
}
