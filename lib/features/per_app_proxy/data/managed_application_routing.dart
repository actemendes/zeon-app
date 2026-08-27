import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/utils/custom_loggers.dart';

enum ManagedApplicationPlatform { android, windows }

enum ManagedApplicationRoute { direct, vpn, block }

const managedApplicationFormatVersion = 1;
const managedApplicationMaxEntries = 5000;

abstract final class ManagedApplicationFreshDefaults {
  static const pendingKey = 'managed_applications_fresh_defaults_pending';
  static const completedKey = 'managed_applications_fresh_defaults_completed';

  static Future<void> markPending(SharedPreferences preferences) async {
    if (preferences.getBool(completedKey) == true) return;
    await preferences.setBool(pendingKey, true);
  }

  static bool shouldApply(SharedPreferences preferences, {required bool firstLaunch}) =>
      firstLaunch || preferences.getBool(pendingKey) == true;

  static Future<void> complete(SharedPreferences preferences) async {
    await preferences.setBool(completedKey, true);
    await preferences.remove(pendingKey);
  }
}

final RegExp _androidPackagePattern = RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$');
final RegExp _windowsApplicationIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._!#@%+={} -]*$');
final RegExp _controlCharacterPattern = RegExp(r'[\u0000-\u001f\u007f]');

class ManagedApplicationValidationException implements Exception {
  const ManagedApplicationValidationException(this.message);

  final String message;

  @override
  String toString() => 'ManagedApplicationValidationException: $message';
}

class ManagedApplication {
  const ManagedApplication({
    required this.id,
    required this.platform,
    required this.stableIdentifier,
    required this.displayName,
    required this.route,
    required this.enabled,
    required this.sortOrder,
    this.iconRef,
  });

  final String id;
  final ManagedApplicationPlatform platform;
  final String stableIdentifier;
  final String displayName;
  final String? iconRef;
  final ManagedApplicationRoute route;
  final bool enabled;
  final int sortOrder;

  factory ManagedApplication.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {
      'id',
      'platform',
      'stableIdentifier',
      'displayName',
      'iconRef',
      'route',
      'enabled',
      'sortOrder',
    });
    final id = json['id'];
    final platform = json['platform'];
    final stableIdentifier = json['stableIdentifier'];
    final displayName = json['displayName'];
    final iconRef = json['iconRef'];
    final route = json['route'];
    final enabled = json['enabled'];
    final sortOrder = json['sortOrder'];
    if (id is! String || id.trim().isEmpty || id.length > 128 || _controlCharacterPattern.hasMatch(id)) {
      throw const ManagedApplicationValidationException('invalid application id');
    }
    if (platform is! String || stableIdentifier is! String || displayName is! String || route is! String) {
      throw const ManagedApplicationValidationException('invalid managed application schema');
    }
    final parsedPlatform = _parsePlatform(platform);
    final normalizedIdentifier = stableIdentifier.trim();
    if (normalizedIdentifier.isEmpty ||
        normalizedIdentifier.length > 260 ||
        _controlCharacterPattern.hasMatch(normalizedIdentifier) ||
        (parsedPlatform == ManagedApplicationPlatform.android
            ? !_androidPackagePattern.hasMatch(normalizedIdentifier)
            : !_windowsApplicationIdentifierPattern.hasMatch(normalizedIdentifier))) {
      throw const ManagedApplicationValidationException('invalid stable application identifier');
    }
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty || normalizedName.length > 128 || _controlCharacterPattern.hasMatch(normalizedName)) {
      throw const ManagedApplicationValidationException('invalid display name');
    }
    if (iconRef != null &&
        (iconRef is! String ||
            iconRef.trim().isEmpty ||
            iconRef.length > 512 ||
            _controlCharacterPattern.hasMatch(iconRef))) {
      throw const ManagedApplicationValidationException('invalid icon reference');
    }
    final normalizedIconRef = iconRef is String ? iconRef.trim() : null;
    if (enabled is! bool || sortOrder is! int || sortOrder < -100000 || sortOrder > 100000) {
      throw const ManagedApplicationValidationException('invalid managed application state');
    }
    return ManagedApplication(
      id: id.trim(),
      platform: parsedPlatform,
      stableIdentifier: normalizedIdentifier,
      displayName: normalizedName,
      iconRef: normalizedIconRef,
      route: _parseRoute(route),
      enabled: enabled,
      sortOrder: sortOrder,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'platform': platform.name,
    'stableIdentifier': stableIdentifier,
    'displayName': displayName,
    'iconRef': iconRef,
    'route': route.name.toUpperCase(),
    'enabled': enabled,
    'sortOrder': sortOrder,
  };
}

class ManagedApplicationConfig {
  ManagedApplicationConfig({
    required this.formatVersion,
    required this.version,
    required this.updatedAt,
    required Iterable<ManagedApplication> applications,
  }) : applications = List<ManagedApplication>.unmodifiable(_normalizeApplications(applications));

  final int formatVersion;
  final int version;
  final DateTime updatedAt;
  final List<ManagedApplication> applications;

  factory ManagedApplicationConfig.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {'formatVersion', 'version', 'updatedAt', 'applications'});
    final formatVersion = json['formatVersion'];
    final version = json['version'];
    final updatedAt = json['updatedAt'];
    final applications = json['applications'];
    if (formatVersion != managedApplicationFormatVersion || version is! int || version < 1) {
      throw const ManagedApplicationValidationException('unsupported managed application config');
    }
    if (updatedAt is! String || applications is! List || applications.length > managedApplicationMaxEntries) {
      throw const ManagedApplicationValidationException('invalid managed application config schema');
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAt)?.toUtc();
    if (parsedUpdatedAt == null) {
      throw const ManagedApplicationValidationException('invalid managed application update time');
    }
    return ManagedApplicationConfig(
      formatVersion: managedApplicationFormatVersion,
      version: version,
      updatedAt: parsedUpdatedAt,
      applications: applications.map((value) {
        if (value is! Map) {
          throw const ManagedApplicationValidationException('application entry must be an object');
        }
        return ManagedApplication.fromJson(Map<String, dynamic>.from(value));
      }),
    );
  }

  factory ManagedApplicationConfig.embedded() => ManagedApplicationConfig(
    formatVersion: managedApplicationFormatVersion,
    version: 1,
    updatedAt: DateTime.utc(2026, 7, 22),
    applications: <ManagedApplication>[
      for (final (index, identifier) in embeddedAndroidDirectApplicationIds.indexed)
        ManagedApplication(
          id: 'android:$identifier',
          platform: ManagedApplicationPlatform.android,
          stableIdentifier: identifier,
          // The historical baseline contained package IDs only. Android
          // resolves the user-facing name and icon from InstalledApps.
          displayName: identifier,
          route: ManagedApplicationRoute.direct,
          enabled: true,
          sortOrder: index,
        ),
    ],
  );

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'version': version,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'applications': applications.map((application) => application.toJson()).toList(growable: false),
  };
}

const embeddedAndroidDirectApplicationIds = <String>[
  'com.apteka.sklad',
  'com.avito.android',
  'com.carshering',
  'com.gnivts.selfemployed',
  'com.magnit.delivery.courier',
  'com.platfomni.vita',
  'com.profibackoffice.reactnative',
  'com.uma.musicvk',
  'com.vk.equals',
  'com.vk.im',
  'com.vk.vkvideo',
  'com.vkontakte.android',
  'com.vtosters.lite',
  'com.wildberries.ru',
  'com.yandex.bank',
  'com.yandex.searchapp',
  'ru.apteki.plus',
  'ru.belkacar.belkacar',
  'ru.dublgis.dgismobile',
  'ru.fns.lkfl',
  'ru.gazprombank.android.mobilebank.app',
  'ru.gosuslugi.auto',
  'ru.gosuslugi.goskey',
  'ru.kinopoisk',
  'ru.mail.cloud',
  'ru.mail.mailapp',
  'ru.megafon.mlk',
  'ru.mts.mymts',
  'ru.nspk.mirpay',
  'ru.oneme.app',
  'ru.ozon.app.android',
  'ru.parkomatica',
  'ru.poryadok.poryadok_flutter_app',
  'ru.profi.client',
  'ru.pyaterochka.app.browser',
  'ru.qugo.mobile',
  'ru.rostel',
  'ru.sbcs.store',
  'ru.sberbankmobile',
  'ru.tander.magnit',
  'ru.tele2.mytele2',
  'ru.vk.store',
  'ru.yandex.disk',
  'ru.yandex.taxi',
  'ru.yandex.taximeter',
  'ru.yandex.telemost',
  'ru.zenmoney.androidsub',
  'shop.tornado.store',
  'youdrive.today',
];

class ManagedApplicationStore {
  ManagedApplicationStore({required this.directory});

  final Directory directory;

  File get activeFile => File(p.join(directory.path, 'active.json'));
  File get temporaryFile => File(p.join(directory.path, 'active.json.tmp'));
  File get lastKnownGoodFile => File(p.join(directory.path, 'active.json.lkg'));

  Future<ManagedApplicationConfig?> readActive() async {
    final active = await _readFile(activeFile);
    if (active != null) return active;
    final lkg = await _readFile(lastKnownGoodFile);
    if (lkg != null) {
      await directory.create(recursive: true);
      if (await activeFile.exists()) await activeFile.delete();
      await lastKnownGoodFile.copy(activeFile.path);
      return lkg;
    }
    return null;
  }

  Future<ManagedApplicationConfig> readEffective() async => await readActive() ?? ManagedApplicationConfig.embedded();

  Future<ManagedApplicationConfig> install(ManagedApplicationConfig candidate) async {
    final current = await readActive();
    if (current != null && candidate.version < current.version) {
      throw const ManagedApplicationValidationException('managed application version rollback');
    }
    await directory.create(recursive: true);
    await temporaryFile.writeAsString(jsonEncode(candidate.toJson()), flush: true);
    final verified = await _readFile(temporaryFile);
    if (verified == null || verified.version != candidate.version) {
      throw const ManagedApplicationValidationException('managed application temporary file validation failed');
    }

    if (await lastKnownGoodFile.exists()) await lastKnownGoodFile.delete();
    if (await activeFile.exists()) await activeFile.rename(lastKnownGoodFile.path);
    try {
      await temporaryFile.rename(activeFile.path);
    } on Object {
      if (await lastKnownGoodFile.exists() && !await activeFile.exists()) {
        await lastKnownGoodFile.copy(activeFile.path);
      }
      rethrow;
    }
    return verified;
  }

  Future<ManagedApplicationConfig?> _readFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 2 << 20) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      return ManagedApplicationConfig.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return null;
    }
  }
}

class ManagedApplicationFetchResult {
  const ManagedApplicationFetchResult({required this.notModified, required this.config, required this.eTag});

  final bool notModified;
  final ManagedApplicationConfig? config;
  final String? eTag;
}

abstract interface class ManagedApplicationRemoteDataSource {
  Future<ManagedApplicationFetchResult> fetch({String? eTag});
}

class ManagedApplicationApiDataSource implements ManagedApplicationRemoteDataSource {
  ManagedApplicationApiDataSource({required DioHttpClient httpClient, String? apiBaseUrl})
    : _httpClient = httpClient,
      _apiBaseUrl = apiBaseUrl ?? MobileApiProxyRoute.apiBaseUrl;

  final DioHttpClient _httpClient;
  final String _apiBaseUrl;

  @override
  Future<ManagedApplicationFetchResult> fetch({String? eTag}) async {
    final baseUri = Uri.tryParse(_apiBaseUrl.trim());
    if (baseUri == null || !baseUri.hasScheme || baseUri.host.isEmpty) {
      throw const ManagedApplicationValidationException('invalid managed application API URL');
    }
    final normalizedETag = _normalizeETag(eTag);
    try {
      final response = await _httpClient.get<dynamic>(
        baseUri.resolve('/routing/v1/applications/current').toString(),
        headers: {'Accept': 'application/json', if (normalizedETag != null) 'If-None-Match': normalizedETag},
        disableRetry: true,
      );
      if (response.statusCode == HttpStatus.notModified) {
        return ManagedApplicationFetchResult(
          notModified: true,
          config: null,
          eTag: _responseETag(response) ?? normalizedETag,
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw ManagedApplicationValidationException(
          'unexpected managed application status ${response.statusCode ?? 0}',
        );
      }
      return ManagedApplicationFetchResult(
        notModified: false,
        config: parseManagedApplicationApiBody(response.data),
        eTag: _responseETag(response),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == HttpStatus.notModified) {
        return ManagedApplicationFetchResult(
          notModified: true,
          config: null,
          eTag: _responseETag(error.response!) ?? normalizedETag,
        );
      }
      rethrow;
    }
  }
}

ManagedApplicationConfig parseManagedApplicationApiBody(Object? body) {
  Object? decoded = body;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on Object {
      throw const ManagedApplicationValidationException('invalid managed application response JSON');
    }
  }
  if (decoded is! Map) {
    throw const ManagedApplicationValidationException('managed application response must be an object');
  }
  final root = Map<String, dynamic>.from(decoded);
  final data = root['ok'] == true && root['data'] is Map ? Map<String, dynamic>.from(root['data'] as Map) : root;
  return ManagedApplicationConfig.fromJson(data);
}

enum ManagedApplicationSyncResult { updated, notModified, skipped, failed }

class ManagedApplicationSyncService with InfraLogger {
  ManagedApplicationSyncService({
    required ManagedApplicationRemoteDataSource remoteDataSource,
    required ManagedApplicationStore store,
    required SharedPreferences preferences,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 15),
    this.onChanged,
  }) : _remoteDataSource = remoteDataSource,
       _store = store,
       _preferences = preferences,
       _now = now ?? (() => DateTime.now().toUtc());

  static const lastSuccessfulCheckKey = 'managed_applications_last_successful_check';
  static const eTagKey = 'managed_applications_etag';
  static const activeVersionKey = 'managed_applications_active_version';

  final ManagedApplicationRemoteDataSource _remoteDataSource;
  final ManagedApplicationStore _store;
  final SharedPreferences _preferences;
  final DateTime Function() _now;
  final Duration ttl;
  final void Function()? onChanged;

  Future<ManagedApplicationSyncResult>? _inFlight;
  bool _inFlightIsForced = false;

  Future<ManagedApplicationSyncResult> sync({bool force = false, String reason = 'scheduled'}) {
    final running = _inFlight;
    if (running != null) {
      if (force && !_inFlightIsForced) {
        return running.then((_) => sync(force: true, reason: reason));
      }
      return running;
    }

    late final Future<ManagedApplicationSyncResult> task;
    _inFlightIsForced = force;
    task = _sync(force: force, reason: reason).whenComplete(() {
      if (identical(_inFlight, task)) {
        _inFlight = null;
        _inFlightIsForced = false;
      }
    });
    _inFlight = task;
    return task;
  }

  Future<ManagedApplicationSyncResult> _sync({required bool force, required String reason}) async {
    try {
      final checkedAt = _now().toUtc();
      final current = await _store.readActive();
      final previousCheck = DateTime.tryParse(_preferences.getString(lastSuccessfulCheckKey) ?? '')?.toUtc();
      final identityMatches = current != null && _preferences.getInt(activeVersionKey) == current.version;
      if (!force && identityMatches && previousCheck != null && checkedAt.isBefore(previousCheck.add(ttl))) {
        return ManagedApplicationSyncResult.skipped;
      }
      final previousETag = identityMatches ? _normalizeETag(_preferences.getString(eTagKey)) : null;
      final fetched = await _remoteDataSource.fetch(eTag: previousETag);
      if (fetched.notModified) {
        if (current == null) {
          await _preferences.remove(eTagKey);
          throw const ManagedApplicationValidationException('304 without active managed application config');
        }
        await _record(checkedAt, current.version, fetched.eTag ?? previousETag);
        return ManagedApplicationSyncResult.notModified;
      }
      final candidate = fetched.config;
      if (candidate == null) {
        throw const ManagedApplicationValidationException('missing managed application config');
      }
      final changed = current == null || current.version != candidate.version;
      final installed = await _store.install(candidate);
      await _record(checkedAt, installed.version, fetched.eTag);
      if (changed) onChanged?.call();
      loggy.info('managed application config accepted [reason=$reason version=${installed.version} changed=$changed]');
      return changed ? ManagedApplicationSyncResult.updated : ManagedApplicationSyncResult.notModified;
    } on Object catch (error, stackTrace) {
      loggy.warning('managed application sync failed [reason=$reason]', error, stackTrace);
      return ManagedApplicationSyncResult.failed;
    }
  }

  Future<void> _record(DateTime checkedAt, int version, String? eTag) async {
    await _preferences.setString(lastSuccessfulCheckKey, checkedAt.toIso8601String());
    await _preferences.setInt(activeVersionKey, version);
    final normalizedETag = _normalizeETag(eTag);
    if (normalizedETag == null) {
      await _preferences.remove(eTagKey);
    } else {
      await _preferences.setString(eTagKey, normalizedETag);
    }
  }
}

class ManagedApplicationRuleCompiler {
  const ManagedApplicationRuleCompiler();

  List<Map<String, dynamic>> compile(
    ManagedApplicationConfig config, {
    required ManagedApplicationPlatform platform,
    Set<String> disabledIdentifiers = const <String>{},
  }) {
    final grouped = <ManagedApplicationRoute, List<String>>{};
    for (final application in config.applications) {
      if (!application.enabled ||
          application.platform != platform ||
          disabledIdentifiers.contains(application.stableIdentifier)) {
        continue;
      }
      (grouped[application.route] ??= <String>[]).add(application.stableIdentifier);
    }
    return <Map<String, dynamic>>[
      for (final route in <ManagedApplicationRoute>[
        ManagedApplicationRoute.block,
        ManagedApplicationRoute.direct,
        ManagedApplicationRoute.vpn,
      ])
        if (grouped[route]?.isNotEmpty ?? false)
          <String, dynamic>{
            'enabled': true,
            'name': 'managed applications ${route.name.toUpperCase()} v${config.version}',
            'outbound': switch (route) {
              ManagedApplicationRoute.vpn => 0,
              ManagedApplicationRoute.direct => 1,
              ManagedApplicationRoute.block => 3,
            },
            'package_names': grouped[route],
          },
    ];
  }
}

final managedApplicationStoreProvider = Provider<ManagedApplicationStore>((ref) {
  final workingDirectory = ref.watch(appDirectoriesProvider).requireValue.workingDir;
  return ManagedApplicationStore(
    directory: Directory(p.join(workingDirectory.path, 'data', 'applications', 'managed')),
  );
});

final managedApplicationConfigProvider = FutureProvider<ManagedApplicationConfig>((ref) {
  return ref.watch(managedApplicationStoreProvider).readEffective();
});

final managedApplicationRemoteDataSourceProvider = Provider<ManagedApplicationRemoteDataSource>((ref) {
  return ManagedApplicationApiDataSource(httpClient: ref.watch(httpClientProvider));
});

final managedApplicationSyncServiceProvider = Provider<ManagedApplicationSyncService>((ref) {
  return ManagedApplicationSyncService(
    remoteDataSource: ref.watch(managedApplicationRemoteDataSourceProvider),
    store: ref.watch(managedApplicationStoreProvider),
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    onChanged: () => ref.invalidate(managedApplicationConfigProvider),
  );
});

List<ManagedApplication> _normalizeApplications(Iterable<ManagedApplication> applications) {
  final values = applications.toList(growable: false);
  if (values.length > managedApplicationMaxEntries) {
    throw const ManagedApplicationValidationException('too many managed applications');
  }
  final identities = <String>{};
  final ids = <String>{};
  for (final application in values) {
    final identity = '${application.platform.name}:${application.stableIdentifier.toLowerCase()}';
    if (!ids.add(application.id) || !identities.add(identity)) {
      throw const ManagedApplicationValidationException('duplicate managed application');
    }
  }
  values.sort((left, right) {
    final platform = left.platform.name.compareTo(right.platform.name);
    if (platform != 0) return platform;
    final order = left.sortOrder.compareTo(right.sortOrder);
    if (order != 0) return order;
    return left.stableIdentifier.compareTo(right.stableIdentifier);
  });
  return values;
}

ManagedApplicationPlatform _parsePlatform(String value) {
  final normalized = value.toLowerCase();
  for (final platform in ManagedApplicationPlatform.values) {
    if (platform.name == normalized) return platform;
  }
  throw const ManagedApplicationValidationException('unsupported managed application platform');
}

ManagedApplicationRoute _parseRoute(String value) {
  final normalized = value.toLowerCase();
  for (final route in ManagedApplicationRoute.values) {
    if (route.name == normalized) return route;
  }
  throw const ManagedApplicationValidationException('unsupported managed application route');
}

String? _normalizeETag(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _responseETag(Response<dynamic> response) {
  final values = response.headers.map['etag'] ?? response.headers.map['ETag'];
  return values == null || values.isEmpty ? null : _normalizeETag(values.first);
}

void _expectExactKeys(Map<String, dynamic> value, Set<String> expected) {
  if (value.length != expected.length || !value.keys.every(expected.contains)) {
    throw const ManagedApplicationValidationException('unexpected managed application schema fields');
  }
}
