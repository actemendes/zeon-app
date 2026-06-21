import 'package:flutter/material.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// A compact, presentation-only health indicator for an outbound.
///
/// The number of filled bars is derived exclusively from [healthScore]. The
/// selected state changes only their colour, never the score or bar count.
class QualityBars extends StatelessWidget {
  const QualityBars({
    super.key,
    required this.healthScore,
    this.success,
    this.errorType,
    this.isActive = false,
    this.activeColor,
    this.inactiveColor,
  });

  factory QualityBars.fromOutbound(
    OutboundInfo outbound, {
    bool isActive = false,
    Color? activeColor,
    Color? inactiveColor,
  }) => QualityBars(
    healthScore: outbound.hasHealthScore() ? outbound.healthScore : null,
    success: outbound.hasSuccess() ? outbound.success : null,
    errorType: outbound.hasErrorType() ? outbound.errorType : null,
    isActive: isActive,
    activeColor: activeColor,
    inactiveColor: inactiveColor,
  );

  final int? healthScore;
  final bool? success;
  final String? errorType;
  final bool isActive;

  /// Optional overrides for contexts such as an error state on the home card.
  final Color? activeColor;
  final Color? inactiveColor;

  static const _barCount = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = _filledBars(healthScore, success: success, errorType: errorType);
    // Tertiary is the project's softer green; primary is intentionally much
    // brighter and is less comfortable for the tiny bars in dark mode.
    final filledColor = activeColor ?? (isActive ? scheme.tertiary : scheme.onSurfaceVariant);
    final emptyColor = inactiveColor ?? scheme.outlineVariant;

    return Semantics(
      label: 'Connection quality',
      child: ExcludeSemantics(
        child: SizedBox(
          width: 28,
          height: 12,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(_barCount, (index) {
                final isFilled = index < filled;
                return Padding(
                  padding: EdgeInsets.only(left: index == 0 ? 0 : 2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isFilled ? filledColor : emptyColor,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                    child: SizedBox(width: 4, height: 4 + index * 2.0),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  static int _filledBars(int? score, {bool? success, String? errorType}) {
    if (success == false || (errorType != null && errorType.isNotEmpty && errorType != 'none')) return 0;
    final value = score ?? 0;
    if (value <= 0) return 0;
    if (value >= 90) return 4;
    if (value >= 60) return 3;
    if (value >= 30) return 2;
    return 1;
  }
}

enum ProxyPingStatus { notTested, checking, success, failed }

ProxyPingStatus outboundPingStatus(OutboundInfo outbound) {
  switch (outbound.urlTestStatus) {
    case 'not_tested':
      return ProxyPingStatus.notTested;
    case 'checking':
      return ProxyPingStatus.checking;
    case 'success':
      return outbound.urlTestDelay > 0 && outbound.urlTestDelay < 65000
          ? ProxyPingStatus.success
          : ProxyPingStatus.failed;
    case 'failed':
      return ProxyPingStatus.failed;
  }

  // Compatibility with an older core which did not send url_test_status.
  if (outbound.hasUrlTestDelay() && outbound.urlTestDelay > 0 && outbound.urlTestDelay < 65000) {
    return ProxyPingStatus.success;
  }
  if (outbound.hasUrlTestTime() ||
      (outbound.hasErrorType() && outbound.errorType.isNotEmpty && outbound.errorType != 'none') ||
      (outbound.hasUrlTestDelay() && outbound.urlTestDelay >= 65000)) {
    return ProxyPingStatus.failed;
  }
  return ProxyPingStatus.notTested;
}

String formatOutboundPing(OutboundInfo outbound) => switch (outboundPingStatus(outbound)) {
  ProxyPingStatus.notTested => '-',
  ProxyPingStatus.checking => '...',
  ProxyPingStatus.success => '${outbound.urlTestDelay} ms',
  ProxyPingStatus.failed => '✕',
};

bool proxyPingFailed(OutboundInfo outbound) => outboundPingStatus(outbound) == ProxyPingStatus.failed;

int compareOutboundsByPingQuality(OutboundInfo a, OutboundInfo b) {
  final groupCompare = _compareGroupsFirst(a, b);
  if (groupCompare != 0) return groupCompare;

  final aStatus = outboundPingStatus(a);
  final bStatus = outboundPingStatus(b);
  final statusCompare = _pingStatusRank(aStatus).compareTo(_pingStatusRank(bStatus));
  if (statusCompare != 0) return statusCompare;

  if (aStatus == ProxyPingStatus.success && bStatus == ProxyPingStatus.success) {
    final scoreCompare = b.healthScore.compareTo(a.healthScore);
    if (scoreCompare != 0) return scoreCompare;

    final delayCompare = a.urlTestDelay.compareTo(b.urlTestDelay);
    if (delayCompare != 0) return delayCompare;
  }

  return a.tag.compareTo(b.tag);
}

int _compareGroupsFirst(OutboundInfo a, OutboundInfo b) {
  if (a.isGroup && !b.isGroup) return -1;
  if (!a.isGroup && b.isGroup) return 1;
  return 0;
}

int _pingStatusRank(ProxyPingStatus status) => switch (status) {
  ProxyPingStatus.success => 0,
  ProxyPingStatus.checking => 1,
  ProxyPingStatus.notTested => 2,
  ProxyPingStatus.failed => 3,
};
