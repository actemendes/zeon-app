import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/data/proxy_data_providers.dart';
import 'package:zeon/features/proxy/data/proxy_repository.dart';
import 'package:zeon/features/proxy/data/proxy_selection_persistence.dart';
import 'package:zeon/features/proxy/model/proxy_failure.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/stats/data/stats_data_providers.dart';
import 'package:zeon/features/stats/data/stats_repository.dart';
import 'package:zeon/features/stats/model/stats_failure.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('offline choice survives provider restart without calling the stopped core', () async {
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
    final preferences = await SharedPreferences.getInstance();
    final repository = _RejectingRepository();
    final group = (await repository.watchProxies().first).getOrElse((_) => null)!;
    await ProxySelectionPersistence(preferences).writeGroupSnapshot(group);
    ProviderContainer createContainer() => ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) async => preferences),
        proxyRepositoryProvider.overrideWithValue(repository),
        serviceRunningProvider.overrideWith((ref) async => false),
      ],
    );
    final first = createContainer();
    await first.read(sharedPreferencesProvider.future);
    final subscription = first.listen(proxiesOverviewNotifierProvider, (_, __) {});
    await first.read(proxiesOverviewNotifierProvider.future);
    await first.read(proxiesOverviewNotifierProvider.notifier).changeProxy('select', 'server-b');
    expect(repository.calls, 0);
    expect(ProxySelectionPersistence(preferences).readPending()?.outboundTag, 'server-b');
    subscription.close();
    first.dispose();
    final restarted = createContainer();
    addTearDown(restarted.dispose);
    await restarted.read(sharedPreferencesProvider.future);
    final restored = await restarted.read(proxiesOverviewNotifierProvider.future);
    expect(restored?.selected, 'server-b');
    expect(repository.calls, 0);
  });
  test('a rejected live selection must not replace the runtime-confirmed server', () async {
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
    final preferences = await SharedPreferences.getInstance();
    final repository = _RejectingRepository();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) async => preferences),
        proxyRepositoryProvider.overrideWithValue(repository),
        statsRepositoryProvider.overrideWithValue(_Stats()),
        serviceRunningProvider.overrideWith((ref) async => true),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    final sub = container.listen(proxiesOverviewNotifierProvider, (_, __) {});
    addTearDown(sub.close);
    final initial = await container.read(proxiesOverviewNotifierProvider.future);
    expect(initial!.selected, 'server-a');
    Object? rejection;
    try {
      await container.read(proxiesOverviewNotifierProvider.notifier).changeProxy('select', 'server-b');
    } catch (error) {
      rejection = error;
    }
    expect(repository.calls, 1);
    expect(
      container.read(proxiesOverviewNotifierProvider).requireValue!.selected,
      'server-a',
      reason: 'runtime rejected server-b and remains on server-a',
    );
    expect(rejection, isNotNull, reason: 'the caller must observe the failed live selection');
    expect(
      ProxySelectionPersistence(preferences).readPending(),
      isNull,
      reason: 'a rejected live choice must not be silently applied on the next startup',
    );
  });
}

class _RejectingRepository implements ProxyRepository {
  int calls = 0;
  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => Stream.value(
    right(
      OutboundGroup(
        tag: 'select',
        type: 'selector',
        selected: 'server-a',
        items: [
          OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isSelected: true, isVisible: true),
          OutboundInfo(tag: 'server-b', tagDisplay: 'Server B', type: 'proxy', isVisible: true),
        ],
      ),
    ),
  );
  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) {
    calls++;
    return TaskEither.left(const ProxyUnexpectedFailure('core rejected selection'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stats implements StatsRepository {
  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() => const Stream.empty();
}
