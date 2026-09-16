import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zeon/core/router/adaptive_layout/animated_branch_container.dart';

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('branch navigation retains nested routes and input at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(find.text('settings tab'));
      await tester.pumpAndSettle();
      router.go('/settings/details');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'retained input');

      await tester.tap(find.text('home tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('profile tab'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('settings tab'));
      await tester.pumpAndSettle();

      expect(find.text('retained input'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, '/settings/details');
      expect(tester.takeException(), isNull);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('settings page'), findsOneWidget);
    });
  }

  testWidgets('only active branch can focus and tick; motion settles when disabled', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final children = [TextField(focusNode: focus), const Text('settings'), const Text('profile')];
    Future<void> show(int index, {bool reduced = false}) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: AnimatedBranchContainer(currentIndex: index, children: children),
          ),
        ),
      ),
    );
    FadeTransition fade() => tester.widget<FadeTransition>(
      find.descendant(of: find.byType(AnimatedBranchContainer), matching: find.byType(FadeTransition)).first,
    );

    await show(0);
    expect(fade().opacity.value, 1);
    await show(1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fade().opacity.value, inExclusiveRange(0, 1));
    expect(focus.canRequestFocus, isFalse);
    final hiddenContext = tester.element(find.byType(TextField, skipOffstage: false));
    expect(TickerMode.of(hiddenContext), isFalse);

    await show(2, reduced: true);
    expect(fade().opacity.value, 1);
    await show(0, reduced: true);
    expect(fade().opacity.value, 1);
    expect(focus.canRequestFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scroll position survives section changes and same-index rebuilds do not restart motion', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final children = [
      ListView.builder(controller: scroll, itemExtent: 60, itemCount: 50, itemBuilder: (_, i) => Text('row $i')),
      const Text('settings'),
    ];
    Future<void> show(int index) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBranchContainer(currentIndex: index, children: children),
        ),
      ),
    );
    await show(0);
    scroll.jumpTo(600);
    await show(1);
    await tester.pumpAndSettle();
    await show(0);
    await tester.pumpAndSettle();
    expect(scroll.offset, 600);
    await show(0);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      navigatorContainerBuilder: (_, shell, children) =>
          AnimatedBranchContainer(currentIndex: shell.currentIndex, children: children),
      builder: (_, _, shell) => Scaffold(
        body: shell,
        bottomNavigationBar: Row(
          children: [
            for (final (index, name) in ['home', 'settings', 'profile'].indexed)
              Expanded(child: TextButton(onPressed: () => shell.goBranch(index), child: Text('$name tab'))),
          ],
        ),
      ),
      branches: [
        for (final name in ['home', 'settings', 'profile'])
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/$name',
                builder: (_, _) => Scaffold(body: Text('$name page')),
                routes: [
                  GoRoute(
                    path: 'details',
                    builder: (_, _) => const Scaffold(body: TextField()),
                  ),
                ],
              ),
            ],
          ),
      ],
    ),
  ],
);
