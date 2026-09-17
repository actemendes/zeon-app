import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_snapshot.dart';
import 'package:zeon/features/proxy/active/ip_widget.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/utils/custom_loggers.dart';

class ActiveProxyFooter extends ConsumerWidget with InfraLogger {
  const ActiveProxyFooter({
    super.key,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    this.backgroundColor,
    this.desktop = false,
  });

  final EdgeInsetsGeometry margin;
  final Color? backgroundColor;
  final bool desktop;

  static const _panelRadius = 20.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(homeConnectionStateProvider);
    if (!connectionState.isConnected) {
      return const SizedBox.shrink();
    }

    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final session = ref.watch(homeVpnSessionSnapshotProvider);
    // On Android the native snapshot survives foreground stream teardown and
    // wins over delayed selector/stats data, including a previous manual/Auto choice.
    final proxy = session == null
        ? activeProxy.valueOrNull
        : activeProxyFromSessionSnapshot(session.valueOrNull, activeProxy: activeProxy.valueOrNull);
    final t = ref.watch(translationsProvider).requireValue;

    final theme = Theme.of(context);
    final displayInfo = proxy == null ? null : resolveOutboundDisplayInfo(proxy, translations: t);
    final serverTextColor = theme.brightness == Brightness.light
        ? theme.colorScheme.onSurface
        : theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{})?.color ?? theme.colorScheme.onSurface;
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
      margin: margin,
      decoration: BoxDecoration(
        color: backgroundColor ?? theme.colorScheme.secondaryContainer,
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
          onTap: () => context.goNamed('proxies'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: proxy == null
                ? Semantics(
                    label: '${t.pages.proxies.activeProxy}\n${t.pages.proxies.title}',
                    button: true,
                    child: _ServerPickerPlaceholder(
                      label: t.pages.proxies.title,
                      foregroundColor: serverTextColor,
                      iconColor: navBarIconColor,
                    ),
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
                      const SizedBox(width: 14),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Semantics(
                              label: t.pages.proxies.activeProxy,
                              child: Text(
                                displayInfo?.title ?? proxy.tagDisplay,
                                style:
                                    (theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{}) ??
                                            theme.textTheme.labelMedium)
                                        ?.copyWith(color: serverTextColor, fontWeight: FontWeight.w700),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Icon(desktop ? Icons.apps : Icons.chevron_right_rounded, color: navBarIconColor, size: 19),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ServerPickerPlaceholder extends StatelessWidget {
  const _ServerPickerPlaceholder({required this.label, required this.foregroundColor, required this.iconColor});

  final String label;
  final Color foregroundColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('home_server_picker_loading'),
      children: [
        const SizedBox.square(
          dimension: 40,
          child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: foregroundColor),
          ),
        ),
        const SizedBox(width: 14),
        Icon(Icons.apps, color: iconColor, size: 20),
      ],
    );
  }
}
