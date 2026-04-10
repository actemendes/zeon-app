import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key});

  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");

  bool get _useMockConnectionUi => kIsWeb && kDebugMode && _debugSeedProfileEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;

    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull;
    final today = DateTime.now();

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (delay <= 0 || delay > 65000 || connectionStatus.value != const Connected()) {
      secureLabel = "";
    }

    final connectedWithoutDelay = _useMockConnectionUi && connectionStatus.value == const Connected();

    final visualState = switch (connectionStatus) {
      AsyncData(value: Connecting()) || AsyncData(value: Disconnecting()) => _ConnectionButtonVisualState.loading,
      AsyncData(value: Connected()) when !connectedWithoutDelay && (delay <= 0 || delay >= 65000) =>
        _ConnectionButtonVisualState.loading,
      AsyncData(value: Connected()) => _ConnectionButtonVisualState.connected,
      AsyncLoading() => _ConnectionButtonVisualState.loading,
      _ => _ConnectionButtonVisualState.off,
    };

    return _ConnectionButton(
      onTap: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => () async {
          final activeProfile = await ref.read(activeProfileProvider.future);
          return await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
        },
        AsyncData(value: Disconnected()) || AsyncError() => () async {
          if (ref.read(activeProfileProvider).valueOrNull == null) {
            await ref.read(dialogNotifierProvider.notifier).showNoActiveProfile();
            await ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview();
          }
          if (await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
          }
        },
        AsyncData(value: Connected()) => () async {
          if (requiresReconnect == true &&
              await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref
                .read(connectionNotifierProvider.notifier)
                .reconnect(await ref.read(activeProfileProvider.future));
          }
          return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
        },
        _ => () {},
      },
      enabled: switch (connectionStatus) {
        AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
        _ => false,
      },
      label: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
        AsyncData(value: Connected()) when !connectedWithoutDelay && (delay <= 0 || delay >= 65000) =>
          t.connection.connecting,
        AsyncData(value: final status) => status.present(t),
        AsyncError() => t.errors.connection.connectionError,
        _ => "",
      },
      image: switch (connectionStatus) {
        AsyncData(value: Connected()) => Assets.images.connectNorouz,
        _ => Assets.images.disconnectNorouz,
      },
      visualState: visualState,
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
      secureLabel: secureLabel,
    );
  }
}

class _ConnectionButton extends StatelessWidget {
  const _ConnectionButton({
    required this.onTap,
    required this.enabled,
    required this.label,
    required this.image,
    required this.useImage,
    required this.secureLabel,
    required this.visualState,
  });

  final VoidCallback onTap;
  final bool enabled;
  final String label;
  final AssetGenImage image;
  final bool useImage;
  final String secureLabel;
  final _ConnectionButtonVisualState visualState;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: label,
          child: Container(
            decoration: const BoxDecoration(shape: BoxShape.circle),
            width: _ConnectionButtonFace.outerSize,
            height: _ConnectionButtonFace.outerSize,
            child: _ConnectionButtonFace(
              onTap: onTap,
              enabled: enabled,
              image: image,
              useImage: useImage,
              visualState: visualState,
            ).animate(target: enabled ? 0 : 1).blurXY(end: 1),
          ).animate(target: enabled ? 0 : 1).scaleXY(end: .88, curve: Curves.easeIn),
        ),
        const Gap(16),
        ExcludeSemantics(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedText(label, style: Theme.of(context).textTheme.titleMedium),
              if (secureLabel.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(FontAwesomeIcons.shieldHalved, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const Gap(4),
                    Text(
                      secureLabel,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.secondary),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum _ConnectionButtonVisualState { off, loading, connected }

class _ConnectionButtonFace extends StatefulWidget {
  const _ConnectionButtonFace({
    required this.onTap,
    required this.enabled,
    required this.image,
    required this.useImage,
    required this.visualState,
  });

  static const double outerSize = 230;
  static const double innerCircleDiameter = 135;
  static const double glyphDiameter = 47;

  final VoidCallback onTap;
  final bool enabled;
  final AssetGenImage image;
  final bool useImage;
  final _ConnectionButtonVisualState visualState;

  @override
  State<_ConnectionButtonFace> createState() => _ConnectionButtonFaceState();
}

class _ConnectionButtonFaceState extends State<_ConnectionButtonFace> with TickerProviderStateMixin {
  late final AnimationController _spinController;
  late final AnimationController _settleController;
  late final AnimationController _loadingVisibilityController;

  bool _pressed = false;
  double _settleStartTurns = 0;
  double _frozenTurns = 0;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _settleController = AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
    _loadingVisibilityController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _loadingVisibilityController.value = widget.visualState == _ConnectionButtonVisualState.loading ? 1 : 0;
    _syncAnimationState(previous: null);
  }

  @override
  void didUpdateWidget(covariant _ConnectionButtonFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visualState != widget.visualState) {
      _syncAnimationState(previous: oldWidget.visualState);
    }
    if (!widget.enabled && _pressed) {
      setState(() {
        _pressed = false;
      });
    }
  }

  void _syncAnimationState({required _ConnectionButtonVisualState? previous}) {
    switch (widget.visualState) {
      case _ConnectionButtonVisualState.loading:
        _settleController.stop();
        _settleController.value = 0;
        if (previous != _ConnectionButtonVisualState.loading) {
          _loadingVisibilityController.forward(from: 0);
        } else {
          _loadingVisibilityController.value = 1;
        }
        if (!_spinController.isAnimating) {
          _spinController.repeat();
        }
        return;
      case _ConnectionButtonVisualState.connected:
        final comesFromLoading = previous == _ConnectionButtonVisualState.loading;
        if (comesFromLoading) {
          _settleStartTurns = _spinController.value;
          _frozenTurns = _settleStartTurns;
          _loadingVisibilityController.value = 1;
          _spinController.stop();
          _settleController.forward(from: 0);
        } else {
          _spinController.stop();
          _settleController.value = 1;
          _loadingVisibilityController.value = 0;
        }
        return;
      case _ConnectionButtonVisualState.off:
        final comesFromLoading = previous == _ConnectionButtonVisualState.loading;
        if (comesFromLoading) {
          _frozenTurns = _spinController.value;
          _loadingVisibilityController.reverse(from: _loadingVisibilityController.value);
        } else {
          _loadingVisibilityController.value = 0;
        }
        _spinController.stop();
        _settleController.stop();
        _settleController.value = 0;
        return;
    }
  }

  double _rotationTurns() {
    if (widget.visualState == _ConnectionButtonVisualState.loading) {
      return _spinController.value;
    }
    if (widget.visualState == _ConnectionButtonVisualState.connected && _settleController.value < 1) {
      final eased = Curves.easeOutCubic.transform(_settleController.value);
      return _settleStartTurns + (1 - eased) * 0.35;
    }
    if (widget.visualState == _ConnectionButtonVisualState.off && _loadingVisibilityController.value > 0) {
      return _frozenTurns;
    }
    return 0;
  }

  double _settleProgress() {
    if (widget.visualState == _ConnectionButtonVisualState.connected) {
      return _settleController.value;
    }
    return 0;
  }

  double _loadingProgress() {
    if (widget.visualState == _ConnectionButtonVisualState.loading) {
      return _loadingVisibilityController.value;
    }
    if (widget.visualState == _ConnectionButtonVisualState.off) {
      return _loadingVisibilityController.value;
    }
    return 0;
  }

  @override
  void dispose() {
    _spinController.dispose();
    _settleController.dispose();
    _loadingVisibilityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = Listenable.merge([_spinController, _settleController, _loadingVisibilityController]);
    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final logoAssetPath = isDarkTheme ? 'assets/images/SVG/logo-black.svg' : 'assets/images/SVG/logo-white.svg';

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        key: const ValueKey("home_connection_button"),
        customBorder: const CircleBorder(),
        splashColor: Colors.white.withValues(alpha: .12),
        highlightColor: Colors.transparent,
        onTap: widget.onTap,
        onTapDown: widget.enabled
            ? (_) => setState(() {
                _pressed = true;
              })
            : null,
        onTapUp: widget.enabled
            ? (_) => setState(() {
                _pressed = false;
              })
            : null,
        onTapCancel: widget.enabled
            ? () => setState(() {
                _pressed = false;
              })
            : null,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            const innerDiameter = _ConnectionButtonFace.innerCircleDiameter;
            return SizedBox(
              width: _ConnectionButtonFace.outerSize,
              height: _ConnectionButtonFace.outerSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size.square(_ConnectionButtonFace.outerSize),
                    painter: _ConnectionRingPainter(
                      state: widget.visualState,
                      isDarkTheme: isDarkTheme,
                      loadingProgress: _loadingProgress(),
                      rotationTurns: _rotationTurns(),
                      settleProgress: _settleProgress(),
                    ),
                  ),
                  AnimatedScale(
                    scale: _pressed && widget.enabled ? 0.94 : 1,
                    duration: const Duration(milliseconds: 110),
                    curve: Curves.easeOutCubic,
                    child: Container(
                      width: innerDiameter,
                      height: innerDiameter,
                      decoration: BoxDecoration(
                        color: isDarkTheme ? const Color(0xFF000000) : const Color(0xFFE8F3F7),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                            color: isDarkTheme
                                ? Colors.black.withValues(alpha: .5)
                                : Colors.white.withValues(alpha: .5),
                          ),
                        ],
                      ),
                      child: Center(
                        child: widget.useImage
                            ? Padding(
                                padding: const EdgeInsets.all(
                                  (_ConnectionButtonFace.innerCircleDiameter - _ConnectionButtonFace.glyphDiameter) / 2,
                                ),
                                child: widget.image.image(fit: BoxFit.contain),
                              )
                            : SizedBox.square(
                                dimension: _ConnectionButtonFace.glyphDiameter,
                                child: SvgPicture.asset(logoAssetPath),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionRingPainter extends CustomPainter {
  const _ConnectionRingPainter({
    required this.state,
    required this.isDarkTheme,
    required this.loadingProgress,
    required this.rotationTurns,
    required this.settleProgress,
  });

  final _ConnectionButtonVisualState state;
  final bool isDarkTheme;
  final double loadingProgress;
  final double rotationTurns;
  final double settleProgress;

  static const double _viewBoxSize = 230.65;
  static const double _outerRadius = 115.32;
  static const double _innerRadius = 68.13;
  static const double _ringWidth = _outerRadius - _innerRadius;
  static const double _ringRadius = (_outerRadius + _innerRadius) / 2;
  static const double _arcGap = math.pi / 2;
  static const double _openSweep = (2 * math.pi) - _arcGap;
  static const double _startAngle = math.pi * .46;
  static const double _capMorphStartProgress = .58;

  static const Color _lightOffColor = Color(0xFFD6E1E5);
  static const Color _darkOffColor = Color(0xFF1A1B1F);
  static const LinearGradient _connectionGradient = LinearGradient(colors: [Color(0xFF3CE74F), Color(0xFFBFDD71)]);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / _viewBoxSize;
    final dx = (size.width - (_viewBoxSize * scale)) / 2;
    final dy = (size.height - (_viewBoxSize * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    const center = Offset(115.32, 115.32);
    const gradientRect = Rect.fromLTWH(0, 0, _viewBoxSize, _viewBoxSize);
    final offColor = isDarkTheme ? _darkOffColor : _lightOffColor;

    final basePaint = Paint()..isAntiAlias = true;
    if (state == _ConnectionButtonVisualState.connected) {
      basePaint.shader = _connectionGradient.createShader(gradientRect);
    } else {
      basePaint.color = offColor;
    }
    canvas.drawCircle(center, _outerRadius, basePaint);

    final arcRect = Rect.fromCircle(center: center, radius: _ringRadius);
    final rotation = rotationTurns * (2 * math.pi);
    final loadingVisibility = Curves.easeOutCubic.transform(loadingProgress.clamp(0, 1));

    if ((state == _ConnectionButtonVisualState.loading || state == _ConnectionButtonVisualState.off) &&
        loadingVisibility > 0.001) {
      final loadingPaint = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringWidth
        ..strokeCap = StrokeCap.round
        ..shader = _connectionGradient.createShader(gradientRect);
      canvas.drawArc(arcRect, _startAngle + rotation, _openSweep * loadingVisibility, false, loadingPaint);
    } else if (state == _ConnectionButtonVisualState.connected && settleProgress < 1) {
      final easedProgress = Curves.easeOutCubic.transform(settleProgress);
      final remainingGap = _arcGap * (1 - easedProgress);
      if (remainingGap > 0.0001) {
        final capMorph = Curves.easeInOutCubic.transform(
          ((easedProgress - _capMorphStartProgress) / (1 - _capMorphStartProgress)).clamp(0.0, 1.0),
        );
        final capRadius = (_ringWidth / 2) * (1 - capMorph);
        final gapStartAngle = _startAngle + rotation + _openSweep;
        final gapEndAngle = gapStartAngle + remainingGap;
        final gapPaint = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.fill
          ..color = offColor;

        final gapPath = Path()
          ..arcTo(Rect.fromCircle(center: center, radius: _outerRadius), gapStartAngle, remainingGap, false)
          ..arcTo(Rect.fromCircle(center: center, radius: _innerRadius), gapEndAngle, -remainingGap, false)
          ..close();

        canvas.drawPath(gapPath, gapPaint);

        if (capRadius > 0.0001) {
          final startCapCenter = center + Offset(math.cos(gapStartAngle), math.sin(gapStartAngle)) * _ringRadius;
          final endCapCenter = center + Offset(math.cos(gapEndAngle), math.sin(gapEndAngle)) * _ringRadius;
          canvas.drawCircle(startCapCenter, capRadius, gapPaint);
          canvas.drawCircle(endCapCenter, capRadius, gapPaint);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConnectionRingPainter oldDelegate) {
    return state != oldDelegate.state ||
        isDarkTheme != oldDelegate.isDarkTheme ||
        loadingProgress != oldDelegate.loadingProgress ||
        rotationTurns != oldDelegate.rotationTurns ||
        settleProgress != oldDelegate.settleProgress;
  }
}
