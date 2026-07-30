//go:build zeon_route_validation

package dns

import (
	"reflect"
	"testing"

	mDNS "github.com/miekg/dns"
)

func TestValidationCNAMEChainIsOrderedSanitizedAndBounded(t *testing.T) {
	response := &mDNS.Msg{
		Question: []mDNS.Question{
			{Name: "Service.RU.", Qtype: mDNS.TypeA, Qclass: mDNS.ClassINET},
		},
		Answer: []mDNS.RR{
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "unrelated.example.", Rrtype: mDNS.TypeCNAME},
				Target: "ignored.example.",
			},
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "Service.RU.", Rrtype: mDNS.TypeCNAME},
				Target: "Edge.Example.COM.",
			},
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "edge.example.com.", Rrtype: mDNS.TypeCNAME},
				Target: "cdn.example.net.",
			},
		},
	}

	expected := []string{"edge.example.com", "cdn.example.net"}
	if actual := validationCNAMEChain(response); !reflect.DeepEqual(actual, expected) {
		t.Fatalf("CNAME chain = %v, want %v", actual, expected)
	}
}

func TestValidationCNAMEChainRejectsAddressAndLoopTargets(t *testing.T) {
	addressTarget := &mDNS.Msg{
		Question: []mDNS.Question{{Name: "service.ru.", Qtype: mDNS.TypeA}},
		Answer: []mDNS.RR{
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "service.ru.", Rrtype: mDNS.TypeCNAME},
				Target: "203.0.113.42.",
			},
		},
	}
	if actual := validationCNAMEChain(addressTarget); len(actual) != 0 {
		t.Fatalf("address target leaked into CNAME evidence: %v", actual)
	}

	loop := &mDNS.Msg{
		Question: []mDNS.Question{{Name: "service.ru.", Qtype: mDNS.TypeA}},
		Answer: []mDNS.RR{
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "service.ru.", Rrtype: mDNS.TypeCNAME},
				Target: "edge.example.",
			},
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "edge.example.", Rrtype: mDNS.TypeCNAME},
				Target: "service.ru.",
			},
		},
	}
	if actual := validationCNAMEChain(loop); !reflect.DeepEqual(actual, []string{"edge.example"}) {
		t.Fatalf("bounded loop evidence = %v", actual)
	}
}
