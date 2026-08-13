//go:build !zeon_route_validation

package zeonvalidation

import "testing"

func TestValidationTelemetryDisabledByDefault(t *testing.T) {
	if Enabled() {
		t.Fatal("validation telemetry must be disabled without zeon_route_validation")
	}
}
