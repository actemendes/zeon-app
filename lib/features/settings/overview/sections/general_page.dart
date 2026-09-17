import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:humanizer/humanizer.dart';
import 'package:zeon/core/haptic/haptic_service.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_page.dart';
import 'package:zeon/features/common/general_pref_tiles.dart';
import 'package:zeon/features/notifications/data/notification_data_providers.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/widget/preference_tile.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/utils/utils.dart';

class GeneralPage extends HookConsumerWidget {
  const GeneralPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Scaffold(
      key: const ValueKey(UiNames.screenGeneralOptions),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.settings.general.title.toUpperCase()),
      ),
      body: SettingsList(
        children: [
          SettingsGroup(
            title: t.pages.settings.groups.appearance,
            children: const [LocalePrefTile(), ThemeModePrefTile(), ButtonAppearancePrefTile()],
          ),
          SettingsGroup(
            title: PlatformUtils.isDesktop ? t.pages.settings.groups.startup : t.pages.settings.groups.feedback,
            children: [
              if (PlatformUtils.isAndroid) ...[
                SettingsSwitch(
                  title: Text(t.pages.settings.general.dynamicNotification),
                  help: t.settingsHelp.dynamicNotification,
                  secondary: const Icon(Icons.speed_rounded),
                  value: ref.watch(Preferences.dynamicNotification),
                  onChanged: ref.read(Preferences.dynamicNotification.notifier).update,
                ),
                SettingsSwitch(
                  title: Text(t.pages.settings.general.hapticFeedback),
                  secondary: const Icon(Icons.vibration_rounded),
                  value: ref.watch(hapticServiceProvider),
                  onChanged: ref.read(hapticServiceProvider.notifier).updatePreference,
                ),
              ],
              if (PlatformUtils.isDesktop) ...[
                const ClosingPrefTile(),
                SettingsSwitch(
                  title: Text(t.pages.settings.general.autoStart),
                  help: t.settingsHelp.autoStart,
                  secondary: const Icon(Icons.auto_mode_rounded),
                  value: ref.watch(autoStartNotifierProvider).valueOrNull ?? false,
                  onChanged: !ref.watch(autoStartNotifierProvider).hasValue
                      ? null
                      : (value) async => value
                            ? await ref.read(autoStartNotifierProvider.notifier).enable()
                            : await ref.read(autoStartNotifierProvider.notifier).disable(),
                ),
                SettingsSwitch(
                  title: Text(t.pages.settings.general.silentStart),
                  help: t.settingsHelp.silentStart,
                  secondary: const Icon(Icons.visibility_off_rounded),
                  value: ref.watch(Preferences.silentStart),
                  onChanged: ref.read(Preferences.silentStart.notifier).update,
                ),
              ],
              SettingsSwitch(
                title: Text(t.pages.settings.general.notifications),
                help: t.settingsHelp.notifications,
                secondary: const Icon(Icons.notifications_active_rounded),
                value: ref.watch(Preferences.remoteNotifications),
                onChanged: (value) async {
                  await ref.read(Preferences.remoteNotifications.notifier).update(value);
                  if (value) {
                    await ref.read(systemNotificationServiceProvider).requestPermission();
                  }
                  await ref.read(notificationPollingServiceProvider).configurePlatformSchedulers();
                },
              ),
            ],
          ),
          SettingsGroup(
            title: t.pages.settings.groups.behavior,
            children: [
              SettingsSwitch(
                key: const ValueKey('settings_low_power_mode'),
                title: Text(t.pages.settings.general.lowPowerMode),
                help: t.settingsHelp.lowPower,
                subtitle: Text(t.pages.settings.general.lowPowerModeMsg),
                secondary: const Icon(Icons.speed_rounded),
                value: ref.watch(Preferences.lowPowerMode),
                onChanged: ref.read(Preferences.lowPowerMode.notifier).update,
              ),
              if (PlatformUtils.isAndroid) const BatteryOptimizationWidget(),
              SettingsSwitch(
                title: Text(t.pages.settings.general.memoryLimit),
                help: t.settingsHelp.memory,
                subtitle: Text(t.pages.settings.general.memoryLimitMsg),
                secondary: const Icon(Icons.memory_rounded),
                value: !ref.watch(Preferences.disableMemoryLimit),
                onChanged: (value) async => await ref.read(Preferences.disableMemoryLimit.notifier).update(!value),
              ),
            ],
          ),
          SettingsGroup(
            title: t.pages.settings.groups.connectionTest,
            children: [
              ValuePreferenceWidget(
                value: ref.watch(ConfigOptions.connectionTestUrl),
                preferences: ref.watch(ConfigOptions.connectionTestUrl.notifier),
                title: t.pages.settings.general.connectionTestUrl,
                help: t.settingsHelp.testUrl,
                icon: Icons.link_rounded,
              ),
              SettingsTile(
                title: Text(t.pages.settings.general.urlTestInterval),
                help: t.settingsHelp.testInterval,
                subtitle: Text(ref.watch(ConfigOptions.urlTestInterval).toApproximateTime(isRelativeToNow: false)),
                leading: const Icon(Icons.timer_rounded),
                onTap: () async => await ref
                    .read(dialogNotifierProvider.notifier)
                    .showSettingSlider(
                      title: t.pages.settings.general.urlTestInterval,
                      initialValue: ref.watch(ConfigOptions.urlTestInterval).inMinutes.coerceIn(1, 60).toDouble(),
                      onReset: ref.read(ConfigOptions.urlTestInterval.notifier).reset,
                      min: 1,
                      max: 60,
                      divisions: 59,
                      labelGen: (value) => Duration(minutes: value.toInt()).toApproximateTime(isRelativeToNow: false),
                    )
                    .then((value) async {
                      if (value == null) return;
                      await ref.read(ConfigOptions.urlTestInterval.notifier).update(Duration(minutes: value.toInt()));
                    }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
