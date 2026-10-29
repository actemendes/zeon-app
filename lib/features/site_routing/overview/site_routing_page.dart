import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/utils/preferences_utils.dart';
import 'package:zeon/features/per_app_proxy/data/desktop_routing_rule_compiler.dart';
import 'package:zeon/features/site_routing/model/site_routing_mode.dart';

class SiteRoutingPage extends HookConsumerWidget {
  const SiteRoutingPage({super.key});

  static String? normalizeEntry(String input) => DesktopRoutingRuleCompiler.normalizeSiteOrResourceEntry(input);

  Future<void> _showAddDialog({
    required WidgetRef ref,
    required Translations t,
    required List<String> websites,
    required PreferencesNotifier<List<String>, List<String>> notifier,
  }) async {
    final result = await ref
        .read(dialogNotifierProvider.notifier)
        .showSettingText(
          lable: t.pages.settings.routing.websites.addNew,
          validator: (value) {
            final normalized = normalizeEntry(value ?? '');
            if (normalized == null) return t.pages.settings.routing.websites.validation.invalid;
            if (websites.contains(normalized)) return t.pages.settings.routing.websites.validation.duplicate;
            return null;
          },
        );
    if (result == null) return;
    final normalized = normalizeEntry(result);
    if (normalized == null) return;
    await notifier.update(<String>[...websites, normalized]);
  }

  Future<void> _showEditDialog({
    required WidgetRef ref,
    required Translations t,
    required List<String> websites,
    required int index,
    required PreferencesNotifier<List<String>, List<String>> notifier,
  }) async {
    final current = websites[index];
    final result = await ref
        .read(dialogNotifierProvider.notifier)
        .showSettingText(
          lable: t.pages.settings.routing.websites.update,
          value: current,
          validator: (value) {
            final normalized = normalizeEntry(value ?? '');
            if (normalized == null) return t.pages.settings.routing.websites.validation.invalid;
            if (normalized != current && websites.contains(normalized)) {
              return t.pages.settings.routing.websites.validation.duplicate;
            }
            return null;
          },
        );
    if (result == null) return;
    final normalized = normalizeEntry(result);
    if (normalized == null) return;
    final updated = <String>[...websites]..[index] = normalized;
    await notifier.update(updated);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final fabForegroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : null;

    final mode = ref.watch(Preferences.siteRoutingMode);
    final websitesProvider = mode == SiteRoutingMode.include ? Preferences.includeSites : Preferences.excludeSites;
    final websites = ref.watch(websitesProvider);
    final websitesNotifier = ref.read(websitesProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.settings.routing.websites.title.toUpperCase()),
        actions: [
          IconButton(
            onPressed: websites.isEmpty
                ? null
                : () async {
                    final shouldClear = await ref
                        .read(dialogNotifierProvider.notifier)
                        .showConfirmation(
                          title: t.pages.settings.routing.websites.clearAllSelections,
                          message: t.pages.settings.routing.websites.clearAllSelectionsMsg,
                        );
                    if (shouldClear) {
                      await websitesNotifier.update(const <String>[]);
                    }
                  },
            icon: const Icon(Icons.clear_all_rounded),
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
                PopupMenuButton<SiteRoutingMode>(
                  borderRadius: BorderRadius.circular(8),
                  position: PopupMenuPosition.under,
                  tooltip: mode.present(t).message,
                  initialValue: mode,
                  onSelected: (selectedMode) async {
                    if (selectedMode == SiteRoutingMode.off && context.mounted) context.pop();
                    await ref.read(Preferences.siteRoutingMode.notifier).update(selectedMode);
                  },
                  itemBuilder: (context) => SiteRoutingMode.values
                      .map((e) => PopupMenuItem(value: e, child: Text(e.present(t).message)))
                      .toList(),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: theme.colorScheme.surface,
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        const Gap(16),
                        Text(mode.present(t).title),
                        const Gap(4),
                        Icon(Icons.arrow_drop_down_rounded, color: theme.colorScheme.onSurfaceVariant),
                        const Gap(8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        foregroundColor: fabForegroundColor,
        tooltip: t.pages.settings.routing.websites.addNew,
        onPressed: () => _showAddDialog(ref: ref, t: t, websites: websites, notifier: websitesNotifier),
        child: Icon(Icons.add_rounded, color: fabForegroundColor),
      ),
      body: websites.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t.pages.settings.routing.websites.empty,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              itemCount: websites.length,
              itemBuilder: (context, index) {
                final website = websites[index];
                final isIpResource = DesktopRoutingRuleCompiler.isIpOrCidrEntry(website);
                return Material(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(index == 0 ? 20 : 0),
                    bottom: Radius.circular(index == websites.length - 1 ? 20 : 0),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    title: Text(website, maxLines: 1, overflow: TextOverflow.ellipsis),
                    leading: Icon(isIpResource ? Icons.lan_rounded : Icons.language_rounded),
                    onTap: () =>
                        _showEditDialog(ref: ref, t: t, websites: websites, index: index, notifier: websitesNotifier),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _showEditDialog(
                            ref: ref,
                            t: t,
                            websites: websites,
                            index: index,
                            notifier: websitesNotifier,
                          ),
                          icon: const Icon(Icons.edit_rounded),
                        ),
                        IconButton(
                          onPressed: () async {
                            final updated = <String>[...websites]..removeAt(index);
                            await websitesNotifier.update(updated);
                          },
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
