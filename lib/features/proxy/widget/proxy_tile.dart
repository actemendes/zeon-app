import 'package:flutter/material.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';

class ProxyTile extends StatelessWidget with PresLogger {
  const ProxyTile(this.proxy, {super.key, required this.selected, required this.onTap});

  final OutboundInfo proxy;
  final bool selected;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final themeTextColor = theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface;
    final selectedTextColor = isDark ? themeTextColor : theme.colorScheme.onPrimaryContainer;

    final primaryColor = selected ? selectedTextColor : themeTextColor;
    final iconColor = selected ? selectedTextColor : themeTextColor;
    final tileColor = selected ? theme.colorScheme.primaryContainer : Colors.transparent;
    final hasDelay = proxy.urlTestDelay != 0;
    final hasNoPing = proxy.urlTestDelay > 65000;
    final hasDownload = proxy.download > 0;

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
            formatProxyDisplayName(proxy.tagDisplay),
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
          countryCode: resolveProxyCountryCode(
            tagDisplay: proxy.tagDisplay,
            fallbackCountryCode: proxy.ipinfo.countryCode,
          ),
          size: 40,
        ),
      ),
      trailing: hasDelay || hasDownload
          ? SizedBox(
              width: 44,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (hasDelay)
                    Text(
                      hasNoPing ? "\u00D7" : proxy.urlTestDelay.toString(),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: delayColor(context, proxy.urlTestDelay),
                        fontSize: hasNoPing ? 16 : null,
                        height: hasNoPing ? 1 : null,
                      ),
                    ),
                  if (hasDelay && hasDownload) const SizedBox(height: 2),
                  if (hasDownload) Icon(Icons.download_rounded, size: 16, color: iconColor.withValues(alpha: .85)),
                ],
              ),
            )
          : null,
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
