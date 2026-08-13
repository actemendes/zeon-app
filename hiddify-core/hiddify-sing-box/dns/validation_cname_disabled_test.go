//go:build !zeon_route_validation

package dns

import (
	"testing"

	mDNS "github.com/miekg/dns"
)

func TestProductionDoesNotCollectValidationCNAMEChain(t *testing.T) {
	response := &mDNS.Msg{
		Question: []mDNS.Question{{Name: "service.ru.", Qtype: mDNS.TypeA}},
		Answer: []mDNS.RR{
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "service.ru.", Rrtype: mDNS.TypeCNAME},
				Target: "edge.example.",
			},
		},
	}
	if chain := validationCNAMEChain(response); chain != nil {
		t.Fatalf("production validation CNAME chain = %v, want nil", chain)
	}
}
