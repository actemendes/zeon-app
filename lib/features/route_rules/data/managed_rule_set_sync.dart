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
import 'package:zeon/features/route_rules/data/managed_rule_set.dart';
import 'package:zeon/utils/custom_loggers.dart';

enum ManagedRuleSetSyncResult { updated, notModified, skipped, failed }

class ManagedRuleSetFetchResult {
  const ManagedRuleSetFetchResult({required this.notModified, required this.envelope, required this.eTag});

  factory ManagedRuleSetFetchResult.modified(ManagedRuleSetEnvelope envelope, {String? eTag}) =>
      ManagedRuleSetFetchResult(notModified: false, envelope: envelope, eTag: eTag);

  factory ManagedRuleSetFetchResult.notModified({String? eTag}) =>
      ManagedRuleSetFetchResult(notModified: true, envelope: null, eTag: eTag);

  final bool notModified;
  final ManagedRuleSetEnvelope? envelope;
  final String? eTag;
}

abstract interface class ManagedRuleSetRemoteDataSource {
  Future<ManagedRuleSetFetchResult> fetch({String? eTag});
}

class ManagedRuleSetApiDataSource implements ManagedRuleSetRemoteDataSource {
  ManagedRuleSetApiDataSource({required DioHttpClient httpClient, String? apiBaseUrl})
    : _httpClient = httpClient,
      _apiBaseUrl = apiBaseUrl ?? MobileApiProxyRoute.apiBaseUrl;

  final DioHttpClient _httpClient;
  final String _apiBaseUrl;

  @override
  Future<ManagedRuleSetFetchResult> fetch({String? eTag}) async {
    final baseUri = Uri.tryParse(_apiBaseUrl.trim());
    if (baseUri == null || !baseUri.hasScheme || baseUri.host.isEmpty) {
      throw const RuleSetValidationException('invalid managed rule-set API URL');
    }
    final uri = baseUri.resolve('/routing/v1/rule-sets/current').toString();
    final normalizedETag = _normalizeETag(eTag);

    try {
      final response = await _httpClient.get<dynamic>(
        uri,
        headers: {'Accept': 'application/json', if (normalizedETag != null) 'If-None-Match': normalizedETag},
        disableRetry: true,
      );
      if (response.statusCode == HttpStatus.notModified) {
        return ManagedRuleSetFetchResult.notModified(eTag: _responseETag(response) ?? normalizedETag);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw RuleSetValidationException('unexpected rule-set status ${response.statusCode ?? 0}');
      }
      return ManagedRuleSetFetchResult.modified(
        parseManagedRuleSetApiBody(response.data),
        eTag: _responseETag(response),
      );
    } on DioException catch (error) {
      // Dio's default validateStatus rejects 304 before returning a Response.
      if (error.response?.statusCode == HttpStatus.notModified) {
        return ManagedRuleSetFetchResult.notModified(eTag: _responseETag(error.response!) ?? normalizedETag);
      }
      rethrow;
    }
  }
}

ManagedRuleSetEnvelope parseManagedRuleSetApiBody(Object? body) {
  Object? decoded = body;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on Object {
      throw const RuleSetValidationException('invalid managed rule-set response JSON');
    }
  }
  if (decoded is! Map) {
    throw const RuleSetValidationException('managed rule-set response must be an object');
  }

  final root = Map<String, dynamic>.from(decoded);
  Map<String, dynamic> envelopeJson;
  if (root.containsKey('formatVersion') && root.containsKey('generation')) {
    envelopeJson = root;
  } else {
    if (root['ok'] != true || root['data'] is! Map) {
      throw const RuleSetValidationException('invalid managed rule-set API response');
    }
    envelopeJson = Map<String, dynamic>.from(root['data'] as Map);
  }
  return ManagedRuleSetEnvelope.fromJson(envelopeJson);
}

class ManagedRuleSetSyncService with InfraLogger {
  ManagedRuleSetSyncService({
    required ManagedRuleSetRemoteDataSource remoteDataSource,
    required ManagedRuleSetStore store,
    required SharedPreferences preferences,
    DateTime Function()? now,
    this.ttl = const Duration(hours: 24),
  }) : _remoteDataSource = remoteDataSource,
       _store = store,
       _preferences = preferences,
       _now = now ?? (() => DateTime.now().toUtc());

  static const lastSuccessfulCheckKey = 'managed_rule_sets_last_successful_check';
  static const eTagKey = 'managed_rule_sets_etag';
  static const activeGenerationKey = 'managed_rule_sets_active_generation';
  static const activeChecksumKey = 'managed_rule_sets_active_checksum';

  final ManagedRuleSetRemoteDataSource _remoteDataSource;
  final ManagedRuleSetStore _store;
  final SharedPreferences _preferences;
  final DateTime Function() _now;
  final Duration ttl;

  Future<ManagedRuleSetSyncResult>? _inFlight;
  bool _inFlightIsForced = false;

  Future<ManagedRuleSetSyncResult> sync({bool force = false, String reason = 'scheduled'}) {
    final running = _inFlight;
    if (running != null) {
      // A subscription refresh is an explicit freshness boundary. If it races
      // a TTL-governed background check, queue one forced pass after that check
      // instead of silently inheriting a possible `skipped` result.
      if (force && !_inFlightIsForced) {
        return running.then((_) => sync(force: true, reason: reason));
      }
      return running;
    }

    late final Future<ManagedRuleSetSyncResult> task;
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

  Future<ManagedRuleSetSyncResult> _sync({required bool force, required String reason}) async {
    try {
      final checkedAt = _now().toUtc();
      final current = await _store.readActiveBundle();
      final previousCheck = DateTime.tryParse(_preferences.getString(lastSuccessfulCheckKey) ?? '')?.toUtc();
      final currentIsFresh = current != null && current.bundle.expiresAt.isAfter(checkedAt);
      final cachedIdentityMatches =
          current != null &&
          _preferences.getInt(activeGenerationKey) == current.envelope.generation &&
          _preferences.getString(activeChecksumKey) == current.envelope.checksum;
      if (!force &&
          currentIsFresh &&
          cachedIdentityMatches &&
          previousCheck != null &&
          checkedAt.isBefore(previousCheck.add(ttl))) {
        return ManagedRuleSetSyncResult.skipped;
      }
      // active.json recovery can move the client from generation N back to its
      // N-1 LKG. Generation N's ETag must never validate that older snapshot.
      final previousETag = cachedIdentityMatches ? _normalizeETag(_preferences.getString(eTagKey)) : null;
      final fetched = await _remoteDataSource.fetch(eTag: previousETag);
      if (fetched.notModified) {
        if (!currentIsFresh) {
          // Do not extend the TTL of an absent/expired LKG on an unexpected
          // 304. Clearing the validator makes the next attempt unconditional.
          await _preferences.remove(eTagKey);
          throw const RuleSetValidationException('304 without a fresh active rule-set bundle');
        }
        await _recordSuccessfulCheck(checkedAt, current.envelope, fetched.eTag ?? previousETag);
        loggy.debug('managed rule-set check not modified [reason=$reason]');
        return ManagedRuleSetSyncResult.notModified;
      }

      final envelope = fetched.envelope;
      if (envelope == null) {
        throw const RuleSetValidationException('missing managed rule-set envelope');
      }
      final changed =
          current == null ||
          envelope.generation != current.envelope.generation ||
          envelope.checksum != current.envelope.checksum;
      final installed = await _store.installEnvelope(envelope);
      await _recordSuccessfulCheck(checkedAt, installed.envelope, fetched.eTag);
      loggy.info(
        'managed rule-set bundle accepted '
        '[reason=$reason generation=${installed.envelope.generation} changed=$changed]',
      );
      return changed ? ManagedRuleSetSyncResult.updated : ManagedRuleSetSyncResult.notModified;
    } on Object catch (error, stackTrace) {
      // Managed routing is optional. The core continues with the active LKG or
      // its embedded fallback, and profile/VPN workflows must not fail here.
      loggy.warning('managed rule-set sync failed [reason=$reason]', error, stackTrace);
      return ManagedRuleSetSyncResult.failed;
    }
  }

  Future<void> _recordSuccessfulCheck(DateTime checkedAt, ManagedRuleSetEnvelope activeEnvelope, String? eTag) async {
    await _preferences.setString(lastSuccessfulCheckKey, checkedAt.toIso8601String());
    await _preferences.setInt(activeGenerationKey, activeEnvelope.generation);
    await _preferences.setString(activeChecksumKey, activeEnvelope.checksum);
    final normalized = _normalizeETag(eTag);
    if (normalized == null) {
      await _preferences.remove(eTagKey);
    } else {
      await _preferences.setString(eTagKey, normalized);
    }
  }
}

final managedRuleSetRemoteDataSourceProvider = Provider<ManagedRuleSetRemoteDataSource>((ref) {
  return ManagedRuleSetApiDataSource(httpClient: ref.watch(httpClientProvider));
});

final managedRuleSetStoreProvider = Provider<ManagedRuleSetStore>((ref) {
  final workingDirectory = ref.watch(appDirectoriesProvider).requireValue.workingDir;
  return ManagedRuleSetStore(directory: Directory(p.join(workingDirectory.path, 'data', 'rule-sets', 'managed')));
});

final managedRuleSetSyncServiceProvider = Provider<ManagedRuleSetSyncService>((ref) {
  return ManagedRuleSetSyncService(
    remoteDataSource: ref.watch(managedRuleSetRemoteDataSourceProvider),
    store: ref.watch(managedRuleSetStoreProvider),
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
  );
});

String? _normalizeETag(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _responseETag(Response<dynamic> response) {
  final values = response.headers.map['etag'] ?? response.headers.map['ETag'];
  return values == null || values.isEmpty ? null : _normalizeETag(values.first);
}
