import 'dart:math' as math;
import 'package:flutter/material.dart';

const accent = Color(0xFF3CE74F);
const ink = Color(0xFF171C1B);

class SettingsSpotlightPainter extends CustomPainter {
  SettingsSpotlightPainter(this.rect, this.teaching);
  final Rect rect;
  final bool teaching;
  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(19));
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rr);
    canvas.drawPath(path, Paint()..color = Color(teaching ? 0xB8111517 : 0x87111517));
    canvas.drawRRect(
      rr,
      Paint()
        ..color = accent.withValues(alpha: .22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(SettingsSpotlightPainter old) => old.rect != rect || old.teaching != teaching;
}

class SettingsHandPainter extends CustomPainter {
  SettingsHandPainter(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    final reach = Curves.easeInOut.transform((progress / .35).clamp(0, 1));
    final release = progress > .85 ? (progress - .85) / .15 : 0.0;
    final dy = (1 - reach + release) * 19;
    canvas.translate(0, dy);
    const touch = Offset(36, 15);
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(touch, 10 + i * 9.0, Paint()..color = accent.withValues(alpha: (.14 - i * .035) * reach));
    }
    final hold = ((progress - .35) / .5).clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: touch, radius: 24),
      -math.pi / 2,
      math.pi * 2 * hold,
      false,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    final p = Path()
      ..moveTo(48, 92)
      ..cubicTo(41, 86, 26, 72, 20, 64)
      ..cubicTo(14, 56, 20, 50, 27, 54)
      ..lineTo(34, 61)
      ..lineTo(28, 22)
      ..cubicTo(26, 9, 39, 7, 42, 19)
      ..lineTo(48, 48)
      ..cubicTo(46, 34, 59, 33, 62, 45)
      ..cubicTo(63, 34, 73, 35, 75, 48)
      ..cubicTo(79, 39, 87, 44, 88, 53)
      ..lineTo(92, 70)
      ..cubicTo(94, 79, 87, 88, 88, 95)
      ..lineTo(60, 103)
      ..quadraticBezierTo(52, 104, 48, 92)
      ..close();
    canvas.drawPath(
      p,
      Paint()
        ..color = accent.withValues(alpha: .28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(p, Paint()..color = ink);
    canvas.drawPath(
      p,
      Paint()
        ..color = const Color(0xFF9AF4AB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(SettingsHandPainter old) => old.progress != progress;
}
