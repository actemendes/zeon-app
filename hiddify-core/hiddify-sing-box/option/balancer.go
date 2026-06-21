package option

import "github.com/sagernet/sing/common/json/badoption"

type BalancerOutboundOptions struct {
	Outbounds                 []string           `json:"outbounds"`
	Tolerance                 uint16             `json:"tolerance,omitempty"` //not implemented yet
	InterruptExistConnections bool               `json:"interrupt_exist_connections,omitempty"`
	Strategy                  string             `json:"strategy,omitempty"`
	DelayAcceptableRatio      float64            `json:"delay_acceptable_ratio,omitempty"`
	TTL                       badoption.Duration `json:"ttl,omitempty"`
	MaxRetry                  int                `json:"max_retry,omitempty"` //not implemented yet
	// Smart Active fault injection is compiled in only with the
	// smart_active_debug build tag. Release builds intentionally ignore these
	// fields even if a hand-written config contains them.
	SmartActiveDebugForceStatus      string `json:"smart_active_debug_force_status,omitempty"`
	SmartActiveDebugForceError       string `json:"smart_active_debug_force_error,omitempty"`
	SmartActiveDebugForceDegradation int    `json:"smart_active_debug_force_degradation,omitempty"`
	SmartActiveDebugRuntimePenalty   int    `json:"smart_active_debug_runtime_penalty,omitempty"`
	SmartActiveDebugRealUserPenalty  int    `json:"smart_active_debug_real_user_penalty,omitempty"`
	SmartActiveDebugForceCandidate   string `json:"smart_active_debug_force_candidate,omitempty"`
	SmartActiveDebugCandidateScore   int    `json:"smart_active_debug_candidate_score,omitempty"`
}
