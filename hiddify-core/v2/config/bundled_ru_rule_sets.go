package config

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	BundledRUDomainsRuleSetTag   = "zapret-ru-domains"
	BundledRUIPRuleSetTag        = "zapret-ru-ip"
	BundledRURuleSetDirectory    = "data/rule-sets"
	BundledRUDomainsRuleSetPath  = BundledRURuleSetDirectory + "/zapret-ru-domains.srs"
	BundledRUIPRuleSetPath       = BundledRURuleSetDirectory + "/zapret-ru-ip.srs"
	BundledRURuleSetManifestPath = BundledRURuleSetDirectory + "/manifest.json"
)

// bundledRURuleSetFiles contains byte-exact files from the pinned reference
// revision plus ZEON's immutable provenance manifest. There is no runtime
// downloader or updater for these files.
//
//go:embed rulesets/manifest.json rulesets/reference-manifest.json rulesets/zapret-ru-domains.json rulesets/*.srs
var bundledRURuleSetFiles embed.FS

type BundledRURuleSetReference struct {
	Repository     string `json:"repository"`
	Commit         string `json:"commit"`
	Tree           string `json:"tree"`
	ManifestFile   string `json:"manifestFile"`
	ManifestSHA256 string `json:"manifestSha256"`
}

type BundledRURuleSetMetadata struct {
	ID                       string `json:"id"`
	Version                  string `json:"version"`
	SourceRepository         string `json:"sourceRepository"`
	SourceCommit             string `json:"sourceCommit"`
	SourceFile               string `json:"sourceFile"`
	SourceSHA256             string `json:"sourceSha256"`
	GeneratedSRSSHA256       string `json:"generatedSrsSha256"`
	License                  string `json:"license"`
	GeneratedAt              string `json:"generatedAt"`
	DomainCount              int    `json:"domainCount"`
	CIDRCount                int    `json:"cidrCount"`
	FormatVersion            int    `json:"formatVersion"`
	IPv4CIDRCount            int    `json:"ipv4CidrCount,omitempty"`
	IPv6CIDRCount            int    `json:"ipv6CidrCount,omitempty"`
	DeclaredUpstreamSource   string `json:"declaredUpstreamSource,omitempty"`
	DeclaredUpstreamCommit   string `json:"declaredUpstreamCommit,omitempty"`
	DeclaredUpstreamVerified bool   `json:"declaredUpstreamVerified,omitempty"`
}

type BundledRURuleSetManifest struct {
	FormatVersion        int                        `json:"formatVersion"`
	GeneratedAtSemantics string                     `json:"generatedAtSemantics"`
	Reference            BundledRURuleSetReference  `json:"reference"`
	RuleSets             []BundledRURuleSetMetadata `json:"ruleSets"`
}

type bundledRURuleSetAsset struct {
	id                 string
	embeddedPath       string
	sourceEmbeddedPath string
	targetPath         string
	sourceSHA256       string
	sha256             string
}

func bundledRURuleSetAssets() []bundledRURuleSetAsset {
	return []bundledRURuleSetAsset{
		{
			id:                 BundledRUDomainsRuleSetTag,
			embeddedPath:       "rulesets/zapret-ru-domains.srs",
			sourceEmbeddedPath: "rulesets/zapret-ru-domains.json",
			targetPath:         BundledRUDomainsRuleSetPath,
			sourceSHA256:       "311c8f5a2ef10b5ad2d52362db354e42dba45d34993816dae2cbf027867bea1b",
			sha256:             "a39faeb4a4c894a2ce665b8919322cee626f61dd12c63a63736fcf8b0a433053",
		},
		{
			id:                 BundledRUIPRuleSetTag,
			embeddedPath:       "rulesets/zapret-ru-ip.srs",
			sourceEmbeddedPath: "rulesets/zapret-ru-ip.srs",
			targetPath:         BundledRUIPRuleSetPath,
			sourceSHA256:       "1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b",
			sha256:             "1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b",
		},
	}
}

func ReadBundledRURuleSetManifest() (BundledRURuleSetManifest, error) {
	content, err := bundledRURuleSetFiles.ReadFile("rulesets/manifest.json")
	if err != nil {
		return BundledRURuleSetManifest{}, err
	}
	var manifest BundledRURuleSetManifest
	if err := json.Unmarshal(content, &manifest); err != nil {
		return BundledRURuleSetManifest{}, fmt.Errorf("decode bundled RU rule-set manifest: %w", err)
	}
	if err := validateBundledRURuleSetManifest(manifest); err != nil {
		return BundledRURuleSetManifest{}, err
	}
	return manifest, nil
}

func validateBundledRURuleSetManifest(manifest BundledRURuleSetManifest) error {
	if manifest.FormatVersion != 1 {
		return fmt.Errorf("unsupported bundled RU rule-set manifest format %d", manifest.FormatVersion)
	}
	if manifest.GeneratedAtSemantics == "" {
		return fmt.Errorf("bundled RU rule-set manifest is missing generatedAt semantics")
	}
	if manifest.Reference.Repository != "https://github.com/youtubediscord/ZapretKVN-android" ||
		manifest.Reference.Commit != "20794bfd2e4223c0d11dba73cab2a0f0fb354e07" ||
		manifest.Reference.Tree != "490d86e6eea8dc16fd47e40c9914e6e942cc4963" {
		return fmt.Errorf("bundled RU rule-set reference is not the pinned revision")
	}
	referenceManifest, err := bundledRURuleSetFiles.ReadFile("rulesets/reference-manifest.json")
	if err != nil {
		return err
	}
	if actual := sha256Hex(referenceManifest); actual != manifest.Reference.ManifestSHA256 {
		return fmt.Errorf("reference rule-set manifest checksum mismatch: got %s", actual)
	}
	if len(manifest.RuleSets) != 2 {
		return fmt.Errorf("bundled RU rule-set manifest contains %d sets, want 2", len(manifest.RuleSets))
	}

	expected := make(map[string]bundledRURuleSetAsset)
	for _, asset := range bundledRURuleSetAssets() {
		expected[asset.id] = asset
	}
	seen := make(map[string]bool)
	for _, metadata := range manifest.RuleSets {
		asset, found := expected[metadata.ID]
		if !found || seen[metadata.ID] {
			return fmt.Errorf("unexpected or duplicate bundled RU rule-set id %q", metadata.ID)
		}
		seen[metadata.ID] = true
		if metadata.Version == "" ||
			metadata.SourceRepository == "" ||
			metadata.SourceCommit == "" ||
			metadata.SourceFile == "" ||
			metadata.SourceSHA256 == "" ||
			metadata.GeneratedSRSSHA256 == "" ||
			metadata.License == "" ||
			metadata.GeneratedAt == "" ||
			metadata.FormatVersion <= 0 {
			return fmt.Errorf("bundled RU rule-set %q has incomplete provenance", metadata.ID)
		}
		if metadata.SourceRepository != manifest.Reference.Repository ||
			metadata.SourceCommit != manifest.Reference.Commit {
			return fmt.Errorf("bundled RU rule-set %q uses an unpinned source", metadata.ID)
		}
		if metadata.GeneratedSRSSHA256 != asset.sha256 {
			return fmt.Errorf("bundled RU rule-set %q manifest SRS checksum mismatch", metadata.ID)
		}
		if metadata.SourceSHA256 != asset.sourceSHA256 {
			return fmt.Errorf("bundled RU rule-set %q manifest source checksum mismatch", metadata.ID)
		}
		sourceContent, err := bundledRURuleSetFiles.ReadFile(asset.sourceEmbeddedPath)
		if err != nil {
			return err
		}
		if actual := sha256Hex(sourceContent); actual != asset.sourceSHA256 {
			return fmt.Errorf("bundled RU rule-set %q source checksum mismatch: got %s", metadata.ID, actual)
		}
		content, err := bundledRURuleSetFiles.ReadFile(asset.embeddedPath)
		if err != nil {
			return err
		}
		if actual := sha256Hex(content); actual != asset.sha256 {
			return fmt.Errorf("bundled RU rule-set %q checksum mismatch: got %s", metadata.ID, actual)
		}
	}
	return nil
}

func EnsureBundledRURuleSets(workingPath string) error {
	if strings.TrimSpace(workingPath) == "" {
		return fmt.Errorf("working path is required to install bundled RU rule-sets")
	}
	if _, err := ReadBundledRURuleSetManifest(); err != nil {
		return err
	}
	for _, asset := range bundledRURuleSetAssets() {
		content, err := bundledRURuleSetFiles.ReadFile(asset.embeddedPath)
		if err != nil {
			return err
		}
		target := filepath.Join(workingPath, filepath.FromSlash(asset.targetPath))
		if err := installBundledRURuleSetFile(target, content, asset.sha256); err != nil {
			return fmt.Errorf("install bundled RU rule-set %q: %w", asset.id, err)
		}
	}
	manifest, err := bundledRURuleSetFiles.ReadFile("rulesets/manifest.json")
	if err != nil {
		return err
	}
	manifestTarget := filepath.Join(workingPath, filepath.FromSlash(BundledRURuleSetManifestPath))
	if err := installBundledRURuleSetFile(manifestTarget, manifest, sha256Hex(manifest)); err != nil {
		return fmt.Errorf("install bundled RU rule-set manifest: %w", err)
	}
	return nil
}

func installBundledRURuleSetFile(target string, content []byte, expectedSHA256 string) error {
	if current, err := os.Open(target); err == nil {
		currentSHA256, hashErr := sha256Reader(current)
		closeErr := current.Close()
		if hashErr == nil && closeErr == nil && currentSHA256 == expectedSHA256 {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(target), filepath.Base(target)+".*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	temporaryFile, err := os.Open(temporaryPath)
	if err != nil {
		return err
	}
	actualSHA256, hashErr := sha256Reader(temporaryFile)
	closeErr := temporaryFile.Close()
	if hashErr != nil {
		return hashErr
	}
	if closeErr != nil {
		return closeErr
	}
	if actualSHA256 != expectedSHA256 {
		return fmt.Errorf("temporary checksum mismatch: got %s", actualSHA256)
	}
	if err := os.Chmod(temporaryPath, 0o644); err != nil {
		return err
	}
	replaceErr := os.Rename(temporaryPath, target)
	if replaceErr == nil {
		return nil
	}

	// Android/Linux replace an existing file atomically above. Windows does
	// not, so keep a recoverable backup while swapping a corrupt local copy.
	if _, err := os.Stat(target); err != nil {
		return fmt.Errorf("replace target: %w", replaceErr)
	}
	backup, err := os.CreateTemp(filepath.Dir(target), filepath.Base(target)+".*.previous")
	if err != nil {
		return err
	}
	backupPath := backup.Name()
	defer os.Remove(backupPath)
	if err := backup.Close(); err != nil {
		return err
	}
	if err := os.Remove(backupPath); err != nil {
		return err
	}
	if err := os.Rename(target, backupPath); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, target); err != nil {
		if restoreErr := os.Rename(backupPath, target); restoreErr != nil {
			return fmt.Errorf("replace target: %v; restore previous target: %w", err, restoreErr)
		}
		return err
	}
	return nil
}

func sha256Hex(content []byte) string {
	digest := sha256.Sum256(content)
	return hex.EncodeToString(digest[:])
}

func sha256Reader(reader io.Reader) (string, error) {
	digest := sha256.New()
	if _, err := io.Copy(digest, reader); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func bundledRURuleSetIDs(manifest BundledRURuleSetManifest) []string {
	ids := make([]string, 0, len(manifest.RuleSets))
	for _, ruleSet := range manifest.RuleSets {
		ids = append(ids, ruleSet.ID)
	}
	sort.Strings(ids)
	return ids
}
