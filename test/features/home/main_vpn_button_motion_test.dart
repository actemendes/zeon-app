import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  testWidgets('center contracts, rotating arc closes from its current phase, then center absorbs it', (tester) async {
    await showPhase(tester, VpnSessionPhase.disconnected);
    final off = ring(tester);
    expect(centerSize(tester), 198);
    expect(off.activeOuterRadius, lessThan(off.innerRadius));

    await showPhase(tester, VpnSessionPhase.startRequested);
    expect(centerSize(tester), 198);
    await tester.pump(const Duration(milliseconds: 230));
    expect(centerSize(tester), inExclusiveRange(135, 198));
    expect(ring(tester).sweep, inExclusiveRange(0, math.pi * 2));
    await tester.pump(const Duration(milliseconds: 230));
    expect(centerSize(tester), 135);
    final loading = ring(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ring(tester).angle, greaterThan(loading.angle));

    final beforeConnected = ring(tester);
    await showPhase(tester, VpnSessionPhase.connected);
    expect(ring(tester).angle, closeTo(beforeConnected.angle, .00001));
    expect(ring(tester).sweep, closeTo(beforeConnected.sweep, .00001));
    await tester.pump(const Duration(milliseconds: 230));
    expect(ring(tester).sweep, inExclusiveRange(beforeConnected.sweep, math.pi * 2));
    await tester.pump(const Duration(milliseconds: 230));
    expect(ring(tester).sweep, math.pi * 2);
    expect(ring(tester).activeOuterRadius, 115);
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.binding.transientCallbackCount, 0);

    await showPhase(tester, VpnSessionPhase.stopRequested);
    expect(centerSize(tester), 135);
    await tester.pump(const Duration(milliseconds: 230));
    expect(centerSize(tester), inExclusiveRange(135, 198));
    expect(ring(tester).sweep, math.pi * 2);
    final duringStop = ring(tester);
    await showPhase(tester, VpnSessionPhase.disconnected);
    expect(centerSize(tester), duringStop.innerRadius * 2);
    await tester.pump(const Duration(milliseconds: 460));
    expect(centerSize(tester), 198);
    expect(ring(tester).activeOuterRadius, lessThan(ring(tester).innerRadius));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('long verification never completes the ring without runtime Connected', (tester) async {
    await showPhase(tester, VpnSessionPhase.verifying);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 10));
      expect(ring(tester).sweep, lessThan(math.pi * 2));
      expect(find.text('Подключено'), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('connected re-entry and theme rebuild render the full active ring immediately', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(const SizedBox.shrink());
      await showPhase(tester, VpnSessionPhase.connected, brightness: brightness);
      expect(ring(tester).sweep, math.pi * 2);
      expect(ring(tester).activeOuterRadius, 115);
      expect(centerSize(tester), 135);
      expect(find.byKey(const ValueKey('Подключено')), findsOneWidget);
    }
    await showPhase(tester, VpnSessionPhase.connected, brightness: Brightness.dark);
    expect(ring(tester).sweep, math.pi * 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('cancel, failure and retry retarget the current geometry without a snap', (tester) async {
    await showPhase(tester, VpnSessionPhase.disconnected);
    for (final phase in [
      VpnSessionPhase.startRequested,
      VpnSessionPhase.stopRequested,
      VpnSessionPhase.disconnected,
      VpnSessionPhase.verifying,
      VpnSessionPhase.failed,
      VpnSessionPhase.startingCore,
      VpnSessionPhase.connected,
      VpnSessionPhase.stopping,
      VpnSessionPhase.connected,
    ]) {
      final before = ring(tester);
      await showPhase(tester, phase);
      final after = ring(tester);
      expect(after.innerRadius, closeTo(before.innerRadius, .00001));
      expect(after.activeOuterRadius, closeTo(before.activeOuterRadius, .00001));
      expect(after.angle, closeTo(before.angle, .00001));
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.takeException(), isNull);
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(ring(tester).sweep, math.pi * 2);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('failure during connection returns to the idle geometry and stops ticking', (tester) async {
    await showPhase(tester, VpnSessionPhase.verifying);
    await tester.pump(const Duration(milliseconds: 90));
    await showPhase(tester, VpnSessionPhase.failed);
    await tester.pump(const Duration(milliseconds: 500));
    expect(centerSize(tester), 198);
    expect(ring(tester).activeOuterRadius, lessThan(ring(tester).innerRadius));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion uses static open loading and complete connected ring', (tester) async {
    await showPhase(tester, VpnSessionPhase.disconnected, reduceMotion: true);
    await showPhase(tester, VpnSessionPhase.verifying, reduceMotion: true);
    final loading = ring(tester);
    expect(loading.sweep, inExclusiveRange(0, math.pi * 2));
    await tester.pump(const Duration(seconds: 1));
    expect(ring(tester).angle, loading.angle);
    expect(tester.binding.transientCallbackCount, 0);
    await showPhase(tester, VpnSessionPhase.connected, reduceMotion: true);
    expect(ring(tester).sweep, math.pi * 2);
    await showPhase(tester, VpnSessionPhase.stopping, reduceMotion: true);
    expect(centerSize(tester), 198);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('turning reduced motion on mid-transition settles the authoritative state', (tester) async {
    await showPhase(tester, VpnSessionPhase.disconnected);
    await showPhase(tester, VpnSessionPhase.verifying);
    await tester.pump(const Duration(milliseconds: 100));
    await showPhase(tester, VpnSessionPhase.connected, reduceMotion: true);
    expect(ring(tester).sweep, math.pi * 2);
    expect(centerSize(tester), 135);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('loading can be cancelled, stopping blocks taps, Connected restores STOP immediately', (tester) async {
    var calls = 0;
    await showPhase(tester, VpnSessionPhase.verifying, onTap: () => calls++);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    expect(calls, 1);
    await showPhase(tester, VpnSessionPhase.stopping, onTap: () => calls++);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    expect(calls, 1);
    await showPhase(tester, VpnSessionPhase.connected, onTap: () => calls++);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 1));
  });
}

ConnectionRingPainter ring(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<ConnectionRingPainter>()
    .single;

double centerSize(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('home_connection_button_center'))).width;

Future<void> showPhase(
  WidgetTester tester,
  VpnSessionPhase phase, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  VoidCallback? onTap,
}) {
  final state = MainVpnButtonState.fromSnapshot(
    VpnSessionSnapshot(
      generation: 42,
      runtimeEpoch: 'runtime-1',
      sequenceNumber: 1,
      snapshotVersion: 1,
      phase: phase,
      requestedAction: 'connect',
      recoverable: true,
    ),
  );
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Center(
            child: MainVpnButtonView(
              presentation: state.present(TranslationsRu()),
              onTap: onTap ?? () {},
              image: Assets.images.disconnectNorouz,
              useImage: false,
              secureLabel: '',
            ),
          ),
        ),
      ),
    ),
  );
}
