import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  test('snapshot stream survives an initial resync failure', () async {
    final source = _FailingInitialResyncSource();
    final container = ProviderContainer(overrides: [vpnSessionSnapshotSourceProvider.overrideWithValue(source)]);
    addTearDown(() async {
      container.dispose();
      await source.dispose();
    });
    final values = <AsyncValue<VpnSessionSnapshot>>[];
    final subscription = container.listen(
      mainVpnSessionSnapshotProvider,
      (_, next) => values.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await source.watching;
    source.emit(_snapshot());
    await _eventually(() => values.any((value) => value.valueOrNull?.phase == VpnSessionPhase.connected));

    expect(values.where((value) => value.hasError), isEmpty);
  });
}

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20 && !predicate(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

final class _FailingInitialResyncSource implements VpnSessionSnapshotSource {
  final _events = StreamController<VpnSessionSnapshot>();
  final _watching = Completer<void>();

  Future<void> get watching => _watching.future;

  @override
  VpnSessionSnapshot? get current => null;

  @override
  Future<VpnSessionSnapshot?> resync(String source) => Future.error(TimeoutException('test resync timeout'));

  @override
  Stream<VpnSessionSnapshot> watch() {
    if (!_watching.isCompleted) _watching.complete();
    return _events.stream;
  }

  void emit(VpnSessionSnapshot snapshot) => _events.add(snapshot);

  Future<void> dispose() => _events.close();
}

VpnSessionSnapshot _snapshot() => const VpnSessionSnapshot(
  generation: 7,
  runtimeEpoch: 'provider-test-runtime',
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
  selectedOutboundId: 'proxy-1',
);
