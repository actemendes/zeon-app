import 'dart:math';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxiesOverviewPage extends HookConsumerWidget with PresLogger {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final fabForegroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : null;

    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);

    // final selectActiveProxyMutation = useMutation(
    //   initialOnFailure: (error) => CustomToast.error(t.presentShortError(error)).show(context),
    // );

    return Scaffold(
      key: const ValueKey(UiNames.screenProxiesOverview),
      appBar: AppBar(
        title: Text(t.pages.proxies.title.toUpperCase()),
        actions: [
          PopupMenuButton<ProxiesSort>(
            initialValue: sortBy,
            onSelected: ref.read(proxiesSortNotifierProvider.notifier).update,
            icon: const Icon(FluentIcons.arrow_sort_24_regular),
            tooltip: t.pages.proxies.sort,
            itemBuilder: (context) {
              return [...ProxiesSort.values.map((e) => PopupMenuItem(value: e, child: Text(e.present(t))))];
            },
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        foregroundColor: fabForegroundColor,
        onPressed: () async => await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest("select"),
        tooltip: t.pages.proxies.testDelay,
        child: Icon(Icons.speed, color: fabForegroundColor),
      ),
      body: proxies.when(
        data: (group) => group != null
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final crossAxisCount = PlatformUtils.isMobile && width < 600 ? 1 : max(1, (width / 268).floor());
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 86),
                    itemCount: group.items.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisExtent: 64,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemBuilder: (context, index) {
                      final proxy = group.items[index];
                      final selectedProxy = findOutboundByTagOrDisplay(group.items, group.selected);
                      final isAutoSelected = selectedProxy != null && isAutoSelectedOutbound(selectedProxy);
                      final realAutoTag = isAutoSelected
                          ? resolveRealOutboundTag(autoOutbound: selectedProxy, allOutbounds: group.items)
                          : null;
                      final isActive = proxy.tag == group.selected || (isAutoSelected && proxy.tag == realAutoTag);
                      final displayInfo = resolveOutboundDisplayInfo(proxy, allOutbounds: group.items);
                      return ProxyTile(
                        proxy,
                        selected: group.selected == proxy.tag,
                        isActive: isActive,
                        countryCode: displayInfo.countryCode,
                        onTap: () async {
                          await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, proxy.tag);
                          // if (selectActiveProxyMutation.state.isInProgress) return;
                          // selectActiveProxyMutation.setFuture(
                          // );
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
    );
  }
}
