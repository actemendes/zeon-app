package mobile

import (
	"encoding/json"
	"runtime"
	"testing"
)

func TestGetBuildMetadata(t *testing.T) {
	var metadata struct {
		Schema             int    `json:"schema"`
		ZeonRevision       string `json:"zeon_revision"`
		HiddifyCoreTree    string `json:"hiddify_core_tree"`
		HiddifySingBoxTree string `json:"hiddify_sing_box_tree"`
		Go                 string `json:"go"`
		BuildTags          string `json:"build_tags"`
	}
	if err := json.Unmarshal([]byte(GetBuildMetadata()), &metadata); err != nil {
		t.Fatalf("invalid build metadata: %v", err)
	}
	if metadata.Schema != 1 {
		t.Fatalf("unexpected schema: %d", metadata.Schema)
	}
	if metadata.ZeonRevision != buildRevision ||
		metadata.HiddifyCoreTree != hiddifyCoreTree ||
		metadata.HiddifySingBoxTree != hiddifySingBoxTree ||
		metadata.BuildTags != coreBuildTags {
		t.Fatal("build metadata does not reflect embedded variables")
	}
	if metadata.Go != runtime.Version() {
		t.Fatalf("unexpected Go version: %s", metadata.Go)
	}
}
