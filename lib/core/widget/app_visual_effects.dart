import 'package:flutter/material.dart';

/// Applies the user's visual preference without muting functional tickers
/// (progress, text input, scrolling) or overriding system accessibility.
class AppVisualEffects extends StatelessWidget {
  const AppVisualEffects({super.key, required this.lowPowerMode, required this.child});

  final bool lowPowerMode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(disableAnimations: media.disableAnimations || lowPowerMode),
      child: child,
    );
  }
}
