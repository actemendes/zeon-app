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
import 'package:zeon/features/common/general_pref_tiles.dart';
import 'package:zeon/features/notifications/data/notification_data_providers.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/widget/preference_tile.dart';
import 'package:zeon/utils/utils.dart';

class GeneralPage extends HookConsumerWidget {
  const GeneralPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Scaffold(
      key: const ValueKey(UiNames.screenGeneralOptions),
      appBar: AppBar(title: Text(t.pages.settings.general.title.toUpperCase())),
      body: ListView(
        children: [
          const LocalePrefTile(),
          const ThemeModePrefTile(),
          if (PlatformUtils.isAndroid) ...[
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.dynamicNotification),
              secondary: const Icon(Icons.speed_rounded),
              value: ref.watch(Preferences.dynamicNotification),
              onChanged: ref.read(Preferences.dynamicNotification.notifier).update,
            ),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.hapticFeedback),
              secondary: const Icon(Icons.vibration_rounded),
              value: ref.watch(hapticServiceProvider),
              onChanged: ref.read(hapticServiceProvider.notifier).updatePreference,
            ),
          ],
          if (PlatformUtils.isDesktop) ...[
            const ClosingPrefTile(),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.autoStart),
              secondary: const Icon(Icons.auto_mode_rounded),
              value: ref.watch(autoStartNotifierProvider).asData!.value,
              onChanged: (value) async => value
                  ? await ref.read(autoStartNotifierProvider.notifier).enable()
                  : await ref.read(autoStartNotifierProvider.notifier).disable(),
            ),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.silentStart),
              secondary: const Icon(Icons.visibility_off_rounded),
              value: ref.watch(Preferences.silentStart),
              onChanged: ref.read(Preferences.silentStart.notifier).update,
            ),
          ],
          if (notificationPollingSupported)
            SwitchListTile.adaptive(
              title: const Text('Уведомления'),
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
          if (PlatformUtils.isAndroid) const BatteryOptimizationWidget(),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.general.memoryLimit),
            subtitle: Text(t.pages.settings.general.memoryLimitMsg),
            secondary: const Icon(Icons.memory_rounded),
            value: !ref.watch(Preferences.disableMemoryLimit),
            onChanged: (value) async => await ref.read(Preferences.disableMemoryLimit.notifier).update(!value),
          ),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.connectionTestUrl),
            preferences: ref.watch(ConfigOptions.connectionTestUrl.notifier),
            title: t.pages.settings.general.connectionTestUrl,
            icon: Icons.link_rounded,
          ),
          ListTile(
            title: Text(t.pages.settings.general.urlTestInterval),
            subtitle: Text(ref.watch(ConfigOptions.urlTestInterval).toApproximateTime(isRelativeToNow: false)),
            leading: const Icon(Icons.timer_rounded),
            onTap: () async => await ref
                .read(dialogNotifierProvider.notifier)
                .showSettingSlider(
                  title: t.pages.settings.general.urlTestInterval,
                  initialValue: ref.watch(ConfigOptions.urlTestInterval).inMinutes.coerceIn(0, 60).toDouble(),
                  onReset: ref.read(ConfigOptions.urlTestInterval.notifier).reset,
                  min: 1,
                  max: 60,
                  divisions: 60,
                  labelGen: (value) => Duration(minutes: value.toInt()).toApproximateTime(isRelativeToNow: false),
                )
                .then((value) async {
                  if (value == null) return;
                  await ref.read(ConfigOptions.urlTestInterval.notifier).update(Duration(minutes: value.toInt()));
                }),
          ),
        ],
      ),
    );
  }
}
