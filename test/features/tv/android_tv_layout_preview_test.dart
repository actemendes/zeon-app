import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/adaptive_layout/animated_branch_container.dart';
import 'package:zeon/core/router/adaptive_layout/my_adaptive_layout.dart';
import 'package:zeon/core/router/go_router/routing_config_notifier.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/core/widget/tv_display_layout.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/home/widget/home_page.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/features/shortcut/shortcut_wrapper.dart';
import 'package:zeon/features/stats/notifier/stats_notifier.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

import '../ui/approved_interface_test.dart' as fixtures;

void main() {
  setUpAll(() async {
    final fonts = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fonts) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final asset in font['fonts'] as List) {
        loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
      }
      await loader.load();
    }
  });

  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    for (final page in ['home', 'settings']) {
      testWidgets('TV $page fits the scaled production shell with visible focus in ${mode.name}', (tester) async {
        final container = await fixtures.pumpPage(tester, const SizedBox(), size: const Size(960, 540));
        await container.read(Preferences.settingsHelpLearned.notifier).update(true);
        final router = GoRouter(
          initialLocation: '/$page',
          routes: [
            StatefulShellRoute(
              navigatorContainerBuilder: (_, shell, children) =>
                  AnimatedBranchContainer(currentIndex: shell.currentIndex, children: children),
              builder: (_, _, shell) =>
                  MyAdaptiveLayout(navigationShell: shell, isMobileBreakpoint: false, showProfilesAction: false),
              branches: [
                for (final name in ['home', 'settings', 'logs', 'about', 'profileMenu'])
                  StatefulShellBranch(
                    routes: [
                      GoRoute(
                        name: name,
                        path: '/$name',
                        builder: (_, _) => FocusScope(
                          node: branchesScope[name],
                          child: switch (name) {
                            'home' => const HomePage(),
                            'settings' => SettingsPage(),
                            _ => const Scaffold(),
                          },
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            for (final name in ['general', 'routeOptions', 'tlsTricks', 'inboundOptions'])
              GoRoute(name: name, path: '/$name', builder: (_, _) => const Scaffold()),
          ],
        );
        addTearDown(router.dispose);
        final theme = AppTheme(mode, 'Montserrat');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: ProviderScope(
              overrides: [statsNotifierProvider.overrideWith(_PreviewStats.new)],
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: RepaintBoundary(
                    key: const ValueKey('capture'),
                    child: TvDisplayLayout(
                      isTelevision: true,
                      child: ShortcutWrapper(
                        MaterialApp.router(
                          debugShowCheckedModeBanner: false,
                          routerConfig: router,
                          theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
                          locale: const Locale('ru'),
                          supportedLocales: const [Locale('ru')],
                          localizationsDelegates: GlobalMaterialLocalizations.delegates,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final focusTarget = page == 'home' ? find.byType(MainVpnButtonView) : find.byType(SettingsTile).first;
        final targetElement = focusTarget.evaluate().single;
        final focus = FocusManager.instance.rootScope.descendants.firstWhere((node) {
          if (!node.canRequestFocus || node.skipTraversal || node.context == null) return false;
          var inside = node.context == targetElement;
          node.context!.visitAncestorElements((ancestor) {
            if (ancestor == targetElement) inside = true;
            return !inside;
          });
          return inside;
        });
        focus.requestFocus();
        // A harmless remote key switches focus visibility into keyboard mode.
        await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isTrue);
        expect(
          find.descendant(
            of: focusTarget,
            matching: find.byWidgetPredicate(
              (widget) => widget is CustomPaint && widget.foregroundPainter is KeyboardFocusOutlinePainter,
            ),
          ),
          findsOneWidget,
        );
        final media = MediaQuery.of(tester.element(focusTarget));
        expect(media.size, const Size(1280, 720));
        expect(tester.takeException(), isNull);
        await fixtures.capture(tester, 'tv-${mode.name}-$page-focused');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}

class _PreviewStats extends StatsNotifier {
  @override
  Stream<SystemInfo> build() => Stream.value(SystemInfo.create());
}
