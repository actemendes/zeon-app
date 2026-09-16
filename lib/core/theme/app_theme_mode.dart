import 'package:flutter/material.dart';
import 'package:zeon/core/localization/translations.dart';

enum AppThemeMode {
  system,
  light,
  dark,
  amoled;

  static AppThemeMode fromStored(String? value) {
    if (value == 'black') return amoled;
    return values.firstWhere((mode) => mode.name == value, orElse: () => system);
  }

  String present(TranslationsEn t) => switch (this) {
    system => t.pages.settings.general.themeModes.system,
    light => t.pages.settings.general.themeModes.light,
    dark => t.pages.settings.general.themeModes.graphite,
    amoled => t.pages.settings.general.themeModes.amoled,
  };

  ThemeMode get flutterThemeMode => switch (this) {
    system => ThemeMode.system,
    light => ThemeMode.light,
    dark || amoled => ThemeMode.dark,
  };
}
