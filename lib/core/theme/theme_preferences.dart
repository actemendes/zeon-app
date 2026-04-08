import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'theme_preferences.g.dart';

@Riverpod(keepAlive: true)
class ThemePreferences extends _$ThemePreferences {
  @override
  AppThemeMode build() {
    final persisted = ref.watch(sharedPreferencesProvider).requireValue.getString("theme_mode");
    if (persisted == null) return AppThemeMode.system;
    if (persisted == "black") return AppThemeMode.dark;
    return AppThemeMode.values.firstWhere(
      (mode) => mode.name == persisted,
      orElse: () => AppThemeMode.system,
    );
  }

  Future<void> changeThemeMode(AppThemeMode value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).requireValue.setString("theme_mode", value.name);
  }
}
