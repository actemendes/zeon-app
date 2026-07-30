package config

import "testing"

func TestRussiaWildberriesPolicyIsIndependent(t *testing.T) {
	assertRussiaServicePolicy(
		t,
		RUWildberriesRuleSetTag,
		OutboundDirectTag,
		DNSMultiDirectTag,
	)
}
