package config

import (
	"encoding/json"
	"github.com/sagernet/sing-box/option"
	"testing"
)

func TestPreferredSelectionAppliedAfterSyntheticGroupsAreBuilt(t *testing.T) {
	for _, tc := range []struct {
		name, preferred, want string
		prefer                bool
	}{
		{"baseline", "", "balance", false},
		{"offline Auto", "balance", "balance", true},
		{"offline manual", "two", "two", true},
		{"removed server", "removed", "balance", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			opts := DefaultHiddifyOptions()
			payload, _ := json.Marshal(map[string]string{"preferred-selector-outbound": tc.preferred})
			if err := json.Unmarshal(payload, opts); err != nil {
				t.Fatal(err)
			}
			built, err := BuildConfig(testConfigContext(), opts, &ReadOptions{Content: `{"outbounds":[{"type":"direct","tag":"one"},{"type":"direct","tag":"two"}]}`})
			if err != nil {
				t.Fatal(err)
			}
			for _, outbound := range built.Outbounds {
				if outbound.Tag != OutboundSelectTag {
					continue
				}
				selector := outbound.Options.(*option.SelectorOutboundOptions)
				if selector.Default != tc.want || selector.ZeonPreferDefault != tc.prefer {
					t.Fatalf("default=%s prefer=%v, want %s/%v", selector.Default, selector.ZeonPreferDefault, tc.want, tc.prefer)
				}
				return
			}
			t.Fatal("generated selector missing")
		})
	}
}
