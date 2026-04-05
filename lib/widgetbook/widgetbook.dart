// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/widgetbook/widgetbook.directories.g.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

@widgetbook.App()
class ZeonWidgetbook extends StatelessWidget {
  const ZeonWidgetbook({super.key});

  @override
  Widget build(BuildContext context) {
    final light = AppTheme(AppThemeMode.light, 'Shabnam').lightTheme(null);
    final dark = AppTheme(AppThemeMode.dark, 'Shabnam').darkTheme(null);

    return Widgetbook.material(
      directories: directories,
      addons: [
        GridAddon(8),
        TextScaleAddon(),
        LocalizationAddon(
          locales: const [Locale('en'), Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
        ),
        MaterialThemeAddon(
          themes: [
            WidgetbookTheme(name: 'Light', data: light),
            WidgetbookTheme(name: 'Dark', data: dark),
          ],
        ),
        ViewportAddon(const [
          Viewports.none,
          WindowsViewports.desktop,
          IosViewports.iPhone13,
          AndroidViewports.samsungGalaxyS20,
          IosViewports.iPadPro11Inches,
        ]),
      ],
    );
  }
}
