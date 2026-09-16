import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/actions_at_closing.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';

class ActionsAtClosingDialog extends HookConsumerWidget {
  const ActionsAtClosingDialog({super.key, required this.selected});
  final ActionsAtClosing selected;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return ZeonDialog(
      title: Text(t.pages.settings.general.actionAtClosing),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: ActionsAtClosing.values
            .map((e) => DialogChoice(title: e.present(t), selected: e == selected, onTap: () => context.pop(e)))
            .toList(),
      ),
    );
  }
}
