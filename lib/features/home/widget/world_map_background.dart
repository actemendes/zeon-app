import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:zeon/core/theme/app_color_tokens.dart';
import 'package:zeon/core/theme/theme_extensions.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/model/world_map_geometry.dart';
import 'package:zeon/features/home/model/world_map_motion.dart';

/// The supplied SVG geometry, baked once by tool/generate_world_map.py.
/// A single painter animates visible dots; no SVG reparsing or widget-per-dot.
class WorldMapBackground extends StatefulWidget {
  const WorldMapBackground({super.key, required this.state, this.buttonKey});

  final MainVpnButtonState state;
  final GlobalKey? buttonKey;

  @override
  State<WorldMapBackground> createState() => _WorldMapBackgroundState();
}

class _WorldMapBackgroundState extends State<WorldMapBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _canvasKey = GlobalKey();
  late final WorldMapMotion _motion;
  late final Ticker _ticker;
  Duration _lastFrame = Duration.zero;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _motion = WorldMapMotion(widget.state);
    _ticker = createTicker(_tick);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.updateReducedMotion(MediaQuery.disableAnimationsOf(context));
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant WorldMapBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion.updateState(widget.state);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTicker();
  }

  void _syncTicker() {
    final enabled = _foreground && !_motion.reducedMotion && TickerMode.of(context);
    if (enabled && !_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    } else if (!enabled && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final delta = elapsed - _lastFrame;
    if (delta.inMicroseconds < 33333) return; // Decorative layer: at most 30 fps.
    _lastFrame = elapsed;
    final button = widget.buttonKey?.currentContext?.findRenderObject();
    final map = _canvasKey.currentContext?.findRenderObject();
    if (button is RenderBox && button.hasSize && button.attached && map is RenderBox && map.hasSize) {
      _motion.updateOrigin(map.globalToLocal(button.localToGlobal(button.size.center(Offset.zero))));
    }
    _motion.advance(delta.inMicroseconds / Duration.microsecondsPerSecond);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            key: _canvasKey,
            painter: WorldMapPainter(
              motion: _motion,
              background: theme.colorScheme.surface,
              dotColor:
                  theme.extension<HomeVisualTheme>()?.mapDotColor ??
                  (theme.brightness == Brightness.dark ? worldMapDarkColor : AppColorTokens.lightMapDots),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class WorldMapPainter extends CustomPainter {
  WorldMapPainter({required this.motion, required this.background, required this.dotColor})
    : _paints = List.generate(33, (i) => Paint()..color = Color.lerp(dotColor, const Color(0xFF3CE74F), i / 32 * .3)!),
      super(repaint: motion);

  final WorldMapMotion motion;
  final Color background;
  final Color dotColor;
  final List<Paint> _paints;
  Size? _layoutSize;
  List<Offset> _visiblePoints = const [];
  double _radius = 0;

  void _layout(Size size) {
    if (size == _layoutSize) return;
    _layoutSize = size;
    final scale = math.max(size.width / worldMapSize.width, size.height / worldMapSize.height);
    // Center the Atlantic under the button; keep this geographic shift in
    // source units so the composition scales with the map on every screen.
    final offset = Offset((size.width - worldMapSize.width * scale) / 2 + 270 * scale, 0);
    _radius = worldMapDotRadius * scale;
    final bounds = (Offset.zero & size).inflate(_radius * 1.5);
    _visiblePoints = [
      for (final point in worldMapPoints)
        if (bounds.contains(point * scale + offset)) point * scale + offset,
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _layout(size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(background, BlendMode.src);
    final fallbackOrigin = Offset(size.width / 2, size.height * .47);
    for (final point in _visiblePoints) {
      final sample = motion.sample(point, fallbackOrigin);
      final paint = _paints[(sample.tint / .3 * 32).round().clamp(0, 32)];
      canvas.drawCircle(point, _radius * sample.scale, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WorldMapPainter oldDelegate) =>
      motion != oldDelegate.motion || background != oldDelegate.background || dotColor != oldDelegate.dotColor;
}
