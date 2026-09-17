import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/optional_range.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/notifier/warp_option/warp_option_notifier.dart';
import 'package:zeon/features/settings/widget/preference_tile.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/utils.dart';

class WarpOptionsPage extends HookConsumerWidget {
  const WarpOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final warpOptions = ref.watch(warpOptionNotifierProvider);
    final isWarpEnabled = ref.watch(ConfigOptions.enableWarp);
    return Scaffold(
      key: const ValueKey(UiNames.screenWarpOptions),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.settings.warp.title.toUpperCase()),
      ),
      body: SettingsList(
        children: [
          SettingsGroup(
            children: [
              SettingsSwitch(
                title: Text(t.pages.settings.warp.enable),
                help: t.settingsHelp.warp,
                value: isWarpEnabled,
                secondary: const Icon(Icons.cloud_rounded),
                onChanged: (value) async {
                  await ref.read(ConfigOptions.enableWarp.notifier).update(value);
                  if (value) await ref.read(warpOptionNotifierProvider.notifier).genWarps();
                },
              ),
              SettingsTile(
                title: Text(t.pages.settings.warp.generateConfig),
                help: t.settingsHelp.warpConfig,
                subtitle: !isWarpEnabled
                    ? null
                    : warpOptions.when(
                        loading: () => null,
                        data: (_) => null,
                        error: (_, _) =>
                            Text(t.pages.settings.warp.missingConfig, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                trailing: warpOptions.isLoading
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
                    : null,
                leading: const Icon(Icons.build_rounded),
                enabled: isWarpEnabled && !warpOptions.isLoading,
                onTap: warpOptions.isLoading
                    ? null
                    : () async {
                        await ref.read(warpOptionNotifierProvider.notifier).genWarps();
                      },
              ),
            ],
          ),
          SettingsGroup(
            title: t.pages.settings.groups.connection,
            children: [
              ChoicePreferenceWidget(
                selected: ref.watch(ConfigOptions.warpDetourMode),
                preferences: ref.watch(ConfigOptions.warpDetourMode.notifier),
                enabled: isWarpEnabled,
                choices: WarpDetourMode.values,
                title: t.pages.settings.warp.detourMode,
                help: t.settingsHelp.warpMode,
                icon: Icons.alt_route_rounded,
                presentChoice: (value) => value.present(t),
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpLicenseKey),
                preferences: ref.watch(ConfigOptions.warpLicenseKey.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.licenseKey,
                help: t.settingsHelp.warpLicense,
                icon: Icons.key_rounded,
                presentValue: (value) => value.isEmpty ? t.common.notSet : value,
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpCleanIp),
                preferences: ref.watch(ConfigOptions.warpCleanIp.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.cleanIp,
                help: t.settingsHelp.warpIp,
                icon: Icons.auto_awesome_rounded,
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpPort),
                preferences: ref.watch(ConfigOptions.warpPort.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.port,
                help: t.settingsHelp.warpPort,
                icon: Icons.device_hub_rounded,
                inputToValue: int.tryParse,
                validateInput: isPort,
                digitsOnly: true,
              ),
            ],
          ),
          SettingsGroup(
            title: t.pages.settings.groups.noise,
            children: [
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpNoise),
                preferences: ref.watch(ConfigOptions.warpNoise.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.noise.count,
                help: t.settingsHelp.noiseCount,
                icon: Icons.web_stories_rounded,
                inputToValue: (input) => OptionalRange.tryParse(input, allowEmpty: true),
                presentValue: (value) => value.present(t),
                formatInputValue: (value) => value.format(),
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpNoiseMode),
                preferences: ref.watch(ConfigOptions.warpNoiseMode.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.noise.mode,
                help: t.settingsHelp.noiseMode,
                icon: Icons.mode_standby_rounded,
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpNoiseSize),
                preferences: ref.watch(ConfigOptions.warpNoiseSize.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.noise.size,
                help: t.settingsHelp.noiseSize,
                icon: Icons.settings_ethernet_rounded,
                inputToValue: (input) => OptionalRange.tryParse(input, allowEmpty: true),
                presentValue: (value) => value.present(t),
                formatInputValue: (value) => value.format(),
              ),
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.warpNoiseDelay),
                preferences: ref.watch(ConfigOptions.warpNoiseDelay.notifier),
                enabled: isWarpEnabled,
                title: t.pages.settings.warp.noise.delay,
                help: t.settingsHelp.noiseDelay,
                icon: Icons.schedule_rounded,
                inputToValue: (input) => OptionalRange.tryParse(input, allowEmpty: true),
                presentValue: (value) => value.present(t),
                formatInputValue: (value) => value.format(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
