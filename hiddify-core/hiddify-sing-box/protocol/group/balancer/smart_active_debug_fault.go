package balancer

import "github.com/sagernet/sing-box/adapter"

// smartActiveHistoryFault only changes the per-cycle copy of monitoring data.
// It never changes URLTest state and never affects a real connection.
type smartActiveHistoryFault interface {
	Apply(activeTag string, history map[string]*adapter.URLTestHistory) bool
}
