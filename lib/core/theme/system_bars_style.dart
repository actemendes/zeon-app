import 'package:flutter/services.dart';

/// System-bar foreground styling for ZEON's edge-to-edge surfaces.
///
/// The application paints every system-bar background in Flutter. Keeping the
/// color fields null is intentional: it prevents Flutter's Android embedding
/// from requesting the deprecated Window color APIs while retaining readable
/// status- and navigation-bar icons.
SystemUiOverlayStyle systemBarsStyleFor(Brightness brightness) {
  final iconBrightness = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarIconBrightness: iconBrightness,
    statusBarBrightness: brightness,
    systemNavigationBarIconBrightness: iconBrightness,
  );
}

/// Foreground style for a surface drawn specifically behind the navigation bar.
SystemUiOverlayStyle navigationBarStyleFor(Brightness brightness) {
  return SystemUiOverlayStyle(
    systemNavigationBarIconBrightness: brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  );
}
