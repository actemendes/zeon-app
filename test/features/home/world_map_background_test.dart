import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/model/world_map_geometry.dart';
import 'package:zeon/features/home/model/world_map_motion.dart';
import 'package:zeon/features/home/widget/world_map_background.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  test('SVG bake contains one dot per solid/outline pair inside its viewBox', () {
    expect(worldMapPoints.length, 4748);
    expect(worldMapPoints.toSet().length, worldMapPoints.length);
    for (final p in worldMapPoints) {
      expect(p.dx, inInclusiveRange(0, worldMapSize.width));
      expect(p.dy, inInclusiveRange(0, worldMapSize.height));
    }
    expect(worldMapLightColor, const Color(0xFFEFF4F4));
    expect(worldMapDarkColor, const Color(0xFF181818));
  });

  test('first connecting wave travels outward from the button, not the screen origin', () {
    final motion = WorldMapMotion(state(VpnSessionPhase.verifying));
    addTearDown(motion.dispose);
    const button = Offset(270, 410);
    motion.updateOrigin(button);
    for (var i = 0; i < 10; i++) {
      motion.advance(.05);
    }
    expect(motion.sample(button, Offset.zero).tint, greaterThan(.2));
    expect(motion.sample(button + const Offset(300, 0), Offset.zero).tint, 0);
    for (var i = 0; i < 26; i++) {
      motion.advance(.05);
    }
    expect(motion.sample(button + const Offset(300, 0), Offset.zero).tint, greaterThan(.2));
  });

  test('elapsed time cannot promote connecting to Connected; cancellation settles idle', () {
    final motion = WorldMapMotion(state(VpnSessionPhase.verifying));
    addTearDown(motion.dispose);
    for (var i = 0; i < 1200; i++) {
      motion.advance(.05);
    }
    expect(motion.state.isConnected, isFalse);
    expect(motion.connected, 0);
    final phase = motion.phase;
    motion.updateState(state(VpnSessionPhase.connected));
    expect(motion.phase, phase);
    for (var i = 0; i < 100; i++) {
      motion.advance(.05);
    }
    expect(motion.connected, greaterThan(.99));
    expect(motion.speed, greaterThan(1.2));
    motion.updateState(state(VpnSessionPhase.failed));
    for (var i = 0; i < 100; i++) {
      motion.advance(.05);
    }
    expect(motion.connected, lessThan(.001));
    expect(motion.connecting, lessThan(.001));
    expect(motion.speed, closeTo(.42, .001));
  });

  test('reduced motion immediately settles current state and keeps the map static', () {
    final motion = WorldMapMotion(state(VpnSessionPhase.disconnected));
    addTearDown(motion.dispose);
    motion.updateState(state(VpnSessionPhase.connected));
    motion.advance(.05);
    motion.updateReducedMotion(true);
    final phase = motion.phase;
    final sample = motion.sample(const Offset(400, 200), Offset.zero);
    motion.advance(5);
    expect(motion.phase, phase);
    expect(motion.connected, 1);
    expect(motion.sample(const Offset(400, 200), Offset.zero), sample);
    motion.updateState(state(VpnSessionPhase.stopping));
    expect(motion.connected, 0);
    expect(motion.sample(Offset.zero, Offset.zero).tint, 0);
  });

  testWidgets('origin follows actual button layout and window resizing without rebuilding painter per tick', (
    tester,
  ) async {
    final key = GlobalKey();
    await showMap(tester, buttonKey: key, left: 60, top: 130);
    await tester.pump(const Duration(milliseconds: 40));
    final painter = mapPainter(tester);
    expect(painter.motion.origin, const Offset(175, 245));
    final time = painter.motion.seconds;
    await tester.pump(const Duration(milliseconds: 40));
    expect(mapPainter(tester), same(painter));
    expect(painter.motion.seconds, greaterThan(time));
    await showMap(tester, buttonKey: key, left: 180, top: 70, width: 620);
    await tester.pump(const Duration(milliseconds: 40));
    expect(mapPainter(tester).motion.origin, const Offset(295, 185));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('hidden, reduced-motion, and background-app maps stop scheduling frames', (tester) async {
    await showMap(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await showMap(tester, tickerEnabled: false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, 0);
    final phase = mapPainter(tester).motion.phase;
    await tester.pump(const Duration(seconds: 10));
    await showMap(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(mapPainter(tester).motion.phase - phase, lessThan(.1));
    await showMap(tester, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, 0);
    await showMap(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });
}

MainVpnButtonState state(VpnSessionPhase phase) => MainVpnButtonState.fromSnapshot(
  VpnSessionSnapshot(
    generation: 1,
    runtimeEpoch: 'map-test',
    sequenceNumber: 1,
    snapshotVersion: 1,
    phase: phase,
    requestedAction: 'connect',
    recoverable: true,
  ),
);

WorldMapPainter mapPainter(WidgetTester tester) =>
    tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w) => w.painter).whereType<WorldMapPainter>().single;

Future<void> showMap(
  WidgetTester tester, {
  GlobalKey? buttonKey,
  double left = 100,
  double top = 200,
  double width = 400,
  bool tickerEnabled = true,
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 600,
            child: Stack(
              children: [
                Positioned.fill(
                  child: WorldMapBackground(state: state(VpnSessionPhase.disconnected), buttonKey: buttonKey),
                ),
                Positioned(
                  left: left,
                  top: top,
                  child: SizedBox(key: buttonKey, width: 230, height: 230),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);
