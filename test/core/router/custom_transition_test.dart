import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zeon/core/router/go_router/helper/custom_transition.dart';
import 'package:zeon/core/widget/app_visual_effects.dart';

void main() {
  for (final initiallyReduced in [false, true]) {
    testWidgets('live motion toggle updates pop delay without losing input ($initiallyReduced)', (tester) async {
      final reduced = ValueNotifier(initiallyReduced);
      addTearDown(reduced.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(),
            routes: [
              GoRoute(
                path: 'settings',
                pageBuilder: (context, state) => customTransition(
                  TransitionType.slide,
                  state.pageKey,
                  const Scaffold(body: TextField()),
                  reduceMotion: MediaQuery.disableAnimationsOf(context),
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: reduced,
          builder: (_, value, _) => MaterialApp.router(
            routerConfig: router,
            builder: (_, child) => AppVisualEffects(lowPowerMode: value, child: child!),
          ),
        ),
      );
      router.push<void>('/settings');
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'preserve input');
      final originalRoute = ModalRoute.of(tester.element(field))!;
      FocusManager.instance.primaryFocus?.unfocus();
      reduced.value = !initiallyReduced;
      await tester.pumpAndSettle();
      expect(find.text('preserve input'), findsOneWidget);
      expect(ModalRoute.of(tester.element(field)), same(originalRoute));
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      if (initiallyReduced) {
        expect(originalRoute.animation!.value, greaterThan(0));
        await tester.pumpAndSettle();
      } else {
        expect(field, findsNothing);
      }
    });
  }
  test('low power route has no forward or reverse animation delay', () {
    final page = customTransition(
      TransitionType.slide,
      const ValueKey('test'),
      const SizedBox.shrink(),
      reduceMotion: true,
    );
    expect(page.transitionDuration, Duration.zero);
    expect(page.reverseTransitionDuration, Duration.zero);
  });
  testWidgets('route transitions remain visible and use eased motion', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (builderContext) {
            context = builderContext;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final page = customTransition(TransitionType.slide, const ValueKey('test'), const SizedBox.shrink());
    expect(page.transitionDuration, const Duration(milliseconds: 280));
    expect(page.reverseTransitionDuration, const Duration(milliseconds: 220));

    final transition =
        page.transitionsBuilder(
              context,
              const AlwaysStoppedAnimation<double>(0.5),
              const AlwaysStoppedAnimation<double>(0.5),
              const SizedBox.shrink(),
            )
            as SlideTransition;
    expect(transition.position.value.dx, lessThan(0.5));
  });
}
