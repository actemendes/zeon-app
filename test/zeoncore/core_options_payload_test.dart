import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/core/model/optional_range.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/log/model/log_level.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart' as route_rule;
import 'package:zeon/zeoncore/zeon_core_service.dart';

final _testCoreServiceProvider = Provider<ZeonCoreService>(
  (ref) => ZeonCoreService(ref, coreInterface: CoreInterface()),
);

final _testWindowsCoreServiceProvider = Provider<ZeonCoreService>(
  (ref) => ZeonCoreService(ref, coreInterface: CoreInterface(), isWindows: true),
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
            domainSuffixes: const <String>['api.zeon-vps.online'],
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
    final profileRules = (payload['profile-rules'] as List).cast<Map<String, dynamic>>();

    expect(rules, hasLength(3));
    expect(rules.first['domain_suffixes'], const <String>['api.zeon-vps.online']);
    expect(rules.first['outbound'], RuleOutbound.proxy.toCoreValue());
    expect(rules[1]['name'], 'first explicit rule');
    expect(rules[2]['name'], 'second explicit rule');
    expect(rules.map((rule) => rule['list_order']), orderedEquals(<int>[0, 1, 2]));
    expect(profileRules, hasLength(1));
    expect(profileRules.single['domain_suffixes'], const <String>['global.example']);
    expect(profileRules.single['list_order'], 0);
    expect(
      rules.where((rule) {
        final values = rule['domain_suffixes'];
        return values is List && values.contains('api.zeon-vps.online');
      }),
      hasLength(1),
    );
    expect(payload['region'], 'other');
    expect(payload['network-profile'], 'stable_mobile');
  });

  test('Windows dynamic TUN uses the approved 1500 MTU when interface discovery is unavailable', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-core-options-windows-mtu-');
    addTearDown(() => directory.delete(recursive: true));
    final directories = (baseDir: directory, workingDir: directory, tempDir: directory);
    final container = ProviderContainer(
      overrides: [appDirectoriesProvider.overrideWith(() => _TestAppDirectories(directories))],
    );
    addTearDown(container.dispose);
    await container.read(appDirectoriesProvider.future);

    final payload = await container
        .read(_testWindowsCoreServiceProvider)
        .buildCoreOptionsPayloadForTesting(
          _configOptions(rules: const <SingboxRule>[], mtu: 1400, networkMtuMode: 'dynamic'),
        );

    expect(payload['network-mtu-mode'], 'dynamic');
    expect(payload['mtu'], 1400, reason: 'saved user/configured MTU remains untouched');
    expect(payload['network-transport-type'], 'unknown');
    expect(payload['network-interface-mtu'], 1500);
  });

  test('Windows per-app include and site exclude compile into core priority rules with direct fallback', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('zeon-core-options-windows-pc-routing-');
    addTearDown(() => directory.delete(recursive: true));
    final directories = (baseDir: directory, workingDir: directory, tempDir: directory);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((_) => prefs),
        appDirectoriesProvider.overrideWith(() => _TestAppDirectories(directories)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await container.read(appDirectoriesProvider.future);

    await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.include);
    await container.read(Preferences.includeApps.notifier).update(const <String>[
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    ]);

    final configured = MobileApiProxyRoute.enforce(
      _configOptions(
        rules: const <SingboxRule>[],
        siteRoutingMode: 'exclude',
        siteRoutingExclude: const <String>['gosuslugi.ru', '192.168.50.0/24'],
      ),
    );

    final payload = await container
        .read(_testWindowsCoreServiceProvider)
        .buildCoreOptionsPayloadForTesting(configured);
    final rules = (payload['rules'] as List).cast<Map<String, dynamic>>();

    // 0: control-plane rule (api.zeon-vps.online -> proxy)
    // 1: site-routing-exclude-domains (gosuslugi.ru -> direct)
    // 2: site-routing-exclude-ips (192.168.50.0/24 -> direct)
    // 3: pc-per-app-include-paths (chrome.exe path -> proxy)
    // 4: pc-per-app-include-names (chrome.exe name variants -> proxy)
    // 5: routing-include-fallback-direct (port_ranges 1:65535 -> direct)
    expect(rules.first['domain_suffixes'], const <String>['api.zeon-vps.online']);
    expect(rules[1]['name'], 'site-routing-exclude-domains');
    expect(rules[1]['outbound'], 1);
    expect(rules[1]['domain_suffixes'], const <String>['gosuslugi.ru']);
    expect(rules[2]['name'], 'site-routing-exclude-ips');
    expect(rules[2]['outbound'], 1);
    expect(rules[2]['ip_cidrs'], const <String>['192.168.50.0/24']);
    expect(rules[3]['name'], 'pc-per-app-include-paths');
    expect(rules[3]['outbound'], 0);
    expect(rules[3]['process_paths'], contains(r'C:\Program Files\Google\Chrome\Application\chrome.exe'));
    expect(rules[4]['name'], 'pc-per-app-include-names');
    expect(rules[4]['outbound'], 0);
    expect(rules[4]['process_names'], contains('chrome.exe'));
    expect(rules.last['name'], 'routing-include-fallback-direct');
    expect(rules.last['outbound'], 1);
    expect(rules.last['port_ranges'], const <String>['1:65535']);
  });
}

class _TestAppDirectories extends AppDirectories {
  _TestAppDirectories(this._directories);

  final Directories _directories;

  @override
  Future<Directories> build() async => _directories;
}

SingboxConfigOption _configOptions({
  required List<SingboxRule> rules,
  int mtu = 1500,
  String networkMtuMode = 'adaptive',
  String siteRoutingMode = 'off',
  List<String> siteRoutingInclude = const <String>[],
  List<String> siteRoutingExclude = const <String>[],
}) {
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
    mtu: mtu,
    strictRoute: true,
    networkProfile: 'stable_mobile',
    networkMtuMode: networkMtuMode,
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
    siteRoutingMode: siteRoutingMode,
    siteRoutingInclude: siteRoutingInclude,
    siteRoutingExclude: siteRoutingExclude,
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
