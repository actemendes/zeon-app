import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
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

    test('background-prepared inactive VPN remains OFF and actionable', () {
      final state = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.disconnected, requestedAction: 'prepare'));

      expect(state.visualState, MainVpnButtonVisualState.off);
      expect(state.action, MainVpnButtonAction.start);
      expect(state.isStarting, isFalse);
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

    test('replacement and pending-connect snapshots keep START loading instead of flickering off', () {
      final transientSnapshots = [
        snapshot(VpnSessionPhase.disconnected, requestedAction: 'stop', stopSource: VpnStopSource.replacement),
        snapshot(VpnSessionPhase.disconnected, requestedAction: 'connect'),
      ];

      for (final transient in transientSnapshots) {
        final state = MainVpnButtonState.fromSnapshot(transient);

        expect(state.isStarting, isTrue);
        expect(state.visualState, MainVpnButtonVisualState.loading);
        expect(state.action, MainVpnButtonAction.stop);
        expect(state.present(translations).label, 'Подключение...');
        expect(state.visualState, isNot(MainVpnButtonVisualState.off));
      }
    });

    test('optimistic STOP overrides a stale native CONNECTED snapshot', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.connected, requestedAction: 'connect', provesConnected: true),
        localStatus: const Disconnecting(),
      );

      expect(state.phase, VpnSessionPhase.stopping);
      expect(state.isStopping, isTrue);
      expect(state.visualState, MainVpnButtonVisualState.loading);
      expect(state.action, MainVpnButtonAction.none);
      expect(state.present(translations).semanticsLabel, 'Отключение выполняется');
    });

    test('terminal external STOP and native failure override optimistic START', () {
      final externalStop = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.disconnected, requestedAction: 'stop', stopSource: VpnStopSource.system),
        localStatus: const Connecting(),
      );
      final nativeFailure = MainVpnButtonState.fromSources(
        snapshot: snapshot(
          VpnSessionPhase.failed,
          requestedAction: 'connect',
          recoverable: false,
          failureCode: 'native_start_failed',
        ),
        localStatus: const Connecting(),
      );

      expect(externalStop.phase, VpnSessionPhase.disconnected);
      expect(externalStop.visualState, MainVpnButtonVisualState.off);
      expect(externalStop.action, MainVpnButtonAction.start);
      expect(externalStop.isStarting, isFalse);

      expect(nativeFailure.phase, VpnSessionPhase.failed);
      expect(nativeFailure.visualState, MainVpnButtonVisualState.failed);
      expect(nativeFailure.action, MainVpnButtonAction.none);
      expect(nativeFailure.isStarting, isFalse);
    });

    test('newer local START masks an older external stopped snapshot', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.disconnected, requestedAction: 'stop', stopSource: VpnStopSource.system),
        localStatus: const Connecting(),
        localDesiredRunning: true,
      );

      expect(state.visualState, MainVpnButtonVisualState.loading);
      expect(state.isStarting, isTrue);
      expect(state.action, MainVpnButtonAction.stop);
    });

    test('Stop watchdog error over native STOPPING remains an enabled STOP retry', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.stopping, requestedAction: 'stop', stopSource: VpnStopSource.flutter),
        localStatus: const Disconnecting(),
        localDesiredRunning: false,
        localHasError: true,
      );

      expect(state.phase, VpnSessionPhase.stopping);
      expect(state.visualState, MainVpnButtonVisualState.failed);
      expect(state.action, MainVpnButtonAction.stop);
      expect(state.enabled, isTrue);
    });

    test('Stop watchdog error over a Connect-owned transition still retries STOP', () {
      final snapshots = [
        snapshot(VpnSessionPhase.startRequested, requestedAction: 'connect'),
        snapshot(VpnSessionPhase.verifying, requestedAction: 'connect'),
        snapshot(VpnSessionPhase.disconnected, requestedAction: 'connect'),
      ];

      for (final native in snapshots) {
        final state = MainVpnButtonState.fromSources(
          snapshot: native,
          localStatus: const Disconnecting(),
          localDesiredRunning: false,
          localHasError: true,
        );

        expect(state.action, MainVpnButtonAction.stop, reason: native.phase.name);
        expect(state.enabled, isTrue, reason: native.phase.name);
        expect(state.isStopping, isTrue, reason: native.phase.name);
        expect(state.present(translations).semanticsLabel, 'Отключение выполняется', reason: native.phase.name);
      }
    });

    test('local Stop retry owns replacement presentation and action coherently', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.stopping, requestedAction: 'stop', stopSource: VpnStopSource.replacement),
        localStatus: const Disconnecting(),
        localDesiredRunning: false,
        localHasError: true,
      );

      expect(state.stopSource, VpnStopSource.flutter);
      expect(state.action, MainVpnButtonAction.stop);
      expect(state.isStopping, isTrue);
      expect(state.present(translations).semanticsLabel, 'Отключение выполняется');
    });

    test('recoverable native Stop failure retries STOP instead of starting a replacement', () {
      final stopFailure = MainVpnButtonState.fromSources(
        snapshot: snapshot(
          VpnSessionPhase.failed,
          requestedAction: 'stop',
          stopSource: VpnStopSource.flutter,
          failureCode: 'teardown_timeout',
        ),
        localStatus: const Disconnected(),
        localDesiredRunning: false,
      );
      final startFailure = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.failed, requestedAction: 'connect', failureCode: 'start_timeout'),
        localStatus: const Disconnected(),
        // A failed Connect clears the notifier's desired-running flag. That
        // must remain a START retry unless native explicitly owns Stop.
        localDesiredRunning: false,
      );

      expect(stopFailure.action, MainVpnButtonAction.stop);
      expect(stopFailure.enabled, isTrue);
      expect(stopFailure.isStopping, isTrue);
      expect(startFailure.action, MainVpnButtonAction.start);
    });

    test('timed-out local Stop overrides a connect-owned native FAILED snapshot', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.failed, requestedAction: 'connect', failureCode: 'owner_did_not_settle'),
        localStatus: const Disconnected(),
        localDesiredRunning: false,
        localStopRetry: true,
        localHasError: true,
      );

      expect(state.action, MainVpnButtonAction.stop);
      expect(state.enabled, isTrue);
      expect(state.isStopping, isTrue);
    });

    test('failed Start preparation remains an enabled START retry', () {
      final state = MainVpnButtonState.fromSources(
        snapshot: snapshot(VpnSessionPhase.startRequested, requestedAction: 'connect'),
        localStatus: null,
        // A failed prepare clears the local Start intent while the native
        // snapshot can still describe the accepted generation as pending.
        localDesiredRunning: false,
        localHasError: true,
      );

      expect(state.phase, VpnSessionPhase.failed);
      expect(state.action, MainVpnButtonAction.start);
      expect(state.enabled, isTrue);
      expect(state.isStopping, isFalse);
      expect(state.present(translations).semanticsLabel, 'Нажмите для подключения');
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

    testWidgets('rotation ticker settles after leaving loading for CONNECTED and OFF', (tester) async {
      final loading = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.startingCore));
      final connected = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.connected));
      final off = MainVpnButtonState.fromSnapshot(snapshot(VpnSessionPhase.disconnected));

      await pumpButton(tester, loading, onTap: () {});
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await pumpButton(tester, connected, onTap: () {});
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await pumpButton(tester, loading, onTap: () {});
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await pumpButton(tester, off, onTap: () {});
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
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

VpnSessionSnapshot snapshot(
  VpnSessionPhase phase, {
  int sequence = 1,
  int version = 1,
  bool recoverable = true,
  String? requestedAction,
  VpnStopSource stopSource = VpnStopSource.none,
  bool provesConnected = false,
  String failureCode = '',
}) {
  return VpnSessionSnapshot(
    generation: 42,
    runtimeEpoch: 'runtime-1',
    sequenceNumber: sequence,
    snapshotVersion: version,
    phase: phase,
    requestedAction:
        requestedAction ??
        switch (phase) {
          VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.disconnected => 'stop',
          _ => 'connect',
        },
    stopSource: stopSource,
    coreReady: provesConnected,
    coreStarted: provesConnected,
    commandEndpointReady: provesConnected,
    tunnelReady: provesConnected,
    protectSucceeded: provesConnected,
    platformVpnValidated: provesConnected,
    selectedOutboundId: provesConnected ? 'proxy-1' : '',
    failureCode: failureCode,
    recoverable: recoverable,
  );
}
