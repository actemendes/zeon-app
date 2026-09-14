//go:build windows

package tun

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net/netip"
	"os"
	"runtime"
	"unsafe"

	"github.com/sagernet/sing-tun/internal/winsys"

	"golang.org/x/sys/windows"
)

func (s *System) startWindowsFirewall() (err error) {
	if s.windowsFirewallSession != 0 {
		return errors.New("Windows firewall session is already active")
	}

	var engine uintptr
	session := &winsys.FWPM_SESSION0{
		DisplayData: winsys.CreateDisplayData(TunnelType, "system stack TCP forwarder"),
		Flags:       winsys.FWPM_SESSION_FLAG_DYNAMIC,
	}
	if err = winsys.FwpmEngineOpen0(nil, winsys.RPC_C_AUTHN_DEFAULT, nil, session, unsafe.Pointer(&engine)); err != nil {
		return os.NewSyscallError("FwpmEngineOpen0", err)
	}
	defer func() {
		if err != nil {
			_ = winsys.FwpmEngineClose0(engine)
		}
	}()

	subLayerKey, guidErr := windows.GenerateGUID()
	if guidErr != nil {
		return os.NewSyscallError("CoCreateGuid", guidErr)
	}
	subLayer := winsys.FWPM_SUBLAYER0{
		SubLayerKey: subLayerKey,
		DisplayData: winsys.CreateDisplayData(TunnelType, "system stack TCP forwarder"),
		Weight:      math.MaxUint16,
	}
	if err = winsys.FwpmSubLayerAdd0(engine, &subLayer, 0); err != nil {
		return os.NewSyscallError("FwpmSubLayerAdd0", err)
	}

	processAppID, appIDErr := winsys.GetCurrentProcessAppID()
	if appIDErr != nil {
		return appIDErr
	}
	defer winsys.FwpmFreeMemory0(unsafe.Pointer(&processAppID))

	if s.tcpListener != nil {
		err = addWindowsFirewallFilter(
			engine,
			subLayerKey,
			winsys.FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
			processAppID,
			s.inet4Address,
			s.inet4NextAddress,
			s.tcpPort,
			"allow scoped IPv4 TCP forwarder",
		)
		if err != nil {
			return err
		}
	}
	if s.tcpListener6 != nil {
		err = addWindowsFirewallFilter(
			engine,
			subLayerKey,
			winsys.FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
			processAppID,
			s.inet6Address,
			s.inet6NextAddress,
			s.tcpPort6,
			"allow scoped IPv6 TCP forwarder",
		)
		if err != nil {
			return err
		}
	}

	s.windowsFirewallSession = engine
	return nil
}

func addWindowsFirewallFilter(
	engine uintptr,
	subLayerKey windows.GUID,
	layerKey windows.GUID,
	processAppID *winsys.FWP_BYTE_BLOB,
	localAddress netip.Addr,
	remoteAddress netip.Addr,
	localPort uint16,
	description string,
) error {
	conditions, addressValues, err := windowsFirewallConditions(processAppID, localAddress, remoteAddress, localPort)
	if err != nil {
		return err
	}
	filter := winsys.FWPM_FILTER0{
		DisplayData:         winsys.CreateDisplayData(TunnelType, description),
		LayerKey:            layerKey,
		SubLayerKey:         subLayerKey,
		Weight:              winsys.FWP_VALUE0{Type: winsys.FWP_UINT8, Value: uintptr(15)},
		NumFilterConditions: uint32(len(conditions)),
		FilterCondition:     &conditions[0],
		Action:              winsys.FWPM_ACTION0{Type: winsys.FWP_ACTION_PERMIT},
		Flags:               winsys.FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT,
	}
	var filterID uint64
	err = winsys.FwpmFilterAdd0(engine, &filter, 0, &filterID)
	runtime.KeepAlive(conditions)
	runtime.KeepAlive(addressValues)
	if err != nil {
		return os.NewSyscallError("FwpmFilterAdd0", err)
	}
	return nil
}

func windowsFirewallConditions(
	processAppID *winsys.FWP_BYTE_BLOB,
	localAddress netip.Addr,
	remoteAddress netip.Addr,
	localPort uint16,
) ([]winsys.FWPM_FILTER_CONDITION0, []winsys.FWP_BYTE_ARRAY16, error) {
	if processAppID == nil {
		return nil, nil, errors.New("missing process application ID")
	}
	if !localAddress.IsValid() || !remoteAddress.IsValid() || localAddress.Is4() != remoteAddress.Is4() {
		return nil, nil, fmt.Errorf("invalid or mixed firewall address family: local=%s remote=%s", localAddress, remoteAddress)
	}
	if localPort == 0 {
		return nil, nil, errors.New("missing TCP forwarder port")
	}

	conditions := []winsys.FWPM_FILTER_CONDITION0{
		{
			FieldKey:  winsys.FWPM_CONDITION_ALE_APP_ID,
			MatchType: winsys.FWP_MATCH_EQUAL,
			ConditionValue: winsys.FWP_CONDITION_VALUE0{
				Type:  winsys.FWP_BYTE_BLOB_TYPE,
				Value: uintptr(unsafe.Pointer(processAppID)),
			},
		},
		{
			FieldKey:  winsys.FWPM_CONDITION_IP_PROTOCOL,
			MatchType: winsys.FWP_MATCH_EQUAL,
			ConditionValue: winsys.FWP_CONDITION_VALUE0{
				Type:  winsys.FWP_UINT8,
				Value: uintptr(winsys.IPPROTO_TCP),
			},
		},
		{
			FieldKey:  winsys.FWPM_CONDITION_IP_LOCAL_PORT,
			MatchType: winsys.FWP_MATCH_EQUAL,
			ConditionValue: winsys.FWP_CONDITION_VALUE0{
				Type:  winsys.FWP_UINT16,
				Value: uintptr(localPort),
			},
		},
		{
			FieldKey:  winsys.FWPM_CONDITION_IP_LOCAL_ADDRESS,
			MatchType: winsys.FWP_MATCH_EQUAL,
		},
		{
			FieldKey:  winsys.FWPM_CONDITION_IP_REMOTE_ADDRESS,
			MatchType: winsys.FWP_MATCH_EQUAL,
		},
	}

	if localAddress.Is4() {
		localBytes := localAddress.As4()
		remoteBytes := remoteAddress.As4()
		conditions[3].ConditionValue = winsys.FWP_CONDITION_VALUE0{
			Type:  winsys.FWP_UINT32,
			Value: uintptr(binary.BigEndian.Uint32(localBytes[:])),
		}
		conditions[4].ConditionValue = winsys.FWP_CONDITION_VALUE0{
			Type:  winsys.FWP_UINT32,
			Value: uintptr(binary.BigEndian.Uint32(remoteBytes[:])),
		}
		return conditions, nil, nil
	}

	localBytes := localAddress.As16()
	remoteBytes := remoteAddress.As16()
	addressValues := []winsys.FWP_BYTE_ARRAY16{
		{ByteArray16: localBytes},
		{ByteArray16: remoteBytes},
	}
	conditions[3].ConditionValue = winsys.FWP_CONDITION_VALUE0{
		Type:  winsys.FWP_BYTE_ARRAY16_TYPE,
		Value: uintptr(unsafe.Pointer(&addressValues[0])),
	}
	conditions[4].ConditionValue = winsys.FWP_CONDITION_VALUE0{
		Type:  winsys.FWP_BYTE_ARRAY16_TYPE,
		Value: uintptr(unsafe.Pointer(&addressValues[1])),
	}
	return conditions, addressValues, nil
}

func (s *System) closeWindowsFirewall() error {
	engine := s.windowsFirewallSession
	if engine == 0 {
		return nil
	}
	s.windowsFirewallSession = 0
	if err := winsys.FwpmEngineClose0(engine); err != nil {
		return os.NewSyscallError("FwpmEngineClose0", err)
	}
	return nil
}

func retryableListenError(err error) bool {
	return errors.Is(err, windows.WSAEADDRNOTAVAIL)
}
