import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/core/model/optional_range.dart';
import 'package:zeon/features/log/model/log_level.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart' as route_rule;
import 'package:zeon/zeoncore/zeon_core_service.dart';

final _testCoreServiceProvider = Provider<ZeonCoreService>(
  (ref) => ZeonCoreService(ref, coreInterface: CoreInterface()),
);

void main() {
  test('final payload keeps control-plane first and appends explicit user rules without duplicates', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-core-options-');
    addTearDown(() => directory.delete(recursive: true));
    final directories = (baseDir: directory, workingDir: directory, tempDir: directory);
    final routeRuleFile = File('${directory.path}${Platform.pathSeparator}route_rule.proto');
    await routeRuleFile.writeAsBytes(
      route_rule.RouteRule(
        rules: <route_rule.Rule>[
          route_rule.Rule(
            listOrder: 20,
            enabled: true,
            name: 'duplicate control-plane rule',
            outbound: route_rule.Outbound.proxy,
            ipCidrs: const <String>['130.49.151.173/32'],
          ),
          route_rule.Rule(
            listOrder: 10,
            enabled: true,
            name: 'second explicit rule',
            outbound: route_rule.Outbound.direct,
            domainSuffixes: const <String>['second.ru'],
          ),
          route_rule.Rule(
            listOrder: 5,
            enabled: true,
            name: 'first explicit rule',
            outbound: route_rule.Outbound.direct,
            domainSuffixes: const <String>['first.ru'],
          ),
        ],
      ).writeToBuffer(),
    );

    final container = ProviderContainer(
      overrides: [appDirectoriesProvider.overrideWith(() => _TestAppDirectories(directories))],
    );
    addTearDown(container.dispose);
    await container.read(appDirectoriesProvider.future);

    final configured = MobileApiProxyRoute.enforce(
      _configOptions(
        rules: const <SingboxRule>[
          SingboxRule(domains: <String>['global.example']),
        ],
      ),
    );
    final payload = await container.read(_testCoreServiceProvider).buildCoreOptionsPayloadForTesting(configured);
    final rules = (payload['rules'] as List).cast<Map<String, dynamic>>();

    expect(rules, hasLength(4));
    expect(rules.first['ip_cidrs'], const <String>['130.49.151.173/32']);
    expect(rules.first['outbound'], RuleOutbound.proxy.toCoreValue());
    expect(rules[1]['name'], 'first explicit rule');
    expect(rules[2]['name'], 'second explicit rule');
    expect(rules[3]['domain_suffixes'], const <String>['global.example']);
    expect(
      rules.where((rule) {
        final values = rule['ip_cidrs'];
        return values is List && values.contains('130.49.151.173/32');
      }),
      hasLength(1),
    );
    expect(payload['region'], 'other');
    expect(payload['network-profile'], 'stable_mobile');
  });
}

class _TestAppDirectories extends AppDirectories {
  _TestAppDirectories(this._directories);

  final Directories _directories;

  @override
  Future<Directories> build() async => _directories;
}

SingboxConfigOption _configOptions({required List<SingboxRule> rules}) {
  return SingboxConfigOption(
    region: 'other',
    balancerStrategy: BalancerStrategy.roundRobin,
    blockAds: false,
    useXrayCoreWhenPossible: false,
    executeConfigAsIs: false,
    logLevel: LogLevel.warn,
    resolveDestination: false,
    ipv6Mode: IPv6Mode.enable,
    remoteDnsAddress: 'tcp://8.8.8.8',
    remoteDnsDomainStrategy: DomainStrategy.auto,
    directDnsAddress: 'udp://1.1.1.1',
    directDnsDomainStrategy: DomainStrategy.auto,
    mixedPort: 12334,
    tproxyPort: 12335,
    directPort: 12337,
    redirectPort: 12336,
    tunImplementation: TunImplementation.gvisor,
    mtu: 1500,
    strictRoute: true,
    networkProfile: 'stable_mobile',
    networkMtuMode: 'adaptive',
    fragmentMode: 'off',
    profileDnsStrategy: 'prefer_ipv4',
    connectionTestUrl: 'http://captive.apple.com/hotspot-detect.html',
    urlTestInterval: const Duration(minutes: 10),
    enableClashApi: true,
    clashApiPort: 16756,
    enableTun: true,
    setSystemProxy: false,
    bypassLan: false,
    allowConnectionFromLan: false,
    enableFakeDns: false,
    independentDnsCache: true,
    siteRoutingMode: 'off',
    siteRoutingInclude: const <String>[],
    siteRoutingExclude: const <String>[],
    rules: rules,
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
      wireguardConfig: '',
      licenseKey: '',
      accountId: '',
      accessToken: '',
      cleanIp: 'auto',
      cleanPort: 0,
      noise: OptionalRange(min: 1, max: 3),
      noiseSize: OptionalRange(min: 10, max: 30),
      noiseDelay: OptionalRange(min: 10, max: 30),
      noiseMode: 'm4',
    ),
    warp2: const SingboxWarpOption(
      enable: false,
      mode: WarpDetourMode.warpOverProxy,
      wireguardConfig: '',
      licenseKey: '',
      accountId: '',
      accessToken: '',
      cleanIp: 'auto',
      cleanPort: 0,
      noise: OptionalRange(min: 1, max: 3),
      noiseSize: OptionalRange(min: 10, max: 30),
      noiseDelay: OptionalRange(min: 10, max: 30),
      noiseMode: 'm4',
    ),
  );
}
