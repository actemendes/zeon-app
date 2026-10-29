import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/route_rules/notifier/rules_notifier.dart';
import 'package:zeon/features/route_rules/overview/rule_page.dart';
import 'package:zeon/features/route_rules/widget/rule_tile.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class RulesPage extends HookConsumerWidget {
  const RulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final fabForegroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : null;
    final rules = ref.watch(rulesNotifierProvider);
    final menuItems = <PopupMenuEntry>[
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromClipboard,
        child: Text(t.pages.settings.routing.routeRule.options.import.clipboard),
      ),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromJsonFile,
        child: Text(t.pages.settings.routing.routeRule.options.import.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).exportJsonToClipboard(),
        child: Text(t.pages.settings.routing.routeRule.options.export.clipboard),
      ),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).saveRulesAsJsonFile(),
        child: Text(t.pages.settings.routing.routeRule.options.export.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).resetRules,
        child: Text(t.pages.settings.routing.routeRule.options.reset),
      ),
    ];

    return Scaffold(
      key: const ValueKey(UiNames.screenRules),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.settings.routing.routeRule.title.toUpperCase()),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.more_vert_rounded),
            itemBuilder: (_) => rules.isEmpty ? menuItems.getRange(0, 2).toList() : menuItems,
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: rules.isNotEmpty
          ? FloatingActionButton(
              foregroundColor: fabForegroundColor,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const RulePage())),
              child: Icon(Icons.add_rounded, color: fabForegroundColor),
            )
          : FloatingActionButton.extended(
              foregroundColor: fabForegroundColor,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const RulePage())),
              label: Text(t.pages.settings.routing.routeRule.createRule),
              icon: Icon(Icons.add_rounded, color: fabForegroundColor),
            ),
      body: rules.isEmpty
          ? SettingsList(
              children: [
                SettingsHint(message: t.pages.settings.routing.hint),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      leading: const Icon(Icons.alt_route_rounded),
                      title: Text(t.pages.settings.routing.routeRule.createRule),
                      subtitle: Text(t.common.empty),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (context) => const RulePage())),
                    ),
                  ],
                ),
              ],
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) => Material(color: Colors.transparent, child: child),
              onReorder: ref.read(rulesNotifierProvider.notifier).reorder,
              itemBuilder: (context, index) => RuleTile(key: Key('$index'), index: index, rule: rules[index]),
              itemCount: rules.length,
            ),
    );
  }
}
