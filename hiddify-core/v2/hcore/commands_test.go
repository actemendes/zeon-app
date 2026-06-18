package hcore

import (
	"testing"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
)

func TestDisplayCurrentOutboundBalanceChoosing(t *testing.T) {
	got := displayCurrentOutbound(config.OutboundRoundRobinTag, "")
	want := "Автовыбор серверов · выбирается сервер..."
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestDisplayCurrentOutboundBalanceRealLeaf(t *testing.T) {
	got := displayCurrentOutbound(config.OutboundRoundRobinTag, "Poland5")
	want := "Автовыбор серверов · Poland5"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestDisplayCurrentOutboundManualServer(t *testing.T) {
	got := displayCurrentOutbound("Germany12", "")
	if got != "Germany12" {
		t.Fatalf("expected manual server display, got %q", got)
	}
}

func TestDisplayCurrentOutboundBalanceLiveChecking(t *testing.T) {
	got := displayCurrentOutboundWithLive(config.OutboundRoundRobinTag, "Poland5", &adapter.URLTestHistory{
		LiveUsabilityStatus: monitoring.LiveUsabilityChecking,
	})
	want := "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u043e\u0432 \u00b7 Poland5 \u00b7 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430..."
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestDisplayCurrentOutboundBalanceLiveFailed(t *testing.T) {
	got := displayCurrentOutboundWithLive(config.OutboundRoundRobinTag, "Poland5", &adapter.URLTestHistory{
		LiveUsabilityStatus: monitoring.LiveUsabilityFailed,
	})
	want := "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u043e\u0432 \u00b7 Poland5 \u00b7 \u043d\u0435 \u0433\u0440\u0443\u0437\u0438\u0442, \u043f\u0435\u0440\u0435\u043a\u043b\u044e\u0447\u0430\u0435\u043c..."
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}
