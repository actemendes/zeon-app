import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/theme/app_color_tokens.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';

const Color _lightBackground = AppColorTokens.lightBackground;
const Color _lightSurfaceAlt = AppColorTokens.lightSurfaceAlt;
const Color _lightAccentPrimary = Color(0xFF3CE74F);
const Color _lightAccentSecondary = Color(0xFFBFDD71);
const Color _lightText = Color(0xFF3B444D);
const Color _lightNavigationIndicator = Color(0xFF586972);

const Color _darkBackground = AppColorTokens.darkBackground;
const Color _darkSurfaceAlt = AppColorTokens.darkSurfaceAlt;
const Color _darkAccentPrimary = Color(0xFF3CE74F);
const Color _darkAccentSecondary = Color(0xFFBFDD71);
const Color _darkText = Color(0xFFD8DEE6);
const Color _darkNavigationIndicator = Color(0xFF333333);

const ColorScheme _lightColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: _lightAccentPrimary,
  onPrimary: Color(0xFF091B0D),
  primaryContainer: _lightAccentSecondary,
  onPrimaryContainer: _lightText,
  secondary: _lightAccentSecondary,
  onSecondary: Color(0xFF1E2429),
  secondaryContainer: _lightSurfaceAlt,
  onSecondaryContainer: _lightText,
  tertiary: _lightAccentSecondary,
  onTertiary: Color(0xFF1E2429),
  tertiaryContainer: _lightSurfaceAlt,
  onTertiaryContainer: _lightText,
  error: Color(0xFFB3261E),
  onError: Colors.white,
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  background: _lightBackground,
  onBackground: _lightText,
  surface: _lightBackground,
  onSurface: _lightText,
  surfaceVariant: _lightSurfaceAlt,
  onSurfaceVariant: _lightText,
  outline: Color(0xFF6A757E),
  outlineVariant: _lightSurfaceAlt,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: _lightText,
  onInverseSurface: _lightBackground,
  inversePrimary: _lightAccentSecondary,
);

const ColorScheme _darkColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: _darkAccentPrimary,
  onPrimary: Color(0xFF001A05),
  primaryContainer: _darkAccentSecondary,
  onPrimaryContainer: _darkSurfaceAlt,
  secondary: _darkAccentSecondary,
  onSecondary: _darkSurfaceAlt,
  secondaryContainer: _darkSurfaceAlt,
  onSecondaryContainer: _darkText,
  tertiary: _darkAccentSecondary,
  onTertiary: _darkSurfaceAlt,
  tertiaryContainer: _darkSurfaceAlt,
  onTertiaryContainer: _darkText,
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  errorContainer: Color(0xFF8C1D18),
  onErrorContainer: Color(0xFFF9DEDC),
  background: _darkBackground,
  onBackground: _darkText,
  surface: _darkBackground,
  onSurface: _darkText,
  surfaceVariant: _darkSurfaceAlt,
  onSurfaceVariant: _darkText,
  outline: Color(0xFF4D5058),
  outlineVariant: _darkSurfaceAlt,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: _darkText,
  onInverseSurface: _darkBackground,
  inversePrimary: _darkAccentPrimary,
);

class AppTheme {
  AppTheme(this.mode, this.fontFamily);
  static const String headingFontFamily = "Unbounded";

  final AppThemeMode mode;
  final String fontFamily;

  ThemeData lightTheme(ColorScheme? _) {
    return _buildThemeData(
      scheme: _lightColorScheme,
      navBarColor: _lightText,
      navBarSelectedColor: _lightAccentPrimary,
      navBarUnselectedColor: _lightBackground.withValues(alpha: .82),
      navBarIndicatorColor: _lightNavigationIndicator,
    );
  }

  ThemeData darkTheme(ColorScheme? _) {
    return _buildThemeData(
      scheme: _darkColorScheme,
      navBarColor: _darkSurfaceAlt,
      navBarSelectedColor: _darkAccentPrimary,
      navBarUnselectedColor: _darkText.withValues(alpha: .82),
      navBarIndicatorColor: _darkNavigationIndicator,
    );
  }

  CupertinoThemeData cupertinoThemeData(bool sysDark, ColorScheme? lightColorScheme, ColorScheme? darkColorScheme) {
    final bool isDark = switch (mode) {
      AppThemeMode.system => sysDark,
      AppThemeMode.light => false,
      AppThemeMode.dark => true,
    };
    final def = CupertinoThemeData(brightness: isDark ? Brightness.dark : Brightness.light);
    // final def = CupertinoThemeData(brightness: Brightness.dark);

    // return def;
    final defaultMaterialTheme = isDark ? darkTheme(darkColorScheme) : lightTheme(lightColorScheme);
    return MaterialBasedCupertinoThemeData(
      materialTheme: defaultMaterialTheme.copyWith(
        cupertinoOverrideTheme: def.copyWith(
          textTheme: CupertinoTextThemeData(
            textStyle: def.textTheme.textStyle.copyWith(fontFamily: fontFamily),
            actionTextStyle: def.textTheme.actionTextStyle.copyWith(fontFamily: fontFamily),
            navActionTextStyle: def.textTheme.navActionTextStyle.copyWith(fontFamily: fontFamily),
            navTitleTextStyle: def.textTheme.navTitleTextStyle.copyWith(fontFamily: fontFamily),
            navLargeTitleTextStyle: def.textTheme.navLargeTitleTextStyle.copyWith(fontFamily: fontFamily),
            pickerTextStyle: def.textTheme.pickerTextStyle.copyWith(fontFamily: fontFamily),
            dateTimePickerTextStyle: def.textTheme.dateTimePickerTextStyle.copyWith(fontFamily: fontFamily),
            tabLabelTextStyle: def.textTheme.tabLabelTextStyle.copyWith(fontFamily: fontFamily),
          ).copyWith(),
          barBackgroundColor: def.barBackgroundColor,
          scaffoldBackgroundColor: def.scaffoldBackgroundColor,
        ),
      ),
    );
  }

  ThemeData _buildThemeData({
    required ColorScheme scheme,
    required Color navBarColor,
    required Color navBarSelectedColor,
    required Color navBarUnselectedColor,
    required Color navBarIndicatorColor,
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    final statusBarIconBrightness = isDark ? Brightness.light : Brightness.dark;
    final statusBarBrightness = isDark ? Brightness.dark : Brightness.light;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.background,
      fontFamily: fontFamily,
      extensions: const <ThemeExtension<dynamic>>{ConnectionButtonTheme.light},
    );
    final textTheme = _withHeadingFont(
      base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
        decorationColor: scheme.onSurface,
      ),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.background,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: statusBarIconBrightness,
          statusBarBrightness: statusBarBrightness,
          systemNavigationBarColor: scheme.background,
          systemNavigationBarIconBrightness: statusBarIconBrightness,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: navBarColor,
        indicatorColor: navBarIndicatorColor,
        surfaceTintColor: Colors.transparent,
        iconTheme: MaterialStateProperty.resolveWith((states) {
          final color = states.contains(MaterialState.selected) ? navBarSelectedColor : navBarUnselectedColor;
          return IconThemeData(color: color);
        }),
        labelTextStyle: MaterialStateProperty.resolveWith((states) {
          final color = states.contains(MaterialState.selected) ? navBarSelectedColor : navBarUnselectedColor;
          return textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: states.contains(MaterialState.selected) ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navBarColor,
        indicatorColor: navBarIndicatorColor,
        selectedIconTheme: IconThemeData(color: navBarSelectedColor),
        unselectedIconTheme: IconThemeData(color: navBarUnselectedColor),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: navBarSelectedColor,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: navBarUnselectedColor,
          fontWeight: FontWeight.w500,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurface,
        textColor: scheme.onSurface,
        selectedColor: scheme.onSurface,
        selectedTileColor: scheme.secondaryContainer,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected) && scheme.brightness == Brightness.light) {
            return navBarColor;
          }
          return null;
        }),
        trackColor: MaterialStateProperty.resolveWith((states) {
          if (!states.contains(MaterialState.selected)) {
            return scheme.brightness == Brightness.light ? _lightSurfaceAlt : _darkSurfaceAlt;
          }
          return null;
        }),
        trackOutlineColor: const MaterialStatePropertyAll<Color>(Colors.transparent),
        trackOutlineWidth: const MaterialStatePropertyAll<double>(0),
      ),
      dividerColor: scheme.outlineVariant,
      cardColor: scheme.surface,
    );
  }

  TextTheme _withHeadingFont(TextTheme textTheme) {
    return textTheme.copyWith(
      displayLarge: _headingStyle(textTheme.displayLarge),
      displayMedium: _headingStyle(textTheme.displayMedium),
      displaySmall: _headingStyle(textTheme.displaySmall),
      headlineLarge: _headingStyle(textTheme.headlineLarge),
      headlineMedium: _headingStyle(textTheme.headlineMedium),
      headlineSmall: _headingStyle(textTheme.headlineSmall),
      titleLarge: _titleStyle(textTheme.titleLarge),
      titleMedium: _titleStyle(textTheme.titleMedium),
      titleSmall: _headingStyle(textTheme.titleSmall),
    );
  }

  TextStyle? _headingStyle(TextStyle? style) => style?.copyWith(fontFamily: headingFontFamily);

  TextStyle? _titleStyle(TextStyle? style) => style?.copyWith(fontFamily: headingFontFamily, fontSize: 18);
}
