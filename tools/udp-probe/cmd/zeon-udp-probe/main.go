package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	magic              = "ZEONUDP1"
	versionByte        = 1
	packetTypeRequest  = 1
	packetTypeResponse = 2
	headerLen          = 48
	hmacLen            = 32
	minPacketSize      = 96
	maxPacketSize      = 1200
	maxSkew            = 30 * time.Second
)

type packetHeader struct {
	Version     byte
	PacketType  byte
	TimestampNS int64
	SessionID   [16]byte
	Seq         uint32
	Count       uint32
	PayloadLen  uint16
}

type stats struct {
	valid       atomic.Uint64
	invalid     atomic.Uint64
	rateLimited atomic.Uint64
	bytesIn     atomic.Uint64
	bytesOut    atomic.Uint64
}

type tokenBucket struct {
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
}

func newBucket(rate, burst int, now time.Time) *tokenBucket {
	if rate <= 0 {
		rate = 1
	}
	if burst <= 0 {
		burst = rate
	}
	return &tokenBucket{
		rate:   float64(rate),
		burst:  float64(burst),
		tokens: float64(burst),
		last:   now,
	}
}

func (b *tokenBucket) allow(now time.Time) bool {
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens = math.Min(b.burst, b.tokens+elapsed*b.rate)
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

type limiter struct {
	mu         sync.Mutex
	global     *tokenBucket
	perIPRate  int
	perIPBurst int
	byIP       map[netip.Addr]*tokenBucket
}

func newLimiter(globalPPS, globalBurst, perIPRate, perIPBurst int) *limiter {
	now := time.Now()
	return &limiter{
		global:     newBucket(globalPPS, globalBurst, now),
		perIPRate:  perIPRate,
		perIPBurst: perIPBurst,
		byIP:       make(map[netip.Addr]*tokenBucket),
	}
}

func (l *limiter) allow(addr netip.Addr, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	if !l.global.allow(now) {
		return false
	}

	bucket := l.byIP[addr]
	if bucket == nil {
		bucket = newBucket(l.perIPRate, l.perIPBurst, now)
		l.byIP[addr] = bucket
	}

	if len(l.byIP) > 4096 {
		for ip, b := range l.byIP {
			if now.Sub(b.last) > 5*time.Minute {
				delete(l.byIP, ip)
			}
		}
	}

	return bucket.allow(now)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "server":
		if err := runServer(os.Args[2:]); err != nil {
			log.Fatal(err)
		}
	case "client":
		if err := runClient(os.Args[2:]); err != nil {
			log.Fatal(err)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: %s <server|client> [options]\n", os.Args[0])
}

func runServer(args []string) error {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	listen := fs.String("listen", ":8443", "UDP listen address")
	globalPPS := fs.Int("global-pps", 2000, "global packets per second limit")
	globalBurst := fs.Int("global-burst", 2000, "global token bucket burst")
	perIPRate := fs.Int("per-ip-pps", 50, "per-source IP packets per second limit")
	perIPBurst := fs.Int("per-ip-burst", 100, "per-source IP token bucket burst")
	statsEvery := fs.Duration("stats-interval", 60*time.Second, "stats log interval")
	if err := fs.Parse(args); err != nil {
		return err
	}

	secret, err := loadSecret("")
	if err != nil {
		return err
	}

	conn, err := net.ListenPacket("udp", *listen)
	if err != nil {
		return err
	}
	defer conn.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var counters stats
	lim := newLimiter(*globalPPS, *globalBurst, *perIPRate, *perIPBurst)

	log.Printf("[UDPProbe] listening udp addr=%s min_packet=%d max_packet=%d", conn.LocalAddr().String(), minPacketSize, maxPacketSize)
	go logStats(ctx, &counters, *statsEvery)

	buf := make([]byte, maxPacketSize)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				select {
				case <-ctx.Done():
					log.Printf("[UDPProbe] stopped")
					return nil
				default:
					continue
				}
			}
			return err
		}

		counters.bytesIn.Add(uint64(n))
		now := time.Now()
		udpAddr, ok := addr.(*net.UDPAddr)
		if !ok {
			counters.invalid.Add(1)
			continue
		}
		src, ok := netip.AddrFromSlice(udpAddr.IP)
		if !ok {
			counters.invalid.Add(1)
			continue
		}
		if !lim.allow(src.Unmap(), now) {
			counters.rateLimited.Add(1)
			continue
		}

		req := append([]byte(nil), buf[:n]...)
		h, payload, err := parseAndVerify(req, secret, now, packetTypeRequest)
		if err != nil {
			counters.invalid.Add(1)
			continue
		}

		recvTime := time.Now()
		resp := buildResponse(h, payload, secret, recvTime, len(req))
		if len(resp) == 0 || len(resp) > len(req) {
			counters.invalid.Add(1)
			continue
		}
		written, err := conn.WriteTo(resp, addr)
		if err != nil {
			counters.invalid.Add(1)
			continue
		}
		counters.valid.Add(1)
		counters.bytesOut.Add(uint64(written))
	}
}

func logStats(ctx context.Context, counters *stats, every time.Duration) {
	if every <= 0 {
		return
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			log.Printf("[UDPProbe] stats packets_valid=%d packets_invalid=%d rate_limited=%d bytes_in=%d bytes_out=%d",
				counters.valid.Load(),
				counters.invalid.Load(),
				counters.rateLimited.Load(),
				counters.bytesIn.Load(),
				counters.bytesOut.Load(),
			)
		}
	}
}

func runClient(args []string) error {
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:8443", "UDP probe address")
	secretFlag := fs.String("secret", "", "HMAC secret hex or text; defaults to ZEON_UDP_PROBE_SECRET")
	count := fs.Int("count", 20, "packet count")
	interval := fs.Duration("interval", 50*time.Millisecond, "interval between packets")
	size := fs.Int("size", 160, "request packet size in bytes")
	timeout := fs.Duration("timeout", 2*time.Second, "read timeout per packet")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *count <= 0 {
		return errors.New("count must be positive")
	}
	if *size < minPacketSize || *size > maxPacketSize {
		return fmt.Errorf("size must be between %d and %d bytes", minPacketSize, maxPacketSize)
	}

	secret, err := loadSecret(*secretFlag)
	if err != nil {
		return err
	}
	raddr, err := net.ResolveUDPAddr("udp", *addr)
	if err != nil {
		return err
	}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		return err
	}
	defer conn.Close()

	var session [16]byte
	if _, err := rand.Read(session[:]); err != nil {
		return err
	}

	rtts := make([]time.Duration, 0, *count)
	received := 0
	payloadSize := *size - headerLen - hmacLen
	buf := make([]byte, maxPacketSize)

	for seq := 0; seq < *count; seq++ {
		payload := make([]byte, payloadSize)
		binary.BigEndian.PutUint32(payload[:4], uint32(seq))
		for i := 4; i < len(payload); i++ {
			payload[i] = byte(i + seq)
		}
		req := buildPacket(packetTypeRequest, time.Now().UnixNano(), session, uint32(seq), uint32(*count), payload, secret)
		start := time.Now()
		if _, err := conn.Write(req); err != nil {
			log.Printf("seq=%d send_error=%v", seq, err)
			continue
		}

		_ = conn.SetReadDeadline(time.Now().Add(*timeout))
		n, err := conn.Read(buf)
		if err != nil {
			log.Printf("seq=%d timeout_or_read_error=%v", seq, err)
		} else {
			rtt := time.Since(start)
			h, respPayload, err := parseAndVerify(buf[:n], secret, time.Now(), packetTypeResponse)
			if err != nil {
				log.Printf("seq=%d invalid_response=%v", seq, err)
			} else if h.SessionID != session || h.Seq != uint32(seq) {
				log.Printf("seq=%d mismatched_response session_or_seq", seq)
			} else if len(respPayload) < 16 {
				log.Printf("seq=%d invalid_response_payload", seq)
			} else {
				serverRecv := int64(binary.BigEndian.Uint64(respPayload[:8]))
				serverSend := int64(binary.BigEndian.Uint64(respPayload[8:16]))
				_ = serverRecv
				_ = serverSend
				received++
				rtts = append(rtts, rtt)
			}
		}

		if seq != *count-1 {
			time.Sleep(*interval)
		}
	}

	printClientSummary(*count, received, rtts)
	return nil
}

func loadSecret(flagValue string) ([]byte, error) {
	raw := strings.TrimSpace(flagValue)
	if raw == "" {
		raw = strings.TrimSpace(os.Getenv("ZEON_UDP_PROBE_SECRET"))
	}
	if raw == "" {
		return nil, errors.New("ZEON_UDP_PROBE_SECRET is required")
	}

	if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) >= 16 {
		return decoded, nil
	}
	if len(raw) < 16 {
		return nil, errors.New("secret must be at least 16 bytes, or a hex string that decodes to at least 16 bytes")
	}
	return []byte(raw), nil
}

func parseAndVerify(packet []byte, secret []byte, now time.Time, wantType byte) (packetHeader, []byte, error) {
	var h packetHeader
	if len(packet) < minPacketSize || len(packet) > maxPacketSize {
		return h, nil, fmt.Errorf("invalid packet size %d", len(packet))
	}
	if !hmac.Equal(packet[len(packet)-hmacLen:], mac(secret, packet[:len(packet)-hmacLen])) {
		return h, nil, errors.New("invalid hmac")
	}
	if string(packet[:8]) != magic {
		return h, nil, errors.New("invalid magic")
	}
	h.Version = packet[8]
	h.PacketType = packet[9]
	if h.Version != versionByte {
		return h, nil, fmt.Errorf("unsupported version %d", h.Version)
	}
	if h.PacketType != wantType {
		return h, nil, fmt.Errorf("unexpected packet type %d", h.PacketType)
	}
	if binary.BigEndian.Uint16(packet[10:12]) != headerLen {
		return h, nil, errors.New("invalid header length")
	}
	h.TimestampNS = int64(binary.BigEndian.Uint64(packet[12:20]))
	copy(h.SessionID[:], packet[20:36])
	h.Seq = binary.BigEndian.Uint32(packet[36:40])
	h.Count = binary.BigEndian.Uint32(packet[40:44])
	h.PayloadLen = binary.BigEndian.Uint16(packet[44:46])

	payloadStart := headerLen
	payloadEnd := len(packet) - hmacLen
	if int(h.PayloadLen) != payloadEnd-payloadStart {
		return h, nil, errors.New("payload length mismatch")
	}
	if h.TimestampNS <= 0 {
		return h, nil, errors.New("invalid timestamp")
	}
	age := now.Sub(time.Unix(0, h.TimestampNS))
	if age < -maxSkew || age > maxSkew {
		return h, nil, errors.New("stale timestamp")
	}

	payload := packet[payloadStart:payloadEnd]
	return h, payload, nil
}

func buildResponse(req packetHeader, reqPayload []byte, secret []byte, recvTime time.Time, maxLen int) []byte {
	sendTime := time.Now()
	maxPayload := maxLen - headerLen - hmacLen
	if maxPayload < 16 {
		return nil
	}
	payload := make([]byte, maxPayload)
	binary.BigEndian.PutUint64(payload[:8], uint64(recvTime.UnixNano()))
	binary.BigEndian.PutUint64(payload[8:16], uint64(sendTime.UnixNano()))
	echoLen := min(len(reqPayload), maxPayload-16)
	copy(payload[16:16+echoLen], reqPayload[:echoLen])
	payload = payload[:16+echoLen]
	return buildPacket(packetTypeResponse, sendTime.UnixNano(), req.SessionID, req.Seq, req.Count, payload, secret)
}

func buildPacket(packetType byte, timestampNS int64, session [16]byte, seq, count uint32, payload []byte, secret []byte) []byte {
	packet := make([]byte, headerLen+len(payload)+hmacLen)
	copy(packet[:8], magic)
	packet[8] = versionByte
	packet[9] = packetType
	binary.BigEndian.PutUint16(packet[10:12], headerLen)
	binary.BigEndian.PutUint64(packet[12:20], uint64(timestampNS))
	copy(packet[20:36], session[:])
	binary.BigEndian.PutUint32(packet[36:40], seq)
	binary.BigEndian.PutUint32(packet[40:44], count)
	binary.BigEndian.PutUint16(packet[44:46], uint16(len(payload)))
	copy(packet[headerLen:headerLen+len(payload)], payload)
	copy(packet[len(packet)-hmacLen:], mac(secret, packet[:len(packet)-hmacLen]))
	return packet
}

func mac(secret []byte, body []byte) []byte {
	h := hmac.New(sha256.New, secret)
	_, _ = h.Write(body)
	return h.Sum(nil)
}

func printClientSummary(sent, received int, rtts []time.Duration) {
	loss := 100.0
	if sent > 0 {
		loss = float64(sent-received) * 100 / float64(sent)
	}
	fmt.Printf("sent=%d received=%d loss=%.1f%%\n", sent, received, loss)
	if len(rtts) == 0 {
		return
	}

	sorted := append([]time.Duration(nil), rtts...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	minRTT := sorted[0]
	maxRTT := sorted[len(sorted)-1]
	var total time.Duration
	for _, rtt := range rtts {
		total += rtt
	}
	avg := total / time.Duration(len(rtts))

	var jitterTotal time.Duration
	if len(rtts) > 1 {
		for i := 1; i < len(rtts); i++ {
			diff := rtts[i] - rtts[i-1]
			if diff < 0 {
				diff = -diff
			}
			jitterTotal += diff
		}
	}
	jitter := time.Duration(0)
	if len(rtts) > 1 {
		jitter = jitterTotal / time.Duration(len(rtts)-1)
	}

	fmt.Printf("rtt_min=%s rtt_avg=%s rtt_max=%s jitter=%s\n", minRTT.Round(time.Microsecond), avg.Round(time.Microsecond), maxRTT.Round(time.Microsecond), jitter.Round(time.Microsecond))
}
