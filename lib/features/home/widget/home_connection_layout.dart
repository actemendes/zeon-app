import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Centres the dial vertically, or places it beside the controls in short
/// landscape windows. Scrolling is needed only when the measured content cannot fit.
class HomeConnectionLayout extends MultiChildRenderObjectWidget {
  HomeConnectionLayout({
    super.key,
    required this.viewportHeight,
    required this.desktop,
    this.compact = false,
    required Widget header,
    required Widget dial,
    required Widget status,
    required Widget footer,
  }) : super(children: [header, dial, status, footer]);

  final double viewportHeight;
  final bool desktop;
  final bool compact;

  @override
  RenderObject createRenderObject(BuildContext context) => _HomeConnectionRenderBox(viewportHeight, desktop, compact);

  @override
  void updateRenderObject(BuildContext context, covariant _HomeConnectionRenderBox renderObject) {
    renderObject.update(viewportHeight, desktop, compact);
  }
}

class _HomeParentData extends ContainerBoxParentData<RenderBox> {}

class _HomeConnectionRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HomeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HomeParentData> {
  _HomeConnectionRenderBox(this._viewportHeight, this._desktop, this._compact);

  double _viewportHeight;
  bool _desktop;
  bool _compact;

  void update(double viewportHeight, bool desktop, bool compact) {
    if (_viewportHeight == viewportHeight && _desktop == desktop && _compact == compact) return;
    _compact = compact;
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
    if (_compact) {
      final leftWidth = math.min(220.0, contentWidth * .38);
      final rightWidth = math.max(0.0, contentWidth - leftWidth - 24);
      header.layout(BoxConstraints.tightFor(width: contentWidth), parentUsesSize: true);
      dial.layout(BoxConstraints(maxWidth: leftWidth), parentUsesSize: true);
      status.layout(BoxConstraints.tightFor(width: rightWidth), parentUsesSize: true);
      footer.layout(BoxConstraints.tightFor(width: rightWidth), parentUsesSize: true);
      final footerGap = footer.size.height > 0 ? 12.0 : 0.0;
      final rightHeight = status.size.height + footerGap + footer.size.height;
      final bodyHeight = math.max(dial.size.height, rightHeight);
      final bodyTop = 12 + header.size.height + 12;
      final height = math.max(_viewportHeight, bodyTop + bodyHeight + 12);
      size = constraints.constrain(Size(width, height));
      final contentTop = bodyTop + (size.height - bodyTop - 12 - bodyHeight) / 2;
      final rightTop = contentTop + (bodyHeight - rightHeight) / 2;
      (header.parentData! as _HomeParentData).offset = const Offset(16, 12);
      (dial.parentData! as _HomeParentData).offset = Offset(
        16 + (leftWidth - dial.size.width) / 2,
        contentTop + (bodyHeight - dial.size.height) / 2,
      );
      (status.parentData! as _HomeParentData).offset = Offset(16 + leftWidth + 24, rightTop);
      (footer.parentData! as _HomeParentData).offset = Offset(
        16 + leftWidth + 24,
        rightTop + status.size.height + footerGap,
      );
      return;
    }
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
