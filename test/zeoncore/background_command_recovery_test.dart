import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

class _DualChannelCore extends CoreInterface {
  _DualChannelCore(this.primary, this.fallback) {
    fgClient = fallback;
    bgClient = fallback;
  }

  final CoreClient primary;
  final CoreClient fallback;

  @override
  CoreClient get backgroundCommandClient => primary;
}

void main() {
  late ClientChannel primaryChannel;
  late ClientChannel fallbackChannel;
  late CoreClient primary;
  late CoreClient fallback;
  late ProviderContainer container;
  late ZeonCoreService service;

  setUp(() {
    primaryChannel = ClientChannel(
      '127.0.0.1',
      port: 1,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    fallbackChannel = ClientChannel(
      '127.0.0.1',
      port: 2,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    primary = CoreClient(primaryChannel);
    fallback = CoreClient(fallbackChannel);
    container = ProviderContainer();
    final serviceProvider = Provider(
      (ref) => ZeonCoreService(ref, coreInterface: _DualChannelCore(primary, fallback), isWindows: true),
    );
    service = container.read(serviceProvider)..currentState = const CoreStatus.started();
  });

  tearDown(() async {
    container.dispose();
    await primaryChannel.terminate();
    await fallbackChannel.terminate();
  });

  test('transient command HTTP2 failure retries on independent background channel', () async {
    final clients = <CoreClient>[];
    final retries = <int>[];

    final result = await service.runBackgroundCommandWithRecovery<int>('test snapshot', (client) async {
      clients.add(client);
      if (identical(client, primary)) {
        throw const GrpcError.unknown('HTTP/2 connection is being forcefully terminated');
      }
      return 42;
    }, onRetry: (attempt, _) => retries.add(attempt));

    expect(result, 42);
    expect(clients, <CoreClient>[primary, fallback]);
    expect(retries, <int>[1]);
  });

  test('non-transient command error is not retried', () async {
    var calls = 0;

    await expectLater(
      service.runBackgroundCommandWithRecovery<void>('test snapshot', (_) {
        calls++;
        return Future<void>.error(const GrpcError.permissionDenied('denied'));
      }),
      throwsA(isA<GrpcError>().having((error) => error.code, 'code', StatusCode.permissionDenied)),
    );
    expect(calls, 1);
  });
}
