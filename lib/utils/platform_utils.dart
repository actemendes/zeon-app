import 'dart:io';

import 'package:flutter/foundation.dart';

abstract class PlatformUtils {
  static const _debugPlatformOverride = String.fromEnvironment("debug_platform_override");

  static bool get _hasDebugPlatformOverride => kIsWeb && kDebugMode && _debugPlatformOverride.isNotEmpty;

  static String? get _debugPlatform => _hasDebugPlatformOverride ? _debugPlatformOverride.toLowerCase() : null;

  static bool get isWindows => _debugPlatform == "windows" || (!kIsWeb && Platform.isWindows);

  static bool get isDesktop => !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  static bool get isInAppStore => _debugPlatform == "ios" || (!kIsWeb && Platform.isIOS);

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isWeb => kIsWeb;

  static bool get isLinux => _debugPlatform == "linux" || (!kIsWeb && Platform.isLinux);

  static bool get isMacOS => _debugPlatform == "macos" || (!kIsWeb && Platform.isMacOS);

  static bool get isIOS => _debugPlatform == "ios" || (!kIsWeb && Platform.isIOS);

  static bool get isApple => isIOS || isMacOS;

  static bool get isAndroid => _debugPlatform == "android" || (!kIsWeb && Platform.isAndroid);

  static String get operatingSystem => _debugPlatform ?? (kIsWeb ? "web" : Platform.operatingSystem);

  static String get operatingSystemVersion => _hasDebugPlatformOverride
      ? "debug web override ($_debugPlatformOverride)"
      : kIsWeb
      ? "web"
      : Platform.operatingSystemVersion;
}
