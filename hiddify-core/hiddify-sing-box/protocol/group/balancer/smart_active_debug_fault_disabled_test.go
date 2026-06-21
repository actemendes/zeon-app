//go:build !smart_active_debug

package balancer

import (
	"testing"

	"github.com/sagernet/sing-box/option"
)

func TestSmartActiveDebugFaultIsDisabledWithoutBuildTag(t *testing.T) {
	fault := newSmartActiveDebugFault(option.BalancerOutboundOptions{
		SmartActiveDebugForceStatus: "CRITICAL",
	})
	if fault != nil {
		t.Fatal("release build must ignore Smart Active debug fault options")
	}
}
