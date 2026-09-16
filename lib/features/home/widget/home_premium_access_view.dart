import 'package:flutter/material.dart';
import 'package:zeon/core/theme/theme_extensions.dart';

/// Presentation shared by the home entry point and isolated visual previews.
class HomePremiumAccessView extends StatelessWidget {
  const HomePremiumAccessView({
    super.key,
    required this.remainingDays,
    required this.label,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final int? remainingDays;
  final String label;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  // This is the renewal countdown, not the fraction of the purchased plan.
  static const _countdownDays = 10;
  static const _accentText = Color(0xFF101010);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentText = colors.brightness == Brightness.light ? colors.onSurface : _accentText;
    final trackColor =
        theme.extension<HomeVisualTheme>()?.premiumTrackColor ??
        (colors.brightness == Brightness.dark ? HomeVisualTheme.amoled : HomeVisualTheme.light).premiumTrackColor;
    final gradient = LinearGradient(colors: [colors.secondary, colors.primary]);
    final days = remainingDays;
    if (days == null || days < 1) {
      return _InactivePremiumState(
        title: title,
        subtitle: subtitle,
        textColor: _accentText,
        gradient: gradient,
        onPressed: onPressed,
      );
    }

    final progress = (days / _countdownDays).clamp(0.0, 1.0);
    final direction = Directionality.of(context);
    final textStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontFamily: 'Unbounded', fontWeight: FontWeight.w500, fontSize: 18, height: 1);
    Widget text(Color color) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          label.toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textStyle?.copyWith(color: color),
        ),
      ),
    );

    return Semantics(
      label: label,
      button: true,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 35.19,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: progress, end: progress),
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              builder: (context, value, child) => Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _PremiumProgressPainter(
                      progress: value,
                      direction: direction,
                      gradient: gradient,
                      trackColor: trackColor,
                      contourColor: colors.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                  text(colors.onSurface),
                  // Identical layout lets dark themes use a dark label over
                  // the accent; light themes keep their regular text color.
                  ClipPath(clipper: _PremiumFillClipper(value, direction), child: text(accentText)),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(onTap: onPressed),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

RRect _fillRect(Size size, double progress, TextDirection direction) {
  final width = size.width * progress;
  return RRect.fromRectAndRadius(
    Rect.fromLTWH(direction == TextDirection.rtl ? size.width - width : 0, 0, width, size.height),
    const Radius.circular(16),
  );
}

class _PremiumFillClipper extends CustomClipper<Path> {
  const _PremiumFillClipper(this.progress, this.direction);

  final double progress;
  final TextDirection direction;

  @override
  Path getClip(Size size) => Path()..addRRect(_fillRect(size, progress, direction));

  @override
  bool shouldReclip(_PremiumFillClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.direction != direction;
}

class _PremiumProgressPainter extends CustomPainter {
  const _PremiumProgressPainter({
    required this.progress,
    required this.direction,
    required this.gradient,
    required this.trackColor,
    required this.contourColor,
  });

  final double progress;
  final TextDirection direction;
  final LinearGradient gradient;
  final Color trackColor;
  final Color contourColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = trackColor);
    // The original contour motif remains vector-based and scales with width.
    final contourPaint = Paint()
      ..color = contourColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.save();
    if (direction == TextDirection.rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    for (var i = 0; i < 5; i++) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * 1.04, size.height * 1.1),
          width: size.width * (0.67 - i * 0.095),
          height: size.height * (5.8 - i * 0.9),
        ),
        contourPaint,
      );
    }
    canvas.restore();
    if (progress <= 0) return;
    final fill = _fillRect(size, progress, direction);
    canvas.drawRRect(fill, Paint()..shader = gradient.createShader(fill.outerRect));
  }

  @override
  bool shouldRepaint(_PremiumProgressPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.direction != direction ||
      oldDelegate.gradient != gradient ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.contourColor != contourColor;
}

class _InactivePremiumState extends StatelessWidget {
  const _InactivePremiumState({
    required this.title,
    required this.subtitle,
    required this.textColor,
    required this.gradient,
    required this.onPressed,
  });

  static const double _height = 65;
  static const double _leftSegmentWidth = 65;
  static const double _crownPadding = 18;
  static const double _crownSize = 29;
  static const double _arrowSize = 24;
  static const double _arrowVisualScale = 1.18;

  final String title;
  final String subtitle;
  final Color textColor;
  final LinearGradient gradient;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: _height,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: gradient),
        child: InkWell(
          onTap: onPressed,
          child: Row(
            children: [
              Container(
                width: _leftSegmentWidth,
                height: _height,
                color: Colors.transparent,
                padding: const EdgeInsets.all(_crownPadding),
                child: _PremiumCrownIcon(size: _crownSize, color: textColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFamily: 'Unbounded',
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: textColor,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      subtitle.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: textColor,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox.square(
                dimension: 44,
                child: Center(
                  child: Transform.scale(
                    scale: _arrowVisualScale,
                    child: Icon(Icons.arrow_outward, size: _arrowSize, color: textColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PremiumCrownIcon extends StatelessWidget {
  const _PremiumCrownIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PremiumCrownPainter(color)),
    );
  }
}

class _PremiumCrownPainter extends CustomPainter {
  const _PremiumCrownPainter(this.color);

  static const _viewBox = 31.15;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _viewBox;
    final dx = (size.width - (_viewBox * scale)) / 2;
    final dy = (size.height - (_viewBox * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final crownPath = Path()
      ..moveTo(1, 30.15)
      ..lineTo(30.15, 30.15)
      ..moveTo(1, 1)
      ..lineTo(1, 23.9)
      ..lineTo(30.15, 23.9)
      ..lineTo(30.15, 1)
      ..lineTo(22.86, 9.33)
      ..lineTo(15.57, 1)
      ..lineTo(8.28, 9.33)
      ..close();

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawPath(crownPath, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PremiumCrownPainter oldDelegate) => oldDelegate.color != color;
}
