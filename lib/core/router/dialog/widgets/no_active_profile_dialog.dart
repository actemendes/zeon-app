import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/windows_network_help_dialog.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/utils/utils.dart';

class NoActiveProfileDialog extends HookConsumerWidget {
  const NoActiveProfileDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    if (PlatformUtils.isWindows) {
      return WindowsNetworkHelpDialog(russian: t.$meta.locale == AppLocale.ru);
    }
    return ZeonDialog(
      title: Text(t.dialogs.noActiveProfile.title),
      content: Text(t.dialogs.noActiveProfile.msg),
      actions: [
        TextButton(
          onPressed: () async {
            await UriUtils.tryLaunch(Uri.parse(t.dialogs.noActiveProfile.helpBtn.url));
          },
          child: Text(t.dialogs.noActiveProfile.helpBtn.label),
        ),
        TextButton(onPressed: () => context.pop(), child: Text(t.common.ok)),
      ],
    );
  }
}
