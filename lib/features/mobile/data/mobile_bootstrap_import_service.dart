import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/mobile_embedded_bootstrap_profile_service.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final mobileBootstrapImportServiceProvider = Provider<MobileBootstrapImportService>((ref) {
  final preferences = ref.read(sharedPreferencesProvider).requireValue;
  return MobileBootstrapImportService(
    httpClient: ref.read(httpClientProvider),
    stableDeviceIdService: StableDeviceIdService(preferences: preferences),
    profileDataSource: ref.read(profileDataSourceProvider),
    connLinkImportService: ref.read(mobileConnLinkImportServiceProvider),
    embeddedProfileService: ref.read(mobileEmbeddedBootstrapProfileServiceProvider),
    preferences: preferences,
  );
});

class MobileBootstrapImportService with InfraLogger {
  MobileBootstrapImportService({
    required DioHttpClient httpClient,
    required StableDeviceIdService stableDeviceIdService,
    required ProfileDataSource profileDataSource,
    required MobileConnLinkImportService connLinkImportService,
    required MobileEmbeddedBootstrapProfileService embeddedProfileService,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _stableDeviceId = stableDeviceIdService,
       _profileDataSource = profileDataSource,
       _connLinkImportService = connLinkImportService,
       _embeddedProfileService = embeddedProfileService,
       _preferences = preferences;

  static const _apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const _prefDone = MobileConnLinkImportService.prefDone;
  static const _prefUserId = MobileConnLinkImportService.prefUserId;
  static const _prefConnLink = MobileConnLinkImportService.prefConnLink;
  static const _prefManagedProfileId = MobileConnLinkImportService.prefManagedProfileId;

  final DioHttpClient _httpClient;
  final StableDeviceIdService _stableDeviceId;
  final ProfileDataSource _profileDataSource;
  final MobileConnLinkImportService _connLinkImportService;
  final MobileEmbeddedBootstrapProfileService _embeddedProfileService;
  final SharedPreferences _preferences;
  Future<bool>? _runInFlight;
  Future<bool>? _postConnectionRunInFlight;

  Future<bool> run({
    bool skipIfAlreadyDone = true,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) async {
    try {
      return await runOrThrow(skipIfAlreadyDone: skipIfAlreadyDone, mode: mode);
    } catch (_) {
      return false;
    }
  }

  Future<bool> runOrThrow({
    bool skipIfAlreadyDone = true,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) async {
    if (mode == MobileConnLinkImportMode.postConnection) {
      final inFlight = _postConnectionRunInFlight;
      if (inFlight != null) {
        return await inFlight;
      }
      final future = _runOrThrowInternal(skipIfAlreadyDone: skipIfAlreadyDone, mode: mode);
      _postConnectionRunInFlight = future;
      try {
        return await future;
      } finally {
        if (identical(_postConnectionRunInFlight, future)) {
          _postConnectionRunInFlight = null;
        }
      }
    }

    final inFlight = _runInFlight;
    if (inFlight != null) {
      return await inFlight;
    }
    final future = _runOrThrowInternal(skipIfAlreadyDone: skipIfAlreadyDone, mode: mode);
    _runInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_runInFlight, future)) {
        _runInFlight = null;
      }
    }
  }

  Future<bool> _runOrThrowInternal({
    bool skipIfAlreadyDone = true,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) async {
    if (PlatformUtils.isWeb) {
      return false;
    }

    final active = await _activeProfile();
    if (active != null && !_embeddedProfileService.isEmbeddedProfile(active)) {
      if (skipIfAlreadyDone && (_preferences.getBool(_prefDone) ?? false)) {
        _refreshSavedConnLinkMetadataInBackground(active);
        return false;
      }

      loggy.info("mobile auto import: active profile already exists, skipping blocking import");
      _refreshSavedConnLinkMetadataInBackground(active);
      return false;
    }
    if (active != null) {
      loggy.info("mobile auto import: embedded bootstrap profile is active, continuing real import");
    }

    if (skipIfAlreadyDone && (_preferences.getBool(_prefDone) ?? false)) {
      loggy.warning("mobile auto import: done flag is set but no active profile found, retrying import");
    }

    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) {
      throw const MobileBootstrapImportException("mobile api is not configured");
    }

    try {
      final savedUserId = int.tryParse((_preferences.getString(_prefUserId) ?? "").trim());
      final savedConnLink = (_preferences.getString(_prefConnLink) ?? "").trim();
      var effectiveUserId = savedUserId;
      String? apiLogin;
      String? apiStatus;
      DateTime? apiExpiresAt;

      if (savedConnLink.isNotEmpty && Uri.tryParse(savedConnLink) != null) {
        loggy.info("mobile auto import: trying saved conn_link");
        await _connLinkImportService.importConnectionLink(
          savedConnLink,
          userId: effectiveUserId,
          clearUserIdWhenMissing: effectiveUserId == null,
          mode: mode,
        );
        loggy.info("mobile auto import succeeded from saved conn_link");
        return true;
      }

      var connLink = "";
      if (savedUserId != null && savedUserId > 0) {
        final lookup = await _lookupSubscriptionByUserId(savedUserId, disableRetry: mode.isFastPath, mode: mode);
        if (lookup != null) {
          connLink = lookup.connectionLink;
          apiStatus = lookup.status;
          apiExpiresAt = lookup.expiresAt;
        }
      }

      if (connLink.isEmpty) {
        final created = await _createOrReuseUser(userId: savedUserId, disableRetry: mode.isFastPath, mode: mode);
        effectiveUserId = created.userId ?? effectiveUserId;
        apiLogin = created.login;
        apiStatus = created.status ?? apiStatus;
        apiExpiresAt = created.expiresAt ?? apiExpiresAt;
        connLink = created.rawUrl;
      }

      if (connLink.isEmpty && effectiveUserId != null && effectiveUserId > 0) {
        final lookup = await _lookupSubscriptionByUserId(effectiveUserId, disableRetry: mode.isFastPath, mode: mode);
        if (lookup != null) {
          connLink = lookup.connectionLink;
          apiStatus = lookup.status ?? apiStatus;
          apiExpiresAt = lookup.expiresAt ?? apiExpiresAt;
        }
      }

      if (connLink.isEmpty || Uri.tryParse(connLink) == null) {
        throw const MobileBootstrapImportException("connection_link is missing");
      }

      await _connLinkImportService.importConnectionLink(
        connLink,
        userId: effectiveUserId,
        apiStatus: apiStatus,
        apiExpiresAt: apiExpiresAt,
        apiLogin: apiLogin,
        clearUserIdWhenMissing: false,
        mode: mode,
      );

      loggy.info("mobile auto import succeeded");
      return true;
    } catch (e, st) {
      loggy.warning("mobile auto import failed with error", e, st);
      rethrow;
    }
  }

  Future<void> pruneToSingleProfileIfManaged() => _connLinkImportService.pruneToSingleProfileIfManaged();

  Future<void> enforceSingleProfile() => _connLinkImportService.enforceSingleProfile();

  Future<bool> ensureEmbeddedFallbackProfile() => _embeddedProfileService.ensureActiveProfile();

  Future<bool> hasActiveEmbeddedProfile() => _embeddedProfileService.hasActiveEmbeddedProfile();

  Future<bool> canReachBackend({MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard}) async {
    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) return false;

    final uri = Uri.parse(
      _apiBaseUrl,
    ).resolve("/api/v1/subscriptions/lookup").replace(queryParameters: {"user_id": "0"});
    try {
      final response = await _httpClient.get<Map<String, dynamic>>(
        uri.toString(),
        headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
        proxyOnly: mode == MobileConnLinkImportMode.postConnection,
        directOnly: mode != MobileConnLinkImportMode.postConnection,
        disableRetry: true,
      );
      return (response.statusCode ?? 0) > 0;
    } on DioException catch (e) {
      return e.response != null;
    } catch (_) {
      return false;
    }
  }

  Future<ProfileEntry?> _activeProfile() async {
    try {
      return await _profileDataSource.watchActiveProfile().first;
    } catch (_) {
      return null;
    }
  }

  void _refreshSavedConnLinkMetadataInBackground(ProfileEntry active) {
    final savedConnLink = (_preferences.getString(_prefConnLink) ?? "").trim();
    if (savedConnLink.isEmpty) return;

    final managedId = (_preferences.getString(_prefManagedProfileId) ?? "").trim();
    final activeUrl = active.url?.trim();
    final looksManaged = managedId.isEmpty || managedId == active.id || activeUrl == savedConnLink;
    if (!looksManaged) {
      loggy.debug("mobile auto import: skip conn_link metadata refresh, active profile was manually replaced");
      return;
    }

    unawaited(
      _connLinkImportService.refreshActiveProfileMetadata(savedConnLink).timeout(const Duration(seconds: 5)).catchError(
        (Object e, StackTrace st) {
          loggy.debug("mobile auto import: background metadata refresh skipped/failed", e, st);
        },
      ),
    );
  }

  Future<_LookupSummary?> _lookupSubscriptionByUserId(
    int userId, {
    bool disableRetry = false,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) async {
    try {
      final uri = Uri.parse(
        _apiBaseUrl,
      ).resolve("/api/v1/subscriptions/lookup").replace(queryParameters: {"user_id": userId.toString()});
      final response = await _httpClient.get<Map<String, dynamic>>(
        uri.toString(),
        headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
        proxyOnly: mode == MobileConnLinkImportMode.postConnection,
        directOnly: mode != MobileConnLinkImportMode.postConnection,
        disableRetry: disableRetry,
      );
      if ((response.statusCode ?? 0) != 200) return null;
      final body = response.data;
      if (body == null || body["ok"] != true) return null;
      final data = body["data"];
      if (data is! Map<String, dynamic>) return null;

      final connLink = (data["connection_link"]?.toString() ?? "").trim();
      if (connLink.isEmpty) return null;
      return _LookupSummary(
        connectionLink: connLink,
        status: data["status"]?.toString(),
        expiresAt: _parseFlexibleExpire(data["expires_at"]?.toString() ?? ""),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<_CreateResult> _createOrReuseUser({
    int? userId,
    bool disableRetry = false,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) async {
    final deviceId = await _stableDeviceId.getOrCreate();
    final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/users/create").toString();
    final body = <String, dynamic>{
      "user": {if (userId != null && userId > 0) "user_id": userId},
      "subscription": {"create_if_missing": true},
      "device_id": deviceId,
      "platform": _platformName(),
    };
    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: body,
      headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
      proxyOnly: mode == MobileConnLinkImportMode.postConnection,
      directOnly: mode != MobileConnLinkImportMode.postConnection,
      disableRetry: disableRetry,
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode != 200 && statusCode != 201) {
      throw MobileBootstrapImportException("users/create returned status $statusCode");
    }
    final payload = response.data;
    if (payload == null || payload["ok"] != true) {
      throw const MobileBootstrapImportException("users/create returned invalid body");
    }
    final data = payload["data"];
    if (data is! Map<String, dynamic>) {
      throw const MobileBootstrapImportException("users/create missing data object");
    }
    final user = data["user"];
    final userMap = user is Map<String, dynamic> ? user : const <String, dynamic>{};
    final sub = data["subscription"];
    final subMap = sub is Map<String, dynamic> ? sub : const <String, dynamic>{};
    final conn = data["connection"];
    final connMap = conn is Map<String, dynamic> ? conn : const <String, dynamic>{};

    final rawUrl = _firstNonEmpty([
      connMap["raw_url"]?.toString(),
      data["connection_link"]?.toString(),
      subMap["connection_link"]?.toString(),
      subMap["conn_link"]?.toString(),
    ]);
    final fallbackVpnUuid = (subMap["vpn_uuid"]?.toString() ?? "").trim();
    final fallbackUrl = fallbackVpnUuid.isEmpty
        ? ""
        : Uri.parse(_apiBaseUrl).resolve("/subscription/$fallbackVpnUuid").toString();

    return _CreateResult(
      userId: _parseInt(userMap["user_id"]),
      login: userMap["login"]?.toString(),
      status: subMap["status"]?.toString(),
      expiresAt: _parseFlexibleExpire(subMap["expires_at"]?.toString() ?? ""),
      rawUrl: rawUrl != null && rawUrl.isNotEmpty ? rawUrl : fallbackUrl,
    );
  }

  String _platformName() {
    if (PlatformUtils.isAndroid) return "android";
    if (PlatformUtils.isIOS) return "ios";
    if (PlatformUtils.isWindows) return "windows";
    if (PlatformUtils.isMacOS) return "macos";
    if (PlatformUtils.isLinux) return "linux";
    return "unknown";
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static DateTime? _parseFlexibleExpire(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toUtc();
    final asInt = int.tryParse(value);
    if (asInt == null) return null;
    final ms = asInt >= 1_000_000_000_000 ? asInt : asInt * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
}

class MobileBootstrapImportException implements Exception {
  const MobileBootstrapImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _LookupSummary {
  const _LookupSummary({required this.connectionLink, required this.status, required this.expiresAt});

  final String connectionLink;
  final String? status;
  final DateTime? expiresAt;
}

class _CreateResult {
  const _CreateResult({
    required this.userId,
    required this.login,
    required this.status,
    required this.expiresAt,
    required this.rawUrl,
  });

  final int? userId;
  final String? login;
  final String? status;
  final DateTime? expiresAt;
  final String rawUrl;
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? "");
}
