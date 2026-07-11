package config

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

func diagnosticEnvEnabled(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on", "enabled":
		return true
	default:
		return false
	}
}

func configFingerprintEnabled() bool {
	return diagnosticEnvEnabled("ZEON_LOG_CONFIG_FINGERPRINT") || diagnosticEnvEnabled("ZEON_DIAGNOSTIC_CONFIG")
}

func shortConfigHash(value string) string {
	if value == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:12]
}

func logRuntimeConfigFingerprints(options *option.Options, app string) {
	if !configFingerprintEnabled() || options == nil {
		return
	}
	for _, outbound := range options.Outbounds {
		logOutboundConfigFingerprint(app, outbound)
	}
	for _, endpoint := range options.Endpoints {
		fmt.Printf("[OutboundConfigFingerprint] app=%s tag=%s protocol=%s endpoint=true\n", app, endpoint.Tag, endpoint.Type)
	}
	if options.Route != nil {
		fmt.Printf("[RuntimeConfigFingerprint] app=%s route_final=%s rules=%d auto_detect_interface=%v\n",
			app, options.Route.Final, len(options.Route.Rules), options.Route.AutoDetectInterface)
		if options.Route.DefaultDomainResolver != nil {
			fmt.Printf("[RuntimeConfigFingerprint] app=%s default_domain_resolver=%s strategy=%s\n",
				app, options.Route.DefaultDomainResolver.Server, options.Route.DefaultDomainResolver.Strategy)
		}
	}
	if options.DNS != nil {
		fmt.Printf("[RuntimeConfigFingerprint] app=%s dns_final=%s dns_servers=%d dns_rules=%d independent_cache=%v\n",
			app, options.DNS.Final, len(options.DNS.Servers), len(options.DNS.Rules), options.DNS.IndependentCache)
	}
	for _, inbound := range options.Inbounds {
		if inbound.Type == C.TypeTun {
			if tunOptions, ok := inbound.Options.(*option.TunInboundOptions); ok {
				fmt.Printf("[RuntimeConfigFingerprint] app=%s tun_tag=%s stack=%s mtu=%d auto_route=%v strict_route=%v addresses=%d\n",
					app, inbound.Tag, tunOptions.Stack, tunOptions.MTU, tunOptions.AutoRoute, tunOptions.StrictRoute, len(tunOptions.Address))
			}
		}
	}
}

func logRuntimeDiagnosticVariant(options *option.Options, hopt *HiddifyOptions) {
	if options == nil || hopt == nil {
		return
	}
	monitoring := (*option.MonitoringOptions)(nil)
	if options.Experimental != nil {
		monitoring = options.Experimental.Monitoring
	}
	if monitoring == nil {
		return
	}
	mtu := uint32(0)
	for _, inbound := range options.Inbounds {
		if inbound.Type != C.TypeTun {
			continue
		}
		if tunOptions, ok := inbound.Options.(*option.TunInboundOptions); ok {
			mtu = tunOptions.MTU
			break
		}
	}
	trafficHooks := !monitoring.DisableTrafficHooks
	udpProbe := monitoring.UDPProbeEnabled && strings.TrimSpace(monitoring.UDPProbeSecret) != ""
	forceIPv4 := C.DomainStrategy(hopt.IPv6Mode) == C.DomainStrategyIPv4Only
	fmt.Printf("[DiagnosticVariant] traffic_hooks=%v disable_traffic_hooks=%v udp_probe=%v force_ipv4=%v disable_quic=%v mtu=%v route_trace=%v source=runtime_config\n",
		trafficHooks,
		monitoring.DisableTrafficHooks,
		udpProbe,
		forceIPv4,
		hopt.BlockQuic,
		mtu,
		monitoring.TraceTrafficRoute,
	)
}

func logNetworkBaseline(options *option.Options, hopt *HiddifyOptions) {
	if options == nil || hopt == nil {
		return
	}
	platform := currentPlatformName()
	tunStack := ""
	mtu := uint32(0)
	for _, inbound := range options.Inbounds {
		if inbound.Type != C.TypeTun {
			continue
		}
		if tunOptions, ok := inbound.Options.(*option.TunInboundOptions); ok {
			tunStack = tunOptions.Stack
			mtu = tunOptions.MTU
			break
		}
	}
	interruptExisting := false
	for _, outbound := range options.Outbounds {
		switch opts := outbound.Options.(type) {
		case *option.SelectorOutboundOptions:
			interruptExisting = interruptExisting || opts.InterruptExistConnections
		case *option.BalancerOutboundOptions:
			interruptExisting = interruptExisting || opts.InterruptExistConnections
		}
	}
	fmt.Printf("[NetworkBaseline] source=hiddify_compatible platform=%s tun_stack=%s mtu=%d quic=%s udp=enabled ip_strategy=%s dns_route=proxy interrupt_exist_connections=%v\n",
		platform,
		tunStack,
		mtu,
		enabledText(!hopt.BlockQuic),
		hopt.RemoteDnsDomainStrategy.String(),
		interruptExisting,
	)
}

func enabledText(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
}

func logDNSRoutes(options *option.Options) {
	if options == nil || options.DNS == nil {
		return
	}
	for _, server := range options.DNS.Servers {
		if server.Tag != DNSRemoteTag && server.Tag != DNSBootstrapTag && server.Tag != DNSLocalTag {
			continue
		}
		detour, resolver, strategy := dnsServerRouteInfo(server)
		fmt.Printf("[DNSRoute] server=%s resolver=%s detour=%s strategy=%s\n",
			server.Tag,
			resolver,
			detour,
			strategy,
		)
	}
}

func dnsServerRouteInfo(server option.DNSServerOptions) (detour string, resolver string, strategy string) {
	readLocal := func(local option.RawLocalDNSServerOptions) (string, string, string) {
		resolver := ""
		strategy := local.DialerOptions.DomainStrategy.String()
		if local.DialerOptions.DomainResolver != nil {
			resolver = local.DialerOptions.DomainResolver.Server
			strategy = local.DialerOptions.DomainResolver.Strategy.String()
		}
		return local.DialerOptions.Detour, resolver, strategy
	}
	switch opts := server.Options.(type) {
	case *option.LocalDNSServerOptions:
		return readLocal(opts.RawLocalDNSServerOptions)
	case *option.RemoteDNSServerOptions:
		return readLocal(opts.RawLocalDNSServerOptions)
	case *option.RemoteTLSDNSServerOptions:
		return readLocal(opts.RawLocalDNSServerOptions)
	case *option.RemoteHTTPSDNSServerOptions:
		return readLocal(opts.RawLocalDNSServerOptions)
	default:
		return "", "", ""
	}
}

func logOutboundConfigFingerprint(app string, outbound option.Outbound) {
	if outbound.Type == C.TypeSelector {
		if opts, ok := outbound.Options.(*option.SelectorOutboundOptions); ok {
			fmt.Printf("[OutboundConfigFingerprint] app=%s tag=%s protocol=%s default=%s interrupt_exist_connections=%v outbounds=%d\n",
				app, outbound.Tag, outbound.Type, opts.Default, opts.InterruptExistConnections, len(opts.Outbounds))
		}
		return
	}
	if outbound.Type == C.TypeBalancer {
		if opts, ok := outbound.Options.(*option.BalancerOutboundOptions); ok {
			fmt.Printf("[OutboundConfigFingerprint] app=%s tag=%s protocol=%s strategy=%s interrupt_exist_connections=%v outbounds=%d\n",
				app, outbound.Tag, outbound.Type, opts.Strategy, opts.InterruptExistConnections, len(opts.Outbounds))
		}
		return
	}

	serverHash := ""
	serverPort := uint16(0)
	if serverOptions, ok := outbound.Options.(option.ServerOptionsWrapper); ok {
		server := serverOptions.TakeServerOptions()
		serverHash = shortConfigHash(server.Server)
		serverPort = server.ServerPort
	}

	tlsEnabled := false
	realityEnabled := false
	fingerprint := ""
	if tlsOptions, ok := outbound.Options.(option.OutboundTLSOptionsWrapper); ok {
		tls := tlsOptions.TakeOutboundTLSOptions()
		if tls != nil {
			tlsEnabled = tls.Enabled
			if tls.Reality != nil {
				realityEnabled = tls.Reality.Enabled
			}
			if tls.UTLS != nil {
				fingerprint = tls.UTLS.Fingerprint
			}
		}
	}

	transportType := ""
	flow := ""
	packetEncoding := ""
	multiplex := false
	switch opts := outbound.Options.(type) {
	case *option.VLESSOutboundOptions:
		flow = opts.Flow
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		if opts.PacketEncoding != nil {
			packetEncoding = *opts.PacketEncoding
		}
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	case option.VLESSOutboundOptions:
		flow = opts.Flow
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		if opts.PacketEncoding != nil {
			packetEncoding = *opts.PacketEncoding
		}
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	case *option.VMessOutboundOptions:
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		packetEncoding = opts.PacketEncoding
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	case option.VMessOutboundOptions:
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		packetEncoding = opts.PacketEncoding
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	case *option.TrojanOutboundOptions:
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	case option.TrojanOutboundOptions:
		if opts.Transport != nil {
			transportType = opts.Transport.Type
		}
		multiplex = opts.Multiplex != nil && opts.Multiplex.Enabled
	}

	fmt.Printf("[OutboundConfigFingerprint] app=%s tag=%s protocol=%s server_hash=%s port=%d transport=%s tls=%v reality=%v flow=%s udp_enabled=%v packet_encoding=%s multiplex=%v fingerprint=%s\n",
		app, outbound.Tag, outbound.Type, serverHash, serverPort, transportType, tlsEnabled, realityEnabled, flow, supportsUDP(outbound), packetEncoding, multiplex, fingerprint)
}

func supportsUDP(outbound option.Outbound) bool {
	switch opts := outbound.Options.(type) {
	case *option.VLESSOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	case option.VLESSOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	case *option.VMessOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	case option.VMessOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	case *option.TrojanOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	case option.TrojanOutboundOptions:
		return networkListSupportsUDP(opts.Network)
	default:
		return true
	}
}

func networkListSupportsUDP(network option.NetworkList) bool {
	for _, item := range network.Build() {
		if item == N.NetworkUDP {
			return true
		}
	}
	return false
}
