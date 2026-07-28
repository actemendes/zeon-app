package mobile

import (
	"fmt"
	"runtime"
)

var (
	buildRevision      = "unknown"
	hiddifyCoreTree    = "unknown"
	hiddifySingBoxTree = "unknown"
	coreBuildTags      = "unknown"
)

// GetBuildMetadata exposes non-secret, reproducible provenance embedded in libhiddify-core.
func GetBuildMetadata() string {
	return fmt.Sprintf(
		`{"schema":1,"zeon_revision":%q,"hiddify_core_tree":%q,"hiddify_sing_box_tree":%q,"go":%q,"build_tags":%q}`,
		buildRevision,
		hiddifyCoreTree,
		hiddifySingBoxTree,
		runtime.Version(),
		coreBuildTags,
	)
}
