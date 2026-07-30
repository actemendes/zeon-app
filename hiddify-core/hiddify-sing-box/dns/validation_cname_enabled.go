//go:build zeon_route_validation

package dns

import (
	"net/netip"
	"strings"

	mDNS "github.com/miekg/dns"
)

const maxValidationCNAMEChainLength = 16

// validationCNAMEChain returns only the ordered, normalized CNAME targets
// reachable from the original DNS question. It excludes addresses and
// unrelated answer records before handing validation evidence to telemetry.
func validationCNAMEChain(response *mDNS.Msg) []string {
	if response == nil || len(response.Question) == 0 {
		return nil
	}
	targetByOwner := make(map[string]string)
	for _, answer := range response.Answer {
		record, isCNAME := answer.(*mDNS.CNAME)
		if !isCNAME {
			continue
		}
		owner := validationDNSHostname(record.Hdr.Name)
		target := validationDNSHostname(record.Target)
		if owner == "" || target == "" {
			continue
		}
		targetByOwner[owner] = target
	}

	current := validationDNSHostname(response.Question[0].Name)
	chain := make([]string, 0, len(targetByOwner))
	seen := make(map[string]struct{}, len(targetByOwner))
	if current != "" {
		seen[current] = struct{}{}
	}
	for current != "" && len(chain) < maxValidationCNAMEChainLength {
		target, loaded := targetByOwner[current]
		if !loaded {
			break
		}
		if _, loop := seen[target]; loop {
			break
		}
		seen[target] = struct{}{}
		chain = append(chain, target)
		current = target
	}
	return chain
}

func validationDNSHostname(value string) string {
	value = strings.ToLower(strings.TrimSpace(FqdnToDomain(value)))
	if value == "" || len(value) > 253 {
		return ""
	}
	if _, err := netip.ParseAddr(value); err == nil {
		return ""
	}
	if _, valid := mDNS.IsDomainName(value + "."); !valid {
		return ""
	}
	return value
}
