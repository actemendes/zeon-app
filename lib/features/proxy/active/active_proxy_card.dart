import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ActiveProxyFooter extends ConsumerWidget with InfraLogger {
  const ActiveProxyFooter({super.key});

  static const _panelRadius = 16.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(
      connectionNotifierProvider.select((value) => value.valueOrNull ?? const Disconnected()),
    );

    final activeProxy = ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull));
    final t = ref.watch(translationsProvider).requireValue;

    // Early return if required data is not available
    if (connectionState != const Connected() || activeProxy == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final navBarBackground = theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final navBarTextColor =
        theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{})?.color ?? theme.colorScheme.onSurface;
    final navBarIconColor =
        theme.navigationBarTheme.iconTheme?.resolve(const <WidgetState>{})?.color ?? theme.colorScheme.onSurface;

    // Handle URL test in a way that won't trigger during build
    Future<void> handleUrlTest() async {
      try {
        if (!context.mounted) return;
        await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
      } catch (e) {
        // Handle error here
        loggy.error("Error during URL test: $e");
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: navBarBackground,
        borderRadius: BorderRadius.circular(_panelRadius),
        // boxShadow: [
        //   BoxShadow(
        //     color: theme.colorScheme.secondary.withValues(alpha: .21),
        //     blurRadius: 10,
        //     offset: const Offset(0, 4),
        //   ),
        // ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_panelRadius),
          onTap: () {
            context.goNamed('proxies');
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                InkWell(
                  onTap: () async {
                    await handleUrlTest();
                    await ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: activeProxy);
                  },
                  borderRadius: BorderRadius.circular(_panelRadius),
                  child: IPCountryFlag(
                    countryCode: resolveProxyCountryCode(
                      tagDisplay: activeProxy.tagDisplay,
                      fallbackCountryCode: activeProxy.ipinfo.countryCode,
                    ),
                    size: 40,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        label: t.pages.proxies.activeProxy,
                        child: Text(
                          getRealOutboundTag(activeProxy),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: navBarTextColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(Icons.apps, color: navBarIconColor, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String getRealOutboundTag(OutboundInfo group) {
  var tag = formatProxyDisplayName(group.tagDisplay);
  final selected = formatProxyDisplayName(group.groupSelectedTagDisplay);
  if (selected.isNotEmpty && selected != tag && selected.toLowerCase() != 'round-robin') {
    tag = '$tag → $selected';
  }
  return tag;
}
