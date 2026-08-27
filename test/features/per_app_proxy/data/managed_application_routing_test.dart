import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:zeon/features/per_app_proxy/data/managed_application_routing.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/per_app_proxy/model/pkg_flag.dart';

void main() {
  group('managed application schema', () {
    test('embedded v1 is the exact last working 49-package baseline', () {
      final config = ManagedApplicationConfig.embedded();

      expect(config.version, 1);
      expect(config.applications, hasLength(49));
      expect(config.applications.first.stableIdentifier, 'com.apteka.sklad');
      expect(config.applications.last.stableIdentifier, 'youdrive.today');
      expect(
        config.applications,
        everyElement(
          isA<ManagedApplication>()
              .having((value) => value.platform, 'platform', ManagedApplicationPlatform.android)
              .having((value) => value.route, 'route', ManagedApplicationRoute.direct)
              .having((value) => value.enabled, 'enabled', isTrue),
        ),
      );
    });

    test('normalizes deterministic order and rejects duplicate identifiers', () {
      final config = ManagedApplicationConfig.fromJson({
        'formatVersion': 1,
        'version': 2,
        'updatedAt': '2026-08-25T00:00:00Z',
        'applications': [
          _application(id: 'b', identifier: 'com.example.b', sortOrder: 20),
          _application(id: 'a', identifier: 'com.example.a', sortOrder: 10),
        ],
      });
      expect(config.applications.map((value) => value.id), ['a', 'b']);

      expect(
        () => ManagedApplicationConfig.fromJson({
          'formatVersion': 1,
          'version': 2,
          'updatedAt': '2026-08-25T00:00:00Z',
          'applications': [
            _application(id: 'a', identifier: 'com.example.same', sortOrder: 1),
            _application(id: 'b', identifier: 'com.example.same', sortOrder: 2),
          ],
        }),
        throwsA(isA<ManagedApplicationValidationException>()),
      );
    });

    test('accepts the shared Windows identifier and ordering contract', () {
      final config = ManagedApplicationConfig.fromJson({
        'formatVersion': 1,
        'version': 2,
        'updatedAt': '2026-08-25T00:00:00Z',
        'applications': [
          {
            'id': 'windows-example',
            'platform': 'windows',
            'stableIdentifier': 'Example App.exe',
            'displayName': 'Example App',
            'iconRef': null,
            'route': 'DIRECT',
            'enabled': true,
            'sortOrder': -1,
          },
        ],
      });

      expect(config.applications.single.platform, ManagedApplicationPlatform.windows);
      expect(config.applications.single.stableIdentifier, 'Example App.exe');
      expect(config.applications.single.sortOrder, -1);
    });

    test('rejects case-only Windows identifier duplicates', () {
      expect(
        () => ManagedApplicationConfig.fromJson({
          'formatVersion': 1,
          'version': 2,
          'updatedAt': '2026-08-25T00:00:00Z',
          'applications': [
            {
              'id': 'windows-a',
              'platform': 'windows',
              'stableIdentifier': 'Example App.exe',
              'displayName': 'Example A',
              'iconRef': null,
              'route': 'DIRECT',
              'enabled': true,
              'sortOrder': 0,
            },
            {
              'id': 'windows-b',
              'platform': 'windows',
              'stableIdentifier': 'example app.EXE',
              'displayName': 'Example B',
              'iconRef': null,
              'route': 'DIRECT',
              'enabled': true,
              'sortOrder': 1,
            },
          ],
        }),
        throwsA(isA<ManagedApplicationValidationException>()),
      );
    });

    test('rejects malformed and unsupported documents', () {
      for (final body in <Object?>[
        null,
        'not-json',
        {'formatVersion': 2, 'version': 1, 'updatedAt': '2026-08-25T00:00:00Z', 'applications': []},
        {
          'formatVersion': 1,
          'version': 1,
          'updatedAt': 'invalid',
          'applications': [_application(id: 'a', identifier: 'bad package', sortOrder: 0)],
        },
      ]) {
        expect(() => parseManagedApplicationApiBody(body), throwsA(isA<ManagedApplicationValidationException>()));
      }
    });
  });

  group('managed application LKG', () {
    late Directory directory;
    late ManagedApplicationStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('zeon-managed-apps-');
      store = ManagedApplicationStore(directory: directory);
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('falls back to embedded config when no cache exists', () async {
      final effective = await store.readEffective();
      expect(effective.version, 1);
      expect(effective.applications, hasLength(49));
    });

    test('restores the previous valid config when active is malformed', () async {
      await store.install(_config(version: 2, identifier: 'com.example.v2'));
      await store.install(_config(version: 3, identifier: 'com.example.v3'));
      await store.activeFile.writeAsString('{broken', flush: true);

      final recovered = await store.readActive();
      expect(recovered?.version, 2);
      expect((await store.readActive())?.version, 2);
    });

    test('rejects rollback without replacing active config', () async {
      await store.install(_config(version: 3, identifier: 'com.example.v3'));

      await expectLater(
        store.install(_config(version: 2, identifier: 'com.example.v2')),
        throwsA(isA<ManagedApplicationValidationException>()),
      );
      expect((await store.readActive())?.version, 3);
    });
  });

  group('managed application sync', () {
    test('keeps LKG on 304 and bounds ETag use to a proven cache identity', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp('zeon-managed-app-sync-');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final store = ManagedApplicationStore(directory: directory);
      await store.install(_config(version: 2, identifier: 'com.example.lkg'));
      final remote = _FakeRemote(<ManagedApplicationFetchResult>[
        const ManagedApplicationFetchResult(notModified: true, config: null, eTag: '"managed-apps-2"'),
      ]);
      final service = ManagedApplicationSyncService(remoteDataSource: remote, store: store, preferences: preferences);

      expect(await service.sync(force: true), ManagedApplicationSyncResult.notModified);
      expect((await store.readActive())?.version, 2);
      expect(remote.eTags, [null]);
    });

    test('keeps LKG when the remote fetch fails', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp('zeon-managed-app-sync-failure-');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final store = ManagedApplicationStore(directory: directory);
      await store.install(_config(version: 2, identifier: 'com.example.lkg'));
      final service = ManagedApplicationSyncService(
        remoteDataSource: _ThrowingRemote(),
        store: store,
        preferences: preferences,
      );

      expect(await service.sync(force: true), ManagedApplicationSyncResult.failed);
      expect((await store.readActive())?.applications.single.stableIdentifier, 'com.example.lkg');
    });

    test('v1 to v2 atomically adds and removes managed applications', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp('zeon-managed-app-sync-update-');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final store = ManagedApplicationStore(directory: directory);
      await store.install(_config(version: 1, identifier: 'com.example.removed'));
      final v2 = ManagedApplicationConfig(
        formatVersion: 1,
        version: 2,
        updatedAt: DateTime.utc(2026, 8, 25),
        applications: [
          _model(
            id: 'android:com.example.added',
            identifier: 'com.example.added',
            route: ManagedApplicationRoute.direct,
            order: 0,
          ),
        ],
      );
      final service = ManagedApplicationSyncService(
        remoteDataSource: _FakeRemote([
          ManagedApplicationFetchResult(notModified: false, config: v2, eTag: '"managed-apps-2"'),
        ]),
        store: store,
        preferences: preferences,
      );

      expect(await service.sync(force: true), ManagedApplicationSyncResult.updated);
      final active = await store.readActive();
      expect(active?.version, 2);
      expect(active?.applications.map((value) => value.stableIdentifier), ['com.example.added']);
      expect(jsonDecode(await store.lastKnownGoodFile.readAsString())['version'], 1);
    });
  });

  test('fresh defaults pending marker survives startup interruption and completes idempotently', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await ManagedApplicationFreshDefaults.markPending(preferences);
    expect(ManagedApplicationFreshDefaults.shouldApply(preferences, firstLaunch: false), isTrue);

    await ManagedApplicationFreshDefaults.complete(preferences);
    expect(ManagedApplicationFreshDefaults.shouldApply(preferences, firstLaunch: false), isFalse);
    expect(preferences.getBool(ManagedApplicationFreshDefaults.completedKey), isTrue);

    await ManagedApplicationFreshDefaults.markPending(preferences);
    expect(ManagedApplicationFreshDefaults.shouldApply(preferences, firstLaunch: false), isFalse);
  });

  test('compiler emits real package rules and applies per-app override', () {
    final config = ManagedApplicationConfig(
      formatVersion: 1,
      version: 4,
      updatedAt: DateTime.utc(2026, 8, 25),
      applications: [
        _model(id: 'direct-a', identifier: 'com.example.direct', route: ManagedApplicationRoute.direct, order: 1),
        _model(id: 'vpn-a', identifier: 'com.example.vpn', route: ManagedApplicationRoute.vpn, order: 2),
        _model(id: 'block-a', identifier: 'com.example.block', route: ManagedApplicationRoute.block, order: 3),
        _model(
          id: 'windows-a',
          identifier: 'ZEON.Example',
          route: ManagedApplicationRoute.direct,
          order: 4,
          platform: ManagedApplicationPlatform.windows,
        ),
      ],
    );

    final rules = const ManagedApplicationRuleCompiler().compile(
      config,
      platform: ManagedApplicationPlatform.android,
      disabledIdentifiers: {'com.example.direct'},
    );

    expect(rules, hasLength(2));
    expect(rules[0]['outbound'], 3);
    expect(rules[0]['package_names'], ['com.example.block']);
    expect(rules[1]['outbound'], 0);
    expect(rules[1]['package_names'], ['com.example.vpn']);
  });

  test('control-plane and user rules remain ahead of managed applications', () {
    final plan = MobileApiProxyRoute.planCoreRules(
      baseUrl: 'https://api.example.test',
      configuredRules: const [
        {'enabled': true, 'name': 'profile', 'outbound': 1},
      ],
      userRules: const [
        {'enabled': true, 'name': 'user', 'outbound': 0},
      ],
      managedApplicationRules: const [
        {
          'enabled': true,
          'name': 'managed',
          'outbound': 1,
          'package_names': ['com.example.app'],
        },
      ],
    );

    expect(plan.priorityRules.map((rule) => rule['name']), [null, 'user', 'managed']);
    expect(plan.profileRules.map((rule) => rule['name']), ['profile']);
  });

  test('managed per-app override toggles without becoming an OS bypass row', () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);
    final dataSource = AppProxyDao(db);

    await dataSource.toggleManagedPkgOverride(pkg: 'com.example.managed', mode: AppProxyMode.exclude);
    final disabled = await dataSource.getPkgsByFlag(flag: PkgFlag.forceDeselection, mode: AppProxyMode.exclude);
    final activeOsBypass = await dataSource
        .watchActivePackages(phonePkgs: {'com.example.managed'}, mode: AppProxyMode.exclude)
        .first;

    expect(disabled, ['com.example.managed']);
    expect(activeOsBypass, isEmpty);

    await dataSource.toggleManagedPkgOverride(pkg: 'com.example.managed', mode: AppProxyMode.exclude);
    expect(await db.select(db.appProxyEntries).get(), isEmpty);
  });
}

Map<String, Object?> _application({required String id, required String identifier, required int sortOrder}) => {
  'id': id,
  'platform': 'android',
  'stableIdentifier': identifier,
  'displayName': identifier,
  'iconRef': null,
  'route': 'DIRECT',
  'enabled': true,
  'sortOrder': sortOrder,
};

ManagedApplicationConfig _config({required int version, required String identifier}) => ManagedApplicationConfig(
  formatVersion: 1,
  version: version,
  updatedAt: DateTime.utc(2026, 8, 25),
  applications: [
    _model(id: 'android:$identifier', identifier: identifier, route: ManagedApplicationRoute.direct, order: 0),
  ],
);

ManagedApplication _model({
  required String id,
  required String identifier,
  required ManagedApplicationRoute route,
  required int order,
  ManagedApplicationPlatform platform = ManagedApplicationPlatform.android,
}) => ManagedApplication(
  id: id,
  platform: platform,
  stableIdentifier: identifier,
  displayName: identifier,
  route: route,
  enabled: true,
  sortOrder: order,
);

class _FakeRemote implements ManagedApplicationRemoteDataSource {
  _FakeRemote(this.results);

  final List<ManagedApplicationFetchResult> results;
  final List<String?> eTags = [];

  @override
  Future<ManagedApplicationFetchResult> fetch({String? eTag}) async {
    eTags.add(eTag);
    return results.removeAt(0);
  }
}

class _ThrowingRemote implements ManagedApplicationRemoteDataSource {
  @override
  Future<ManagedApplicationFetchResult> fetch({String? eTag}) {
    throw StateError('isolated transport failure');
  }
}
