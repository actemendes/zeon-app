import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/adaptive_layout/my_adaptive_layout.dart';
import 'package:zeon/core/router/go_router/routing_config_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/home/widget/home_connection_layout.dart';
import 'package:zeon/features/intro/widget/intro_page.dart';
import 'package:zeon/features/shortcut/shortcut_wrapper.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

import '../ui/approved_interface_test.dart' as fixtures;

bool focusIsInside(Finder finder) {
  final element = finder.evaluate().single;
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  var inside = focused == element;
  focused.visitAncestorElements((ancestor) {
    if (ancestor == element) inside = true;
    return !inside;
  });
  return inside;
}

final _readyToConnect = MainVpnButtonState.fromSnapshot(
  const VpnSessionSnapshot(
    generation: 1,
    runtimeEpoch: 'tv-focus-test',
    sequenceNumber: 1,
    snapshotVersion: 1,
    phase: VpnSessionPhase.idle,
  ),
);

Future<void> pumpAsyncVpnButton(
  WidgetTester tester, {
  required ValueNotifier<MainVpnButtonState> state,
  required VoidCallback onPressed,
  required FocusNode otherFocus,
  ButtonPreset preset = ButtonPreset.standard,
  ValueNotifier<bool>? visible,
}) async {
  Widget button(bool active) => TickerMode(
    enabled: active,
    child: ExcludeFocus(
      excluding: !active,
      child: ValueListenableBuilder<MainVpnButtonState>(
        valueListenable: state,
        builder: (_, value, _) => MainVpnButtonView(
          autofocus: true,
          showStatus: false,
          presentation: value.present(TranslationsRu()),
          image: Assets.images.disconnectNorouz,
          useImage: false,
          secureLabel: '',
          appearance: ButtonAppearance(preset: preset),
          onTap: value.enabled ? onPressed : null,
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: LayoutBuilder(
              builder: (_, constraints) => FocusScope(
                child: SingleChildScrollView(
                  child: HomeConnectionLayout(
                    viewportHeight: constraints.maxHeight,
                    desktop: true,
                    header: const SizedBox(height: 48),
                    dial: visible == null
                        ? button(true)
                        : ValueListenableBuilder<bool>(
                            valueListenable: visible,
                            builder: (_, active, _) => button(active),
                          ),
                    status: TextButton(focusNode: otherFocus, onPressed: () {}, child: const Text('Other action')),
                    footer: const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('D-pad center activates through the production ShortcutWrapper nesting', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: ShortcutWrapper(
          MaterialApp(
            home: Scaffold(
              body: FilledButton(autofocus: true, onPressed: () => taps++, child: const Text('Connect')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('first launch exposes start, account and terms to D-pad traversal', (tester) async {
    await fixtures.pumpPage(tester, const IntroPage(), size: const Size(960, 540));
    final start = find.byKey(const ValueKey(UiNames.buttonIntroStart));
    final account = find.byKey(const ValueKey(UiNames.buttonIntroAlreadyHaveAccount));
    final terms = find.byKey(const ValueKey('intro_terms_button'));
    expect(focusIsInside(start), isTrue, reason: 'A remote user needs an initial action without a pointer.');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusIsInside(account), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(terms, findsOneWidget);
    expect(focusIsInside(terms), isTrue, reason: 'The terms link must be reachable without touch.');
  });

  testWidgets('D-pad center opens account input and system Back closes it', (tester) async {
    await fixtures.pumpPage(tester, const IntroPage(), size: const Size(960, 540));
    // Starting at the first action also exercises traversal without touch.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(UiNames.dialogIntroBindAccount)), findsOneWidget);
    expect(focusIsInside(find.byKey(const ValueKey(UiNames.inputIntroBindLink))), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(UiNames.dialogIntroBindAccount)), findsNothing);
  });

  testWidgets('Home initially focuses the main VPN action', (tester) async {
    await fixtures.pumpPage(
      tester,
      const Scaffold(body: Center(child: ConnectionButton(showStatus: false))),
      size: const Size(960, 540),
    );
    expect(focusIsInside(find.byType(ConnectionButton)), isTrue);
  });

  for (final preset in [ButtonPreset.standard, ButtonPreset.kawaii]) {
    testWidgets('first enabled VPN action receives focus after async loading, preset=$preset', (tester) async {
      final state = ValueNotifier(const MainVpnButtonState.loading());
      final otherFocus = FocusNode();
      addTearDown(state.dispose);
      addTearDown(otherFocus.dispose);
      var activations = 0;
      await pumpAsyncVpnButton(
        tester,
        state: state,
        otherFocus: otherFocus,
        preset: preset,
        onPressed: () => activations++,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 0);
      state.value = _readyToConnect;
      await tester.pump();
      await tester.pump();
      expect(focusIsInside(find.byType(MainVpnButtonView)), isTrue);
      expect(FocusManager.instance.primaryFocus!.canRequestFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('home_vpn_focus_outline')), findsOneWidget);

      // Stopping temporarily disables the action that still owns remote focus.
      state.value = const MainVpnButtonState.loading();
      await tester.pump();
      state.value = _readyToConnect;
      await tester.pump();
      await tester.pump();
      expect(focusIsInside(find.byType(MainVpnButtonView)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(otherFocus.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('home_vpn_focus_outline')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusIsInside(find.byType(MainVpnButtonView)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 3);

      // A new user choice while disabled cancels restoration to the old owner.
      state.value = const MainVpnButtonState.loading();
      await tester.pump();
      otherFocus.requestFocus();
      await tester.pump();
      state.value = _readyToConnect;
      await tester.pump();
      await tester.pump();
      expect(otherFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 3);
    });
  }

  testWidgets('async VPN readiness does not steal focus chosen by the user', (tester) async {
    final state = ValueNotifier(const MainVpnButtonState.loading());
    final otherFocus = FocusNode();
    addTearDown(state.dispose);
    addTearDown(otherFocus.dispose);
    await pumpAsyncVpnButton(tester, state: state, otherFocus: otherFocus, onPressed: () {});
    otherFocus.requestFocus();
    await tester.pump();
    expect(otherFocus.hasFocus, isTrue);
    state.value = _readyToConnect;
    await tester.pump();
    await tester.pump();
    expect(otherFocus.hasFocus, isTrue);
    // Subsequent disabled/enabled cycles must not restart initial focus either.
    state.value = const MainVpnButtonState.loading();
    await tester.pump();
    state.value = _readyToConnect;
    await tester.pump();
    await tester.pump();
    expect(otherFocus.hasFocus, isTrue);
  });

  testWidgets('async VPN readiness preserves root dialog focus', (tester) async {
    final state = ValueNotifier(const MainVpnButtonState.loading());
    final otherFocus = FocusNode();
    addTearDown(state.dispose);
    addTearDown(otherFocus.dispose);
    await pumpAsyncVpnButton(tester, state: state, otherFocus: otherFocus, onPressed: () {});
    final homeContext = tester.element(find.byType(MainVpnButtonView));
    showDialog<void>(
      context: homeContext,
      builder: (dialogContext) => AlertDialog(
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
    // The disabled Home dial keeps animating beneath this route.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    state.value = _readyToConnect;
    await tester.pump();
    await tester.pump();
    expect(focusIsInside(find.byType(AlertDialog)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('inactive Home waits for visibility before initial focus', (tester) async {
    final state = ValueNotifier(const MainVpnButtonState.loading());
    final visible = ValueNotifier(false);
    final otherFocus = FocusNode();
    addTearDown(state.dispose);
    addTearDown(visible.dispose);
    addTearDown(otherFocus.dispose);
    await pumpAsyncVpnButton(tester, state: state, visible: visible, otherFocus: otherFocus, onPressed: () {});
    state.value = _readyToConnect;
    await tester.pump();
    await tester.pump();
    expect(focusIsInside(find.byType(MainVpnButtonView)), isFalse);
    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(focusIsInside(find.byType(MainVpnButtonView)), isTrue);
  });

  for (final rtl in [false, true]) {
    testWidgets('rail navigation crosses the shared edge and preserves modal focus, rtl=$rtl', (tester) async {
      final towardsRail = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
      final towardsContent = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
      tester.view.physicalSize = const Size(960, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final contentFocus = FocusNode();
      final secondFocus = FocusNode();
      final inputFocus = FocusNode();
      final input = TextEditingController();
      addTearDown(contentFocus.dispose);
      addTearDown(secondFocus.dispose);
      addTearDown(inputFocus.dispose);
      addTearDown(input.dispose);
      final container = ProviderContainer(overrides: [translationsProvider.overrideWith((_) => TranslationsRu())]);
      await container.read(translationsProvider.future);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) =>
                MyAdaptiveLayout(navigationShell: shell, isMobileBreakpoint: false, showProfilesAction: false),
            branches: [
              for (final name in ['home', 'settings', 'logs', 'about', 'profileMenu'])
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/$name',
                      builder: (context, _) => FocusScope(
                        node: branchesScope[name],
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FilledButton(
                                  focusNode: name == 'home' ? secondFocus : null,
                                  onPressed: () {},
                                  child: const Text('Other action'),
                                ),
                                FilledButton(
                                  focusNode: name == 'home' ? contentFocus : null,
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (dialogContext) => AlertDialog(
                                      title: const Text('Permission explanation'),
                                      actions: [
                                        TextButton(
                                          autofocus: true,
                                          onPressed: () => Navigator.of(dialogContext).pop(),
                                          child: const Text('Close'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: Text('content-$name'),
                                ),
                              ],
                            ),
                            if (name == 'home')
                              SizedBox(
                                width: 220,
                                child: TextField(
                                  focusNode: inputFocus,
                                  controller: input,
                                  textDirection: TextDirection.ltr,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            builder: (_, child) =>
                Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      contentFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(towardsContent);
      await tester.pump();
      expect(contentFocus.hasFocus, isTrue, reason: 'The outer content edge must not jump backwards into the rail.');
      await tester.sendKeyEvent(towardsRail);
      await tester.pump();
      expect(secondFocus.hasFocus, isTrue, reason: 'In-pane traversal must precede the shell handoff.');
      await tester.sendKeyEvent(towardsRail);
      await tester.pump();
      expect(focusIsInside(find.byType(NavigationRail)), isTrue);
      await tester.sendKeyEvent(towardsRail);
      await tester.pump();
      expect(
        focusIsInside(find.byType(NavigationRail)),
        isTrue,
        reason: 'The outer rail edge must not jump into content.',
      );
      await tester.sendKeyEvent(towardsContent);
      await tester.pump();
      expect(secondFocus.hasFocus, isTrue, reason: 'Re-entering content restores its last action.');
      await tester.sendKeyEvent(towardsContent);
      await tester.pump();
      expect(contentFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      for (final arrow in [towardsRail, towardsContent]) {
        await tester.sendKeyEvent(arrow);
        await tester.pump();
        expect(focusIsInside(find.byType(AlertDialog)), isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(find.byType(TextField), 'tv-code');
      await tester.sendKeyEvent(towardsRail);
      await tester.pump();
      expect(inputFocus.hasFocus, isTrue, reason: 'Editing a link must not hand focus to the rail.');
      expect(input.text, 'tv-code');
    });
  }
}
