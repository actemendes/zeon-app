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
import 'package:zeon/zeoncore/generated/google/protobuf/timestamp.pb.dart';
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

  for (final (selectedStatus, otherStatus, expectedStatus) in [
    ('failed', 'checking', 'checking'),
    ('success', 'checking', 'success'),
    ('failed', 'failed', 'failed'),
  ]) {
    test('Auto projects selected $selectedStatus with other $otherStatus as $expectedStatus', () async {
      final container = ProviderContainer(
        overrides: [
          proxyRepositoryProvider.overrideWithValue(_AutoCycleProxyRepository(selectedStatus, otherStatus)),
          statsRepositoryProvider.overrideWithValue(const _SilentStatsRepository()),
          serviceRunningProvider.overrideWith((ref) => true),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(activeProxyNotifierProvider, (_, _) {}, fireImmediately: true);
      addTearDown(subscription.close);

      final result = await container.read(activeProxyNotifierProvider.future).timeout(const Duration(seconds: 2));
      expect(result.tag, 'balance');
      expect(result.groupSelectedTagDisplay, 'Server A');
      expect(result.urlTestStatus, expectedStatus);
    });
  }

  test('newer selector success wins over a stale active failure', () async {
    final repository = _AutoCycleProxyRepository(
      'success',
      'checking',
      activeStatus: 'failed',
      activeTime: DateTime.utc(2026, 9, 26, 10),
      selectorTime: DateTime.utc(2026, 9, 26, 10, 1),
    );
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
    expect(result.urlTestStatus, 'success');
  });
}

class _AutoCycleProxyRepository extends _SelectorFirstProxyRepository {
  _AutoCycleProxyRepository(
    this.selectedStatus,
    this.otherStatus, {
    this.activeStatus,
    this.activeTime,
    this.selectorTime,
  });

  final String selectedStatus;
  final String otherStatus;
  final String? activeStatus;
  final DateTime? activeTime;
  final DateTime? selectorTime;

  OutboundInfo selectedLeaf({bool active = false}) => OutboundInfo(
    tag: 'server-a',
    tagDisplay: 'Server A',
    type: 'proxy',
    isSelected: true,
    isVisible: true,
    urlTestStatus: active ? activeStatus ?? selectedStatus : selectedStatus,
    urlTestDelay: (active ? activeStatus ?? selectedStatus : selectedStatus) == 'success' ? 42 : 0,
    urlTestTime: (active ? activeTime : selectorTime) == null
        ? null
        : Timestamp.fromDateTime((active ? activeTime : selectorTime)!),
  );

  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() => Stream.value(
    right([
      OutboundGroup(
        tag: 'select',
        selected: 'balance',
        items: [OutboundInfo(tag: 'balance', tagDisplay: 'balance', type: 'balancer', isGroup: true, isSelected: true)],
      ),
      OutboundGroup(tag: 'balance', selected: 'server-a', items: [selectedLeaf(active: true)]),
    ]),
  );

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => Stream.value(
    right(
      OutboundGroup(
        tag: 'select',
        selected: 'balance',
        items: [
          OutboundInfo(tag: 'balance', tagDisplay: 'balance', type: 'balancer', isGroup: true, isSelected: true),
          selectedLeaf(),
          OutboundInfo(
            tag: 'server-b',
            tagDisplay: 'Server B',
            type: 'proxy',
            isVisible: true,
            urlTestStatus: otherStatus,
          ),
        ],
      ),
    ),
  );
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
