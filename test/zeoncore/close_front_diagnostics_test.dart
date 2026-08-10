import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_mobile.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  group('closeFront tri-state decision semantics', () {
    test('connected background probe preserves Started without a duplicate publication', () {
      expect(_decision(outcome: PortProbeOutcome.connected), CloseFrontPublicationDecision.preserveStarted);
    });

    test('confirmed closed probe publishes Stopped when native state does not contradict it', () {
      expect(_decision(outcome: PortProbeOutcome.closed), CloseFrontPublicationDecision.publishStopped);
    });

    test('timeout is unknown and cannot publish Stopped', () {
      expect(_decision(outcome: PortProbeOutcome.timeout), CloseFrontPublicationDecision.preserveUnknown);
    });

    test('socket error is unknown and cannot publish Stopped', () {
      expect(_decision(outcome: PortProbeOutcome.socketError), CloseFrontPublicationDecision.preserveUnknown);
    });

    test('an unobserved false result remains unknown', () {
      expect(
        closeFrontBackgroundState(singleChannel: false, backgroundActive: false, observation: null),
        CloseFrontBackgroundState.unknown,
      );
    });

    test('same-generation native connected snapshot overrides closed or unknown control probes', () {
      for (final outcome in [PortProbeOutcome.closed, PortProbeOutcome.timeout]) {
        expect(
          _decision(outcome: outcome, nativeProvesConnected: true),
          CloseFrontPublicationDecision.nativeConnectedOverride,
        );
      }
    });

    test('stale lifecycle operation cannot publish regardless of probe result', () {
      expect(
        _decision(outcome: PortProbeOutcome.closed, operationCurrent: false),
        CloseFrontPublicationDecision.skipStaleOperation,
      );
    });

    test('start or stop lifecycle intent cannot be overwritten by a closed probe', () {
      expect(
        _decision(outcome: PortProbeOutcome.closed, lifecycleIntentReserved: true),
        CloseFrontPublicationDecision.preserveLifecycleIntent,
      );
    });

    test('start or stop lifecycle intent also wins over active and native-connected evidence', () {
      expect(
        _decision(outcome: PortProbeOutcome.connected, nativeProvesConnected: true, lifecycleIntentReserved: true),
        CloseFrontPublicationDecision.preserveLifecycleIntent,
      );
    });
  });

  group('closeFront operation integration', () {
    test('confirmed closed probe publishes Stopped for the current operation', () async {
      final fixture = _CloseFrontFixture(PortProbeOutcome.closed);
      addTearDown(fixture.close);
      fixture.publishStarted();
      fixture.events.clear();

      await fixture.service.closeFront();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.events.whereType<CoreStopped>(), hasLength(1));
      expect(fixture.service.currentState, isA<CoreStopped>());
    });

    test('timeout and socket error preserve the last Started state', () async {
      for (final outcome in [PortProbeOutcome.timeout, PortProbeOutcome.socketError]) {
        final fixture = _CloseFrontFixture(outcome);
        fixture.publishStarted();
        fixture.events.clear();

        await fixture.service.closeFront();
        await Future<void>.delayed(Duration.zero);

        expect(fixture.events.whereType<CoreStopped>(), isEmpty, reason: outcome.name);
        expect(fixture.service.currentState, isA<CoreStarted>(), reason: outcome.name);
        await fixture.close();
      }
    });

    test('cached same-generation native CONNECTED prevents Stopped on a closed probe', () async {
      final fixture = _CloseFrontFixture(PortProbeOutcome.closed);
      addTearDown(fixture.close);
      final generation = fixture.service.beginVpnOperation('native_override_test');
      fixture.core.nativeSnapshot = _connectedSnapshot(generation);
      fixture.publishStarted();
      fixture.events.clear();

      await fixture.service.closeFront();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.events.whereType<CoreStopped>(), isEmpty);
      expect(fixture.service.currentState, isA<CoreStarted>());
    });

    test('resume overlap cannot overwrite Started and only cleans captured foreground resources', () async {
      final barrier = Completer<void>();
      final enteredProbe = Completer<void>();
      final fixture = _CloseFrontFixture(PortProbeOutcome.closed, probeBarrier: barrier, onProbeEntered: enteredProbe);
      addTearDown(fixture.close);
      fixture.publishStarted();
      fixture.events.clear();
      var oldListenerCancelled = false;
      var newListenerCancelled = false;
      final oldController = StreamController<void>(onCancel: () => oldListenerCancelled = true);
      final newController = StreamController<void>(onCancel: () => newListenerCancelled = true);
      addTearDown(oldController.close);
      addTearDown(newController.close);
      final oldSubscription = oldController.stream.listen((_) {});
      final newSubscription = newController.stream.listen((_) {});
      addTearDown(oldSubscription.cancel);
      addTearDown(newSubscription.cancel);
      fixture.service.subscriptions['fg-test'] = oldSubscription;

      final closeOperation = fixture.service.closeFront();
      await enteredProbe.future.timeout(const Duration(seconds: 1));
      final resumedClient = _TrackingCoreClient();
      fixture.additionalClients.add(resumedClient);
      fixture.core.fgClient = resumedClient;
      fixture.service.subscriptions['fg-test'] = newSubscription;
      fixture.service.recordAppResume();
      fixture.publishStarted();
      barrier.complete();

      await closeOperation;
      await Future<void>.delayed(Duration.zero);

      expect(fixture.events.whereType<CoreStopped>(), isEmpty);
      expect(fixture.service.currentState, isA<CoreStarted>());
      expect(oldListenerCancelled, isTrue);
      expect(newListenerCancelled, isFalse);
      expect(identical(fixture.service.subscriptions['fg-test'], newSubscription), isTrue);
      expect(fixture.initialForegroundClient.closeCalls, 2);
      expect(resumedClient.closeCalls, 0);
    });

    test('generation replacement makes the old closeFront unable to publish', () async {
      final barrier = Completer<void>();
      final enteredProbe = Completer<void>();
      final fixture = _CloseFrontFixture(PortProbeOutcome.closed, probeBarrier: barrier, onProbeEntered: enteredProbe);
      addTearDown(fixture.close);
      fixture.publishStarted();
      fixture.events.clear();

      final closeOperation = fixture.service.closeFront();
      await enteredProbe.future.timeout(const Duration(seconds: 1));
      fixture.service.beginVpnOperation('replacement');
      fixture.events.clear();
      barrier.complete();
      await closeOperation;
      await Future<void>.delayed(Duration.zero);

      expect(fixture.events.whereType<CoreStopped>(), isEmpty);
      expect(fixture.service.currentState, isA<CoreStarting>());
    });

    test('ordinary explicit stop still reaches Stopped', () async {
      final fixture = _CloseFrontFixture(PortProbeOutcome.connected);
      addTearDown(fixture.close);
      fixture.publishStarted();

      final result = await fixture.service.stop().run();

      expect(result.isRight(), isTrue);
      expect(fixture.core.nativeStopCalls, 1);
      expect(fixture.service.currentState, isA<CoreStopped>());
    });
  });

  group('mobile background port probe diagnostics', () {
    test('the probe that determines true emits one connected observation', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var acceptedConnections = 0;
      final accepted = Completer<void>();
      final subscription = server.listen((socket) async {
        acceptedConnections++;
        await socket.close();
        if (!accepted.isCompleted) accepted.complete();
      });
      PortProbeObservation? observation;

      try {
        final active = await isPortOpen(
          InternetAddress.loopbackIPv4.address,
          server.port,
          onObservation: (value) => observation = value,
        );
        await accepted.future.timeout(const Duration(seconds: 1));

        expect(active, isTrue);
        expect(acceptedConnections, 1);
        expect(observation?.outcome, PortProbeOutcome.connected);
        expect(
          closeFrontBackgroundState(singleChannel: false, backgroundActive: active, observation: observation),
          CloseFrontBackgroundState.active,
        );
      } finally {
        await subscription.cancel();
        await server.close();
      }
    });

    test('connection refused is categorized as closed without exposing its message', () {
      const error = SocketException('environment-specific text', osError: OSError('refused', 111));

      expect(classifySocketProbeError(error), PortProbeOutcome.closed);
    });

    test('timeout socket codes remain distinct from other socket errors', () {
      const timeout = SocketException('opaque', osError: OSError('timeout', 110));
      const other = SocketException('opaque', osError: OSError('other', 12345));

      expect(classifySocketProbeError(timeout), PortProbeOutcome.timeout);
      expect(classifySocketProbeError(other), PortProbeOutcome.socketError);
    });
  });
}

CloseFrontPublicationDecision _decision({
  required PortProbeOutcome outcome,
  bool operationCurrent = true,
  bool nativeProvesConnected = false,
  bool lifecycleIntentReserved = false,
}) => classifyCloseFrontPublication(
  operationCurrent: operationCurrent,
  backgroundState: closeFrontBackgroundState(
    singleChannel: false,
    backgroundActive: outcome == PortProbeOutcome.connected,
    observation: PortProbeObservation(outcome),
  ),
  nativeProvesConnected: nativeProvesConnected,
  lifecycleIntentReserved: lifecycleIntentReserved,
  currentStatus: const CoreStatus.started(),
);

class _CloseFrontFixture {
  _CloseFrontFixture(
    PortProbeOutcome outcome, {
    VpnSessionSnapshot? nativeSnapshot,
    Completer<void>? probeBarrier,
    Completer<void>? onProbeEntered,
  }) : core = _CloseFrontCoreInterface(
         outcome,
         nativeSnapshot: nativeSnapshot,
         probeBarrier: probeBarrier,
         onProbeEntered: onProbeEntered,
       ),
       container = ProviderContainer() {
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    service = container.read(provider);
    subscription = service.statusController.listen(events.add);
    initialForegroundClient = core.fgClient as _TrackingCoreClient;
  }

  final _CloseFrontCoreInterface core;
  final ProviderContainer container;
  late final ZeonCoreService service;
  late final StreamSubscription<CoreStatus> subscription;
  late final _TrackingCoreClient initialForegroundClient;
  final List<_TrackingCoreClient> additionalClients = [];
  final List<CoreStatus> events = [];

  void publishStarted() {
    service.currentState = const CoreStatus.started();
    service.statusController.add(service.currentState);
  }

  Future<void> close() async {
    await subscription.cancel();
    container.dispose();
    await core.close();
    for (final client in additionalClients) {
      await client.shutdown();
    }
  }
}

class _CloseFrontCoreInterface extends CoreInterface {
  _CloseFrontCoreInterface(this.outcome, {this.nativeSnapshot, this.probeBarrier, this.onProbeEntered}) {
    fgClient = initialForegroundClient = _TrackingCoreClient();
    bgClient = initialBackgroundClient = _TrackingCoreClient();
  }

  final PortProbeOutcome outcome;
  VpnSessionSnapshot? nativeSnapshot;
  final Completer<void>? probeBarrier;
  final Completer<void>? onProbeEntered;
  late final _TrackingCoreClient initialForegroundClient;
  late final _TrackingCoreClient initialBackgroundClient;
  int nativeStopCalls = 0;

  @override
  VpnSessionSnapshot? get authoritativeSessionSnapshot => nativeSnapshot;

  @override
  Future<bool> isActiveBg({PortProbeObserver? onPortProbe}) async {
    if (onProbeEntered != null && !onProbeEntered!.isCompleted) onProbeEntered!.complete();
    await probeBarrier?.future;
    onPortProbe?.call(PortProbeObservation(outcome));
    return outcome == PortProbeOutcome.connected;
  }

  @override
  Future<bool> stop({int generation = 0}) async {
    nativeStopCalls++;
    return true;
  }

  Future<void> close() async {
    await initialForegroundClient.shutdown();
    await initialBackgroundClient.shutdown();
  }
}

class _TrackingCoreClient extends CoreClient {
  factory _TrackingCoreClient() {
    final channel = ClientChannel(
      InternetAddress.loopbackIPv4.address,
      port: 1,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    return _TrackingCoreClient._(channel);
  }

  _TrackingCoreClient._(this.channel) : super(channel);

  final ClientChannel channel;
  int closeCalls = 0;

  @override
  ResponseFuture<Empty> close(CloseRequest request, {CallOptions? options}) {
    closeCalls++;
    throw StateError('test close');
  }

  @override
  ResponseFuture<SystemInfo> getSystemInfo(Empty request, {CallOptions? options}) {
    throw StateError('test system info unavailable');
  }

  @override
  ResponseFuture<CoreInfoResponse> stop(Empty request, {CallOptions? options}) {
    throw StateError('test grpc stop unavailable');
  }

  Future<void> shutdown() => channel.shutdown();
}

VpnSessionSnapshot _connectedSnapshot(int generation) => VpnSessionSnapshot(
  generation: generation,
  runtimeEpoch: 'close-front-runtime',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: VpnSessionPhase.connected,
  requestedAction: 'connect',
  coreReady: true,
  coreStarted: true,
  commandEndpointReady: true,
  tunnelReady: true,
  protectSucceeded: true,
  platformVpnValidated: true,
  selectedOutboundId: 'selected',
);
