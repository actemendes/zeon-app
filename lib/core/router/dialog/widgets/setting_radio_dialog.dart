import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';

class SettingRadioDialog<T> extends ConsumerWidget {
  const SettingRadioDialog({
    super.key,
    required this.title,
    required this.values,
    required this.value,
    this.defaultValue,
    this.t,
  });

  final String title;
  final List<T> values;
  final T value;
  final T? defaultValue;
  final Map<String, String>? t;

  String textWithTranslation(T e) {
    if (t == null) return '$e';
    return t!['$e'] ?? '$e';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return ZeonDialog(
      primaryAction: false,
      title: Text(title),
      content: ConstrainedBox(
        constraints: AlertDialogConst.boxConstraints,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: values
                .map(
                  (e) => DialogChoice(title: textWithTranslation(e), selected: e == value, onTap: () => context.pop(e)),
                )
                .toList(),
          ),
        ),
      ),
      actions: [
        if (defaultValue != null) TextButton(child: Text(t.common.reset), onPressed: () => context.pop(defaultValue)),
        TextButton(child: Text(t.common.cancel), onPressed: () => context.pop()),
      ],
    );
  }
}
