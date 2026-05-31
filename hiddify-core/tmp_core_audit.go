package main

import (
    "context"
    "encoding/json"
    "fmt"
    "os"

    cfg "github.com/hiddify/hiddify-core/v2/config"
)

func main() {
    profile := "../out/active_profile.json"
    opt := cfg.DefaultHiddifyOptions()
    opt.Region = "ru"
    opt.BalancerStrategy = "round-robin"
    opt.MTU = 1500
    opt.StrictRoute = true
    opt.TUNStack = "gvisor"
    opt.RemoteDnsAddress = "tcp://8.8.8.8"
    opt.BypassLAN = false

    built, err := cfg.BuildConfig(context.Background(), opt, &cfg.ReadOptions{Path: profile})
    if err != nil {
        panic(err)
    }
    b, err := built.MarshalJSONContext(context.Background())
    if err != nil {
        panic(err)
    }
    if err := os.WriteFile("../out/generated_current_core_from_profile.json", b, 0644); err != nil {
        panic(err)
    }

    var obj map[string]any
    if err := json.Unmarshal(b, &obj); err != nil {
        panic(err)
    }
    route, _ := obj["route"].(map[string]any)
    dns, _ := obj["dns"].(map[string]any)
    rules, _ := route["rules"].([]any)
    dnsRules, _ := dns["rules"].([]any)
    fmt.Printf("route.rules=%d dns.rules=%d\n", len(rules), len(dnsRules))
}