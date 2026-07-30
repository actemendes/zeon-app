package dialer

import "testing"

func TestShouldInstallDefaultInterfaceControl(t *testing.T) {
	tests := []struct {
		name                        string
		autoDetectInterface         bool
		usePlatformInterfaceControl bool
		disableDefaultBind          bool
		want                        bool
	}{
		{
			name:                        "android platform protect without desktop auto detect",
			usePlatformInterfaceControl: true,
			want:                        true,
		},
		{
			name:                "desktop auto detect",
			autoDetectInterface: true,
			want:                true,
		},
		{
			name: "no interface control",
			want: false,
		},
		{
			name:                        "explicit bind retains precedence",
			autoDetectInterface:         true,
			usePlatformInterfaceControl: true,
			disableDefaultBind:          true,
			want:                        false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := shouldInstallDefaultInterfaceControl(
				test.autoDetectInterface,
				test.usePlatformInterfaceControl,
				test.disableDefaultBind,
			)
			if got != test.want {
				t.Fatalf("shouldInstallDefaultInterfaceControl() = %v, want %v", got, test.want)
			}
		})
	}
}
