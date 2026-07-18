import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/haptic/haptic_service.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/profile/add/model/free_profiles_model.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/model/profile_failure.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/utils/riverpod_utils.dart';
import 'package:zeon/utils/utils.dart';

part 'profile_notifier.g.dart';

@riverpod
class AddProfileNotifier extends _$AddProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      loggy.debug("disposing");
      _cancelToken?.cancel();
    });
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.save.success);
        case AsyncError(:final error):
          if (error case ProfileInvalidUrlFailure()) {
            notification.showErrorToast(t.pages.profiles.msg.invalidUrl);
          } else if (error case ProfileCancelByUserFailure()) {
            return;
          } else {
            ref
                .read(dialogNotifierProvider.notifier)
                .showCustomAlertFromErrWithDiagnostic(
                  t.presentError(error, action: t.pages.profiles.msg.add.failure),
                  diagnosticText: t.diagnosticError(error, action: t.pages.profiles.msg.add.failure),
                );
          }
      }
    });
    ref.onDispose(() {
      if (!(_cancelToken?.isCancelled ?? true)) _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;
  CancelToken? _cancelToken;

  MobileBootstrapImportService get _mobileBootstrapImportService => ref.read(mobileBootstrapImportServiceProvider);

  Future<void> addClipboard(String rawInput) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // final activeProfile = await ref.read(activeProfileProvider.future);
      // final markAsActive = activeProfile == null || ref.read(Preferences.markNewProfileActive);
      final TaskEither<ProfileFailure, Unit> task;
      if (LinkParser.parse(rawInput) case (final rs)?) {
        loggy.debug("adding profile, url: [${_redactUrl(rs.url)}]");
        task = _profilesRepo.upsertRemote(
          rs.url,
          userOverride: rs.name.isNotEmpty ? UserOverride(name: rs.name) : null,
          cancelToken: _cancelToken = CancelToken(),
        );
      } else {
        loggy.debug("adding profile, content");
        task = _profilesRepo.addLocal(safeDecodeBase64(rawInput));
      }
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile");
              unawaited(_mobileBootstrapImportService.pruneToSingleProfileIfManaged());
              return unit;
            },
          )
          .run();
    });
  }

  String _redactUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return '<redacted>';
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: '/…').toString();
  }

  Future<void> addManual({required String url, required UserOverride userOverride}) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final task = _profilesRepo.upsertRemote(url, userOverride: userOverride);
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added profile, mark as active? [true]");
              unawaited(_mobileBootstrapImportService.pruneToSingleProfileIfManaged());
              return r;
            },
          )
          .run();
    });
  }

  Future<void> addMobileAccount() async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final imported = await _mobileBootstrapImportService.runOrThrow(skipIfAlreadyDone: false);
      if (!imported) {
        throw const ProfileFailure.unexpected("mobile account import returned no data");
      }
      return unit;
    });
  }
}

@riverpod
class UpdateProfileNotifier extends _$UpdateProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build(String id) {
    ref.disposeDelay(const Duration(minutes: 1));
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.update.success);
        case AsyncError(:final error):
          ref
              .read(dialogNotifierProvider.notifier)
              .showCustomAlertFromErrWithDiagnostic(
                t.presentError(error, action: t.pages.profiles.msg.update.failure),
                diagnosticText: t.diagnosticError(error, action: t.pages.profiles.msg.update.failure),
              );
      }
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;

  Future<void> updateProfile(RemoteProfileEntity profile) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    final proxyOnly = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    state = await AsyncValue.guard(() async {
      return await _profilesRepo
          .upsertRemote(profile.url, proxyOnly: proxyOnly)
          .match(
            (err) {
              loggy.warning("failed to update profile", err);
              throw err;
            },
            (_) async {
              loggy.info('successfully updated profile');

              await ref.read(activeProfileProvider.future).then((active) async {
                if (active != null && active.id == profile.id) {
                  await ref.read(connectionNotifierProvider.notifier).reconnect(profile);
                }
              });
              return unit;
            },
          )
          .run();
    });
  }
}

@riverpod
class FreeSwitchNotifier extends _$FreeSwitchNotifier {
  @override
  bool build() {
    return false;
  }

  Future<void> onChange(bool value) async => state = value;
}

@riverpod
class AddProfilePageNotifier extends _$AddProfilePageNotifier {
  @override
  AddProfilePages build() => AddProfilePages.options;

  void goOptions() => state = AddProfilePages.options;
  void goManual() => state = AddProfilePages.manual;
}

enum AddProfilePages { options, manual }

@riverpod
class FreeProfilesNotifier extends _$FreeProfilesNotifier {
  @override
  Future<List<FreeProfile>> build() async {
    final httpClient = ref.watch(httpClientProvider);
    final res = await httpClient.get(
      'https://raw.githubusercontent.com/zeon/zeon-app/refs/heads/main/test.configs/free_configs',
    );
    if (res.statusCode == 200) {
      return FreeProfilesModel.fromJson(jsonDecode(res.data.toString()) as Map<String, dynamic>).profiles;
    }
    return <FreeProfile>[];
  }
}

@riverpod
Future<List<FreeProfile>> freeProfilesFilteredByRegion(Ref ref) async {
  final freeProfiles = await ref.watch(freeProfilesNotifierProvider.future);
  final region = ref.watch(ConfigOptions.region);
  return freeProfiles.where((e) => e.region.contains(region.name) || e.region.isEmpty).toList();
}
