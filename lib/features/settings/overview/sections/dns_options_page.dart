import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/widget/preference_tile.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class DnsOptionsPage extends HookConsumerWidget {
  const DnsOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Scaffold(
      key: const ValueKey(UiNames.screenDnsOptions),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.settings.dns.title.toUpperCase()),
      ),
      body: SettingsList(
        children: [
          SettingsGroup(
            children: [
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.remoteDnsAddress),
                icon: Icons.vpn_lock_rounded,
                preferences: ref.watch(ConfigOptions.remoteDnsAddress.notifier),
                title: t.pages.settings.dns.remoteDns,
                help: t.settingsHelp.remoteDns,
              ),
              SettingsSwitch(
                title: Text(t.pages.settings.dns.enableFakeDns),
                help: t.settingsHelp.fakeDns,
                secondary: const Icon(Icons.private_connectivity_rounded),
                value: ref.watch(ConfigOptions.enableFakeDns),
                onChanged: ref.read(ConfigOptions.enableFakeDns.notifier).update,
              ),
            ],
          ),
          SettingsGroup(
            children: [
              ValuePreferenceWidget(
                title: t.pages.settings.dns.directDns,
                help: t.settingsHelp.directDns,
                icon: Icons.public_rounded,
                value: ref.watch(ConfigOptions.directDnsAddress),
                preferences: ref.watch(ConfigOptions.directDnsAddress.notifier),
              ),
              // SettingsSwitch(
              //   title: Text(t.pages.settings.dns.enableDnsRouting),
              //   secondary: const Icon(Icons.private_connectivity_rounded),
              //   value: ref.watch(ConfigOptions.enableDnsRouting),
              //   onChanged: ref.read(ConfigOptions.enableDnsRouting.notifier).update,
              // ),
            ],
          ),
        ],
      ),
    );
  }
}
