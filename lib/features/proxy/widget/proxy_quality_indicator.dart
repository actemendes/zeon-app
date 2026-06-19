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

String formatOutboundPing(OutboundInfo outbound) {
  if (proxyPingFailed(
    delay: outbound.hasUrlTestDelay() ? outbound.urlTestDelay : null,
    success: outbound.hasSuccess() ? outbound.success : null,
  )) {
    return '×';
  }
  if (!outbound.hasUrlTestDelay() || outbound.urlTestDelay <= 0) return '–';
  return '${outbound.urlTestDelay} ms';
}

bool proxyPingFailed({required int? delay, required bool? success}) =>
    success == false || (delay != null && delay >= 65000);
