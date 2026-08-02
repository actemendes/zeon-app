package config

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestManagedAdsAppliesInRussiaAndGlobalOnlyWhenEnabled(t *testing.T) {
	ads := managedAdsRuleSetForTest(t, []string{
		"tpc.googlesyndication.com", "criteo.com", "ads.vk.com", "appmetrica.yandex.ru", "adfox.ru",
	})
	path := writeManagedRUBundleForTest(t, []managedRURuleSet{ads})
	previousPath := managedRURuleSetBundleFile
	managedRURuleSetBundleFile = path
	t.Cleanup(func() { managedRURuleSetBundleFile = previousPath })

	for _, region := range []string{"ru", "other"} {
		t.Run(region+" enabled", func(t *testing.T) {
			hopt := DefaultHiddifyOptions()
			hopt.Region = region
			hopt.BlockAds = true
			opts := option.Options{DNS: &option.DNSOptions{}}
			if err := setRoutingOptions(&opts, hopt); err != nil {
				t.Fatal(err)
			}
			tag := managedRURuleSetTagPrefix + "ads"
			foundLocal := false
			foundEmbedded := false
			for _, ruleSet := range opts.Route.RuleSet {
				if ruleSet.Tag == tag {
					foundLocal = ruleSet.Type == C.RuleSetTypeLocal && ruleSet.Format == C.RuleSetFormatBinary && ruleSet.LocalOptions.Path != ""
				}
				if ruleSet.Tag == embeddedAdsRuleSetTag {
					foundEmbedded = ruleSet.Type == C.RuleSetTypeInline && len(ruleSet.InlineOptions.Rules) > 0
				}
				if ruleSet.Tag == "geosite-ads" {
					t.Fatal("mutable remote ads rule set must not be present")
				}
			}
			if !foundLocal || !foundEmbedded || indexRejectedRuleSet(opts.Route.Rules, tag) < 0 {
				t.Fatalf("managed ads local/reject rule missing in region %s", region)
			}
			managedIndex := indexRejectedRuleSet(opts.Route.Rules, tag)
			embeddedIndex := indexRejectedRuleSet(opts.Route.Rules, embeddedAdsRuleSetTag)
			if managedIndex < 0 || embeddedIndex < 0 || managedIndex > embeddedIndex {
				t.Fatalf("managed ads must precede embedded fallback: managed=%d embedded=%d", managedIndex, embeddedIndex)
			}
			foundDNSRefused := false
			for _, rule := range opts.DNS.Rules {
				candidate := rule.DefaultOptions
				if containsString(candidate.RuleSet, tag) && candidate.Action == C.RuleActionTypePredefined &&
					candidate.PredefinedOptions.Rcode != nil {
					foundDNSRefused = true
				}
			}
			if !foundDNSRefused {
				t.Fatalf("managed ads DNS REFUSED rule missing in region %s", region)
			}
			if region == "ru" {
				adsIndex := indexRejectedRuleSet(opts.Route.Rules, tag)
				yandexIndex := indexRouteRuleSet(opts.Route.Rules, RUYandexRuleSetTag, OutboundDirectTag)
				if adsIndex < 0 || yandexIndex < 0 || adsIndex >= yandexIndex {
					t.Fatalf("managed ads must precede Russia direct rules: ads=%d yandex=%d", adsIndex, yandexIndex)
				}
			}
		})

		t.Run(region+" disabled", func(t *testing.T) {
			hopt := DefaultHiddifyOptions()
			hopt.Region = region
			hopt.BlockAds = false
			opts := option.Options{DNS: &option.DNSOptions{}}
			if err := setRoutingOptions(&opts, hopt); err != nil {
				t.Fatal(err)
			}
			for _, ruleSet := range opts.Route.RuleSet {
				if ruleSet.Tag == managedRURuleSetTagPrefix+"ads" || ruleSet.Tag == embeddedAdsRuleSetTag || ruleSet.Tag == RUAdListHardcodedRuleSetTag {
					t.Fatalf("ads rule set %q present while disabled", ruleSet.Tag)
				}
			}
		})
	}
}

func TestEmbeddedAdsFallbackAppliesWithoutManagedRelease(t *testing.T) {
	previousPath := managedRURuleSetBundleFile
	managedRURuleSetBundleFile = filepath.Join(t.TempDir(), "active.json")
	t.Cleanup(func() { managedRURuleSetBundleFile = previousPath })

	parsed, err := srs.Read(bytes.NewReader(embeddedAdsSRS), false)
	if err != nil || len(parsed.Options.Rules) == 0 {
		t.Fatalf("embedded ads artifact is invalid: rules=%d err=%v", len(parsed.Options.Rules), err)
	}
	recovered, err := srs.Read(bytes.NewReader(embeddedAdsSRS), true)
	if err != nil {
		t.Fatalf("recover embedded ads artifact: %v", err)
	}
	for _, domain := range []string{
		"tpc.googlesyndication.com", "criteo.com", "ads.vk.com", "appmetrica.yandex.ru", "adfox.ru",
	} {
		found := false
		for _, rule := range recovered.Options.Rules {
			if containsString(rule.DefaultOptions.Domain, domain) {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("embedded ads artifact is missing acceptance domain %q", domain)
		}
	}
	for _, region := range []string{"ru", "other"} {
		hopt := DefaultHiddifyOptions()
		hopt.Region = region
		hopt.BlockAds = true
		opts := option.Options{DNS: &option.DNSOptions{}}
		if err := setRoutingOptions(&opts, hopt); err != nil {
			t.Fatal(err)
		}
		foundDNSRefused := false
		for _, rule := range opts.DNS.Rules {
			candidate := rule.DefaultOptions
			if containsString(candidate.RuleSet, embeddedAdsRuleSetTag) &&
				candidate.Action == C.RuleActionTypePredefined && candidate.PredefinedOptions.Rcode != nil {
				foundDNSRefused = true
			}
		}
		if indexRejectedRuleSet(opts.Route.Rules, embeddedAdsRuleSetTag) < 0 || !foundDNSRefused {
			t.Fatalf("embedded ads fallback missing in region %s", region)
		}
	}
}

func TestManagedRURuleSetsPrecedeRussiaDirectPolicy(t *testing.T) {
	vpn := managedRURuleSetForTest(t, "force-vpn", 10, "VPN", []string{"blocked.ru"}, nil)
	direct := managedRURuleSetForTest(t, "extra-direct", 20, "DIRECT", []string{"internal.example"}, nil)
	path := writeManagedRUBundleForTest(t, []managedRURuleSet{direct, vpn})
	previousPath := managedRURuleSetBundleFile
	managedRURuleSetBundleFile = path
	t.Cleanup(func() { managedRURuleSetBundleFile = previousPath })

	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}

	vpnTag := managedRURuleSetTagPrefix + vpn.Metadata.ID
	directTag := managedRURuleSetTagPrefix + direct.Metadata.ID
	vpnIndex := indexRouteRuleSet(opts.Route.Rules, vpnTag, OutboundMainDetour)
	directIndex := indexRouteRuleSet(opts.Route.Rules, directTag, OutboundDirectTag)
	yandexIndex := indexRouteRuleSet(opts.Route.Rules, RUYandexRuleSetTag, OutboundDirectTag)
	ruDomainsIndex := indexRouteRuleSet(opts.Route.Rules, BundledRUDomainsRuleSetTag, OutboundDirectTag)
	if vpnIndex < 0 || directIndex < 0 || yandexIndex < 0 || ruDomainsIndex < 0 {
		t.Fatalf("missing managed or bundled routing rule: vpn=%d direct=%d yandex=%d ru=%d", vpnIndex, directIndex, yandexIndex, ruDomainsIndex)
	}
	if !(vpnIndex < directIndex && directIndex < yandexIndex && yandexIndex < ruDomainsIndex) {
		t.Fatalf("unexpected managed RU priority: vpn=%d direct=%d yandex=%d ru=%d", vpnIndex, directIndex, yandexIndex, ruDomainsIndex)
	}
	if dnsIndex := indexDNSRuleSet(opts.DNS.Rules, vpnTag, DNSMultiRemoteTag); dnsIndex < 0 {
		t.Fatal("managed VPN domain must use remote DNS")
	}
}

func TestGlobalPresetIgnoresManagedRURuleSets(t *testing.T) {
	managed := managedRURuleSetForTest(t, "force-vpn", 10, "VPN", []string{"blocked.ru"}, nil)
	path := writeManagedRUBundleForTest(t, []managedRURuleSet{managed})
	previousPath := managedRURuleSetBundleFile
	managedRURuleSetBundleFile = path
	t.Cleanup(func() { managedRURuleSetBundleFile = previousPath })

	hopt := DefaultHiddifyOptions()
	hopt.Region = "other"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	managedTag := managedRURuleSetTagPrefix + managed.Metadata.ID
	if index := indexRouteRuleSet(opts.Route.Rules, managedTag, OutboundMainDetour); index >= 0 {
		t.Fatalf("Global preset unexpectedly contains managed RU rule at index %d", index)
	}
	for _, ruleSet := range opts.Route.RuleSet {
		if ruleSet.Tag == managedTag {
			t.Fatalf("Global preset unexpectedly declares managed RU rule-set %q", managedTag)
		}
	}
}

func TestTamperedManagedRUBundleFallsBackToBundledRules(t *testing.T) {
	managed := managedRURuleSetForTest(t, "force-vpn", 10, "VPN", []string{"blocked.ru"}, nil)
	path := writeManagedRUBundleForTest(t, []managedRURuleSet{managed})
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var envelope managedRURuleSetEnvelope
	if err := json.Unmarshal(content, &envelope); err != nil {
		t.Fatal(err)
	}
	envelope.Checksum = "00" + envelope.Checksum[2:]
	tampered, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, tampered, 0o600); err != nil {
		t.Fatal(err)
	}

	previousPath := managedRURuleSetBundleFile
	managedRURuleSetBundleFile = path
	t.Cleanup(func() { managedRURuleSetBundleFile = previousPath })
	hopt := DefaultHiddifyOptions()
	hopt.Region = "ru"
	opts := option.Options{DNS: &option.DNSOptions{}}
	if err := setRoutingOptions(&opts, hopt); err != nil {
		t.Fatalf("setRoutingOptions returned error: %v", err)
	}
	if index := indexRouteRuleSet(opts.Route.Rules, managedRURuleSetTagPrefix+managed.Metadata.ID, OutboundMainDetour); index >= 0 {
		t.Fatalf("tampered managed rule unexpectedly active at index %d", index)
	}
	if index := indexRouteRuleSet(opts.Route.Rules, BundledRUDomainsRuleSetTag, OutboundDirectTag); index < 0 {
		t.Fatal("bundled RU fallback is missing")
	}
}

func TestManagedRURuleSetLoaderRejectsTruncatedAndConflictingBundles(t *testing.T) {
	truncated := filepath.Join(t.TempDir(), "active.json")
	if err := os.WriteFile(truncated, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readManagedRURuleSets(truncated); err == nil {
		t.Fatal("truncated bundle was accepted")
	}

	vpn := managedRURuleSetForTest(t, "vpn", 10, "VPN", []string{"same.ru"}, nil)
	direct := managedRURuleSetForTest(t, "direct", 20, "DIRECT", []string{"same.ru"}, nil)
	if _, err := readManagedRURuleSets(writeManagedRUBundleForTest(t, []managedRURuleSet{vpn, direct})); err == nil {
		t.Fatal("cross-action conflict was accepted")
	}

	empty := managedRURuleSetForTest(t, "empty", 30, "VPN", nil, nil)
	empty.Metadata.Checksum = strings.Repeat("0", 64)
	if _, err := readManagedRURuleSets(writeManagedRUBundleForTest(t, []managedRURuleSet{empty})); err == nil {
		t.Fatal("empty rule-set with an invalid checksum was accepted")
	}
}

func managedRURuleSetForTest(
	t *testing.T,
	id string,
	priority int,
	action string,
	domains []string,
	cidrs []string,
) managedRURuleSet {
	t.Helper()
	payload := managedRURuleSetPayload{DomainSuffix: domains, IPCIDR: cidrs}
	canonical, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(canonical)
	return managedRURuleSet{
		Metadata: managedRURuleSetMetadata{
			ID:               id,
			Version:          "test-v1",
			Source:           "test",
			GeneratedAt:      "2026-07-31T00:00:00Z",
			ExpiresAt:        "2026-08-31T00:00:00Z",
			Checksum:         hex.EncodeToString(digest[:]),
			FormatVersion:    1,
			DomainCount:      len(domains),
			CIDRCount:        len(cidrs),
			Priority:         priority,
			Action:           action,
			ApplicablePreset: "russia",
		},
		Payload: payload,
	}
}

func managedAdsRuleSetForTest(t *testing.T, domains []string) managedRURuleSet {
	t.Helper()
	var artifact bytes.Buffer
	err := srs.Write(&artifact, option.PlainRuleSet{Rules: []option.HeadlessRule{{
		Type:           C.RuleTypeDefault,
		DefaultOptions: option.DefaultHeadlessRule{DomainSuffix: domains},
	}}}, C.RuleSetVersionCurrent)
	if err != nil {
		t.Fatal(err)
	}
	bytes := artifact.Bytes()
	digest := sha256.Sum256(bytes)
	return managedRURuleSet{
		Metadata: managedRURuleSetMetadata{
			ID: "ads", Version: "test-v1", Source: "test", GeneratedAt: "2026-07-31T00:00:00Z",
			ExpiresAt: "2026-08-31T00:00:00Z", Checksum: hex.EncodeToString(digest[:]), FormatVersion: 1,
			Priority: -1000, Action: "BLOCK", ApplicablePreset: "all", Format: "srs", Size: len(bytes),
		},
		Payload: managedRURuleSetPayload{DomainSuffix: []string{}, IPCIDR: []string{}, SRSBase64: base64.StdEncoding.EncodeToString(bytes)},
	}
}

func writeManagedRUBundleForTest(t *testing.T, ruleSets []managedRURuleSet) string {
	t.Helper()
	payload, err := json.Marshal(managedRURuleSetBundle{
		GeneratedAt: "2026-07-31T00:00:00Z",
		ExpiresAt:   "2026-08-31T00:00:00Z",
		RuleSets:    ruleSets,
	})
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	envelope, err := json.Marshal(managedRURuleSetEnvelope{
		FormatVersion: 1,
		Generation:    1,
		Payload:       base64.RawURLEncoding.EncodeToString(payload),
		Checksum:      hex.EncodeToString(digest[:]),
	})
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "active.json")
	if err := os.WriteFile(path, envelope, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, ruleSet := range ruleSets {
		if ruleSet.Metadata.Format != "srs" {
			continue
		}
		artifact, err := base64.StdEncoding.DecodeString(ruleSet.Payload.SRSBase64)
		if err != nil {
			t.Fatal(err)
		}
		artifactDirectory := filepath.Join(directory, "artifacts")
		if err := os.MkdirAll(artifactDirectory, 0o700); err != nil {
			t.Fatal(err)
		}
		artifactPath := filepath.Join(artifactDirectory, ruleSet.Metadata.ID+"-"+ruleSet.Metadata.Checksum+".srs")
		if err := os.WriteFile(artifactPath, artifact, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return path
}
