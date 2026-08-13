package dns

import (
	"net"
	"net/netip"
	"testing"

	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/contrab/freelru"
	"github.com/sagernet/sing/contrab/maphash"

	mDNS "github.com/miekg/dns"
)

func TestReverseMappingPreservesOriginalQuestionAcrossCNAME(t *testing.T) {
	router := &Router{
		dnsReverseMapping: common.Must1(
			freelru.NewSharded[netip.Addr, string](16, maphash.NewHasher[netip.Addr]().Hash32),
		),
	}
	request := new(mDNS.Msg)
	request.SetQuestion("Service.RU.", mDNS.TypeA)
	response := &mDNS.Msg{
		MsgHdr:   mDNS.MsgHdr{Response: true, Rcode: mDNS.RcodeSuccess},
		Question: request.Question,
		Answer: []mDNS.RR{
			&mDNS.CNAME{
				Hdr:    mDNS.RR_Header{Name: "Service.RU.", Rrtype: mDNS.TypeCNAME, Class: mDNS.ClassINET, Ttl: 30},
				Target: "edge.example.com.",
			},
			&mDNS.A{
				Hdr: mDNS.RR_Header{Name: "edge.example.com.", Rrtype: mDNS.TypeA, Class: mDNS.ClassINET, Ttl: 120},
				A:   net.ParseIP("203.0.113.9").To4(),
			},
		},
	}

	router.rememberDNSReverseMapping(request, response)

	domain, loaded := router.LookupReverseMapping(netip.MustParseAddr("203.0.113.9"))
	if !loaded {
		t.Fatal("original query domain was not retained for the resolved address")
	}
	if domain != "service.ru" {
		t.Fatalf("reverse-mapped domain = %q, want original query domain service.ru", domain)
	}
}

func TestReverseMappingPreservesOriginalQuestionForIPv6(t *testing.T) {
	router := &Router{
		dnsReverseMapping: common.Must1(
			freelru.NewSharded[netip.Addr, string](16, maphash.NewHasher[netip.Addr]().Hash32),
		),
	}
	request := new(mDNS.Msg)
	request.SetQuestion("service.xn--p1ai.", mDNS.TypeAAAA)
	response := &mDNS.Msg{
		MsgHdr:   mDNS.MsgHdr{Response: true, Rcode: mDNS.RcodeSuccess},
		Question: request.Question,
		Answer: []mDNS.RR{
			&mDNS.AAAA{
				Hdr:  mDNS.RR_Header{Name: "service.xn--p1ai.", Rrtype: mDNS.TypeAAAA, Class: mDNS.ClassINET, Ttl: 60},
				AAAA: net.ParseIP("2001:db8::9"),
			},
		},
	}

	router.rememberDNSReverseMapping(request, response)

	domain, loaded := router.LookupReverseMapping(netip.MustParseAddr("2001:db8::9"))
	if !loaded || domain != "service.xn--p1ai" {
		t.Fatalf("IPv6 reverse mapping = %q, loaded=%v", domain, loaded)
	}
}
