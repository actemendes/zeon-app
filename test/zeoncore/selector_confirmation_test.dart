import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' hide Response;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

class _SelectorService extends Service {
  bool apply = true;
  bool reject = false;
  bool snapshotUnavailable = false;
  String selected = 'old';
  int requests = 0;
  int snapshots = 0;

  @override
  String get $name => 'hcore.Core';

  _SelectorService() {
    $addMethod(
      ServiceMethod<SelectOutboundRequest, Response>(
        'SelectOutbound',
        _select,
        false,
        false,
        SelectOutboundRequest.fromBuffer,
        (value) => value.writeToBuffer(),
      ),
    );
    $addMethod(
      ServiceMethod<Empty, OutboundGroupList>(
        'OutboundsInfo',
        _snapshot,
        false,
        true,
        Empty.fromBuffer,
        (value) => value.writeToBuffer(),
      ),
    );
  }

  Future<Response> _select(ServiceCall call, Future<SelectOutboundRequest> request) async {
    final selection = await request;
    requests++;
    if (reject) return Response(code: ResponseCode.FAILED, message: 'rejected');
    if (apply) selected = selection.outboundTag;
    // Native commit can happen before the reply deadline expires.
    throw const GrpcError.deadlineExceeded('reply lost after native selection');
  }

  Stream<OutboundGroupList> _snapshot(ServiceCall call, Future<Empty> request) async* {
    await request;
    snapshots++;
    if (snapshotUnavailable) throw const GrpcError.unavailable('snapshot unavailable');
    final updates = StreamController<OutboundGroupList>();
    try {
      yield OutboundGroupList(
        items: [OutboundGroup(tag: 'select', selected: selected)],
      );
      yield* updates.stream;
    } finally {
      await updates.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SelectorService native;
  late Server server;
  late ClientChannel channel;
  late ProviderContainer container;
  late ZeonCoreService service;

  setUp(() async {
    native = _SelectorService();
    server = Server.create(services: [native]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final core = CoreInterface()..bgClient = CoreClient(channel);
    container = ProviderContainer();
    service = container.read(Provider((ref) => ZeonCoreService(ref, coreInterface: core)));
  });

  tearDown(() async {
    container.dispose();
    await channel.shutdown();
    await server.shutdown();
  });

  test('lost selection reply is confirmed from actual native selector without retry', () async {
    final result = await service.selectOutbound('select', 'new').run();
    expect(result.isRight(), isTrue);
    expect(native.requests, 1);
    expect(native.snapshots, 1);
  });

  test('timeout before native apply remains a failure', () async {
    native.apply = false;
    await expectLater(service.selectOutbound('select', 'new').run(), throwsA(isA<GrpcError>()));
    expect(native.selected, 'old');
    expect(native.requests, 1);
  });

  test('unavailable confirmation cannot turn timeout into success', () async {
    native.snapshotUnavailable = true;
    await expectLater(service.selectOutbound('select', 'new').run(), throwsA(isA<GrpcError>()));
    expect(native.requests, 1);
  });

  test('explicit native rejection is not overridden by a snapshot', () async {
    native.reject = true;
    native.selected = 'new';
    expect((await service.selectOutbound('select', 'new').run()).isLeft(), isTrue);
    expect(native.snapshots, 0);
  });
}
