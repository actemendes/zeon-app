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

  @override
  String get $name => 'hcore.Core';

  _StateService() {
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
}
