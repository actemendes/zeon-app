package config

import (
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestBundledRURuleSetManifestPinsReferenceAndCompleteMetadata(t *testing.T) {
	manifest, err := ReadBundledRURuleSetManifest()
	if err != nil {
		t.Fatalf("ReadBundledRURuleSetManifest returned error: %v", err)
	}
	if manifest.Reference.Commit != "20794bfd2e4223c0d11dba73cab2a0f0fb354e07" {
		t.Fatalf("reference commit = %q", manifest.Reference.Commit)
	}
	if manifest.Reference.Tree != "490d86e6eea8dc16fd47e40c9914e6e942cc4963" {
		t.Fatalf("reference tree = %q", manifest.Reference.Tree)
	}
	ids := bundledRURuleSetIDs(manifest)
	if len(ids) != 2 || ids[0] != BundledRUDomainsRuleSetTag || ids[1] != BundledRUIPRuleSetTag {
		t.Fatalf("rule-set ids = %v", ids)
	}
	for _, metadata := range manifest.RuleSets {
		if metadata.Version == "" ||
			metadata.SourceRepository == "" ||
			metadata.SourceCommit == "" ||
			metadata.SourceFile == "" ||
			metadata.SourceSHA256 == "" ||
			metadata.GeneratedSRSSHA256 == "" ||
			metadata.License == "" ||
			metadata.GeneratedAt == "" ||
			metadata.FormatVersion == 0 {
			t.Fatalf("incomplete provenance for %s: %+v", metadata.ID, metadata)
		}
	}
}

func TestBundledRURuleSetContentCountsAndVersions(t *testing.T) {
	manifest, err := ReadBundledRURuleSetManifest()
	if err != nil {
		t.Fatalf("ReadBundledRURuleSetManifest returned error: %v", err)
	}
	metadataByID := make(map[string]BundledRURuleSetMetadata)
	for _, metadata := range manifest.RuleSets {
		metadataByID[metadata.ID] = metadata
	}
	for _, asset := range bundledRURuleSetAssets() {
		file, err := bundledRURuleSetFiles.Open(asset.embeddedPath)
		if err != nil {
			t.Fatalf("open %s: %v", asset.id, err)
		}
		ruleSet, err := srs.Read(file, true)
		file.Close()
		if err != nil {
			t.Fatalf("decode %s: %v", asset.id, err)
		}
		domainCount, ipv4Count, ipv6Count := countBundledRuleSetEntries(ruleSet.Options.Rules)
		metadata := metadataByID[asset.id]
		if int(ruleSet.Version) != metadata.FormatVersion {
			t.Fatalf("%s format version = %d, manifest = %d", asset.id, ruleSet.Version, metadata.FormatVersion)
		}
		if domainCount != metadata.DomainCount {
			t.Fatalf("%s domain count = %d, manifest = %d", asset.id, domainCount, metadata.DomainCount)
		}
		if ipv4Count+ipv6Count != metadata.CIDRCount {
			t.Fatalf("%s CIDR count = %d, manifest = %d", asset.id, ipv4Count+ipv6Count, metadata.CIDRCount)
		}
		if ipv4Count != metadata.IPv4CIDRCount || ipv6Count != metadata.IPv6CIDRCount {
			t.Fatalf("%s family counts = %d/%d, manifest = %d/%d", asset.id, ipv4Count, ipv6Count, metadata.IPv4CIDRCount, metadata.IPv6CIDRCount)
		}
		if asset.id == BundledRUDomainsRuleSetTag {
			suffixes := bundledRuleSetDomainSuffixes(ruleSet.Options.Rules)
			if strings.Join(suffixes, ",") != ".ru,.su,.xn--p1ai" {
				t.Fatalf("RU domain suffixes = %v", suffixes)
			}
		}
	}
}

func TestEnsureBundledRURuleSetsInstallsAndRepairsPinnedFiles(t *testing.T) {
	workingPath := t.TempDir()
	if err := EnsureBundledRURuleSets(workingPath); err != nil {
		t.Fatalf("EnsureBundledRURuleSets returned error: %v", err)
	}
	for _, asset := range bundledRURuleSetAssets() {
		target := filepath.Join(workingPath, filepath.FromSlash(asset.targetPath))
		content, err := os.ReadFile(target)
		if err != nil {
			t.Fatalf("read installed %s: %v", asset.id, err)
		}
		if actual := sha256Hex(content); actual != asset.sha256 {
			t.Fatalf("%s installed checksum = %s", asset.id, actual)
		}
	}

	corruptPath := filepath.Join(workingPath, filepath.FromSlash(BundledRUIPRuleSetPath))
	if err := os.WriteFile(corruptPath, []byte("corrupt"), 0o644); err != nil {
		t.Fatalf("corrupt installed file: %v", err)
	}
	if err := EnsureBundledRURuleSets(workingPath); err != nil {
		t.Fatalf("repair bundled rule-sets: %v", err)
	}
	repaired, err := os.ReadFile(corruptPath)
	if err != nil {
		t.Fatalf("read repaired file: %v", err)
	}
	if actual := sha256Hex(repaired); actual != "1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b" {
		t.Fatalf("repaired IP rule-set checksum = %s", actual)
	}
}

func bundledRuleSetDomainSuffixes(rules []option.HeadlessRule) []string {
	var suffixes []string
	for _, rule := range rules {
		switch rule.Type {
		case C.RuleTypeDefault:
			suffixes = append(suffixes, rule.DefaultOptions.DomainSuffix...)
		case C.RuleTypeLogical:
			suffixes = append(suffixes, bundledRuleSetDomainSuffixes(rule.LogicalOptions.Rules)...)
		}
	}
	sort.Strings(suffixes)
	return suffixes
}

func countBundledRuleSetEntries(rules []option.HeadlessRule) (domainCount int, ipv4Count int, ipv6Count int) {
	for _, rule := range rules {
		switch rule.Type {
		case C.RuleTypeDefault:
			domainCount += len(rule.DefaultOptions.Domain)
			domainCount += len(rule.DefaultOptions.DomainSuffix)
			for _, cidr := range rule.DefaultOptions.IPCIDR {
				prefix, err := netip.ParsePrefix(cidr)
				if err != nil {
					panic("invalid CIDR in bundled rule set: " + cidr)
				}
				if prefix.Addr().Is4() {
					ipv4Count++
				} else {
					ipv6Count++
				}
			}
		case C.RuleTypeLogical:
			nestedDomains, nestedIPv4, nestedIPv6 := countBundledRuleSetEntries(rule.LogicalOptions.Rules)
			domainCount += nestedDomains
			ipv4Count += nestedIPv4
			ipv6Count += nestedIPv6
		}
	}
	return
}
