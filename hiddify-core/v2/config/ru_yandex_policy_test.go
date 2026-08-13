package config

import "testing"

func TestRussiaYandexPolicyIsIndependent(t *testing.T) {
	assertRussiaServicePolicy(
		t,
		RUYandexRuleSetTag,
		OutboundDirectTag,
		DNSMultiDirectTag,
	)
}
