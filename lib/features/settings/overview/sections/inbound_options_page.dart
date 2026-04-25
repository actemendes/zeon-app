import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/ui/ui_names.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class InboundOptionsPage extends HookConsumerWidget {
  const InboundOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Scaffold(
      key: const ValueKey(UiNames.screenInboundOptions),
      appBar: AppBar(title: Text(t.pages.settings.inbound.title.toUpperCase())),
      body: ListView(
        children: [
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.serviceMode),
            preferences: ref.watch(ConfigOptions.serviceMode.notifier),
            choices: ServiceMode.choices,
            title: t.pages.settings.inbound.serviceMode,
            icon: Icons.tune_rounded,
            presentChoice: (value) => value.present(t),
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.inbound.strictRoute),
            secondary: const Icon(Icons.merge_rounded),
            value: ref.watch(ConfigOptions.strictRoute),
            onChanged: ref.read(ConfigOptions.strictRoute.notifier).update,
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.tunImplementation),
            preferences: ref.watch(ConfigOptions.tunImplementation.notifier),
            choices: TunImplementation.values,
            title: t.pages.settings.inbound.tunImplementation,
            icon: Icons.trip_origin_rounded,
            presentChoice: (value) => value.name,
          ),
          if (PlatformUtils.isLinux)
            ValuePreferenceWidget(
              value: ref.watch(ConfigOptions.tproxyPort),
              preferences: ref.watch(ConfigOptions.tproxyPort.notifier),
              title: t.pages.settings.inbound.tproxyPort,
              icon: Icons.device_hub_rounded,
              inputToValue: int.tryParse,
              digitsOnly: true,
              validateInput: isPort,
            ),
          if (PlatformUtils.isLinux || PlatformUtils.isMacOS)
            ValuePreferenceWidget(
              value: ref.watch(ConfigOptions.redirectPort),
              preferences: ref.watch(ConfigOptions.redirectPort.notifier),
              title: t.pages.settings.inbound.redirectPort,
              icon: Icons.device_hub_rounded,
              inputToValue: int.tryParse,
              digitsOnly: true,
              validateInput: isPort,
            ),
        ],
      ),
    );
  }
}
