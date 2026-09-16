import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/utils/custom_loggers.dart';

class ActiveProxyDelayIndicator extends HookConsumerWidget with InfraLogger {
  const ActiveProxyDelayIndicator({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final theme = Theme.of(context);

    if (activeProxy is! AsyncData) {
      return const SizedBox(); // Avoid building widget if data is not available
    }

    final proxy = activeProxy.value!;
    final pingText = formatOutboundPing(proxy);
    final failedPing = proxyPingFailed(proxy);
    final isLightTheme = theme.brightness == Brightness.light;
    final activeBarColor = failedPing ? theme.colorScheme.error : (isLightTheme ? theme.colorScheme.onSurface : null);
    final inactiveBarColor = isLightTheme ? theme.colorScheme.onSurface.withValues(alpha: 0.35) : null;

    return Center(
      widthFactor: compact ? 1 : null,
      child: InkWell(
        onTap: () async {
          try {
            await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
          } catch (e) {
            // Handle error here
            loggy.error("Error during URL test: $e");
          }
        },
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 0 : 8, horizontal: compact ? 0 : 16),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (compact)
                QualityBars.fromOutbound(
                  proxy,
                  isActive: !failedPing,
                  activeColor: activeBarColor,
                  inactiveColor: inactiveBarColor,
                )
              else
                const Icon(FluentIcons.wifi_1_24_regular),
              Text(
                pingText,
                style: (compact ? theme.textTheme.bodyMedium : theme.textTheme.titleMedium)?.copyWith(
                  fontSize: compact ? 14 : null,
                  fontFamily: compact ? 'Montserrat' : null,
                  fontWeight: compact ? FontWeight.w600 : FontWeight.bold,
                  color: failedPing ? theme.colorScheme.error : null,
                ),
              ),
              if (!compact) ...[
                QualityBars.fromOutbound(
                  proxy,
                  isActive: !failedPing,
                  activeColor: activeBarColor,
                  inactiveColor: inactiveBarColor,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
