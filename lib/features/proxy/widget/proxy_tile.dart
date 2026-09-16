import 'package:flutter/material.dart';
import 'package:zeon/features/proxy/active/ip_widget.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

class ProxyTile extends StatelessWidget with PresLogger {
  const ProxyTile(
    this.proxy, {
    super.key,
    required this.selected,
    required this.isActive,
    this.countryCode,
    this.displayTitle,
    this.ipv6Status,
    this.ipv6StatusText,
    required this.ipv6Mode,
    required this.onTap,
  });

  final OutboundInfo proxy;
  final bool selected;
  final bool isActive;
  final String? countryCode;
  final String? displayTitle;
  final String? ipv6Status;
  final String? ipv6StatusText;
  final IPv6Mode ipv6Mode;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final primaryColor = selected ? cs.onPrimaryContainer : cs.onSurface;
    final tileColor = selected ? cs.primaryContainer : cs.secondaryContainer;
    final pingText = formatOutboundPing(proxy);
    final failedPing = proxyPingFailed(proxy);
    final pingColor = failedPing
        ? theme.colorScheme.error
        : delayColor(context, proxy.hasUrlTestDelay() ? proxy.urlTestDelay : 0);
    final showIpv6Outline = ipv6Mode != IPv6Mode.disable && ipv6Status == "supported";
    final showIpv6Unavailable = ipv6Mode == IPv6Mode.only && ipv6Status == "unavailable";

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: tileColor,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Semantics(
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
                    // The flag is part of the row's selection target.
                    child: IgnorePointer(
                      child: IPCountryFlag(
                        countryCode:
                            countryCode ??
                            resolveProxyCountryCode(
                              tagDisplay: proxy.tagDisplay,
                              fallbackCountryCode: proxy.ipinfo.countryCode,
                            ),
                        size: 34,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle ?? formatOutboundTitle(proxy),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontFamilyFallback: const ['Emoji'],
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          QualityBars.fromOutbound(
                            proxy,
                            isActive: isActive,
                            activeColor: selected ? primaryColor : null,
                            inactiveColor: primaryColor.withValues(alpha: .16),
                          ),
                          const SizedBox(width: 8),
                          if (showIpv6Unavailable || failedPing)
                            Icon(
                              Icons.close_rounded,
                              key: ValueKey(showIpv6Unavailable ? 'proxy-ipv6-unavailable-cross' : 'proxy-ping'),
                              size: 16,
                              color: selected ? primaryColor : cs.error,
                              semanticLabel: showIpv6Unavailable ? ipv6StatusText : pingText,
                            )
                          else
                            Flexible(
                              child: Text(
                                pingText,
                                key: const ValueKey('proxy-ping'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: failedPing ? 14 : 11,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                  color: selected ? primaryColor : pingColor,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 22,
                  child: selected ? Icon(Icons.check_circle_rounded, size: 22, color: primaryColor) : null,
                ),
              ],
            ),
          ),
        ),
      ),
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
      < 800 => Colors.green.shade800,
      < 1500 => Colors.deepOrangeAccent,
      _ => Colors.red,
    };
  }
}
