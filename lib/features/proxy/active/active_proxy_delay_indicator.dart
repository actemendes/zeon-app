import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: compact ? 4 : 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
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
              const Gap(8),
              Text(
                pingText,
                style: (compact ? theme.textTheme.bodyMedium : theme.textTheme.titleMedium)?.copyWith(
                  fontFamily: compact ? 'Montserrat' : null,
                  fontWeight: compact ? FontWeight.w600 : FontWeight.bold,
                  color: failedPing ? theme.colorScheme.error : null,
                ),
              ),
              if (!compact) ...[
                const Gap(8),
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
