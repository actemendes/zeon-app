package mobile

import (
	"os"
	"testing"
)

func TestSetSessionGenerationUpdatesGoEnvironment(t *testing.T) {
	const key = "ZEON_SESSION_GENERATION"
	previous, existed := os.LookupEnv(key)
	t.Cleanup(func() {
		if existed {
			_ = os.Setenv(key, previous)
		} else {
			_ = os.Unsetenv(key)
		}
	})

	if err := SetSessionGeneration(42); err != nil {
		t.Fatalf("SetSessionGeneration returned error: %v", err)
	}
	if current := os.Getenv(key); current != "42" {
		t.Fatalf("%s = %q, want 42", key, current)
	}
}
