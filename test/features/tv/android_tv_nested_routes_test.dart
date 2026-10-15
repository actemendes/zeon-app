import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/router/go_router/routing_config_notifier.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_provider.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_editor.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_page.dart';
import 'package:zeon/features/common/general_pref_tiles.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home_tips/home_tip_controller.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_page.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/features/profile/overview/profiles_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_page.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/features/settings/overview/sections/general_page.dart';
import 'package:zeon/features/settings/overview/sections/route_options_page.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

import '../ui/approved_interface_test.dart' as fixtures;
import 'android_tv_navigation_test.dart' show focusIsInside;

class _Proxies extends ProxiesOverviewNotifier {
  @override
  Stream<OutboundGroup?> build() => Stream.value(
    OutboundGroup(
      tag: 'select',
      selected: 'test-a',
      items: [
        OutboundInfo(tag: 'test-a', tagDisplay: 'Test server A', type: 'proxy', urlTestDelay: 42),
        OutboundInfo(tag: 'test-b', tagDisplay: 'Test server B', type: 'proxy', urlTestDelay: 57),
      ],
    ),
  );
}

class _Appearance extends ButtonAppearanceNotifier {
  @override
  Future<ButtonAppearance> build() async => const ButtonAppearance(preset: ButtonPreset.custom, name: 'TV draft');
}

Future<GoRouter> _pumpRouter(WidgetTester tester, {required String location, bool mobile = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = mobile ? const Size(393, 852) : const Size(960, 450);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((_) => prefs),
      translationsProvider.overrideWith((_) => TranslationsRu()),
      appInfoProvider.overrideWith(fixtures.FakeAppInfo.new),
      autoStartNotifierProvider.overrideWith(fixtures.FakeAutoStart.new),
      activeProfileProvider.overrideWith(fixtures.FakeProfile.new),
      profilesNotifierProvider.overrideWith(fixtures.FakeProfiles.new),
      hasAnyProfileProvider.overrideWith((_) => Stream.value(false)),
      connectionNotifierProvider.overrideWith(fixtures.FakeConnection.new),
      homeConnectionStateProvider.overrideWithValue(MainVpnButtonState.fromLegacyConnectionStatus(const Connected())),
      updateProfileNotifierProvider('fixture').overrideWith(fixtures.FakeUpdate.new),
      activeProxyNotifierProvider.overrideWith(fixtures.FakeProxy.new),
      proxiesOverviewNotifierProvider.overrideWith(_Proxies.new),
      buttonAppearanceProvider.overrideWith(_Appearance.new),
      isMobileBreakpointProvider.overrideWithValue(mobile),
      homeTipProvider.overrideWith(
        (_) => HomeTipController(
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
  await container.read(proxiesOverviewNotifierProvider.future);
  await container.read(buttonAppearanceProvider.future);
  await container.read(hasAnyProfileProvider.future);
  await container.read(Preferences.introCompleted.notifier).update(true);
  final config = container.read(routingConfigNotifierProvider);
  final router = GoRouter(initialLocation: location, navigatorKey: rootNavKey, routes: config.routes);
  addTearDown(() {
    router.dispose();
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  return router;
}

Future<FocusNode> _focusAction(WidgetTester tester, Finder action) async {
  final outline = find.descendant(of: action, matching: find.byType(KeyboardFocusOutline)).first;
  final node = Focus.of(tester.element(outline));
  node.requestFocus();
  await tester.pump();
  return node;
}

Future<void> _roundTripToRail(WidgetTester tester, FocusNode content) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.pump();
  expect(focusIsInside(find.byType(NavigationRail)), isTrue, reason: 'A pushed page must reach the visible rail.');
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  await tester.pump();
  expect(content.hasPrimaryFocus, isTrue, reason: 'Return to the visible nested page, not its hidden root page.');
}

void main() {
  testWidgets('real server page crosses to rail and back without changing selection or route', (tester) async {
    final router = await _pumpRouter(tester, location: '/home/proxies');
    expect(find.byType(ProxiesOverviewPage), findsOneWidget);
    final tile = find.byType(ProxyTile).first;
    final node = await _focusAction(tester, tile);
    await _roundTripToRail(tester, node);
    expect(tester.widget<ProxyTile>(tile).selected, isTrue);
    expect(router.routeInformationProvider.value.uri.path, '/home/proxies');
    expect(router.canPop(), isTrue);
    router.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProxiesOverviewPage), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/home');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real nested settings preserve route and Back stack across rail focus and branch switches', (
    tester,
  ) async {
    final router = await _pumpRouter(tester, location: '/settings/general');
    final node = await _focusAction(tester, find.byType(LocalePrefTile));
    await _roundTripToRail(tester, node);
    expect(find.byType(GeneralPage), findsOneWidget);
    final rail = find.byType(NavigationRail);
    await tester.tap(find.descendant(of: rail, matching: find.byIcon(Icons.power_settings_new_rounded)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.descendant(of: rail, matching: find.byIcon(Icons.settings_rounded)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GeneralPage), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/settings/general');
    router.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real settings modal keeps arrows inside the dialog', (tester) async {
    await _pumpRouter(tester, location: '/settings/general');
    await _focusAction(tester, find.byType(ThemeModePrefTile));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Dialog), findsOneWidget);
    for (final arrow in [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
      await tester.sendKeyEvent(arrow);
      await tester.pump();
      expect(focusIsInside(find.byType(Dialog)), isTrue);
    }
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(GeneralPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('imperative settings page keeps text editing and its nested Back stack', (tester) async {
    await _pumpRouter(tester, location: '/settings/general');
    await tester.ensureVisible(find.byType(ButtonAppearancePrefTile));
    await _focusAction(tester, find.byType(ButtonAppearancePrefTile));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ButtonAppearancePage), findsOneWidget);
    expect(find.byType(ButtonAppearanceEditor), findsOneWidget);
    final back = find.descendant(
      of: find.byType(ButtonAppearancePage),
      matching: find.byIcon(Icons.arrow_back_rounded),
    );
    final backNode = Focus.of(tester.element(back));
    backNode.requestFocus();
    await tester.pump();
    await _roundTripToRail(tester, backNode);
    final input = find.byKey(const ValueKey('preset-name'));
    await tester.scrollUntilVisible(
      input,
      200,
      scrollable: find.descendant(of: find.byType(ButtonAppearancePage), matching: find.byType(Scrollable)).first,
    );
    await tester.enterText(input, 'TV draft unchanged');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(focusIsInside(input), isTrue);
    expect(tester.widget<TextField>(input).controller!.text, 'TV draft unchanged');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GeneralPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone nested route retains bottom navigation and Back behavior', (tester) async {
    final router = await _pumpRouter(tester, location: '/settings/general', mobile: true);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(GeneralPage), findsOneWidget);
    router.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real per-app route reaches rail while search arrows remain in the input', (tester) async {
    final router = await _pumpRouter(tester, location: '/settings/route-options/per-app-proxy');
    final page = find.byType(PerAppProxyPage);
    expect(page, findsOneWidget);
    final back = find.descendant(of: page, matching: find.byType(BackButton));
    final node = Focus.of(tester.element(find.descendant(of: back, matching: find.byType(Icon)).first));
    node.requestFocus();
    await tester.pump();
    await _roundTripToRail(tester, node);
    final localizations = MaterialLocalizations.of(tester.element(page));
    await tester.tap(find.byTooltip(localizations.searchFieldLabel));
    await tester.pump();
    final input = find.byType(TextFormField);
    await tester.enterText(input, 'TV search');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(focusIsInside(input), isTrue);
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'TV search');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RouteOptionsPage), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/settings/route-options');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
