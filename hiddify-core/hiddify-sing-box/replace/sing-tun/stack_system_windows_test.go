//go:build windows

package tun

import (
	"net/netip"
	"testing"
	"unsafe"

	"github.com/sagernet/sing-tun/internal/winsys"
	"github.com/stretchr/testify/require"
)

func TestWindowsFirewallConditionsIPv4(t *testing.T) {
	appID := new(winsys.FWP_BYTE_BLOB)
	conditions, addressValues, err := windowsFirewallConditions(
		appID,
		netip.MustParseAddr("172.19.0.1"),
		netip.MustParseAddr("172.19.0.2"),
		32123,
	)
	require.NoError(t, err)
	require.Empty(t, addressValues)
	require.Len(t, conditions, 5)
	require.Equal(t, winsys.FWPM_CONDITION_ALE_APP_ID, conditions[0].FieldKey)
	require.Equal(t, winsys.FWP_BYTE_BLOB_TYPE, conditions[0].ConditionValue.Type)
	require.Equal(t, uintptr(unsafe.Pointer(appID)), conditions[0].ConditionValue.Value)
	require.Equal(t, winsys.FWPM_CONDITION_IP_PROTOCOL, conditions[1].FieldKey)
	require.Equal(t, winsys.FWP_UINT8, conditions[1].ConditionValue.Type)
	require.Equal(t, uintptr(winsys.IPPROTO_TCP), conditions[1].ConditionValue.Value)
	require.Equal(t, winsys.FWPM_CONDITION_IP_LOCAL_PORT, conditions[2].FieldKey)
	require.Equal(t, winsys.FWP_UINT16, conditions[2].ConditionValue.Type)
	require.Equal(t, uintptr(32123), conditions[2].ConditionValue.Value)
	require.Equal(t, winsys.FWPM_CONDITION_IP_LOCAL_ADDRESS, conditions[3].FieldKey)
	require.Equal(t, winsys.FWP_UINT32, conditions[3].ConditionValue.Type)
	require.Equal(t, uintptr(0xac130001), conditions[3].ConditionValue.Value)
	require.Equal(t, winsys.FWPM_CONDITION_IP_REMOTE_ADDRESS, conditions[4].FieldKey)
	require.Equal(t, winsys.FWP_UINT32, conditions[4].ConditionValue.Type)
	require.Equal(t, uintptr(0xac130002), conditions[4].ConditionValue.Value)
}

func TestWindowsFirewallConditionsIPv6(t *testing.T) {
	appID := new(winsys.FWP_BYTE_BLOB)
	localAddress := netip.MustParseAddr("fdfe:dcba:9876::1")
	remoteAddress := netip.MustParseAddr("fdfe:dcba:9876::2")
	conditions, addressValues, err := windowsFirewallConditions(appID, localAddress, remoteAddress, 32124)
	require.NoError(t, err)
	require.Len(t, addressValues, 2)
	require.Len(t, conditions, 5)
	require.Equal(t, winsys.FWP_BYTE_ARRAY16_TYPE, conditions[3].ConditionValue.Type)
	require.Equal(t, winsys.FWP_BYTE_ARRAY16_TYPE, conditions[4].ConditionValue.Type)
	localValue := (*winsys.FWP_BYTE_ARRAY16)(unsafe.Pointer(conditions[3].ConditionValue.Value))
	remoteValue := (*winsys.FWP_BYTE_ARRAY16)(unsafe.Pointer(conditions[4].ConditionValue.Value))
	require.Equal(t, localAddress.As16(), localValue.ByteArray16)
	require.Equal(t, remoteAddress.As16(), remoteValue.ByteArray16)
}

func TestWindowsFirewallConditionsRejectBroadOrInvalidRules(t *testing.T) {
	appID := new(winsys.FWP_BYTE_BLOB)
	_, _, err := windowsFirewallConditions(nil, netip.MustParseAddr("172.19.0.1"), netip.MustParseAddr("172.19.0.2"), 32123)
	require.ErrorContains(t, err, "application ID")
	_, _, err = windowsFirewallConditions(appID, netip.MustParseAddr("172.19.0.1"), netip.MustParseAddr("fdfe:dcba:9876::2"), 32123)
	require.ErrorContains(t, err, "address family")
	_, _, err = windowsFirewallConditions(appID, netip.MustParseAddr("172.19.0.1"), netip.MustParseAddr("172.19.0.2"), 0)
	require.ErrorContains(t, err, "port")
}
