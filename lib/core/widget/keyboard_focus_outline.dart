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
    this.focused,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double outset;
  final bool includeDescendantFocus;

  /// For composite Material controls whose focus node is inside [child].
  final bool? focused;

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
    final focused =
        widget.focused ?? ((widget.includeDescendantFocus ? node?.hasFocus : node?.hasPrimaryFocus) ?? false);
    final visible = focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return CustomPaint(
      foregroundPainter: visible
          ? KeyboardFocusOutlinePainter.fromTheme(
              Theme.of(context),
              borderRadius: widget.borderRadius,
              outset: widget.outset,
            )
          : null,
      child: widget.child,
    );
  }
}

class KeyboardFocusOutlinePainter extends CustomPainter {
  const KeyboardFocusOutlinePainter({
    required this.color,
    required this.borderRadius,
    required this.outset,
    this.separatorColor = const Color(0xFF101010),
    this.separatorWidth = 8,
  });

  factory KeyboardFocusOutlinePainter.fromTheme(
    ThemeData theme, {
    required BorderRadius borderRadius,
    required double outset,
  }) {
    final colors = theme.colorScheme;
    final light = colors.brightness == Brightness.light;
    return KeyboardFocusOutlinePainter(
      color: light ? Color.lerp(colors.primary, colors.onSurface, .45)! : colors.primary,
      separatorColor: light ? colors.surface : const Color(0xFF101010),
      separatorWidth: light ? 6 : 8,
      borderRadius: borderRadius,
      outset: outset,
    );
  }

  final Color color;
  final BorderRadius borderRadius;
  final double outset;
  final Color separatorColor;
  final double separatorWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = (Offset.zero & size).inflate(outset).deflate(4);
    if (bounds.isEmpty) return;
    final outline = borderRadius.toRRect(bounds);
    // Separate focus from selected green controls without a black edge in Light.
    canvas.drawRRect(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = separatorWidth
        ..color = separatorColor,
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
      color != oldDelegate.color ||
      separatorColor != oldDelegate.separatorColor ||
      separatorWidth != oldDelegate.separatorWidth ||
      borderRadius != oldDelegate.borderRadius ||
      outset != oldDelegate.outset;
}
