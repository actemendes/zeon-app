import 'package:flutter/material.dart';
import 'package:zeon/features/proxy/active/ip_widget.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/gen/fonts.gen.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

class ProxyTile extends StatelessWidget with PresLogger {
  const ProxyTile(
    this.proxy, {
    super.key,
    required this.selected,
    required this.isActive,
    this.countryCode,
    this.ipv6Status,
    this.ipv6StatusText,
    required this.ipv6Mode,
    required this.onTap,
  });

  final OutboundInfo proxy;
  final bool selected;
  final bool isActive;
  final String? countryCode;
  final String? ipv6Status;
  final String? ipv6StatusText;
  final IPv6Mode ipv6Mode;
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
    final showIpv6Outline = ipv6Mode != IPv6Mode.disable && ipv6Status == "supported";
    final showIpv6Unavailable = ipv6Mode == IPv6Mode.only && ipv6Status == "unavailable";

    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      tileColor: tileColor,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minTileHeight: 64,
      minLeadingWidth: 40,
      horizontalTitleGap: 12,
      title: Text(
        formatOutboundTitle(proxy),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: primaryColor,
          fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
        ),
      ),
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: () {},
        child: Semantics(
          label: ipv6Mode == IPv6Mode.disable ? null : ipv6StatusText,
          child: Container(
            key: const ValueKey('proxy-ipv6-flag-frame'),
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: showIpv6Outline
                ? BoxDecoration(
                    border: Border.all(color: const Color(0xFF3CE74F), width: 2),
                    borderRadius: BorderRadius.circular(9),
                  )
                : null,
            child: IPCountryFlag(
              countryCode:
                  countryCode ??
                  resolveProxyCountryCode(tagDisplay: proxy.tagDisplay, fallbackCountryCode: proxy.ipinfo.countryCode),
              size: 40,
            ),
          ),
        ),
      ),
      trailing: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIpv6Unavailable)
              Icon(
                Icons.close_rounded,
                key: const ValueKey('proxy-ipv6-unavailable-cross'),
                size: 20,
                color: selected ? primaryColor : theme.colorScheme.error,
                semanticLabel: ipv6StatusText,
              )
            else
              Flexible(
                child: Text(
                  pingText,
                  key: const ValueKey('proxy-ping'),
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
