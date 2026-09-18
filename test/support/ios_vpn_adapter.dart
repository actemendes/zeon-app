import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

/// Test-only replacement at the production repository boundary. No sockets,
/// native channels, credentials or real VPN operations are reachable here.
class IosVpnAdapter implements ConnectionRepository, VpnSessionSnapshotSource {
  final _statuses = StreamController<ConnectionStatus>.broadcast();
  final _snapshots = StreamController<VpnSessionSnapshot>.broadcast();
  ConnectionStatus status = const Disconnected();
  int generation = 0;
  int sequence = 0;
  int connects = 0;
  int stops = 0;
  Completer<void>? startBarrier;
  ConnectionFailure? nextFailure;
  final profiles = <String>[];

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  VpnSessionSnapshot get current => VpnSessionSnapshot(
    generation: generation,
    runtimeEpoch: 'ios-simulator-fixture',
    sequenceNumber: sequence,
    snapshotVersion: sequence,
    phase: switch (status) {
      Connected() => VpnSessionPhase.connected,
      Connecting() => VpnSessionPhase.startingCore,
      Disconnecting() => VpnSessionPhase.stopping,
      _ => VpnSessionPhase.disconnected,
    },
    requestedAction: status is Disconnected ? 'stop' : 'connect',
    recoverable: true,
  );

  void emit(ConnectionStatus next) {
    status = next;
    sequence++;
    _statuses.add(next);
    _snapshots.add(current);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() async* {
    yield status;
    yield* _statuses.stream;
  }

  @override
  Stream<VpnSessionSnapshot> watch() => _snapshots.stream;
  @override
  Future<VpnSessionSnapshot?> resync(String source) async => current;
  @override
  Future<ConnectionStatus?> resyncConnectionStatus(String source) async => status;
  @override
  TaskEither<ConnectionFailure, Unit> setup() => TaskEither.of(unit);
  @override
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      TaskEither.of(unit);

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      TaskEither(() async {
        final owner = ++generation;
        connects++;
        profiles.add(activeProfile.id);
        emit(const Connecting());
        final barrier = startBarrier;
        if (barrier != null) await barrier.future;
        if (owner != generation) return right(unit);
        final failure = nextFailure;
        nextFailure = null;
        if (failure != null) {
          emit(const Disconnected());
          return left(failure);
        }
        emit(const Connected());
        return right(unit);
      });

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => TaskEither(() async {
    generation++;
    stops++;
    emit(const Disconnecting());
    emit(const Disconnected());
    return right(unit);
  });

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(
    ProfileEntity activeProfile,
    bool disableMemoryLimit, {
    String source = 'reconnect',
  }) => disconnect().flatMap((_) => connect(activeProfile, disableMemoryLimit));

  Future<void> dispose() async {
    if (startBarrier case final barrier? when !barrier.isCompleted) barrier.complete();
    await _statuses.close();
    await _snapshots.close();
  }
}
