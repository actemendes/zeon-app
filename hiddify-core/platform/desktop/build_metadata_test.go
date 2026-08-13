package main

import (
	"encoding/json"
	"runtime"
	"testing"
)

func TestDesktopBuildMetadata(t *testing.T) {
	var metadata desktopBuildMetadata
	if err := json.Unmarshal([]byte(desktopBuildMetadataJSON()), &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata.BuildRevision != buildRevision ||
		metadata.HiddifyCoreTree != hiddifyCoreTree ||
		metadata.HiddifySingBoxTree != hiddifySingBoxTree ||
		metadata.BuildTags != coreBuildTags ||
		metadata.UpstreamVersion != upstreamVersion ||
		metadata.UpstreamCommit != upstreamCommit ||
		metadata.Go != runtime.Version() {
		t.Fatalf("unexpected metadata: %+v", metadata)
	}
}
