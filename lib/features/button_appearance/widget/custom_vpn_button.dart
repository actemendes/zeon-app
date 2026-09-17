import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:zeon/core/localization/translation_context.dart';

import 'package:zeon/features/button_appearance/button_appearance.dart';
export 'package:zeon/features/button_appearance/button_appearance.dart';

class PictureFace extends StatelessWidget {
  const PictureFace({super.key, required this.picture});
  final ButtonPicture? picture;
  @override
  Widget build(BuildContext context) {
    if (picture == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: const Center(child: Icon(Icons.add_photo_alternate_outlined, size: 32)),
      );
    }
    return ClipRect(
      child: Transform.scale(
        scale: picture!.zoom,
        alignment: picture!.alignment,
        child: Image(
          image: picture!.image,
          fit: BoxFit.cover,
          alignment: picture!.alignment,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)),
        ),
      ),
    );
  }
}

/// Presentation only. The owner supplies the authoritative VPN phase and action.
/// Animation completion never changes phase or implies a successful connection.
class CustomVpnButton extends StatefulWidget {
  const CustomVpnButton({
    super.key,
    required this.phase,
    required this.appearance,
    this.diameter = 244,
    this.onPressed,
    this.animate = true,
    this.semanticsLabel,
  });
  final ButtonPhase phase;
  final ButtonAppearance appearance;
  final double diameter;
  final VoidCallback? onPressed;
  final bool animate;
  final String? semanticsLabel;
  @override
  State<CustomVpnButton> createState() => _CustomVpnButtonState();
}

class _CustomVpnButtonState extends State<CustomVpnButton> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
    sync();
  }

  late final AnimationController spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  bool get motion =>
      _foreground && widget.animate && !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
  void sync() {
    if (motion && widget.phase == ButtonPhase.connecting) {
      if (!spin.isAnimating) spin.repeat();
    } else {
      spin.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(covariant CustomVpnButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final standard = widget.appearance.preset == ButtonPreset.standard;
    final picture = widget.appearance.pictureFor(widget.phase);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inset = standard ? widget.diameter * .16 : 11.0;
    return Semantics(
      button: true,
      label:
          widget.semanticsLabel ??
          '${widget.phase.label(context.translations)}. ${widget.phase.action(context.translations)}',
      enabled: widget.onPressed != null,
      child: SizedBox.square(
        dimension: widget.diameter,
        child: AnimatedContainer(
          duration: motion ? const Duration(milliseconds: 240) : Duration.zero,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              if (motion && widget.phase == ButtonPhase.connected)
                BoxShadow(color: zeonGreen.withValues(alpha: dark ? .17 : .19), blurRadius: 28, spreadRadius: 1),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: spin,
                builder: (_, _) => CustomPaint(
                  painter: _RingPainter(
                    widget.phase,
                    spin.value,
                    standard ? widget.diameter * .115 : 5.0,
                    Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(inset),
                child: ClipOval(
                  child: AnimatedSwitcher(
                    key: ValueKey(motion),
                    duration: motion ? const Duration(milliseconds: 240) : Duration.zero,
                    switchInCurve: Curves.easeInOut,
                    child: SizedBox.expand(
                      key: ValueKey(
                        '${widget.appearance.preset}-${widget.phase}-${picture?.image}-${picture?.zoom}-${picture?.alignment}',
                      ),
                      child: standard
                          ? ColoredBox(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: Center(
                                child: Image.asset(
                                  'assets/images/2x/logo-black_1@2x.png',
                                  width: widget.diameter * .36,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            )
                          : PictureFace(picture: picture),
                    ),
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onPressed,
                  focusColor: zeonGreen.withValues(alpha: .3),
                  hoverColor: zeonGreen.withValues(alpha: .07),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.phase, this.rotation, this.width, this.track);
  final ButtonPhase phase;
  final double rotation;
  final double width;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: (size.shortestSide - width) / 2 - 1);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, pen..color = track);
    if (phase == ButtonPhase.idle) return;
    pen.shader = const SweepGradient(colors: [zeonLime, zeonGreen, zeonLime]).createShader(rect);
    if (phase == ButtonPhase.connected) {
      canvas.drawOval(rect, pen);
    } else {
      canvas.drawArc(rect, rotation * math.pi * 2 - math.pi / 2, math.pi * 1.25, false, pen);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.phase != phase || old.rotation != rotation || old.width != width || old.track != track;
}
