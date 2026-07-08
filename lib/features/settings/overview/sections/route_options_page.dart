import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/region.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/core/widget/tip_card.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/widget/preference_tile.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/platform_utils.dart';

class RouteOptionsPage extends HookConsumerWidget {
  const RouteOptionsPage({super.key});

  static const _regionChoices = [Region.ru, Region.other];

  String _defaultDirectDnsForRegion(Region region) => switch (region) {
    Region.cn => "223.5.5.5",
    Region.ru => "77.88.8.8",
    _ => "1.1.1.1",
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final perAppProxy = ref.watch(Preferences.perAppProxyMode).enabled;
    final currentRegion = ref.watch(ConfigOptions.region);
    return Scaffold(
      key: const ValueKey(UiNames.screenRouteOptions),
      appBar: AppBar(title: Text(t.pages.settings.routing.title.toUpperCase())),
      body: ListView(
        children: [
          TipCard(message: t.pages.settings.routing.hint),
          if (PlatformUtils.isAndroid)
            ListTile(
              title: Text(t.pages.settings.routing.perAppProxy.title),
              leading: const Icon(Icons.apps_rounded),
              trailing: Switch(
                value: perAppProxy,
                onChanged: (value) async {
                  final newMode = perAppProxy ? PerAppProxyMode.off : PerAppProxyMode.exclude;
                  await ref.read(Preferences.perAppProxyMode.notifier).update(newMode);
                  if (!perAppProxy && context.mounted) context.goNamed('perAppProxy');
                },
              ),
              onTap: () async {
                if (!perAppProxy) {
                  await ref.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
                }
                if (context.mounted) context.goNamed('perAppProxy');
              },
            ),
          ChoicePreferenceWidget(
            selected: currentRegion,
            preferences: ref.watch(ConfigOptions.region.notifier),
            choices: _regionChoices,
            title: t.pages.settings.routing.region,
            showFlag: true,
            icon: Icons.place_rounded,
            presentChoice: (value) => value.present(t),
            onChanged: (val) async {
              final currentDirectDns = ref.read(ConfigOptions.directDnsAddress).trim().toLowerCase();
              final previousRegionDefault = _defaultDirectDnsForRegion(currentRegion);
              final nextRegionDefault = _defaultDirectDnsForRegion(val);
              final normalizedPreviousDefaults = {previousRegionDefault, 'udp://$previousRegionDefault'};
              final normalizedNextDefaults = {nextRegionDefault, 'udp://$nextRegionDefault'};
              final usingRegionDefault =
                  normalizedPreviousDefaults.contains(currentDirectDns) ||
                  normalizedNextDefaults.contains(currentDirectDns);
              if (usingRegionDefault) {
                await ref.read(ConfigOptions.directDnsAddress.notifier).reset();
              }
              final autoRegion = ref.read(Preferences.autoAppsSelectionRegion);
              final mode = ref.read(Preferences.perAppProxyMode).toAppProxy();
              if (autoRegion != val &&
                  autoRegion != null &&
                  val != Region.other &&
                  mode != null &&
                  PlatformUtils.isAndroid) {
                await ref
                    .read(dialogNotifierProvider.notifier)
                    .showOk(
                      t.pages.settings.routing.perAppProxy.autoSelection.dialog.title,
                      t.pages.settings.routing.perAppProxy.autoSelection.dialog.msg(region: val.name),
                    );
                await ref.read(PerAppProxyProvider(mode).notifier).clearAutoSelected();
              }
            },
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.balancerStrategy),
            preferences: ref.watch(ConfigOptions.balancerStrategy.notifier),
            choices: BalancerStrategy.choices,
            title: t.pages.settings.routing.balancerStrategy.title,
            icon: Icons.auto_awesome_rounded,
            presentChoice: (value) => value.present(t),
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.blockAds),
            secondary: const Icon(Icons.block_rounded),
            value: ref.watch(ConfigOptions.blockAds),
            onChanged: ref.read(ConfigOptions.blockAds.notifier).update,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.bypassLan),
            secondary: const Icon(Icons.call_split_rounded),
            value: ref.watch(ConfigOptions.bypassLan),
            onChanged: ref.read(ConfigOptions.bypassLan.notifier).update,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.resolveDestination),
            secondary: const Icon(Icons.security_rounded),
            value: ref.watch(ConfigOptions.resolveDestination),
            onChanged: ref.read(ConfigOptions.resolveDestination.notifier).update,
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.ipv6Mode),
            preferences: ref.watch(ConfigOptions.ipv6Mode.notifier),
            choices: IPv6Mode.values,
            title: t.pages.settings.routing.ipv6Route,
            icon: Icons.looks_6_rounded,
            presentChoice: (value) => value.present(t),
          ),
        ],
      ),
    );
  }
}
