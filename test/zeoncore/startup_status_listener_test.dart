import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  late _StatusEndpoint endpoint;
  late Server server;
  late ClientChannel channel;
  late ProviderContainer container;
  late ZeonCoreService service;
  late CoreInterface core;
  late StreamSubscription<CoreStatus> subscription;
  late List<CoreStatus> events;

  setUp(() async {
    endpoint = _StatusEndpoint();
    server = Server.create(services: [endpoint]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    // Distinct clients reproduce the iOS foreground/background ownership.
    core = CoreInterface()
      ..fgClient = CoreClient(channel)
      ..bgClient = CoreClient(channel);
    container = ProviderContainer();
    service = container.read(Provider((ref) => ZeonCoreService(ref, coreInterface: core)));
    events = [];
    subscription = service.statusController.listen(events.add);
  });

  tearDown(() async {
    await service.stopListenSingle('bgStatusListener');
    await subscription.cancel();
    container.dispose();
    await channel.terminate();
    await server.shutdown();
    await endpoint.updates.close();
    await service.statusController.close();
  });

  Future<void> listen({bool beforeCoreStart = true}) async {
    await service.startListeningStatus('bg', core.bgClient, beforeCoreStart: beforeCoreStart);
    await endpoint.listening.future.timeout(const Duration(seconds: 2));
  }

  Future<CoreStatus> send(CoreStates state, bool Function(CoreStatus) matches) {
    final received = service.statusController.stream.skip(1).firstWhere(matches);
    endpoint.updates.add(CoreInfoResponse(coreState: state, messageType: MessageType.EMPTY));
    return received.timeout(const Duration(seconds: 2));
  }

  test('dual-channel startup ignores initial daemon STOPPED without reversing the UI', () async {
    service.beginVpnOperation('connect');
    await listen();
    await send(CoreStates.STARTING, (status) => status is CoreStarting);
    expect(events.whereType<CoreStopped>(), isEmpty);
    expect(service.currentState, isA<CoreStarting>());
  });

  test('initial STOPPED carrying a startup error is published', () async {
    endpoint.initial = CoreInfoResponse(coreState: CoreStates.STOPPED, messageType: MessageType.START_SERVICE);
    service.beginVpnOperation('connect');
    final failed = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    await listen();
    final status = await failed.timeout(const Duration(seconds: 2)) as CoreStopped;
    expect(status.alert, CoreAlert.startService);
  });

  test('a later STOPPED during startup remains terminal', () async {
    service.beginVpnOperation('connect');
    await listen();
    await send(CoreStates.STARTING, (status) => status is CoreStarting);
    await send(CoreStates.STOPPED, (status) => status is CoreStopped);
    expect(service.currentState, isA<CoreStopped>());
  });

  test('initial STOPPED without a pending start is published', () async {
    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    await listen();
    await stopped.timeout(const Duration(seconds: 2));
    expect(service.currentState, isA<CoreStopped>());
  });

  test('recovery subscription does not hide its initial STOPPED', () async {
    service.beginVpnOperation('connect');
    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    await listen(beforeCoreStart: false);
    await stopped.timeout(const Duration(seconds: 2));
    expect(service.currentState, isA<CoreStopped>());
  });

  test('initial STOPPED with a diagnostic message is not discarded', () async {
    endpoint.initial = CoreInfoResponse(
      coreState: CoreStates.STOPPED,
      messageType: MessageType.EMPTY,
      message: 'startup failed',
    );
    service.beginVpnOperation('connect');
    final stopped = service.statusController.stream.firstWhere((status) => status is CoreStopped);
    await listen();
    final status = await stopped.timeout(const Duration(seconds: 2)) as CoreStopped;
    expect(status.message, 'startup failed');
  });
}

class _StatusEndpoint extends Service {
  _StatusEndpoint() {
    $addMethod(
      ServiceMethod<Empty, CoreInfoResponse>(
        'CoreInfoListener',
        _listen,
        false,
        true,
        Empty.fromBuffer,
        (value) => value.writeToBuffer(),
      ),
    );
  }
  @override
  String get $name => 'hcore.Core';
  CoreInfoResponse initial = CoreInfoResponse(coreState: CoreStates.STOPPED, messageType: MessageType.EMPTY);
  final listening = Completer<void>();
  final updates = StreamController<CoreInfoResponse>();

  Stream<CoreInfoResponse> _listen(ServiceCall call, Future<Empty> request) async* {
    await request;
    yield initial;
    listening.complete();
    yield* updates.stream;
  }
}
