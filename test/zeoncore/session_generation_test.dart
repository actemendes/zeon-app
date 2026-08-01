import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_mobile.dart';
import 'package:zeon/zeoncore/session_generation.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionGenerationGate', () {
    test('start then restart makes the start callback stale', () {
      final stale = <String>[];
      final gate = SessionGenerationGate(
        seed: 100,
        onStale: (value, current, source) => stale.add('$value/$current/$source'),
      );

      final start = gate.next();
      final restart = gate.next();

      expect(gate.isCurrent(start, source: 'start_result'), isFalse);
      expect(gate.isCurrent(restart, source: 'restart_result'), isTrue);
      expect(stale, ['101/102/start_result']);
    });

    test('start then stop rejects a late start callback', () {
      final gate = SessionGenerationGate(seed: 200);
      final start = gate.next();
      final stop = gate.next();

      expect(gate.isCurrent(start, source: 'start_result'), isFalse);
      expect(gate.isCurrent(stop, source: 'stop_result'), isTrue);
    });

    test('restart then restart keeps only the newest attempt', () {
      final gate = SessionGenerationGate(seed: 300);
      final first = gate.next();
      final second = gate.next();

      expect(gate.isCurrent(first, source: 'first_restart'), isFalse);
      expect(gate.isCurrent(second, source: 'second_restart'), isTrue);
    });

    test('profile switch invalidates results from the old profile session', () {
      final gate = SessionGenerationGate(seed: 400);
      final profileA = gate.next();
      final profileB = gate.next();

      expect(gate.isCurrent(profileA, source: 'profile_a_callback'), isFalse);
      expect(gate.isCurrent(profileB, source: 'profile_b_callback'), isTrue);
    });

    test('manual reselect invalidates an older background test result', () {
      final gate = SessionGenerationGate(seed: 500);
      final backgroundTest = gate.current;
      final manualSession = gate.next();

      expect(gate.isCurrent(backgroundTest, source: 'background_url_test'), isFalse);
      expect(gate.isCurrent(manualSession, source: 'manual_reselect'), isTrue);
    });

    test('callback from a closed session cannot affect the new session', () {
      final gate = SessionGenerationGate(seed: 600);
      final closed = gate.next();
      final active = gate.next();

      expect(gate.isCurrent(closed, source: 'closed_session_callback'), isFalse);
      expect(gate.isCurrent(active, source: 'active_session_callback'), isTrue);
    });

    test('authoritative external generation is never reused', () {
      final gate = SessionGenerationGate(seed: 700);
      expect(gate.advanceTo(900), 900);
      expect(gate.advanceTo(800), 900);
      expect(gate.next(), 901);
    });
  });

  group('Stage 2.1 stale completion and serialized mode switch', () {
    test('Smart to Round Robin closes old body before new body starts', () async {
      final queue = SerialLifecycleQueue();
      final oldMayClose = Completer<void>();
      final oldStarted = Completer<void>();
      final order = <String>[];

      final smartToRoundRobin = queue.enqueue(() async {
        order.add('old-start');
        oldStarted.complete();
        await oldMayClose.future;
        order.add('old-close');
      });
      await oldStarted.future;
      final roundRobinToSmart = queue.enqueue(() async => order.add('new-start'));
      expect(order, ['old-start']);
      oldMayClose.complete();
      await Future.wait([smartToRoundRobin, roundRobinToSmart]);
      expect(order, ['old-start', 'old-close', 'new-start']);
    });

    test('20 rapid switches execute at most one lifecycle body at a time', () async {
      final queue = SerialLifecycleQueue();
      var active = 0;
      var maxActive = 0;
      final barriers = List.generate(20, (_) => Completer<void>());
      final started = List.generate(20, (_) => Completer<void>());
      final futures = <Future<void>>[];

      for (var index = 0; index < 20; index++) {
        futures.add(
          queue.enqueue(() async {
            active++;
            if (active > maxActive) maxActive = active;
            started[index].complete();
            await barriers[index].future;
            active--;
          }),
        );
      }
      for (var index = 0; index < 20; index++) {
        await started[index].future;
        expect(active, 1);
        barriers[index].complete();
      }
      await Future.wait(futures);
      expect(maxActive, 1);
      expect(active, 0);
    });

    test('stale openTun exception is cancellation and cannot reach UI', () {
      final gate = SessionGenerationGate(seed: 1000);
      final old = gate.next();
      gate.next();
      var dialogShown = false;
      final disposition = gate.classifyCompletion(old, source: 'open_tun_exception');
      if (disposition == SessionCompletionDisposition.current) dialogShown = true;
      expect(disposition, SessionCompletionDisposition.stale);
      expect(dialogShown, isFalse);
    });

    test('stale Mobile.start exception does not stop new generation', () {
      final gate = SessionGenerationGate(seed: 1100);
      final old = gate.next();
      final current = gate.next();
      var currentRunning = true;
      if (gate.classifyCompletion(old, source: 'mobile_start_exception') == SessionCompletionDisposition.current) {
        currentRunning = false;
      }
      expect(gate.isCurrent(current, source: 'current_session'), isTrue);
      expect(currentRunning, isTrue);
    });

    test('stale command timeout and stale close cannot mutate current state', () {
      final gate = SessionGenerationGate(seed: 1200);
      final old = gate.next();
      gate.next();
      var state = 'connected';
      for (final source in ['command_timeout', 'close_callback']) {
        if (gate.classifyCompletion(old, source: source) == SessionCompletionDisposition.current) {
          state = 'stopped';
        }
      }
      expect(state, 'connected');
    });

    test('switch during start and TUN open only publishes newest generation', () {
      final gate = SessionGenerationGate(seed: 1300);
      final starting = gate.next();
      final tunOpening = starting;
      final latest = gate.next();
      expect(gate.classifyCompletion(starting, source: 'start'), SessionCompletionDisposition.stale);
      expect(gate.classifyCompletion(tunOpening, source: 'tun'), SessionCompletionDisposition.stale);
      expect(gate.classifyCompletion(latest, source: 'latest'), SessionCompletionDisposition.current);
    });

    test('late error immediately after old core success cannot replace new session', () {
      final gate = SessionGenerationGate(seed: 1400);
      final old = gate.next();
      final latest = gate.next();
      var selectedGeneration = latest;
      if (gate.classifyCompletion(old, source: 'late_core_success_error') == SessionCompletionDisposition.current) {
        selectedGeneration = old;
      }
      expect(selectedGeneration, latest);
    });
  });

  test('Android replacement cleanup is typed separately from terminal Stop', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        calls.add(call);
        return (call.arguments as Map<Object?, Object?>)['generation'];
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        CoreInterfaceMobile.methodChannel,
        null,
      ),
    );

    final core = CoreInterfaceMobile();
    await core.stopMethodChannel(generation: 9001, replacement: true);
    await core.stopMethodChannel(generation: 9002, preemptive: true);

    expect(calls, hasLength(2));
    expect(calls[0].method, 'stop');
    expect(calls[0].arguments, {'generation': 9001, 'preemptive': false, 'replacement': true});
    expect(calls[1].arguments, {'generation': 9002, 'preemptive': true, 'replacement': false});
  });

  test('Android replacement cleanup waits for its exact terminal snapshot before continuing', () async {
    const generation = 9101;
    var snapshotPolls = 0;
    var completed = false;
    var snapshot = _androidSnapshotEvent(
      generation: generation,
      sequenceNumber: 1,
      phase: VpnSessionPhase.stopping,
      stopSource: VpnStopSource.replacement,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        switch (call.method) {
          case 'set_session_generation':
          case 'stop':
            return generation;
          case 'get_vpn_session_snapshot':
            snapshotPolls++;
            return snapshot;
          default:
            throw StateError('unexpected platform call: ${call.method}');
        }
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        CoreInterfaceMobile.methodChannel,
        null,
      ),
    );

    final core = CoreInterfaceMobile(androidOverride: true, portProbe: (_, _) async => false);
    final cleanup = core.stopForReplacement(generation: generation).then((value) {
      completed = true;
      return value;
    });
    for (var attempt = 0; attempt < 20 && snapshotPolls == 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(snapshotPolls, greaterThan(0));
    expect(completed, isFalse);

    snapshot = _androidSnapshotEvent(
      generation: generation,
      sequenceNumber: 2,
      phase: VpnSessionPhase.disconnected,
      stopSource: VpnStopSource.replacement,
    );
    expect(await cleanup.timeout(const Duration(seconds: 3)), isTrue);
  });

  test('newer explicit terminal Stop cannot satisfy replacement cleanup', () async {
    const generation = 9201;
    var startCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        switch (call.method) {
          case 'set_session_generation':
          case 'stop':
            return generation;
          case 'get_vpn_session_snapshot':
            return _androidSnapshotEvent(
              generation: generation + 1,
              sequenceNumber: 1,
              phase: VpnSessionPhase.disconnected,
              stopSource: VpnStopSource.notification,
            );
          case 'start':
            startCalls++;
            return generation;
          default:
            throw StateError('unexpected platform call: ${call.method}');
        }
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        CoreInterfaceMobile.methodChannel,
        null,
      ),
    );

    final core = CoreInterfaceMobile(androidOverride: true, portProbe: (_, _) async => false);
    expect(await core.stopForReplacement(generation: generation).timeout(const Duration(seconds: 3)), isFalse);
    expect(startCalls, 0);
  });

  test('repeated stop confirmed by the platform does not dispatch another native stop', () async {
    final core = _StoppedCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final first = await service.stop().run();
    final second = await service.stop().run();

    expect(first.isRight(), isTrue);
    expect(second.isRight(), isTrue);
    expect(core.resyncCalls, 2);
    expect(core.setGenerationCalls, 0);
    expect(core.stopCalls, 0);
  });

  test('concurrent repeated stops share one authoritative stop operation', () async {
    final core = _DelayedStoppedCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final first = service.stop().run();
    await Future<void>.delayed(Duration.zero);
    final second = service.stop().run();
    expect(core.resyncCalls, 1);

    core.resyncBarrier.complete(const CoreStatus.stopped());
    final results = await Future.wait([first, second]);

    expect(results.every((result) => result.isRight()), isTrue);
    expect(core.resyncCalls, 1);
    expect(core.setGenerationCalls, 0);
    expect(core.stopCalls, 0);
  });

  test('failed stopped-state resync falls back to an idempotent native stop', () async {
    final core = _ThrowingResyncCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final result = await service.stop().run();

    expect(result.isRight(), isTrue);
    expect(core.resyncCalls, 1);
    expect(core.setGenerationCalls, 1);
    expect(core.stopCalls, 1);
  });

  test('unavailable stopped-state resync falls back to an idempotent native stop', () async {
    final core = _NullResyncCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final result = await service.stop().run();

    expect(result.isRight(), isTrue);
    expect(core.resyncCalls, 1);
    expect(core.setGenerationCalls, 1);
    expect(core.stopCalls, 1);
  });

  test('native stop exception returns Left and clears the coalescing latch for retry', () async {
    final core = _ThrowingNativeStopCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final first = await service.stop().run();
    final second = await service.stop().run();

    expect(first.isLeft(), isTrue);
    expect(second.isLeft(), isTrue);
    expect(core.stopCalls, 2);
    expect(service.currentState, isA<CoreStopped>());
  });

  test('generation synchronization exception returns Left and clears the stop latch', () async {
    final core = _ThrowingSetGenerationCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final first = await service.stop().run();
    final second = await service.stop().run();

    expect(first.isLeft(), isTrue);
    expect(second.isLeft(), isTrue);
    expect(core.setGenerationCalls, 2);
    expect(core.stopCalls, 0);
  });

  test('authoritative status query has no UI side effect before caller acceptance', () async {
    final core = _StoppedCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);
    service.beginVpnOperation('guarded_resync_test');

    final authoritative = await service.resyncFromPlatform('guarded_test');

    expect(authoritative, isA<CoreStopped>());
    expect(service.currentState, isA<CoreStarting>());
  });

  test('resync-only external stop preserves snapshot generation and running intent', () async {
    SharedPreferences.setMockInitialValues({'started_by_user': true});
    final preferences = await SharedPreferences.getInstance();
    final snapshot = _platformSnapshot(
      generation: 1 << 60,
      phase: VpnSessionPhase.disconnected,
      requestedAction: 'stop',
      stopSource: VpnStopSource.notification,
    );
    final core = _ResyncSnapshotCoreInterface(snapshot);
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    final service = container.read(provider);

    final authoritative = await service.resyncFromPlatform('missed_event_channel_stop');

    expect(authoritative, isA<CoreStopped>());
    expect(preferences.getBool('started_by_user'), isFalse);
    expect(service.beginVpnOperation('after_resync'), greaterThan(snapshot.generation));
  });

  test('platform stop preempts a lifecycle body blocked inside the serial queue', () async {
    final core = _PreemptiveStopCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);
    final restartGeneration = service.beginVpnOperation('blocked_restart');
    final restart = service.restart('', '', false, generation: restartGeneration).run();
    await core.firstSetGenerationEntered.future.timeout(const Duration(seconds: 2));

    final stop = service.stop().run();
    final preemptiveGeneration = await core.firstPlatformStopRequested.future.timeout(const Duration(seconds: 2));

    expect(preemptiveGeneration, greaterThan(restartGeneration));
    expect(core.releaseFirstSetGeneration.isCompleted, isFalse);
    core.releaseFirstSetGeneration.complete();
    await restart.timeout(const Duration(seconds: 2));
    await stop.timeout(const Duration(seconds: 2));
  });

  test('a newer connect intent prevents Stop from coalescing with an older in-flight Stop', () async {
    final core = _PreemptiveStopCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final blockedRestartGeneration = service.beginVpnOperation('blocked_restart');
    final blockedRestart = service.restart('', '', false, generation: blockedRestartGeneration).run();
    await core.firstSetGenerationEntered.future.timeout(const Duration(seconds: 2));

    final firstStop = service.stop().run();
    final firstStopGeneration = await core.firstPlatformStopRequested.future.timeout(const Duration(seconds: 2));
    final newerConnectGeneration = service.beginVpnOperation('connect_after_first_stop');
    final newerConnect = service.start('', '', false, generation: newerConnectGeneration).run();
    final secondStop = service.stop().run();
    final secondStopGeneration = await core.secondPlatformStopRequested.future.timeout(const Duration(seconds: 2));

    expect(firstStopGeneration, greaterThan(blockedRestartGeneration));
    expect(newerConnectGeneration, greaterThan(firstStopGeneration));
    expect(secondStopGeneration, greaterThan(newerConnectGeneration));
    expect(core.releaseFirstSetGeneration.isCompleted, isFalse);

    core.releaseFirstSetGeneration.complete();
    await Future.wait([blockedRestart, firstStop, newerConnect, secondStop]).timeout(const Duration(seconds: 2));
  });

  test('preemptive Stop adopts a native generation that was ahead of Dart', () async {
    final core = _RebasedPreemptiveStopCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final result = await service.stop().run();

    expect(result.isRight(), isTrue);
    expect(core.acceptedStopGeneration, greaterThan(core.requestedStopGeneration));
    expect(core.lastSetGeneration, core.acceptedStopGeneration);
    expect(service.beginVpnOperation('after_native_rebase'), greaterThan(core.acceptedStopGeneration));
  });

  test('terminal preemptive snapshot is not regressed to stopping by queued cleanup', () async {
    final core = _TerminalPreemptiveCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      await core.close();
    });
    final service = container.read(provider);
    final events = <CoreStatus>[];
    final subscription = service.statusController.listen(events.add);
    addTearDown(subscription.cancel);

    final result = await service.stop().run();

    expect(result.isRight(), isTrue);
    final stoppedIndex = events.indexWhere((status) => status is CoreStopped);
    expect(stoppedIndex, greaterThanOrEqualTo(0));
    expect(events.skip(stoppedIndex + 1).whereType<CoreStopping>(), isEmpty);
    expect(core.stopCalls, 0);
  });

  test('Android snapshots drive UI status and advance the next operation generation', () async {
    SharedPreferences.setMockInitialValues({'started_by_user': true});
    final preferences = await SharedPreferences.getInstance();
    final core = _SnapshotCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    addTearDown(() async {
      container.dispose();
      await core.close();
    });
    await container.read(sharedPreferencesProvider.future);
    final service = container.read(provider);
    const connectedGeneration = 1 << 60;
    final connected = service.statusController.stream.firstWhere((status) => status is CoreStarted);
    core.add(_platformSnapshot(generation: connectedGeneration, phase: VpnSessionPhase.connected, ready: true));
    await connected.timeout(const Duration(seconds: 2));

    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    core.add(
      _platformSnapshot(
        generation: connectedGeneration + 1,
        phase: VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.notification,
      ),
    );
    await stopped.timeout(const Duration(seconds: 2));

    expect(preferences.getBool('started_by_user'), isFalse);
    expect(service.currentState, isA<CoreStopped>());
    expect(service.beginVpnOperation('test_after_external_stop'), greaterThan(connectedGeneration + 1));
  });

  test('older Android snapshot cannot overwrite a newer locally reserved operation', () async {
    final core = _SnapshotCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      await core.close();
    });
    final service = container.read(provider);
    final localGeneration = service.beginVpnOperation('local_start_before_android_replay');

    core.add(
      _platformSnapshot(
        generation: localGeneration - 1,
        phase: VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.destroy,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.currentState, isA<CoreStarting>());
    expect(service.isVpnOperationCurrent(localGeneration, source: 'test_assertion'), isTrue);
  });

  test('unexpected Android destroy preserves expected-running preference', () async {
    SharedPreferences.setMockInitialValues({'started_by_user': true});
    final preferences = await SharedPreferences.getInstance();
    final core = _SnapshotCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    addTearDown(() async {
      container.dispose();
      await core.close();
    });
    await container.read(sharedPreferencesProvider.future);
    final service = container.read(provider);
    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    core.add(
      _platformSnapshot(
        generation: 1 << 60,
        phase: VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.destroy,
      ),
    );
    await stopped.timeout(const Duration(seconds: 2));

    expect(preferences.getBool('started_by_user'), isTrue);
  });

  test('replacement snapshot preserves running intent and accepts same-generation start', () async {
    SharedPreferences.setMockInitialValues({'started_by_user': true});
    final preferences = await SharedPreferences.getInstance();
    final core = _SnapshotCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    addTearDown(() async {
      container.dispose();
      await core.close();
    });
    await container.read(sharedPreferencesProvider.future);
    final service = container.read(provider);
    const generation = 1 << 60;

    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    core.add(
      _platformSnapshot(
        generation: generation,
        sequenceNumber: 1,
        phase: VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.replacement,
      ),
    );
    await stopped.timeout(const Duration(seconds: 2));
    expect(preferences.getBool('started_by_user'), isTrue);

    final starting = service.statusController.stream.firstWhere((status) => status is CoreStarting);
    core.add(
      _platformSnapshot(
        generation: generation,
        sequenceNumber: 2,
        phase: VpnSessionPhase.startRequested,
        requestedAction: 'connect',
      ),
    );
    await starting.timeout(const Duration(seconds: 2));

    final connected = service.statusController.stream.firstWhere((status) => status is CoreStarted);
    core.add(
      _platformSnapshot(
        generation: generation,
        sequenceNumber: 3,
        phase: VpnSessionPhase.connected,
        requestedAction: 'connect',
        ready: true,
      ),
    );
    await connected.timeout(const Duration(seconds: 2));
    expect(preferences.getBool('started_by_user'), isTrue);
    expect(service.currentState, isA<CoreStarted>());
  });
}

class _StoppedCoreInterface extends CoreInterface {
  int resyncCalls = 0;
  int setGenerationCalls = 0;
  int stopCalls = 0;

  @override
  Future<CoreStatus?> resyncSessionStatus() async {
    resyncCalls++;
    return const CoreStatus.stopped();
  }

  @override
  Future<void> setSessionGeneration(int generation) async {
    setGenerationCalls++;
  }

  @override
  Future<bool> stop({int generation = 0}) async {
    stopCalls++;
    return true;
  }
}

class _DelayedStoppedCoreInterface extends _StoppedCoreInterface {
  final resyncBarrier = Completer<CoreStatus?>();

  @override
  Future<CoreStatus?> resyncSessionStatus() {
    resyncCalls++;
    return resyncBarrier.future;
  }
}

class _ThrowingResyncCoreInterface extends _StoppedCoreInterface {
  @override
  Future<CoreStatus?> resyncSessionStatus() {
    resyncCalls++;
    return Future<CoreStatus?>.error(StateError('authoritative platform snapshot unavailable'));
  }
}

class _NullResyncCoreInterface extends _StoppedCoreInterface {
  @override
  Future<CoreStatus?> resyncSessionStatus() async {
    resyncCalls++;
    return null;
  }
}

class _ThrowingNativeStopCoreInterface extends _NullResyncCoreInterface {
  @override
  Future<bool> stop({int generation = 0}) {
    stopCalls++;
    return Future<bool>.error(StateError('native stop unavailable'));
  }
}

class _ThrowingSetGenerationCoreInterface extends _NullResyncCoreInterface {
  @override
  Future<void> setSessionGeneration(int generation) {
    setGenerationCalls++;
    return Future<void>.error(StateError('native generation rejected'));
  }
}

class _ResyncSnapshotCoreInterface extends CoreInterface {
  _ResyncSnapshotCoreInterface(this.snapshot);

  final VpnSessionSnapshot snapshot;

  @override
  VpnSessionSnapshot get authoritativeSessionSnapshot => snapshot;

  @override
  int get authoritativeSessionGeneration => snapshot.generation;

  @override
  Future<CoreStatus?> resyncSessionStatus() async => snapshot.toCoreStatus();
}

class _SnapshotCoreInterface extends CoreInterface {
  final StreamController<VpnSessionSnapshot> _snapshots = StreamController<VpnSessionSnapshot>.broadcast();

  void add(VpnSessionSnapshot snapshot) => _snapshots.add(snapshot);

  Future<void> close() => _snapshots.close();

  @override
  Stream<VpnSessionSnapshot> watchSessionSnapshots() => _snapshots.stream;
}

class _PreemptiveStopCoreInterface extends CoreInterface {
  final Completer<void> firstSetGenerationEntered = Completer<void>();
  final Completer<void> releaseFirstSetGeneration = Completer<void>();
  final Completer<int> firstPlatformStopRequested = Completer<int>();
  final Completer<int> secondPlatformStopRequested = Completer<int>();
  var _setGenerationCalls = 0;

  @override
  bool get supportsPreemptivePlatformStop => true;

  @override
  Future<void> setSessionGeneration(int generation) async {
    _setGenerationCalls++;
    if (_setGenerationCalls != 1) return;
    firstSetGenerationEntered.complete();
    await releaseFirstSetGeneration.future;
  }

  @override
  Future<int> requestPlatformStop({required int generation}) async {
    if (!firstPlatformStopRequested.isCompleted) {
      firstPlatformStopRequested.complete(generation);
    } else if (!secondPlatformStopRequested.isCompleted) {
      secondPlatformStopRequested.complete(generation);
    }
    return generation;
  }

  @override
  Future<bool> stop({int generation = 0}) async => true;
}

class _TerminalPreemptiveCoreInterface extends CoreInterface {
  final StreamController<VpnSessionSnapshot> _snapshots = StreamController<VpnSessionSnapshot>.broadcast();
  int stopCalls = 0;

  @override
  bool get supportsPreemptivePlatformStop => true;

  @override
  Future<int> requestPlatformStop({required int generation}) async {
    _snapshots.add(
      _platformSnapshot(
        generation: generation,
        phase: VpnSessionPhase.disconnected,
        requestedAction: 'stop',
        stopSource: VpnStopSource.flutter,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return generation;
  }

  @override
  Future<bool> stop({int generation = 0}) async {
    stopCalls++;
    return true;
  }

  @override
  Stream<VpnSessionSnapshot> watchSessionSnapshots() => _snapshots.stream;

  Future<void> close() => _snapshots.close();
}

class _RebasedPreemptiveStopCoreInterface extends CoreInterface {
  int requestedStopGeneration = 0;
  int acceptedStopGeneration = 0;
  int lastSetGeneration = 0;

  @override
  bool get supportsPreemptivePlatformStop => true;

  @override
  Future<int> requestPlatformStop({required int generation}) {
    requestedStopGeneration = generation;
    return Future<int>.value(acceptedStopGeneration = generation + 100);
  }

  @override
  Future<void> setSessionGeneration(int generation) async {
    lastSetGeneration = generation;
  }

  @override
  Future<bool> stop({int generation = 0}) async => true;
}

VpnSessionSnapshot _platformSnapshot({
  required int generation,
  required VpnSessionPhase phase,
  int? sequenceNumber,
  bool ready = false,
  String requestedAction = '',
  VpnStopSource stopSource = VpnStopSource.none,
}) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: 'android-process',
  sequenceNumber: sequenceNumber ?? generation,
  snapshotVersion: sequenceNumber ?? generation,
  phase: phase,
  requestedAction: requestedAction,
  stopSource: stopSource,
  coreReady: ready,
  coreStarted: ready,
  commandEndpointReady: ready,
  tunnelReady: ready,
  protectSucceeded: ready,
  platformVpnValidated: ready,
  selectedOutboundId: ready ? 'opaque-outbound' : '',
);

Map<String, Object?> _androidSnapshotEvent({
  required int generation,
  required int sequenceNumber,
  required VpnSessionPhase phase,
  required VpnStopSource stopSource,
}) => {
  'generation': generation,
  'runtimeEpoch': 'android-test-process',
  'sequenceNumber': sequenceNumber,
  'snapshotVersion': sequenceNumber,
  'phase': phase.name,
  'requestedAction': 'stop',
  'stopSource': stopSource.name,
};
