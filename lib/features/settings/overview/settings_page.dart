import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/app_update/notifier/app_update_notifier.dart';
import 'package:zeon/features/app_update/notifier/app_update_state.dart';
import 'package:zeon/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/utils/utils.dart';

enum ConfigOptionSection {
  fragment;

  static final _fragmentKey = GlobalKey(debugLabel: "fragment-section-key");

  GlobalKey get key => switch (this) {
    ConfigOptionSection.fragment => _fragmentKey,
  };
}

class SettingsPage extends HookConsumerWidget {
  SettingsPage({super.key, String? section}) : section = _parseSection(section);

  final ConfigOptionSection? section;

  static ConfigOptionSection? _parseSection(String? section) {
    if (section == null) return null;
    for (final value in ConfigOptionSection.values) {
      if (value.name == section) return value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final appUpdateState = ref.watch(appUpdateNotifierProvider);
    // final scrollController = useScrollController();

    // useMemoized(
    //   () {
    //     if (section != null) {
    //       WidgetsBinding.instance.addPostFrameCallback(
    //         (_) {
    //           final box = section!.key.currentContext?.findRenderObject() as RenderBox?;

    //           final offset = box?.localToGlobal(Offset.zero);
    //           if (offset == null) return;
    //           final height = scrollController.offset + offset.dy - MediaQueryData.fromView(View.of(context)).padding.top - kToolbarHeight;
    //           scrollController.animateTo(
    //             height,
    //             duration: const Duration(milliseconds: 500),
    //             curve: Curves.decelerate,
    //           );
    //         },
    //       );
    //     }
    //   },
    // );

    return Scaffold(
      key: const ValueKey(UiNames.screenSettings),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.settings.title.toUpperCase()),
        actions: [
          MenuAnchor(
            menuChildren: <Widget>[
              SubmenuButton(
                menuChildren: <Widget>[
                  MenuItemButton(
                    onPressed: () async => await ref
                        .read(dialogNotifierProvider.notifier)
                        .showConfirmation(
                          title: t.common.msg.import.confirm,
                          message: t.dialogs.confirmation.settings.import.msg,
                        )
                        .then((shouldImport) async {
                          if (shouldImport) {
                            await ref.read(configOptionNotifierProvider.notifier).importFromClipboard();
                          }
                        }),
                    child: Text(t.pages.settings.options.import.clipboard),
                  ),
                  MenuItemButton(
                    onPressed: () async => await ref
                        .read(dialogNotifierProvider.notifier)
                        .showConfirmation(
                          title: t.common.msg.import.confirm,
                          message: t.dialogs.confirmation.settings.import.msg,
                        )
                        .then((shouldImport) async {
                          if (shouldImport) {
                            await ref.read(configOptionNotifierProvider.notifier).importFromJsonFile();
                          }
                        }),
                    child: Text(t.pages.settings.options.import.file),
                  ),
                ],
                child: Text(t.common.import),
              ),
              SubmenuButton(
                menuChildren: <Widget>[
                  MenuItemButton(
                    onPressed: () async => await ref.read(configOptionNotifierProvider.notifier).exportJsonClipboard(),
                    child: Text(t.pages.settings.options.export.anonymousToClipboard),
                  ),
                  MenuItemButton(
                    onPressed: () async => await ref.read(configOptionNotifierProvider.notifier).exportJsonFile(),
                    child: Text(t.pages.settings.options.export.anonymousToFile),
                  ),
                  const PopupMenuDivider(),
                  MenuItemButton(
                    onPressed: () async => await ref
                        .read(configOptionNotifierProvider.notifier)
                        .exportJsonClipboard(excludePrivate: false),
                    child: Text(t.pages.settings.options.export.allToClipboard),
                  ),
                  MenuItemButton(
                    onPressed: () async =>
                        await ref.read(configOptionNotifierProvider.notifier).exportJsonFile(excludePrivate: false),
                    child: Text(t.pages.settings.options.export.allToFile),
                  ),
                ],
                child: Text(t.common.export),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                child: Text(t.pages.settings.options.reset),
                onPressed: () async => await ref.read(configOptionNotifierProvider.notifier).resetOption(),
              ),
            ],
            builder: (context, controller, child) => IconButton(
              onPressed: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              icon: const Icon(Icons.more_vert_rounded),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: SettingsList(
        children: [
          SettingsGroup(
            title: t.pages.settings.groups.application,
            children: [
              // SettingsHint(message: t.settings.experimentalMsg),
              SettingsSection(
                title: t.pages.settings.general.title,
                icon: Icons.layers_rounded,
                namedLocation: context.namedLocation('general'),
                subtitle: '${t.pages.settings.general.locale} · ${t.pages.settings.general.themeMode}',
              ),
            ],
          ),
          SettingsGroup(
            title: t.pages.settings.groups.connection,
            children: [
              SettingsSection(
                title: t.pages.settings.routing.title,
                icon: Icons.route_rounded,
                namedLocation: context.namedLocation('routeOptions'),
                subtitle: '${t.pages.settings.routing.region} · ${t.pages.settings.routing.ipv6Route}',
              ),
              SettingsSection(
                title: t.pages.settings.tlsTricks.title,
                icon: Icons.content_cut_rounded,
                namedLocation: context.namedLocation('tlsTricks'),
              ),
              if (!PlatformUtils.isApple)
                SettingsSection(
                  title: t.pages.settings.inbound.title,
                  icon: Icons.input_rounded,
                  namedLocation: context.namedLocation('inboundOptions'),
                ),
            ],
          ),
          SettingsGroup(
            children: [
              if (Breakpoint(context).isMobile()) ...[
                SettingsSection(
                  title: t.pages.about.title,
                  icon: Icons.info_rounded,
                  namedLocation: context.namedLocation('about'),
                ),
              ],
              if (shouldShowManualAppUpdate(appInfo.release, isIOS: PlatformUtils.isIOS))
                SettingsTile(
                  leading: const Icon(Icons.system_update_alt_rounded),
                  title: Text(t.pages.about.checkForUpdate),
                  subtitle: Text("${t.common.version} ${appInfo.presentVersion}"),
                  trailing: appUpdateState is AppUpdateStateChecking
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded),
                  onTap: appUpdateState is AppUpdateStateChecking ? null : () => _checkForUpdate(context, ref),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

bool shouldShowManualAppUpdate(Release release, {required bool isIOS}) => release.allowCustomUpdateChecker && !isIOS;

Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
  final result = await ref.read(appUpdateNotifierProvider.notifier).check();
  if (!context.mounted) return;

  final t = ref.read(translationsProvider).requireValue;
  final appInfo = ref.read(appInfoProvider).requireValue;
  switch (result) {
    case AppUpdateStateAvailable(:final versionInfo) || AppUpdateStateIgnored(:final versionInfo):
      await ref
          .read(dialogNotifierProvider.notifier)
          .showNewVersion(currentVersion: appInfo.presentVersion, newVersion: versionInfo, canIgnore: false);
    case AppUpdateStateError(:final error):
      CustomToast.error(t.presentShortError(error), diagnosticText: t.diagnosticError(error)).show(context);
    case AppUpdateStateNotAvailable():
      CustomToast.success(t.pages.about.notAvailableMsg).show(context);
    case AppUpdateStateInitial() || AppUpdateStateDisabled() || AppUpdateStateChecking():
      return;
  }
}

class SettingsSection extends HookConsumerWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.icon,
    required this.namedLocation,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String namedLocation;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.go(namedLocation),
    );
  }
}
