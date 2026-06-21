package hcore

import "testing"

func TestSmartActiveDiagnosticMessageDetection(t *testing.T) {
	for _, marker := range smartActiveDiagnosticMarkers {
		if !isSmartActiveDiagnosticMessage("prefix " + marker + " suffix") {
			t.Fatalf("marker %q was not detected", marker)
		}
	}
	if isSmartActiveDiagnosticMessage("[Unrelated] message") {
		t.Fatal("unrelated log message was detected as Smart Active diagnostic")
	}
}
