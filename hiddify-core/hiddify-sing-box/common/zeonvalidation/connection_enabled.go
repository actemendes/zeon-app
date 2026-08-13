//go:build zeon_route_validation

package zeonvalidation

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/logger"
)

type connectionContextKey struct{}

type connectionState struct {
	id           string
	generation   string
	hostname     string
	protocol     string
	outboundType string
	outboundHash string
	openedAt     time.Time
	bytesUp      atomic.Int64
	bytesDown    atomic.Int64
	ended        atomic.Int32
	closed       atomic.Bool
}

type connectionEvent struct {
	Kind         string `json:"kind"`
	ConnectionID string `json:"connectionId"`
	Generation   string `json:"generation"`
	Hostname     string `json:"hostname"`
	Protocol     string `json:"protocol"`
	Outbound     string `json:"outbound"`
	OutboundHash string `json:"outboundHash,omitempty"`
	Stage        string `json:"stage"`
	OpenedAt     string `json:"openedAt"`
	ClosedAt     string `json:"closedAt,omitempty"`
	ElapsedMs    int64  `json:"elapsedMs"`
	BytesUp      int64  `json:"bytesUp"`
	BytesDown    int64  `json:"bytesDown"`
	CloseOwner   string `json:"closeOwner,omitempty"`
	ErrorClass   string `json:"errorClass,omitempty"`
	TransferSide string `json:"transferSide,omitempty"`
}

var connectionSequence atomic.Uint64

// BeginConnection attaches bounded validation state only for explicitly
// allowlisted Stage 2.9 hosts. It never records payload or a plaintext server
// tag/address.
func BeginConnection(
	ctx context.Context,
	log logger.ContextLogger,
	metadata *adapter.InboundContext,
	outboundTag string,
	outboundType string,
	protocol string,
) context.Context {
	if metadata == nil {
		return ctx
	}
	hostname, _, allowed := routeHostname(metadata, routeAddresses(metadata))
	if !allowed {
		return ctx
	}
	now := time.Now().UTC()
	sequence := connectionSequence.Add(1)
	state := &connectionState{
		id:           sessionGeneration() + "-" + formatSequence(sequence),
		generation:   sessionGeneration(),
		hostname:     hostname,
		protocol:     strings.ToUpper(protocol),
		outboundType: sanitizeOutboundType(outboundType),
		outboundHash: hashOpaque(outboundTag, "outbound-tag", sessionGeneration()),
		openedAt:     now,
	}
	emitConnection(log, ctx, state, "OPEN", "", "", "")
	return context.WithValue(ctx, connectionContextKey{}, state)
}

func RecordConnectionDialResult(ctx context.Context, log logger.ContextLogger, err error) {
	state := connectionFromContext(ctx)
	if state == nil {
		return
	}
	if err == nil {
		emitConnection(log, ctx, state, "OUTBOUND_ESTABLISHED", "", "", "")
		return
	}
	if state.closed.CompareAndSwap(false, true) {
		emitConnection(log, ctx, state, "DIAL_FAILED", "OUTBOUND_DIAL", classifyConnectionError(err), "")
	}
}

func RecordConnectionHandshakeResult(ctx context.Context, log logger.ContextLogger, err error) {
	state := connectionFromContext(ctx)
	if state == nil {
		return
	}
	if err == nil {
		emitConnection(log, ctx, state, "STREAM_ESTABLISHED", "", "", "")
		return
	}
	if state.closed.CompareAndSwap(false, true) {
		emitConnection(log, ctx, state, "HANDSHAKE_FAILED", "CLIENT_OR_OUTBOUND", classifyConnectionError(err), "")
	}
}

func RecordConnectionTransferEnd(
	ctx context.Context,
	log logger.ContextLogger,
	download bool,
	bytes int64,
	err error,
) {
	state := connectionFromContext(ctx)
	if state == nil {
		return
	}
	side := "UPLOAD"
	owner := "CLIENT_OR_TUN"
	if download {
		side = "DOWNLOAD"
		owner = "OUTBOUND_OR_DESTINATION"
		state.bytesDown.Add(max64(bytes, 0))
	} else {
		state.bytesUp.Add(max64(bytes, 0))
	}
	emitConnection(log, ctx, state, "TRANSFER_END", owner, classifyConnectionError(err), side)
	if state.ended.Add(1) >= 2 && state.closed.CompareAndSwap(false, true) {
		emitConnection(log, ctx, state, "CLOSED", "BIDIRECTIONAL_SETTLED", classifyConnectionError(err), "")
	}
}

func connectionFromContext(ctx context.Context) *connectionState {
	state, _ := ctx.Value(connectionContextKey{}).(*connectionState)
	return state
}

func emitConnection(
	log logger.ContextLogger,
	ctx context.Context,
	state *connectionState,
	stage string,
	owner string,
	errorClass string,
	transferSide string,
) {
	now := time.Now().UTC()
	event := connectionEvent{
		Kind:         "connection",
		ConnectionID: state.id,
		Generation:   state.generation,
		Hostname:     state.hostname,
		Protocol:     state.protocol,
		Outbound:     state.outboundType,
		OutboundHash: state.outboundHash,
		Stage:        stage,
		OpenedAt:     state.openedAt.Format(time.RFC3339Nano),
		ElapsedMs:    now.Sub(state.openedAt).Milliseconds(),
		BytesUp:      state.bytesUp.Load(),
		BytesDown:    state.bytesDown.Load(),
		CloseOwner:   owner,
		ErrorClass:   errorClass,
		TransferSide: transferSide,
	}
	if stage == "CLOSED" || strings.HasSuffix(stage, "FAILED") {
		event.ClosedAt = now.Format(time.RFC3339Nano)
	}
	payload, err := json.Marshal(event)
	if err != nil {
		return
	}
	message := validationLogPrefix + string(payload)
	emitPlatformEvent(message)
	log.WarnContext(ctx, message)
}

func classifyConnectionError(err error) string {
	if err == nil {
		return "EOF_OR_ORDERLY_CLOSE"
	}
	if errors.Is(err, context.Canceled) {
		return "CONTEXT_CANCELED"
	}
	if errors.Is(err, io.EOF) {
		return "EOF"
	}
	if errors.Is(err, net.ErrClosed) {
		return "LOCAL_SOCKET_CLOSED"
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return "TIMEOUT"
	}
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "reset"):
		return "CONNECTION_RESET"
	case strings.Contains(text, "broken pipe"):
		return "BROKEN_PIPE"
	case strings.Contains(text, "refused"):
		return "CONNECTION_REFUSED"
	case strings.Contains(text, "network is unreachable"), strings.Contains(text, "no route"):
		return "NETWORK_UNREACHABLE"
	default:
		return "IO_ERROR"
	}
}

func sanitizeOutboundType(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	switch value {
	case "DIRECT", "SELECTOR", "URLTEST", "VLESS", "VMESS", "TROJAN", "SHADOWSOCKS", "HYSTERIA2", "TUIC", "WIREGUARD", "ANYTLS", "HTTP", "SOCKS":
		return value
	case "":
		return "UNKNOWN"
	default:
		return "OTHER"
	}
}

func hashOpaque(value string, namespace string, generation string) string {
	if value == "" || !telemetry.saltReady {
		return ""
	}
	mac := hmac.New(sha256.New, telemetry.salt[:])
	_, _ = mac.Write([]byte(namespace))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(generation))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(value))
	return "hmac-sha256:" + hex.EncodeToString(mac.Sum(nil)[:16])
}

func formatSequence(value uint64) string {
	return strconv.FormatUint(value, 10)
}

func max64(value int64, minimum int64) int64 {
	if value < minimum {
		return minimum
	}
	return value
}
