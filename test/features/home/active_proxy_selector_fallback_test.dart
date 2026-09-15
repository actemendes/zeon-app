import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/data/proxy_data_providers.dart';
import 'package:zeon/features/proxy/data/proxy_repository.dart';
import 'package:zeon/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:zeon/features/proxy/model/proxy_failure.dart';
import 'package:zeon/features/stats/data/stats_data_providers.dart';
import 'package:zeon/features/stats/data/stats_repository.dart';
import 'package:zeon/features/stats/model/stats_failure.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  test('selector snapshot resolves Home when the active stream has not emitted', () async {
    final repository = _SelectorFirstProxyRepository();
    final container = ProviderContainer(
      overrides: [
        proxyRepositoryProvider.overrideWithValue(repository),
        statsRepositoryProvider.overrideWithValue(const _SilentStatsRepository()),
        serviceRunningProvider.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);

    final subscription = container.listen(activeProxyNotifierProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    final result = await container.read(activeProxyNotifierProvider.future).timeout(const Duration(seconds: 2));

    expect(repository.activeStreamEmitted, isFalse);
    expect(result.tag, 'server-a');
    expect(result.tagDisplay, 'Server A');
  });
}

class _SelectorFirstProxyRepository implements ProxyRepository {
  bool activeStreamEmitted = false;

  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() async* {
    await Completer<void>().future;
    activeStreamEmitted = true;
    yield right(const <OutboundGroup>[]);
  }

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => Stream.value(
    right(
      OutboundGroup(
        tag: 'select',
        type: 'selector',
        selected: 'server-a',
        items: [
          OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isSelected: true, isVisible: true),
        ],
      ),
    ),
  );

  @override
  TaskEither<ProxyFailure, oldipinfo.IpInfo> getCurrentIpInfo(CancelToken cancelToken) =>
      TaskEither.left(const ProxyUnexpectedFailure('unused', StackTrace.empty));

  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) => TaskEither.right(unit);

  @override
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag) => TaskEither.right(unit);
}

class _SilentStatsRepository implements StatsRepository {
  const _SilentStatsRepository();

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() => const Stream.empty();
}
