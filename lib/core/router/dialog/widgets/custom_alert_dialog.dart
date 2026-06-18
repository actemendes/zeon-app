import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class CustomAlertDialog extends HookConsumerWidget {
  const CustomAlertDialog({super.key, this.title, required this.message, this.diagnosticText});

  final String? title;
  final String message;
  final String? diagnosticText;

  factory CustomAlertDialog.fromErr(({String type, String? message}) err) =>
      CustomAlertDialog(title: err.message == null ? null : err.type, message: err.message ?? err.type);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final copyText = diagnosticText ?? (title == null ? message : "$title\n$message");
    return AlertDialog(
      title: Text(title ?? message),
      content: const SingleChildScrollView(
        child: SizedBox(
          width: 468,
          child: Text('Если ошибка повторяется часто - пожалуйста, скопируйте ошибку и напишите в поддержку.'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: copyText));
          },
          child: const Text('Копировать ошибку'),
        ),
        TextButton(
          onPressed: () {
            context.pop();
          },
          child: Text(t.common.ok),
        ),
      ],
    );
  }
}
