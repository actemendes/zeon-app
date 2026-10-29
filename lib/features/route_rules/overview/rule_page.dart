import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:protobuf/protobuf.dart';
import 'package:recase/recase.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/route_rules/notifier/rule_notifier.dart';
import 'package:zeon/features/route_rules/overview/android_apps_page.dart';
import 'package:zeon/features/route_rules/overview/generic_list_page.dart';
import 'package:zeon/features/route_rules/widget/setting_checkbox.dart';
import 'package:zeon/features/route_rules/widget/setting_generic_list.dart';
import 'package:zeon/features/route_rules/widget/setting_radio.dart';
import 'package:zeon/features/route_rules/widget/setting_text.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/generated/v2/config/route_rule.pb.dart';

class RulePage extends HookConsumerWidget {
  const RulePage({super.key, this.ruleListOrder});

  final int? ruleListOrder;

  String getTitle(Map<String, String> t, RuleEnum key) => t[key.name.snakeCase] ?? key.name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final isRuleEdited = ref.watch(IsRuleEditedProvider(ruleListOrder));
    final packageNames = ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.packageNames));
    final processNames = ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.processNames));
    final processPaths = ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.processPaths));

    return PopScope(
      canPop: !isRuleEdited,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (isRuleEdited) {
          final shouldSave = await ref
              .read(dialogNotifierProvider.notifier)
              .showSave(
                title: t.pages.settings.routing.routeRule.rule.ruleChanged,
                description: t.pages.settings.routing.routeRule.rule.ruleChangedMsg,
              );
          if (shouldSave == null) return;
          if (shouldSave == true) {
            ref.read(ruleNotifierProvider(ruleListOrder).notifier).save();
            if (context.mounted) Navigator.of(context).pop();
          } else {
            if (context.mounted) Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        key: const ValueKey(UiNames.screenRule),
        appBar: AppBar(
          centerTitle: false,
          titleTextStyle: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          title: Text(t.pages.settings.routing.routeRule.rule.title.toUpperCase()),
          actions: [
            IconButton(
              onPressed: isRuleEdited
                  ? () {
                      ref.read(ruleNotifierProvider(ruleListOrder).notifier).save();
                      Navigator.of(context).pop();
                    }
                  : null,
              icon: const Icon(Icons.check_rounded),
            ),
            const Gap(8),
          ],
        ),
        body: SettingsList(
          children: [
            SettingsGroup(
              children: [
                SettingText(
                  title: RuleEnum.name.present(t),
                  icon: Icons.label_outline_rounded,
                  value: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.name)),
                  setValue: (value) =>
                      ref.read(ruleNotifierProvider(ruleListOrder).notifier).update<String>(RuleEnum.name, value),
                ),
                SettingRadio<Outbound>(
                  title: RuleEnum.outbound.present(t),
                  icon: Icons.alt_route_rounded,
                  values: Outbound.values,
                  value: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.outbound)),
                  setValue: (value) =>
                      ref.read(ruleNotifierProvider(ruleListOrder).notifier).update<Outbound>(RuleEnum.outbound, value),
                  defaultValue: Outbound.direct,
                  t: t.pages.settings.routing.routeRule.rule.outbound,
                ),
              ],
            ),
            SettingsGroup(
              title: t.pages.settings.routing.perAppProxy.title,
              children: [
                if (PlatformUtils.isDesktop)
                  SettingsTile(
                    leading: const Icon(Icons.apps_rounded),
                    title: Text(t.pages.settings.routing.perAppProxy.title),
                    subtitle: Text(
                      processPaths.isEmpty ? t.common.empty : '${processPaths.length}',
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => AndroidAppsPage(ruleListOrder: ruleListOrder),
                        fullscreenDialog: true,
                      ),
                    ),
                  ),
                if (PlatformUtils.isAndroid || packageNames.isNotEmpty)
                  SettingGenericList<String>(
                    title: RuleEnum.packageName.present(t),
                    icon: Icons.apps_rounded,
                    values: packageNames,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => AndroidAppsPage(ruleListOrder: ruleListOrder),
                        fullscreenDialog: true,
                      ),
                    ),
                    isPackageName: true,
                    showPlatformWarning: !PlatformUtils.isAndroid,
                  ),
                if (PlatformUtils.isDesktop || processPaths.isNotEmpty)
                  SettingGenericList<String>(
                    title: RuleEnum.processPath.present(t),
                    icon: Icons.folder_open_rounded,
                    values: processPaths,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => GenericListPage(
                          ruleListOrder: ruleListOrder,
                          ruleEnum: RuleEnum.processPath,
                          validator: (value) {
                            if (isProcessPath('$value')) return null;
                            return t.pages.settings.routing.routeRule.rule.validProcessPath;
                          },
                        ),
                        fullscreenDialog: true,
                      ),
                    ),
                    showPlatformWarning: !PlatformUtils.isDesktop,
                  ),
                if (PlatformUtils.isDesktop || processNames.isNotEmpty)
                  SettingGenericList<String>(
                    title: RuleEnum.processName.present(t),
                    icon: Icons.terminal_rounded,
                    values: processNames,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => GenericListPage(
                          ruleListOrder: ruleListOrder,
                          ruleEnum: RuleEnum.processName,
                          validator: (value) {
                            if (isProcessName('$value')) return null;
                            return t.pages.settings.routing.routeRule.rule.validProcessName;
                          },
                        ),
                        fullscreenDialog: true,
                      ),
                    ),
                    showPlatformWarning: !PlatformUtils.isDesktop,
                  ),
              ],
            ),
            SettingsGroup(
              title: t.pages.settings.routing.websites.title,
              children: [
                SettingGenericList<String>(
                  title: RuleEnum.domain.present(t),
                  icon: Icons.language_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.domains)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.domain,
                        validator: (value) {
                          if (isDomain('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validDomain;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.domainSuffix.present(t),
                  icon: Icons.dns_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.domainSuffixes)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.domainSuffix,
                        validator: (value) {
                          if (isDomainSuffix('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validDomainSuffix;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.domainKeyword.present(t),
                  icon: Icons.manage_search_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.domainKeywords)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          GenericListPage(ruleListOrder: ruleListOrder, ruleEnum: RuleEnum.domainKeyword),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.domainRegex.present(t),
                  icon: Icons.code_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.domainRegexes)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          GenericListPage(ruleListOrder: ruleListOrder, ruleEnum: RuleEnum.domainRegex),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'IP / CIDR',
              children: [
                SettingGenericList<String>(
                  title: RuleEnum.ipCidr.present(t),
                  icon: Icons.lan_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.ipCidrs)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.ipCidr,
                        validator: (value) {
                          if (isIpCidr('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validIpCidr;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.sourceIpCidr.present(t),
                  icon: Icons.router_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.sourceIpCidrs)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.sourceIpCidr,
                        validator: (value) {
                          if (isIpCidr('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validIpCidr;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: t.pages.settings.groups.traffic,
              children: [
                SettingRadio<Network>(
                  title: RuleEnum.network.present(t),
                  icon: Icons.swap_vert_rounded,
                  values: Network.values,
                  value: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.network)),
                  setValue: (value) =>
                      ref.read(ruleNotifierProvider(ruleListOrder).notifier).update<Network>(RuleEnum.network, value),
                  defaultValue: Network.all,
                  t: t.pages.settings.routing.routeRule.rule.network,
                ),
                SettingCheckbox(
                  title: RuleEnum.protocol.present(t),
                  icon: Icons.security_rounded,
                  values: Protocol.values,
                  selectedValues: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.protocols)),
                  setValue: (value) => ref
                      .read(ruleNotifierProvider(ruleListOrder).notifier)
                      .update<List<ProtobufEnum>>(RuleEnum.protocol, value),
                  t: t.pages.settings.routing.routeRule.rule.protocol,
                ),
                SettingGenericList<String>(
                  title: RuleEnum.portRange.present(t),
                  icon: Icons.numbers_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.portRanges)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.portRange,
                        validator: (value) {
                          if (isPortOrPortRange('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validPortRange;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.sourcePortRange.present(t),
                  icon: Icons.pin_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.sourcePortRanges)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.sourcePortRange,
                        validator: (value) {
                          if (isPortOrPortRange('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validPortRange;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
                SettingGenericList<String>(
                  title: RuleEnum.ruleSet.present(t),
                  icon: Icons.dataset_linked_rounded,
                  values: ref.watch(ruleNotifierProvider(ruleListOrder).select((value) => value.ruleSets)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => GenericListPage(
                        ruleListOrder: ruleListOrder,
                        ruleEnum: RuleEnum.ruleSet,
                        validator: (value) {
                          if (isUrl('$value')) return null;
                          return t.pages.settings.routing.routeRule.rule.validUrl;
                        },
                      ),
                      fullscreenDialog: true,
                    ),
                  ),
                  useEllipsis: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
