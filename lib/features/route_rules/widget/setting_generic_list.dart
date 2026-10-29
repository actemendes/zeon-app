import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/route_rules/widget/setting_detail_chips.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class SettingGenericList<T extends Object> extends ConsumerWidget {
  const SettingGenericList({
    super.key,
    required this.title,
    required this.values,
    required this.onTap,
    this.useEllipsis = false,
    this.isPackageName = false,
    this.showPlatformWarning = false,
    this.icon,
  });

  final String title;
  final List<T> values;
  final GestureTapCallback? onTap;
  final bool useEllipsis;
  final bool isPackageName;
  final bool showPlatformWarning;
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          title: Text(title),
          leading: icon != null ? Icon(icon) : null,
          subtitle: showPlatformWarning
              ? Row(
                  children: [
                    const Icon(size: 15, Icons.info_outline_rounded, color: Colors.amber),
                    const Gap(4),
                    Expanded(
                      child: Text(
                        t.pages.settings.routing.routeRule.rule.notAvailabeInThisPlatform,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                )
              : values.isEmpty
              ? Text(t.common.empty)
              : null,
          onTap: onTap,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (values.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${values.length}',
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                ),
                const Gap(8),
              ],
              Icon(Icons.chevron_right_rounded, size: 19, color: cs.onSurfaceVariant),
            ],
          ),
        ),
        if (values.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SettingDetailChips<T>(
              values: values,
              useEllipsis: useEllipsis,
              isPackageName: isPackageName,
            ),
          ),
      ],
    );
  }
}
