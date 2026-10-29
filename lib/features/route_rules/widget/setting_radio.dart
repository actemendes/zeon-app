import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class SettingRadio<T> extends ConsumerWidget {
  const SettingRadio({
    super.key,
    required this.title,
    required this.values,
    required this.value,
    required this.setValue,
    this.defaultValue,
    this.t,
    this.icon,
  });

  final String title;
  final List<T> values;
  final T value;
  final Function(T value) setValue;
  final T? defaultValue;
  final Map<String, String>? t;
  final IconData? icon;

  String textWithTranslation(T e) {
    if (t == null) return '$e';
    return t!['$e'] ?? '$e';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsTile(
      title: Text(title),
      subtitle: Text(textWithTranslation(value)),
      leading: icon != null ? Icon(icon) : null,
      onTap: () async {
        final result = await ref
            .read(dialogNotifierProvider.notifier)
            .showSettingRadio<T>(title: title, values: values, value: value, defaultValue: defaultValue, t: t);
        if (result is T) setValue(result);
      },
    );
  }
}
