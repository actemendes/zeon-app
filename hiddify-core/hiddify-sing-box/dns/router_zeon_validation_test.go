package dns

import (
	"testing"

	mDNS "github.com/miekg/dns"
)

func TestPredefinedDNSResponseBlocked(t *testing.T) {
	tests := []struct {
		name     string
		response *mDNS.Msg
		blocked  bool
	}{
		{name: "nil", response: nil, blocked: true},
		{name: "success", response: &mDNS.Msg{MsgHdr: mDNS.MsgHdr{Rcode: mDNS.RcodeSuccess}}, blocked: false},
		{name: "refused", response: &mDNS.Msg{MsgHdr: mDNS.MsgHdr{Rcode: mDNS.RcodeRefused}}, blocked: true},
		{name: "name_error", response: &mDNS.Msg{MsgHdr: mDNS.MsgHdr{Rcode: mDNS.RcodeNameError}}, blocked: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := predefinedDNSResponseBlocked(test.response); got != test.blocked {
				t.Fatalf("blocked=%v, want %v", got, test.blocked)
			}
		})
	}
}
