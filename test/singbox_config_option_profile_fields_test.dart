import "package:flutter_test/flutter_test.dart";
import "package:hiddify/core/model/optional_range.dart";
import "package:hiddify/features/log/model/log_level.dart";
import "package:hiddify/singbox/model/singbox_config_enum.dart";
import "package:hiddify/singbox/model/singbox_config_option.dart";

void main() {
  test("toCoreJson includes network profile and diagnostic fields", () {
    final option = SingboxConfigOption(
      region: "other",
      balancerStrategy: BalancerStrategy.roundRobin,
      blockAds: false,
      useXrayCoreWhenPossible: false,
      executeConfigAsIs: false,
      logLevel: LogLevel.warn,
      resolveDestination: false,
      ipv6Mode: IPv6Mode.enable,
      remoteDnsAddress: "tcp://8.8.8.8",
      remoteDnsDomainStrategy: DomainStrategy.auto,
      directDnsAddress: "udp://1.1.1.1",
      directDnsDomainStrategy: DomainStrategy.auto,
      mixedPort: 12334,
      tproxyPort: 12335,
      directPort: 12337,
      redirectPort: 12336,
      tunImplementation: TunImplementation.gvisor,
      mtu: 1500,
      strictRoute: true,
      networkProfile: "stable_mobile",
      networkMtuMode: "adaptive",
      fragmentMode: "off",
      profileDnsStrategy: "prefer_ipv4",
      connectionTestUrl: "http://captive.apple.com/hotspot-detect.html",
      urlTestInterval: const Duration(minutes: 10),
      enableClashApi: true,
      clashApiPort: 16756,
      enableTun: true,
      setSystemProxy: false,
      bypassLan: false,
      allowConnectionFromLan: false,
      enableFakeDns: false,
      independentDnsCache: true,
      siteRoutingMode: "off",
      siteRoutingInclude: const [],
      siteRoutingExclude: const [],
      rules: const [],
      tlsTricks: const SingboxTlsTricks(
        enableFragment: false,
        fragmentSize: OptionalRange(min: 10, max: 30),
        fragmentSleep: OptionalRange(min: 2, max: 8),
        mixedSniCase: true,
        enablePadding: false,
        paddingSize: OptionalRange(min: 1, max: 1500),
      ),
      warp: const SingboxWarpOption(
        enable: false,
        mode: WarpDetourMode.warpOverProxy,
        wireguardConfig: "",
        licenseKey: "",
        accountId: "",
        accessToken: "",
        cleanIp: "auto",
        cleanPort: 0,
        noise: OptionalRange(min: 1, max: 3),
        noiseSize: OptionalRange(min: 10, max: 30),
        noiseDelay: OptionalRange(min: 10, max: 30),
        noiseMode: "m4",
      ),
      warp2: const SingboxWarpOption(
        enable: false,
        mode: WarpDetourMode.warpOverProxy,
        wireguardConfig: "",
        licenseKey: "",
        accountId: "",
        accessToken: "",
        cleanIp: "auto",
        cleanPort: 0,
        noise: OptionalRange(min: 1, max: 3),
        noiseSize: OptionalRange(min: 10, max: 30),
        noiseDelay: OptionalRange(min: 10, max: 30),
        noiseMode: "m4",
      ),
    );

    final json = option.toCoreJson();
    expect(json["network-profile"], "stable_mobile");
    expect(json["network-mtu-mode"], "adaptive");
    expect(json["fragment-mode"], "off");
    expect(json["profile-dns-strategy"], "prefer_ipv4");
  });
}
