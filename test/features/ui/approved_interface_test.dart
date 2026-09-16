import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Unit;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/app_info_entity.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/bottom_sheets/widgets/quick_settings_modal.dart';
import 'package:zeon/core/router/dialog/widgets/custom_alert_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/setting_input_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/setting_picker_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/about/widget/about_page.dart';
import 'package:zeon/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home/widget/home_page.dart';
import 'package:zeon/features/home_tips/home_tip_controller.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/features/profile/overview/profile_link_account_page.dart';
import 'package:zeon/features/profile/overview/profile_menu_page.dart';
import 'package:zeon/features/profile/overview/profiles_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/overview/sections/dns_options_page.dart';
import 'package:zeon/features/settings/overview/sections/general_page.dart';
import 'package:zeon/features/settings/overview/sections/inbound_options_page.dart';
import 'package:zeon/features/settings/overview/sections/route_options_page.dart';
import 'package:zeon/features/settings/overview/sections/tls_tricks_page.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fonts) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final entry in font['fonts'] as List) {
        final asset = entry as Map<String, dynamic>;
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
  });
  for (final (device, size, scale) in [
    ('phone', const Size(393, 852), 1.0),
    ('tablet', const Size(768, 1024), 1.0),
    ('desktop', const Size(1000, 800), 1.0),
    ('narrow', const Size(320, 740), 1.3),
  ]) {
    for (final (name, page) in <(String, Widget)>[
      ('home', const HomePage()),
      ('profile', const ProfileMenuPage()),
      ('link', const ProfileLinkAccountPage()),
      ('settings', SettingsPage()),
      ('about', const AboutPage()),
      ('general', const GeneralPage()),
      ('routing', const RouteOptionsPage()),
      ('tls', const TlsTricksPage()),
      ('inbound', const InboundOptionsPage()),
      ('dns', const DnsOptionsPage()),
    ]) {
      testWidgets('$device $name uses live widgets without overflow', (tester) async {
        await pumpPage(tester, page, size: size, scale: scale);
        expect(tester.takeException(), isNull);
        if (name == 'home') {
          final nameRect = tester.getRect(find.byKey(const ValueKey('home_header_text')));
          final refresh = tester.getRect(find.byKey(const ValueKey('home_refresh')));
          expect(nameRect.right, lessThan(refresh.left));
          expect(find.text('DEMO PROFILE'), findsOneWidget);
          final canvas = tester.getRect(find.byKey(const ValueKey('home_canvas')));
          final face = tester.getRect(find.byWidgetPredicate((w) => w is Container && w.key is GlobalKey).first);
          expect(face.center.dy, closeTo(canvas.center.dy, 1));
          if (size.width < 840) {
            expect(
              find.descendant(of: find.byKey(const ValueKey('home_mobile_status')), matching: find.text('42 ms')),
              findsOneWidget,
            );
          } else {
            final panel = tester.getRect(find.byKey(const ValueKey('home_desktop_connection_panel')));
            expect(panel.top - face.bottom, closeTo(16, 1));
          }
        }
        await capture(tester, '$device-$name');
      });
    }
  }
  for (final light in [false, true]) {
    testWidgets('about copies complete app info with enlarged text light=$light', (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final container = await pumpPage(tester, const AboutPage(), size: const Size(320, 740), scale: 2, light: light);
      await tester.tap(find.byKey(const ValueKey('about_copy_info')));
      await tester.pump();
      expect(clipboard, container.read(appInfoProvider).requireValue.format());
      expect(tester.takeException(), isNull);
      await capture(tester, 'about-enlarged-$light');
    });
  }
  for (final size in [const Size(393, 740), const Size(768, 650)]) {
    testWidgets('secure caption remains visible above expired server footer $size', (tester) async {
      final container = await pumpPage(tester, const HomePage(), size: size);
      final profile = container.read(activeProfileProvider).requireValue! as RemoteProfileEntity;
      container.read(activeProfileProvider.notifier).state = AsyncData(
        profile.copyWith(
          subInfo: SubscriptionInfo(
            upload: 0,
            download: 0,
            total: 1000,
            expire: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ),
      );
      await container.read(ConfigOptions.warpDetourMode.notifier).update(WarpDetourMode.warpOverProxy);
      await container.read(ConfigOptions.enableWarp.notifier).update(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final secure = find.byKey(const ValueKey('home_secure_caption'));
      expect(secure, findsOneWidget);
      expect(
        tester.getRect(secure).bottom,
        lessThan(tester.getRect(find.byKey(const ValueKey('home_server_picker'))).top),
      );
      expect(tester.takeException(), isNull);
      await container.read(ConfigOptions.enableWarp.notifier).update(false);
      await tester.pump();
      expect(secure, findsNothing);
    });
  }
  testWidgets('quick settings retain immediate service-mode persistence', (tester) async {
    final container = await pumpPage(tester, const QuickSettingsModal());
    final mode = ServiceMode.choices.last;
    await tester.tap(find.text(mode.present(TranslationsRu())));
    await tester.pump();
    expect(container.read(ConfigOptions.serviceMode), mode);
    expect(find.byType(QuickSettingsModal), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('TLS switch persists and enables its dependent settings', (tester) async {
    final container = await pumpPage(tester, const TlsTricksPage());
    final t = TranslationsRu();
    expect(container.read(ConfigOptions.enableTlsFragment), isFalse);
    await tester.tap(find.text(t.pages.settings.tlsTricks.enable));
    await tester.pumpAndSettle();
    expect(container.read(ConfigOptions.enableTlsFragment), isTrue);
  });
  for (final (size, scale, keyboard) in [
    (const Size(393, 852), 1.0, 0.0),
    (const Size(1000, 800), 1.0, 0.0),
    (const Size(320, 740), 1.3, 0.0),
    (const Size(393, 600), 1.3, 290.0),
  ]) {
    testWidgets('long diagnostic scroll and copy $size $scale $keyboard', (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final long = List.filled(45, 'Diagnostic message with an exceptionally long detail.').join('\n');
      await pumpPage(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showZeonDialog<void>(
                context,
                CustomAlertDialog(title: 'Ошибка', message: long, diagnosticText: 'exact diagnostic'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
        size: size,
        scale: scale,
        keyboard: keyboard,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Копировать ошибку'));
      await tester.tap(find.text('Копировать ошибку'));
      await tester.pump();
      expect(clipboard, 'exact diagnostic');
      expect(find.byType(CustomAlertDialog), findsOneWidget);
      await tester.ensureVisible(find.text(TranslationsRu().common.ok));
      await tester.tap(find.text(TranslationsRu().common.ok));
      await tester.pumpAndSettle();
      expect(find.byType(CustomAlertDialog), findsNothing);
    });
  }
  testWidgets('picker returns actual value and input maps validated numbers', (tester) async {
    int? selected;
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => selected = await showZeonDialog<int>(
              context,
              SettingPickerDialog<int>(
                title: 'Choice',
                selected: 1,
                options: const [1, 2],
                getTitle: (n) => 'Value $n',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Value 2'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => selected = await showZeonDialog<int>(
              context,
              const SettingInputDialog<int>(title: 'Port', initialValue: 100, mapTo: int.tryParse, digitsOnly: true),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '8080');
    final label = MaterialLocalizations.of(
      tester.element(find.byType(SettingInputDialog<int>)),
    ).okButtonLabel.toUpperCase();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(selected, 8080);
  });
}

Future<ProviderContainer> pumpPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(393, 852),
  double scale = 1,
  double keyboard = 0,
  bool light = false,
  ProxiesOverviewNotifier Function()? proxies,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => prefs),
      translationsProvider.overrideWith((ref) => TranslationsRu()),
      appInfoProvider.overrideWith(FakeAppInfo.new),
      autoStartNotifierProvider.overrideWith(FakeAutoStart.new),
      updateProfileNotifierProvider('fixture').overrideWith(FakeUpdate.new),
      activeProfileProvider.overrideWith(FakeProfile.new),
      profilesNotifierProvider.overrideWith(FakeProfiles.new),
      connectionNotifierProvider.overrideWith(FakeConnection.new),
      activeProxyNotifierProvider.overrideWith(FakeProxy.new),
      if (proxies != null) proxiesOverviewNotifierProvider.overrideWith(proxies),
      homeConnectionStateProvider.overrideWithValue(MainVpnButtonState.fromLegacyConnectionStatus(const Connected())),
      homeTipProvider.overrideWith(
        (ref) => HomeTipController(
          preferences: prefs,
          currentUser: () => '',
          fetchTip: () async => null,
          fetchImage: (_) async => Uint8List(0),
        ),
      ),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(translationsProvider.future);
  await container.read(appInfoProvider.future);
  await container.read(activeProfileProvider.future);
  await container.read(autoStartNotifierProvider.future);
  await container.read(profilesNotifierProvider.future);
  await container.read(connectionNotifierProvider.future);
  await container.read(activeProxyNotifierProvider.future);
  if (proxies != null) await container.read(proxiesOverviewNotifierProvider.future);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => page),
      for (final name in [
        'general',
        'routeOptions',
        'tlsTricks',
        'inboundOptions',
        'about',
        'profileLinkAccount',
        'intro',
        'proxies',
      ])
        GoRoute(path: '/$name', name: name, builder: (_, _) => const Scaffold()),
    ],
  );
  addTearDown(() {
    router.dispose();
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: light
              ? AppTheme(AppThemeMode.light, 'Montserrat').lightTheme(null)
              : AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null),
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  return container;
}

Future<void> capture(WidgetTester tester, String name) async {
  final path = Platform.environment['ZEON_UI_EVIDENCE'];
  if (path == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('capture')));
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(path).create(recursive: true);
    await File('$path/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class FakeAppInfo extends AppInfo {
  @override
  Future<AppInfoEntity> build() async => const AppInfoEntity(
    name: 'ZEON',
    version: '1.5.0',
    buildNumber: '1',
    release: Release.general,
    operatingSystem: 'test',
    operatingSystemVersion: 'test',
    environment: Environment.prod,
  );
}

class FakeAutoStart extends AutoStartNotifier {
  @override
  Future<bool> build() async => false;
}

class FakeUpdate extends UpdateProfileNotifier {
  @override
  AsyncValue<Unit?> build(String id) => const AsyncData(null);
}

class FakeProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(
    ProfileEntity.remote(
      id: 'fixture',
      active: true,
      name: 'demo_profile',
      url: 'https://example.invalid/preview',
      lastUpdate: DateTime.now(),
      subInfo: SubscriptionInfo(
        upload: 0,
        download: 0,
        total: 1000,
        expire: DateTime.now().add(const Duration(days: 7, hours: 1)),
      ),
    ),
  );
}

class FakeProfiles extends ProfilesNotifier {
  @override
  Stream<List<ProfileEntity>> build() => Stream.value([]);
}

class FakeConnection extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(const Connected());
}

class FakeProxy extends ActiveProxyNotifier {
  @override
  Stream<OutboundInfo> build() => Stream.value(
    OutboundInfo(tag: 'demo', tagDisplay: 'Нидерланды', type: 'proxy', urlTestDelay: 42, isVisible: true),
  );
}
