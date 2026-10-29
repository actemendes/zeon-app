import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/per_app_proxy/data/desktop_routing_rule_compiler.dart';
import 'package:zeon/features/per_app_proxy/data/managed_application_routing.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/settings/overview/sections/route_options_page.dart';
import 'package:zeon/features/site_routing/model/site_routing_mode.dart';
import 'package:zeon/features/site_routing/overview/site_routing_page.dart';
import 'package:zeon/gen/translations_ru.g.dart';

void main() {
  group('WindowsInstalledAppsService', () {
    test('parses Uninstall registry output, App Paths, running processes, and filters system/noise apps', () async {
      const fakeUninstallReg = r'''
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome
    DisplayName    REG_SZ    Google Chrome
    DisplayIcon    REG_SZ    "C:\Program Files\Google\Chrome\Application\chrome.exe",0
    DisplayVersion    REG_SZ    130.0.6723.70

HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam
    DisplayName    REG_SZ    Steam
    InstallLocation    REG_SZ    C:\Program Files (x86)\Steam

HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VCRedist
    DisplayName    REG_SZ    Microsoft Visual C++ 2022 Redistributable
    DisplayIcon    REG_SZ    C:\Windows\System32\msiexec.exe
    SystemComponent    REG_DWORD    0x1

HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ZEON
    DisplayName    REG_SZ    ZEON
    DisplayIcon    REG_SZ    "C:\Program Files\ZEON\ZEON.exe",0
''';

      const fakeAppPathsReg = r'''
HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Telegram.exe
    (Default)    REG_SZ    "C:\Users\Test\AppData\Roaming\Telegram Desktop\Telegram.exe"
''';

      final existingFiles = <String>{
        r'c:\program files\google\chrome\application\chrome.exe',
        r'c:\program files (x86)\steam\steam.exe',
        r'c:\program files (x86)\steam\uninstall.exe',
        r'c:\users\test\appdata\roaming\telegram desktop\telegram.exe',
        r'c:\games\portablegame\gameclient.exe',
        r'c:\windows\system32\svchost.exe',
        r'c:\program files\zeon\zeon.exe',
      };

      final service = WindowsInstalledAppsService(
        environment: const <String, String>{},
        fileExists: (path) => existingFiles.contains(path.toLowerCase()),
        exeFinder: (dirPath, {int maxDepth = 2}) {
          if (dirPath.toLowerCase() == r'c:\program files (x86)\steam') {
            return const <String>[
              r'C:\Program Files (x86)\Steam\uninstall.exe',
              r'C:\Program Files (x86)\Steam\steam.exe',
            ];
          }
          return const <String>[];
        },
        registryReader: (args) async {
          final key = args[1];
          if (key.contains('Uninstall')) return fakeUninstallReg;
          if (key.contains('App Paths')) return fakeAppPathsReg;
          return '';
        },
        runningProcessPathsReader: () async => const <String>[
          r'C:\Games\PortableGame\GameClient.exe',
          r'C:\Windows\System32\svchost.exe',
          r'C:\Program Files\ZEON\ZEON.exe',
        ],
      );

      final userApps = await service.getInstalledApps(
        customPaths: const <String>[r'D:\CustomTools\MyProxyTool.exe'],
      );

      final names = userApps.map((e) => e.name).toList();
      final paths = userApps.map((e) => e.packageName).toList();

      expect(names, containsAll(<String>['Google Chrome', 'Steam', 'Telegram Desktop', 'GameClient', 'MyProxyTool']));
      expect(paths, contains(r'C:\Program Files\Google\Chrome\Application\chrome.exe'));
      expect(paths, contains(r'C:\Program Files (x86)\Steam\steam.exe'));
      expect(paths, contains(r'C:\Users\Test\AppData\Roaming\Telegram Desktop\Telegram.exe'));
      expect(paths, contains(r'C:\Games\PortableGame\GameClient.exe'));
      expect(paths, contains(r'D:\CustomTools\MyProxyTool.exe'));
      // ZEON itself, uninstallers, and Windows system processes must be excluded when hideSystem is true.
      expect(paths.any((p) => p.toLowerCase().contains('zeon.exe')), isFalse);
      expect(paths.any((p) => p.toLowerCase().contains('uninstall.exe')), isFalse);
      expect(paths.any((p) => p.toLowerCase().contains('svchost.exe')), isFalse);

      // When hideSystem is false, system processes like svchost.exe are included.
      final allApps = await service.getInstalledApps(hideSystem: false);
      expect(allApps.any((a) => a.packageName.toLowerCase().contains('svchost.exe')), isTrue);
    });

    test('friendlyProgramName resolves known browsers, Squirrel app-* folders, and Yandex Browser', () {
      expect(
        WindowsInstalledAppsService.friendlyProgramName(
          r'C:\Users\User\AppData\Local\Yandex\YandexBrowser\Application\browser.exe',
        ),
        'Yandex Browser',
      );
      expect(
        WindowsInstalledAppsService.friendlyProgramName(
          r'C:\Users\User\AppData\Local\Discord\app-1.0.9015\Discord.exe',
        ),
        'Discord',
      );
      expect(
        WindowsInstalledAppsService.friendlyProgramName(
          r'C:\Users\User\AppData\Local\CustomApp\app-2.1.0\launcher.exe',
        ),
        'CustomApp',
      );
    });
  });

  group('DesktopRoutingRuleCompiler', () {
    test('emits separate process_paths and process_names rules with companion executables', () {
      final compiler = DesktopRoutingRuleCompiler(
        companionFinder: (exePath) {
          if (exePath.toLowerCase().endsWith('steam.exe')) {
            return const <String>[
              r'C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe',
              r'C:\Program Files (x86)\Steam\uninstall.exe',
            ];
          }
          return const <String>[];
        },
      );

      final overlay = compiler.compileOverlay(
        isDesktop: true,
        perAppProxyMode: PerAppProxyMode.exclude,
        includeApps: const <String>[],
        excludeApps: const <String>[r'C:\Program Files (x86)\Steam\steam.exe'],
        siteRoutingMode: SiteRoutingMode.off,
        includeSites: const <String>[],
        excludeSites: const <String>[],
      );

      expect(overlay.trailingRules, isEmpty);
      expect(overlay.leadingRules, hasLength(2));

      final pathRule = overlay.leadingRules[0];
      final nameRule = overlay.leadingRules[1];

      expect(pathRule['name'], 'pc-per-app-exclude-paths');
      expect(pathRule['outbound'], 1);
      expect(pathRule.containsKey('process_names'), isFalse);
      expect(
        pathRule['process_paths'],
        const <String>[
          r'C:\Program Files (x86)\Steam\steam.exe',
          r'C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe',
        ],
      );

      expect(nameRule['name'], 'pc-per-app-exclude-names');
      expect(nameRule['outbound'], 1);
      expect(nameRule.containsKey('process_paths'), isFalse);
      expect(nameRule['process_names'], containsAll(<String>['steam.exe', 'Steam.exe', 'steamwebhelper.exe']));
    });

    test('include mode adds catch-all direct fallback rule so unselected PC apps bypass VPN', () {
      const compiler = DesktopRoutingRuleCompiler(companionFinder: _noCompanions);
      final overlay = compiler.compileOverlay(
        isDesktop: true,
        perAppProxyMode: PerAppProxyMode.include,
        includeApps: const <String>[r'C:\Users\User\AppData\Local\Discord\app-1.0.9015\Discord.exe'],
        excludeApps: const <String>[],
        siteRoutingMode: SiteRoutingMode.off,
        includeSites: const <String>[],
        excludeSites: const <String>[],
      );

      expect(overlay.leadingRules, hasLength(2));
      expect(overlay.leadingRules[0]['outbound'], 0);
      expect(overlay.leadingRules[1]['outbound'], 0);
      expect(overlay.trailingRules, hasLength(1));
      expect(overlay.trailingRules.single['name'], 'routing-include-fallback-direct');
      expect(overlay.trailingRules.single['outbound'], 1);
      expect(overlay.trailingRules.single['port_ranges'], const <String>['1:65535']);
    });

    test('site routing normalizes URLs, domains, suffixes, IPs, and CIDRs into separate domain and IP rules', () {
      expect(SiteRoutingPage.normalizeEntry('https://Store.Steampowered.com/app/10/'), 'store.steampowered.com');
      expect(SiteRoutingPage.normalizeEntry('*.YouTube.com.'), '*.youtube.com');
      expect(SiteRoutingPage.normalizeEntry('192.168.10.0/24'), '192.168.10.0/24');
      expect(SiteRoutingPage.normalizeEntry('8.8.8.8'), '8.8.8.8');
      expect(SiteRoutingPage.normalizeEntry('192.168.10.0/99'), isNull);
      expect(SiteRoutingPage.normalizeEntry('not a domain'), isNull);

      const compiler = DesktopRoutingRuleCompiler(companionFinder: _noCompanions);
      final rules = compiler.compileSiteRules(
        rawEntries: const <String>['https://youtube.com/watch', '*.googlevideo.com', '8.8.8.8', '10.0.0.0/8'],
        outbound: 0,
        ruleNamePrefix: 'site-routing-include',
      );

      expect(rules, hasLength(2));
      expect(rules[0]['name'], 'site-routing-include-domains');
      expect(rules[0]['domains'], const <String>['youtube.com', 'googlevideo.com']);
      expect(rules[0]['domain_suffixes'], const <String>['youtube.com', 'googlevideo.com']);
      expect(rules[1]['name'], 'site-routing-include-ips');
      expect(rules[1]['ip_cidrs'], const <String>['8.8.8.8', '10.0.0.0/8']);
    });
  });

  group('ManagedApplicationRuleCompiler for Windows', () {
    test('compiles Windows managed applications into process_names and process_paths rules', () {
      final config = ManagedApplicationConfig(
        formatVersion: 1,
        version: 3,
        updatedAt: DateTime.utc(2026, 8, 25),
        applications: const <ManagedApplication>[
          ManagedApplication(
            id: 'win-direct-name',
            platform: ManagedApplicationPlatform.windows,
            stableIdentifier: 'yandex.exe',
            displayName: 'Yandex',
            route: ManagedApplicationRoute.direct,
            enabled: true,
            sortOrder: 1,
          ),
          ManagedApplication(
            id: 'win-vpn-path',
            platform: ManagedApplicationPlatform.windows,
            stableIdentifier: r'C:\App\Discord.exe',
            displayName: 'Discord',
            route: ManagedApplicationRoute.vpn,
            enabled: true,
            sortOrder: 2,
          ),
        ],
      );

      final rules = const ManagedApplicationRuleCompiler().compile(
        config,
        platform: ManagedApplicationPlatform.windows,
      );

      expect(rules, hasLength(3));
      expect(rules[0]['name'], 'managed applications DIRECT v3');
      expect(rules[0]['outbound'], 1);
      expect(rules[0]['process_names'], const <String>['yandex.exe']);

      expect(rules[1]['name'], 'managed applications VPN paths v3');
      expect(rules[1]['outbound'], 0);
      expect(rules[1]['process_paths'], const <String>[r'C:\App\Discord.exe']);

      expect(rules[2]['name'], 'managed applications VPN v3');
      expect(rules[2]['outbound'], 0);
      expect(rules[2]['process_names'], const <String>['Discord.exe']);
    });
  });

  group('Desktop Routing UI', () {
    testWidgets('RouteOptionsPage exposes Applications, Websites, and Route Rules on PC', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final t = TranslationsRu();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) => prefs),
          translationsProvider.overrideWith((_) => t),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      await container.read(translationsProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('ru'),
            supportedLocales: [Locale('ru')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: RouteOptionsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(t.pages.settings.routing.perAppProxy.title), findsOneWidget);
      expect(find.text(t.pages.settings.routing.websites.title), findsOneWidget);
      expect(find.text(t.pages.settings.routing.routeRule.title), findsOneWidget);
    });

    testWidgets('SiteRoutingPage renders configured domains and IP CIDRs and allows deletion', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final t = TranslationsRu();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) => prefs),
          translationsProvider.overrideWith((_) => t),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      await container.read(translationsProvider.future);

      await container.read(Preferences.siteRoutingMode.notifier).update(SiteRoutingMode.exclude);
      await container.read(Preferences.excludeSites.notifier).update(const <String>[
        'store.steampowered.com',
        '192.168.1.0/24',
      ]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('ru'),
            supportedLocales: [Locale('ru')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: SiteRoutingPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('store.steampowered.com'), findsOneWidget);
      expect(find.text('192.168.1.0/24'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.remove_circle_outline_rounded).first);
      await tester.pumpAndSettle();

      expect(container.read(Preferences.excludeSites), const <String>['192.168.1.0/24']);
    });
  });
}

List<String> _noCompanions(String _) => const <String>[];
