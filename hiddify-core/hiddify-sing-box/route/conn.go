package route

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/dialer"
	healthmonitoring "github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/common/tlsfragment"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/bufio"
	"github.com/sagernet/sing/common/canceler"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/x/list"
)

var _ adapter.ConnectionManager = (*ConnectionManager)(nil)

type ConnectionManager struct {
	logger           logger.ContextLogger
	access           sync.Mutex
	connections      list.List[io.Closer]
	nextConnectionID atomic.Uint64
}

func NewConnectionManager(logger logger.ContextLogger) *ConnectionManager {
	return &ConnectionManager{
		logger: logger,
	}
}

func (m *ConnectionManager) Start(stage adapter.StartStage) error {
	return nil
}

func (m *ConnectionManager) Close() error {
	m.access.Lock()
	defer m.access.Unlock()
	for element := m.connections.Front(); element != nil; element = element.Next() {
		common.Close(element.Value)
	}
	m.connections.Init()
	return nil
}

func (m *ConnectionManager) NewConnection(ctx context.Context, this N.Dialer, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	connectionID := m.nextConnectionID.Add(1)
	metadata.Network = N.NetworkTCP
	if metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(zeonOutboundTag(this))
	}
	zeonApplyIPFamilyFallback(m.logger, ctx, &metadata)
	ctx = adapter.WithContext(ctx, &metadata)
	connectStartedAt := time.Now()
	zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
		event:        "connect_start",
		connectionID: connectionID,
		metadata:     metadata,
		selected:     zeonOutboundTag(this),
		leaf:         metadata.GetRealOutbound(),
	})
	var (
		remoteConn net.Conn
		err        error
	)
	if len(metadata.DestinationAddresses) > 0 || metadata.Destination.IsIP() {
		remoteConn, err = dialer.DialSerialNetwork(ctx, this, N.NetworkTCP, metadata.Destination, metadata.DestinationAddresses, metadata.NetworkStrategy, metadata.NetworkType, metadata.FallbackNetworkType, metadata.FallbackDelay)
	} else {
		remoteConn, err = this.DialContext(ctx, N.NetworkTCP, metadata.Destination)
	}
	if err != nil {
		var remoteString string
		if len(metadata.DestinationAddresses) > 0 {
			remoteString = "[" + strings.Join(common.Map(metadata.DestinationAddresses, netip.Addr.String), ",") + "]"
		} else {
			remoteString = metadata.Destination.String()
		}
		var dialerString string
		if outbound, isOutbound := this.(adapter.Outbound); isOutbound {
			dialerString = " using outbound/" + outbound.Type() + "[" + outbound.Tag() + "]"
			if outbound.Type() == C.TypeBalancer {
				dialerString += "[" + metadata.GetRealOutbound() + "]"
			}
		}
		err = E.Cause(err, "open connection to ", remoteString, dialerString)
		N.CloseOnHandshakeFailure(conn, onClose, err)
		m.logger.ErrorContext(ctx, err)
		zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
			event:           "connect_failure",
			connectionID:    connectionID,
			metadata:        metadata,
			selected:        zeonOutboundTag(this),
			leaf:            metadata.GetRealOutbound(),
			connectDuration: time.Since(connectStartedAt),
			err:             err,
		})
		zeonObserveConnectFailure(m.logger, ctx, metadata, err)
		m.recordRuntimePenalty(ctx, err, false)
		return
	}
	err = N.ReportConnHandshakeSuccess(conn, remoteConn)
	if err != nil {
		err = E.Cause(err, "report handshake success")
		remoteConn.Close()
		N.CloseOnHandshakeFailure(conn, onClose, err)
		m.logger.ErrorContext(ctx, err)
		zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
			event:           "handshake_report_failure",
			connectionID:    connectionID,
			metadata:        metadata,
			selected:        zeonOutboundTag(this),
			leaf:            metadata.GetRealOutbound(),
			connectDuration: time.Since(connectStartedAt),
			err:             err,
		})
		m.recordRuntimePenalty(ctx, err, true)
		return
	}
	m.recordRuntimeSuccess(ctx)
	zeonObserveConnectSuccess(m.logger, ctx, metadata)
	zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
		event:           "connect_success",
		connectionID:    connectionID,
		metadata:        metadata,
		selected:        zeonOutboundTag(this),
		leaf:            metadata.GetRealOutbound(),
		connectDuration: time.Since(connectStartedAt),
	})
	if metadata.TLSFragment || metadata.TLSRecordFragment {
		remoteConn = tf.NewConn(remoteConn, ctx, metadata.TLSFragment, metadata.TLSRecordFragment, metadata.TLSFragmentFallbackDelay)
	}
	m.access.Lock()
	element := m.connections.PushBack(conn)
	m.access.Unlock()
	onClose = N.AppendClose(onClose, func(it error) {
		m.access.Lock()
		defer m.access.Unlock()
		m.connections.Remove(element)
	})
	var done atomic.Bool
	trafficTracker := zeonNewTrafficTracker(m.logger, ctx, connectionID, metadata)
	m.preConnectionCopy(ctx, conn, remoteConn, false, &done, onClose)
	m.preConnectionCopy(ctx, remoteConn, conn, true, &done, onClose)
	go m.connectionCopy(ctx, conn, remoteConn, false, &done, onClose, connectionID, trafficTracker)
	go m.connectionCopy(ctx, remoteConn, conn, true, &done, onClose, connectionID, trafficTracker)
}

func (m *ConnectionManager) NewPacketConnection(ctx context.Context, this N.Dialer, conn N.PacketConn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	connectionID := m.nextConnectionID.Add(1)
	metadata.Network = N.NetworkUDP
	if metadata.GetRealOutbound() == "" {
		metadata.SetRealOutbound(zeonOutboundTag(this))
	}
	zeonApplyIPFamilyFallback(m.logger, ctx, &metadata)
	ctx = adapter.WithContext(ctx, &metadata)
	connectStartedAt := time.Now()
	zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
		event:        "packet_connect_start",
		connectionID: connectionID,
		metadata:     metadata,
		selected:     zeonOutboundTag(this),
		leaf:         metadata.GetRealOutbound(),
	})
	var (
		remotePacketConn   net.PacketConn
		remoteConn         net.Conn
		destinationAddress netip.Addr
		err                error
	)
	if metadata.UDPConnect {
		parallelDialer, isParallelDialer := this.(dialer.ParallelInterfaceDialer)
		if len(metadata.DestinationAddresses) > 0 {
			if isParallelDialer {
				remoteConn, err = dialer.DialSerialNetwork(ctx, parallelDialer, N.NetworkUDP, metadata.Destination, metadata.DestinationAddresses, metadata.NetworkStrategy, metadata.NetworkType, metadata.FallbackNetworkType, metadata.FallbackDelay)
			} else {
				remoteConn, err = N.DialSerial(ctx, this, N.NetworkUDP, metadata.Destination, metadata.DestinationAddresses)
			}
		} else if metadata.Destination.IsIP() {
			if isParallelDialer {
				remoteConn, err = dialer.DialSerialNetwork(ctx, parallelDialer, N.NetworkUDP, metadata.Destination, metadata.DestinationAddresses, metadata.NetworkStrategy, metadata.NetworkType, metadata.FallbackNetworkType, metadata.FallbackDelay)
			} else {
				remoteConn, err = this.DialContext(ctx, N.NetworkUDP, metadata.Destination)
			}
		} else {
			remoteConn, err = this.DialContext(ctx, N.NetworkUDP, metadata.Destination)
		}
		if err != nil {
			var remoteString string
			if len(metadata.DestinationAddresses) > 0 {
				remoteString = "[" + strings.Join(common.Map(metadata.DestinationAddresses, netip.Addr.String), ",") + "]"
			} else {
				remoteString = metadata.Destination.String()
			}
			var dialerString string
			if outbound, isOutbound := this.(adapter.Outbound); isOutbound {
				dialerString = " using outbound/" + outbound.Type() + "[" + outbound.Tag() + "]"
				if outbound.Type() == C.TypeBalancer {
					dialerString += "[" + metadata.GetRealOutbound() + "]"
				}
			}
			err = E.Cause(err, "open packet connection to ", remoteString, dialerString)
			N.CloseOnHandshakeFailure(conn, onClose, err)
			m.logger.ErrorContext(ctx, err)
			zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
				event:           "packet_connect_failure",
				connectionID:    connectionID,
				metadata:        metadata,
				selected:        zeonOutboundTag(this),
				leaf:            metadata.GetRealOutbound(),
				connectDuration: time.Since(connectStartedAt),
				err:             err,
			})
			zeonObserveConnectFailure(m.logger, ctx, metadata, err)
			m.recordRuntimePenalty(ctx, err, false)
			return
		}
		remotePacketConn = bufio.NewUnbindPacketConn(remoteConn)
		connRemoteAddr := M.AddrFromNet(remoteConn.RemoteAddr())
		if connRemoteAddr != metadata.Destination.Addr {
			destinationAddress = connRemoteAddr
		}
	} else {
		if len(metadata.DestinationAddresses) > 0 {
			remotePacketConn, destinationAddress, err = dialer.ListenSerialNetworkPacket(ctx, this, metadata.Destination, metadata.DestinationAddresses, metadata.NetworkStrategy, metadata.NetworkType, metadata.FallbackNetworkType, metadata.FallbackDelay)
		} else {
			remotePacketConn, err = this.ListenPacket(ctx, metadata.Destination)
		}
		if err != nil {
			var dialerString string
			if outbound, isOutbound := this.(adapter.Outbound); isOutbound {
				dialerString = " using outbound/" + outbound.Type() + "[" + outbound.Tag() + "]"
				if outbound.Type() == C.TypeBalancer {
					dialerString += "[" + metadata.GetRealOutbound() + "]"
				}
			}
			err = E.Cause(err, "listen packet connection using ", dialerString)
			N.CloseOnHandshakeFailure(conn, onClose, err)
			m.logger.ErrorContext(ctx, err)
			zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
				event:           "packet_listen_failure",
				connectionID:    connectionID,
				metadata:        metadata,
				selected:        zeonOutboundTag(this),
				leaf:            metadata.GetRealOutbound(),
				connectDuration: time.Since(connectStartedAt),
				err:             err,
			})
			zeonObserveConnectFailure(m.logger, ctx, metadata, err)
			m.recordRuntimePenalty(ctx, err, false)
			return
		}
	}
	err = N.ReportPacketConnHandshakeSuccess(conn, remotePacketConn)
	if err != nil {
		conn.Close()
		remotePacketConn.Close()
		m.logger.ErrorContext(ctx, "report handshake success: ", err)
		zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
			event:           "packet_handshake_report_failure",
			connectionID:    connectionID,
			metadata:        metadata,
			selected:        zeonOutboundTag(this),
			leaf:            metadata.GetRealOutbound(),
			connectDuration: time.Since(connectStartedAt),
			err:             err,
		})
		m.recordRuntimePenalty(ctx, err, true)
		return
	}
	zeonLogTrafficConnect(m.logger, ctx, zeonTrafficLogFields{
		event:           "packet_connect_success",
		connectionID:    connectionID,
		metadata:        metadata,
		selected:        zeonOutboundTag(this),
		leaf:            metadata.GetRealOutbound(),
		connectDuration: time.Since(connectStartedAt),
	})
	zeonObserveConnectSuccess(m.logger, ctx, metadata)
	if destinationAddress.IsValid() {
		var originDestination M.Socksaddr
		if metadata.RouteOriginalDestination.IsValid() {
			originDestination = metadata.RouteOriginalDestination
		} else {
			originDestination = metadata.Destination
		}
		if natConn, loaded := common.Cast[bufio.NATPacketConn](conn); loaded {
			natConn.UpdateDestination(destinationAddress)
		} else if metadata.Destination != M.SocksaddrFrom(destinationAddress, metadata.Destination.Port) {
			if metadata.UDPDisableDomainUnmapping {
				remotePacketConn = bufio.NewUnidirectionalNATPacketConn(bufio.NewPacketConn(remotePacketConn), M.SocksaddrFrom(destinationAddress, metadata.Destination.Port), originDestination)
			} else {
				remotePacketConn = bufio.NewNATPacketConn(bufio.NewPacketConn(remotePacketConn), M.SocksaddrFrom(destinationAddress, metadata.Destination.Port), originDestination)
			}
		}
	} else if metadata.RouteOriginalDestination.IsValid() && metadata.RouteOriginalDestination != metadata.Destination {
		remotePacketConn = bufio.NewDestinationNATPacketConn(bufio.NewPacketConn(remotePacketConn), metadata.Destination, metadata.RouteOriginalDestination)
	}
	var udpTimeout time.Duration
	if metadata.UDPTimeout > 0 {
		udpTimeout = metadata.UDPTimeout
	} else {
		protocol := metadata.Protocol
		if protocol == "" {
			protocol = C.PortProtocols[metadata.Destination.Port]
		}
		if protocol != "" {
			udpTimeout = C.ProtocolTimeouts[protocol]
		}
	}
	if udpTimeout > 0 {
		ctx, conn = canceler.NewPacketConn(ctx, conn, udpTimeout)
	}
	destination := bufio.NewPacketConn(remotePacketConn)
	m.access.Lock()
	element := m.connections.PushBack(conn)
	m.access.Unlock()
	onClose = N.AppendClose(onClose, func(it error) {
		m.access.Lock()
		defer m.access.Unlock()
		m.connections.Remove(element)
	})
	var done atomic.Bool
	trafficTracker := zeonNewTrafficTracker(m.logger, ctx, connectionID, metadata)
	go m.packetConnectionCopy(ctx, conn, destination, false, &done, onClose, connectionID, trafficTracker)
	go m.packetConnectionCopy(ctx, destination, conn, true, &done, onClose, connectionID, trafficTracker)
}

func (m *ConnectionManager) preConnectionCopy(ctx context.Context, source net.Conn, destination net.Conn, direction bool, done *atomic.Bool, onClose N.CloseHandlerFunc) {
	readHandshake := N.NeedHandshakeForRead(source)
	writeHandshake := N.NeedHandshakeForWrite(destination)
	if readHandshake || writeHandshake {
		var err error
		for {
			err = m.connectionCopyEarlyWrite(source, destination, readHandshake, writeHandshake)
			if err == nil && N.NeedHandshakeForRead(source) {
				continue
			} else if E.IsMulti(err, os.ErrInvalid, context.DeadlineExceeded, io.EOF) {
				err = nil
			}
			break
		}
		if err != nil {
			if done.Swap(true) {
				onClose(err)
			}
			common.Close(source, destination)
			if !direction {
				m.logger.ErrorContext(ctx, "connection upload handshake: ", err)
			} else {
				m.logger.ErrorContext(ctx, "connection download handshake: ", err)
			}
			m.recordRuntimePenalty(ctx, err, true)
			return
		}
	}
}

func (m *ConnectionManager) connectionCopy(ctx context.Context, source net.Conn, destination net.Conn, direction bool, done *atomic.Bool, onClose N.CloseHandlerFunc, connectionID uint64, trafficTracker *zeonTrafficTracker) {
	var (
		sourceReader      io.Reader = source
		destinationWriter io.Writer = destination
	)
	if trafficTracker != nil {
		sourceReader = zeonCountingReader{Reader: sourceReader, counter: trafficTracker.countFunc(direction)}
	}
	var readCounters, writeCounters []N.CountFunc
	for {
		sourceReader, readCounters = N.UnwrapCountReader(sourceReader, readCounters)
		destinationWriter, writeCounters = N.UnwrapCountWriter(destinationWriter, writeCounters)
		if cachedSrc, isCached := sourceReader.(N.CachedReader); isCached {
			cachedBuffer := cachedSrc.ReadCached()
			if cachedBuffer != nil {
				dataLen := cachedBuffer.Len()
				_, err := destination.Write(cachedBuffer.Bytes())
				cachedBuffer.Release()
				if err != nil {
					if done.Swap(true) {
						onClose(err)
					}
					common.Close(source, destination)
					if !direction {
						m.logger.ErrorContext(ctx, "connection upload payload: ", err)
					} else {
						m.logger.ErrorContext(ctx, "connection download payload: ", err)
					}
					if trafficTracker != nil {
						trafficTracker.closeDirection(direction, 0, err)
					}
					return
				}
				for _, counter := range readCounters {
					counter(int64(dataLen))
				}
				for _, counter := range writeCounters {
					counter(int64(dataLen))
				}
			}
			continue
		}
		break
	}

	bytes, err := bufio.CopyWithCounters(destinationWriter, sourceReader, source, readCounters, writeCounters, bufio.DefaultIncreaseBufferAfter, bufio.DefaultBatchSize)
	m.recordRuntimeTraffic(ctx, bytes, direction)
	if trafficTracker != nil {
		trafficTracker.closeDirection(direction, bytes, err)
	}
	if err != nil {
		common.Close(source, destination)
	} else if duplexDst, isDuplex := destination.(N.WriteCloser); isDuplex {
		err = duplexDst.CloseWrite()
		if err != nil {
			common.Close(source, destination)
		}
	} else {
		destination.Close()
	}
	if done.Swap(true) {
		onClose(err)
		common.Close(source, destination)
	}
	if !direction {
		if err == nil {
			m.logger.DebugContext(ctx, "connection upload finished")
		} else if !E.IsClosedOrCanceled(err) && !strings.Contains(err.Error(), "NO_ERROR") {
			m.logger.ErrorContext(ctx, "connection upload closed: ", err)
			m.recordRuntimePenalty(ctx, err, true)
		} else {
			m.logger.TraceContext(ctx, "connection upload closed")
		}
	} else {
		if err == nil {
			m.logger.DebugContext(ctx, "connection download finished")
		} else if !E.IsClosedOrCanceled(err) && !strings.Contains(err.Error(), "NO_ERROR") && !strings.Contains(err.Error(), "response body closed") {
			m.logger.ErrorContext(ctx, "connection download closed: ", err)
			m.recordRuntimePenalty(ctx, err, true)
		} else {
			m.logger.TraceContext(ctx, "connection download closed")
		}
	}
}

func (m *ConnectionManager) connectionCopyEarlyWrite(source net.Conn, destination io.Writer, readHandshake bool, writeHandshake bool) error {
	payload := buf.NewPacket()
	defer payload.Release()
	err := source.SetReadDeadline(time.Now().Add(C.ReadPayloadTimeout))
	if err != nil {
		if err == os.ErrInvalid {
			if writeHandshake {
				return common.Error(destination.Write(nil))
			}
		}
		return err
	}
	var (
		isTimeout bool
		isEOF     bool
	)
	_, err = payload.ReadOnceFrom(source)
	if err != nil {
		if E.IsTimeout(err) {
			isTimeout = true
		} else if errors.Is(err, io.EOF) {
			isEOF = true
		} else {
			return E.Cause(err, "read payload")
		}
	}
	_ = source.SetReadDeadline(time.Time{})
	if !payload.IsEmpty() || writeHandshake {
		_, err = destination.Write(payload.Bytes())
		if err != nil {
			return E.Cause(err, "write payload")
		}
	}
	if isTimeout {
		return context.DeadlineExceeded
	} else if isEOF {
		return io.EOF
	}
	return nil
}

func (m *ConnectionManager) recordRuntimePenalty(ctx context.Context, err error, strict bool) {
	if zeonTrafficHooksDisabled(ctx) {
		return
	}
	if err == nil {
		return
	}
	metadata := adapter.ContextFrom(ctx)
	if metadata == nil || metadata.GetRealOutbound() == "" {
		return
	}
	errorType, _ := urltest.ClassifyProbeError(err)
	if !urltest.ShouldApplyRuntimePenalty(errorType, strict) {
		return
	}
	if monitor := healthmonitoring.Get(ctx); monitor != nil {
		monitor.RecordRuntimeError(metadata.GetRealOutbound(), err)
	}
}

func (m *ConnectionManager) recordRuntimeSuccess(ctx context.Context) {
	if zeonTrafficHooksDisabled(ctx) {
		return
	}
	metadata := adapter.ContextFrom(ctx)
	if metadata == nil || metadata.GetRealOutbound() == "" {
		return
	}
	if monitor := healthmonitoring.Get(ctx); monitor != nil {
		monitor.RecordRuntimeSuccess(metadata.GetRealOutbound())
	}
}

func (m *ConnectionManager) recordRuntimeTraffic(ctx context.Context, bytes int64, download bool) {
	if zeonTrafficHooksDisabled(ctx) {
		return
	}
	metadata := adapter.ContextFrom(ctx)
	if metadata == nil || metadata.GetRealOutbound() == "" || bytes <= 0 {
		return
	}
	if monitor := healthmonitoring.Get(ctx); monitor != nil {
		monitor.RecordRuntimeTraffic(metadata.GetRealOutbound(), bytes, download)
	}
}

func (m *ConnectionManager) packetConnectionCopy(ctx context.Context, source N.PacketReader, destination N.PacketWriter, direction bool, done *atomic.Bool, onClose N.CloseHandlerFunc, connectionID uint64, trafficTracker *zeonTrafficTracker) {
	if trafficTracker != nil {
		source = zeonCountingPacketReader{PacketReader: source, counter: trafficTracker.countFunc(direction)}
	}
	bytes, err := bufio.CopyPacket(destination, source)
	m.recordRuntimeTraffic(ctx, int64(bytes), direction)
	if trafficTracker != nil {
		trafficTracker.closeDirection(direction, int64(bytes), err)
	}
	if !direction {
		if err == nil {
			m.logger.DebugContext(ctx, "packet upload finished")
		} else if E.IsClosedOrCanceled(err) {
			m.logger.TraceContext(ctx, "packet upload closed")
		} else {
			m.logger.DebugContext(ctx, "packet upload closed: ", err)
			m.recordRuntimePenalty(ctx, err, true)
		}
	} else {
		if err == nil {
			m.logger.DebugContext(ctx, "packet download finished")
		} else if E.IsClosedOrCanceled(err) {
			m.logger.TraceContext(ctx, "packet download closed")
		} else {
			m.logger.DebugContext(ctx, "packet download closed: ", err)
			m.recordRuntimePenalty(ctx, err, true)
		}
	}
	if !done.Swap(true) {
		onClose(err)
	}
	common.Close(source, destination)
}
