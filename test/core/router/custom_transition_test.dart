import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/router/go_router/helper/custom_transition.dart';

void main() {
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
