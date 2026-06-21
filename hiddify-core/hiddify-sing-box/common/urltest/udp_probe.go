package urltest

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	UDPProbeErrorUnsupported = "udp_not_supported"
	UDPProbeErrorBadResponse = "bad_response"

	udpProbeMagic        = "ZEONUDP1"
	udpProbeVersion      = 1
	udpProbeTypeRequest  = 1
	udpProbeTypeResponse = 2
	udpProbeHeaderLen    = 48
	udpProbeHMACLen      = 32
	udpProbeMinPacket    = 96
	udpProbeMaxPacket    = 1200
	udpProbeMaxSkew      = 30 * time.Second
)

type UDPProbeOptions struct {
	Count    int
	Size     int
	Interval time.Duration
	Timeout  time.Duration
}

type UDPProbeResult struct {
	Available bool
	Sent      int
	Received  int
	Loss      float64
	RTTMinMs  int
	RTTAvgMs  int
	RTTMaxMs  int
	JitterMs  int
	Penalty   int
	ErrorType string
	ErrorText string
	UpdatedAt time.Time
}

type udpProbeHeader struct {
	Version     byte
	PacketType  byte
	TimestampNS int64
	SessionID   [16]byte
	Seq         uint32
	Count       uint32
	PayloadLen  uint16
}

func ParseUDPProbeSecret(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("udp probe secret is empty")
	}
	if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) >= 16 {
		return decoded, nil
	}
	if len(raw) < 16 {
		return nil, errors.New("udp probe secret must be at least 16 bytes")
	}
	return []byte(raw), nil
}

func DefaultUDPProbeOptions() UDPProbeOptions {
	return UDPProbeOptions{
		Count:    10,
		Size:     160,
		Interval: 40 * time.Millisecond,
		Timeout:  1000 * time.Millisecond,
	}
}

func RunUDPProbeThroughOutbound(ctx context.Context, outbound adapter.Outbound, endpoint string, secret []byte, options UDPProbeOptions) UDPProbeResult {
	now := time.Now()
	result := UDPProbeResult{
		Available: false,
		ErrorType: UDPProbeErrorUnsupported,
		UpdatedAt: now,
	}
	if outbound == nil {
		result.ErrorText = "outbound is nil"
		return result
	}
	if len(secret) == 0 {
		result.ErrorText = "missing secret"
		return result
	}
	options = normalizeUDPProbeOptions(options)

	destination, err := parseUDPProbeEndpoint(endpoint)
	if err != nil {
		result.ErrorType, result.ErrorText = ClassifyProbeError(err)
		return result
	}

	conn, err := outbound.ListenPacket(ctx, destination)
	if err != nil {
		result.ErrorType, result.ErrorText = classifyUDPProbeError(err)
		if result.ErrorType == UDPProbeErrorUnsupported {
			result.Available = false
			result.Penalty = 0
		} else {
			result.Available = true
			result.Penalty = 12
		}
		return result
	}
	defer conn.Close()

	result.Available = true
	result.Sent = options.Count
	result.ErrorType = ErrorTypeNone

	var session [16]byte
	if _, err = rand.Read(session[:]); err != nil {
		result.ErrorType, result.ErrorText = ClassifyProbeError(err)
		result.Penalty = 0
		return result
	}

	payloadSize := options.Size - udpProbeHeaderLen - udpProbeHMACLen
	rttsBySeq := make(map[uint32]time.Duration, options.Count)
	rttsInOrder := make([]time.Duration, 0, options.Count)
	readBuffer := make([]byte, udpProbeMaxPacket)

	for seq := 0; seq < options.Count; seq++ {
		payload := make([]byte, payloadSize)
		binary.BigEndian.PutUint32(payload[:4], uint32(seq))
		for i := 4; i < len(payload); i++ {
			payload[i] = byte(seq + i)
		}
		packet := buildUDPProbePacket(udpProbeTypeRequest, time.Now().UnixNano(), session, uint32(seq), uint32(options.Count), payload, secret)

		start := time.Now()
		if _, err = conn.WriteTo(packet, destination); err != nil {
			result.ErrorType, result.ErrorText = ClassifyProbeError(err)
			break
		}

		_ = conn.SetReadDeadline(time.Now().Add(options.Timeout))
		n, _, readErr := conn.ReadFrom(readBuffer)
		if readErr != nil {
			if result.ErrorType == ErrorTypeNone {
				result.ErrorType, result.ErrorText = ClassifyProbeError(readErr)
			}
		} else if response, _, parseErr := parseUDPProbePacket(readBuffer[:n], secret, time.Now(), udpProbeTypeResponse); parseErr != nil {
			result.ErrorType = UDPProbeErrorBadResponse
			result.ErrorText = shortenErrorText(parseErr.Error())
		} else if response.SessionID == session && response.Seq == uint32(seq) {
			rtt := time.Since(start)
			rttsBySeq[uint32(seq)] = rtt
			rttsInOrder = append(rttsInOrder, rtt)
		}

		if seq != options.Count-1 {
			select {
			case <-ctx.Done():
				result.ErrorType, result.ErrorText = ClassifyProbeError(ctx.Err())
				seq = options.Count
			case <-time.After(options.Interval):
			}
		}
	}

	result.Received = len(rttsBySeq)
	if result.Sent <= 0 {
		result.Sent = options.Count
	}
	result.Loss = float64(result.Sent-result.Received) * 100 / float64(result.Sent)
	result.RTTMinMs, result.RTTAvgMs, result.RTTMaxMs = summarizeRTT(rttsInOrder)
	result.JitterMs = calculateJitterMs(rttsInOrder)
	result.Penalty = CalculateUDPPenalty(result.Loss, result.JitterMs)
	if result.Received == 0 && result.ErrorType == ErrorTypeNone {
		result.ErrorType = ErrorTypeTimeout
	}
	if result.Received > 0 {
		result.ErrorType = ErrorTypeNone
		result.ErrorText = ""
	}
	result.UpdatedAt = time.Now()
	return result
}

func CalculateUDPPenalty(loss float64, jitterMs int) int {
	penalty := 0
	switch {
	case loss <= 0:
	case loss <= 5:
		penalty += 4
	case loss <= 15:
		penalty += 9
	default:
		penalty += 14
	}
	switch {
	case jitterMs < 30:
	case jitterMs <= 80:
		penalty += 4
	default:
		penalty += 9
	}
	if penalty > 15 {
		return 15
	}
	return penalty
}

func normalizeUDPProbeOptions(options UDPProbeOptions) UDPProbeOptions {
	defaults := DefaultUDPProbeOptions()
	if options.Count <= 0 {
		options.Count = defaults.Count
	}
	if options.Count > 20 {
		options.Count = 20
	}
	if options.Size <= 0 {
		options.Size = defaults.Size
	}
	if options.Size < udpProbeMinPacket {
		options.Size = udpProbeMinPacket
	}
	if options.Size > udpProbeMaxPacket {
		options.Size = udpProbeMaxPacket
	}
	if options.Interval <= 0 {
		options.Interval = defaults.Interval
	}
	if options.Timeout <= 0 {
		options.Timeout = defaults.Timeout
	}
	return options
}

func parseUDPProbeEndpoint(endpoint string) (M.Socksaddr, error) {
	if endpoint == "" {
		endpoint = "udp-probe.zeon-vps.link:8443"
	}
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		if strings.Count(endpoint, ":") == 0 {
			host = endpoint
			port = "8443"
		} else {
			return M.Socksaddr{}, err
		}
	}
	destination := M.ParseSocksaddrHostPortStr(host, port)
	if !destination.IsValid() || destination.Port == 0 {
		return M.Socksaddr{}, fmt.Errorf("invalid udp probe endpoint: %s", endpoint)
	}
	return destination, nil
}

func classifyUDPProbeError(err error) (string, string) {
	errorType, errorText := ClassifyProbeError(err)
	lower := strings.ToLower(errorText)
	if errors.Is(err, net.ErrClosed) ||
		strings.Contains(lower, "invalid argument") ||
		strings.Contains(lower, "operation not supported") ||
		strings.Contains(lower, "unsupported network") ||
		strings.Contains(lower, "missing supported outbound") ||
		strings.Contains(lower, "domain destination is not supported") {
		return UDPProbeErrorUnsupported, errorText
	}
	return errorType, errorText
}

func buildUDPProbePacket(packetType byte, timestampNS int64, session [16]byte, seq, count uint32, payload []byte, secret []byte) []byte {
	packet := make([]byte, udpProbeHeaderLen+len(payload)+udpProbeHMACLen)
	copy(packet[:8], udpProbeMagic)
	packet[8] = udpProbeVersion
	packet[9] = packetType
	binary.BigEndian.PutUint16(packet[10:12], udpProbeHeaderLen)
	binary.BigEndian.PutUint64(packet[12:20], uint64(timestampNS))
	copy(packet[20:36], session[:])
	binary.BigEndian.PutUint32(packet[36:40], seq)
	binary.BigEndian.PutUint32(packet[40:44], count)
	binary.BigEndian.PutUint16(packet[44:46], uint16(len(payload)))
	copy(packet[udpProbeHeaderLen:udpProbeHeaderLen+len(payload)], payload)
	copy(packet[len(packet)-udpProbeHMACLen:], udpProbeMAC(secret, packet[:len(packet)-udpProbeHMACLen]))
	return packet
}

func parseUDPProbePacket(packet []byte, secret []byte, now time.Time, wantType byte) (udpProbeHeader, []byte, error) {
	var header udpProbeHeader
	if len(packet) < udpProbeMinPacket || len(packet) > udpProbeMaxPacket {
		return header, nil, fmt.Errorf("invalid packet size %d", len(packet))
	}
	if !hmac.Equal(packet[len(packet)-udpProbeHMACLen:], udpProbeMAC(secret, packet[:len(packet)-udpProbeHMACLen])) {
		return header, nil, errors.New("invalid hmac")
	}
	if string(packet[:8]) != udpProbeMagic {
		return header, nil, errors.New("invalid magic")
	}
	header.Version = packet[8]
	header.PacketType = packet[9]
	if header.Version != udpProbeVersion {
		return header, nil, fmt.Errorf("unsupported version %d", header.Version)
	}
	if header.PacketType != wantType {
		return header, nil, fmt.Errorf("unexpected packet type %d", header.PacketType)
	}
	if binary.BigEndian.Uint16(packet[10:12]) != udpProbeHeaderLen {
		return header, nil, errors.New("invalid header length")
	}
	header.TimestampNS = int64(binary.BigEndian.Uint64(packet[12:20]))
	copy(header.SessionID[:], packet[20:36])
	header.Seq = binary.BigEndian.Uint32(packet[36:40])
	header.Count = binary.BigEndian.Uint32(packet[40:44])
	header.PayloadLen = binary.BigEndian.Uint16(packet[44:46])
	payloadStart := udpProbeHeaderLen
	payloadEnd := len(packet) - udpProbeHMACLen
	if int(header.PayloadLen) != payloadEnd-payloadStart {
		return header, nil, errors.New("payload length mismatch")
	}
	age := now.Sub(time.Unix(0, header.TimestampNS))
	if age < -udpProbeMaxSkew || age > udpProbeMaxSkew {
		return header, nil, errors.New("stale timestamp")
	}
	return header, packet[payloadStart:payloadEnd], nil
}

func udpProbeMAC(secret []byte, body []byte) []byte {
	h := hmac.New(sha256.New, secret)
	_, _ = h.Write(body)
	return h.Sum(nil)
}

func summarizeRTT(rtts []time.Duration) (int, int, int) {
	if len(rtts) == 0 {
		return 0, 0, 0
	}
	sorted := append([]time.Duration(nil), rtts...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	var total time.Duration
	for _, rtt := range rtts {
		total += rtt
	}
	return durationMs(sorted[0]), durationMs(total / time.Duration(len(rtts))), durationMs(sorted[len(sorted)-1])
}

func calculateJitterMs(rtts []time.Duration) int {
	if len(rtts) < 2 {
		return 0
	}
	var total time.Duration
	for i := 1; i < len(rtts); i++ {
		diff := rtts[i] - rtts[i-1]
		if diff < 0 {
			diff = -diff
		}
		total += diff
	}
	return durationMs(total / time.Duration(len(rtts)-1))
}

func durationMs(value time.Duration) int {
	if value <= 0 {
		return 0
	}
	ms := int(value.Round(time.Millisecond) / time.Millisecond)
	if ms == 0 {
		return 1
	}
	return ms
}
