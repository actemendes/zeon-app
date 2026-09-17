import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/overview/sections/inbound_options_page.dart';
import 'package:zeon/features/settings/widget/settings_help.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final translations = <AppLocale, Translations>{};
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      translations[locale] = await loadTranslations(locale);
    }
  });

  Future<ProviderContainer> pumpSettings(
    WidgetTester tester, {
    AppLocale locale = AppLocale.ru,
    Widget page = const InboundOptionsPage(),
  }) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        translationsProvider.overrideWith((ref) => translations[locale]!),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    final router = GoRouter(
      navigatorKey: rootNavKey,
      routes: [GoRoute(path: '/', builder: (_, _) => page)],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: locale.flutterLocale,
          supportedLocales: AppLocale.values.map((value) => value.flutterLocale),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  test('every app locale supplies all help strings without English fallback', () {
    Map<String, dynamic> catalog(AppLocale locale) =>
        (jsonDecode(File('assets/translations/${locale.languageTag}.i18n.json').readAsStringSync())
                as Map<String, dynamic>)['settingsHelp']
            as Map<String, dynamic>;
    final base = catalog(AppLocale.en);
    for (final locale in AppLocale.values) {
      final help = catalog(locale);
      expect(help.keys, unorderedEquals(base.keys), reason: locale.languageTag);
      for (final entry in help.entries) {
        expect(entry.value, isA<String>(), reason: '${locale.languageTag}.${entry.key}');
        expect((entry.value as String).trim(), isNotEmpty);
        if (locale != AppLocale.en) {
          expect(entry.value, isNot(base[entry.key]), reason: '${locale.languageTag}.${entry.key}');
        }
        expect(translations[locale]!['settingsHelp.${entry.key}'], entry.value);
      }
    }
  });

  testWidgets('mixed port is editable in every mode and persists valid input', (tester) async {
    final container = await pumpSettings(tester);
    final title = translations[AppLocale.ru]!.pages.settings.inbound.mixedPort;
    expect(find.text('12334'), findsOneWidget);
    for (final mode in ServiceMode.choices) {
      await container.read(ConfigOptions.serviceMode.notifier).update(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '23456');
      final label = MaterialLocalizations.of(tester.element(find.byType(TextField))).okButtonLabel.toUpperCase();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(container.read(ConfigOptions.mixedPort), 23456);
      expect(container.read(sharedPreferencesProvider).requireValue.getInt('mixed-port'), 23456);
      expect(find.text('23456'), findsOneWidget);
    }
    final reloaded = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => container.read(sharedPreferencesProvider).requireValue),
      ],
    );
    addTearDown(reloaded.dispose);
    await reloaded.read(sharedPreferencesProvider.future);
    expect(reloaded.read(ConfigOptions.mixedPort), 23456);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid port input cannot replace the saved port', (tester) async {
    final container = await pumpSettings(tester);
    final title = translations[AppLocale.ru]!.pages.settings.inbound.mixedPort;
    for (final invalid in ['', '0', '65536']) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), invalid);
      final label = MaterialLocalizations.of(tester.element(find.byType(TextField))).okButtonLabel.toUpperCase();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(container.read(ConfigOptions.mixedPort), 12334);
      expect(container.read(sharedPreferencesProvider).requireValue.getInt('mixed-port'), isNull);
    }
    expect(tester.takeException(), isNull);
  });

  for (final locale in AppLocale.values) {
    testWidgets('${locale.languageTag}: localized port help is read only', (tester) async {
      final container = await pumpSettings(tester, locale: locale);
      final t = translations[locale]!;
      await tester.longPress(find.text(t.pages.settings.inbound.mixedPort));
      await tester.pumpAndSettle();
      expect(find.text(t.settingsHelp.mixedPort), findsOneWidget);
      expect(find.text(t.settingsHelp.label), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(container.read(ConfigOptions.mixedPort), 12334);
      expect(container.read(sharedPreferencesProvider).requireValue.getInt('mixed-port'), isNull);
      final direction = Directionality.of(tester.element(find.text(t.settingsHelp.mixedPort)));
      expect(direction, [AppLocale.ar, AppLocale.fa].contains(locale) ? TextDirection.rtl : TextDirection.ltr);
      await tester.tap(find.byKey(const ValueKey('settings-help-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-help-card')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${locale.languageTag}: translated onboarding can be completed', (tester) async {
      final t = translations[locale]!;
      await pumpSettings(
        tester,
        locale: locale,
        page: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 120, 16, 0),
              child: SettingsHelpOnboarding(
                child: SettingsTile(title: Text(t.pages.settings.routing.title), help: t.settingsHelp.routing),
              ),
            ),
          ),
        ),
      );
      expect(find.text(t.settingsHelp.learn), findsOneWidget);
      expect(find.text(t.settingsHelp.tryRouting), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-help-close')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('settings-help-target')));
      await tester.pumpAndSettle();
      expect(find.text(t.settingsHelp.routing), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-help-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
