// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/model/app_info_entity.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app_update/data/app_update_data_providers.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('automatic update notification is emitted only once per release', () async {
    final (:container, :preferences, :repository) = await _createContainer(_remoteVersion('1.1.0'));
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateNotifierProvider.notifier);

    expect(await notifier.checkAutomatically(), repository.latest);
    expect(preferences.getString('last_auto_notified_release_stable'), 'v1.1.0');
    expect(await notifier.checkAutomatically(), isNull);

    repository.latest = _remoteVersion('1.2.0');
    expect(await notifier.checkAutomatically(), repository.latest);
    expect(preferences.getString('last_auto_notified_release_stable'), 'v1.2.0');
  });

  test('manual check remains available after automatic notification', () async {
    final setup = await _createContainer(_remoteVersion('1.1.0'));
    final container = setup.container;
    final repository = setup.repository;
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateNotifierProvider.notifier);

    expect(await notifier.checkAutomatically(), repository.latest);
    expect(await notifier.check(), isA<AppUpdateStateAvailable>());
  });

  test('google play release disables custom update checker', () async {
    final setup = await _createContainer(_remoteVersion('1.1.0'), release: Release.googlePlay);
    final container = setup.container;
    final repository = setup.repository;
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateNotifierProvider.notifier);

    expect(await notifier.checkAutomatically(), isNull);
    expect(container.read(appUpdateNotifierProvider), isA<AppUpdateStateDisabled>());
    expect(repository.callCount, 0);
  });
}

Future<({ProviderContainer container, SharedPreferences preferences, _FakeAppUpdateRepository repository})>
_createContainer(RemoteVersionEntity latest, {Release release = Release.general}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final repository = _FakeAppUpdateRepository(latest);
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      appInfoProvider.overrideWith(() => _TestAppInfo(release)),
      appUpdateRepositoryProvider.overrideWith((ref) => repository),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(appInfoProvider.future);
  return (container: container, preferences: preferences, repository: repository);
}

RemoteVersionEntity _remoteVersion(String version) => RemoteVersionEntity(
  version: version,
  buildNumber: '',
  releaseTag: 'v$version',
  preRelease: false,
  url: 'https://example.com/zeon-$version.apk',
  publishedAt: DateTime.utc(2026),
  flavor: Environment.prod,
);

class _TestAppInfo extends AppInfo {
  _TestAppInfo(this.release);

  final Release release;

  @override
  Future<AppInfoEntity> build() async => AppInfoEntity(
    name: 'ZEON',
    version: '1.0.0',
    buildNumber: '1',
    release: release,
    operatingSystem: 'test',
    operatingSystemVersion: 'test',
    environment: Environment.prod,
  );
}

class _FakeAppUpdateRepository implements AppUpdateRepository {
  _FakeAppUpdateRepository(this.latest);

  RemoteVersionEntity latest;
  int callCount = 0;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    callCount++;
    return TaskEither(() async => right(latest));
  }
}
