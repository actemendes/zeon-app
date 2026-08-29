import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/active/ip_widget.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

class ActiveProxyFooter extends ConsumerWidget with InfraLogger {
  const ActiveProxyFooter({required this.activeProxy, super.key});

  final AsyncValue<OutboundInfo> activeProxy;

  static const _panelRadius = 16.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(
      connectionNotifierProvider.select((value) => value.valueOrNull ?? const Disconnected()),
    );
    final proxy = activeProxy.valueOrNull;
    final t = ref.watch(translationsProvider).requireValue;

    final theme = Theme.of(context);
    final displayInfo = proxy == null ? null : resolveOutboundDisplayInfo(proxy);
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
      key: const ValueKey('home_server_picker'),
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
          onTap: connectionState == const Connected() ? () => context.goNamed('proxies') : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: proxy == null
                ? _ServerPickerPlaceholder(
                    connected: connectionState == const Connected(),
                    label: t.pages.proxies.title,
                    foregroundColor: navBarTextColor,
                    iconColor: navBarIconColor,
                  )
                : Row(
                    children: [
                      InkWell(
                        onTap: () async {
                          await handleUrlTest();
                          await ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: proxy);
                        },
                        onLongPress: () {},
                        borderRadius: BorderRadius.circular(_panelRadius),
                        child: IPCountryFlag(
                          countryCode: resolveProxyCountryCode(
                            tagDisplay: proxy.tagDisplay,
                            fallbackCountryCode: displayInfo?.countryCode ?? proxy.ipinfo.countryCode,
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
                                displayInfo?.title ?? proxy.tagDisplay,
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

class _ServerPickerPlaceholder extends StatelessWidget {
  const _ServerPickerPlaceholder({
    required this.connected,
    required this.label,
    required this.foregroundColor,
    required this.iconColor,
  });

  final bool connected;
  final String label;
  final Color foregroundColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: ValueKey(connected ? 'home_server_picker_loading' : 'home_server_picker_unavailable'),
      children: [
        SizedBox.square(
          dimension: 40,
          child: Center(
            child: connected
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.dns_outlined, color: iconColor, size: 24),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, color: foregroundColor),
          ),
        ),
        const SizedBox(width: 12),
        Icon(Icons.apps, color: iconColor, size: 20),
      ],
    );
  }
}
