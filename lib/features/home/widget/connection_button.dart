import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/theme/theme_extensions.dart';
import 'package:zeon/core/widget/animated_text.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_provider.dart';
import 'package:zeon/features/button_appearance/widget/custom_vpn_button.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';

const _connectionTransitionDuration = Duration(milliseconds: 460);

class ConnectionButton extends ConsumerWidget {
  const ConnectionButton({super.key, this.faceKey, this.showStatus = true});

  final GlobalKey? faceKey;
  final bool showStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final buttonState = ref.watch(homeConnectionStateProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;
    final hasValidDelay = delay > 0 && delay < 65000;

    final today = DateTime.now();

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (!hasValidDelay || !buttonState.isConnected) {
      secureLabel = "";
    }

    final presentation = buttonState.present(t);

    return MainVpnButtonView(
      appearance: ref.watch(buttonAppearanceProvider).valueOrNull ?? const ButtonAppearance(),
      faceKey: faceKey,
      showStatus: showStatus,
      onTap: buttonState.enabled
          ? () => ref.read(connectionNotifierProvider.notifier).handleMainVpnButtonTap(buttonState)
          : null,
      presentation: presentation,
      image: buttonState.isConnected ? Assets.images.connectNorouz : Assets.images.disconnectNorouz,
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
      secureLabel: secureLabel,
    );
  }
}

class MainVpnButtonView extends StatelessWidget {
  const MainVpnButtonView({
    super.key,
    this.faceKey,
    this.showStatus = true,
    required this.onTap,
    required this.presentation,
    required this.image,
    required this.useImage,
    required this.secureLabel,
    this.appearance = const ButtonAppearance(),
  });

  final VoidCallback? onTap;
  final GlobalKey? faceKey;
  final bool showStatus;
  final MainVpnButtonPresentation presentation;
  final AssetGenImage image;
  final bool useImage;
  final String secureLabel;
  final ButtonAppearance appearance;

  @override
  Widget build(BuildContext context) {
    final state = presentation.state;
    return Column(
      mainAxisSize: showStatus ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          enabled: state.enabled,
          label: presentation.semanticsLabel,
          onTap: appearance.preset != ButtonPreset.standard && state.enabled ? onTap : null,
          child: Container(
            key: faceKey,
            decoration: const BoxDecoration(shape: BoxShape.circle),
            width: _ConnectionButtonFace.outerSize,
            height: _ConnectionButtonFace.outerSize,
            child: appearance.preset != ButtonPreset.standard
                ? ExcludeSemantics(
                    child: CustomVpnButton(
                      diameter: _ConnectionButtonFace.outerSize,
                      appearance: appearance,
                      phase: switch (state.visualState) {
                        MainVpnButtonVisualState.connected => ButtonPhase.connected,
                        MainVpnButtonVisualState.loading when !state.isStopping => ButtonPhase.connecting,
                        _ => ButtonPhase.idle,
                      },
                      onPressed: state.enabled ? onTap : null,
                    ),
                  )
                : _ConnectionButtonFace(
                    onTap: onTap,
                    enabled: state.enabled,
                    image: image,
                    useImage: useImage,
                    visualState: state.visualState,
                    isStopping: state.isStopping,
                  ),
          ),
        ),
        if (showStatus) ...[
          const Gap(16),
          ExcludeSemantics(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DefaultTextStyle.merge(
                  textAlign: TextAlign.center,
                  child: _ConnectionContentOpacity(
                    key: const ValueKey('home_connection_label_opacity'),
                    visualState: state.visualState,
                    isStopping: state.isStopping,
                    child: AnimatedText(
                      presentation.label,
                      style: Theme.of(context).textTheme.titleMedium,
                      size: false,
                      slide: false,
                    ),
                  ),
                ),
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
      ],
    );
  }
}

class _ConnectionContentOpacity extends StatelessWidget {
  const _ConnectionContentOpacity({
    super.key,
    required this.visualState,
    required this.isStopping,
    required this.child,
  });

  final MainVpnButtonVisualState visualState;
  final bool isStopping;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    final visualTheme = Theme.of(context).extension<HomeVisualTheme>();
    return AnimatedOpacity(
      // Settle an in-flight fade when reduced motion is enabled.
      key: ValueKey(reduceMotion),
      opacity: switch (visualState) {
        MainVpnButtonVisualState.connected => 1,
        MainVpnButtonVisualState.loading when !isStopping => visualTheme?.loadingOpacity ?? (isLightTheme ? .92 : .7),
        _ => visualTheme?.idleOpacity ?? (isLightTheme ? .85 : .45),
      },
      duration: reduceMotion ? Duration.zero : _connectionTransitionDuration,
      curve: Curves.easeInOutCubic,
      child: child,
    );
  }
}

class _ConnectionButtonFace extends StatefulWidget {
  const _ConnectionButtonFace({
    required this.onTap,
    required this.enabled,
    required this.image,
    required this.useImage,
    required this.visualState,
    required this.isStopping,
  });

  static const double outerSize = 230;
  static const double glyphDiameter = 47;

  final VoidCallback? onTap;
  final bool enabled;
  final AssetGenImage image;
  final bool useImage;
  final MainVpnButtonVisualState visualState;
  final bool isStopping;

  @override
  State<_ConnectionButtonFace> createState() => _ConnectionButtonFaceState();
}

// Geometry, rather than opacity, carries every transition. The current frame is
// the starting point of a new transition, including cancel/retry and fast starts.
class _ConnectionButtonFaceState extends State<_ConnectionButtonFace> with TickerProviderStateMixin {
  static const _duration = _connectionTransitionDuration;
  static const _rotationDuration = Duration(milliseconds: 1500);
  static const _restRadius = 99.0;
  static const _connectedRadius = 67.5;
  static const _outerRadius = 115.0;
  static const _loadingSweep = math.pi * 1.2;

  late final AnimationController _morph;
  late final AnimationController _rotation;
  late final AnimationController _gradientFlow;
  late final Listenable _animation;
  late _DialFrame _from;
  late _DialFrame _to;
  bool _reduceMotion = false;
  bool _pressed = false;

  bool get _spinning => widget.visualState == MainVpnButtonVisualState.loading && !widget.isStopping;

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(vsync: this, duration: _duration, value: 1);
    _rotation = AnimationController(vsync: this, duration: _rotationDuration);
    _gradientFlow = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _animation = Listenable.merge([_morph, _rotation]);
    _from = _to = _targetFrame(-math.pi / 2);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _retarget(animate: false);
    } else if (_spinning && !_reduceMotion && !_rotation.isAnimating) {
      _rotation.repeat();
    }
    _syncGradientFlow();
  }

  void _syncGradientFlow() {
    final active = _spinning || widget.visualState == MainVpnButtonVisualState.connected;
    if (active && !_reduceMotion) {
      if (!_gradientFlow.isAnimating) _gradientFlow.repeat();
    } else {
      // Keep the current colors when stopping or enabling reduced motion.
      _gradientFlow.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _ConnectionButtonFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visualState != widget.visualState || oldWidget.isStopping != widget.isStopping) {
      _retarget(animate: !_reduceMotion);
    }
    if (!widget.enabled) _pressed = false;
  }

  _DialFrame _targetFrame(double angle) {
    if (widget.isStopping ||
        widget.visualState == MainVpnButtonVisualState.off ||
        widget.visualState == MainVpnButtonVisualState.failed) {
      return _DialFrame(innerRadius: _restRadius, outerRadius: _restRadius - 1, sweep: 0, angle: angle);
    }
    return _DialFrame(
      innerRadius: _connectedRadius,
      outerRadius: _outerRadius,
      sweep: _spinning ? _loadingSweep : math.pi * 2,
      angle: angle,
    );
  }

  _DialFrame get _frame {
    final t = Curves.easeInOutCubic.transform(_morph.value);
    return _DialFrame(
      innerRadius: _mix(_from.innerRadius, _to.innerRadius, t),
      outerRadius: _mix(_from.outerRadius, _to.outerRadius, t),
      sweep: _mix(_from.sweep, _to.sweep, t),
      // Keep the spinner's phase at completion, then let it coast to rest.
      angle: _mix(_from.angle, _to.angle, Curves.easeOutCubic.transform(_morph.value)) + _rotation.value * math.pi * 2,
    );
  }

  void _retarget({required bool animate}) {
    var current = _frame;
    _rotation.stop();
    _rotation.value = 0;
    var target = _targetFrame(current.angle);
    if (target.outerRadius < target.innerRadius) {
      // Preserve the arc while the expanding center swallows it radially.
      target = target.copyWith(sweep: current.sweep);
    } else if (current.outerRadius <= current.innerRadius) {
      current = current.copyWith(sweep: 0);
    }
    if (widget.visualState == MainVpnButtonVisualState.connected && animate) {
      // easeOutCubic starts at 3x its mean velocity: match the running
      // spinner's velocity at the seam instead of accelerating on success.
      final coast = math.pi * 2 * _duration.inMilliseconds / _rotationDuration.inMilliseconds / 3;
      target = target.copyWith(angle: current.angle + coast);
    }
    _from = animate ? current : target;
    _to = target;
    if (animate) {
      _morph.forward(from: 0);
    } else {
      _morph.value = 1;
    }
    if (_spinning && !_reduceMotion) _rotation.repeat();
    _syncGradientFlow();
  }

  @override
  void dispose() {
    _morph.dispose();
    _rotation.dispose();
    _gradientFlow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    final logoAssetPath = isDarkTheme ? 'assets/images/SVG/logo-black.svg' : 'assets/images/SVG/logo-white.svg';
    final logoColor =
        theme.extension<HomeVisualTheme>()?.connectionLogoColor ??
        (isDarkTheme ? Colors.white : theme.colorScheme.onSurface);

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        key: const ValueKey('home_connection_button'),
        customBorder: const CircleBorder(),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        onTap: widget.enabled ? widget.onTap : null,
        onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: widget.enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: widget.enabled ? () => setState(() => _pressed = false) : null,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _animation,
            child: SizedBox.square(
              dimension: _ConnectionButtonFace.glyphDiameter,
              child: widget.useImage
                  ? widget.image.image(fit: BoxFit.contain)
                  : SvgPicture.asset(logoAssetPath, colorFilter: ColorFilter.mode(logoColor, BlendMode.srcIn)),
            ),
            builder: (context, child) {
              final frame = _frame;
              return SizedBox.square(
                dimension: _ConnectionButtonFace.outerSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size.square(_ConnectionButtonFace.outerSize),
                      painter: ConnectionRingPainter(
                        offColor: theme.colorScheme.secondaryContainer,
                        innerRadius: frame.innerRadius,
                        activeOuterRadius: frame.outerRadius,
                        sweep: frame.sweep,
                        angle: frame.angle,
                        gradientPhase: _gradientFlow,
                      ),
                    ),
                    AnimatedScale(
                      scale: _pressed && widget.enabled ? .96 : 1,
                      duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      child: Container(
                        key: const ValueKey('home_connection_button_center'),
                        width: frame.innerRadius * 2,
                        height: frame.innerRadius * 2,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          shape: BoxShape.circle,
                          boxShadow: _reduceMotion
                              ? const []
                              : [
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
                          child: _ConnectionContentOpacity(
                            visualState: widget.visualState,
                            isStopping: widget.isStopping,
                            child: child!,
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
      ),
    );
  }
}

double _mix(double a, double b, double t) => a + (b - a) * t;

class _DialFrame {
  const _DialFrame({required this.innerRadius, required this.outerRadius, required this.sweep, required this.angle});

  final double innerRadius;
  final double outerRadius;
  final double sweep;
  final double angle;

  _DialFrame copyWith({double? sweep, double? angle}) => _DialFrame(
    innerRadius: innerRadius,
    outerRadius: outerRadius,
    sweep: sweep ?? this.sweep,
    angle: angle ?? this.angle,
  );
}

/// The same opaque green arc grows into the connected ring; no cross-fade or
/// success timer can override runtime state. Public for rendered-frame tests.
@visibleForTesting
class ConnectionRingPainter extends CustomPainter {
  const ConnectionRingPainter({
    required this.offColor,
    required this.innerRadius,
    required this.activeOuterRadius,
    required this.sweep,
    required this.angle,
    required this.gradientPhase,
  }) : super(repaint: gradientPhase);

  final Color offColor;
  final double innerRadius;
  final double activeOuterRadius;
  final double sweep;
  final double angle;
  // Repaint the ring directly: the resting center, logo and label do not rebuild
  // on each gradient tick. This phase is independent of the spinner's rotation.
  final Animation<double> gradientPhase;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 230;
    canvas.save();
    canvas.translate((size.width - 230 * scale) / 2, (size.height - 230 * scale) / 2);
    canvas.scale(scale);
    const center = Offset(115, 115);
    canvas.drawCircle(center, 115, Paint()..color = offColor);

    final width = activeOuterRadius - innerRadius;
    if (width > 0 && sweep > 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: const [Color(0xFF3CE74F), Color(0xFFBFDD71)],
          transform: GradientRotation(gradientPhase.value * math.pi * 2),
        ).createShader(const Rect.fromLTWH(0, 0, 230, 230));
      final radius = (activeOuterRadius + innerRadius) / 2;
      if (sweep >= math.pi * 2 - .001) {
        canvas.drawCircle(center, radius, paint);
      } else {
        canvas.drawArc(Rect.fromCircle(center: center, radius: radius), angle, sweep, false, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ConnectionRingPainter oldDelegate) =>
      offColor != oldDelegate.offColor ||
      innerRadius != oldDelegate.innerRadius ||
      activeOuterRadius != oldDelegate.activeOuterRadius ||
      sweep != oldDelegate.sweep ||
      angle != oldDelegate.angle ||
      gradientPhase != oldDelegate.gradientPhase;
}
