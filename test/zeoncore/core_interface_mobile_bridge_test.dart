import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_mobile.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      null,
    );
  });

  test('iOS bridge drops duplicate and stale events and projects the accepted snapshot', () async {
    final core = CoreInterfaceMobile(androidOverride: false);

    final statuses = await core
        .projectAppleSnapshotStatusesForTesting(
          Stream<Object?>.fromIterable([
            _iosSnapshotEvent(
              generation: 9301,
              sequenceNumber: 1,
              phase: VpnSessionPhase.verifying,
              legacyStatus: 'Stopped',
            ),
            _iosSnapshotEvent(
              generation: 9301,
              sequenceNumber: 1,
              phase: VpnSessionPhase.connected,
              ready: true,
              legacyStatus: 'Started',
            ),
            _iosSnapshotEvent(
              generation: 9301,
              sequenceNumber: 0,
              phase: VpnSessionPhase.disconnected,
              requestedAction: 'stop',
              legacyStatus: 'Stopped',
            ),
            _iosSnapshotEvent(
              generation: 9301,
              sequenceNumber: 3,
              phase: VpnSessionPhase.connected,
              ready: true,
              legacyStatus: 'Stopped',
            ),
          ]),
        )
        .toList();

    expect(statuses, hasLength(2));
    expect(statuses[0], isA<CoreStarting>());
    expect(statuses[1], isA<CoreStarted>());
    expect(core.authoritativeSessionSnapshot?.sequenceNumber, 3);
    expect(core.authoritativeSessionSnapshot?.phase, VpnSessionPhase.connected);
  });

  test('iOS stop waits for an authoritative terminal snapshot after the port closes', () async {
    const generation = 9401;
    var snapshotPolls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async => switch (call.method) {
        'set_session_generation' || 'stop' => generation,
        'get_vpn_session_snapshot' => _iosSnapshotEvent(
          generation: generation,
          sequenceNumber: ++snapshotPolls,
          phase: snapshotPolls == 1 ? VpnSessionPhase.stopping : VpnSessionPhase.disconnected,
          requestedAction: 'stop',
          stopSource: VpnStopSource.flutter,
        ),
        _ => throw StateError('unexpected native call: ${call.method}'),
      },
    );
    final core = _testCore();

    expect(await core.stop(generation: generation), isTrue);
    expect(snapshotPolls, 2);
    expect(core.authoritativeSessionSnapshot?.isTerminalStop, isTrue);
  });

  test('iOS explicit stop rejects an inactive snapshot that still belongs to Connect', () async {
    const generation = 9402;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async => switch (call.method) {
        'set_session_generation' || 'stop' => generation,
        'get_vpn_session_snapshot' => _iosSnapshotEvent(
          generation: generation,
          sequenceNumber: 1,
          phase: VpnSessionPhase.disconnected,
        ),
        _ => throw StateError('unexpected native call: ${call.method}'),
      },
    );
    final core = _testCore(terminalSnapshotTimeout: const Duration(milliseconds: 25));

    expect(await core.stop(generation: generation), isFalse);
  });

  test('iOS replacement accepts an already inactive same-generation Connect snapshot', () async {
    const generation = 9403;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async => switch (call.method) {
        'set_session_generation' || 'stop' => generation,
        'get_vpn_session_snapshot' => _iosSnapshotEvent(
          generation: generation,
          sequenceNumber: 1,
          phase: VpnSessionPhase.startRequested,
        ),
        _ => throw StateError('unexpected native call: ${call.method}'),
      },
    );
    final core = _testCore();

    expect(await core.stopForReplacement(generation: generation), isTrue);
  });

  test('iOS stop confirmation distinguishes terminal Stop from replacement teardown', () {
    const generation = 9450;
    final core = _testCore();
    VpnSessionSnapshot snapshot({
      required int generation,
      required VpnSessionPhase phase,
      String requestedAction = 'connect',
      VpnStopSource stopSource = VpnStopSource.none,
    }) => VpnSessionSnapshot.fromEvent(
      _iosSnapshotEvent(
        generation: generation,
        sequenceNumber: 1,
        phase: phase,
        requestedAction: requestedAction,
        stopSource: stopSource,
      ),
    );

    expect(
      core.confirmsPlatformStopForTesting(
        snapshot(
          generation: generation,
          phase: VpnSessionPhase.disconnected,
          requestedAction: 'stop',
          stopSource: VpnStopSource.flutter,
        ),
        generation: generation,
        replacement: false,
      ),
      isTrue,
      reason: 'a user Stop needs a terminal snapshot at the requested generation or newer',
    );
    expect(
      core.confirmsPlatformStopForTesting(
        snapshot(
          generation: generation,
          phase: VpnSessionPhase.disconnected,
          requestedAction: 'stop',
          stopSource: VpnStopSource.replacement,
        ),
        generation: generation,
        replacement: true,
      ),
      isTrue,
      reason: 'replacement teardown can complete with its native stop source',
    );
    expect(
      core.confirmsPlatformStopForTesting(
        snapshot(generation: generation, phase: VpnSessionPhase.startRequested),
        generation: generation,
        replacement: true,
      ),
      isTrue,
      reason: 'an already inactive tunnel keeps the pending Connect intent',
    );
    expect(
      core.confirmsPlatformStopForTesting(
        snapshot(
          generation: generation + 1,
          phase: VpnSessionPhase.disconnected,
          requestedAction: 'stop',
          stopSource: VpnStopSource.flutter,
        ),
        generation: generation,
        replacement: true,
      ),
      isFalse,
      reason: 'a newer explicit Stop cannot confirm the older replacement',
    );
  });

  test('native stop acknowledgement has a bounded MethodChannel timeout', () async {
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) => pending.future,
    );
    final core = _testCore(nativeControlTimeout: const Duration(milliseconds: 10));

    await expectLater(core.stopMethodChannel(generation: 9501), throwsA(isA<TimeoutException>()));
    pending.complete(null);
  });

  test('native VPN preparation has a bounded MethodChannel timeout', () async {
    const generation = 9502;
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) => switch (call.method) {
        'set_session_generation' => Future<Object?>.value(generation),
        'prepare_vpn' => pending.future,
        _ => Future<Object?>.error(StateError('unexpected native call: ${call.method}')),
      },
    );
    final core = _testCore(nativeSetupTimeout: const Duration(milliseconds: 10));

    await expectLater(
      core.prepareVpn('runtime.json', 'profile', false, generation: generation),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete(null);
  });

  test('timed-out generation synchronization can resend the same generation', () async {
    const generation = 9503;
    final firstCall = Completer<Object?>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) {
        expect(call.method, 'set_session_generation');
        calls++;
        return calls == 1 ? firstCall.future : Future<Object?>.value(generation);
      },
    );
    final core = _testCore(nativeControlTimeout: const Duration(milliseconds: 10));

    await expectLater(core.setSessionGeneration(generation), throwsA(isA<TimeoutException>()));
    await core.setSessionGeneration(generation);
    await core.setSessionGeneration(generation);

    expect(calls, 2, reason: 'timeout retries once; acknowledged generations remain coalesced');
    firstCall.complete(generation);
  });

  test('prepare is promoted to connect once within the same generation', () async {
    const generation = 9504;
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) {
        expect(call.method, 'set_session_generation');
        final arguments = call.arguments! as Map<Object?, Object?>;
        actions.add(arguments['requestedAction']! as String);
        return Future<Object?>.value(generation);
      },
    );
    final core = _testCore();

    await core.setPreparationGeneration(generation);
    await core.setPreparationGeneration(generation);
    await core.setSessionGeneration(generation);
    await core.setSessionGeneration(generation);
    await core.setPreparationGeneration(generation);

    expect(actions, ['prepare', 'connect']);
  });

  test('deferred preparation reports the authoritative generation without poisoning retry cache', () async {
    const generation = 95040;
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        expect(call.method, 'set_session_generation');
        calls++;
        return 0;
      },
    );
    final core = _testCore();

    await expectLater(
      core.setPreparationGeneration(generation),
      throwsA(
        isA<SessionGenerationRejectedException>()
            .having((error) => error.requested, 'requested', generation)
            .having((error) => error.accepted, 'accepted', 0),
      ),
    );
    await expectLater(core.setPreparationGeneration(generation), throwsA(isA<SessionGenerationRejectedException>()));

    expect(calls, 2);
    expect(core.cachedSessionGenerationForTesting, 0);
  });

  test('bootstrap provider readiness mapped to the monotonic host generation reaches Dart', () async {
    const generation = 95041;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        expect(call.method, 'set_session_generation');
        return generation;
      },
    );
    final core = _testCore();
    await core.setPreparationGeneration(generation);

    final statuses = await core
        .projectAppleSnapshotStatusesForTesting(
          Stream<Object?>.fromIterable([
            _iosSnapshotEvent(
              generation: generation,
              sequenceNumber: 1,
              phase: VpnSessionPhase.disconnected,
              requestedAction: 'prepare',
            ),
            _iosSnapshotEvent(
              generation: generation,
              sequenceNumber: 2,
              phase: VpnSessionPhase.connected,
              ready: true,
              legacyStatus: 'Started',
            ),
          ]),
        )
        .toList();

    expect(statuses.last, isA<CoreStarted>());
    expect(core.cachedSessionGenerationForTesting, generation);
    expect(core.cachedSessionRequestedActionForTesting, 'connect');
    expect(core.authoritativeSessionSnapshot?.provesConnected, isTrue);
  });

  test('late lower-generation acknowledgement cannot overwrite a newer action cache', () async {
    const oldGeneration = 9505;
    const newGeneration = 9506;
    final oldAcknowledgement = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) {
        expect(call.method, 'set_session_generation');
        final arguments = call.arguments! as Map<Object?, Object?>;
        final generation = arguments['generation']! as int;
        return generation == oldGeneration ? oldAcknowledgement.future : Future<Object?>.value(newGeneration);
      },
    );
    final core = _testCore();

    final oldPrepare = core.setPreparationGeneration(oldGeneration);
    await Future<void>.delayed(Duration.zero);
    await core.setSessionGeneration(newGeneration);
    oldAcknowledgement.complete(oldGeneration);
    await oldPrepare;

    expect(core.cachedSessionGenerationForTesting, newGeneration);
    expect(core.cachedSessionRequestedActionForTesting, 'connect');
  });

  test('late lower-generation Stop cannot steal a newer Connect action cache', () async {
    const oldGeneration = 9507;
    const newGeneration = 9508;
    final oldAcknowledgement = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) {
        final arguments = call.arguments! as Map<Object?, Object?>;
        final generation = arguments['generation']! as int;
        if (call.method == 'stop') return oldAcknowledgement.future;
        expect(call.method, 'set_session_generation');
        return Future<Object?>.value(generation);
      },
    );
    final core = _testCore();

    final oldStop = core.stopMethodChannel(generation: oldGeneration);
    await Future<void>.delayed(Duration.zero);
    await core.setSessionGeneration(newGeneration);
    oldAcknowledgement.complete(oldGeneration);
    await oldStop;

    expect(core.cachedSessionGenerationForTesting, newGeneration);
    expect(core.cachedSessionRequestedActionForTesting, 'connect');
  });

  test('preemptive native rebase caches Stop ownership at the accepted generation', () async {
    const requestedGeneration = 9510;
    const acceptedGeneration = 9520;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CoreInterfaceMobile.methodChannel,
      (call) async {
        expect(call.method, 'stop');
        return acceptedGeneration;
      },
    );
    final core = _testCore();

    expect(await core.stopMethodChannel(generation: requestedGeneration, preemptive: true), acceptedGeneration);
    expect(core.cachedSessionGenerationForTesting, acceptedGeneration);
    expect(core.cachedSessionRequestedActionForTesting, 'stop');
  });
}

CoreInterfaceMobile _testCore({
  Duration nativeSetupTimeout = const Duration(milliseconds: 100),
  Duration nativeControlTimeout = const Duration(milliseconds: 100),
  Duration terminalSnapshotTimeout = const Duration(milliseconds: 100),
}) => CoreInterfaceMobile(
  androidOverride: false,
  portProbe: (_, _) async => false,
  nativeSetupTimeout: nativeSetupTimeout,
  nativeControlTimeout: nativeControlTimeout,
  platformStopTimeout: const Duration(milliseconds: 100),
  terminalSnapshotTimeout: terminalSnapshotTimeout,
  terminalSnapshotPollInterval: const Duration(milliseconds: 1),
);

Map<String, Object?> _iosSnapshotEvent({
  required int generation,
  required int sequenceNumber,
  required VpnSessionPhase phase,
  String requestedAction = 'connect',
  VpnStopSource stopSource = VpnStopSource.none,
  bool ready = false,
  String legacyStatus = 'Starting',
}) => {
  'generation': generation,
  'runtimeEpoch': 'ios-test-process',
  'sequenceNumber': sequenceNumber,
  'snapshotVersion': sequenceNumber,
  'phase': phase.name,
  'requestedAction': requestedAction,
  'stopSource': stopSource.name,
  'coreReady': ready,
  'coreStarted': ready,
  'commandEndpointReady': ready,
  'tunnelReady': ready,
  'protectSucceeded': ready,
  'platformVpnValidated': ready,
  'selectedOutboundId': ready ? 'opaque-ios-outbound' : '',
  'status': legacyStatus,
};
