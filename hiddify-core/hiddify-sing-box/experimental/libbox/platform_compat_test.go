package libbox

import "testing"

func TestConnectionOwnerStage1PackageCompatibility(t *testing.T) {
	owner := &ConnectionOwner{AndroidPackageName: "app.synthetic"}
	names := iteratorToArray[string](owner.AndroidPackageNames())
	if len(names) != 1 || names[0] != owner.AndroidPackageName {
		t.Fatalf("legacy package was not exposed through the new iterator: %v", names)
	}

	owner.SetAndroidPackageNames(newIterator([]string{"app.first", "app.second"}))
	if owner.AndroidPackageName != "app.first" {
		t.Fatalf("legacy package was not synchronized: %q", owner.AndroidPackageName)
	}
	if names = owner.effectiveAndroidPackageNames(); len(names) != 2 {
		t.Fatalf("shared UID package list was lost: %v", names)
	}
}

func TestProcessInfoStage1PackageCompatibility(t *testing.T) {
	process := &ProcessInfo{PackageName: "app.synthetic"}
	names := iteratorToArray[string](process.PackageNames())
	if len(names) != 1 || names[0] != process.PackageName {
		t.Fatalf("legacy process package was not exposed: %v", names)
	}
}
