//go:build !zeon_route_validation

package dns

import mDNS "github.com/miekg/dns"

// Production does not inspect or retain CNAME targets for validation evidence.
func validationCNAMEChain(*mDNS.Msg) []string {
	return nil
}
