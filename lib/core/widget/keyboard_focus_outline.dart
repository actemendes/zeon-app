import 'package:flutter/material.dart';

/// A foreground cue for the enclosing control's keyboard/remote focus.
/// It adds no focus target, padding, animation, or touch-mode decoration.
class KeyboardFocusOutline extends StatefulWidget {
  const KeyboardFocusOutline({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.outset = 0,
    this.includeDescendantFocus = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double outset;
  final bool includeDescendantFocus;

  /// Wraps the whole padded Material button without replacing its local style.
  static Widget buttonBuilder(BuildContext context, Set<WidgetState> states, Widget? child) =>
      KeyboardFocusOutline(child: child ?? const SizedBox.shrink());

  @override
  State<KeyboardFocusOutline> createState() => _KeyboardFocusOutlineState();
}

class _KeyboardFocusOutlineState extends State<KeyboardFocusOutline> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_highlightModeChanged);
  }

  void _highlightModeChanged(FocusHighlightMode _) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = Focus.maybeOf(context);
    final focused = (widget.includeDescendantFocus ? node?.hasFocus : node?.hasPrimaryFocus) ?? false;
    final visible = focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return CustomPaint(
      foregroundPainter: visible
          ? KeyboardFocusOutlinePainter(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: widget.borderRadius,
              outset: widget.outset,
            )
          : null,
      child: widget.child,
    );
  }
}

class KeyboardFocusOutlinePainter extends CustomPainter {
  const KeyboardFocusOutlinePainter({required this.color, required this.borderRadius, required this.outset});

  final Color color;
  final BorderRadius borderRadius;
  final double outset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = (Offset.zero & size).inflate(outset).deflate(4);
    if (bounds.isEmpty) return;
    final outline = borderRadius.toRRect(bounds);
    // The dark edge separates the green ring from selected/green controls.
    canvas.drawRRect(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = const Color(0xFF101010),
    );
    canvas.drawRRect(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(KeyboardFocusOutlinePainter oldDelegate) =>
      color != oldDelegate.color || borderRadius != oldDelegate.borderRadius || outset != oldDelegate.outset;
}
