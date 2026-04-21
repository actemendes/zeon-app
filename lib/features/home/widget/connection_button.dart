import 'dart:math' as math;

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final resolvedConnectionStatus = connectionStatus.valueOrNull;
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;
    final hasValidDelay = delay > 0 && delay < 65000;

    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull;
    final today = DateTime.now();

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (!hasValidDelay || resolvedConnectionStatus != const Connected()) {
      secureLabel = "";
    }

    final isInitialConnectionLoad = connectionStatus.isLoading && resolvedConnectionStatus == null;

    final visualState = switch (resolvedConnectionStatus) {
      Connecting() || Disconnecting() => _ConnectionButtonVisualState.loading,
      Connected() => _ConnectionButtonVisualState.connected,
      _ when isInitialConnectionLoad => _ConnectionButtonVisualState.loading,
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
      label: switch (resolvedConnectionStatus) {
        Connected() when requiresReconnect == true => t.connection.reconnect,
        final status? => status.present(t),
        _ when connectionStatus.hasError => t.errors.connection.connectionError,
        _ => "",
      },
      image: switch (resolvedConnectionStatus) {
        Connected() => Assets.images.connectNorouz,
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
  late final AnimationController _rotationController;
  late final AnimationController _loadingController;
  late final AnimationController _connectedController;

  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1320))..repeat();
    _loadingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _connectedController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 260),
    );

    _applyVisualState(widget.visualState, animate: false);
  }

  @override
  void didUpdateWidget(covariant _ConnectionButtonFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visualState != widget.visualState) {
      _applyVisualState(widget.visualState, animate: true);
    }
    if (!widget.enabled && _pressed) {
      setState(() {
        _pressed = false;
      });
    }
  }

  void _applyVisualState(_ConnectionButtonVisualState state, {required bool animate}) {
    final loadingTarget = state == _ConnectionButtonVisualState.loading ? 1.0 : 0.0;
    final connectedTarget = state == _ConnectionButtonVisualState.connected ? 1.0 : 0.0;

    if (animate) {
      if (loadingTarget > _loadingController.value) {
        _loadingController.forward();
      } else {
        _loadingController.reverse();
      }
      if (connectedTarget > _connectedController.value) {
        _connectedController.forward();
      } else {
        _connectedController.reverse();
      }
      return;
    }
    _loadingController.value = loadingTarget;
    _connectedController.value = connectedTarget;
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _loadingController.dispose();
    _connectedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = Listenable.merge([_rotationController, _loadingController, _connectedController]);
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
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
                      offColor: theme.colorScheme.secondaryContainer,
                      loadingProgress: _loadingController.value,
                      connectedProgress: _connectedController.value,
                      rotationTurns: _rotationController.value,
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
                        color: theme.colorScheme.surface,
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
    required this.offColor,
    required this.loadingProgress,
    required this.connectedProgress,
    required this.rotationTurns,
  });

  final Color offColor;
  final double loadingProgress;
  final double connectedProgress;
  final double rotationTurns;

  static const double _viewBoxSize = 230.65;
  static const double _outerRadius = 115.32;
  static const double _innerRadius = 68.13;
  static const double _ringWidth = _outerRadius - _innerRadius;
  static const double _ringRadius = (_outerRadius + _innerRadius) / 2;
  static const double _spinnerSweep = math.pi * 1.2;
  static const double _spinnerStartAngle = -math.pi / 2;

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
    final connectedOpacity = Curves.easeOutCubic.transform(connectedProgress.clamp(0, 1));
    final loadingOpacity = Curves.easeOutCubic.transform(loadingProgress.clamp(0, 1));
    final arcRect = Rect.fromCircle(center: center, radius: _ringRadius);
    final rotation = rotationTurns * (2 * math.pi);

    final basePaint = Paint()
      ..isAntiAlias = true
      ..color = offColor;
    canvas.drawCircle(center, _outerRadius, basePaint);

    if (connectedOpacity > 0.001) {
      final connectedPaint = Paint()
        ..isAntiAlias = true
        ..shader = _connectionGradient.createShader(gradientRect)
        ..colorFilter = ColorFilter.mode(Colors.white.withValues(alpha: connectedOpacity), BlendMode.modulate);
      canvas.drawCircle(center, _outerRadius, connectedPaint);
    }

    final spinnerOpacity = (loadingOpacity * (1 - connectedOpacity)).clamp(0.0, 1.0);
    if (spinnerOpacity > 0.001) {
      final loadingPaint = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringWidth
        ..strokeCap = StrokeCap.round
        ..shader = _connectionGradient.createShader(gradientRect)
        ..colorFilter = ColorFilter.mode(Colors.white.withValues(alpha: spinnerOpacity), BlendMode.modulate);
      canvas.drawArc(arcRect, _spinnerStartAngle + rotation, _spinnerSweep, false, loadingPaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConnectionRingPainter oldDelegate) {
    return offColor != oldDelegate.offColor ||
        loadingProgress != oldDelegate.loadingProgress ||
        connectedProgress != oldDelegate.connectedProgress ||
        rotationTurns != oldDelegate.rotationTurns;
  }
}
