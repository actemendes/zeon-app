import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:protobuf/protobuf.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/features/route_rules/notifier/rules_notifier.dart';
import 'package:zeon/features/route_rules/overview/rule_page.dart';
import 'package:zeon/features/route_rules/widget/setting_detail_chips.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart';

class RuleTile extends HookConsumerWidget {
  const RuleTile({super.key, required this.index, required this.rule});

  final Rule rule;
  final int index;

  Map detailChipsValue() {
    final map = rule.toProto3Json()! as Map<String, dynamic>;
    map.removeWhere((key, value) => ['list_order', 'enabled', 'name', 'outbound'].contains(key));
    map.updateAll(
      (key, value) => value is List
          ? value.length
          : value is ProtobufEnum
          ? value.name
          : value,
    );
    return map;
  }

  Map<String, String> mergeTranslation(List<Map<String, String>> translations) {
    return Map.fromEntries(translations.expand((map) => map.entries).toList());
  }

  Future handleDelete(BuildContext context, WidgetRef ref) async {
    final t = ref.watch(translationsProvider).requireValue;
    final result = await ref
        .read(dialogNotifierProvider.notifier)
        .showConfirmation(
          title: t.dialogs.confirmation.routeRule.delete.title,
          message: t.dialogs.confirmation.routeRule.delete.msg(rulename: rule.name),
          positiveBtnTxt: t.common.delete,
        );
    if (result == true) {
      await ref.read(rulesNotifierProvider.notifier).deleteRule(rule.listOrder);
    }
  }

  IconData _outboundIcon(Outbound outbound) => switch (outbound) {
    Outbound.proxy => Icons.vpn_lock_rounded,
    Outbound.direct => Icons.call_split_rounded,
    Outbound.block => Icons.block_rounded,
    _ => Icons.alt_route_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final cs = Theme.of(context).colorScheme;
    final scrollController = useScrollController();
    ref.listen(rulesNotifierProvider, (_, _) {
      if (scrollController.hasClients && scrollController.offset > 0) scrollController.jumpTo(0);
    });
    final chips = detailChipsValue().entries.toList();
    final outboundLabel = t.pages.settings.routing.routeRule.rule.outbound[rule.outbound.name] ?? rule.outbound.name;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (context) => RulePage(ruleListOrder: rule.listOrder))),
          onLongPress: () async => await handleDelete(context, ref),
          onSecondaryTapUp: PlatformUtils.isDesktop
              ? (details) {
                  final offset = details.globalPosition;
                  showMenu(
                    context: context,
                    position: RelativeRect.fromLTRB(offset.dx, offset.dy, offset.dx, offset.dy),
                    items: [
                      PopupMenuItem(
                        child: Text(t.pages.settings.routing.routeRule.deleteRule),
                        onTap: () async => await handleDelete(context, ref),
                      ),
                    ],
                  );
                }
              : null,
          child: KeyboardFocusOutline(
            includeDescendantFocus: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.drag_indicator_rounded, size: 22, color: cs.onSurfaceVariant),
                        ),
                      ),
                      const Gap(10),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(_outboundIcon(rule.outbound), size: 19, color: cs.primary),
                      ),
                      const Gap(12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rule.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                            const Gap(3),
                            Text(
                              outboundLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () async => await handleDelete(context, ref),
                        icon: Icon(Icons.delete_outline_rounded, size: 20, color: cs.onSurfaceVariant),
                        tooltip: t.pages.settings.routing.routeRule.deleteRule,
                      ),
                      const Gap(4),
                      SizedBox(
                        width: 46,
                        height: 30,
                        child: FittedBox(
                          child: Switch.adaptive(
                            value: rule.enabled,
                            trackOutlineWidth: const WidgetStatePropertyAll(0),
                            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                            onChanged: (value) async =>
                                await ref.read(rulesNotifierProvider.notifier).updateEnabled(value, rule.listOrder),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SettingDetailChips<MapEntry>(
                      values: chips,
                      scrollController: scrollController,
                      t: mergeTranslation([
                        t.pages.settings.routing.routeRule.rule.tileTitle,
                        t.pages.settings.routing.routeRule.rule.network,
                        t.pages.settings.routing.routeRule.rule.outbound,
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
