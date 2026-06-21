//go:build !smart_active_debug

package balancer

import "github.com/sagernet/sing-box/option"

// The production implementation is deliberately absent. Config fields remain
// parseable for a shared debug/release config, but are inert in release builds.
func newSmartActiveDebugFault(option.BalancerOutboundOptions) smartActiveHistoryFault {
	return nil
}
