import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/notifier/home_selected_proxy_provider.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

class ActiveProxyDelayIndicator extends ConsumerWidget with InfraLogger {
  const ActiveProxyDelayIndicator({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proxy = ref.watch(homeSelectedProxyProvider);
    if (proxy == null && !compact) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final pingStatus = proxy == null ? ProxyPingStatus.checking : outboundPingStatus(proxy);
    final pingText = proxy == null ? '...' : formatOutboundPing(proxy);
    final failedPing = pingStatus == ProxyPingStatus.failed;
    final isLightTheme = theme.brightness == Brightness.light;
    final activeBarColor = failedPing ? theme.colorScheme.error : (isLightTheme ? theme.colorScheme.onSurface : null);
    final inactiveBarColor = isLightTheme ? theme.colorScheme.onSurface.withValues(alpha: 0.35) : null;

    final bars = proxy == null
        ? const QualityBars(healthScore: null)
        : QualityBars.fromOutbound(
            proxy,
            isActive: !failedPing,
            activeColor: activeBarColor,
            inactiveColor: inactiveBarColor,
          );

    return Center(
      widthFactor: compact ? 1 : null,
      child: InkWell(
        onTap: () async {
          try {
            await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
          } catch (e) {
            loggy.error("Error during URL test: $e");
          }
        },
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 0 : 8, horizontal: compact ? 0 : 16),
          child: compact
              ? _CompactPing(
                  proxy: proxy,
                  status: pingStatus,
                  text: pingText,
                  bars: bars,
                  textColor: failedPing ? theme.colorScheme.error : null,
                  reduceMotion: MediaQuery.disableAnimationsOf(context),
                )
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    const Icon(FluentIcons.wifi_1_24_regular),
                    Text(
                      pingText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: failedPing ? theme.colorScheme.error : null,
                      ),
                    ),
                    bars,
                  ],
                ),
        ),
      ),
    );
  }
}

class _CompactPing extends StatelessWidget {
  const _CompactPing({
    required this.proxy,
    required this.status,
    required this.text,
    required this.bars,
    required this.textColor,
    required this.reduceMotion,
  });

  final OutboundInfo? proxy;
  final ProxyPingStatus status;
  final String text;
  final Widget bars;
  final Color? textColor;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    final qualityKey = '${proxy?.tag}:${status.name}:${proxy?.healthScore}:${proxy?.success}';
    final quality = status == ProxyPingStatus.checking
        ? reduceMotion
              ? const Icon(Icons.sync_rounded, size: 18)
              : const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : bars;

    return AnimatedSize(
      key: const ValueKey('home_connected_ping_slot'),
      duration: duration,
      curve: Curves.easeInOut,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 16,
              child: AnimatedSwitcher(
                duration: duration,
                child: Center(key: ValueKey(qualityKey), child: quality),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: duration,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, if (current != null) current]),
              child: Text(
                text,
                key: ValueKey('${proxy?.tag}:$text'),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
