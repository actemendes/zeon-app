package hcore

import "testing"

func TestChangeHiddifySettingsLegacyExecuteAlias(t *testing.T) {
	previous := static.HiddifyOptions
	defer func() {
		static.HiddifyOptions = previous
	}()

	_, err := ChangeHiddifySettings(&ChangeHiddifySettingsRequest{
		HiddifySettingsJson: `{"execute-config-as-is":true}`,
	}, false)
	if err != nil {
		t.Fatalf("ChangeHiddifySettings returned error: %v", err)
	}
	if static.HiddifyOptions == nil {
		t.Fatalf("hiddify options should be initialized")
	}
	if !static.HiddifyOptions.ExecuteConfigAsIs {
		t.Fatalf("legacy execute-config-as-is should be preserved")
	}
	if !static.HiddifyOptions.EnableFullConfig {
		t.Fatalf("legacy execute-config-as-is should enable full config")
	}
}

func TestChangeHiddifySettingsCanonicalEnableFullConfig(t *testing.T) {
	previous := static.HiddifyOptions
	defer func() {
		static.HiddifyOptions = previous
	}()

	_, err := ChangeHiddifySettings(&ChangeHiddifySettingsRequest{
		HiddifySettingsJson: `{"enable-full-config":true}`,
	}, false)
	if err != nil {
		t.Fatalf("ChangeHiddifySettings returned error: %v", err)
	}
	if static.HiddifyOptions == nil {
		t.Fatalf("hiddify options should be initialized")
	}
	if !static.HiddifyOptions.EnableFullConfig {
		t.Fatalf("enable-full-config should enable full config")
	}
	if !static.HiddifyOptions.ExecuteConfigAsIs {
		t.Fatalf("canonical key should be mirrored to legacy alias for compatibility")
	}
}
