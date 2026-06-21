package balancer

import (
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

type LowestDelay struct {
	outbounds        map[string][]adapter.Outbound
	udpOutbounds     []adapter.Outbound
	selectedOutbound map[string]adapter.Outbound

	mu sync.Mutex
}

func NewLowestDelay(outbounds []adapter.Outbound, options option.BalancerOutboundOptions) *LowestDelay {
	couts := convertOutbounds(outbounds)
	initialTCP := firstPolicyPreferredOutbound(couts[N.NetworkTCP])
	initialUDP := firstPolicyPreferredOutbound(couts[N.NetworkUDP])
	return &LowestDelay{
		outbounds: couts,
		selectedOutbound: map[string]adapter.Outbound{
			N.NetworkUDP: initialUDP,
			N.NetworkTCP: initialTCP,
		},
	}
}

var _ Strategy = (*LowestDelay)(nil)

func (s *LowestDelay) Now() string {
	s.mu.Lock()
	defer s.mu.Unlock()

	return s.selectedOutbound[N.NetworkTCP].Tag()
}
func (s *LowestDelay) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	min, _ := getMinDelay(s.outbounds, history)

	s.mu.Lock()
	changed := false
	for net, out := range min {
		changed = changed || out.Tag() != s.selectedOutbound[net].Tag()
	}
	s.selectedOutbound = min
	s.mu.Unlock()
	return changed
}
func (s *LowestDelay) Select(metadata adapter.InboundContext, net string, touch bool) adapter.Outbound {
	s.mu.Lock()
	defer s.mu.Unlock()
	if net != N.NetworkTCP && net != N.NetworkUDP {
		net = N.NetworkTCP
	}
	return s.selectedOutbound[net]

}
