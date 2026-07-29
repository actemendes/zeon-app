package mobile

import (
	"encoding/json"
	"runtime"
	"testing"
)

func TestGetBuildMetadata(t *testing.T) {
	var metadata struct {
		Schema                       int    `json:"schema"`
		ZeonRevision                 string `json:"zeon_revision"`
		HiddifyCoreTree              string `json:"hiddify_core_tree"`
		HiddifySingBoxTree           string `json:"hiddify_sing_box_tree"`
		UpstreamVersion              string `json:"upstream_version"`
		UpstreamCommit               string `json:"upstream_commit"`
		HiddifyCompatibilityRevision string `json:"hiddify_compatibility_revision"`
		ZeonPatchRevision            string `json:"zeon_patch_revision"`
		SourceDirty                  string `json:"source_dirty"`
		Go                           string `json:"go"`
		Gomobile                     string `json:"gomobile"`
		AndroidNDK                   string `json:"android_ndk"`
		BuildTags                    string `json:"build_tags"`
		BuildTimestampPolicy         string `json:"build_timestamp_policy"`
		BuildIDPolicy                string `json:"build_id_policy"`
	}
	if err := json.Unmarshal([]byte(GetBuildMetadata()), &metadata); err != nil {
		t.Fatalf("invalid build metadata: %v", err)
	}
	if metadata.Schema != 2 {
		t.Fatalf("unexpected schema: %d", metadata.Schema)
	}
	if metadata.ZeonRevision != buildRevision ||
		metadata.HiddifyCoreTree != hiddifyCoreTree ||
		metadata.HiddifySingBoxTree != hiddifySingBoxTree ||
		metadata.UpstreamVersion != upstreamVersion ||
		metadata.UpstreamCommit != upstreamCommit ||
		metadata.HiddifyCompatibilityRevision != hiddifyCompatibilityRevision ||
		metadata.ZeonPatchRevision != zeonPatchRevision ||
		metadata.SourceDirty != sourceDirty ||
		metadata.Gomobile != gomobileVersion ||
		metadata.AndroidNDK != androidNDKVersion ||
		metadata.BuildTags != coreBuildTags ||
		metadata.BuildTimestampPolicy != buildTimestampPolicy ||
		metadata.BuildIDPolicy != buildIDPolicy {
		t.Fatal("build metadata does not reflect embedded variables")
	}
	if metadata.Go != runtime.Version() {
		t.Fatalf("unexpected Go version: %s", metadata.Go)
	}
}
