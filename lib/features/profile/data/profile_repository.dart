import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:uuid/uuid.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/utils/exception_handler.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_data_mapper.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/model/profile_failure.dart';
import 'package:zeon/features/profile/model/profile_sort_enum.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

abstract interface class ProfileRepository {
  TaskEither<ProfileFailure, Unit> init();
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id);
  TaskEither<ProfileFailure, Unit> setAsActive(String id);
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive);
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile();
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile();
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  });
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    bool validateConfigOnImport = true,
    bool syncManagedRuleSets = true,
  });
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride});
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, String> validateConfig(String tempPath, String? profileOverride, bool debug);
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository {
  ProfileRepositoryImpl({
    required ProfileDataSource profileDataSource,
    required ProfilePathResolver profilePathResolver,
    required ZeonCoreService singbox,
    required ConfigOptionRepository configOptionRepository,
    required ProfileParser profileParser,
    required ProfileConfigStore profileConfigStore,
    required ManagedRuleSetSyncService managedRuleSetSyncService,
  }) : _profileParser = profileParser,
       _configOptionRepo = configOptionRepository,
       _singbox = singbox,
       _profilePathResolver = profilePathResolver,
       _profileConfigStore = profileConfigStore,
       _managedRuleSetSyncService = managedRuleSetSyncService,
       _profileDataSource = profileDataSource;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final ZeonCoreService _singbox;
  final ConfigOptionRepository _configOptionRepo;
  final ProfileParser _profileParser;
  final ProfileConfigStore _profileConfigStore;
  final ManagedRuleSetSyncService _managedRuleSetSyncService;

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
        await _profileConfigStore.init();
        await _profileDataSource.migrateSensitiveFields();
      }

      return right(unit);
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) {
    return TaskEither.tryCatch(
      () => _profileDataSource.getById(id).then((value) => value?.toEntity()),
      ProfileUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.deleteById(id, isActive);
      await _profileConfigStore.delete(id);
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile() {
    return _profileDataSource.watchActiveProfile().map((event) => event?.toEntity()).handleExceptions((
      error,
      stackTrace,
    ) {
      loggy.error("error watching active profile", error, stackTrace);
      return ProfileUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile() {
    return _profileDataSource
        .watchProfilesCount()
        .map((event) => event != 0)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    return _profileDataSource
        .watchAll(sort: sort, sortMode: sortMode)
        .map((event) => event.map((e) => e.toEntity()).toList())
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    bool validateConfigOnImport = true,
    bool syncManagedRuleSets = true,
  }) => TaskEither.tryCatch(() async {
    final existingProfile = await _profileDataSource.getByUrl(url).then((profEntry) => profEntry?.toEntity());
    final isUpdate = existingProfile != null && existingProfile is RemoteProfileEntity;
    final id = existingProfile?.id ?? const Uuid().v4();
    final tempFile = _profilePathResolver.tempFile(id);

    try {
      await tempFile.parent.create(recursive: true);
      final profEntity = isUpdate
          ? await _profileParser
                .updateRemote(
                  rp: userOverride == null ? existingProfile : existingProfile.copyWith(userOverride: userOverride),
                  tempFilePath: tempFile.path,
                  cancelToken: cancelToken,
                  proxyOnly: proxyOnly,
                  directOnly: directOnly,
                  disableRetry: disableRetry,
                )
                .run()
                .then((result) => result.getOrElse((failure) => throw failure))
          : await _profileParser
                .addRemote(
                  id: id,
                  url: url,
                  tempFilePath: tempFile.path,
                  userOverride: userOverride,
                  cancelToken: cancelToken,
                  proxyOnly: proxyOnly,
                  directOnly: directOnly,
                  disableRetry: disableRetry,
                )
                .run()
                .then((result) => result.getOrElse((failure) => throw failure));

      // Subscription parsing succeeded. Refresh the optional managed routing
      // bundle before core validation/config generation so this profile update
      // can immediately use the newly published policy. The sync service is
      // deliberately fail-open and never turns a routing outage into a profile
      // update failure.
      if (syncManagedRuleSets) {
        await _managedRuleSetSyncService.sync(force: true, reason: 'subscription_refresh');
      }

      final content = validateConfigOnImport
          ? await _validatedOrPreviousUpdatedConfig(
              profileId: id,
              tempPath: tempFile.path,
              profileOverride: profEntity.profileOverride.value,
              debug: false,
              allowTransientValidationFallback: isUpdate,
            )
          : await _configWithoutValidation(profileId: id, tempPath: tempFile.path, isUpdate: isUpdate);
      await _profileConfigStore.write(id, content);
      if (isUpdate) {
        await _profileConfigStore.refreshRuntimeConnectionFileIfExists(id, content: content);
      }

      if (isUpdate) {
        await _profileDataSource.edit(id, profEntity);
      } else {
        await _profileDataSource.insert(profEntity);
      }
      return unit;
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }, _profileFailure);

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) =>
      TaskEither.tryCatch(() async {
        final id = const Uuid().v4();
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          await tempFile.parent.create(recursive: true);
          await tempFile.writeAsString(content);
          final task = _profileParser
              .addLocal(id: id, content: content, tempFilePath: tempFile.path, userOverride: userOverride)
              .flatMap(
                (profEntity) => validateConfig(tempFile.path, profEntity.profileOverride.value, false).flatMap(
                  (content) => _writeConfig(id, content).flatMap(
                    (unit) => TaskEither.tryCatch(() async {
                      await _profileDataSource.insert(profEntity);
                      return unit;
                    }, ProfileFailure.unexpected),
                  ),
                ),
              );
          return (await task.run()).getOrElse((l) => throw l);
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      }, ProfileFailure.unexpected);

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String nContent) =>
      TaskEither.tryCatch(() async {
        final oProfile = await _profileDataSource.getById(profile.id).then((profEntry) => profEntry?.toEntity());
        if (oProfile == null || oProfile.runtimeType != profile.runtimeType) throw const ProfileFailure.notFound();
        if (profile.userOverride == null) loggy.warning('Updaing profile content with "userOverride" == null');
        final id = oProfile.id;
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          await tempFile.parent.create(recursive: true);
          await tempFile.writeAsString(nContent);
          final profEntity = _profileParser
              .offlineUpdate(
                profile: oProfile.copyWith(userOverride: profile.userOverride),
                tempFilePath: tempFile.path,
              )
              .getOrElse((failure) => throw failure);
          final content = await validateConfig(
            tempFile.path,
            profEntity.profileOverride.value,
            false,
          ).run().then((result) => result.getOrElse((failure) => throw failure));
          await _profileConfigStore.write(id, content);
          await _profileConfigStore.refreshRuntimeConnectionFileIfExists(id, content: content);
          await _profileDataSource.edit(id, profEntity);
          return unit;
        } finally {
          if (await tempFile.exists()) await tempFile.delete();
        }
      }, _profileFailure);

  @override
  TaskEither<ProfileFailure, String> validateConfig(String tempPath, String? profileOverride, bool debug) =>
      TaskEither.fromEither(_configOptionRepo.fullOptionsOverrided(profileOverride))
          .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
          .flatMap(
            (overridedOptions) => _singbox
                .changeOptions(overridedOptions)
                .mapLeft(ProfileFailure.invalidConfig)
                .flatMap(
                  (_) => _readTempConfig(tempPath).flatMap(
                    (content) => _singbox.validateConfigContent(content, debug).mapLeft(ProfileFailure.invalidConfig),
                  ),
                ),
          );

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) =>
      TaskEither.tryCatch(() async {
        // This closes the startup/autoconnect race: config generation waits for a
        // TTL-governed, fail-open rule-set check without initiating a reconnect.
        await _managedRuleSetSyncService.sync(reason: 'config_generation');
        return unit;
      }, ProfileFailure.unexpected).flatMap(
        (_) => getRawConfig(
          id,
        ).flatMap((content) => _singbox.generateFullConfig(content).mapLeft(ProfileFailure.unexpected)),
      );

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    return TaskEither.tryCatch(() => _profileConfigStore.read(id), ProfileFailure.unexpected);
  }

  TaskEither<ProfileFailure, String> _readTempConfig(String tempPath) {
    return TaskEither.tryCatch(() => File(tempPath).readAsString(), ProfileFailure.unexpected);
  }

  Future<String> _validatedOrPreviousUpdatedConfig({
    required String profileId,
    required String tempPath,
    required String? profileOverride,
    required bool debug,
    required bool allowTransientValidationFallback,
  }) async {
    final validation = await validateConfig(tempPath, profileOverride, debug).run();
    return await validation.match((failure) async {
      if (!allowTransientValidationFallback || !_isTransientCoreValidationFailure(failure)) {
        throw failure;
      }
      loggy.warning(
        "profile update validation failed because core is temporarily unavailable; "
        "keeping previous generated config without blocking profile metadata update",
        failure,
      );
      final previousContent = await _profileConfigStore.read(profileId);
      if (!_looksLikeGeneratedJsonConfig(previousContent)) {
        loggy.warning("previous profile config is not generated JSON; refusing transient validation fallback");
        throw failure;
      }
      return previousContent;
    }, Future.value);
  }

  Future<String> _configWithoutValidation({
    required String profileId,
    required String tempPath,
    required bool isUpdate,
  }) async {
    final content = await _readTempConfig(
      tempPath,
    ).run().then((result) => result.getOrElse((failure) => throw failure));
    if (_looksLikeGeneratedJsonConfig(content)) return content;

    if (isUpdate) {
      final previousContent = await _profileConfigStore.read(profileId);
      if (_looksLikeGeneratedJsonConfig(previousContent)) {
        loggy.warning(
          "profile update skipped validation but downloaded content is not generated JSON; keeping previous config",
        );
        return previousContent;
      }
    }

    throw const ProfileFailure.invalidConfig(
      "profile validation skipped but downloaded content is not generated JSON config",
    );
  }

  bool _isTransientCoreValidationFailure(ProfileFailure failure) {
    if (failure case ProfileInvalidConfigFailure(:final message, configOptionFailure: null)) {
      final normalized = (message ?? "").toLowerCase();
      return normalized.contains("core unavailable") ||
          normalized.contains("grpc") ||
          normalized.contains("connection refused") ||
          normalized.contains("http/2") ||
          normalized.contains("transport is closing") ||
          normalized.contains("stream terminated") ||
          normalized.contains("socketexception");
    }
    return false;
  }

  bool _looksLikeGeneratedJsonConfig(String content) {
    try {
      return jsonDecode(content) is Map;
    } catch (_) {
      return false;
    }
  }

  TaskEither<ProfileFailure, Unit> _writeConfig(String id, String content) {
    return TaskEither.tryCatch(() async {
      await _profileConfigStore.write(id, content);
      return unit;
    }, ProfileFailure.unexpected);
  }

  ProfileFailure _profileFailure(Object error, StackTrace stackTrace) {
    return error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace);
  }
}
