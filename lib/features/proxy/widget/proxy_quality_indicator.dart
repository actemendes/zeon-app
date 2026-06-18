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
      ProxyQualityLevel.weak => Colors.orange.shade700,
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

enum ProxyQualityLevel { excellent, good, medium, weak, bad, unknown }

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
    final stageLabel = _stageLabel(proxy.healthReason, t);
    final hasCombinedHealth =
        proxy.combinedHealthLevel.isNotEmpty ||
        proxy.combinedHealthScore != 0 ||
        proxy.externalHealthLevel.isNotEmpty ||
        proxy.externalHealthScore != 0 ||
        proxy.healthReason.isNotEmpty ||
        proxy.speedCheckedAt != 0 ||
        proxy.speedLevel.isNotEmpty;
    final level = _parseLevel(hasCombinedHealth ? proxy.combinedHealthLevel : proxy.qualityLevel);
    final label = _levelLabel(level, t);
    final safeError = _safeErrorLabel(proxy.lastError, t);
    final safeHealthReason = _safeHealthReasonLabel(proxy.healthReason, t);
    final showReason =
        (level == ProxyQualityLevel.medium || level == ProxyQualityLevel.weak || level == ProxyQualityLevel.bad) &&
        (safeError.isNotEmpty || safeHealthReason.isNotEmpty);
    final notInAuto = !proxy.autoAllowed && !isUnknownLevel(level);
    final speedLabel = _speedLabel(proxy.speedKbps);
    final detailLabel = stageLabel.isNotEmpty
        ? stageLabel
        : showReason
        ? (safeError.isNotEmpty ? safeError : safeHealthReason)
        : (notInAuto ? t.pages.proxies.quality.notUsedInAuto : (speedLabel.isNotEmpty ? speedLabel : ""));
    final scoreValue = hasCombinedHealth && proxy.combinedHealthScore > 0
        ? proxy.combinedHealthScore
        : proxy.qualityScore;
    final score = scoreValue > 0 ? " / $scoreValue" : "";
    final speedTooltip = speedLabel.isNotEmpty ? " / $speedLabel" : "";
    final tooltip = detailLabel.isEmpty ? "$label$score$speedTooltip" : "$label$score / $detailLabel";

    return ProxyQualityPresentation(
      level: level,
      label: label,
      activeBars: _activeBars(level),
      isUnknown: stageLabel.isNotEmpty || isUnknownLevel(level),
      detailLabel: detailLabel,
      tooltip: tooltip,
    );
  }

  static ProxyQualityLevel _parseLevel(String rawLevel) {
    return switch (rawLevel.trim().toLowerCase()) {
      "excellent" => ProxyQualityLevel.excellent,
      "good" => ProxyQualityLevel.good,
      "medium" => ProxyQualityLevel.medium,
      "slow" => ProxyQualityLevel.medium,
      "weak" => ProxyQualityLevel.weak,
      "very_slow" => ProxyQualityLevel.weak,
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
      ProxyQualityLevel.weak => 1,
      ProxyQualityLevel.bad => 0,
      ProxyQualityLevel.unknown => 0,
    };
  }

  static String _levelLabel(ProxyQualityLevel level, Translations t) {
    return switch (level) {
      ProxyQualityLevel.excellent => t.pages.proxies.quality.excellent,
      ProxyQualityLevel.good => t.pages.proxies.quality.good,
      ProxyQualityLevel.medium => t.pages.proxies.quality.slow,
      ProxyQualityLevel.weak => t.pages.proxies.quality.verySlow,
      ProxyQualityLevel.bad => t.pages.proxies.quality.bad,
      ProxyQualityLevel.unknown => t.pages.proxies.quality.checking,
    };
  }

  static String _speedLabel(int speedKbps) {
    if (speedKbps <= 0) return "";
    final mbps = speedKbps / 1000;
    if (mbps >= 10) {
      return "${mbps.toStringAsFixed(0)} Mbps";
    }
    return "${mbps.toStringAsFixed(1)} Mbps";
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

  static String _safeHealthReasonLabel(String rawReason, Translations t) {
    final normalized = rawReason.trim().toLowerCase();
    if (normalized.isEmpty) return "";
    return switch (normalized) {
      "external-slow" => t.pages.proxies.quality.reasons.externalSlow,
      "external-timeout" => t.pages.proxies.quality.reasons.externalTimeout,
      "public-external-slow" => t.pages.proxies.quality.reasons.externalSlow,
      "public-external-timeout" => t.pages.proxies.quality.reasons.externalTimeout,
      "cloudflare-only" => t.pages.proxies.quality.reasons.cdnOnly,
      "discord-timeout" => t.pages.proxies.quality.reasons.discordTimeout,
      "google-timeout" => t.pages.proxies.quality.reasons.googleTimeout,
      "external-unknown" => t.pages.proxies.quality.reasons.externalUnknown,
      "live-usability-failed" => "not loading",
      "live-timeout" => "live timeout",
      "traffic-failed" => "traffic failed",
      "live-degraded" => "live degraded",
      "urltest-failed" => "",
      "quality-not-usable" => "",
      _ => "",
    };
  }

  static String _stageLabel(String rawReason, Translations t) {
    final normalized = rawReason.trim().toLowerCase();
    return switch (normalized) {
      "ping-checking" => t.pages.proxies.delay.testing,
      "quality-checking" => t.pages.proxies.quality.checking,
      "speed-checking" => "скорость...",
      _ => "",
    };
  }
}
