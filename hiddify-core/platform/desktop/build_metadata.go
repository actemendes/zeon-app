package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"runtime"
)

var (
	buildRevision        = "unknown"
	hiddifyCoreTree      = "unknown"
	hiddifySingBoxTree   = "unknown"
	coreBuildTags        = "unknown"
	upstreamVersion      = "unknown"
	upstreamCommit       = "unknown"
	sourceDirty          = "unknown"
	buildTimestampPolicy = "unknown"
	buildIDPolicy        = "unknown"
)

type desktopBuildMetadata struct {
	BuildRevision        string `json:"build_revision"`
	HiddifyCoreTree      string `json:"hiddify_core_tree"`
	HiddifySingBoxTree   string `json:"hiddify_sing_box_tree"`
	BuildTags            string `json:"build_tags"`
	UpstreamVersion      string `json:"upstream_version"`
	UpstreamCommit       string `json:"upstream_commit"`
	Go                   string `json:"go"`
	SourceDirty          string `json:"source_dirty"`
	BuildTimestampPolicy string `json:"build_timestamp_policy"`
	BuildIDPolicy        string `json:"build_id_policy"`
}

func desktopBuildMetadataJSON() string {
	encoded, err := json.Marshal(desktopBuildMetadata{
		BuildRevision:        buildRevision,
		HiddifyCoreTree:      hiddifyCoreTree,
		HiddifySingBoxTree:   hiddifySingBoxTree,
		BuildTags:            coreBuildTags,
		UpstreamVersion:      upstreamVersion,
		UpstreamCommit:       upstreamCommit,
		Go:                   runtime.Version(),
		SourceDirty:          sourceDirty,
		BuildTimestampPolicy: buildTimestampPolicy,
		BuildIDPolicy:        buildIDPolicy,
	})
	if err != nil {
		return `{"error":"metadata_encoding_failed"}`
	}
	return string(encoded)
}

//export getBuildMetadata
func getBuildMetadata() *C.char {
	return C.CString(desktopBuildMetadataJSON())
}
