import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/theme/system_bars_style.dart';

void main() {
  group('systemBarsStyleFor', () {
    test('keeps all deprecated Android color requests unset', () {
      for (final brightness in Brightness.values) {
        final style = systemBarsStyleFor(brightness);

        expect(style.statusBarColor, isNull);
        expect(style.systemNavigationBarColor, isNull);
        expect(style.systemNavigationBarDividerColor, isNull);
      }
    });

    test('uses contrasting status and navigation icons', () {
      final light = systemBarsStyleFor(Brightness.light);
      final dark = systemBarsStyleFor(Brightness.dark);

      expect(light.statusBarIconBrightness, Brightness.dark);
      expect(light.systemNavigationBarIconBrightness, Brightness.dark);
      expect(dark.statusBarIconBrightness, Brightness.light);
      expect(dark.systemNavigationBarIconBrightness, Brightness.light);
    });

    test('navigation surface styling also remains color-free', () {
      final style = navigationBarStyleFor(Brightness.dark);

      expect(style.statusBarColor, isNull);
      expect(style.systemNavigationBarColor, isNull);
      expect(style.systemNavigationBarDividerColor, isNull);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    });
  });

  group('Android edge-to-edge resources', () {
    test('API 35 themes do not declare legacy system-bar colors', () {
      for (final path in <String>[
        'android/app/src/main/res/values-v35/styles.xml',
        'android/app/src/main/res/values-night-v35/styles.xml',
      ]) {
        final xml = File(path).readAsStringSync();

        expect(xml, isNot(contains('statusBarColor')));
        expect(xml, isNot(contains('navigationBarColor')));
        expect(xml, isNot(contains('navigationBarDividerColor')));
        expect(xml, isNot(contains('windowOptOutEdgeToEdgeEnforcement')));
      }
    });

    test('pre-35 compatibility themes request transparent surfaces', () {
      for (final path in <String>[
        'android/app/src/main/res/values/styles.xml',
        'android/app/src/main/res/values-night/styles.xml',
        'android/app/src/main/res/values-v31/styles.xml',
        'android/app/src/main/res/values-night-v31/styles.xml',
      ]) {
        final xml = File(path).readAsStringSync();

        expect(xml, contains('<item name="android:statusBarColor">@android:color/transparent</item>'));
        expect(xml, contains('<item name="android:navigationBarColor">@android:color/transparent</item>'));
        expect(xml, isNot(contains('navigationBarDividerColor')));
      }
    });
  });
}
