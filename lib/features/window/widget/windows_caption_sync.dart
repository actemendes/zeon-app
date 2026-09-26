import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/utils/platform_utils.dart';

@immutable
class WindowsCaptionStyle {
  const WindowsCaptionStyle({required this.background, required this.foreground, required this.dark});

  factory WindowsCaptionStyle.fromTheme(ThemeData theme) => WindowsCaptionStyle(
    background: theme.colorScheme.surface,
    foreground: theme.colorScheme.onSurface,
    dark: theme.brightness == Brightness.dark,
  );

  factory WindowsCaptionStyle.fromMode(AppThemeMode mode, Brightness systemBrightness) {
    final theme = AppTheme(mode, 'Montserrat');
    final isDark = switch (mode) {
      AppThemeMode.system => systemBrightness == Brightness.dark,
      AppThemeMode.light => false,
      AppThemeMode.dark || AppThemeMode.amoled => true,
    };
    return WindowsCaptionStyle.fromTheme(isDark ? theme.darkTheme(null) : theme.lightTheme(null));
  }

  final Color background;
  final Color foreground;
  final bool dark;

  Map<String, Object> get channelArguments => {
    'background': background.toARGB32(),
    'foreground': foreground.toARGB32(),
    'dark': dark,
  };

  @override
  bool operator ==(Object other) =>
      other is WindowsCaptionStyle &&
      background == other.background &&
      foreground == other.foreground &&
      dark == other.dark;

  @override
  int get hashCode => Object.hash(background, foreground, dark);
}

const _captionChannel = MethodChannel('zeon/window_caption');

Future<void> applyWindowsCaptionStyle(WindowsCaptionStyle style) async {
  try {
    await _captionChannel.invokeMethod<void>('setCaptionAppearance', style.channelArguments);
  } on MissingPluginException {
    // Native Runner support is absent in Flutter widget tests.
  } on PlatformException catch (error) {
    debugPrint('Unable to update Windows caption: ${error.code}');
  }
}

/// Reapply the native caption whenever Flutter selects a different theme.
class WindowsCaptionSync extends StatefulWidget {
  const WindowsCaptionSync({super.key, required this.style, required this.child});

  final WindowsCaptionStyle style;
  final Widget child;

  @override
  State<WindowsCaptionSync> createState() => _WindowsCaptionSyncState();
}

class _WindowsCaptionSyncState extends State<WindowsCaptionSync> {
  @override
  void initState() {
    super.initState();
    _schedule(widget.style);
  }

  @override
  void didUpdateWidget(WindowsCaptionSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) _schedule(widget.style);
  }

  void _schedule(WindowsCaptionStyle next) {
    if (!PlatformUtils.isWindows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.style == next) unawaited(applyWindowsCaptionStyle(next));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
