import 'package:dartx/dartx.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/index.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/region.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/features/per_app_proxy/model/app_package_info.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/per_app_proxy/model/pkg_flag.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_loading_notifier.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/utils/utils.dart';

class PerAppProxyPage extends HookConsumerWidget with PresLogger {
  const PerAppProxyPage({super.key});

  static const double applicationIconLogicalSize = 48;

  int _getPriority(AppPackageInfo app, Map<String, int> selected) {
    final flag = selected[app.packageName];
    if (flag == null) return 4;
    if (PkgFlag.userSelection.check(flag)) {
      return 1;
    } else if ((PkgFlag.autoSelection.check(flag) || PkgFlag.managedSelection.check(flag)) &&
        !PkgFlag.forceDeselection.check(flag)) {
      return 2;
    } else {
      return 3;
    }
  }

  Future<Set<AppPackageInfo>> getApps(bool hideSystem) async {
    if (PlatformUtils.isAndroid) {
      return (await InstalledApps.getInstalledApps(
        hideSystem,
        true,
      )).map((e) => AppPackageInfo(packageName: e.packageName, name: e.name, icon: e.icon)).toSet();
    }
    if (PlatformUtils.isDesktop) {
      final apps = await WindowsInstalledAppsService().getInstalledApps(hideSystem: hideSystem);
      return apps.map((e) => AppPackageInfo(packageName: e.packageName, name: e.name, icon: e.icon)).toSet();
    }
    return {};
  }

  Future<void> _pickCustomDesktopExecutable(WidgetRef ref, AppProxyMode? mode) async {
    if (mode == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['exe'],
    );
    final path = result?.files.singleOrNull?.path;
    if (path == null || path.trim().isEmpty) return;
    await ref.read(PerAppProxyProvider(mode).notifier).addAndSelectDesktopApp(path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final applicationIconPhysicalSize = applicationIconCacheExtent(MediaQuery.devicePixelRatioOf(context));
    final fabForegroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : null;
    final t = ref.watch(translationsProvider).requireValue;
    final localizations = MaterialLocalizations.of(context);

    final mode = ref.watch(Preferences.perAppProxyMode).toAppProxy();
    final selectedApps = ref.watch(PerAppProxyProvider(mode));
    final customDesktopApps = ref.watch(Preferences.desktopCustomApps);

    final hideSystemApps = useState(false);
    final isSearching = useState(false);
    final searchQuery = useState("");
    final sortListener = useState(false);

    final asyncFilteredApps = useFuture(useMemoized(() => getApps(hideSystemApps.value), [hideSystemApps.value]));

    final displayedApps = useMemoized<AsyncValue<List<AppPackageInfo>>>(
      () {
        if (!(selectedApps.hasValue &&
            selectedApps is AsyncData &&
            asyncFilteredApps.hasData &&
            asyncFilteredApps.connectionState == ConnectionState.done)) {
          return const AsyncValue.loading();
        }
        final appsList = asyncFilteredApps.requireData.toList();
        if (PlatformUtils.isDesktop) {
          final existingKeys = appsList.map((e) => e.packageName.toLowerCase()).toSet();
          final extraPaths = <String>{
            ...customDesktopApps,
            ...selectedApps.requireValue.keys.where((k) => k.toLowerCase().endsWith('.exe')),
          };
          for (final rawPath in extraPaths) {
            final normalized = WindowsInstalledAppsService.normalizeExecutablePath(rawPath);
            if (normalized == null) continue;
            if (existingKeys.add(normalized.toLowerCase())) {
              appsList.add(
                AppPackageInfo(
                  packageName: normalized,
                  name: WindowsInstalledAppsService.friendlyProgramName(normalized),
                  icon: WindowsInstalledAppsService.extractExecutableIcon(normalized),
                ),
              );
            }
          }
        }
        if (searchQuery.value.isBlank) {
          appsList.sort((a, b) {
            final priorityA = _getPriority(a, selectedApps.requireValue);
            final priorityB = _getPriority(b, selectedApps.requireValue);
            final byPriority = priorityA.compareTo(priorityB);
            if (byPriority != 0) return byPriority;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          return AsyncValue.data(appsList);
        }
        final query = searchQuery.value.toLowerCase();
        final filteredAppsList = appsList
            .filter((e) => e.name.toLowerCase().contains(query) || e.packageName.toLowerCase().contains(query))
            .toList();
        return AsyncValue.data(filteredAppsList);
      },
      [
        asyncFilteredApps.connectionState == ConnectionState.done,
        hideSystemApps.value,
        selectedApps.hasValue,
        selectedApps.valueOrNull?.length,
        customDesktopApps.length,
        searchQuery.value,
        sortListener.value,
      ],
    );

    if (mode != null) {
      ref.listen(PerAppProxyProvider(mode), (previous, next) {
        if (previous != null) {
          if ((previous, next) case (AsyncData(value: final prevData), AsyncData(value: final nextData))) {
            if (nextData.isNotEmpty) {
              if ((nextData.length - prevData.length).abs() > 1) sortListener.value = !sortListener.value;
            }
          }
        }
      });
    }

    final scrollController = useScrollController();
    const double scrollThreshold = 300.0;
    final showScrollToTop = useState<bool>(false);
    useEffect(() {
      void listener() {
        showScrollToTop.value = scrollController.offset > scrollThreshold;
      }

      scrollController.addListener(listener);
      return () => scrollController.removeListener(listener);
    }, []);
    useEffect(() {
      showScrollToTop.value = false;
      return null;
    }, [displayedApps]);

    return Scaffold(
      key: const ValueKey(UiNames.screenPerAppProxy),
      appBar: isSearching.value
          ? AppBar(
              title: TextFormField(
                onChanged: (value) => searchQuery.value = value,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "${localizations.searchFieldLabel}...",
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
              ),
              leading: IconButton(
                onPressed: () {
                  searchQuery.value = "";
                  isSearching.value = false;
                },
                icon: const Icon(Icons.close),
                tooltip: localizations.cancelButtonLabel,
              ),
            )
          : AppBar(
              title: Text(t.pages.settings.routing.perAppProxy.title.toUpperCase()),
              actions: [
                IconButton(
                  icon: const Icon(FluentIcons.search_24_regular),
                  onPressed: () => isSearching.value = true,
                  tooltip: localizations.searchFieldLabel,
                ),
                MenuAnchor(
                  menuChildren: <Widget>[
                    SubmenuButton(
                      menuChildren: <Widget>[
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.perAppProxy.options.import.clipboard),
                          onPressed: () async => await ref
                              .read(dialogNotifierProvider.notifier)
                              .showConfirmation(
                                title: t.common.msg.import.confirm,
                                message: t.dialogs.confirmation.perAppProxy.import.msg,
                              )
                              .then((shouldImport) async {
                                if (shouldImport) await ref.read(PerAppProxyProvider(mode).notifier).importClipboard();
                              }),
                        ),
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.perAppProxy.options.import.file),
                          onPressed: () async => await ref
                              .read(dialogNotifierProvider.notifier)
                              .showConfirmation(
                                title: t.pages.settings.routing.perAppProxy.options.import.file,
                                message: t.pages.settings.routing.perAppProxy.options.import.msg,
                              )
                              .then((shouldImport) async {
                                if (shouldImport) await ref.read(PerAppProxyProvider(mode).notifier).importFile();
                              }),
                        ),
                      ],
                      child: Text(t.common.import),
                    ),
                    SubmenuButton(
                      menuChildren: <Widget>[
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.perAppProxy.options.export.clipboard),
                          onPressed: () async => await ref.read(PerAppProxyProvider(mode).notifier).exportClipboard(),
                        ),
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.perAppProxy.options.export.file),
                          onPressed: () async => await ref.read(PerAppProxyProvider(mode).notifier).exportFile(),
                        ),
                      ],
                      child: Text(t.common.export),
                    ),
                    if (ref.watch(ConfigOptions.region) != Region.other)
                      MenuItemButton(
                        child: Text(t.pages.settings.routing.perAppProxy.options.shareToAll),
                        onPressed: () async => await ref
                            .read(appProxyLoadingProvider.notifier)
                            .doAsync(ref.read(PerAppProxyProvider(mode).notifier).shareOnGithub),
                      ),
                    const PopupMenuDivider(),
                    MenuItemButton(
                      child: Text(t.pages.settings.routing.perAppProxy.options.clearAllSelections),
                      onPressed: () => ref.read(PerAppProxyProvider(mode).notifier).clearAll(),
                    ),
                  ],
                  builder: (context, controller, child) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: ref.watch(appProxyLoadingProvider)
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator()),
                          )
                        : IconButton(
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
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    children: [
                      PopupMenuButton(
                        borderRadius: BorderRadius.circular(8),
                        position: PopupMenuPosition.under,
                        tooltip: (mode?.toPerAppProxy() ?? PerAppProxyMode.off).present(t).message,
                        initialValue: mode?.toPerAppProxy() ?? PerAppProxyMode.off,
                        onSelected: (e) async {
                          if (ref.read(Preferences.autoAppsSelectionRegion) != null) {
                            await ref.read(PerAppProxyProvider(mode).notifier).clearAutoSelected();
                          }
                          if (e == PerAppProxyMode.off && context.mounted) context.pop();
                          await ref.read(Preferences.perAppProxyMode.notifier).update(e);
                        },
                        itemBuilder: (context) => PerAppProxyMode.values
                            .map((e) => PopupMenuItem(value: e, child: Text(e.present(t).message)))
                            .toList(),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: theme.colorScheme.surface,
                          ),
                          child: Row(
                            children: [
                              const Gap(16),
                              Text(mode?.present(t).title ?? ''),
                              const Gap(4),
                              Icon(Icons.arrow_drop_down_rounded, color: theme.colorScheme.onSurfaceVariant),
                              const Gap(8),
                            ],
                          ),
                        ),
                      ),
                      const Gap(8),
                      ChoiceChip(
                        side: BorderSide.none,
                        label: Text(t.pages.settings.routing.perAppProxy.hideSysApps),
                        selected: hideSystemApps.value,
                        onSelected: (value) => hideSystemApps.value = value,
                      ),
                      if (PlatformUtils.isDesktop) ...[
                        const Gap(8),
                        ActionChip(
                          side: BorderSide.none,
                          avatar: const Icon(Icons.add_rounded, size: 18),
                          label: Text('${t.common.add} .exe'),
                          onPressed: () => _pickCustomDesktopExecutable(ref, mode),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
      floatingActionButton: showScrollToTop.value
          ? FloatingActionButton(
              foregroundColor: fabForegroundColor,
              onPressed: () =>
                  scrollController.animateTo(0.0, duration: const Duration(milliseconds: 500), curve: Curves.easeOut),
              child: Icon(Icons.keyboard_arrow_up_rounded, color: fabForegroundColor),
            )
          : null,
      body: displayedApps.when(
        data: (packages) => ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          controller: scrollController,
          itemBuilder: (context, index) {
            final package = packages[index];
            final flag = selectedApps.requireValue[package.packageName];
            return HookBuilder(
              key: ValueKey(package.packageName),
              builder: (context) {
                final focused = useState(false);
                final hovered = useState(false);
                return MouseRegion(
                  onEnter: (_) => hovered.value = true,
                  onExit: (_) => hovered.value = false,
                  child: KeyboardFocusOutline(
                    focused: focused.value,
                    child: Material(
                      color: hovered.value
                          ? Color.alphaBlend(
                              theme.colorScheme.primary.withValues(alpha: .10),
                              theme.colorScheme.secondaryContainer,
                            )
                          : theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(index == 0 ? 20 : 0),
                        bottom: Radius.circular(index == packages.length - 1 ? 20 : 0),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ListTileTheme(
                        data: ListTileThemeData(
                          titleTextStyle: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(fontSize: 14),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        ),
                        child: CheckboxListTile.adaptive(
                          onFocusChange: (value) => focused.value = value,
                          title: Row(
                            children: [
                              Flexible(child: Text(package.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              if (flag != null && PkgFlag.forceDeselection.check(flag)) ...[
                                const Gap(6),
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(color: theme.colorScheme.error, shape: BoxShape.circle),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            package.packageName,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: flag == null ? false : PkgFlag.checkboxValue(flag),
                          tristate: true,
                          onChanged: (_) => ref.read(PerAppProxyProvider(mode).notifier).updatePkg(package.packageName),
                          secondary: package.icon != null
                              ? Image.memory(
                                  package.icon!,
                                  width: applicationIconLogicalSize,
                                  height: applicationIconLogicalSize,
                                  cacheWidth: applicationIconPhysicalSize,
                                  cacheHeight: applicationIconPhysicalSize,
                                  filterQuality: FilterQuality.high,
                                  errorBuilder: (context, error, stackTrace) => _DesktopAppFallbackIcon(
                                    size: applicationIconLogicalSize,
                                    name: package.name,
                                  ),
                                )
                              : package.packageName.toLowerCase().endsWith('.exe')
                              ? _DesktopAppFallbackIcon(
                                  size: applicationIconLogicalSize,
                                  name: package.name,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
          itemCount: packages.length,
        ),
        error: (error, _) => SliverErrorBodyPlaceholder(error.toString()),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _DesktopAppFallbackIcon extends StatelessWidget {
  const _DesktopAppFallbackIcon({required this.size, required this.name});

  final double size;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final initial = trimmed.isNotEmpty ? trimmed.characters.first.toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: cs.primary,
        ),
      ),
    );
  }
}

int applicationIconCacheExtent(double devicePixelRatio) =>
    (PerAppProxyPage.applicationIconLogicalSize * devicePixelRatio).ceil();
