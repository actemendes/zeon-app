package config

import "testing"

func TestRussiaWildberriesPolicyIsIndependent(t *testing.T) {
	assertRussiaServicePolicy(
		t,
		RUWildberriesRuleSetTag,
		OutboundMainDetour,
		DNSMultiRemoteTag,
	)
}
