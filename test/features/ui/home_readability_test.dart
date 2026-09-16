import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/home/widget/home_connection_layout.dart';
import 'package:zeon/features/home/widget/home_page.dart';

import 'approved_interface_test.dart' as ui;

void main() {
  testWidgets('home does not scroll when its actual content fits', (tester) async {
    // Includes the extra Windows quick-settings row; the mobile-only layout is tested below.
    await ui.pumpPage(tester, const HomePage(), size: const Size(393, 680));
    final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(state.position.maxScrollExtent, 0);
    await tester.drag(find.byKey(const ValueKey('home_canvas')), const Offset(0, -150));
    await tester.pump();
    expect(state.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  for (final (height, statusHeight, footerHeight) in [(600.0, 44.0, 72.0), (480.0, 100.0, 144.0)]) {
    testWidgets('mobile content determines scrolling at $height', (tester) async {
      tester.view.physicalSize = Size(393, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: HomeConnectionLayout(
              viewportHeight: height,
              desktop: false,
              header: const SizedBox(key: ValueKey('header'), height: 100),
              dial: const SizedBox(key: ValueKey('dial'), width: 230, height: 230),
              status: SizedBox(key: const ValueKey('status'), height: statusHeight),
              footer: SizedBox(key: const ValueKey('footer'), height: footerHeight),
            ),
          ),
        ),
      );
      final state = tester.state<ScrollableState>(find.byType(Scrollable));
      if (height == 600) {
        expect(state.position.maxScrollExtent, 0);
        expect(tester.getCenter(find.byKey(const ValueKey('dial'))).dy, height / 2);
      } else {
        expect(state.position.maxScrollExtent, greaterThan(0));
      }
      expect(
        tester.getRect(find.byKey(const ValueKey('header'))).bottom,
        lessThan(tester.getRect(find.byKey(const ValueKey('dial'))).top),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('status'))).bottom,
        lessThan(tester.getRect(find.byKey(const ValueKey('footer'))).top),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('Montserrat body and labels use semibold and at least 14px in every palette', () {
    for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
      final app = AppTheme(mode, 'Montserrat');
      final theme = mode == AppThemeMode.light ? app.lightTheme(null) : app.darkTheme(null);
      for (final style in [
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.textTheme.labelMedium,
        theme.textTheme.labelSmall,
      ]) {
        expect(style?.fontWeight, FontWeight.w600);
        expect(style?.fontSize, greaterThanOrEqualTo(14));
      }
    }
  });
}
