import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/locale_extensions.dart';
import 'package:zeon/core/localization/translation_context.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_provider.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_editor.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_page.dart';
import 'package:zeon/gen/translations.g.dart';

class _SavedAppearance extends ButtonAppearanceNotifier {
  @override
  Future<ButtonAppearance> build() async => const ButtonAppearance(preset: ButtonPreset.kawaii);
}

void main() {
  final catalogs = <AppLocale, Translations>{};
  final base =
      (jsonDecode(File('assets/translations/en.i18n.json').readAsStringSync()) as Map)['buttonAppearance'] as Map;
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      catalogs[locale] = await loadTranslations(locale);
    }
    for (final entry in jsonDecode(await rootBundle.loadString('FontManifest.json')) as List) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final item in font['fonts'] as List) {
        final asset = item as Map<String, dynamic>;
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
    // flutter_tester has no OS font fallback. Supply the host fonts in this
    // fixture so previews also exercise Arabic shaping and Chinese glyphs.
    if (Platform.isWindows) {
      for (final (family, fileName) in [
        ('Arial', 'arial.ttf'),
        ('Microsoft YaHei', 'msyh.ttc'),
        ('Microsoft JhengHei', 'msjh.ttc'),
      ]) {
        final file = File('${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/$fileName');
        if (await file.exists()) {
          await (FontLoader(family)..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
        }
      }
    }
  });

  for (final locale in AppLocale.values) {
    final tag = locale.languageTag;
    test('$tag explicitly translates every button string', () {
      final file = File('assets/translations/$tag.i18n.json');
      final section = (jsonDecode(file.readAsStringSync()) as Map)['buttonAppearance'] as Map;
      expect(section.keys.toSet(), base.keys.toSet());
      expect(section.length, 32);
      for (final entry in section.entries) {
        expect((entry.value as String).trim(), isNotEmpty, reason: '$tag:${entry.key}');
        if (locale != AppLocale.ru) {
          expect(RegExp('[А-Яа-яЁё]').hasMatch(entry.value as String), isFalse);
        }
      }
    });

    for (final scale in [1.0, 1.6]) {
      testWidgets('$tag menu/editor/crop at text scale $scale', (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final t = catalogs[locale]!;
        final theme = AppTheme(AppThemeMode.light, locale.preferredFontFamily).lightTheme(null);
        const fallback = ['Shabnam', 'Arial', 'Microsoft YaHei', 'Microsoft JhengHei'];
        Widget app(Widget child) => ProviderScope(
          overrides: [buttonAppearanceProvider.overrideWith(_SavedAppearance.new)],
          child: MaterialApp(
            locale: locale.flutterLocale,
            supportedLocales: AppLocale.values.map((l) => l.flutterLocale).toList(),
            localizationsDelegates: const [InterfaceTranslationsDelegate(), ...GlobalMaterialLocalizations.delegates],
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamilyFallback: fallback),
              appBarTheme: theme.appBarTheme.copyWith(
                titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamilyFallback: fallback),
              ),
              listTileTheme: theme.listTileTheme.copyWith(
                titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(fontFamilyFallback: fallback),
                subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(fontFamilyFallback: fallback),
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: child,
          ),
        );
        await tester.pumpWidget(app(const Scaffold(body: ButtonAppearancePrefTile())));
        await tester.pumpAndSettle();
        expect(find.text(t.buttonAppearance.title), findsOneWidget);
        expect(find.text(t.buttonAppearance.kawaii), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(app(ButtonAppearanceEditor(onSave: (_) async {}, animate: false)));
        await tester.pumpAndSettle();
        expect(find.text(t.buttonAppearance.title), findsOneWidget);
        expect(find.text(t.buttonAppearance.standard), findsOneWidget);
        expect(
          Directionality.of(tester.element(find.byType(ButtonAppearanceEditor))),
          [AppLocale.ar, AppLocale.fa].contains(locale) ? TextDirection.rtl : TextDirection.ltr,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('preset-custom')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('preset-name')),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        final field = tester.widget<TextField>(find.byKey(const ValueKey('preset-name')));
        expect(field.controller!.text, t.buttonAppearance.defaultName);
        await tester.drag(find.byType(ListView), const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(find.text(t.buttonAppearance.yourImages), findsOneWidget);
        expect(tester.widget<Text>(find.text('0 / 3')).textDirection, TextDirection.ltr);
        expect(find.byKey(const ValueKey('slot-connected')), findsOneWidget);
        expect(tester.takeException(), isNull);

        final evidence = Platform.environment['ZEON_BUTTON_LOCALE_EVIDENCE'];
        if (evidence != null && scale == 1) {
          final boundary = tester.renderObject(find.byType(RepaintBoundary).first) as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(evidence).create(recursive: true);
            await File('$evidence/$tag-editor.png').writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(
          app(
            const Scaffold(
              body: PictureCropDialog(
                picture: ButtonPicture(AssetImage('assets/images/button_presets/kawaii-idle.png')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(t.buttonAppearance.cropTitle), findsOneWidget);
        await tester.ensureVisible(find.text(t.buttonAppearance.done));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
