import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/proxy/active/ip_widget.dart';
import 'package:zeon/utils/custom_loggers.dart';

class SettingPickerDialog<T> extends HookConsumerWidget with PresLogger {
  const SettingPickerDialog({
    super.key,
    required this.title,
    this.showFlag = false,
    required this.selected,
    required this.options,
    required this.getTitle,
    this.onReset,
  });

  final String title;
  final bool showFlag;
  final T selected;
  final List<T> options;
  final String Function(T e) getTitle;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return ZeonDialog(
      primaryAction: false,
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((e) {
            final title = getTitle(e);
            return DialogChoice(
              title: title,
              leading: e is AppThemeMode ? _themePreview(context, e) : _getSecondaryWidget(title),
              selected: e == selected,
              onTap: () => context.pop(e),
            );
          }).toList(),
        ),
      ),
      actions: [
        if (onReset != null)
          TextButton(
            onPressed: () {
              onReset!();
              context.pop();
            },
            child: Text(t.common.reset),
          ),
        TextButton(onPressed: () => context.pop(), child: Text(t.common.cancel)),
      ],
      // scrollable: true,
    );
  }

  Widget _themePreview(BuildContext context, AppThemeMode mode) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: switch (mode) {
          AppThemeMode.system => cs.secondaryContainer,
          AppThemeMode.light => const Color(0xffe2e6eb),
          AppThemeMode.dark => const Color(0xff252730),
          AppThemeMode.amoled => Colors.black,
        },
      ),
      child: Icon(
        switch (mode) {
          AppThemeMode.system => Icons.brightness_auto_rounded,
          AppThemeMode.light => Icons.light_mode_rounded,
          AppThemeMode.dark => Icons.dark_mode_rounded,
          AppThemeMode.amoled => Icons.nights_stay_rounded,
        },
        size: 18,
        color: mode == AppThemeMode.light ? const Color(0xff454d58) : cs.onSurfaceVariant,
      ),
    );
  }

  Widget? _getSecondaryWidget(String title) {
    if (!showFlag || title.isEmpty) return null;
    try {
      // Matches content inside parenthesis at the end of string, e.g. "US (US)" -> "US"
      final match = RegExp(r'\(([^)]+)\)$').firstMatch(title);
      final countryCode = match?.group(1);
      if (countryCode == null) return null;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: () {},
        child: IPCountryFlag(countryCode: countryCode, size: 32),
      );
    } catch (e) {
      return null;
    }
  }
}
