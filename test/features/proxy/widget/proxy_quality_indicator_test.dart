import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  test('formats every explicit URLTest status unambiguously', () {
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'not_tested')), '-');
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'checking')), '...');
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'success', urlTestDelay: 42)), '42 ms');
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'failed')), '✕');
  });

  test('success without a valid delay is displayed as failed', () {
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'success')), '✕');
    expect(formatOutboundPing(OutboundInfo(urlTestStatus: 'success', urlTestDelay: 65535)), '✕');
  });

  test('supports results from older cores without explicit status', () {
    expect(formatOutboundPing(OutboundInfo(urlTestDelay: 85)), '85 ms');
    expect(formatOutboundPing(OutboundInfo(errorType: 'timeout')), '✕');
    expect(formatOutboundPing(OutboundInfo()), '-');
  });

  test('sorts by quality: success, checking, not tested, failed', () {
    final items = [
      OutboundInfo(tag: 'failed', urlTestStatus: 'failed'),
      OutboundInfo(tag: 'checking', urlTestStatus: 'checking'),
      OutboundInfo(tag: 'not-tested', urlTestStatus: 'not_tested'),
      OutboundInfo(tag: 'slow', urlTestStatus: 'success', urlTestDelay: 220, healthScore: 70),
      OutboundInfo(tag: 'fast', urlTestStatus: 'success', urlTestDelay: 40, healthScore: 95),
    ]..sort(compareOutboundsByPingQuality);

    expect(items.map((e) => e.tag), ['fast', 'slow', 'checking', 'not-tested', 'failed']);
  });

  testWidgets('checking result with stale health score does not draw filled bars', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QualityBars.fromOutbound(
            OutboundInfo(urlTestStatus: 'checking', urlTestDelay: 42, healthScore: 100, success: true),
            activeColor: Colors.green,
            inactiveColor: Colors.grey,
          ),
        ),
      ),
    );

    final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).toList();
    expect(boxes, hasLength(4));
    final colors = boxes.map((box) => (box.decoration as BoxDecoration).color).toList();
    expect(colors, everyElement(Colors.grey));
  });
}
