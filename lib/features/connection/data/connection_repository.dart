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
import 'package:zeon/zeoncore/zeon_core_service.dart';

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;

  TaskEither<ConnectionFailure, Unit> setup();
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit);
  Stream<ConnectionStatus> watchConnectionStatus();
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect();
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit);
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  static const _tunRecoveryRestartAttempts = 2;
  static const _tunReleaseDelay = Duration(milliseconds: 500);

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

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  bool _initialized = false;

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    if (_initialized) return TaskEither.of(unit);
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      return singbox
          .setup()
          .map((r) {
            _initialized = true;
            return r;
          })
          .mapLeft(UnexpectedConnectionFailure.new)
          .run();
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
  TaskEither<ConnectionFailure, Unit> prepareSystemVpn(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      TaskEither.tryCatch(() async {
        final runtimeFile = await _createRuntimeConfigFile(activeProfile);
        return (await singbox.prepareVpnConfiguration(runtimeFile.path, activeProfile.name, disableMemoryLimit).run())
            .match((failure) => throw ConnectionFailure.unexpected(failure), (_) => unit);
      }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) => setup().flatMap(
    (_) => applyConfigOption(activeProfile).flatMap(
      (_) => TaskEither.tryCatch(() async {
        // TODO: Move core startup to in-memory config once the background service
        // no longer persists config_content or requires a readable config path.
        final runtimeFile = await _createRuntimeConfigFile(activeProfile);
        return (await singbox.start(runtimeFile.path, activeProfile.name, disableMemoryLimit).run()).match(
          (failure) => throw failure,
          (_) => unit,
        );
      }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
      // .mapLeft(UnexpectedConnectionFailure.new),
    ),
  );

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => singbox.stop().mapLeft(UnexpectedConnectionFailure.new);

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      applyConfigOption(activeProfile).flatMap(
        (_) => TaskEither(() async {
          late final String path;
          Either<ConnectionFailure, Unit> result;
          try {
            // TODO: Move core restart to in-memory config once the background service
            // no longer persists config_content or requires a readable config path.
            final runtimeFile = await _createRuntimeConfigFile(activeProfile);
            path = runtimeFile.path;
            result = (await singbox.restart(path, activeProfile.name, disableMemoryLimit).run()).mapLeft(
              UnexpectedConnectionFailure.new,
            );
          } catch (err, st) {
            return left(err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
          }

          for (var attempt = 1; attempt <= _tunRecoveryRestartAttempts && result.isLeft(); attempt++) {
            final failure = result.getLeft().toNullable();
            if (failure == null || !isTunInterfacePermissionDenied(failure)) {
              break;
            }

            loggy.warning(
              "TUN interface was not released during reconnect; "
              "performing full connection restart "
              "[$attempt/$_tunRecoveryRestartAttempts]",
            );

            final stopResult = await singbox.stop(force: true).run();
            stopResult.match(
              (error) => loggy.warning(
                "core stop reported an error during TUN recovery; "
                "continuing because local cleanup has completed",
                error,
              ),
              (_) {},
            );
            await Future<void>.delayed(_tunReleaseDelay);
            result = await singbox.start(path, activeProfile.name, disableMemoryLimit).run();
          }

          return result;
        }),
      );

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
