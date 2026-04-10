import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class DnsOptionsPage extends HookConsumerWidget {
  const DnsOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.dns.title.toUpperCase())),
      body: ListView(
        children: [
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.remoteDnsAddress),
            icon: Icons.vpn_lock_rounded,
            preferences: ref.watch(ConfigOptions.remoteDnsAddress.notifier),
            title: t.pages.settings.dns.remoteDns,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.dns.enableFakeDns),
            secondary: const Icon(Icons.private_connectivity_rounded),
            value: ref.watch(ConfigOptions.enableFakeDns),
            onChanged: ref.read(ConfigOptions.enableFakeDns.notifier).update,
          ),
          ValuePreferenceWidget(
            title: t.pages.settings.dns.directDns,
            icon: Icons.public_rounded,
            value: ref.watch(ConfigOptions.directDnsAddress),
            preferences: ref.watch(ConfigOptions.directDnsAddress.notifier),
          ),
          // SwitchListTile.adaptive(
          //   title: Text(t.pages.settings.dns.enableDnsRouting),
          //   secondary: const Icon(Icons.private_connectivity_rounded),
          //   value: ref.watch(ConfigOptions.enableDnsRouting),
          //   onChanged: ref.read(ConfigOptions.enableDnsRouting.notifier).update,
          // ),
        ],
      ),
    );
  }
}
