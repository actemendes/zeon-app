import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_desktop.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';

class _StateService extends Service {
  CoreStates state = CoreStates.STOPPED;
  bool unavailable = false;
  Completer<void>? stopBarrier;

  @override
  String get $name => 'hcore.Core';

  _StateService() {
    $addMethod(
      ServiceMethod<Empty, CoreInfoResponse>(
        'Stop',
        _stop,
        false,
        false,
        Empty.fromBuffer,
        (response) => response.writeToBuffer(),
      ),
    );
    $addMethod(
      ServiceMethod<Empty, CoreInfoResponse>(
        'CoreInfoListener',
        _listen,
        false,
        true,
        Empty.fromBuffer,
        (response) => response.writeToBuffer(),
      ),
    );
  }

  Future<CoreInfoResponse> _stop(ServiceCall call, Future<Empty> request) async {
    await request;
    await stopBarrier?.future;
    return CoreInfoResponse(coreState: state, messageType: MessageType.EMPTY);
  }

  Stream<CoreInfoResponse> _listen(ServiceCall call, Future<Empty> request) async* {
    await request;
    if (unavailable) throw const GrpcError.unavailable('test core unavailable');
    // The native endpoint stays subscribed until the client cancels.
    final updates = StreamController<CoreInfoResponse>();
    try {
      yield CoreInfoResponse(coreState: state, messageType: MessageType.EMPTY);
      yield* updates.stream;
    } finally {
      await updates.close();
    }
  }
}

void main() {
  late _StateService service;
  late Server server;
  late ClientChannel channel;
  late CoreInterfaceDesktop desktop;

  setUp(() async {
    service = _StateService();
    server = Server.create(services: [service]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    desktop = CoreInterfaceDesktop()..bgClient = CoreClient(channel);
    await desktop.setSessionGeneration(1);
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
  });

  test('native startup is not reported as stopped before the start acknowledgement', () async {
    service.state = CoreStates.STARTING;
    expect(await desktop.resyncSessionStatus(), isA<CoreStarting>());
    service.state = CoreStates.STARTED;
    expect(await desktop.resyncSessionStatus(), isA<CoreStarted>());
  });

  test('desktop stop waits for native acknowledgement and rejects nonterminal response', () async {
    service.state = CoreStates.STARTING;
    service.stopBarrier = Completer<void>();
    var completed = false;
    final pending = desktop.stop(generation: 2).then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, isFalse);
    service.stopBarrier!.complete();
    expect(await pending, isFalse);
    service.state = CoreStates.STOPPED;
    expect(await desktop.stop(generation: 2), isTrue);
  });

  test('native stop supersedes a previously acknowledged start', () async {
    await desktop.markCoreStarted(1);
    service.state = CoreStates.STOPPING;
    expect(await desktop.resyncSessionStatus(), isA<CoreStopping>());
    service.state = CoreStates.STOPPED;
    expect(await desktop.resyncSessionStatus(), isA<CoreStopped>());
  });

  test('unavailable native state is inconclusive rather than cached connected', () async {
    await desktop.markCoreStarted(1);
    service.unavailable = true;
    expect(await desktop.resyncSessionStatus(), isNull);
  });

  test('unresponsive telemetry transport cannot block stop or terminal confirmation', () async {
    // Accept TCP but never answer HTTP/2: the old telemetry connection remains
    // open, so socket liveness cannot establish that it can deliver a command.
    final silentServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final accepted = silentServer.listen(sockets.add);
    final telemetry = ClientChannel(
      '127.0.0.1',
      port: silentServer.port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    addTearDown(() async {
      await telemetry.terminate();
      for (final socket in sockets) {
        socket.destroy();
      }
      await accepted.cancel();
      await silentServer.close();
    });
    desktop = CoreInterfaceDesktop(commandClient: CoreClient(channel))..bgClient = CoreClient(telemetry);
    await desktop.setSessionGeneration(1);
    await expectLater(
      desktop.bgClient.coreInfoListener(Empty(), options: CallOptions(timeout: const Duration(milliseconds: 50))).first,
      throwsA(isA<GrpcError>().having((error) => error.code, 'code', StatusCode.deadlineExceeded)),
    );
    service.state = CoreStates.STOPPING;
    expect(await desktop.resyncSessionStatus(), isA<CoreStopping>());
    service.stopBarrier = Completer<void>();
    var terminal = false;
    final stop = desktop.stop(generation: 2).then((value) => terminal = value);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(terminal, isFalse);
    service.state = CoreStates.STOPPED;
    service.stopBarrier!.complete();
    expect(await stop, isTrue);
    expect(await desktop.resyncSessionStatus(), isA<CoreStopped>());
  });
}
