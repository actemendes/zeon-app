import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxyQualityIndicator extends ConsumerWidget {
  const ProxyQualityIndicator(this.proxy, {super.key, this.showDetails = true, this.foregroundColor});

  final OutboundInfo proxy;
  final bool showDetails;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final data = ProxyQualityPresentation.from(proxy, t);
    final foreground = foregroundColor ?? theme.colorScheme.onSurface;
    final muted = foreground.withValues(alpha: .55);

    final indicator = data.isUnknown
        ? SizedBox(
            width: 28,
            height: 12,
            child: Center(
              child: Text(
                "-",
                style: theme.textTheme.labelSmall?.copyWith(color: muted, height: 1, fontWeight: FontWeight.w700),
              ),
            ),
          )
        : _QualityBars(
            activeBars: data.activeBars,
            activeColor: _qualityColor(theme, data.level),
            inactiveColor: muted.withValues(alpha: .28),
          );

    final detail = showDetails ? data.detailLabel : "";

    return Tooltip(
      message: data.tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: Semantics(
        label: data.tooltip,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              indicator,
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 72),
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted, fontSize: 10, height: 1),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _qualityColor(ThemeData theme, ProxyQualityLevel level) {
    final scheme = theme.colorScheme;
    return switch (level) {
      ProxyQualityLevel.excellent => theme.brightness == Brightness.dark ? Colors.lightGreenAccent : Colors.green,
      ProxyQualityLevel.good => theme.brightness == Brightness.dark ? Colors.lightGreen : Colors.green.shade700,
      ProxyQualityLevel.medium => Colors.amber.shade700,
      ProxyQualityLevel.bad => scheme.error,
      ProxyQualityLevel.unknown => scheme.outline,
    };
  }
}

class _QualityBars extends StatelessWidget {
  const _QualityBars({required this.activeBars, required this.activeColor, required this.inactiveColor});

  final int activeBars;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 12,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (index) {
            final height = 4.0 + index * 2.0;
            final active = index < activeBars;
            return Padding(
              padding: EdgeInsets.only(left: index == 0 ? 0 : 2),
              child: Container(
                width: 4,
                height: height,
                decoration: BoxDecoration(
                  color: active ? activeColor : inactiveColor,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

enum ProxyQualityLevel { excellent, good, medium, bad, unknown }

class ProxyQualityPresentation {
  const ProxyQualityPresentation({
    required this.level,
    required this.label,
    required this.activeBars,
    required this.isUnknown,
    required this.detailLabel,
    required this.tooltip,
  });

  final ProxyQualityLevel level;
  final String label;
  final int activeBars;
  final bool isUnknown;
  final String detailLabel;
  final String tooltip;

  factory ProxyQualityPresentation.from(OutboundInfo proxy, Translations t) {
    final level = _parseLevel(proxy.qualityLevel);
    final label = _levelLabel(level, t);
    final safeError = _safeErrorLabel(proxy.lastError, t);
    final showReason = (level == ProxyQualityLevel.medium || level == ProxyQualityLevel.bad) && safeError.isNotEmpty;
    final notInAuto = !proxy.autoAllowed && !isUnknownLevel(level);
    final detailLabel = showReason ? safeError : (notInAuto ? t.pages.proxies.quality.notUsedInAuto : "");
    final score = proxy.qualityScore > 0 ? " / ${proxy.qualityScore}" : "";
    final tooltip = detailLabel.isEmpty ? "$label$score" : "$label$score / $detailLabel";

    return ProxyQualityPresentation(
      level: level,
      label: label,
      activeBars: _activeBars(level),
      isUnknown: isUnknownLevel(level),
      detailLabel: detailLabel,
      tooltip: tooltip,
    );
  }

  static ProxyQualityLevel _parseLevel(String rawLevel) {
    return switch (rawLevel.trim().toLowerCase()) {
      "excellent" => ProxyQualityLevel.excellent,
      "good" => ProxyQualityLevel.good,
      "medium" => ProxyQualityLevel.medium,
      "bad" => ProxyQualityLevel.bad,
      _ => ProxyQualityLevel.unknown,
    };
  }

  static bool isUnknownLevel(ProxyQualityLevel level) => level == ProxyQualityLevel.unknown;

  static int _activeBars(ProxyQualityLevel level) {
    return switch (level) {
      ProxyQualityLevel.excellent => 4,
      ProxyQualityLevel.good => 3,
      ProxyQualityLevel.medium => 2,
      ProxyQualityLevel.bad => 0,
      ProxyQualityLevel.unknown => 0,
    };
  }

  static String _levelLabel(ProxyQualityLevel level, Translations t) {
    return switch (level) {
      ProxyQualityLevel.excellent => t.pages.proxies.quality.excellent,
      ProxyQualityLevel.good => t.pages.proxies.quality.good,
      ProxyQualityLevel.medium => t.pages.proxies.quality.medium,
      ProxyQualityLevel.bad => t.pages.proxies.quality.bad,
      ProxyQualityLevel.unknown => t.pages.proxies.quality.unknown,
    };
  }

  static String _safeErrorLabel(String rawError, Translations t) {
    final normalized = rawError.trim().toLowerCase();
    if (normalized.isEmpty) return "";
    if (normalized.contains("i/o timeout")) return t.pages.proxies.quality.errors.timeout;
    if (normalized.contains("connection refused")) return t.pages.proxies.quality.errors.refused;
    if (normalized.contains("connection reset")) return t.pages.proxies.quality.errors.reset;
    if (normalized == "eof" || normalized.contains(": eof") || normalized.contains(" eof")) {
      return t.pages.proxies.quality.errors.eof;
    }
    if (normalized.contains("nxdomain")) return t.pages.proxies.quality.errors.nxdomain;
    if (normalized.contains("broken pipe")) return t.pages.proxies.quality.errors.brokenPipe;
    if (normalized.contains("context deadline exceeded")) return t.pages.proxies.quality.errors.deadline;
    if (normalized.contains("authentication handshake failed")) {
      return t.pages.proxies.quality.errors.handshakeFailed;
    }
    return "";
  }
}
