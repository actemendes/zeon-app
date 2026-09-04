import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/utils/exception_handler.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/notifier/warp_option/warp_option_notifier.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;

  TaskEither<ConnectionFailure, Unit> setup();
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit);
  Stream<ConnectionStatus> watchConnectionStatus();
  Future<ConnectionStatus?> resyncConnectionStatus(String source);
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect({bool force = false});
  TaskEither<ConnectionFailure, Unit> reconnect(
    ProfileEntity activeProfile,
    bool disableMemoryLimit, {
    String source = "reconnect",
  });
}

@visibleForTesting
bool shouldPrepareSystemVpnForSnapshot(VpnSessionSnapshot? snapshot) {
  // Bootstrap preparation is optional. Unknown native state may belong to a
  // tunnel that survived a cold Runner relaunch, so it must fail closed.
  if (snapshot == null) return false;
  return switch (snapshot.phase) {
    VpnSessionPhase.idle => true,
    VpnSessionPhase.disconnected when snapshot.requestedAction != 'connect' => true,
    VpnSessionPhase.failed => true,
    _ => false,
  };
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  static const _tunRecoveryRestartAttempts = 2;
  static const _tunReleaseDelay = Duration(milliseconds: 500);
  static const _tunRecoveryCooldown = Duration(seconds: 2);

  ConnectionRepositoryImpl({
    required this.ref,
    required this.directories,
    required this.singbox,
    required this.configOptionRepository,
    required this.profileConfigStore,
  });

  final Ref ref;

  final Directories directories;
  final ZeonCoreService singbox;

  final ConfigOptionRepository configOptionRepository;
  final ProfileConfigStore profileConfigStore;
  final Map<String, Future<File>> _runtimeConfigRepairByProfile = {};
  Future<Either<ConnectionFailure, Unit>>? _systemVpnPreparationInFlight;
  DateTime? _lastTunRecoveryAttemptAt;

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      // ZeonCoreService owns idempotence and foreground-channel health. A
      // repository-local permanent latch becomes stale after Android closes or
      // wedges the foreground gRPC transport during repeated VPN lifecycles.
      return singbox.setup().mapLeft(UnexpectedConnectionFailure.new).run();
    }, UnexpectedConnectionFailure.new);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() {
    return singbox.watchStatus().map(
      (event) => switch (event) {
        CoreStopped() => Disconnected(event.getCoreAlert()),
        CoreStarting() => const Connecting(),
        CoreStarted() => const Connected(),
        CoreStopping() => const Disconnecting(),
      },
    );
  }

  @override
  Future<ConnectionStatus?> resyncConnectionStatus(String source) async {
    final status = await singbox.resyncFromPlatform(source);
    return switch (status) {
      null => null,
      CoreStopped() => Disconnected(status.getCoreAlert()),
      CoreStarting() => const Connecting(),
      CoreStarted() => const Connected(),
      CoreStopping() => const Disconnecting(),
    };
  }

  @override
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit) {
    return TaskEither(() {
      final existing = _systemVpnPreparationInFlight;
      if (existing != null) return existing;

      final operation = _prepareSystemVpn(activeProfile, disableMemoryLimit);
      _systemVpnPreparationInFlight = operation;
      return operation.whenComplete(() {
        if (identical(_systemVpnPreparationInFlight, operation)) {
          _systemVpnPreparationInFlight = null;
        }
      });
    });
  }

  Future<Either<ConnectionFailure, Unit>> _prepareSystemVpn(
    ProfileEntity activeProfile,
    bool disableMemoryLimit,
  ) async {
    try {
      if (!await _systemVpnPreparationAllowed("before_config")) return right(unit);
      final runtimeFile = await _createRuntimeConfigFile(activeProfile);
      // Creating/repairing the runtime config can take long enough for a user
      // start (or a system start) to win the race. Check again immediately
      // before reserving a generation; preparation must never supersede a
      // running tunnel.
      final expectedGeneration = singbox.currentVpnGeneration;
      if (!await _systemVpnPreparationAllowed("before_generation")) return right(unit);
      final generation = singbox.tryBeginVpnPreparation("prepare_system_vpn", expectedGeneration: expectedGeneration);
      if (generation == null) return right(unit);
      return (await singbox
              .prepareVpnConfiguration(
                runtimeFile.path,
                activeProfile.name,
                disableMemoryLimit,
                generation: generation,
                bootstrapOnly: true,
              )
              .run())
          .mapLeft(_vpnPreparationFailure);
    } catch (err, st) {
      return left(err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
    }
  }

  Future<bool> _systemVpnPreparationAllowed(String stage) async {
    VpnSessionSnapshot? snapshot;
    try {
      snapshot = await singbox.resyncSessionSnapshot("prepare_system_vpn_$stage");
    } catch (error, stackTrace) {
      // This is best-effort bootstrap work. Unknown native state must not
      // supersede a live tunnel owned by a previous Runner process.
      loggy.warning("could not guard iOS system VPN preparation [$stage]", error, stackTrace);
      return false;
    }
    final allowed = shouldPrepareSystemVpnForSnapshot(snapshot);
    if (!allowed) {
      loggy.info(
        "event=system_vpn_prepare_skipped stage=$stage "
        "generation=${snapshot?.generation ?? 0} phase=${snapshot?.phase.name ?? "none"} "
        "requested_action=${snapshot?.requestedAction ?? ""}",
      );
    }
    return allowed;
  }

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      TaskEither(() async {
        // Reserve the lifecycle generation before setup/config/file I/O. A
        // later Stop can then supersede this attempt even while preflight is
        // still awaiting work outside ZeonCoreService's lifecycle queue.
        final generation = singbox.beginVpnOperation("connect");
        final setupResult = await setup().run();
        if (setupResult.isLeft()) return setupResult;
        final optionsResult = await applyConfigOption(activeProfile).run();
        if (optionsResult.isLeft()) return optionsResult;
        try {
          // TODO: Move core startup to in-memory config once the background service
          // no longer persists config_content or requires a readable config path.
          final runtimeFile = await _createRuntimeConfigFile(activeProfile);
          final prepared = await _prepareVpnBeforeCoreStart(
            runtimeFile.path,
            activeProfile.name,
            disableMemoryLimit,
            generation,
          );
          if (prepared.isLeft()) {
            throw prepared.getLeft().toNullable() ?? const ConnectionFailure.missingVpnPermission();
          }
          return await singbox
              .start(runtimeFile.path, activeProfile.name, disableMemoryLimit, generation: generation)
              .run();
        } catch (err, st) {
          return left(err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
        }
      });

  @override
  TaskEither<ConnectionFailure, Unit> disconnect({bool force = false}) =>
      singbox.stop(force: force).mapLeft(UnexpectedConnectionFailure.new);

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(
    ProfileEntity activeProfile,
    bool disableMemoryLimit, {
    String source = "reconnect",
  }) => TaskEither(() async {
    // See connect(): Stop must own a newer generation even when this
    // reconnect is still applying options or creating its runtime file.
    final generation = singbox.beginVpnOperation(source);
    final optionsResult = await applyConfigOption(activeProfile).run();
    if (optionsResult.isLeft()) return optionsResult;
    late final String path;
    Either<ConnectionFailure, Unit> result;
    try {
      // TODO: Move core restart to in-memory config once the background service
      // no longer persists config_content or requires a readable config path.
      final runtimeFile = await _createRuntimeConfigFile(activeProfile);
      path = runtimeFile.path;
      final prepared = await _prepareVpnBeforeCoreStart(path, activeProfile.name, disableMemoryLimit, generation);
      if (prepared.isLeft()) {
        return left(prepared.getLeft().toNullable() ?? const ConnectionFailure.missingVpnPermission());
      }
      result =
          (await singbox
                  .restart(path, activeProfile.name, disableMemoryLimit, generation: generation, source: source)
                  .run())
              .mapLeft(UnexpectedConnectionFailure.new);
    } catch (err, st) {
      return left(err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
    }

    var recoveryOwnerGeneration = generation;
    for (var attempt = 1; attempt <= _tunRecoveryRestartAttempts && result.isLeft(); attempt++) {
      final failure = result.getLeft().toNullable();
      if (failure == null || !isTunInterfacePermissionDenied(failure)) {
        break;
      }
      if (!singbox.isVpnOperationCurrent(recoveryOwnerGeneration, source: "tun_recovery_entry")) {
        loggy.info("TUN recovery cancelled: a newer VPN intent owns the lifecycle");
        return right(unit);
      }

      loggy.warning(
        "TUN recovery attempt "
        "[$attempt/$_tunRecoveryRestartAttempts]",
      );

      await _waitForTunRecoveryCooldown();
      if (!singbox.isVpnOperationCurrent(recoveryOwnerGeneration, source: "tun_recovery_before_cleanup")) {
        loggy.info("TUN recovery cancelled before cleanup: a newer VPN intent owns the lifecycle");
        return right(unit);
      }

      // stop(force:true) reserves exactly the next monotonic generation when
      // run. Remember it so a manual/native Stop that arrives during cleanup
      // or the release delay cannot be overwritten by a recovery Start.
      final cleanupGeneration = recoveryOwnerGeneration + 1;
      final stopResult = await singbox.stop(force: true).run();
      stopResult.match(
        (error) => loggy.warning(
          "core stop reported an error during TUN recovery; "
          "continuing because local cleanup has completed",
          error,
        ),
        (_) {},
      );
      if (!singbox.isVpnOperationCurrent(cleanupGeneration, source: "tun_recovery_after_cleanup")) {
        loggy.info("TUN recovery cancelled after cleanup: a newer VPN intent owns the lifecycle");
        return right(unit);
      }
      await Future<void>.delayed(_tunReleaseDelay);
      if (!singbox.isVpnOperationCurrent(cleanupGeneration, source: "tun_recovery_after_release_delay")) {
        loggy.info("TUN recovery cancelled during release delay: a newer VPN intent owns the lifecycle");
        return right(unit);
      }
      final recoveryGeneration = singbox.beginVpnOperation("tun_recovery");
      recoveryOwnerGeneration = recoveryGeneration;
      final prepared = await _prepareVpnBeforeCoreStart(
        path,
        activeProfile.name,
        disableMemoryLimit,
        recoveryGeneration,
      );
      if (!singbox.isVpnOperationCurrent(recoveryGeneration, source: "tun_recovery_permission_result")) {
        loggy.info("TUN recovery cancelled after permission result: a newer VPN intent owns the lifecycle");
        return right(unit);
      }
      if (prepared.isLeft()) {
        return left(prepared.getLeft().toNullable() ?? const ConnectionFailure.missingVpnPermission());
      }
      result = await singbox.start(path, activeProfile.name, disableMemoryLimit, generation: recoveryGeneration).run();
    }

    return result;
  });

  Future<Either<ConnectionFailure, Unit>> _prepareVpnBeforeCoreStart(
    String path,
    String name,
    bool disableMemoryLimit,
    int generation,
  ) async {
    final result = await singbox.prepareVpnConfiguration(path, name, disableMemoryLimit, generation: generation).run();
    return result.mapLeft(_vpnPreparationFailure);
  }

  ConnectionFailure _vpnPreparationFailure(String message) {
    if (isVpnPermissionDenied(message)) {
      return ConnectionFailure.missingVpnPermission(message);
    }
    return ConnectionFailure.unexpected(message);
  }

  Future<void> _waitForTunRecoveryCooldown() async {
    final now = DateTime.now();
    final lastAttemptAt = _lastTunRecoveryAttemptAt;
    if (lastAttemptAt != null) {
      final elapsed = now.difference(lastAttemptAt);
      if (elapsed < _tunRecoveryCooldown) {
        await Future<void>.delayed(_tunRecoveryCooldown - elapsed);
      }
    }
    _lastTunRecoveryAttemptAt = DateTime.now();
  }

  Future<File> _createRuntimeConfigFile(ProfileEntity activeProfile) async {
    final content = await profileConfigStore.read(activeProfile.id);
    if (_looksLikeGeneratedJsonConfig(content)) {
      return profileConfigStore.createRuntimeConnectionFile(activeProfile.id, content: content);
    }

    final repair = _runtimeConfigRepairByProfile.putIfAbsent(
      activeProfile.id,
      () => _repairRuntimeConfig(activeProfile),
    );
    try {
      return await repair;
    } finally {
      if (identical(_runtimeConfigRepairByProfile[activeProfile.id], repair)) {
        _runtimeConfigRepairByProfile.remove(activeProfile.id);
      }
    }
  }

  Future<File> _repairRuntimeConfig(ProfileEntity activeProfile) async {
    final content = await profileConfigStore.read(activeProfile.id);
    if (_looksLikeGeneratedJsonConfig(content)) {
      return profileConfigStore.createRuntimeConnectionFile(activeProfile.id, content: content);
    }

    loggy.warning("stored profile config is not generated JSON; trying to regenerate it before core start");
    final regenerated = await _regenerateStoredConfig(activeProfile, content);
    await profileConfigStore.write(activeProfile.id, regenerated);
    final file = await profileConfigStore.createRuntimeConnectionFile(activeProfile.id, content: regenerated);
    loggy.info("stored profile config repaired and runtime config refreshed");
    return file;
  }

  Future<String> _regenerateStoredConfig(ProfileEntity activeProfile, String rawContent) async {
    final options = configOptionRepository
        .fullOptionsOverrided(activeProfile.profileOverride)
        .match((failure) => throw ConnectionFailure.invalidConfigOption(null, failure), (options) => options);

    final optionsResult = await singbox.changeOptions(options).run();
    optionsResult.match(
      (err) => throw ConnectionFailure.unexpected("failed to apply core options before config repair: $err"),
      (_) => unit,
    );

    final validationResult = await singbox.validateConfigContent(rawContent, false).run();
    return validationResult.match(
      (err) => throw ConnectionFailure.unexpected("failed to repair stored profile config: $err"),
      (content) => content,
    );
  }

  bool _looksLikeGeneratedJsonConfig(String content) {
    try {
      return jsonDecode(content) is Map;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(ProfileEntity prof) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(prof.profileOverride))
          .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
          .flatMap(
            (overridedOptions) => TaskEither.tryCatch(() async {
              final isWarpLicenseAgreed = ref.read(warpLicenseNotifierProvider);
              final isWarpEnabled = overridedOptions.warp.enable || overridedOptions.warp2.enable;
              if (!isWarpLicenseAgreed && isWarpEnabled) {
                final isAgreed = await ref.read(dialogNotifierProvider.notifier).showWarpLicense();
                if (isAgreed == true) {
                  await ref.read(warpLicenseNotifierProvider.notifier).agree();
                  // return (await applyConfigOption(prof).run()).match((l) => throw l, (_) => unit);
                } else {
                  throw const MissingWarpLicense();
                }
              }
              _configOptionsSnapshot = overridedOptions;
              loggy.info(
                "apply config option (safe): "
                "profile=${overridedOptions.networkProfile}, "
                "mtuMode=${overridedOptions.networkMtuMode}, "
                "fragmentMode=${overridedOptions.fragmentMode}, "
                "profileDns=${overridedOptions.profileDnsStrategy}, "
                "mtu=${overridedOptions.mtu}, "
                "tun=${overridedOptions.tunImplementation.name}, "
                "strictRoute=${overridedOptions.strictRoute}",
              );
              final changeResult = await singbox.changeOptions(overridedOptions).run();
              changeResult.match(
                (err) => throw ConnectionFailure.unexpected("failed to apply core options: $err"),
                (_) => unit,
              );
              return unit;
            }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
          );
}
