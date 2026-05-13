package config

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestEnsureRuleSetCachedPrimarySuccess(t *testing.T) {
	dir := t.TempDir()
	srv := newRuleSetTestServer(t, map[string]ruleSetResponse{
		"/primary.srs": {status: 200, body: []byte("abc-primary")},
	})
	src := RuleSetSource{
		Tag:            "geosite-ru",
		PrimaryURL:     srv.URL + "/primary.srs",
		Format:         C.RuleSetFormatBinary,
		DownloadDetour: OutboundSelectTag,
	}
	resolved, meta, err := EnsureRuleSetCached(context.Background(), src, dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolved.UsedCache || meta.UsedCache {
		t.Fatal("did not expect cache usage")
	}
	if resolved.FallbackUsed || meta.FallbackUsed {
		t.Fatal("did not expect fallback usage")
	}
	if resolved.ActiveURL != src.PrimaryURL {
		t.Fatalf("unexpected active url: %s", resolved.ActiveURL)
	}
	if meta.LastHash == "" {
		t.Fatal("expected hash")
	}
	if _, err := os.Stat(resolved.LocalPath); err != nil {
		t.Fatalf("expected local file: %v", err)
	}
}

func TestEnsureRuleSetCachedPrimaryFailFallbackSuccess(t *testing.T) {
	dir := t.TempDir()
	srv := newRuleSetTestServer(t, map[string]ruleSetResponse{
		"/fallback.srs": {status: 200, body: []byte("abc-fallback")},
	})
	src := RuleSetSource{
		Tag:            "geoip-ru",
		PrimaryURL:     srv.URL + "/missing.srs",
		FallbackURLs:   []string{srv.URL + "/fallback.srs"},
		Format:         C.RuleSetFormatBinary,
		DownloadDetour: OutboundSelectTag,
	}
	resolved, meta, err := EnsureRuleSetCached(context.Background(), src, dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resolved.FallbackUsed || !meta.FallbackUsed {
		t.Fatal("expected fallback used")
	}
	if resolved.ActiveURL != srv.URL+"/fallback.srs" {
		t.Fatalf("unexpected active url: %s", resolved.ActiveURL)
	}
}

func TestEnsureRuleSetCachedFailUseExistingCache(t *testing.T) {
	dir := t.TempDir()
	cachePath := filepath.Join(dir, "rulesets", "geosite-ru.srs")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cachePath, []byte("old-cache"), 0o644); err != nil {
		t.Fatal(err)
	}
	src := RuleSetSource{
		Tag:            "geosite-ru",
		PrimaryURL:     "http://127.0.0.1:1/unreachable",
		Format:         C.RuleSetFormatBinary,
		DownloadDetour: OutboundSelectTag,
	}
	resolved, meta, err := EnsureRuleSetCached(context.Background(), src, dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resolved.UsedCache || !meta.UsedCache {
		t.Fatal("expected used_cache=true")
	}
	if meta.LastError == "" {
		t.Fatal("expected last_error")
	}
}

func TestEnsureRuleSetCachedFailNoCache(t *testing.T) {
	dir := t.TempDir()
	src := RuleSetSource{
		Tag:            "geosite-ru",
		PrimaryURL:     "http://127.0.0.1:1/unreachable",
		Format:         C.RuleSetFormatBinary,
		DownloadDetour: OutboundSelectTag,
	}
	_, meta, err := EnsureRuleSetCached(context.Background(), src, dir)
	if err == nil {
		t.Fatal("expected error")
	}
	if meta.LastError == "" {
		t.Fatal("expected last_error")
	}
}

func TestEnsureRuleSetCachedEmptyResponseDoesNotOverwrite(t *testing.T) {
	dir := t.TempDir()
	cachePath := filepath.Join(dir, "rulesets", "geoip-ru.srs")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cachePath, []byte("old-cache"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv := newRuleSetTestServer(t, map[string]ruleSetResponse{
		"/empty.srs": {status: 200, body: []byte{}},
	})
	src := RuleSetSource{
		Tag:            "geoip-ru",
		PrimaryURL:     srv.URL + "/empty.srs",
		Format:         C.RuleSetFormatBinary,
		DownloadDetour: OutboundSelectTag,
	}
	_, _, err := EnsureRuleSetCached(context.Background(), src, dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	b, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "old-cache" {
		t.Fatal("expected previous cache content unchanged")
	}
}

func TestGeoSiteRUFallbackDoesNotUseDB(t *testing.T) {
	src := buildCountryGeositeRuleSetSource("ru")
	for _, f := range src.FallbackURLs {
		if strings.HasSuffix(strings.ToLower(f), ".db") {
			t.Fatalf("unexpected .db fallback: %s", f)
		}
	}
}

func TestGeoIPRUFallbackContainsSRS(t *testing.T) {
	src := buildCountryGeoIPRuleSetSource("ru")
	found := false
	for _, f := range src.FallbackURLs {
		if strings.HasSuffix(strings.ToLower(f), ".srs") {
			found = true
		}
	}
	if !found {
		t.Fatal("expected .srs fallback candidate for geoip-ru")
	}
}

func TestRuleSetToOptionWithLocalOverrideAndRemoteFallback(t *testing.T) {
	src := buildCountryGeositeRuleSetSource("ru")
	hopt := DefaultHiddifyOptions()
	hopt.ResolvedRuleSetPaths = map[string]string{src.Tag: "data/rulesets/geosite-ru.srs"}
	local := ruleSetToOptionWithLocalOverride(src, hopt)
	if local.Type != C.RuleSetTypeLocal || local.LocalOptions.Path == "" {
		t.Fatal("expected local ruleset option")
	}
	hopt.ResolvedRuleSetPaths = map[string]string{}
	remote := ruleSetToOptionWithLocalOverride(src, hopt)
	if remote.Type != C.RuleSetTypeRemote || remote.RemoteOptions.URL == "" {
		t.Fatal("expected remote fallback option")
	}
}

type ruleSetResponse struct {
	status int
	body   []byte
}

func newRuleSetTestServer(t *testing.T, routes map[string]ruleSetResponse) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	for path, response := range routes {
		resp := response
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(resp.status)
			if len(resp.body) > 0 {
				_, _ = w.Write(resp.body)
			}
		})
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(func() { srv.Close() })
	return srv
}

// compile guard for option usage path in tests.
var _ = option.RuleSet{}
