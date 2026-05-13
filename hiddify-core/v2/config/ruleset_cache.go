package config

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

type RuleSetRuntimeMetadata struct {
	Tag           string   `json:"tag"`
	ActiveURL     string   `json:"active_url,omitempty"`
	FallbackURLs  []string `json:"fallback_urls,omitempty"`
	LocalPath     string   `json:"local_path,omitempty"`
	LastSuccessAt string   `json:"last_success_at,omitempty"`
	LastError     string   `json:"last_error,omitempty"`
	LastHash      string   `json:"last_hash,omitempty"`
	UsedCache     bool     `json:"used_cache"`
	FallbackUsed  bool     `json:"fallback_used"`
}

type RuleSetMetadataFile struct {
	GeneratedAt string                   `json:"generated_at"`
	RuleSets    []RuleSetRuntimeMetadata `json:"rule_sets"`
}

type ResolvedRuleSet struct {
	Tag          string
	LocalPath    string
	UsedCache    bool
	ActiveURL    string
	FallbackUsed bool
}

var ensureRuleSetCachedFunc = EnsureRuleSetCached

func EnsureRuleSetCached(ctx context.Context, source RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
	resolved := ResolvedRuleSet{Tag: source.Tag}
	meta := RuleSetRuntimeMetadata{
		Tag:          source.Tag,
		FallbackURLs: append([]string{}, source.FallbackURLs...),
	}
	rulesDir := filepath.Join(dataDir, "rulesets")
	if err := os.MkdirAll(rulesDir, 0o755); err != nil {
		meta.LastError = shortErr(err)
		_ = updateRuleSetMetadata(dataDir, meta)
		return resolved, meta, err
	}

	localPath := filepath.Join(rulesDir, source.Tag+".srs")
	meta.LocalPath = localPath

	urls := append([]string{source.PrimaryURL}, source.FallbackURLs...)
	var errs []string
	for idx, candidate := range urls {
		fallback := idx > 0
		content, dlErr := downloadRuleSet(ctx, candidate)
		if dlErr != nil {
			errs = append(errs, fmt.Sprintf("%s: %s", candidate, shortErr(dlErr)))
			continue
		}
		hash := sha256.Sum256(content)
		if err := writeAtomic(localPath, content, 0o644); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %s", candidate, shortErr(err)))
			continue
		}
		meta.ActiveURL = candidate
		meta.LastSuccessAt = time.Now().UTC().Format(time.RFC3339)
		meta.LastHash = hex.EncodeToString(hash[:])
		meta.LastError = ""
		meta.UsedCache = false
		meta.FallbackUsed = fallback
		resolved.LocalPath = localPath
		resolved.ActiveURL = candidate
		resolved.UsedCache = false
		resolved.FallbackUsed = fallback
		_ = updateRuleSetMetadata(dataDir, meta)
		return resolved, meta, nil
	}

	if fi, err := os.Stat(localPath); err == nil && fi.Size() > 0 {
		meta.UsedCache = true
		meta.FallbackUsed = false
		meta.LastError = strings.Join(errs, " | ")
		resolved.LocalPath = localPath
		resolved.UsedCache = true
		_ = updateRuleSetMetadata(dataDir, meta)
		return resolved, meta, nil
	}

	meta.LastError = strings.Join(errs, " | ")
	_ = updateRuleSetMetadata(dataDir, meta)
	return resolved, meta, errors.New("all remote sources failed and no local cache available")
}

func downloadRuleSet(ctx context.Context, url string) ([]byte, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	limited := io.LimitReader(resp.Body, 64<<20)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		return nil, errors.New("empty ruleset body")
	}
	return body, nil
}

func writeAtomic(path string, content []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, content, mode); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func updateRuleSetMetadata(dataDir string, entry RuleSetRuntimeMetadata) error {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return err
	}
	metaPath := filepath.Join(dataDir, "rule-set-metadata.json")
	existing := RuleSetMetadataFile{}
	if raw, err := os.ReadFile(metaPath); err == nil && len(raw) > 0 {
		_ = json.Unmarshal(raw, &existing)
	}
	byTag := map[string]RuleSetRuntimeMetadata{}
	for _, item := range existing.RuleSets {
		byTag[item.Tag] = item
	}
	byTag[entry.Tag] = entry
	list := make([]RuleSetRuntimeMetadata, 0, len(byTag))
	for _, item := range byTag {
		list = append(list, item)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Tag < list[j].Tag })
	out := RuleSetMetadataFile{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		RuleSets:    list,
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(metaPath, b, 0o644)
}

func ruleSetToOptionWithLocalOverride(source RuleSetSource, hopt *HiddifyOptions) option.RuleSet {
	if hopt != nil && hopt.ResolvedRuleSetPaths != nil {
		if p := hopt.ResolvedRuleSetPaths[source.Tag]; p != "" {
			return option.RuleSet{
				Type:   C.RuleSetTypeLocal,
				Tag:    source.Tag,
				Format: source.Format,
				LocalOptions: option.LocalRuleSet{
					Path: p,
				},
			}
		}
	}
	return toRemoteRuleSet(source)
}

func shortErr(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if len(s) > 180 {
		return s[:180]
	}
	return s
}
