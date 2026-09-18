import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/utils.dart';

class ProxiesOverviewPage extends HookConsumerWidget with PresLogger {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    final ipv6Mode = ref.watch(ConfigOptions.ipv6Mode);

    return Scaffold(
      key: const ValueKey(UiNames.screenProxiesOverview),
      appBar: AppBar(title: Text(t.pages.proxies.title.toUpperCase())),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: PopupMenuButton<ProxiesSort>(
                    initialValue: sortBy,
                    onSelected: ref.read(proxiesSortNotifierProvider.notifier).update,
                    tooltip: t.pages.proxies.sort,
                    itemBuilder: (context) => [
                      for (final value in ProxiesSort.values)
                        PopupMenuItem(value: value, child: Text(value.present(t))),
                    ],
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          const Icon(FluentIcons.arrow_sort_24_regular, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              sortBy.present(t),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  key: const ValueKey('proxies_test_delay'),
                  onPressed: () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest('select'),
                  tooltip: t.pages.proxies.testDelay,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.speed_rounded, size: 22),
                ),
              ],
            ),
          ),
          Expanded(
            child: proxies.when(
              data: (group) => group != null
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final crossAxisCount = PlatformUtils.isMobile && width < 600
                            ? 1
                            : max(1, (width / 536).floor());
                        return GridView.builder(
                          // The shell extends this route behind the mobile navbar.
                          // Keep the last server scrollable above the whole panel.
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
                          itemCount: group.items.length,
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            mainAxisExtent: 24 + max(42, MediaQuery.textScalerOf(context).scale(16) * 1.3 * 2),
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                          ),
                          itemBuilder: (context, index) {
                            final proxy = group.items[index];
                            final selectedProxy = findOutboundByTagOrDisplay(group.items, group.selected);
                            final isAutoSelected = selectedProxy != null && isAutoSelectedOutbound(selectedProxy);
                            final realAutoTag = isAutoSelected
                                ? resolveRealOutboundTag(autoOutbound: selectedProxy, allOutbounds: group.items)
                                : null;
                            final isActive =
                                proxy.tag == group.selected || (isAutoSelected && proxy.tag == realAutoTag);
                            final displayInfo = resolveOutboundDisplayInfo(
                              proxy,
                              allOutbounds: group.items,
                              translations: t,
                            );
                            final ipv6Status = proxy.isGroup ? "not_tested" : proxy.ipv6Status;
                            final ipv6StatusText = ipv6Mode == IPv6Mode.disable
                                ? null
                                : switch (ipv6Status) {
                                    "supported" => t.pages.proxies.ipv6.supported,
                                    "unavailable" => t.pages.proxies.ipv6.unavailable,
                                    "checking" => t.pages.proxies.ipv6.checking,
                                    _ => t.pages.proxies.ipv6.notTested,
                                  };
                            return ProxyTile(
                              proxy,
                              selected: group.selected == proxy.tag,
                              isActive: isActive,
                              countryCode: displayInfo.countryCode,
                              displayTitle: displayInfo.title,
                              ipv6Status: ipv6Status,
                              ipv6StatusText: ipv6StatusText,
                              ipv6Mode: ipv6Mode,
                              onTap: () async {
                                await ref
                                    .read(proxiesOverviewNotifierProvider.notifier)
                                    .changeProxy(group.tag, proxy.tag);
                              },
                            );
                          },
                        );
                      },
                    )
                  : Center(child: Text(t.pages.proxies.empty)),
              error: (error, stackTrace) => Center(child: Text(t.presentShortError(error))),
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}
