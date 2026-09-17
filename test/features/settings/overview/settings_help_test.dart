import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/adaptive_layout/animated_branch_container.dart';
import 'package:zeon/features/settings/overview/sections/route_options_page.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';
import 'package:zeon/features/settings/widget/settings_help.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/gen/translations_ru.g.dart';

import '../../ui/approved_interface_test.dart' as fixtures;

const card = ValueKey('settings-help-card');
const target = ValueKey('settings-help-target');
const close = ValueKey('settings-help-close');

Future<ProviderContainer> pumpHelp(
  WidgetTester tester,
  Widget child, {
  SharedPreferences? prefs,
  Size size = const Size(393, 852),
  double scale = 1,
  bool reduced = true,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (prefs == null) {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  }
  final store = prefs;
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => store),
      translationsProvider.overrideWith((ref) => TranslationsRu()),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(translationsProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced, textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

Widget lesson() => const Scaffold(
  body: SingleChildScrollView(
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 160, 16, 0),
      child: SettingsHelpOnboarding(
        child: SettingsTile(title: Text('Маршрутизация'), help: 'Routing help'),
      ),
    ),
  ),
);

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

  testWidgets('mandatory lesson, root barrier, back, short tap, persistence and repeat help', (tester) async {
    var taps = 0;
    final container = await pumpHelp(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(top: 160),
            child: SettingsHelpOnboarding(
              child: SettingsTile(title: const Text('Маршрутизация'), help: 'Routing help', onTap: () => taps++),
            ),
          ),
        ),
        bottomNavigationBar: TextButton(onPressed: () => taps++, child: const Text('Other tab')),
      ),
    );
    expect(find.byKey(card), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.tapAt(const Offset(190, 825));
    await tester.tap(find.byKey(target));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(card), findsOneWidget);
    expect(find.byKey(close), findsNothing);
    expect(taps, 0);
    expect(container.read(Preferences.settingsHelpLearned), isFalse);
    await tester.longPress(find.byKey(target));
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(container.read(Preferences.settingsHelpLearned), isTrue);
    final prefs = container.read(sharedPreferencesProvider).requireValue;
    expect(prefs.getBool('settings_help_learned'), isTrue);
    await tester.tap(find.byKey(close));
    await tester.pumpAndSettle();
    // New widget tree AND new providers read the persisted marker.
    final reloaded = await pumpHelp(tester, lesson(), prefs: prefs);
    expect(reloaded.read(Preferences.settingsHelpLearned), isTrue);
    expect(find.byKey(card), findsNothing);
    await tester.longPress(find.text('Маршрутизация'));
    await tester.pumpAndSettle();
    expect(find.text('Routing help'), findsOneWidget);
    expect(find.byKey(close), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden branch waits for first visible Settings entry', (tester) async {
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await pumpHelp(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, value, child) => TickerMode(
          enabled: value,
          child: Offstage(offstage: !value, child: child),
        ),
        child: lesson(),
      ),
    );
    expect(find.byKey(card), findsNothing);
    active.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);
    await tester.longPress(find.byKey(target));
    await tester.pumpAndSettle();
  });

  testWidgets('holding enabled or disabled switch does not change its value', (tester) async {
    var changed = 0;
    await pumpHelp(
      tester,
      Scaffold(
        body: Column(
          children: [
            SettingsSwitch(
              title: const Text('Enabled'),
              help: 'Enabled help',
              value: false,
              onChanged: (_) => changed++,
            ),
            const SettingsSwitch(title: Text('Disabled'), help: 'Disabled help', value: false, onChanged: null),
          ],
        ),
      ),
    );
    for (final name in ['Enabled', 'Disabled']) {
      await tester.longPress(find.text(name));
      await tester.pumpAndSettle();
      expect(find.text('$name help'), findsOneWidget);
      expect(changed, 0);
      await tester.tap(find.byKey(close));
      await tester.pumpAndSettle();
    }
    await tester.longPress(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('Enabled help'), findsOneWidget);
    expect(changed, 0);
    await tester.tap(find.byKey(close));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enabled'));
    await tester.pump();
    expect(changed, 1);
  });

  for (final size in [const Size(320, 740), const Size(740, 320), const Size(1000, 800)]) {
    testWidgets('real Settings lesson and help fit $size with enlarged text', (tester) async {
      await fixtures.pumpPage(tester, SettingsPage(), size: size, scale: 1.3);
      await tester.pump();
      expect(find.byKey(card), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixtures.capture(tester, 'settings-lesson-${size.width.toInt()}');
      await tester.longPress(find.byKey(target));
      await tester.pumpAndSettle();
      expect(find.byKey(close), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixtures.capture(tester, 'settings-help-${size.width.toInt()}');
    });
  }

  testWidgets('real IPv6 help leaves selected preference unchanged', (tester) async {
    final container = await fixtures.pumpPage(tester, const RouteOptionsPage());
    final prefs = container.read(sharedPreferencesProvider).requireValue;
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    await tester.ensureVisible(find.text('Маршрут IPv6'));
    await tester.longPress(find.text('Маршрут IPv6'));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    expect(tester.takeException(), isNull);
    await fixtures.capture(tester, 'settings-ipv6-help');
  });

  testWidgets('keyboard activation teaches; live low-power toggle stops motion', (tester) async {
    final container = await pumpHelp(tester, lesson(), reduced: false);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await container.read(Preferences.lowPowerMode.notifier).update(true);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(Preferences.settingsHelpLearned), isTrue);
    expect(find.byKey(close), findsOneWidget);
  });

  testWidgets('spotlight follows target after window resize', (tester) async {
    await pumpHelp(tester, lesson());
    tester.view.physicalSize = const Size(740, 320);
    await tester.pumpAndSettle();
    final targetRect = tester.getRect(find.byKey(target));
    final rowRect = tester.getRect(find.byType(SettingsTile));
    expect(targetRect.center.dx, closeTo(rowRect.center.dx, 1));
    expect(targetRect.top, closeTo(rowRect.top, 1));
    expect(tester.takeException(), isNull);
    await tester.longPress(find.byKey(target));
    await tester.pumpAndSettle();
    expect(find.byKey(close), findsOneWidget);
  });

  testWidgets('spotlight follows the real animated branch entrance', (tester) async {
    final active = ValueNotifier(0);
    addTearDown(active.dispose);
    await pumpHelp(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: active,
        builder: (_, value, _) => AnimatedBranchContainer(
          currentIndex: value,
          children: [
            const Scaffold(body: Text('Home')),
            lesson(),
          ],
        ),
      ),
      reduced: false,
    );
    active.value = 1;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Commit geometry measured after the animation's final layout frame.
    await tester.pump();
    expect(tester.getRect(find.byKey(target)).top, closeTo(tester.getRect(find.byType(SettingsTile)).top, 1));
    await tester.longPress(find.byKey(target));
    await tester.pumpAndSettle();
  });

  for (final teaching in [false, true]) {
    testWidgets('offscreen target remains usable after shrinking window, lesson=$teaching', (tester) async {
      const row = SettingsTile(title: Text('Setting'), help: 'Help text');
      await pumpHelp(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(top: 600),
              child: teaching ? const SettingsHelpOnboarding(child: row) : row,
            ),
          ),
        ),
        size: const Size(900, 900),
      );
      if (!teaching) {
        await tester.longPress(find.text('Setting'));
        await tester.pumpAndSettle();
      }
      tester.view.physicalSize = const Size(740, 320);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(target));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.center.dy, lessThan(320));
      expect(rect.top, closeTo(tester.getRect(find.byType(SettingsTile)).top, 1));
      if (teaching) {
        await tester.longPress(find.byKey(target));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(close));
      await tester.pumpAndSettle();
      expect(find.byKey(card), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
