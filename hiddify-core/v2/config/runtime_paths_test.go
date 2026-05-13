package config

import (
	"context"
	"path/filepath"
	"testing"
)

func TestPrepareRUCachedRuleSetUsesRuntimeDataDir(t *testing.T) {
	h := DefaultHiddifyOptions()
	h.RuntimeDataDir = filepath.Join(t.TempDir(), "runtime-data")

	source := buildCountryGeositeRuleSetSource("ru")

	orig := ensureRuleSetCachedFunc
	t.Cleanup(func() {
		ensureRuleSetCachedFunc = orig
	})

	called := false
	gotDir := ""
	ensureRuleSetCachedFunc = func(ctx context.Context, src RuleSetSource, dataDir string) (ResolvedRuleSet, RuleSetRuntimeMetadata, error) {
		called = true
		gotDir = dataDir
		return ResolvedRuleSet{
				Tag:       src.Tag,
				LocalPath: filepath.Join(dataDir, "rulesets", src.Tag+".srs"),
			},
			RuleSetRuntimeMetadata{Tag: src.Tag},
			nil
	}

	if err := prepareRUCachedRuleSet(context.Background(), h, source); err != nil {
		t.Fatalf("prepareRUCachedRuleSet failed: %v", err)
	}
	if !called {
		t.Fatal("expected ensureRuleSetCachedFunc to be called")
	}
	if gotDir != h.RuntimeDataDir {
		t.Fatalf("expected runtime data dir %q, got %q", h.RuntimeDataDir, gotDir)
	}
}
