package config

import (
	"strings"
	"testing"

	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
)

// The corpus deliberately uses documentation-only addresses and synthetic
// credentials. It is safe to commit and must never be replaced with exported
// user profiles.
func TestStage2AnonymizedConfigCorpus(t *testing.T) {
	const zeroKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	fixtures := []struct {
		name       string
		content    string
		checkBox   bool
		wantFinal  string
		outbounds  int
		endpoints  int
		mustRetain []string
	}{
		{"vless", `{"outbounds":[{"type":"vless","tag":"vless","server":"192.0.2.10","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"}],"route":{"final":"vless"}}`, true, "vless", 1, 0, []string{"00000000-0000-4000-8000-000000000001"}},
		{"vmess", `{"outbounds":[{"type":"vmess","tag":"vmess","server":"192.0.2.11","server_port":443,"uuid":"00000000-0000-4000-8000-000000000002","security":"auto"}],"route":{"final":"vmess"}}`, true, "vmess", 1, 0, []string{"00000000-0000-4000-8000-000000000002"}},
		{"trojan", `{"outbounds":[{"type":"trojan","tag":"trojan","server":"192.0.2.12","server_port":443,"password":"synthetic-trojan-secret"}],"route":{"final":"trojan"}}`, true, "trojan", 1, 0, []string{"synthetic-trojan-secret"}},
		{"shadowsocks", `{"outbounds":[{"type":"shadowsocks","tag":"ss","server":"192.0.2.13","server_port":8388,"method":"aes-128-gcm","password":"synthetic-ss-secret"}],"route":{"final":"ss"}}`, true, "ss", 1, 0, []string{"synthetic-ss-secret"}},
		{"hysteria2_quic", `{"outbounds":[{"type":"hysteria2","tag":"hy2","server":"192.0.2.14","server_port":443,"password":"synthetic-hy2-secret","tls":{"enabled":true,"server_name":"example.invalid","insecure":true}}],"route":{"final":"hy2"}}`, true, "hy2", 1, 0, []string{"synthetic-hy2-secret", "example.invalid"}},
		{"legacy_wireguard", `{"outbounds":[{"type":"wireguard","tag":"wg","server":"192.0.2.15","server_port":51820,"local_address":["10.0.0.2/32"],"private_key":"` + zeroKey + `","peer_public_key":"` + zeroKey + `","mtu":1400}],"route":{"final":"wg"}}`, true, "wg", 1, 0, []string{"10.0.0.2/32", "\"mtu\": 1400"}},
		{"amneziawg_endpoint", `{"endpoints":[{"type":"awg","tag":"awg","address":["10.0.0.3/32"],"private_key":"` + zeroKey + `","peers":[{"address":"192.0.2.16","port":51820,"public_key":"` + zeroKey + `","allowed_ips":["0.0.0.0/0"]}],"jc":4,"jmin":40,"jmax":70,"s1":10,"s2":20,"h1":"1"}],"route":{"final":"awg"}}`, false, "awg", 0, 1, []string{"\"jc\": 4", "0.0.0.0/0"}},
		{"groups", `{"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"},{"type":"selector","tag":"select","outbounds":["a","b"],"default":"a","interrupt_exist_connections":false},{"type":"urltest","tag":"urltest","outbounds":["a","b"],"url":"https://example.invalid/generate_204","interrupt_exist_connections":false},{"type":"balancer","tag":"round","outbounds":["a","b"],"strategy":"round-robin","interrupt_exist_connections":false},{"type":"balancer","tag":"smart","outbounds":["a","b"],"strategy":"smart-active-auto","interrupt_exist_connections":true,"smart_active_debug_force_status":""}],"route":{"final":"select"}}`, true, "select", 6, 0, []string{"round-robin", "smart-active-auto", "interrupt_exist_connections"}},
		{"routing_dns_dual_stack", `{"dns":{"servers":[{"type":"udp","tag":"remote","server":"192.0.2.53"}],"final":"remote","independent_cache":true},"outbounds":[{"type":"direct","tag":"proxy"},{"type":"direct","tag":"direct"}],"route":{"rules":[{"domain_suffix":["example.invalid"],"action":"route","outbound":"direct"},{"ip_cidr":["198.51.100.0/24"],"action":"route","outbound":"direct"}],"final":"proxy","auto_detect_interface":true}}`, true, "proxy", 2, 0, []string{"independent_cache", "198.51.100.0/24", "example.invalid"}},
	}

	ctx := testConfigContext()
	for _, fixture := range fixtures {
		t.Run(fixture.name, func(t *testing.T) {
			parsed, err := ParseConfig(ctx, &ReadOptions{Content: fixture.content}, false, DefaultHiddifyOptions(), true)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			if len(parsed.Outbounds) != fixture.outbounds || len(parsed.Endpoints) != fixture.endpoints {
				t.Fatalf("membership changed: outbounds=%d endpoints=%d", len(parsed.Outbounds), len(parsed.Endpoints))
			}
			if parsed.Route == nil || parsed.Route.Final != fixture.wantFinal {
				t.Fatalf("final=%v, want %q", parsed.Route, fixture.wantFinal)
			}
			encoded, err := parsed.MarshalJSONContext(ctx)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			for _, marker := range fixture.mustRetain {
				if !strings.Contains(string(encoded), marker) {
					t.Fatalf("semantic marker %q was lost: %s", marker, encoded)
				}
			}
			var roundTrip option.Options
			if err := roundTrip.UnmarshalJSONContext(ctx, encoded); err != nil {
				t.Fatalf("round-trip parse: %v", err)
			}
			if fixture.checkBox {
				if err := libbox.CheckConfigOptions(&roundTrip); err != nil {
					t.Fatalf("CheckConfig: %v", err)
				}
			}
		})
	}
}

func TestStage2BuilderPreservesGroupAndMTUPolicy(t *testing.T) {
	ctx := testConfigContext()
	input := &ReadOptions{Content: `{"outbounds":[{"type":"direct","tag":"one"},{"type":"direct","tag":"two"}]}`}
	for _, strategy := range []string{"round-robin", "smart-active-auto"} {
		t.Run(strategy, func(t *testing.T) {
			hopts := DefaultHiddifyOptions()
			hopts.BalancerStrategy = strategy
			hopts.EnableTun = true
			hopts.NetworkMtuMode = "dynamic"
			hopts.NetworkTransportType = "cellular"
			built, err := BuildConfig(ctx, hopts, input)
			if err != nil {
				t.Fatal(err)
			}
			var tunOptions *option.TunInboundOptions
			for _, inbound := range built.Inbounds {
				if candidate, ok := inbound.Options.(*option.TunInboundOptions); ok {
					tunOptions = candidate
					break
				}
			}
			if tunOptions == nil {
				t.Fatal("TUN inbound missing")
			}
			if got := tunOptions.MTU; got != 1380 {
				t.Fatalf("MTU policy changed: got %d want 1380", got)
			}
			var selector *option.SelectorOutboundOptions
			var balancer *option.BalancerOutboundOptions
			for _, outbound := range built.Outbounds {
				switch outbound.Tag {
				case OutboundSelectTag:
					selector = outbound.Options.(*option.SelectorOutboundOptions)
				case OutboundRoundRobinTag:
					balancer = outbound.Options.(*option.BalancerOutboundOptions)
				}
			}
			if selector == nil || balancer == nil {
				t.Fatal("selector or balancer missing")
			}
			if selector.InterruptExistConnections {
				t.Fatal("manual selector interruption policy widened")
			}
			if balancer.Strategy != strategy {
				t.Fatalf("strategy=%q want %q", balancer.Strategy, strategy)
			}
			wantCapability := strategy == "smart-active-auto"
			if balancer.InterruptExistConnections != wantCapability {
				t.Fatalf("emergency capability=%v want %v", balancer.InterruptExistConnections, wantCapability)
			}
		})
	}
}
