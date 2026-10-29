import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/features/route_rules/notifier/generic_list_notifier.dart';
import 'package:zeon/features/route_rules/notifier/rule_notifier.dart';
import 'package:zeon/features/route_rules/overview/android_apps_page.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/utils/platform_utils.dart';

class GenericListPage extends HookConsumerWidget {
  const GenericListPage({super.key, this.ruleListOrder, required this.ruleEnum, this.validator});

  final int? ruleListOrder;
  final RuleEnum ruleEnum;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fabForegroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : null;
    final provider = genericListNotifierProvider(ruleListOrder, ruleEnum);
    final list = ref.watch(provider);

    final isDesktopProcessField =
        PlatformUtils.isDesktop && (ruleEnum == RuleEnum.processPath || ruleEnum == RuleEnum.processName);

    Future<void> addNewValue() async {
      final result = await ref
          .read(dialogNotifierProvider.notifier)
          .showSettingText(lable: t.pages.settings.routing.routeRule.genericList.addNew, validator: validator);
      if (result is String) ref.read(provider.notifier).add(result);
    }

    Future<void> pickExecutableFile() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['exe'],
      );
      final rawPath = result?.files.singleOrNull?.path;
      if (rawPath == null || rawPath.trim().isEmpty) return;
      final normalized = WindowsInstalledAppsService.normalizeExecutablePath(rawPath) ?? rawPath.trim();
      final valueToAdd = ruleEnum == RuleEnum.processName
          ? normalized.split(RegExp(r'[\\/]')).last
          : normalized;
      if (!list.contains(valueToAdd)) {
        ref.read(provider.notifier).add(valueToAdd);
      }
    }

    return Scaffold(
      key: const ValueKey(UiNames.screenGenericList),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(ruleEnum.present(t).toUpperCase()),
        actions: [
          IconButton(
            onPressed: list.isEmpty
                ? null
                : () async {
                    final result = await ref
                        .read(dialogNotifierProvider.notifier)
                        .showConfirmation(
                          title: t.pages.settings.routing.routeRule.genericList.clearList,
                          message: t.pages.settings.routing.routeRule.genericList.clearListMsg,
                        );
                    if (result == true) ref.read(provider.notifier).reset();
                  },
            icon: const Icon(Icons.clear_all_rounded),
          ),
          const Gap(8),
        ],
        bottom: isDesktopProcessField
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    children: [
                      if (ruleEnum == RuleEnum.processPath) ...[
                        ActionChip(
                          side: BorderSide.none,
                          avatar: const Icon(Icons.apps_rounded, size: 18),
                          label: Text(t.pages.settings.routing.perAppProxy.title),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => AndroidAppsPage(ruleListOrder: ruleListOrder),
                              fullscreenDialog: true,
                            ),
                          ),
                        ),
                        const Gap(8),
                      ],
                      ActionChip(
                        side: BorderSide.none,
                        avatar: const Icon(Icons.folder_open_rounded, size: 18),
                        label: Text('${t.common.add} .exe'),
                        onPressed: pickExecutableFile,
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      floatingActionButton: list.isNotEmpty
          ? FloatingActionButton(
              foregroundColor: fabForegroundColor,
              onPressed: addNewValue,
              child: Icon(Icons.add_rounded, color: fabForegroundColor),
            )
          : FloatingActionButton.extended(
              foregroundColor: fabForegroundColor,
              onPressed: addNewValue,
              label: Text(t.pages.settings.routing.routeRule.genericList.addNew),
              icon: Icon(Icons.add_rounded, color: fabForegroundColor),
            ),
      body: list.isEmpty
          ? SettingsList(
              children: [
                SettingsGroup(
                  children: [
                    SettingsTile(
                      leading: const Icon(Icons.playlist_add_rounded),
                      title: Text(t.pages.settings.routing.routeRule.genericList.addNew),
                      subtitle: Text(t.common.empty),
                      onTap: addNewValue,
                    ),
                  ],
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              itemCount: list.length,
              itemBuilder: (context, index) {
                final itemStr = '${list[index]}';
                return Material(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(index == 0 ? 20 : 0),
                    bottom: Radius.circular(index == list.length - 1 ? 20 : 0),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      if (index > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 54, right: 16),
                          child: Divider(height: 1, color: cs.onSurface.withValues(alpha: .07)),
                        ),
                      GenericListTile(
                        value: itemStr,
                        onRemove: () => ref.read(provider.notifier).remove(index),
                        onUpdate: () async {
                          final result = await ref
                              .read(dialogNotifierProvider.notifier)
                              .showSettingText(
                                lable: t.pages.settings.routing.routeRule.genericList.update,
                                value: itemStr,
                                validator: validator,
                              );
                          if (result is String) ref.read(provider.notifier).update(index, result);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class GenericListTile extends ConsumerWidget {
  const GenericListTile({super.key, required this.value, required this.onRemove, required this.onUpdate});

  final dynamic value;
  final VoidCallback? onRemove;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final text = '$value';
    final isExePath = PlatformUtils.isDesktop && text.toLowerCase().endsWith('.exe') && text.contains(RegExp(r'[\\/]'));
    final Uint8List? exeIcon = isExePath ? WindowsInstalledAppsService.extractExecutableIcon(text) : null;
    final String? friendlyTitle = isExePath ? WindowsInstalledAppsService.friendlyProgramName(text) : null;

    return SettingsTile(
      onTap: onUpdate,
      leading: exeIcon != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(exeIcon, width: 28, height: 28, filterQuality: FilterQuality.high),
            )
          : Icon(isExePath ? Icons.apps_rounded : Icons.tune_rounded),
      title: Text(
        friendlyTitle ?? text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: friendlyTitle != null
          ? Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onUpdate,
            icon: Icon(Icons.edit_rounded, size: 19, color: cs.onSurfaceVariant),
          ),
          IconButton(
            onPressed: onRemove,
            icon: Icon(Icons.remove_circle_outline_rounded, size: 20, color: cs.error),
          ),
        ],
      ),
    );
  }
}
