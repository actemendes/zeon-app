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

    testWidgets('a second connect is not lost while an older connect is pending', (tester) async {
      final repository = _FakeConnectionRepository()
        ..initialStatus = const Disconnected()
        ..authoritativeStatus = const Connected()
        ..connectBarrier = Completer<void>();
      final setup = await _createContainer(repository, startedByUser: false);
      addTearDown(setup.dispose);

      final first = setup.notifier.mayConnect();
      await _pumpUntil(tester, () => repository.connectCalls == 1);
      final second = setup.notifier.mayConnect();
      await _pumpUntil(tester, () => repository.connectCalls == 2);

      repository.connectBarrier!.complete();
      await Future.wait([first, second]);

      expect(repository.connectCalls, 2);
      expect(repository.resyncSources.where((source) => source == 'connect_completion'), hasLength(1));
      await _pumpUntil(tester, () => setup.status is Connected, diagnostics: () => setup.observedStates.join(' -> '));
      expect(setup.status, const Connected());
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

    testWidgets('STOPPING authoritative snapshot blocks every command', (tester) async {
      final repository = _FakeConnectionRepository();
      final snapshots = _FakeSnapshotSource(_snapshot(VpnSessionPhase.stopping));
      final setup = await _createContainer(repository, snapshotSource: snapshots);
      addTearDown(setup.dispose);

      await setup.notifier.handleMainVpnButtonTap(MainVpnButtonState.fromSnapshot(snapshots.current!));

      expect(repository.connectCalls, 0);
      expect(repository.disconnectCalls, 0);
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
  Completer<void>? reconnectBarrier;
  Completer<void>? connectBarrier;
  ConnectionStatus? reconnectStatus;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int reconnectCalls = 0;
  final resyncSources = <String>[];

  void emit(ConnectionStatus status) => _events.add(status);

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  Stream<ConnectionStatus> watchConnectionStatus() async* {
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
      connectCalls++;
      final barrier = connectBarrier;
      if (barrier != null) await barrier.future;
      return right(unit);
    });
  }

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() {
    return TaskEither(() async {
      disconnectCalls++;
      final barrier = disconnectBarrier;
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

VpnSessionSnapshot _snapshot(VpnSessionPhase phase, {int sequence = 1, int version = 1}) {
  return VpnSessionSnapshot(
    generation: 50,
    runtimeEpoch: 'runtime-main-button',
    sequenceNumber: sequence,
    snapshotVersion: version,
    phase: phase,
    requestedAction: switch (phase) {
      VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.disconnected => 'stop',
      _ => 'connect',
    },
    recoverable: true,
  );
}
