import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';

enum AppThemeMode {
  system,
  light,
  dark;

  String present(TranslationsEn t) => switch (this) {
    system => t.pages.settings.general.themeModes.system,
    light => t.pages.settings.general.themeModes.light,
    dark => t.pages.settings.general.themeModes.dark,
  };

  ThemeMode get flutterThemeMode => switch (this) {
    system => ThemeMode.system,
    light => ThemeMode.light,
    dark => ThemeMode.dark,
  };
}
