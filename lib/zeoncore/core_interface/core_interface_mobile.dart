import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';
import 'package:rxdart/rxdart.dart';
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/core/utils/laststeam.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/mtls_channel_cred.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/generated/v2/hello/hello.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hello/hello_service.pbgrpc.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

class CoreInterfaceMobile extends CoreInterface with InfraLogger {
  CoreInterfaceMobile({bool? androidOverride, Future<bool> Function(String, int)? portProbe})
    : _isAndroid = androidOverride ?? Platform.isAndroid,
      // Tests use androidOverride=false to exercise the iOS bridge. At
      // runtime only Android and iOS expose authoritative session snapshots;
      // macOS still uses its legacy status channel.
      _supportsSessionSnapshots = androidOverride != null || Platform.isAndroid || Platform.isIOS,
      _portProbe = portProbe ?? isPortOpen;

  static const channelPrefix = "com.zeon.app";
  static const methodChannel = MethodChannel("$channelPrefix/method");
  static const statusChannel = EventChannel("$channelPrefix/service.status", JSONMethodCodec());
  static const alertsChannel = EventChannel("$channelPrefix/service.alerts", JSONMethodCodec());
  static const snapshotChannel = EventChannel("$channelPrefix/service.snapshot", JSONMethodCodec());

  late Uint8List serverPublicKey;
  static final cert = CryptoUtils.generateEcKeyPair();

  // Keep app-specific gRPC ports to avoid collisions with other ZEON-based apps on device.
  static const portBack = int.fromEnvironment("mobile_grpc_port_back", defaultValue: 17179);
  static const portFront = int.fromEnvironment("mobile_grpc_port_front", defaultValue: 17178);
  static const _nativeSetupTimeout = Duration(seconds: 15);
  static const _nativeControlTimeout = Duration(seconds: 10);

  bool _isBgClientAvailable = false;
  bool _debug = false;
  ClientChannel? _fgChannel;
  ClientChannel? _bgChannel;
  final bool _isAndroid;
  final bool _supportsSessionSnapshots;
  final Future<bool> Function(String, int) _portProbe;
  int _sessionGeneration = 0;
  VpnSessionSnapshot? _authoritativeSessionSnapshot;
  final VpnSessionSnapshotGate _snapshotGate = VpnSessionSnapshotGate();
  final BehaviorSubject<VpnSessionSnapshot> _sessionSnapshots = BehaviorSubject<VpnSessionSnapshot>();

  LastStream<CoreStatus>? _status;
  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    final channelOption = [1, 2].contains(mode)
        ? MTLSChannelCredentials(serverPublicKey: serverPublicKey, clientKey: cert)
        : const ChannelCredentials.insecure();
    _debug = debug;
    final helloChannel = ClientChannel(
      '127.0.0.1',
      port: portFront,
      options: ChannelOptions(credentials: channelOption),
    );
    final helloClient = HelloClient(helloChannel);
    _status ??= LastStream(
      ValueConnectableStream(
        Rx.merge([
          if (_isAndroid)
            _androidSnapshotStatuses()
          else if (_supportsSessionSnapshots)
            _appleSnapshotStatuses()
          else
            statusChannel.receiveBroadcastStream().map(CoreStatus.fromEvent),
          if (!_isAndroid) alertsChannel.receiveBroadcastStream().where(_isCurrentEvent).map(CoreStatus.fromEvent),
        ]),
      ).autoConnect(),
    );

    try {
      try {
        await helloClient.sayHello(
          HelloRequest(name: "test"),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
        loggy.info("core is already started!");
      } catch (e) {
        // core is not started yet

        await methodChannel
            .invokeMethod("setup", {
              "baseDir": directories.baseDir.path,
              "workingDir": directories.workingDir.path,
              "tempDir": directories.tempDir.path,
              "grpcPort": portFront,
              "mode": mode,
              "debug": debug,
            })
            .timeout(_nativeSetupTimeout);
        final res = await _sayHelloWhenReady(helloClient);
        loggy.info(res.toString());
      }
    } finally {
      await _shutdownChannel(helloChannel);
    }

    // serverPublicKey = await methodChannel.invokeMethod<Uint8List>("get_grpc_server_public_key") ?? Uint8List.fromList([]);
    // await methodChannel.invokeMethod(
    //   "add_grpc_client_public_key",
    //   {
    //     "clientPublicKey": ascii.encode(CryptoUtils.encodeEcPublicKeyToPem(cert.publicKey as ECPublicKey)),
    //   },
    // );
    // serverPublicKey = X509Utils.x509CertificateFromPem(String.fromCharCodes(serverPublicKey));
    // var chanelOption = ChannelOptions(
    //   credentials: MTLSChannelCredentials(serverPublicKey: serverPublicKey, clientPrivateKey: cert.privateKey as ECPrivateKey),
    // );
    final nextFgChannel = ClientChannel(
      '127.0.0.1',
      port: portFront,
      options: ChannelOptions(credentials: channelOption),
    );
    final previousFgChannel = _fgChannel;
    _fgChannel = nextFgChannel;
    fgClient = CoreClient(nextFgChannel);
    // The background channel owns long-lived stats/proxy streams. It connects
    // to a different native process and does not need replacement when only the
    // foreground core is restored after app resume.
    if (_bgChannel == null) {
      final nextBgChannel = ClientChannel(
        '127.0.0.1',
        port: portBack,
        options: ChannelOptions(credentials: channelOption),
      );
      _bgChannel = nextBgChannel;
      bgClient = CoreClient(nextBgChannel);
    }
    if (previousFgChannel != null) {
      await _shutdownChannel(previousFgChannel);
    }
    // await start("/sdcard/Android/data/app.zeonvpn.com/files/configs/cdc633e9-8cfc-4a67-948d-009f779a5c91.json", "zeon");
    return "";
  }

  Stream<CoreStatus> _androidSnapshotStatuses() async* {
    await for (final event in snapshotChannel.receiveBroadcastStream()) {
      final incoming = VpnSessionSnapshot.fromEvent(event);
      final disposition = _snapshotGate.classify(incoming);
      if (disposition == VpnSnapshotDisposition.duplicate || disposition == VpnSnapshotDisposition.stale) {
        loggy.warning(
          "event=stale_callback_ignored generation=${incoming.generation} "
          "sequence=${incoming.sequenceNumber} source=android_snapshot disposition=${disposition.name}",
        );
        continue;
      }
      if (disposition == VpnSnapshotDisposition.gap) {
        final resynced = await _getAuthoritativeSnapshot();
        if (resynced == null) continue;
        final accepted = _acceptResyncedSnapshot(resynced, publish: true);
        if (accepted != null) yield accepted.toCoreStatus();
        continue;
      }
      _acceptAuthoritativeSnapshot(incoming, publish: true);
      yield incoming.toCoreStatus();
    }
  }

  Stream<CoreStatus> _appleSnapshotStatuses() async* {
    await for (final event in statusChannel.receiveBroadcastStream().where(_isCurrentEvent)) {
      final snapshot = VpnSessionSnapshot.fromEvent(event);
      final disposition = _snapshotGate.classify(snapshot);
      if (disposition != VpnSnapshotDisposition.stale && disposition != VpnSnapshotDisposition.duplicate) {
        // Every iOS status event contains a complete synchronous snapshot, so
        // it can bridge directly into the same authoritative stream used by
        // Android and by the main VPN button.
        _acceptAuthoritativeSnapshot(snapshot, publish: true);
      }
      yield CoreStatus.fromEvent(event);
    }
  }

  void _acceptAuthoritativeSnapshot(VpnSessionSnapshot snapshot, {required bool publish}) {
    _snapshotGate.acceptAuthoritative(snapshot);
    _recordAcceptedSnapshot(snapshot, publish: publish);
  }

  void _recordAcceptedSnapshot(VpnSessionSnapshot snapshot, {required bool publish}) {
    _sessionGeneration = max(_sessionGeneration, snapshot.generation);
    _authoritativeSessionSnapshot = snapshot;
    if (!publish) return;
    if (_sessionSnapshots.hasValue) {
      final previous = _sessionSnapshots.value;
      if (previous.runtimeEpoch == snapshot.runtimeEpoch &&
          previous.sequenceNumber == snapshot.sequenceNumber &&
          previous.snapshotVersion == snapshot.snapshotVersion) {
        return;
      }
    }
    _sessionSnapshots.add(snapshot);
  }

  VpnSessionSnapshot? _acceptResyncedSnapshot(VpnSessionSnapshot snapshot, {required bool publish}) {
    final disposition = _snapshotGate.classify(snapshot);
    if (!_snapshotGate.acceptResynced(snapshot)) {
      loggy.info(
        "event=vpn_snapshot_resync_ignored generation=${snapshot.generation} "
        "sequence=${snapshot.sequenceNumber} disposition=${disposition.name}",
      );
      return _snapshotGate.current;
    }
    // A MethodChannel read is the platform's current authoritative value. A
    // sequence gap therefore advances the gate just like a normal accepted
    // snapshot, but it must never roll the gate back behind an EventChannel
    // value that won the race while the method call was in flight.
    _recordAcceptedSnapshot(snapshot, publish: publish);
    return snapshot;
  }

  Future<VpnSessionSnapshot?> _getAuthoritativeSnapshot() async {
    if (!_supportsSessionSnapshots) return null;
    final event = await methodChannel.invokeMethod<Object?>("get_vpn_session_snapshot");
    return VpnSessionSnapshot.fromEvent(event);
  }

  @override
  Future<CoreStatus?> resyncSessionStatus() async {
    final snapshot = await _getAuthoritativeSnapshot();
    if (snapshot == null) return null;
    final accepted = _acceptResyncedSnapshot(snapshot, publish: false);
    if (accepted == null) return null;
    loggy.info(
      "event=vpn_snapshot_resync generation=${accepted.generation} "
      "sequence=${accepted.sequenceNumber} phase=${accepted.phase.name}",
    );
    return accepted.toCoreStatus();
  }

  @override
  int get authoritativeSessionGeneration => _sessionGeneration;

  @override
  VpnSessionSnapshot? get authoritativeSessionSnapshot => _authoritativeSessionSnapshot;

  @override
  Stream<VpnSessionSnapshot> watchSessionSnapshots() => _sessionSnapshots.stream;

  @override
  Future<int> requestPlatformStop({required int generation}) {
    // Do not call setSessionGeneration first: Android may have advanced its
    // process-local generation (tile/notification/service recovery) before the
    // snapshot reached Dart. A preemptive user Stop must atomically rebase
    // above that native generation and stop the current service.
    return stopMethodChannel(generation: generation, preemptive: true);
  }

  @override
  bool get supportsPreemptivePlatformStop => Platform.isAndroid;

  Future<HelloResponse> _sayHelloWhenReady(HelloClient client) async {
    const maxAttempts = 10;
    var delay = const Duration(milliseconds: 120);
    final random = Random();
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await client.sayHello(
          HelloRequest(name: "test"),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
        if (attempt == maxAttempts) break;
        loggy.debug("foreground core hello not ready [$attempt/$maxAttempts]: $e");
        final jitterMs = random.nextInt(max(1, delay.inMilliseconds ~/ 3));
        await Future<void>.delayed(Duration(milliseconds: delay.inMilliseconds + jitterMs));
        delay = Duration(milliseconds: min(1000, max(delay.inMilliseconds + 1, (delay.inMilliseconds * 1.7).round())));
      }
    }

    Error.throwWithStackTrace(
      lastError ?? StateError("foreground core hello failed"),
      lastStackTrace ?? StackTrace.current,
    );
  }

  Future<void> _shutdownChannel(ClientChannel channel) async {
    try {
      await channel.shutdown().timeout(const Duration(seconds: 1));
    } catch (_) {
      try {
        await channel.terminate().timeout(const Duration(seconds: 1));
      } catch (_) {
        // The native core may already be gone. Channel cleanup is best-effort.
      }
    }
  }

  @override
  Future<BackgroundSetupResult> setupBackground(String path, String name, {int generation = 0}) async {
    await setSessionGeneration(generation);
    // if (!await waitUntilPort(portBack, false, stop)) return const CoreStatus.stopped(alert: CoreAlert.createService);
    if (!await stopForReplacement(generation: generation)) {
      return BackgroundSetupResult(
        generation: generation,
        status: const CoreStatus.stopped(alert: CoreAlert.createService),
        failure: BackgroundSetupFailure.replacementTeardown,
        nativeSnapshot: _authoritativeSessionSnapshot,
      );
    }
    _status?.clean();
    await methodChannel.invokeMethod("start", {
      "path": path,
      "name": name,
      "grpcPort": portBack,
      "startBg": true,
      "debug": _debug,
      "generation": generation,
    });

    _isBgClientAvailable = true;
    PortProbeObservation? lastPortProbe;
    if (!await waitUntilPort(
      portBack,
      true,
      null,
      maxTry: 18,
      baseDelay: const Duration(milliseconds: 180),
      maxDelay: const Duration(milliseconds: 1600),
      portProbe: _portProbe,
      onObservation: (observation) => lastPortProbe = observation,
    )) {
      final nativeSnapshot = await _snapshotBeforeFailedStartCleanup();
      await stopMethodChannel(generation: generation);
      return BackgroundSetupResult(
        generation: generation,
        status: const CoreStatus.stopped(alert: CoreAlert.startService, message: "starting background core..."),
        failure: _backgroundSetupFailureForProbe(lastPortProbe),
        portProbe: lastPortProbe,
        nativeSnapshot: nativeSnapshot,
      );
    }
    if (!await _waitForBackgroundCommandEndpoint(generation)) {
      final nativeSnapshot = await _snapshotBeforeFailedStartCleanup();
      await stopMethodChannel(generation: generation);
      return BackgroundSetupResult(
        generation: generation,
        status: const CoreStatus.stopped(
          alert: CoreAlert.startService,
          message: "background command endpoint readiness timeout",
        ),
        failure: BackgroundSetupFailure.commandEndpointTimeout,
        portProbe: lastPortProbe,
        nativeSnapshot: nativeSnapshot,
      );
    }
    // The daemon/control endpoint is reachable, but the tunnel core has not
    // completed Mobile.start yet. This must never be exposed as Connected.
    return BackgroundSetupResult(
      generation: generation,
      status: const CoreStarting(),
      portProbe: lastPortProbe,
      nativeSnapshot: _authoritativeSessionSnapshot,
    );
  }

  Future<VpnSessionSnapshot?> _snapshotBeforeFailedStartCleanup() async {
    if (!_supportsSessionSnapshots) return _authoritativeSessionSnapshot;
    try {
      await resyncSessionStatus();
    } catch (_) {
      // Failure cleanup must not be blocked by an observational snapshot read.
    }
    return _authoritativeSessionSnapshot;
  }

  BackgroundSetupFailure _backgroundSetupFailureForProbe(PortProbeObservation? observation) =>
      switch (observation?.outcome) {
        PortProbeOutcome.closed => BackgroundSetupFailure.controlPortClosed,
        PortProbeOutcome.timeout => BackgroundSetupFailure.controlPortTimeout,
        PortProbeOutcome.socketError => BackgroundSetupFailure.controlPortSocketError,
        PortProbeOutcome.otherError => BackgroundSetupFailure.controlPortOtherError,
        PortProbeOutcome.connected || null => BackgroundSetupFailure.controlPortOtherError,
      };

  @override
  Future<bool> prepareVpn(String path, String name, bool disableMemoryLimit, {int generation = 0}) async {
    await setSessionGeneration(generation);
    final prepared = await methodChannel.invokeMethod<bool>("prepare_vpn", {
      "path": path,
      "name": name,
      "grpcPort": portBack,
      "disableMemoryLimit": disableMemoryLimit,
      "generation": generation,
    });
    return prepared ?? false;
  }

  @override
  Future<bool> stop({int generation = 0}) => _stopPlatform(generation: generation, replacement: false);

  @override
  Future<bool> stopForReplacement({int generation = 0}) => _stopPlatform(generation: generation, replacement: true);

  Future<bool> _stopPlatform({required int generation, required bool replacement}) async {
    if (generation > 0) {
      await setSessionGeneration(generation);
    }
    final acceptedGeneration = await stopMethodChannel(
      generation: generation,
      replacement: replacement,
    ).timeout(const Duration(seconds: 3), onTimeout: () => generation);
    if (replacement && acceptedGeneration != generation) {
      return false;
    }
    final stopped = await waitUntilPort(
      portBack,
      false,
      () => stopMethodChannel(generation: generation, replacement: replacement),
      baseDelay: const Duration(milliseconds: 160),
      maxDelay: const Duration(milliseconds: 900),
      portProbe: _portProbe,
    ).timeout(const Duration(seconds: 12), onTimeout: () => false);
    _isBgClientAvailable = false;
    if (!stopped) {
      return false;
    }
    if (!_isAndroid) return true;
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await resyncSessionStatus();
        final snapshot = _authoritativeSessionSnapshot;
        final terminalGenerationMatches = replacement
            ? snapshot?.generation == generation && snapshot?.stopSource == VpnStopSource.replacement
            : (snapshot?.generation ?? 0) >= generation;
        if (terminalGenerationMatches && snapshot?.phase == VpnSessionPhase.disconnected) {
          return true;
        }
      } catch (error, stackTrace) {
        loggy.debug("Android terminal stop snapshot poll failed", error, stackTrace);
      }
      if (attempt < 9) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return false;
  }

  Future<int> stopMethodChannel({int? generation, bool preemptive = false, bool replacement = false}) async {
    final requested = generation ?? _sessionGeneration;
    final response = await methodChannel.invokeMethod<Object?>("stop", {
      "generation": requested,
      "preemptive": preemptive,
      "replacement": replacement,
    });
    // Older iOS runners returned `true` even though this method has always
    // needed the accepted generation. Tolerate that response during upgrades;
    // current runners return an integer on every path.
    final accepted = switch (response) {
      final int value => value,
      final num value => value.toInt(),
      true => requested,
      null => requested,
      _ => throw StateError("invalid native stop response: ${response.runtimeType}"),
    };
    _sessionGeneration = max(_sessionGeneration, accepted);
    return accepted;
  }

  @override
  Future<void> setSessionGeneration(int generation) async {
    if (generation <= 0 || generation == _sessionGeneration) return;
    if (generation < _sessionGeneration) {
      throw StateError("stale VPN session generation: requested=$generation current=$_sessionGeneration");
    }
    _sessionGeneration = generation;
    final accepted = await methodChannel.invokeMethod<int>("set_session_generation", {"generation": generation});
    if (accepted != null && accepted != generation) {
      _sessionGeneration = max(_sessionGeneration, accepted);
      throw StateError("stale VPN session generation: requested=$generation current=$accepted");
    }
  }

  @override
  Future<void> markCoreStarted(int generation) async {
    if (generation != _sessionGeneration) {
      throw StateError("cannot mark stale VPN session ready");
    }
    await methodChannel.invokeMethod<int>("mark_core_started", {"generation": generation});
  }

  Future<bool> _waitForBackgroundCommandEndpoint(int generation) async {
    const maxAttempts = 15;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (generation != _sessionGeneration) return false;
      try {
        await bgClient
            .getSystemInfo(Empty(), options: CallOptions(timeout: const Duration(milliseconds: 800)))
            .timeout(const Duration(seconds: 1));
        return true;
      } catch (error) {
        if (attempt == maxAttempts) return false;
        await Future<void>.delayed(Duration(milliseconds: min(1000, 100 + attempt * 80)));
      }
    }
    return false;
  }

  bool _isCurrentEvent(dynamic event) {
    final map = event as Map<dynamic, dynamic>?;
    final raw = map?["generation"];
    final generation = raw is int ? raw : int.tryParse(raw?.toString() ?? "") ?? 0;
    if (_sessionGeneration <= 0 || generation == _sessionGeneration) return true;
    loggy.warning(
      "event=stale_callback_ignored generation=$generation current_generation=$_sessionGeneration source=platform_event_channel",
    );
    return false;
  }

  @override
  Future<bool> isBgClientAvailable() async {
    return _isBgClientAvailable;
  }

  @override
  Future<bool> resetTunnel() async {
    await methodChannel.invokeMethod("reset").timeout(_nativeControlTimeout);
    return true;
  }

  @override
  Future<bool> isActiveFg() async {
    final channel = _fgChannel;
    if (channel == null) return false;
    try {
      await HelloClient(channel).sayHello(
        HelloRequest(name: "health"),
        options: CallOptions(timeout: const Duration(seconds: 1)),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isActiveBg({PortProbeObserver? onPortProbe}) async {
    return await isPortOpen("127.0.0.1", portBack, onObservation: onPortProbe);
  }
}

Future<bool> waitUntilPort(
  int portNumber,
  bool isOpen,
  Future Function()? callFunctionAfterEachFail, {
  int maxTry = 14,
  Duration baseDelay = const Duration(milliseconds: 200),
  Duration maxDelay = const Duration(milliseconds: 1500),
  double factor = 1.8,
  Future<bool> Function(String, int)? portProbe,
  PortProbeObserver? onObservation,
}) async {
  var delay = baseDelay;
  final random = Random();
  for (var i = 0; i < maxTry; i++) {
    final observed = portProbe == null
        ? await isPortOpen("127.0.0.1", portNumber, onObservation: onObservation)
        : await portProbe("127.0.0.1", portNumber);
    if (portProbe != null) {
      _notifyPortProbe(
        onObservation,
        PortProbeObservation(observed ? PortProbeOutcome.connected : PortProbeOutcome.closed),
      );
    }
    if (observed == isOpen) {
      return true;
    }
    if (callFunctionAfterEachFail != null) {
      await callFunctionAfterEachFail();
    }
    final jitterMs = random.nextInt(max(1, delay.inMilliseconds ~/ 4));
    await Future.delayed(Duration(milliseconds: delay.inMilliseconds + jitterMs));
    final nextDelayMs = min(
      maxDelay.inMilliseconds,
      max(delay.inMilliseconds + 1, (delay.inMilliseconds * factor).round()),
    );
    delay = Duration(milliseconds: nextDelayMs);
  }
  return false;
}

Future<bool> isPortOpen(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 300),
  PortProbeObserver? onObservation,
}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    await socket.close();
    _notifyPortProbe(onObservation, const PortProbeObservation(PortProbeOutcome.connected));
    return true;
  } on TimeoutException {
    _notifyPortProbe(onObservation, const PortProbeObservation(PortProbeOutcome.timeout));
    return false;
  } on SocketException catch (error) {
    _notifyPortProbe(onObservation, PortProbeObservation(classifySocketProbeError(error)));
    return false;
  } catch (_) {
    _notifyPortProbe(onObservation, const PortProbeObservation(PortProbeOutcome.otherError));
    return false;
  }
}

void _notifyPortProbe(PortProbeObserver? observer, PortProbeObservation observation) {
  try {
    observer?.call(observation);
  } catch (_) {
    // Diagnostics must not change the probe result used by the caller.
  }
}

PortProbeOutcome classifySocketProbeError(SocketException error) {
  final code = error.osError?.errorCode;
  if (const {60, 110, 10060}.contains(code) || error.message.toLowerCase().contains('timed out')) {
    return PortProbeOutcome.timeout;
  }
  if (const {61, 111, 10061}.contains(code) || error.message.toLowerCase().contains('refused')) {
    return PortProbeOutcome.closed;
  }
  return PortProbeOutcome.socketError;
}
