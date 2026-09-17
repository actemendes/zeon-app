import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/no_active_profile_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/windows_network_help_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/gen/translations_ru.g.dart';

void main() {
  setUpAll(() async {
    for (final entry in jsonDecode(await rootBundle.loadString('FontManifest.json')) as List) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final entry in font['fonts'] as List) {
        final asset = entry as Map<String, dynamic>;
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
  });

  for (final (name, mode, size, scale) in [
    ('graphite', AppThemeMode.dark, const Size(840, 920), 1.0),
    ('silver', AppThemeMode.light, const Size(840, 920), 1.0),
    ('amoled', AppThemeMode.amoled, const Size(840, 920), 1.0),
    ('small-window', AppThemeMode.dark, const Size(460, 600), 1.0),
    ('large-text', AppThemeMode.light, const Size(600, 700), 1.6),
  ]) {
    testWidgets('$name: help remains readable and close is reachable', (tester) async {
      await _pump(tester, mode: mode, size: size, scale: scale);
      expect(find.byType(WindowsNetworkHelpDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      final folder = Platform.environment['ZEON_UI_EVIDENCE'];
      if (folder != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('capture')));
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(folder).create(recursive: true);
          await File('$folder/windows-network-help-$name.png').writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      final footer = find.text('После изменения настроек перезапустите ZEON.');
      await tester.ensureVisible(footer);
      await tester.pumpAndSettle();
      expect(tester.getRect(footer).bottom, lessThan(size.height));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(WindowsNetworkHelpDialog), findsNothing);
    });
  }

  testWidgets('all four actions open the intended external destinations', (tester) async {
    final opened = <Uri>[];
    await _pump(
      tester,
      openLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    for (final label in ['Как добавить исключение', 'Скачать Happ для Windows', 'Telegram ↗', 'ВКонтакте ↗']) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(opened, [
      WindowsNetworkHelpDialog.firewallUri,
      WindowsNetworkHelpDialog.happUri,
      WindowsNetworkHelpDialog.telegramUri,
      WindowsNetworkHelpDialog.vkUri,
    ]);
  });

  testWidgets('failed browser launch exposes a selectable fallback URL', (tester) async {
    await _pump(tester, openLink: (_) async => false);
    await tester.tap(find.text('Как добавить исключение'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, WindowsNetworkHelpDialog.firewallUri.toString()), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no-profile entry uses Windows help only on Windows', (tester) async {
    final container = ProviderContainer(overrides: [translationsProvider.overrideWith((_) => TranslationsRu())]);
    addTearDown(container.dispose);
    await container.read(translationsProvider.future);
    await _pump(
      tester,
      dialog: UncontrolledProviderScope(container: container, child: const NoActiveProfileDialog()),
    );
    expect(find.byType(WindowsNetworkHelpDialog), Platform.isWindows ? findsOneWidget : findsNothing);
  });

  testWidgets('English fallback has working layout', (tester) async {
    await _pump(tester, dialog: const WindowsNetworkHelpDialog(russian: false));
    expect(find.text('UNABLE TO CONNECT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  AppThemeMode mode = AppThemeMode.dark,
  Size size = const Size(840, 920),
  double scale = 1,
  Future<bool> Function(Uri)? openLink,
  Widget? dialog,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = AppTheme(mode, 'Montserrat');
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showZeonDialog<void>(
                  context,
                  dialog ?? WindowsNetworkHelpDialog(russian: true, openLink: openLink),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}
