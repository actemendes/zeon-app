import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';

class QuickSettingsModal extends ConsumerWidget {
  const QuickSettingsModal({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return ZeonDialog(
      title: Text(t.pages.home.quickSettings),
      icon: const Icon(Icons.vpn_key_rounded),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in ServiceMode.choices)
            DialogChoice(
              title: mode.present(t),
              selected: ref.watch(ConfigOptions.serviceMode) == mode,
              onTap: () => ref.read(ConfigOptions.serviceMode.notifier).update(mode),
            ),
        ],
      ),
    );
  }
}
