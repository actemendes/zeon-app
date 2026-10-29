import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/app_info.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/features/route_rules/notifier/android_apps_notifier.dart';

class AndroidAppsPage extends HookConsumerWidget {
  const AndroidAppsPage({super.key, this.ruleListOrder});

  final int? ruleListOrder;

  static const double _iconSize = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final isSearching = useState(false);
    final hideSystem = ref.watch(hideSystemNotifierProvider);

    ref.watch(appPackagesProvider);
    final selectedNotifier = SelectedPackagesNotifierProvider(ruleListOrder);
    final selected = ref.watch(selectedNotifier);
    final combinedList = ref.watch(FilterBySearchProvider(ruleListOrder));

    return Scaffold(
      key: const ValueKey(UiNames.screenAndroidApps),
      appBar: isSearching.value
          ? AppBar(
              title: TextFormField(
                autofocus: true,
                onChanged: (value) => ref.read(searchQueryNotifierProvider.notifier).setQuery(value),
                decoration: InputDecoration(
                  hintText: '${localizations.searchFieldLabel}...',
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
              ),
              leading: IconButton(
                onPressed: () {
                  ref.read(searchQueryNotifierProvider.notifier).clear();
                  isSearching.value = false;
                },
                icon: const Icon(Icons.close_rounded),
                tooltip: localizations.cancelButtonLabel,
              ),
            )
          : AppBar(
              centerTitle: false,
              titleTextStyle: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
              title: Text(t.pages.settings.routing.perAppProxy.title.toUpperCase()),
              actions: [
                IconButton(
                  icon: const Icon(FluentIcons.search_24_regular),
                  onPressed: () => isSearching.value = true,
                  tooltip: localizations.searchFieldLabel,
                ),
                if (selected.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_all_rounded),
                    tooltip: t.pages.settings.routing.routeRule.androidApps.clearSelection,
                    onPressed: ref.read(selectedNotifier.notifier).clearSelection,
                  ),
                const Gap(8),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    children: [
                      ChoiceChip(
                        side: BorderSide.none,
                        label: Text(t.pages.settings.routing.perAppProxy.hideSysApps),
                        selected: hideSystem,
                        onSelected: (value) {
                          if (value) {
                            ref.read(hideSystemNotifierProvider.notifier).hide();
                          } else {
                            ref.read(hideSystemNotifierProvider.notifier).show();
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
      body: combinedList.when(
        data: (items) => ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final String packageName;
            final String titleText;
            final Widget leadingWidget;

            if (item is AppInfo) {
              packageName = item.packageName;
              titleText = item.name;
              leadingWidget = item.icon != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        item.icon!,
                        width: _iconSize,
                        height: _iconSize,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, _, _) => _AppPickerFallbackIcon(name: item.name, size: _iconSize),
                      ),
                    )
                  : _AppPickerFallbackIcon(name: item.name, size: _iconSize);
            } else if (item is String) {
              packageName = item;
              titleText = packageName.toLowerCase().endsWith('.exe')
                  ? WindowsInstalledAppsService.friendlyProgramName(packageName)
                  : t.pages.settings.routing.routeRule.androidApps.uninstalled;
              final extracted = packageName.toLowerCase().endsWith('.exe')
                  ? WindowsInstalledAppsService.extractExecutableIcon(packageName)
                  : null;
              leadingWidget = extracted != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        extracted,
                        width: _iconSize,
                        height: _iconSize,
                        filterQuality: FilterQuality.high,
                      ),
                    )
                  : _AppPickerFallbackIcon(name: titleText, size: _iconSize);
            } else {
              return const SizedBox.shrink();
            }

            return HookBuilder(
              key: ValueKey(packageName),
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
                          ? Color.alphaBlend(cs.primary.withValues(alpha: .10), cs.secondaryContainer)
                          : cs.secondaryContainer,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(index == 0 ? 20 : 0),
                        bottom: Radius.circular(index == items.length - 1 ? 20 : 0),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          if (index > 0)
                            Padding(
                              padding: const EdgeInsets.only(left: 72, right: 16),
                              child: Divider(height: 1, color: cs.onSurface.withValues(alpha: .07)),
                            ),
                          ListTileTheme(
                            data: ListTileThemeData(
                              titleTextStyle: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'Montserrat',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'Montserrat',
                                fontSize: 13,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            ),
                            child: CheckboxListTile.adaptive(
                              onFocusChange: (value) => focused.value = value,
                              secondary: leadingWidget,
                              title: Text(titleText, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(packageName, maxLines: 1, overflow: TextOverflow.ellipsis),
                              value: selected.contains(packageName),
                              onChanged: (_) => ref.read(selectedNotifier.notifier).onChanged(packageName),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(t.errors.withDetails(error: error))),
      ),
    );
  }
}

class _AppPickerFallbackIcon extends StatelessWidget {
  const _AppPickerFallbackIcon({required this.name, required this.size});

  final String name;
  final double size;

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
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: cs.primary,
        ),
      ),
    );
  }
}
