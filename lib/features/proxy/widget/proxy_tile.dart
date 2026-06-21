import 'package:flutter/material.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';
import 'package:hiddify/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';

class ProxyTile extends StatelessWidget with PresLogger {
  const ProxyTile(
    this.proxy, {
    super.key,
    required this.selected,
    required this.isActive,
    this.countryCode,
    required this.onTap,
  });

  final OutboundInfo proxy;
  final bool selected;
  final bool isActive;
  final String? countryCode;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final themeTextColor = theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface;
    final selectedTextColor = isDark ? themeTextColor : theme.colorScheme.onPrimaryContainer;

    final primaryColor = selected ? selectedTextColor : themeTextColor;
    final tileColor = selected ? theme.colorScheme.primaryContainer : Colors.transparent;
    final pingText = formatOutboundPing(proxy);
    final failedPing = proxyPingFailed(proxy);
    final pingColor = failedPing
        ? theme.colorScheme.error
        : delayColor(context, proxy.hasUrlTestDelay() ? proxy.urlTestDelay : 0);

    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      tileColor: tileColor,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minTileHeight: 64,
      minLeadingWidth: 40,
      horizontalTitleGap: 12,
      title: SizedBox(
        height: 40,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            formatOutboundTitle(proxy),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: primaryColor,
              fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
            ),
          ),
        ),
      ),
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: () {},
        child: IPCountryFlag(
          countryCode:
              countryCode ??
              resolveProxyCountryCode(tagDisplay: proxy.tagDisplay, fallbackCountryCode: proxy.ipinfo.countryCode),
          size: 40,
        ),
      ),
      trailing: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                pingText,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: selected ? primaryColor : pingColor,
                  fontSize: failedPing ? 16 : null,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(width: 6),
            QualityBars.fromOutbound(proxy, isActive: isActive),
          ],
        ),
      ),
      onTap: onTap,
    );
  }

  Color delayColor(BuildContext context, int delay) {
    if (Theme.of(context).brightness == Brightness.dark) {
      return switch (delay) {
        < 800 => Colors.lightGreen,
        < 1500 => Colors.orange,
        _ => Colors.redAccent,
      };
    }
    return switch (delay) {
      < 800 => Colors.green,
      < 1500 => Colors.deepOrangeAccent,
      _ => Colors.red,
    };
  }
}
