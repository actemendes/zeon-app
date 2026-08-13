import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  final translations = TranslationsRu();

  group('MainVpnButtonState', () {
    test('CONNECTED derives STOP, connected visuals, and disconnect semantics', () {
      final state = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.connected));
      final presentation = state.present(translations);

      expect(state.action, MainVpnButtonAction.stop);
      expect(state.visualState, MainVpnButtonVisualState.connected);
      expect(state.enabled, isTrue);
      expect(presentation.label, 'Подключено');
      expect(presentation.semanticsLabel, 'Нажмите для отключения');
    });

    test('DISCONNECTED derives START and connect semantics', () {
      final state = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.disconnected));
      final presentation = state.present(translations);

      expect(state.action, MainVpnButtonAction.start);
      expect(presentation.semanticsLabel, 'Нажмите для подключения');
    });

    test('STARTING and STOPPING have progress semantics and coherent actions', () {
      final starting = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.verifying));
      final stopping = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.stopping));

      expect(starting.action, MainVpnButtonAction.stop);
      expect(starting.present(translations).semanticsLabel, 'Подключение выполняется');
      expect(stopping.action, MainVpnButtonAction.none);
      expect(stopping.enabled, isFalse);
      expect(stopping.present(translations).semanticsLabel, 'Отключение выполняется');
    });

    test('stale disconnected snapshot after CONNECTED is ignored by the authoritative gate', () {
      final gate = VpnSessionSnapshotGate();
      final connected = snapshot(VpnSessionPhase.connected, sequence: 20, version: 20);
      final staleDisconnected = snapshot(VpnSessionPhase.disconnected, sequence: 19, version: 19);

      expect(gate.accept(connected), isTrue);
      expect(gate.classify(staleDisconnected), VpnSnapshotDisposition.stale);
      expect(gate.accept(staleDisconnected), isFalse);
      expect(MainVpnButtonState.fromSnapshot(gate.current!).action, MainVpnButtonAction.stop);
    });

    test('sequence gap followed by authoritative resync produces STOP', () {
      final gate = VpnSessionSnapshotGate()..accept(snapshot(VpnSessionPhase.startingCore, sequence: 2, version: 2));
      final connectedAfterGap = snapshot(VpnSessionPhase.connected, sequence: 5, version: 5);

      expect(gate.classify(connectedAfterGap), VpnSnapshotDisposition.gap);
      expect(gate.acceptResynced(connectedAfterGap), isTrue);
      expect(MainVpnButtonState.fromSnapshot(gate.current!).action, MainVpnButtonAction.stop);
    });

    test('completion of an old start Future cannot overwrite a CONNECTED projection', () async {
      var state = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.startingCore));
      final oldStart = Completer<void>();
      state = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.connected, sequence: 2, version: 2));

      oldStart.complete();
      await oldStart.future;

      expect(state.action, MainVpnButtonAction.stop);
      expect(state.present(translations).semanticsLabel, 'Нажмите для отключения');
    });

    test('100 transitions keep text, semantics, visuals, and action coherent', () {
      const phases = VpnSessionPhase.values;
      for (var index = 0; index < 100; index++) {
        final phase = phases[index % phases.length];
        final state = MainVpnButtonState.fromSnapshot(
          snapshot(phase, sequence: index + 1, version: index + 1, recoverable: index.isEven),
        );
        final presentation = state.present(translations);

        if (phase == VpnSessionPhase.connected) {
          expect(state.action, MainVpnButtonAction.stop);
          expect(state.visualState, MainVpnButtonVisualState.connected);
          expect(presentation.label, 'Подключено');
          expect(presentation.semanticsLabel, 'Нажмите для отключения');
        } else if (state.isStopping) {
          expect(state.action, MainVpnButtonAction.none);
          expect(state.enabled, isFalse);
          expect(presentation.semanticsLabel, 'Отключение выполняется');
        } else if (state.isStarting) {
          expect(state.action, MainVpnButtonAction.stop);
          expect(state.visualState, MainVpnButtonVisualState.loading);
          expect(presentation.semanticsLabel, 'Подключение выполняется');
        } else if (phase == VpnSessionPhase.disconnected || phase == VpnSessionPhase.idle) {
          expect(state.action, MainVpnButtonAction.start);
          expect(presentation.semanticsLabel, 'Нажмите для подключения');
        }
      }
    });
  });

  group('MainVpnButtonView semantics and callback', () {
    testWidgets('CONNECTED semantics and tap invoke the supplied STOP callback exactly once', (tester) async {
      final semantics = tester.ensureSemantics();
      var stopCalls = 0;
      final connected = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.connected));

      await pumpButton(tester, connected, onTap: () => stopCalls++);
      expect(find.bySemanticsLabel('Нажмите для отключения'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home_connection_button')));
      await tester.pump();

      expect(stopCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    });

    testWidgets('STOPPING exposes progress semantics and blocks repeated taps', (tester) async {
      final semantics = tester.ensureSemantics();
      var calls = 0;
      final stopping = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.stopping));

      await pumpButton(tester, stopping, onTap: () => calls++);
      expect(find.bySemanticsLabel('Отключение выполняется'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home_connection_button')), warnIfMissed: false);
      await tester.pump();

      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    });

    testWidgets('theme rebuild preserves CONNECTED semantics and action', (tester) async {
      final semantics = tester.ensureSemantics();
      var calls = 0;
      final connected = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.connected));

      await pumpButton(tester, connected, onTap: () => calls++);
      await pumpButton(tester, connected, onTap: () => calls++, brightness: Brightness.dark);

      expect(find.bySemanticsLabel('Нажмите для отключения'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home_connection_button')));
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    });
  });
}

Future<void> pumpButton(
  WidgetTester tester,
  MainVpnButtonState state, {
  required VoidCallback onTap,
  Brightness brightness = Brightness.light,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: Center(
          child: MainVpnButtonView(
            presentation: state.present(TranslationsRu()),
            onTap: onTap,
            image: Assets.images.disconnectNorouz,
            useImage: false,
            secureLabel: '',
          ),
        ),
      ),
    ),
  );
}

VpnSessionSnapshot snapshot(VpnSessionPhase phase, {int sequence = 1, int version = 1, bool recoverable = true}) {
  return VpnSessionSnapshot(
    generation: 42,
    runtimeEpoch: 'runtime-1',
    sequenceNumber: sequence,
    snapshotVersion: version,
    phase: phase,
    requestedAction: switch (phase) {
      VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.disconnected => 'stop',
      _ => 'connect',
    },
    recoverable: recoverable,
  );
}
