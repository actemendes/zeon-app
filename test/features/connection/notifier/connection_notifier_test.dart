import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/haptic/haptic_service.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/data/connection_data_providers.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/zeoncore/init_signal.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  group('shouldReconnectForActiveProfileChange', () {
    test('reconnects when a release-speed transition has no previous provider value', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: true,
          connectedProfileId: 'anonymous',
          nextProfileId: 'device-profile',
        ),
        isTrue,
      );
    });

    test('does not reconnect for the profile already running in the core', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: true,
          connectedProfileId: 'device-profile',
          nextProfileId: 'device-profile',
        ),
        isFalse,
      );
    });

    test('does not reconnect while disconnected', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: false,
          connectedProfileId: 'anonymous',
          nextProfileId: 'device-profile',
        ),
        isFalse,
      );
    });
  });

  group('transient stop filtering during START', () {
    test('preparation, replacement, and pending-connect DISCONNECTED callbacks are ignored', () {
      final transientSnapshots = [
        _snapshot(VpnSessionPhase.disconnected, requestedAction: 'prepare'),
        _snapshot(VpnSessionPhase.disconnected, requestedAction: 'stop', stopSource: VpnStopSource.replacement),
        _snapshot(VpnSessionPhase.disconnected, requestedAction: 'connect'),
      ];

      for (final nativeSnapshot in transientSnapshots) {
        expect(
          shouldIgnoreTransientStopDuringStart(
            desiredRunning: true,
            status: const Disconnected(),
            nativeSnapshot: nativeSnapshot,
          ),
          isTrue,
        );
      }
    });

    test('external stop and failure evidence remain terminal during optimistic START', () {
      final externalStop = _snapshot(
        VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.system,
      );
      final failedStart = _snapshot(
        VpnSessionPhase.failed,
        requestedAction: 'connect',
        failureCode: 'native_start_failed',
      );

      expect(
        shouldIgnoreTransientStopDuringStart(
          desiredRunning: true,
          status: const Disconnected(),
          nativeSnapshot: externalStop,
        ),
        isFalse,
      );
      expect(
        shouldIgnoreTransientStopDuringStart(
          desiredRunning: true,
          status: const Disconnected(ConnectionFailure.unexpected('platform failure')),
          nativeSnapshot: _snapshot(VpnSessionPhase.disconnected, requestedAction: 'connect'),
        ),
        isFalse,
      );
      expect(
        shouldIgnoreTransientStopDuringStart(
          desiredRunning: true,
          status: const Disconnected(),
          nativeSnapshot: failedStart,
        ),
        isFalse,
      );
    });
  });

  test('mobile main-button resync failure never authorizes an action from stale cache', () {
    expect(shouldFailClosedMainButtonSnapshotResync(isMobile: true), isTrue);
    expect(shouldFailClosedMainButtonSnapshotResync(isMobile: false), isFalse);
  });

  testWidgets('core restart signal does not rebuild the connection owner during Start', (tester) async {
    final repository = _FakeConnectionRepository()
      ..initialStatus = const Disconnected()
      ..authoritativeStatus = const Connected();
    final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
    final setup = await _createContainer(repository, startedByUser: false, snapshotSource: snapshots);
    addTearDown(setup.dispose);
    repository.onConnectSuccess = () {
      // ZeonCoreService publishes Started and then invalidates proxy/stat
      // consumers. ConnectionNotifier owns a stable BehaviorSubject stream
      // and must not be rebuilt in the narrow interval between those events.
      repository.emit(const Connected());
      setup.container.read(coreRestartSignalProvider.notifier).restart();
    };

    await setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
    await _pumpUntil(tester, () => setup.status is Connected, diagnostics: () => setup.observedStates.join(' -> '));

    expect(repository.watchCalls, 1);
    expect(setup.container.read(connectionNotifierProvider).hasError, isFalse);
    expect(repository.resyncSources, contains('connect_completion'));
    await tester.pump(const Duration(seconds: 12));
  });

  group('disconnect reconciliation', () {
    testWidgets('authoritative stopped snapshot releases a hung Disconnecting UI', (tester) async {
      final repository = _FakeConnectionRepository();
      repository.disconnectBarrier = Completer<void>();
      repository.authoritativeStatus = const Disconnected();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final disconnect = setup.notifier.abortConnection();
      await tester.pump();
      expect(setup.status, const Disconnecting());

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(setup.status, const Disconnected());
      expect(repository.resyncSources, contains('disconnecting_timeout_1'));

      repository.disconnectBarrier!.complete();
      await disconnect;
    });

    testWidgets('successful Stop without a snapshot stays non-terminal until reconciliation', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = null;
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      await setup.notifier.abortConnection();
      expect(repository.disconnectCalls, 1);
      expect(setup.status, const Disconnecting(), reason: 'null is not proof that Android released the TUN');

      repository.authoritativeStatus = const Disconnected();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(setup.status, const Disconnected());
    });

    testWidgets('hung haptic side effect does not hold native Stop completion', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Disconnected();
      final hapticBarrier = Completer<void>();
      final setup = await _createContainer(repository, hapticBarrier: hapticBarrier);
      addTearDown(setup.dispose);

      var completed = false;
      unawaited(setup.notifier.toggleConnection().then((_) => completed = true));
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);
      await _pumpUntil(tester, () => completed);

      expect(hapticBarrier.isCompleted, isFalse);
      expect(setup.status, const Disconnected());
      hapticBarrier.complete();
      // Let the already-scheduled reconciliation timer observe the terminal
      // state before the widget-test binding verifies that no timers leaked.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('late stop completion cannot overwrite a newer connect', (tester) async {
      final repository = _FakeConnectionRepository();
      repository.disconnectBarrier = Completer<void>();
      repository.authoritativeStatus = const Disconnected();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final disconnect = setup.notifier.abortConnection();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(setup.status, const Disconnected());

      repository.authoritativeStatus = const Connected();
      final connect = setup.notifier.toggleConnection();
      await tester.pump();
      repository.disconnectBarrier!.complete();
      await tester.pump();
      await Future.wait([disconnect, connect]);

      expect(repository.connectCalls, 1);
      await _pumpUntil(
        tester,
        () => setup.status is Connected,
        diagnostics: () =>
            '${setup.observedStates.join(' -> ')}; resync=${repository.resyncSources}; '
            'connect=${repository.connectCalls}; reconnect=${repository.reconnectCalls}; '
            'intent=${setup.notifier.connectionIntentEpochForTesting}; '
            'desired=${setup.notifier.desiredRunningForTesting}',
      );
      expect(setup.status, const Connected());
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('terminal Stop releases its token before old cleanup so a later session can stop', (tester) async {
      final repository = _FakeConnectionRepository();
      final firstStop = Completer<void>();
      final secondStop = Completer<void>();
      repository.disconnectBarriers.addAll([firstStop, secondStop]);
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected, provesConnected: true));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      final oldStop = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);

      snapshots.currentSnapshot = _snapshot(
        VpnSessionPhase.disconnected,
        sequence: 2,
        version: 2,
        requestedAction: 'stop',
      );
      repository.emit(const Disconnected());
      await _pumpUntil(tester, () => setup.status is Disconnected);

      await setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      expect(repository.connectCalls, 1);

      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 3, version: 3, provesConnected: true);
      repository.emit(const Connected());
      await _pumpUntil(tester, () => setup.status is Connected);

      final newStop = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 2);
      expect(firstStop.isCompleted, isFalse);

      firstStop.complete();
      await oldStop;
      // A stale finally from Stop #1 must not release Stop #2's token.
      expect(setup.notifier.mainButtonStopInFlightForTesting, isTrue);

      secondStop.complete();
      await newStop;
      expect(setup.notifier.mainButtonStopInFlightForTesting, isFalse);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('external Start supersedes a hung Stop token and the new session remains stoppable', (tester) async {
      final repository = _FakeConnectionRepository();
      final firstStop = Completer<void>();
      final secondStop = Completer<void>();
      repository.disconnectBarriers.addAll([firstStop, secondStop]);
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected, provesConnected: true));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      final oldStop = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);

      // Settings/Control Center starts the tunnel while the old Dart cleanup
      // is still pending and no intermediate Disconnected event was observed.
      final persistExternalStart = setup.container.read(Preferences.startedByUser.notifier).updateOptimistically(true);
      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 2, version: 2, provesConnected: true);
      repository.emit(const Connected());
      await _pumpUntil(tester, () => setup.status is Connected);
      await persistExternalStart;
      expect(setup.notifier.mainButtonStopInFlightForTesting, isFalse);

      final newStop = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 2);
      expect(firstStop.isCompleted, isFalse);

      firstStop.complete();
      await oldStop;
      expect(setup.notifier.mainButtonStopInFlightForTesting, isTrue);

      secondStop.complete();
      await newStop;
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('manual stop supersedes a mode restart and remains terminal', (tester) async {
      final repository = _FakeConnectionRepository();
      repository.authoritativeStatus = const Disconnected();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final restart = setup.notifier.restartForConfigChange(setup.profile);
      final disconnect = setup.notifier.abortConnection();
      await tester.pump();
      await Future.wait([restart, disconnect]);

      expect(repository.reconnectCalls, 1);
      expect(repository.disconnectCalls, 1);
      expect(setup.status, const Disconnected());
      expect(setup.preferences.getBool('started_by_user'), isFalse);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('stop preempts an in-flight reconnect and remains the final intent', (tester) async {
      final repository = _FakeConnectionRepository();
      repository.reconnectBarrier = Completer<void>();
      repository.reconnectStatus = const Disconnecting();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final restart = setup.notifier.restartForConfigChange(setup.profile);
      await _pumpUntil(tester, () => repository.reconnectCalls == 1);
      await _pumpUntil(tester, () => setup.status is Disconnecting);

      repository.authoritativeStatus = const Disconnected();
      final disconnect = setup.notifier.abortConnection();
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);
      expect(repository.disconnectCalls, 1);
      expect(repository.reconnectBarrier!.isCompleted, isFalse);

      // Stop completes before the older reconnect barrier is released.
      await disconnect;
      expect(setup.status, const Disconnected());

      repository.reconnectBarrier!.complete();
      await tester.pump();
      await restart;

      expect(repository.disconnectCalls, 1);
      expect(setup.status, const Disconnected());
      expect(setup.preferences.getBool('started_by_user'), isFalse);
      repository.emit(const Connected());
      await tester.pump();
      expect(setup.status, const Disconnected(), reason: 'a stale restart callback must not revive the UI');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('watchdog releases the START latch so retry starts while the first Future is pending', (tester) async {
      final firstBarrier = Completer<void>();
      final retryBarrier = Completer<void>();
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarriers.addAll([firstBarrier, retryBarrier]);
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, startedByUser: false, snapshotSource: snapshots);
      addTearDown(setup.dispose);
      final displayed = MainVpnButtonState.fromSnapshot(snapshots.current!);
      var firstCompleted = false;

      final first = setup.notifier
          .handleMainVpnButtonTap(displayed, confirmStart: () async => true)
          .whenComplete(() => firstCompleted = true);
      await _pumpUntil(tester, () => repository.connectCalls == 1);
      expect(setup.status, const Connecting());

      await tester.pump(const Duration(seconds: 12));
      await tester.pump();
      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);
      expect(firstCompleted, isFalse, reason: 'the first repository Future is deliberately still unresolved');

      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.disconnected, sequence: 2, version: 2);
      final retryDisplayed = MainVpnButtonState.fromSources(
        snapshot: snapshots.current,
        localStatus: setup.status,
        localHasError: setup.container.read(connectionNotifierProvider).hasError,
      );
      final retry = setup.notifier.handleMainVpnButtonTap(retryDisplayed, confirmStart: () async => true);
      await _pumpUntil(
        tester,
        () => repository.connectCalls == 2,
        diagnostics: () =>
            '${setup.observedStates.join(' -> ')}; calls=${repository.connectCalls}; '
            'resync=${repository.resyncSources}; snapshotResync=${snapshots.resyncSources}',
      );

      expect(firstCompleted, isFalse);
      expect(firstBarrier.isCompleted, isFalse);

      repository.authoritativeStatus = const Connected();
      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 3, version: 3, provesConnected: true);
      repository.emit(const Connected());
      retryBarrier.complete();
      await retry;

      expect(repository.connectCalls, 2);
      expect(repository.resyncSources.where((source) => source == 'connect_completion'), hasLength(1));
      await _pumpUntil(tester, () => setup.status is Connected, diagnostics: () => setup.observedStates.join(' -> '));
      expect(setup.status, const Connected());

      firstBarrier.complete();
      await first;
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('persistent connecting platform state ends with a retryable error', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarrier = Completer<void>();
      final setup = await _createContainer(repository, startedByUser: false);
      addTearDown(setup.dispose);

      final connect = setup.notifier.mayConnect();
      await _pumpUntil(tester, () => repository.connectCalls == 1);
      repository.emit(const Connecting());
      await tester.pump();
      expect(setup.status, const Connecting());

      await tester.pump(const Duration(seconds: 12));
      await tester.pump();
      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);

      repository.connectBarrier!.complete();
      await connect;
      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);
    });

    testWidgets('temporary null profile does not tear down a running intent', (tester) async {
      final repository = _FakeConnectionRepository();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final profileReconcile = setup.notifier.reconnect(null);
      final configReconcile = setup.notifier.restartForConfigChange(null);
      await tester.pump(const Duration(milliseconds: 500));
      await Future.wait([profileReconcile, configReconcile]);

      expect(repository.reconnectCalls, 1);
      expect(repository.disconnectCalls, 0);
      expect(setup.preferences.getBool('started_by_user'), isTrue);
      expect(setup.status, const Connected());
    });

    testWidgets('persistent null profile stops an orphaned running config', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Disconnected();
      final setup = await _createContainer(repository, activeProfileMissing: true);
      addTearDown(setup.dispose);

      final reconcile = setup.notifier.reconnect(null);
      for (var attempt = 0; attempt < 6; attempt++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await reconcile;

      expect(repository.reconnectCalls, 0);
      expect(repository.disconnectCalls, 1);
      expect(setup.preferences.getBool('started_by_user'), isFalse);
      expect(setup.status, const Disconnected());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('persistent non-terminal platform state ends with a retryable error', (tester) async {
      final repository = _FakeConnectionRepository();
      repository.disconnectBarrier = Completer<void>();
      repository.authoritativeStatus = const Connected();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      final disconnect = setup.notifier.abortConnection();
      await tester.pump();
      expect(setup.status, const Disconnecting());

      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }

      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);
      expect(repository.resyncSources, [
        'disconnecting_timeout_1',
        'disconnecting_timeout_2',
        'disconnecting_timeout_3',
      ]);

      repository.emit(const Disconnecting());
      await tester.pump();
      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);

      repository.disconnectBarrier!.complete();
      await disconnect;
    });

    testWidgets('Stop watchdog releases the button token so a hung transport can be retried', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Connected();
      final firstStop = Completer<void>();
      final secondStop = Completer<void>();
      repository.disconnectBarriers.addAll([firstStop, secondStop]);
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected, provesConnected: true));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      final first = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);
      snapshots.currentSnapshot = _snapshot(
        VpnSessionPhase.stopping,
        sequence: 2,
        version: 2,
        requestedAction: 'stop',
        stopSource: VpnStopSource.flutter,
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }

      expect(setup.container.read(connectionNotifierProvider).hasError, isTrue);
      expect(setup.notifier.mainButtonStopInFlightForTesting, isFalse);

      final retryDisplayed = MainVpnButtonState.fromSources(
        snapshot: snapshots.current,
        localStatus: setup.status,
        localDesiredRunning: setup.notifier.desiredRunningForTesting,
        localHasError: setup.container.read(connectionNotifierProvider).hasError,
      );
      expect(retryDisplayed.action, MainVpnButtonAction.stop);
      final retry = setup.notifier.handleMainVpnButtonTap(retryDisplayed);
      await _pumpUntil(
        tester,
        () => repository.disconnectCalls == 2,
        step: const Duration(milliseconds: 1),
        diagnostics: () =>
            'calls=${repository.disconnectCalls} state=${setup.container.read(connectionNotifierProvider)} '
            'token=${setup.notifier.mainButtonStopInFlightForTesting} '
            'intent=${setup.notifier.connectionIntentEpochForTesting}',
      );

      expect(repository.connectCalls, 0);
      expect(repository.disconnectForceValues, [false, true]);

      firstStop.complete();
      secondStop.complete();
      await Future.wait([first, retry]);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('Stop watchdog retries STOP while native still owns a pending Connect', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Connected();
      final firstStop = Completer<void>();
      final secondStop = Completer<void>();
      repository.disconnectBarriers.addAll([firstStop, secondStop]);
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected, provesConnected: true));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      final first = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);
      snapshots.currentSnapshot = _snapshot(
        VpnSessionPhase.verifying,
        sequence: 2,
        version: 2,
        requestedAction: 'connect',
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }

      final retryDisplayed = MainVpnButtonState.fromSources(
        snapshot: snapshots.current,
        localStatus: setup.status,
        localDesiredRunning: setup.notifier.desiredRunningForTesting,
        localHasError: setup.container.read(connectionNotifierProvider).hasError,
      );
      expect(retryDisplayed.action, MainVpnButtonAction.stop);

      final retry = setup.notifier.handleMainVpnButtonTap(retryDisplayed);
      await _pumpUntil(tester, () => repository.disconnectCalls == 2, step: const Duration(milliseconds: 1));

      expect(repository.connectCalls, 0);
      expect(repository.disconnectForceValues, [false, true]);
      firstStop.complete();
      secondStop.complete();
      await Future.wait([first, retry]);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('external notification stop rejects a stale connected callback', (tester) async {
      final repository = _FakeConnectionRepository();
      final setup = await _createContainer(repository);
      addTearDown(setup.dispose);

      await setup.container.read(Preferences.startedByUser.notifier).update(false);
      repository.emit(const Disconnected());
      await _pumpUntil(
        tester,
        () => setup.status is Disconnected,
        diagnostics: () => setup.observedStates.join(' -> '),
        step: const Duration(milliseconds: 1),
      );
      expect(setup.status, const Disconnected());

      repository.emit(const Connected());
      for (var attempt = 0; attempt < 5; attempt++) {
        await tester.pump();
      }
      expect(setup.status, const Disconnected());

      await setup.container.read(Preferences.startedByUser.notifier).update(true);
      repository.emit(const Connected());
      await _pumpUntil(tester, () => setup.status is Connected, step: const Duration(milliseconds: 1));
      expect(setup.status, const Connected());
    });
  });

  group('authoritative main VPN button', () {
    testWidgets('CONNECTED snapshot dispatches STOP once and never START', (tester) async {
      final repository = _FakeConnectionRepository()..disconnectBarrier = Completer<void>();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);
      final displayed = MainVpnButtonState.fromSnapshot(snapshots.current!);

      final first = setup.notifier.handleMainVpnButtonTap(displayed);
      await _pumpUntil(tester, () => repository.disconnectCalls == 1);
      final second = setup.notifier.handleMainVpnButtonTap(displayed);
      await tester.pump();

      expect(repository.disconnectCalls, 1);
      expect(repository.connectCalls, 0);
      repository.authoritativeStatus = const Disconnected();
      repository.disconnectBarrier!.complete();
      await Future.wait([first, second]);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('stale displayed START resyncs CONNECTED and dispatches STOP', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Disconnected();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.connected));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);
      final staleDisplayed = MainVpnButtonState.fromSnapshot(_snapshot(VpnSessionPhase.disconnected));

      await setup.notifier.handleMainVpnButtonTap(staleDisplayed);

      expect(snapshots.resyncSources, contains('main_button_tap'));
      expect(repository.disconnectCalls, 1);
      expect(repository.connectCalls, 0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('DISCONNECTED snapshot dispatches START exactly once', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connected();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots, startedByUser: false);
      addTearDown(setup.dispose);
      final displayed = MainVpnButtonState.fromSnapshot(snapshots.current!);

      await setup.notifier.handleMainVpnButtonTap(displayed, confirmStart: () async => true);

      expect(repository.connectCalls, 1);
      expect(repository.disconnectCalls, 0);
      expect(snapshots.resyncSources, ['main_button_tap', 'main_button_before_start']);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('one-tap START uses one native fence and immediately publishes Connecting', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarrier = Completer<void>();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots, startedByUser: false);
      addTearDown(setup.dispose);

      final connect = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.connectCalls == 1);

      expect(snapshots.resyncSources, ['main_button_tap']);
      expect(setup.status, const Connecting());

      repository.connectBarrier!.complete();
      await connect;
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('stale confirmation cannot start after a newer button attempt owns the latch', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarrier = Completer<void>();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots, startedByUser: false);
      addTearDown(setup.dispose);
      final confirmationEntered = Completer<void>();
      final releaseConfirmation = Completer<void>();
      final displayed = MainVpnButtonState.fromSnapshot(snapshots.current!);

      final staleAttempt = setup.notifier.handleMainVpnButtonTap(
        displayed,
        confirmStart: () async {
          confirmationEntered.complete();
          await releaseConfirmation.future;
          return true;
        },
      );
      await confirmationEntered.future;

      // A terminal platform event releases attempt #1 while its dialog is
      // open. A newer tap may now acquire attempt #2.
      repository.emit(const Disconnected());
      await tester.pump();
      final currentAttempt = setup.notifier.handleMainVpnButtonTap(displayed);
      await _pumpUntil(tester, () => repository.connectCalls == 1);

      releaseConfirmation.complete();
      await staleAttempt;
      expect(repository.connectCalls, 1, reason: 'the stale dialog continuation must not issue a second START');

      repository.authoritativeStatus = const Connected();
      repository.connectBarrier!.complete();
      await currentAttempt;
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('replacement DISCONNECTED callback never overwrites an accepted START', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarrier = Completer<void>();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots, startedByUser: false);
      addTearDown(setup.dispose);
      final displayed = MainVpnButtonState.fromSnapshot(snapshots.current!);
      final transitionStart = setup.observedStates.length;

      final connect = setup.notifier.handleMainVpnButtonTap(displayed, confirmStart: () async => true);
      await _pumpUntil(tester, () => repository.connectCalls == 1);
      expect(setup.status, const Connecting());

      snapshots.currentSnapshot = _snapshot(
        VpnSessionPhase.disconnected,
        sequence: 2,
        version: 2,
        requestedAction: 'stop',
        stopSource: VpnStopSource.replacement,
      );
      repository.emit(const Disconnected());
      await tester.pump();

      expect(setup.status, const Connecting());
      expect(
        setup.observedStates.skip(transitionStart).map((value) => value.valueOrNull).whereType<Disconnected>(),
        isEmpty,
      );

      repository.authoritativeStatus = const Connected();
      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 3, version: 3, provesConnected: true);
      repository.emit(const Connected());
      repository.connectBarrier!.complete();
      await connect;
      await _pumpUntil(tester, () => setup.status is Connected);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('prepare DISCONNECTED callback never makes an accepted START flash OFF', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connecting()
        ..connectBarrier = Completer<void>();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots, startedByUser: false);
      addTearDown(setup.dispose);
      final transitionStart = setup.observedStates.length;

      final connect = setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));
      await _pumpUntil(tester, () => repository.connectCalls == 1);
      expect(setup.status, const Connecting());

      snapshots.currentSnapshot = _snapshot(
        VpnSessionPhase.disconnected,
        sequence: 2,
        version: 2,
        requestedAction: 'prepare',
      );
      repository.emit(const Disconnected());
      await tester.pump();

      expect(setup.status, const Connecting());
      expect(
        setup.observedStates.skip(transitionStart).map((value) => value.valueOrNull).whereType<Disconnected>(),
        isEmpty,
      );

      repository.authoritativeStatus = const Connected();
      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 3, version: 3, provesConnected: true);
      repository.emit(const Connected());
      repository.connectBarrier!.complete();
      await connect;
      await _pumpUntil(tester, () => setup.status is Connected);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('STOPPING authoritative snapshot blocks every command', (tester) async {
      final repository = _FakeConnectionRepository();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.stopping));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      await setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));

      expect(repository.connectCalls, 0);
      expect(repository.disconnectCalls, 0);
    });

    testWidgets('recoverable native Stop failure dispatches STOP and never START', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Disconnected();
      final snapshots = _FakeSnapshotSource(
        _snapshot(
          VpnSessionPhase.failed,
          requestedAction: 'stop',
          stopSource: VpnStopSource.flutter,
          failureCode: 'teardown_timeout',
        ),
      );
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);
      final displayed = MainVpnButtonState.fromSources(
        snapshot: snapshots.current,
        localStatus: setup.status,
        localDesiredRunning: false,
      );

      expect(displayed.action, MainVpnButtonAction.stop);
      await setup.notifier.handleMainVpnButtonTap(displayed);

      expect(repository.disconnectCalls, 1);
      expect(repository.connectCalls, 0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('notification/resume resync to CONNECTED makes a stale button stop', (tester) async {
      final repository = _FakeConnectionRepository()..authoritativeStatus = const Disconnected();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.disconnected));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);
      final beforeResume = MainVpnButtonState.fromSnapshot(snapshots.current!);
      snapshots.currentSnapshot = _snapshot(VpnSessionPhase.connected, sequence: 2, version: 2);

      await setup.notifier.handleMainVpnButtonTap(beforeResume);

      expect(repository.disconnectCalls, 1);
      expect(repository.connectCalls, 0);
      await tester.pump(const Duration(seconds: 2));
    });
  });
}

Future<_ConnectionTestSetup> _createContainer(
  _FakeConnectionRepository repository, {
  bool startedByUser = true,
  Completer<void>? hapticBarrier,
  bool activeProfileMissing = false,
  VpnSessionSnapshotSource? snapshotSource,
}) async {
  SharedPreferences.setMockInitialValues({'haptic_feedback': false, 'started_by_user': startedByUser});
  final preferences = await SharedPreferences.getInstance();
  final profile = ProfileEntity.local(
    id: 'profile-1',
    active: true,
    name: 'Test profile',
    lastUpdate: DateTime.utc(2026),
  );
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      connectionRepositoryProvider.overrideWith((ref) => repository),
      activeProfileProvider.overrideWith(() => _TestActiveProfile(activeProfileMissing ? null : profile)),
      if (snapshotSource != null) vpnSessionSnapshotSourceProvider.overrideWithValue(snapshotSource),
      if (hapticBarrier != null) hapticServiceProvider.overrideWith(() => _TestHapticService(hapticBarrier)),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  final observedStates = <AsyncValue<ConnectionStatus>>[];
  final subscription = container.listen(
    connectionNotifierProvider,
    (_, next) => observedStates.add(next),
    fireImmediately: true,
  );
  await container.read(connectionNotifierProvider.future);
  await repository.eventsListening.future;
  return _ConnectionTestSetup(
    container: container,
    subscription: subscription,
    preferences: preferences,
    repository: repository,
    profile: profile,
    observedStates: observedStates,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  String Function()? diagnostics,
  Duration step = Duration.zero,
}) async {
  for (var attempt = 0; attempt < 20 && !predicate(); attempt++) {
    await tester.pump(step);
  }
  expect(predicate(), isTrue, reason: diagnostics?.call());
}

class _ConnectionTestSetup {
  const _ConnectionTestSetup({
    required this.container,
    required this.subscription,
    required this.preferences,
    required this.repository,
    required this.profile,
    required this.observedStates,
  });

  final ProviderContainer container;
  final ProviderSubscription<AsyncValue<ConnectionStatus>> subscription;
  final SharedPreferences preferences;
  final _FakeConnectionRepository repository;
  final ProfileEntity profile;
  final List<AsyncValue<ConnectionStatus>> observedStates;

  ConnectionNotifier get notifier => container.read(connectionNotifierProvider.notifier);
  ConnectionStatus? get status => container.read(connectionNotifierProvider).valueOrNull;

  void dispose() {
    subscription.close();
    container.dispose();
    unawaited(repository.dispose());
  }
}

class _TestActiveProfile extends ActiveProfile {
  _TestActiveProfile(this.profile);

  final ProfileEntity? profile;

  @override
  Stream<ProfileEntity?> build() => Stream.value(profile);
}

class _TestHapticService extends HapticService {
  _TestHapticService(this.barrier);

  final Completer<void> barrier;

  @override
  bool build() => true;

  @override
  Future<void> mediumImpact() => barrier.future;
}

class _FakeConnectionRepository implements ConnectionRepository {
  // Single-subscription controllers buffer events emitted just after the
  // initial status yield but before watchConnectionStatus resumes at yield*.
  final _events = StreamController<ConnectionStatus>();
  final eventsListening = Completer<void>();

  ConnectionStatus initialStatus = const Connected();
  ConnectionStatus? authoritativeStatus = const Connected();
  Completer<void>? disconnectBarrier;
  final disconnectBarriers = <Completer<void>>[];
  Completer<void>? reconnectBarrier;
  Completer<void>? connectBarrier;
  final connectBarriers = <Completer<void>>[];
  ConnectionStatus? reconnectStatus;
  int connectCalls = 0;
  int disconnectCalls = 0;
  final disconnectForceValues = <bool>[];
  int reconnectCalls = 0;
  int watchCalls = 0;
  final resyncSources = <String>[];
  void Function()? onConnectSuccess;

  void emit(ConnectionStatus status) => _events.add(status);

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  Stream<ConnectionStatus> watchConnectionStatus() async* {
    watchCalls++;
    yield initialStatus;
    if (!eventsListening.isCompleted) eventsListening.complete();
    yield* _events.stream;
  }

  @override
  Future<ConnectionStatus?> resyncConnectionStatus(String source) async {
    resyncSources.add(source);
    return authoritativeStatus;
  }

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    return TaskEither(() async {
      final callIndex = connectCalls;
      connectCalls++;
      final barrier = callIndex < connectBarriers.length ? connectBarriers[callIndex] : connectBarrier;
      if (barrier != null) await barrier.future;
      onConnectSuccess?.call();
      return right(unit);
    });
  }

  @override
  TaskEither<ConnectionFailure, Unit> disconnect({bool force = false}) {
    return TaskEither(() async {
      final callIndex = disconnectCalls;
      disconnectCalls++;
      disconnectForceValues.add(force);
      final barrier = callIndex < disconnectBarriers.length ? disconnectBarriers[callIndex] : disconnectBarrier;
      if (barrier != null) await barrier.future;
      return right(unit);
    });
  }

  @override
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit) {
    return TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(
    ProfileEntity activeProfile,
    bool disableMemoryLimit, {
    String source = 'reconnect',
  }) {
    return TaskEither(() async {
      reconnectCalls++;
      final status = reconnectStatus;
      if (status != null) emit(status);
      final barrier = reconnectBarrier;
      if (barrier != null) await barrier.future;
      return right(unit);
    });
  }

  @override
  TaskEither<ConnectionFailure, Unit> setup() => TaskEither.of(unit);

  Future<void> dispose() => _events.close();
}

class _FakeSnapshotSource implements VpnSessionSnapshotSource {
  _FakeSnapshotSource(this.currentSnapshot);

  VpnSessionSnapshot? currentSnapshot;
  final resyncSources = <String>[];
  final _events = StreamController<VpnSessionSnapshot>.broadcast();

  @override
  VpnSessionSnapshot? get current => currentSnapshot;

  @override
  Future<VpnSessionSnapshot?> resync(String source) async {
    resyncSources.add(source);
    return currentSnapshot;
  }

  @override
  Stream<VpnSessionSnapshot> watch() => _events.stream;
}

VpnSessionSnapshot _snapshot(
  VpnSessionPhase phase, {
  int sequence = 1,
  int version = 1,
  String? requestedAction,
  VpnStopSource stopSource = VpnStopSource.none,
  bool provesConnected = false,
  String failureCode = '',
}) {
  return VpnSessionSnapshot(
    generation: 50,
    runtimeEpoch: 'runtime-main-button',
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
    recoverable: true,
  );
}
