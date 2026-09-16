import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';

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
    return ZeonDialog(
      title: Text(title ?? t.errors.unexpected),
      icon: Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
      content: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(message, style: const TextStyle(fontFamily: 'Montserrat', fontSize: 13, height: 1.65)),
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () => context.pop(),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontFamily: 'Montserrat', fontSize: 13, fontWeight: FontWeight.w600),
            ),
            child: Text(t.common.ok),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: copyText)),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: const TextStyle(fontFamily: 'Montserrat', fontSize: 12),
            ),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Копировать ошибку'),
          ),
        ],
      ),
    );
  }
}
