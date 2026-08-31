import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

class ActiveProxyDelayIndicator extends HookConsumerWidget with InfraLogger {
  const ActiveProxyDelayIndicator({required this.activeProxy, super.key});

  final AsyncValue<OutboundInfo> activeProxy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionNotifierProvider.select((value) => value.valueOrNull));
    if (connectionState is! Connected) {
      return const SizedBox();
    }
    final theme = Theme.of(context);

    if (activeProxy is! AsyncData) {
      return const SizedBox(); // Avoid building widget if data is not available
    }

    final proxy = activeProxy.value!;
    final pingText = formatOutboundPing(proxy);
    final failedPing = proxyPingFailed(proxy);

    return Center(
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
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.wifi_1_24_regular),
              const Gap(8),
              Text(
                pingText,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: failedPing ? theme.colorScheme.error : null,
                ),
              ),
              const Gap(8),
              QualityBars.fromOutbound(
                proxy,
                isActive: !failedPing,
                activeColor: failedPing ? theme.colorScheme.error : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
