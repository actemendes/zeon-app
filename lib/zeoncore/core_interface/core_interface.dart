import 'package:zeon/core/model/directories.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

enum PortProbeOutcome { connected, closed, timeout, socketError, otherError }

class PortProbeObservation {
  const PortProbeObservation(this.outcome);

  final PortProbeOutcome outcome;
}

typedef PortProbeObserver = void Function(PortProbeObservation observation);

class SessionGenerationRejectedException implements Exception {
  const SessionGenerationRejectedException({required this.requested, required this.accepted});

  final int requested;
  final int accepted;

  @override
  String toString() => 'VPN session generation rejected: requested=$requested accepted=$accepted';
}

enum BackgroundSetupFailure {
  none,
  replacementTeardown,
  controlPortClosed,
  controlPortTimeout,
  controlPortSocketError,
  controlPortOtherError,
  commandEndpointTimeout,
}

class BackgroundSetupResult {
  const BackgroundSetupResult({
    required this.generation,
    required this.status,
    this.failure = BackgroundSetupFailure.none,
    this.portProbe,
    this.nativeSnapshot,
  });

  final int generation;
  final CoreStatus status;
  final BackgroundSetupFailure failure;
  final PortProbeObservation? portProbe;
  final VpnSessionSnapshot? nativeSnapshot;

  bool get isReady => status is CoreStarting && failure == BackgroundSetupFailure.none;
}

class CoreInterface {
  late CoreClient fgClient;
  late CoreClient bgClient;

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<BackgroundSetupResult> setupBackground(String path, String name, {int generation = 0}) async {
    return BackgroundSetupResult(generation: generation, status: const CoreStarting());
  }

  Future<bool> prepareVpn(String path, String name, bool disableMemoryLimit, {int generation = 0}) async {
    return true;
  }

  Future<bool> restart(String path, String name) async {
    return false;
  }

  Future<bool> stop({int generation = 0}) async {
    return false;
  }

  /// Whether a successful [stop] result is only local bookkeeping and the
  /// shared lifecycle must first observe an authoritative terminal core
  /// status. Desktop keeps its process-owned management endpoint alive, so an
  /// open port or a local boolean cannot prove that the data plane stopped.
  bool get requiresAuthoritativeStopConfirmation => false;

  /// Starts a bounded terminal-status observation. Callers intentionally
  /// create this future before sending Stop so a fast STOPPED transition
  /// cannot be missed.
  Future<bool> waitForAuthoritativeStop({required Duration timeout}) async => false;

  /// Closes the previous platform owner without making the replacement
  /// generation terminal. Android Start/restart calls this before installing
  /// the new owner for the same generation.
  Future<bool> stopForReplacement({int generation = 0}) => stop(generation: generation);

  Future<bool> isBgClientAvailable() async {
    return true;
  }

  Future<void> setSessionGeneration(int generation) async {}

  /// Reserves a generation for permission/configuration preparation without
  /// declaring that the user has requested a live VPN connection.
  Future<void> setPreparationGeneration(int generation) => setSessionGeneration(generation);

  /// Sends the platform-owned VPN service a lightweight stop request. The
  /// caller performs slower gRPC/listener cleanup separately.
  Future<int> requestPlatformStop({required int generation}) async {
    await setSessionGeneration(generation);
    return generation;
  }

  bool get supportsPreemptivePlatformStop => false;

  Future<void> markCoreStarted(int generation) async {}

  Future<CoreStatus?> resyncSessionStatus() async => null;

  /// Highest authoritative platform generation observed while resyncing.
  /// Reading this value has no UI publication side effect.
  int get authoritativeSessionGeneration => 0;

  VpnSessionSnapshot? get authoritativeSessionSnapshot => null;

  Stream<VpnSessionSnapshot> watchSessionSnapshots() => const Stream<VpnSessionSnapshot>.empty();

  bool isSingleChannel() {
    // return true;
    return fgClient == bgClient;
  }

  Future<bool> resetTunnel() async {
    return false;
  }

  Future<bool> isActiveFg() async {
    return true;
  }

  Future<bool> isActiveBg({PortProbeObserver? onPortProbe}) async {
    return true;
  }

  bool isInitialized() {
    try {
      // ignore: unnecessary_statements
      bgClient; // touch it
      return true;
    } catch (_) {
      return false;
    }
  }
}
