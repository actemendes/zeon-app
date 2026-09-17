import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

final _snapshot = StateProvider<AsyncValue<VpnSessionSnapshot>>((ref) => const AsyncLoading());

void main() {
  test('surviving native VPN opens live streams despite disconnected Flutter state', () async {
    final container = _container(const Disconnected());
    addTearDown(container.dispose);
    expect(await container.read(serviceRunningProvider.future), isFalse);
    container.read(_snapshot.notifier).state = AsyncData(_connected());
    expect(await container.read(serviceRunningProvider.future), isTrue);

    // Selected leaf/statistics updates must not recreate the data streams.
    final runningFuture = container.read(serviceRunningProvider.future);
    container.read(_snapshot.notifier).state = AsyncData(_connected(label: 'Server B'));
    expect(container.read(serviceRunningProvider.future), same(runningFuture));
  });

  test('native stop wins over stale connected Flutter state', () async {
    final container = _container(const Connected());
    addTearDown(container.dispose);
    container.read(_snapshot.notifier).state = AsyncData(_connected());
    expect(await container.read(serviceRunningProvider.future), isTrue);
    container.read(_snapshot.notifier).state = AsyncData(_connected(phase: VpnSessionPhase.disconnected));
    expect(await container.read(serviceRunningProvider.future), isFalse);
  });

  test('unknown, verifying and unproven native sessions keep live streams closed', () async {
    final container = _container(const Connected());
    addTearDown(container.dispose);
    expect(await container.read(serviceRunningProvider.future), isFalse);
    container.read(_snapshot.notifier).state = AsyncData(_connected(phase: VpnSessionPhase.verifying));
    expect(await container.read(serviceRunningProvider.future), isFalse);
    container.read(_snapshot.notifier).state = AsyncData(_connected(ready: false));
    expect(await container.read(serviceRunningProvider.future), isFalse);
  });

  for (final status in [const Connected(), const Disconnected()]) {
    test('non-Android keeps legacy service state $status', () async {
      final container = ProviderContainer(
        overrides: [
          nativeVpnSessionSnapshotProvider.overrideWithValue(null),
          connectionNotifierProvider.overrideWith(() => _Connection(status)),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(serviceRunningProvider.future), status is Connected);
    });
  }
}

ProviderContainer _container(ConnectionStatus status) => ProviderContainer(
  overrides: [
    nativeVpnSessionSnapshotProvider.overrideWith((ref) => ref.watch(_snapshot)),
    connectionNotifierProvider.overrideWith(() => _Connection(status)),
  ],
);

class _Connection extends ConnectionNotifier {
  _Connection(this.status);
  final ConnectionStatus status;
  @override
  Stream<ConnectionStatus> build() => Stream.value(status);
}

VpnSessionSnapshot _connected({
  String label = 'Server A',
  VpnSessionPhase phase = VpnSessionPhase.connected,
  bool ready = true,
}) => VpnSessionSnapshot(
  generation: 1,
  runtimeEpoch: 'native',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: phase,
  coreReady: ready,
  coreStarted: ready,
  commandEndpointReady: ready,
  tunnelReady: ready,
  protectSucceeded: ready,
  selectedOutboundId: 'opaque-id',
  selectedOutboundLabel: label,
);
