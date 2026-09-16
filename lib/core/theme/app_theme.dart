import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zeon/core/theme/app_color_tokens.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/theme/system_bars_style.dart';
import 'package:zeon/core/theme/theme_extensions.dart';

const Color _lightBackground = AppColorTokens.lightBackground;
const Color _lightSurfaceAlt = AppColorTokens.lightSurfaceAlt;
const Color _lightAccentPrimary = Color(0xFF3CE74F);
const Color _lightAccentSecondary = Color(0xFFBFDD71);
const Color _lightText = AppColorTokens.lightText;

const Color _amoledBackground = AppColorTokens.amoledBackground;
const Color _amoledSurfaceAlt = AppColorTokens.amoledSurfaceAlt;
const Color _darkAccentPrimary = Color(0xFF3CE74F);
const Color _darkAccentSecondary = Color(0xFFBFDD71);
const Color _darkText = Color(0xFFD8DEE6);
const Color _darkNavigationIndicator = Color(0xFF333333);

const ColorScheme _lightColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: _lightAccentPrimary,
  onPrimary: _lightText,
  primaryContainer: _lightAccentSecondary,
  onPrimaryContainer: _lightText,
  secondary: _lightAccentSecondary,
  onSecondary: _lightText,
  secondaryContainer: AppColorTokens.lightControlSurface,
  onSecondaryContainer: _lightText,
  tertiary: _lightAccentSecondary,
  onTertiary: _lightText,
  tertiaryContainer: _lightSurfaceAlt,
  onTertiaryContainer: _lightText,
  error: Color(0xFFB3261E),
  onError: Colors.white,
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  background: _lightBackground,
  onBackground: _lightText,
  surface: _lightBackground,
  surfaceDim: _lightBackground,
  surfaceBright: _lightBackground,
  surfaceContainerLowest: _lightBackground,
  surfaceContainerLow: _lightBackground,
  surfaceContainer: _lightSurfaceAlt,
  surfaceContainerHigh: _lightSurfaceAlt,
  surfaceContainerHighest: _lightSurfaceAlt,
  onSurface: _lightText,
  surfaceVariant: _lightSurfaceAlt,
  onSurfaceVariant: AppColorTokens.lightTextMuted,
  outline: Color(0xFF6A757E),
  outlineVariant: _lightSurfaceAlt,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: _lightText,
  onInverseSurface: _lightBackground,
  inversePrimary: _lightAccentSecondary,
);

const ColorScheme _amoledColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: _darkAccentPrimary,
  onPrimary: Color(0xFF001A05),
  primaryContainer: _darkAccentSecondary,
  onPrimaryContainer: _amoledSurfaceAlt,
  secondary: _darkAccentSecondary,
  onSecondary: _amoledSurfaceAlt,
  secondaryContainer: _amoledSurfaceAlt,
  onSecondaryContainer: _darkText,
  tertiary: _darkAccentSecondary,
  onTertiary: _amoledSurfaceAlt,
  tertiaryContainer: _amoledSurfaceAlt,
  onTertiaryContainer: _darkText,
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  errorContainer: Color(0xFF8C1D18),
  onErrorContainer: Color(0xFFF9DEDC),
  background: _amoledBackground,
  onBackground: _darkText,
  surface: _amoledBackground,
  onSurface: _darkText,
  surfaceVariant: _amoledSurfaceAlt,
  onSurfaceVariant: _darkText,
  outline: Color(0xFF4D5058),
  outlineVariant: _amoledSurfaceAlt,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: _darkText,
  onInverseSurface: _amoledBackground,
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
      navBarColor: _lightSurfaceAlt,
      navBarSelectedColor: _lightText,
      navBarUnselectedColor: AppColorTokens.lightTextMuted,
      navBarIndicatorColor: _lightAccentPrimary,
      homeVisualTheme: HomeVisualTheme.light,
    );
  }

  ThemeData darkTheme(ColorScheme? _) {
    if (mode != AppThemeMode.amoled) {
      return _buildThemeData(
        scheme: _amoledColorScheme.copyWith(
          background: AppColorTokens.darkBackground,
          surface: AppColorTokens.darkBackground,
          surfaceDim: AppColorTokens.darkBackground,
          surfaceBright: AppColorTokens.darkSurfaceAlt,
          surfaceContainerLowest: AppColorTokens.darkBackground,
          surfaceContainerLow: AppColorTokens.darkMapDots,
          surfaceContainer: AppColorTokens.darkSurfaceAlt,
          surfaceContainerHigh: AppColorTokens.darkSurfaceAlt,
          surfaceContainerHighest: AppColorTokens.darkSurfaceAlt,
          onSecondary: AppColorTokens.darkSurfaceAlt,
          onTertiary: AppColorTokens.darkSurfaceAlt,
          onPrimaryContainer: AppColorTokens.darkSurfaceAlt,
          secondaryContainer: AppColorTokens.darkSurfaceAlt,
          tertiaryContainer: AppColorTokens.darkSurfaceAlt,
          surfaceVariant: AppColorTokens.darkSurfaceAlt,
          onSurfaceVariant: AppColorTokens.darkTextMuted,
          outlineVariant: AppColorTokens.darkSurfaceAlt,
          onInverseSurface: AppColorTokens.darkBackground,
        ),
        navBarColor: AppColorTokens.darkSurfaceAlt,
        navBarSelectedColor: _darkAccentPrimary,
        navBarSelectedIconColor: AppColorTokens.amoledSurfaceAlt,
        navBarUnselectedColor: AppColorTokens.darkTextMuted,
        navBarIndicatorColor: _darkAccentPrimary,
        homeVisualTheme: HomeVisualTheme.graphite,
      );
    }
    return _buildThemeData(
      scheme: _amoledColorScheme,
      navBarColor: _amoledSurfaceAlt,
      navBarSelectedColor: _darkAccentPrimary,
      navBarUnselectedColor: _darkText.withValues(alpha: .82),
      navBarIndicatorColor: _darkNavigationIndicator,
      homeVisualTheme: HomeVisualTheme.amoled,
    );
  }

  CupertinoThemeData cupertinoThemeData(bool sysDark, ColorScheme? lightColorScheme, ColorScheme? darkColorScheme) {
    final bool isDark = switch (mode) {
      AppThemeMode.system => sysDark,
      AppThemeMode.light => false,
      AppThemeMode.dark || AppThemeMode.amoled => true,
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
            tabLabelTextStyle: def.textTheme.tabLabelTextStyle.copyWith(fontFamily: fontFamily, fontSize: 14),
          ).copyWith(),
          barBackgroundColor: defaultMaterialTheme.colorScheme.surface,
          scaffoldBackgroundColor: defaultMaterialTheme.scaffoldBackgroundColor,
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
    required HomeVisualTheme homeVisualTheme,
    Color? navBarSelectedIconColor,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.background,
      fontFamily: fontFamily,
      extensions: <ThemeExtension<dynamic>>{ConnectionButtonTheme.light, homeVisualTheme},
    );
    final textTheme = _withHeadingFont(
      _withReadableBody(
        base.textTheme,
      ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface, decorationColor: scheme.onSurface),
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: _withHeadingFont(_withReadableBody(base.primaryTextTheme)),
      iconTheme: scheme.brightness == Brightness.light ? IconThemeData(color: scheme.onSurface) : base.iconTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.background,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: systemBarsStyleFor(scheme.brightness),
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
          final color = states.contains(MaterialState.selected)
              ? (navBarSelectedIconColor ?? navBarSelectedColor)
              : navBarUnselectedColor;
          return IconThemeData(color: color);
        }),
        labelTextStyle: MaterialStateProperty.resolveWith((states) {
          final color = states.contains(MaterialState.selected) ? navBarSelectedColor : navBarUnselectedColor;
          return textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: states.contains(MaterialState.selected)
                ? (scheme.brightness == Brightness.light ? FontWeight.w700 : FontWeight.w600)
                : FontWeight.w600,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navBarColor,
        indicatorColor: navBarIndicatorColor,
        selectedIconTheme: IconThemeData(color: navBarSelectedIconColor ?? navBarSelectedColor),
        unselectedIconTheme: IconThemeData(color: navBarUnselectedColor),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: navBarSelectedColor,
          fontWeight: scheme.brightness == Brightness.light ? FontWeight.w700 : FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: navBarUnselectedColor,
          fontWeight: FontWeight.w600,
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
            return scheme.onPrimary;
          }
          return null;
        }),
        trackColor: MaterialStateProperty.resolveWith((states) {
          if (!states.contains(MaterialState.selected)) {
            return navBarColor;
          }
          return null;
        }),
        trackOutlineColor: const MaterialStatePropertyAll<Color>(Colors.transparent),
        trackOutlineWidth: const MaterialStatePropertyAll<double>(0),
      ),
      dividerColor: scheme.outlineVariant,
      cardColor: scheme.brightness == Brightness.light ? _lightSurfaceAlt : scheme.surface,
    );
  }

  TextTheme _withReadableBody(TextTheme theme) {
    TextStyle? readable(TextStyle? style, {double fallbackSize = 14}) {
      if (style == null) return null;
      final size = style.fontSize ?? fallbackSize;
      return style.copyWith(
        fontSize: size < 14 ? 14 : size,
        fontWeight: fontFamily == 'Montserrat' ? FontWeight.w600 : style.fontWeight,
      );
    }

    return theme.copyWith(
      bodyLarge: readable(theme.bodyLarge, fallbackSize: 16),
      bodyMedium: readable(theme.bodyMedium),
      bodySmall: readable(theme.bodySmall),
      labelLarge: readable(theme.labelLarge),
      labelMedium: readable(theme.labelMedium),
      labelSmall: readable(theme.labelSmall),
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
