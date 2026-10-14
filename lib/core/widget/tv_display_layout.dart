import 'package:flutter/widgets.dart';

/// A denser app canvas for TVs (960 x 540 becomes 1280 x 720).
///
/// Scaling the entire layout keeps dialogs, focus, semantics and hit testing in
/// the same coordinate space. It does not alter Android's display settings or
/// discard the user's accessibility text scale.
class TvDisplayLayout extends StatefulWidget {
  const TvDisplayLayout({super.key, required this.isTelevision, required this.child});

  final bool isTelevision;
  final Widget child;

  static const scale = .75;

  @override
  State<TvDisplayLayout> createState() => _TvDisplayLayoutState();
}

class _TvDisplayLayoutState extends State<TvDisplayLayout> {
  FocusHighlightStrategy? _previousHighlightStrategy;

  @override
  void initState() {
    super.initState();
    _updateFocusPolicy();
  }

  @override
  void didUpdateWidget(TvDisplayLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isTelevision != widget.isTelevision) _updateFocusPolicy();
  }

  void _updateFocusPolicy() {
    if (widget.isTelevision) {
      _previousHighlightStrategy ??= FocusManager.instance.highlightStrategy;
      // Android normally starts in touch mode. A TV must show its initial
      // focused action even before the first remote key event.
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    } else {
      _restoreFocusPolicy();
    }
  }

  void _restoreFocusPolicy() {
    final previous = _previousHighlightStrategy;
    if (previous == null) return;
    if (FocusManager.instance.highlightStrategy == FocusHighlightStrategy.alwaysTraditional) {
      FocusManager.instance.highlightStrategy = previous;
    }
    _previousHighlightStrategy = null;
  }

  @override
  void dispose() {
    _restoreFocusPolicy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isTelevision) return widget.child;
    const scale = TvDisplayLayout.scale;
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return widget.child;
        final size = constraints.biggest / scale;
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: media.copyWith(
                size: size,
                devicePixelRatio: media.devicePixelRatio * scale,
                padding: media.padding / scale,
                viewPadding: media.viewPadding / scale,
                viewInsets: media.viewInsets / scale,
                systemGestureInsets: media.systemGestureInsets / scale,
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
