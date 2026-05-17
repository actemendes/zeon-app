import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/ui/ui_names.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/site_routing/model/site_routing_mode.dart';
import 'package:hiddify/utils/validators.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SiteRoutingPage extends HookConsumerWidget {
  const SiteRoutingPage({super.key});

  static String? _normalizeWebsite(String input) {
    var candidate = input.trim().toLowerCase();
    if (candidate.isEmpty) return null;

    candidate = candidate.replaceAll(RegExp(r'\s+'), '');
    final hasScheme = RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(candidate);
    final uri = Uri.tryParse(hasScheme ? candidate : 'https://$candidate');
    if (uri != null && uri.host.isNotEmpty) {
      candidate = uri.host.toLowerCase();
    }

    candidate = candidate
        .replaceFirst(RegExp(r'^\*\.'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .replaceFirst(RegExp(r'^\.'), '')
        .replaceFirst(RegExp(r'\.$'), '');

    if (isDomain(candidate)) return candidate;
    return null;
  }

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
            final normalized = _normalizeWebsite(value ?? '');
            if (normalized == null) return t.pages.settings.routing.websites.validation.invalid;
            if (websites.contains(normalized)) return t.pages.settings.routing.websites.validation.duplicate;
            return null;
          },
        );
    if (result == null) return;
    final normalized = _normalizeWebsite(result);
    if (normalized == null) return;
    await notifier.update([...websites, normalized]);
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
            final normalized = _normalizeWebsite(value ?? '');
            if (normalized == null) return t.pages.settings.routing.websites.validation.invalid;
            if (normalized != current && websites.contains(normalized)) {
              return t.pages.settings.routing.websites.validation.duplicate;
            }
            return null;
          },
        );
    if (result == null) return;
    final normalized = _normalizeWebsite(result);
    if (normalized == null) return;
    final updated = [...websites]..[index] = normalized;
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
      key: const ValueKey(UiNames.screenSiteRouting),
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
                      await websitesNotifier.update(const []);
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
      floatingActionButton: websites.isNotEmpty
          ? FloatingActionButton(
              foregroundColor: fabForegroundColor,
              onPressed: () => _showAddDialog(ref: ref, t: t, websites: websites, notifier: websitesNotifier),
              child: Icon(Icons.add_rounded, color: fabForegroundColor),
            )
          : FloatingActionButton.extended(
              foregroundColor: fabForegroundColor,
              onPressed: () => _showAddDialog(ref: ref, t: t, websites: websites, notifier: websitesNotifier),
              icon: Icon(Icons.add_rounded, color: fabForegroundColor),
              label: Text(t.pages.settings.routing.websites.addNew),
            ),
      body: websites.isEmpty
          ? Center(child: Text(t.pages.settings.routing.websites.empty))
          : ListView.builder(
              itemCount: websites.length,
              itemBuilder: (context, index) {
                final website = websites[index];
                return ListTile(
                  title: Text(website, maxLines: 1, overflow: TextOverflow.ellipsis),
                  leading: const Icon(Icons.language_rounded),
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
                          final updated = [...websites]..removeAt(index);
                          await websitesNotifier.update(updated);
                        },
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
