import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/data/proxy_data_providers.dart';
import 'package:zeon/features/proxy/data/proxy_repository.dart';
import 'package:zeon/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:zeon/features/proxy/model/proxy_failure.dart';
import 'package:zeon/features/stats/data/stats_data_providers.dart';
import 'package:zeon/features/stats/data/stats_repository.dart';
import 'package:zeon/features/stats/model/stats_failure.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  test('selector snapshot resolves Home even when active stream has not emitted', () async {
    final repository = _SelectorFirstProxyRepository();
    final container = ProviderContainer(
      overrides: [
        proxyRepositoryProvider.overrideWithValue(repository),
        statsRepositoryProvider.overrideWithValue(const _SilentStatsRepository()),
        serviceRunningProvider.overrideWith((ref) => Future.value(true)),
        activeProfileProvider.overrideWith(() => _NoActiveProfile()),
        vpnSessionSnapshotSourceProvider.overrideWithValue(const _SnapshotSource()),
      ],
    );
    addTearDown(container.dispose);

    final subscription = container.listen(activeProxyNotifierProvider, (previous, next) {}, fireImmediately: true);
    addTearDown(subscription.close);

    final result = await container.read(activeProxyNotifierProvider.future).timeout(const Duration(seconds: 2));

    expect(repository.activeStreamEmitted, isFalse);
    expect(result.tag, 'server-stable-id');
    expect(result.tagDisplay, 'Test Server');
  });

  test('refresh replaces, removes, and temporarily loses a selection without hiding Home', () async {
    final repository = _RefreshingProxyRepository();
    final container = ProviderContainer(
      overrides: [
        proxyRepositoryProvider.overrideWithValue(repository),
        statsRepositoryProvider.overrideWithValue(const _SilentStatsRepository()),
        serviceRunningProvider.overrideWith((ref) => Future.value(true)),
        activeProfileProvider.overrideWith(() => _NoActiveProfile()),
        vpnSessionSnapshotSourceProvider.overrideWithValue(const _SnapshotSource()),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(repository.dispose);

    final observed = <String>[];
    final subscription = container.listen(activeProxyNotifierProvider, (previous, next) {
      final tag = next.valueOrNull?.tag;
      if (tag != null) observed.add(tag);
    }, fireImmediately: true);
    addTearDown(subscription.close);

    repository.publish(_selectorGroup(selected: 'server-a', servers: const ['server-a', 'server-b']));
    await _waitFor(() => observed.isNotEmpty && observed.last == 'server-a');

    repository.publish(_selectorGroup(selected: 'server-b', servers: const ['server-a', 'server-b']));
    await _waitFor(() => observed.isNotEmpty && observed.last == 'server-b');

    // A removed persisted selection falls back deterministically to a valid
    // visible leaf instead of leaving the picker unresolved.
    repository.publish(_selectorGroup(selected: 'deleted-server', servers: const ['server-b']));
    await _waitFor(() => observed.isNotEmpty && observed.last == 'server-b');

    // A temporary refresh error/null snapshot keeps the in-memory LKG.
    repository.publishFailure();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(activeProxyNotifierProvider).valueOrNull?.tag, 'server-b');
  });
}

OutboundGroup _selectorGroup({required String selected, required List<String> servers}) => OutboundGroup(
  tag: 'select',
  type: 'selector',
  selected: selected,
  items: [
    for (final server in servers)
      OutboundInfo(tag: server, tagDisplay: server, type: 'proxy', isSelected: server == selected, isVisible: true),
  ],
);

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('server-picker provider did not publish');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
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
        selected: 'server-stable-id',
        items: [
          OutboundInfo(
            tag: 'server-stable-id',
            tagDisplay: 'Test Server',
            type: 'proxy',
            isSelected: true,
            isVisible: true,
          ),
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

class _RefreshingProxyRepository implements ProxyRepository {
  final _selector = StreamController<Either<ProxyFailure, OutboundGroup?>>();

  void publish(OutboundGroup group) => _selector.add(right(group));

  void publishFailure() => _selector.add(left(const ProxyUnexpectedFailure('refresh failed')));

  Future<void> dispose() => _selector.close();

  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() => const Stream.empty();

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => _selector.stream;

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

class _NoActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class _SnapshotSource implements VpnSessionSnapshotSource {
  const _SnapshotSource();

  static const snapshot = VpnSessionSnapshot(
    generation: 14,
    runtimeEpoch: 'picker-regression',
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
    selectedOutboundId: 'server-stable-id',
  );

  @override
  VpnSessionSnapshot get current => snapshot;

  @override
  Future<VpnSessionSnapshot> resync(String source) async => snapshot;

  @override
  Stream<VpnSessionSnapshot> watch() => Stream.value(snapshot);
}
