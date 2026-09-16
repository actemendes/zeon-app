import 'package:flutter/material.dart';
import 'package:zeon/core/theme/app_color_tokens.dart';

/// Home visuals that differ between Graphite and AMOLED at the same brightness.
class HomeVisualTheme extends ThemeExtension<HomeVisualTheme> {
  const HomeVisualTheme({
    required this.mapDotColor,
    required this.connectionLogoColor,
    required this.premiumTrackColor,
    required this.idleOpacity,
    required this.loadingOpacity,
  });

  final Color mapDotColor;
  final Color connectionLogoColor;
  final Color premiumTrackColor;
  final double idleOpacity;
  final double loadingOpacity;

  static const light = HomeVisualTheme(
    mapDotColor: AppColorTokens.lightMapDots,
    connectionLogoColor: AppColorTokens.lightText,
    premiumTrackColor: AppColorTokens.lightSurfaceAlt,
    idleOpacity: .85,
    loadingOpacity: .92,
  );
  static const graphite = HomeVisualTheme(
    mapDotColor: AppColorTokens.darkMapDots,
    connectionLogoColor: Color(0xFFD8DEE6),
    premiumTrackColor: AppColorTokens.darkMapDots,
    idleOpacity: .65,
    loadingOpacity: .8,
  );
  static const amoled = HomeVisualTheme(
    mapDotColor: Color(0xFF181818),
    connectionLogoColor: Colors.white,
    premiumTrackColor: Color(0xFF26292F),
    idleOpacity: .45,
    loadingOpacity: .7,
  );

  @override
  HomeVisualTheme copyWith({
    Color? mapDotColor,
    Color? connectionLogoColor,
    Color? premiumTrackColor,
    double? idleOpacity,
    double? loadingOpacity,
  }) => HomeVisualTheme(
    mapDotColor: mapDotColor ?? this.mapDotColor,
    connectionLogoColor: connectionLogoColor ?? this.connectionLogoColor,
    premiumTrackColor: premiumTrackColor ?? this.premiumTrackColor,
    idleOpacity: idleOpacity ?? this.idleOpacity,
    loadingOpacity: loadingOpacity ?? this.loadingOpacity,
  );

  @override
  HomeVisualTheme lerp(covariant HomeVisualTheme? other, double t) {
    if (other == null) return this;
    return HomeVisualTheme(
      mapDotColor: Color.lerp(mapDotColor, other.mapDotColor, t)!,
      connectionLogoColor: Color.lerp(connectionLogoColor, other.connectionLogoColor, t)!,
      premiumTrackColor: Color.lerp(premiumTrackColor, other.premiumTrackColor, t)!,
      idleOpacity: idleOpacity + (other.idleOpacity - idleOpacity) * t,
      loadingOpacity: loadingOpacity + (other.loadingOpacity - loadingOpacity) * t,
    );
  }
}

class ConnectionButtonTheme extends ThemeExtension<ConnectionButtonTheme> {
  const ConnectionButtonTheme({this.idleColor, this.connectedColor});

  final Color? idleColor;
  final Color? connectedColor;

  static const ConnectionButtonTheme light = ConnectionButtonTheme(
    idleColor: Color(0xFFBFDD71),
    connectedColor: Color(0xFF3CE74F),
  );

  @override
  ThemeExtension<ConnectionButtonTheme> copyWith({Color? idleColor, Color? connectedColor}) => ConnectionButtonTheme(
    idleColor: idleColor ?? this.idleColor,
    connectedColor: connectedColor ?? this.connectedColor,
  );

  @override
  ThemeExtension<ConnectionButtonTheme> lerp(covariant ThemeExtension<ConnectionButtonTheme>? other, double t) {
    if (other is! ConnectionButtonTheme) {
      return this;
    }
    return ConnectionButtonTheme(
      idleColor: Color.lerp(idleColor, other.idleColor, t),
      connectedColor: Color.lerp(connectedColor, other.connectedColor, t),
    );
  }
}
