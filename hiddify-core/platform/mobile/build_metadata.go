package mobile

import (
	"fmt"
	"runtime"
)

var (
	buildRevision                = "unknown"
	hiddifyCoreTree              = "unknown"
	hiddifySingBoxTree           = "unknown"
	coreBuildTags                = "unknown"
	upstreamVersion              = "unknown"
	upstreamCommit               = "unknown"
	hiddifyCompatibilityRevision = "unknown"
	zeonPatchRevision            = "unknown"
	sourceDirty                  = "unknown"
	gomobileVersion              = "unknown"
	androidNDKVersion            = "unknown"
	buildTimestampPolicy         = "unknown"
	buildIDPolicy                = "unknown"
)

// GetBuildMetadata exposes non-secret, reproducible provenance embedded in libhiddify-core.
func GetBuildMetadata() string {
	return fmt.Sprintf(
		`{"schema":2,"zeon_revision":%q,"hiddify_core_tree":%q,"hiddify_sing_box_tree":%q,"upstream_version":%q,"upstream_commit":%q,"hiddify_compatibility_revision":%q,"zeon_patch_revision":%q,"source_dirty":%q,"go":%q,"gomobile":%q,"android_ndk":%q,"build_tags":%q,"build_timestamp_policy":%q,"build_id_policy":%q}`,
		buildRevision,
		hiddifyCoreTree,
		hiddifySingBoxTree,
		upstreamVersion,
		upstreamCommit,
		hiddifyCompatibilityRevision,
		zeonPatchRevision,
		sourceDirty,
		runtime.Version(),
		gomobileVersion,
		androidNDKVersion,
		coreBuildTags,
		buildTimestampPolicy,
		buildIDPolicy,
	)
}
