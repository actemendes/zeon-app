package config

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"regexp"
	"sort"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	sdns "github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/option"
)

const (
	ManagedRURuleSetBundlePath = "data/rule-sets/managed/active.json"
	managedRURuleSetTagPrefix  = "zeon-managed-"
	managedRUMaxBundleBytes    = 4 << 20
	managedRUMaxRuleSets       = 32
	managedRUMaxEntries        = 100_000
)

var managedRURuleSetIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// managedRURuleSetBundleFile is a test seam. Production code never mutates it.
var managedRURuleSetBundleFile = ManagedRURuleSetBundlePath

type managedRURuleSetEnvelope struct {
	FormatVersion int    `json:"formatVersion"`
	Generation    int64  `json:"generation"`
	Payload       string `json:"payload"`
	Checksum      string `json:"checksum"`
}

type managedRURuleSetBundle struct {
	GeneratedAt string             `json:"generatedAt"`
	ExpiresAt   string             `json:"expiresAt"`
	RuleSets    []managedRURuleSet `json:"ruleSets"`
}

type managedRURuleSet struct {
	Metadata managedRURuleSetMetadata `json:"metadata"`
	Payload  managedRURuleSetPayload  `json:"payload"`
}

type managedRURuleSetMetadata struct {
	ID               string `json:"id"`
	Version          string `json:"version"`
	Source           string `json:"source"`
	GeneratedAt      string `json:"generatedAt"`
	ExpiresAt        string `json:"expiresAt"`
	Checksum         string `json:"checksum"`
	FormatVersion    int    `json:"formatVersion"`
	DomainCount      int    `json:"domainCount"`
	CIDRCount        int    `json:"cidrCount"`
	Priority         int    `json:"priority"`
	Action           string `json:"action"`
	ApplicablePreset string `json:"applicablePreset"`
}

type managedRURuleSetPayload struct {
	DomainSuffix []string `json:"domainSuffix"`
	IPCIDR       []string `json:"ipCidr"`
}

func readManagedRURuleSets(path string) ([]managedRURuleSet, error) {
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if len(content) == 0 || len(content) > managedRUMaxBundleBytes {
		return nil, fmt.Errorf("managed RU rule-set bundle has invalid size %d", len(content))
	}

	var envelope managedRURuleSetEnvelope
	if err := json.Unmarshal(content, &envelope); err != nil {
		return nil, fmt.Errorf("decode managed RU rule-set envelope: %w", err)
	}
	// Generation zero is the server's bootstrap bundle. It contains no active
	// entries but is still a valid, cacheable policy until release 1 exists.
	if envelope.FormatVersion != 1 || envelope.Generation < 0 {
		return nil, fmt.Errorf("unsupported managed RU rule-set envelope")
	}
	payload, err := decodeManagedRUPayload(envelope.Payload)
	if err != nil {
		return nil, err
	}
	actualChecksum := sha256.Sum256(payload)
	if !strings.EqualFold(hex.EncodeToString(actualChecksum[:]), envelope.Checksum) {
		return nil, fmt.Errorf("managed RU rule-set bundle checksum mismatch")
	}

	var bundle managedRURuleSetBundle
	if err := json.Unmarshal(payload, &bundle); err != nil {
		return nil, fmt.Errorf("decode managed RU rule-set payload: %w", err)
	}
	if bundle.GeneratedAt == "" || bundle.ExpiresAt == "" {
		return nil, fmt.Errorf("managed RU rule-set bundle metadata is incomplete")
	}
	if len(bundle.RuleSets) > managedRUMaxRuleSets {
		return nil, fmt.Errorf("managed RU rule-set bundle contains too many sets")
	}

	entries := 0
	seenIDs := make(map[string]struct{}, len(bundle.RuleSets))
	entryActions := make(map[string]string)
	for index := range bundle.RuleSets {
		ruleSet := &bundle.RuleSets[index]
		if err := validateManagedRURuleSet(*ruleSet); err != nil {
			return nil, fmt.Errorf("validate managed RU rule-set %d: %w", index, err)
		}
		if _, exists := seenIDs[ruleSet.Metadata.ID]; exists {
			return nil, fmt.Errorf("duplicate managed RU rule-set id %q", ruleSet.Metadata.ID)
		}
		seenIDs[ruleSet.Metadata.ID] = struct{}{}
		entries += len(ruleSet.Payload.DomainSuffix) + len(ruleSet.Payload.IPCIDR)
		if entries > managedRUMaxEntries {
			return nil, fmt.Errorf("managed RU rule-set bundle contains too many entries")
		}
		for _, domain := range ruleSet.Payload.DomainSuffix {
			if err := recordManagedRUAction(entryActions, "domain:"+domain, ruleSet.Metadata.Action); err != nil {
				return nil, err
			}
		}
		for _, cidr := range ruleSet.Payload.IPCIDR {
			if err := recordManagedRUAction(entryActions, "cidr:"+cidr, ruleSet.Metadata.Action); err != nil {
				return nil, err
			}
		}
	}

	sort.SliceStable(bundle.RuleSets, func(i, j int) bool {
		if bundle.RuleSets[i].Metadata.Priority != bundle.RuleSets[j].Metadata.Priority {
			return bundle.RuleSets[i].Metadata.Priority < bundle.RuleSets[j].Metadata.Priority
		}
		return bundle.RuleSets[i].Metadata.ID < bundle.RuleSets[j].Metadata.ID
	})
	return bundle.RuleSets, nil
}

func decodeManagedRUPayload(value string) ([]byte, error) {
	payload, err := base64.RawURLEncoding.DecodeString(value)
	if err == nil {
		return payload, nil
	}
	payload, paddedErr := base64.URLEncoding.DecodeString(value)
	if paddedErr != nil {
		return nil, fmt.Errorf("decode managed RU rule-set payload: %w", err)
	}
	return payload, nil
}

func validateManagedRURuleSet(ruleSet managedRURuleSet) error {
	metadata := ruleSet.Metadata
	if !managedRURuleSetIDPattern.MatchString(metadata.ID) {
		return fmt.Errorf("invalid id %q", metadata.ID)
	}
	if metadata.Version == "" || metadata.Source == "" || metadata.GeneratedAt == "" || metadata.ExpiresAt == "" {
		return fmt.Errorf("metadata is incomplete")
	}
	if metadata.FormatVersion != 1 {
		return fmt.Errorf("unsupported format version %d", metadata.FormatVersion)
	}
	if metadata.ApplicablePreset != "russia" && metadata.ApplicablePreset != "all" {
		return fmt.Errorf("unsupported preset %q", metadata.ApplicablePreset)
	}
	switch metadata.Action {
	case "VPN", "DIRECT", "BLOCK":
	default:
		return fmt.Errorf("unsupported action %q", metadata.Action)
	}
	if metadata.DomainCount != len(ruleSet.Payload.DomainSuffix) || metadata.CIDRCount != len(ruleSet.Payload.IPCIDR) {
		return fmt.Errorf("entry count mismatch")
	}
	for _, domain := range ruleSet.Payload.DomainSuffix {
		if domain == "" || domain != strings.TrimSpace(domain) || domain != strings.ToLower(domain) ||
			strings.Contains(domain, "://") || strings.ContainsAny(domain, " /@") || strings.HasPrefix(domain, ".") || strings.HasSuffix(domain, ".") {
			return fmt.Errorf("invalid domain suffix %q", domain)
		}
	}
	for _, cidr := range ruleSet.Payload.IPCIDR {
		if _, err := netip.ParsePrefix(cidr); err != nil {
			return fmt.Errorf("invalid CIDR %q", cidr)
		}
	}
	canonical, err := json.Marshal(ruleSet.Payload)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(canonical)
	if !strings.EqualFold(hex.EncodeToString(digest[:]), metadata.Checksum) {
		return fmt.Errorf("payload checksum mismatch")
	}
	return nil
}

func recordManagedRUAction(actions map[string]string, value string, action string) error {
	if previous, exists := actions[value]; exists && previous != action {
		return fmt.Errorf("managed RU rule %q has conflicting actions %s and %s", value, previous, action)
	}
	actions[value] = action
	return nil
}

func appendManagedRURouting(
	dnsRules *[]option.DefaultDNSRule,
	routeRules *[]option.Rule,
	ruleSets *[]option.RuleSet,
	hopt *HiddifyOptions,
	managed []managedRURuleSet,
) {
	for _, managedSet := range managed {
		if len(managedSet.Payload.DomainSuffix)+len(managedSet.Payload.IPCIDR) == 0 {
			continue
		}
		tag := managedRURuleSetTagPrefix + managedSet.Metadata.ID
		headlessRules := make([]option.HeadlessRule, 0, 2)
		if len(managedSet.Payload.DomainSuffix) > 0 {
			headlessRules = append(headlessRules, option.HeadlessRule{
				Type: C.RuleTypeDefault,
				DefaultOptions: option.DefaultHeadlessRule{
					DomainSuffix: managedSet.Payload.DomainSuffix,
				},
			})
		}
		if len(managedSet.Payload.IPCIDR) > 0 {
			headlessRules = append(headlessRules, option.HeadlessRule{
				Type: C.RuleTypeDefault,
				DefaultOptions: option.DefaultHeadlessRule{
					IPCIDR: managedSet.Payload.IPCIDR,
				},
			})
		}
		*ruleSets = append(*ruleSets, option.RuleSet{
			Type: C.RuleSetTypeInline,
			Tag:  tag,
			InlineOptions: option.PlainRuleSet{
				Rules: headlessRules,
			},
		})

		if len(managedSet.Payload.DomainSuffix) > 0 {
			*dnsRules = append(*dnsRules, managedRUDNSRule(tag, managedSet.Metadata.Action, hopt))
		}
		*routeRules = append(*routeRules, managedRURouteRule(tag, managedSet.Metadata.Action))
	}
}

func managedRUDNSRule(tag string, action string, hopt *HiddifyOptions) option.DefaultDNSRule {
	rule := option.DefaultDNSRule{RawDefaultDNSRule: option.RawDefaultDNSRule{RuleSet: []string{tag}}}
	switch action {
	case "VPN":
		rule.DNSRuleAction = option.DNSRuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.DNSRouteActionOptions{
				Server:         DNSMultiRemoteTag,
				Strategy:       hopt.RemoteDnsDomainStrategy,
				RewriteTTL:     &DEFAULT_DNS_TTL,
				BypassIfFailed: false,
			},
		}
	case "DIRECT":
		server, strategy := ruDestinationDNSPolicy(hopt)
		rule.DNSRuleAction = option.DNSRuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.DNSRouteActionOptions{
				Server:         server,
				Strategy:       strategy,
				RewriteTTL:     &DEFAULT_DNS_TTL,
				BypassIfFailed: true,
			},
		}
	case "BLOCK":
		rcode := option.DNSRCode(sdns.RcodeRefused)
		rule.DNSRuleAction = option.DNSRuleAction{
			Action: C.RuleActionTypePredefined,
			PredefinedOptions: option.DNSRouteActionPredefined{
				Rcode: &rcode,
			},
		}
	}
	return rule
}

func managedRURouteRule(tag string, action string) option.Rule {
	rule := option.Rule{
		Type: C.RuleTypeDefault,
		DefaultOptions: option.DefaultRule{
			RawDefaultRule: option.RawDefaultRule{RuleSet: []string{tag}},
		},
	}
	switch action {
	case "VPN":
		rule.DefaultOptions.RuleAction = option.RuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.RouteActionOptions{
				Outbound: OutboundMainDetour,
			},
		}
	case "DIRECT":
		rule.DefaultOptions.RuleAction = option.RuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.RouteActionOptions{
				Outbound: OutboundDirectTag,
			},
		}
	case "BLOCK":
		rule.DefaultOptions.RuleAction = option.RuleAction{
			Action: C.RuleActionTypeReject,
			RejectOptions: option.RejectActionOptions{
				Method: C.RuleActionRejectMethodDefault,
			},
		}
	}
	return rule
}
