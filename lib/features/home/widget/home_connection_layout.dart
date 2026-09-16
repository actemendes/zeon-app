import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps the dial at the viewport's centre and grows only when real content
/// would overlap. The surrounding scroll view handles genuinely short windows.
class HomeConnectionLayout extends MultiChildRenderObjectWidget {
  HomeConnectionLayout({
    super.key,
    required this.viewportHeight,
    required this.desktop,
    required Widget header,
    required Widget dial,
    required Widget status,
    required Widget footer,
  }) : super(children: [header, dial, status, footer]);

  final double viewportHeight;
  final bool desktop;

  @override
  RenderObject createRenderObject(BuildContext context) => _HomeConnectionRenderBox(viewportHeight, desktop);

  @override
  void updateRenderObject(BuildContext context, covariant _HomeConnectionRenderBox renderObject) {
    renderObject.update(viewportHeight, desktop);
  }
}

class _HomeParentData extends ContainerBoxParentData<RenderBox> {}

class _HomeConnectionRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HomeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HomeParentData> {
  _HomeConnectionRenderBox(this._viewportHeight, this._desktop);

  double _viewportHeight;
  bool _desktop;

  void update(double viewportHeight, bool desktop) {
    if (_viewportHeight == viewportHeight && _desktop == desktop) return;
    _viewportHeight = viewportHeight;
    _desktop = desktop;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HomeParentData) child.parentData = _HomeParentData();
  }

  @override
  void performLayout() {
    final children = getChildrenAsList();
    final header = children[0];
    final dial = children[1];
    final status = children[2];
    final footer = children[3];
    final width = constraints.maxWidth;
    final contentWidth = math.max(0.0, width - 32);
    header.layout(BoxConstraints.tightFor(width: contentWidth), parentUsesSize: true);
    dial.layout(BoxConstraints(maxWidth: contentWidth), parentUsesSize: true);
    status.layout(
      BoxConstraints.tightFor(width: _desktop ? math.min(440.0, contentWidth) : contentWidth),
      parentUsesSize: true,
    );
    footer.layout(BoxConstraints.tightFor(width: contentWidth), parentUsesSize: true);

    final halfDial = dial.size.height / 2;
    final statusGap = _desktop ? 16.0 : 24.0;
    final footerGap = footer.size.height > 0 ? 12.0 : 0.0;
    final topSpace = 24.0 + header.size.height + 24 + halfDial;
    final bottomSpace = halfDial + statusGap + status.size.height + footerGap + footer.size.height + 16;
    final height = math.max(_viewportHeight, 2.0 * math.max(topSpace, bottomSpace));
    size = constraints.constrain(Size(width, height));

    void place(RenderBox child, double x, double y) {
      (child.parentData! as _HomeParentData).offset = Offset(x, y);
    }

    place(header, 16, 24);
    place(dial, (width - dial.size.width) / 2, size.height / 2 - halfDial);
    place(status, (width - status.size.width) / 2, size.height / 2 + halfDial + statusGap);
    place(footer, 16, size.height - 16 - footer.size.height);
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
