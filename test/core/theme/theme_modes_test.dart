import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/theme/app_color_tokens.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/theme/theme_extensions.dart';
import 'package:zeon/core/theme/theme_preferences.dart';
import 'package:zeon/features/bootstrap/widget/bootstrap_splash_screen.dart';
import 'package:zeon/features/common/general_pref_tiles.dart';
import 'package:zeon/gen/translations_ru.g.dart';

void main() {
  test('theme selection survives a new provider container, including legacy black', () async {
    for (final (stored, expected) in [
      (null, AppThemeMode.system),
      ('system', AppThemeMode.system),
      ('light', AppThemeMode.light),
      ('dark', AppThemeMode.dark),
      ('amoled', AppThemeMode.amoled),
      ('black', AppThemeMode.amoled),
      ('invalid', AppThemeMode.system),
    ]) {
      SharedPreferences.setMockInitialValues({if (stored != null) 'theme_mode': stored});
      final prefs = await SharedPreferences.getInstance();
      final container = await themeContainer(prefs);
      expect(container.read(themePreferencesProvider), expected);
      for (final choice in AppThemeMode.values) {
        await container.read(themePreferencesProvider.notifier).changeThemeMode(choice);
        expect(prefs.getString('theme_mode'), choice.name);
        final restarted = await themeContainer(prefs);
        expect(restarted.read(themePreferencesProvider), choice);
        restarted.dispose();
      }
      container.dispose();
    }
  });

  testWidgets('picker selects AMOLED or Graphite; system follows OS light and Graphite', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await themeContainer(prefs);
    addTearDown(container.dispose);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final router = GoRouter(
      navigatorKey: rootNavKey,
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: ThemeModePrefTile()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            final mode = ref.watch(themePreferencesProvider);
            final theme = AppTheme(mode, 'Montserrat');
            return MaterialApp.router(
              routerConfig: router,
              themeMode: mode.flutterThemeMode,
              theme: theme.lightTheme(null),
              darkTheme: theme.darkTheme(null),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Color surface() => Theme.of(tester.element(find.byType(ThemeModePrefTile))).colorScheme.surface;
    expect(surface(), AppColorTokens.darkBackground);

    for (final (label, mode, background) in [
      ('AMOLED', AppThemeMode.amoled, AppColorTokens.amoledBackground),
      ('Графит', AppThemeMode.dark, AppColorTokens.darkBackground),
      ('Светлая', AppThemeMode.light, AppColorTokens.lightBackground),
      ('Системная', AppThemeMode.system, AppColorTokens.darkBackground),
    ]) {
      await tester.tap(find.byType(ThemeModePrefTile));
      await tester.pumpAndSettle();
      for (final option in ['Системная', 'Светлая', 'Графит', 'AMOLED']) {
        expect(find.text(option), findsWidgets);
      }
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(container.read(themePreferencesProvider), mode);
      expect(surface(), background);
    }
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(surface(), AppColorTokens.lightBackground);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(surface(), AppColorTokens.darkBackground);
  });

  testWidgets('splash uses the same explicit and system backgrounds as the app', (tester) async {
    for (final mode in AppThemeMode.values) {
      for (final brightness in Brightness.values) {
        final theme = AppTheme(mode, 'Montserrat');
        final dark =
            mode.flutterThemeMode == ThemeMode.dark || (mode == AppThemeMode.system && brightness == Brightness.dark);
        final expected = dark ? theme.darkTheme(null) : theme.lightTheme(null);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(platformBrightness: brightness),
              child: BootstrapSplashScreen(themeMode: mode),
            ),
          ),
        );
        final color = tester
            .widget<ColoredBox>(
              find.descendant(of: find.byType(BootstrapSplashScreen), matching: find.byType(ColoredBox)).first,
            )
            .color;
        expect(color, expected.colorScheme.surface);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
  });

  test('AMOLED preserves original black palette and Graphite uses the approved accents', () {
    final amoled = AppTheme(AppThemeMode.amoled, 'Montserrat').darkTheme(null);
    final graphite = AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null);
    expect(amoled.colorScheme.surface, const Color(0xFF000000));
    expect(amoled.navigationBarTheme.backgroundColor, const Color(0xFF1A1B1F));
    expect(amoled.navigationBarTheme.indicatorColor, const Color(0xFF333333));
    expect(amoled.extension<HomeVisualTheme>()!.idleOpacity, .45);
    expect(graphite.extension<HomeVisualTheme>()!.idleOpacity, .65);
    expect(graphite.colorScheme.surfaceContainerHigh, AppColorTokens.darkSurfaceAlt);
    expect(amoled.colorScheme.surfaceContainerHigh, AppColorTokens.amoledBackground);
    final selected = {WidgetState.selected};
    expect(graphite.navigationBarTheme.indicatorColor, const Color(0xFF3CE74F));
    expect(graphite.navigationBarTheme.iconTheme!.resolve(selected)!.color, const Color(0xFF1A1B1F));
    expect(graphite.navigationBarTheme.labelTextStyle!.resolve(selected)!.color, const Color(0xFF3CE74F));
    expect(
      graphite.navigationRailTheme.selectedIconTheme!.color,
      graphite.navigationBarTheme.iconTheme!.resolve(selected)!.color,
    );
    for (final mode in AppThemeMode.values) {
      final theme = AppTheme(mode, 'Montserrat');
      for (final systemDark in [true, false]) {
        final dark =
            mode == AppThemeMode.dark || mode == AppThemeMode.amoled || (mode == AppThemeMode.system && systemDark);
        final material = dark ? theme.darkTheme(null) : theme.lightTheme(null);
        expect(
          theme.cupertinoThemeData(systemDark, null, null).scaffoldBackgroundColor,
          material.scaffoldBackgroundColor,
        );
      }
    }
  });
}

Future<ProviderContainer> themeContainer(SharedPreferences prefs) async {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => prefs),
      translationsProvider.overrideWith((ref) => TranslationsRu()),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(translationsProvider.future);
  return container;
}
