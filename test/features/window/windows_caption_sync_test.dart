import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/theme/app_color_tokens.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/window/widget/windows_caption_sync.dart';

void main() {
  test('caption colors follow all app themes and system brightness', () {
    for (final (mode, brightness, background) in [
      (AppThemeMode.light, Brightness.dark, AppColorTokens.lightBackground),
      (AppThemeMode.dark, Brightness.light, AppColorTokens.darkBackground),
      (AppThemeMode.amoled, Brightness.light, AppColorTokens.amoledBackground),
      (AppThemeMode.system, Brightness.light, AppColorTokens.lightBackground),
      (AppThemeMode.system, Brightness.dark, AppColorTokens.darkBackground),
    ]) {
      final style = WindowsCaptionStyle.fromMode(mode, brightness);
      expect(style.background, background);
      expect(style.dark, background != AppColorTokens.lightBackground);
    }
  });

  testWidgets('native caption receives the resolved theme after each change', (tester) async {
    const channel = MethodChannel('zeon/window_caption');
    final calls = <Map<String, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setCaptionAppearance');
      calls.add(Map<String, Object?>.from(call.arguments as Map));
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final light = AppTheme(AppThemeMode.light, 'Montserrat').lightTheme(null);
    final graphite = AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null);
    await tester.pumpWidget(
      MaterialApp(
        theme: light,
        home: WindowsCaptionSync(style: WindowsCaptionStyle.fromTheme(light), child: const SizedBox()),
      ),
    );
    await tester.pump();
    expect(calls.last['background'], AppColorTokens.lightBackground.toARGB32());
    expect(calls.last['foreground'], light.colorScheme.onSurface.toARGB32());
    expect(calls.last['dark'], isFalse);

    await tester.pumpWidget(
      MaterialApp(
        theme: graphite,
        home: WindowsCaptionSync(style: WindowsCaptionStyle.fromTheme(graphite), child: const SizedBox()),
      ),
    );
    await tester.pump();
    expect(calls.last['background'], AppColorTokens.darkBackground.toARGB32());
    expect(calls.last['foreground'], graphite.colorScheme.onSurface.toARGB32());
    expect(calls.last['dark'], isTrue);
    expect(calls.length, 2);
  });
}
