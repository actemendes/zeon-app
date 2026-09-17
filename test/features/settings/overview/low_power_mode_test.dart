import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/settings/overview/sections/general_page.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

import '../../ui/approved_interface_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  for (final light in [false, true]) {
    for (final size in [const Size(320, 740), const Size(1000, 800)]) {
      testWidgets('low power switch applies in general settings ($light, $size)', (tester) async {
        final container = await fixtures.pumpPage(
          tester,
          const GeneralPage(),
          size: size,
          scale: size.width == 320 ? 1.3 : 1,
          light: light,
        );
        final tile = find.byKey(const ValueKey('settings_low_power_mode'));
        await tester.ensureVisible(tile);
        expect(tester.widget<SettingsSwitch>(tile).value, isFalse);
        await tester.tap(find.descendant(of: tile, matching: find.text('Слабое устройство')));
        await tester.pumpAndSettle();
        expect(container.read(Preferences.lowPowerMode), isTrue);
        expect(tester.widget<SettingsSwitch>(tile).value, isTrue);
        expect(tester.takeException(), isNull);
        await fixtures.capture(tester, 'low-power-${light ? 'light' : 'dark'}-${size.width.toInt()}');
        await tester.tap(find.descendant(of: tile, matching: find.text('Слабое устройство')));
        await tester.pumpAndSettle();
        expect(container.read(Preferences.lowPowerMode), isFalse);
      });
    }
  }
}
