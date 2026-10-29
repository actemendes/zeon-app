import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class SettingText extends ConsumerWidget {
  const SettingText({
    super.key,
    required this.title,
    required this.value,
    required this.setValue,
    this.defaultValue,
    this.validator,
    this.icon,
  });

  final String title;
  final String value;
  final Function(String value) setValue;
  final String? defaultValue;
  final FormFieldValidator<String>? validator;
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return SettingsTile(
      title: Text(title),
      subtitle: Text(value.isEmpty ? t.common.empty : value),
      leading: icon != null ? Icon(icon) : null,
      onTap: () async {
        final result = await ref
            .read(dialogNotifierProvider.notifier)
            .showSettingText(lable: title, value: value, defaultValue: defaultValue, validator: validator);
        if (result is String) setValue(result);
      },
    );
  }
}
