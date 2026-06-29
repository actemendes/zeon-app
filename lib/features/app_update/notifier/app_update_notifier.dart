import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/utils/preferences_utils.dart';
import 'package:zeon/features/app_update/data/app_update_data_providers.dart';
import 'package:zeon/features/app_update/model/app_update_failure.dart';
import 'package:zeon/features/app_update/model/remote_version_entity.dart';
import 'package:zeon/features/app_update/notifier/app_update_state.dart';
import 'package:zeon/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:upgrader/upgrader.dart';
import 'package:version/version.dart';

part 'app_update_notifier.g.dart';

@riverpod
Upgrader upgrader(Ref ref) =>
    Upgrader(messages: UpgraderMessages(code: ref.watch(localePreferencesProvider).languageCode));

@Riverpod(keepAlive: true)
class AppUpdateNotifier extends _$AppUpdateNotifier with AppLogger {
  @override
  AppUpdateState build() => const AppUpdateState.initial();

  PreferencesEntry<String?, dynamic> get _ignoreReleasePref => PreferencesEntry(
    preferences: ref.read(sharedPreferencesProvider).requireValue,
    key: 'ignored_release_version',
    defaultValue: null,
  );

  PreferencesEntry<String?, dynamic> get _lastAutoNotifiedReleasePref => PreferencesEntry(
    preferences: ref.read(sharedPreferencesProvider).requireValue,
    key: 'last_auto_notified_release_${UpdateChannel.read().key}',
    defaultValue: null,
  );

  Future<RemoteVersionEntity?> checkAutomatically() async {
    final result = await check();
    if (result case AppUpdateStateAvailable(:final versionInfo)) {
      if (_lastAutoNotifiedReleasePref.read() == versionInfo.releaseTag) {
        loggy.debug("release already notified automatically [${versionInfo.releaseTag}]");
        return null;
      }
      await _lastAutoNotifiedReleasePref.write(versionInfo.releaseTag);
      return versionInfo;
    }
    return null;
  }

  Future<AppUpdateState> check() async {
    loggy.debug("checking for update");
    state = const AppUpdateState.checking();
    final updateChannel = UpdateChannel.read();
    final appInfo = ref.watch(appInfoProvider).requireValue;
    if (!appInfo.release.allowCustomUpdateChecker) {
      loggy.debug("custom update checkers are not allowed for [${appInfo.release.name}] release");
      return state = const AppUpdateState.disabled();
    }
    return ref
        .watch(appUpdateRepositoryProvider)
        .getLatestVersion(includePreReleases: updateChannel.includePreReleases)
        .match(
          (err) {
            loggy.warning("failed to get latest version", err);
            return state = AppUpdateState.error(err);
          },
          (remote) {
            try {
              if (!updateChannel.includePreReleases && remote.preRelease) {
                loggy.info("stable channel ignores pre-release [${remote.releaseTag}]");
                return state = const AppUpdateState.notAvailable();
              }
              final latestVersion = Version.parse(remote.version);
              final currentVersion = Version.parse(appInfo.version);
              if (latestVersion > currentVersion) {
                if (remote.version == _ignoreReleasePref.read()) {
                  loggy.debug("ignored release [${remote.version}]");
                  return state = AppUpdateStateIgnored(remote);
                }
                loggy.debug("new version available: $remote");
                return state = AppUpdateState.available(remote);
              }
              loggy.info("already using latest version[$currentVersion], remote: [${remote.version}]");
              return state = const AppUpdateState.notAvailable();
            } catch (error, stackTrace) {
              loggy.warning("error parsing versions", error, stackTrace);
              return state = AppUpdateState.error(AppUpdateFailure.unexpected(error, stackTrace));
            }
          },
        )
        .run();
  }

  Future<void> ignoreRelease(RemoteVersionEntity version) async {
    loggy.debug("ignoring release [${version.version}]");
    await _ignoreReleasePref.write(version.version);
    state = AppUpdateStateIgnored(version);
  }
}
