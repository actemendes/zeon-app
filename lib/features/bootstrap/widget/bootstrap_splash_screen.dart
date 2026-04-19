import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';

class BootstrapSplashScreen extends StatefulWidget {
  const BootstrapSplashScreen({super.key, required this.themeMode});

  final AppThemeMode themeMode;

  @override
  State<BootstrapSplashScreen> createState() => _BootstrapSplashScreenState();
}

class _BootstrapSplashScreenState extends State<BootstrapSplashScreen> with TickerProviderStateMixin {
  static const _lightBackground = Color(0xFFE4EFF4);
  static const _darkBackground = Color(0xFF000000);
  static const _logoRevealDelay = Duration(milliseconds: 420);
  static const _logoRevealDuration = Duration(milliseconds: 260);

  late final AnimationController _logoRevealController = AnimationController(
    vsync: this,
    duration: _logoRevealDuration,
  );
  late final Animation<double> _logoOpacity = CurvedAnimation(
    parent: _logoRevealController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _logoScale = Tween<double>(
    begin: 0.94,
    end: 1,
  ).animate(
    CurvedAnimation(
      parent: _logoRevealController,
      curve: Curves.easeOutCubic,
    ),
  );

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  bool _logoRevealScheduled = false;

  void _scheduleLogoReveal() {
    if (_logoRevealScheduled) return;
    _logoRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(_logoRevealDelay, () {
        if (!mounted) return;
        _logoRevealController.forward();
        _controller.repeat();
      });
    });
  }

  @override
  void dispose() {
    _logoRevealController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final isDark = switch (widget.themeMode) {
      AppThemeMode.dark => true,
      AppThemeMode.light => false,
      AppThemeMode.system => platformBrightness == Brightness.dark,
    };
    final backgroundColor = isDark ? _darkBackground : _lightBackground;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: backgroundColor,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: backgroundColor,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: ColoredBox(
        color: backgroundColor,
        child: SafeArea(
          child: Builder(
            builder: (context) {
              _scheduleLogoReveal();
              return LayoutBuilder(
                builder: (context, constraints) {
                  final logoWidth = (constraints.maxWidth * 0.49).clamp(192.0, 220.0);
                  return Center(
                    child: AnimatedBuilder(
                      animation: _logoRevealController,
                      child: _AnimatedBootstrapLogo(
                        assetPath: isDark ? 'assets/images/SVG/big-logo-dark.svg' : 'assets/images/SVG/big-logo-light.svg',
                        width: logoWidth,
                        animation: _controller,
                      ),
                      builder: (context, child) {
                        if (_logoRevealController.isDismissed) {
                          return const SizedBox.shrink();
                        }
                        return Opacity(
                          opacity: _logoOpacity.value,
                          child: Transform.scale(
                            scale: _logoScale.value,
                            child: child,
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AnimatedBootstrapLogo extends StatelessWidget {
  const _AnimatedBootstrapLogo({required this.assetPath, required this.width, required this.animation});

  static const _viewBoxWidth = 346.67;
  static const _viewBoxHeight = 91.55;
  static const _ringCenterX = 215.36;
  static const _ringCenterY = 45.77;
  static const _ringOuterRadius = 45.77;
  static const _ringInnerRadius = 29.77;

  final String assetPath;
  final double width;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final height = width * (_viewBoxHeight / _viewBoxWidth);
    final scale = width / _viewBoxWidth;
    final ringDiameter = _ringOuterRadius * 2 * scale;
    final ringLeft = (_ringCenterX - _ringOuterRadius) * scale;
    final ringTop = (_ringCenterY - _ringOuterRadius) * scale;
    final ringStrokeWidth = (_ringOuterRadius - _ringInnerRadius) * scale;

    final baseLogo = SvgPicture.asset(assetPath, width: width, height: height, fit: BoxFit.contain);

    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            baseLogo,
            Positioned(
              left: ringLeft,
              top: ringTop,
              width: ringDiameter,
              height: ringDiameter,
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _BootstrapRingPainter(progress: animation.value, strokeWidth: ringStrokeWidth),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BootstrapRingPainter extends CustomPainter {
  const _BootstrapRingPainter({required this.progress, required this.strokeWidth});

  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = (size.shortestSide - strokeWidth) / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = SweepGradient(
        transform: GradientRotation(progress * math.pi * 2),
        colors: const [Color(0xFF27D646), Color(0xFF70F05D), Color(0xFFD8EF79), Color(0xFF4BEA7A), Color(0xFF27D646)],
        stops: const [0.0, 0.2, 0.5, 0.78, 1.0],
      ).createShader(rect);

    canvas.drawCircle(size.center(Offset.zero), radius, paint);
  }

  @override
  bool shouldRepaint(covariant _BootstrapRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.strokeWidth != strokeWidth;
  }
}
