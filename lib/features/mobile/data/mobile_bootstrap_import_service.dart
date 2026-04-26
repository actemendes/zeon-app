import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/link_parsers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MobileBootstrapImportService with InfraLogger {
  MobileBootstrapImportService({
    required DioHttpClient httpClient,
    required StableDeviceIdService stableDeviceIdService,
    required ProfileRepository profileRepository,
    required ProfileDataSource profileDataSource,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _stableDeviceId = stableDeviceIdService,
       _profileRepository = profileRepository,
       _profileDataSource = profileDataSource,
       _preferences = preferences;

  static const _apiBaseUrl = String.fromEnvironment("mobile_api_base_url", defaultValue: "https://130.49.151.173");
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const _prefDone = "mobile_auto_import_done";
  static const _prefUserId = "mobile_auto_import_user_id";
  static const _prefConnLink = "mobile_auto_import_conn_link";
  static const _prefManagedProfileId = "mobile_managed_profile_id";
  static const _prefRegion = "region";

  final DioHttpClient _httpClient;
  final StableDeviceIdService _stableDeviceId;
  final ProfileRepository _profileRepository;
  final ProfileDataSource _profileDataSource;
  final SharedPreferences _preferences;

  Future<bool> run({bool skipIfAlreadyDone = true}) async {
    try {
      return await runOrThrow(skipIfAlreadyDone: skipIfAlreadyDone);
    } catch (_) {
      return false;
    }
  }

  Future<bool> runOrThrow({bool skipIfAlreadyDone = true}) async {
    if (PlatformUtils.isWeb) {
      return false;
    }
    if (skipIfAlreadyDone && (_preferences.getBool(_prefDone) ?? false)) {
      final hasAnyProfile = await _hasAnyProfile();
      if (hasAnyProfile) {
        final savedConnLink = _preferences.getString(_prefConnLink);
        if (savedConnLink != null && savedConnLink.isNotEmpty) {
          // Refresh metadata only when active profile is still the bound account link.
          final active = await _profileDataSource.watchActiveProfile().first;
          final activeUrl = active?.url?.trim();
          if (activeUrl != null && activeUrl.isNotEmpty && activeUrl == savedConnLink.trim()) {
            await _syncMetaFromConnLink(savedConnLink);
          } else {
            loggy.debug("mobile auto import: skip bound-link meta sync, active profile was manually replaced");
          }
        }
        return false;
      }
      loggy.warning("mobile auto import: done flag is set but no profile found, retrying import");
    }
    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) {
      throw const MobileBootstrapImportException("mobile api is not configured");
    }

    try {
      final savedUserId = int.tryParse((_preferences.getString(_prefUserId) ?? "").trim());
      var effectiveUserId = savedUserId;
      String? apiLogin;
      String? apiStatus;
      DateTime? apiExpiresAt;

      var connLink = "";
      if (savedUserId != null && savedUserId > 0) {
        final lookup = await _lookupSubscriptionByUserId(savedUserId);
        if (lookup != null) {
          connLink = lookup.connectionLink;
          apiStatus = lookup.status;
          apiExpiresAt = lookup.expiresAt;
        }
      }

      if (connLink.isEmpty) {
        final created = await _createOrReuseUser(userId: savedUserId);
        effectiveUserId = created.userId ?? effectiveUserId;
        apiLogin = created.login;
        apiStatus = created.status ?? apiStatus;
        apiExpiresAt = created.expiresAt ?? apiExpiresAt;
        connLink = created.rawUrl;
      }

      if (connLink.isEmpty && effectiveUserId != null && effectiveUserId > 0) {
        final lookup = await _lookupSubscriptionByUserId(effectiveUserId);
        if (lookup != null) {
          connLink = lookup.connectionLink;
          apiStatus = lookup.status ?? apiStatus;
          apiExpiresAt = lookup.expiresAt ?? apiExpiresAt;
        }
      }

      if (connLink.isEmpty || Uri.tryParse(connLink) == null) {
        throw const MobileBootstrapImportException("connection_link is missing");
      }

      final imported = await _importFromConnLink(connLink);
      if (!imported) {
        throw const MobileBootstrapImportException("failed to import conn_link");
      }
      await _replaceManagedProfileWithActive();
      await _syncMetaFromConnLink(connLink);
      await _syncMetaFromApiSummary(status: apiStatus, expiresAt: apiExpiresAt, login: apiLogin);
      await _syncNameFromApiLogin(apiLogin);

      await _preferences.setBool(_prefDone, true);
      await _preferences.setString(_prefConnLink, connLink);
      if (effectiveUserId != null && effectiveUserId > 0) {
        await _preferences.setString(_prefUserId, effectiveUserId.toString());
      }
      final existingRegion = _preferences.getString(_prefRegion);
      if (existingRegion == null || existingRegion.isEmpty || existingRegion == "other") {
        await _preferences.setString(_prefRegion, "ru");
      }
      loggy.info("mobile auto import succeeded");
      return true;
    } catch (e, st) {
      loggy.warning("mobile auto import failed with error", e, st);
      rethrow;
    }
  }

  Future<String> _resolveImportUrl(String connLink) async {
    try {
      final response = await _httpClient.get<String>(connLink, headers: {"Accept": "text/html"});
      final content = response.data;
      if (content == null || content.isEmpty) {
        return connLink;
      }

      final idIndex = content.indexOf('id="zeon-data"');
      final altIdIndex = content.indexOf("id='zeon-data'");
      final targetIndex = idIndex >= 0 ? idIndex : altIdIndex;
      if (targetIndex < 0) {
        return connLink;
      }

      final openTagEnd = content.indexOf(">", targetIndex);
      if (openTagEnd < 0) {
        return connLink;
      }
      final closeTagIndex = content.indexOf("</script>", openTagEnd + 1);
      if (closeTagIndex < 0) {
        return connLink;
      }

      final jsonText = content.substring(openTagEnd + 1, closeTagIndex).trim();
      if (jsonText.isEmpty) {
        return connLink;
      }
      final parsed = jsonDecode(jsonText);
      if (parsed is! Map<String, dynamic>) {
        return connLink;
      }

      final subscriptionUrl = parsed["subscriptionUrl"]?.toString() ?? "";
      if (subscriptionUrl.isEmpty || Uri.tryParse(subscriptionUrl) == null) {
        return connLink;
      }

      return subscriptionUrl;
    } catch (_) {
      return connLink;
    }
  }

  Future<bool> _importFromConnLink(String connLink) async {
    loggy.debug("mobile import: trying direct conn_link import");
    final directImport = await _profileRepository.upsertRemote(connLink).run();
    if (directImport.isRight()) {
      loggy.debug("mobile import: direct conn_link import succeeded");
      return true;
    }

    final importUrl = await _resolveImportUrl(connLink);
    if (importUrl.isNotEmpty && importUrl != connLink) {
      loggy.debug("mobile import: trying resolved subscription url import");
      final resolvedImport = await _profileRepository.upsertRemote(importUrl).run();
      if (resolvedImport.isRight()) {
        loggy.debug("mobile import: resolved subscription url import succeeded");
        return true;
      }
    }

    loggy.debug("mobile import: trying directOnly conn_link import");
    final directOnlyImport = await _profileRepository.upsertRemote(connLink, directOnly: true).run();
    if (directOnlyImport.isRight()) {
      loggy.debug("mobile import: directOnly conn_link import succeeded");
      return true;
    }

    if (importUrl.isNotEmpty && importUrl != connLink) {
      loggy.debug("mobile import: trying directOnly resolved subscription url import");
      final resolvedDirectOnlyImport = await _profileRepository.upsertRemote(importUrl, directOnly: true).run();
      if (resolvedDirectOnlyImport.isRight()) {
        loggy.debug("mobile import: directOnly resolved subscription url import succeeded");
        return true;
      }
    }

    // Last-resort fallback: store profile even if core validation fails now.
    loggy.warning("mobile import: trying fallback import without validation");
    final fallbackDirect = await _profileRepository.upsertRemote(connLink, validateConfigOnImport: false).run();
    if (fallbackDirect.isRight()) {
      loggy.warning("mobile import: fallback import without validation succeeded");
      return true;
    }
    if (importUrl.isNotEmpty && importUrl != connLink) {
      final fallbackResolved = await _profileRepository.upsertRemote(importUrl, validateConfigOnImport: false).run();
      if (fallbackResolved.isRight()) {
        loggy.warning("mobile import: fallback resolved import without validation succeeded");
        return true;
      }
    }

    loggy.warning("mobile import: all import attempts failed");
    return false;
  }

  Future<void> _replaceManagedProfileWithActive() async {
    try {
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null || active.type != ProfileType.remote) return;

      final previousManagedId = (_preferences.getString(_prefManagedProfileId) ?? "").trim();
      final previousConnLink = (_preferences.getString(_prefConnLink) ?? "").trim();

      await _preferences.setString(_prefManagedProfileId, active.id);

      if (previousManagedId.isNotEmpty && previousManagedId != active.id) {
        final previousManaged = await _profileDataSource.getById(previousManagedId);
        if (previousManaged != null) {
          await _profileRepository.deleteById(previousManaged.id, previousManaged.active).run();
          loggy.info("mobile import: removed previous managed profile [id=${previousManaged.id}]");
        }
      }

      if (previousConnLink.isNotEmpty) {
        final previousByUrl = await _profileDataSource.getByUrl(previousConnLink);
        if (previousByUrl != null && previousByUrl.id != active.id) {
          await _profileRepository.deleteById(previousByUrl.id, previousByUrl.active).run();
          loggy.info("mobile import: removed previous profile by conn_link [id=${previousByUrl.id}]");
        }
      }
    } catch (e, st) {
      loggy.warning("mobile import: failed to replace managed profile", e, st);
    }
  }

  Future<void> _syncMetaFromConnLink(String connLink) async {
    try {
      final meta = await _fetchConnLinkMeta(connLink);
      if (meta == null) {
        return;
      }
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null || active.type != ProfileType.remote) {
        return;
      }

      final now = DateTime.now().toUtc();
      final status = meta.status?.toLowerCase();
      DateTime? effectiveExpire = meta.expiresAt;
      if (status == "inactive") {
        effectiveExpire = (effectiveExpire != null && effectiveExpire.isAfter(now))
            ? now.subtract(const Duration(seconds: 1))
            : (effectiveExpire ?? now.subtract(const Duration(seconds: 1)));
      }

      if (effectiveExpire == null &&
          (meta.login == null || meta.login?.isEmpty == true) &&
          (meta.webPageUrl == null || meta.webPageUrl?.isEmpty == true) &&
          (meta.supportUrl == null || meta.supportUrl?.isEmpty == true)) {
        return;
      }

      await _profileDataSource.edit(
        active.id,
        ProfileEntriesCompanion(
          name: () {
            final normalizedName = parseProfileName(meta.login).trim();
            if (normalizedName.isEmpty || _looksObfuscatedName(normalizedName)) {
              return const Value<String>.absent();
            }
            return Value(normalizedName);
          }(),
          upload: Value(effectiveExpire == null ? (active.upload ?? 0) : 0),
          download: Value(effectiveExpire == null ? (active.download ?? 0) : 0),
          total: Value(effectiveExpire == null ? (active.total ?? 920233720369) : 920233720369),
          expire: Value(effectiveExpire ?? active.expire),
          webPageUrl: Value(meta.webPageUrl ?? active.webPageUrl),
          supportUrl: Value(meta.supportUrl ?? active.supportUrl),
        ),
      );

      loggy.info(
        "mobile import: synced meta from conn_link "
        "[status=${status ?? "unknown"}, expires_at=${effectiveExpire?.toIso8601String() ?? "null"}]",
      );
    } catch (e, st) {
      loggy.warning("mobile import: failed to sync conn_link meta", e, st);
    }
  }

  Future<_ConnLinkMeta?> _fetchConnLinkMeta(String connLink) async {
    try {
      final response = await _httpClient.get<String>(connLink, headers: {"Accept": "text/html"});
      final content = response.data?.trim();
      if (content == null || content.isEmpty) return null;

      Map<String, dynamic>? root = _decodeAsJsonMap(content);
      root ??= _extractZeonScriptJson(content);
      if (root == null) return null;

      final profile = root["profile"];
      final profileMap = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
      final ok24 = root["ok24_meta"];
      final ok24Map = ok24 is Map<String, dynamic> ? ok24 : const <String, dynamic>{};

      final status = _firstNonEmpty([
        _decodeMaybeBase64(ok24Map["status"]),
        _decodeMaybeBase64(root["status"]),
        _decodeMaybeBase64(profileMap["status"]),
      ])?.toLowerCase();

      final expiresAtRaw = _firstNonEmpty([
        _decodeMaybeBase64(ok24Map["expires_at"]),
        _decodeMaybeBase64(root["expires_at"]),
        _decodeMaybeBase64(root["expiresAt"]),
        _decodeMaybeBase64(profileMap["expires_at"]),
        _decodeMaybeBase64(profileMap["expiresAt"]),
      ]);

      final login = _firstNonEmpty([
        _decodeMaybeBase64(ok24Map["login"]),
        _decodeMaybeBase64(root["login"]),
        _decodeMaybeBase64(profileMap["login"]),
      ]);

      final webPageUrl = _firstNonEmpty([
        root["profile-web-page-url"]?.toString(),
        root["profileWebPageUrl"]?.toString(),
        root["openUrl"]?.toString(),
      ]);
      final supportUrl = _firstNonEmpty([
        root["support-url"]?.toString(),
        root["supportUrl"]?.toString(),
        root["siteFaqTroubleshootingUrl"]?.toString(),
      ]);

      final expiresAt = expiresAtRaw == null ? null : _parseFlexibleExpire(expiresAtRaw);
      if (status == null &&
          expiresAt == null &&
          (login == null || login.isEmpty) &&
          (webPageUrl == null || webPageUrl.isEmpty) &&
          (supportUrl == null || supportUrl.isEmpty)) {
        return null;
      }
      return _ConnLinkMeta(
        status: status,
        expiresAt: expiresAt,
        login: login,
        webPageUrl: webPageUrl,
        supportUrl: supportUrl,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static String? _decodeMaybeBase64(dynamic value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final lower = raw.toLowerCase();
    if (lower == "active" || lower == "inactive") return lower;
    if (raw.contains("-") || raw.contains(":") || raw.contains("T") || raw.contains(" ")) return raw;
    final base64Like = RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(raw);
    if (!base64Like) return raw;
    return safeDecodeBase64(raw).trim();
  }

  Future<void> _syncMetaFromApiSummary({String? status, DateTime? expiresAt, String? login}) async {
    try {
      final normalizedStatus = status?.trim().toLowerCase();
      final normalizedName = parseProfileName(login).trim();
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null || active.type != ProfileType.remote) return;

      final now = DateTime.now().toUtc();
      DateTime? effectiveExpire = expiresAt?.toUtc();
      if (normalizedStatus == "inactive") {
        effectiveExpire = (effectiveExpire != null && effectiveExpire.isAfter(now))
            ? now.subtract(const Duration(seconds: 1))
            : (effectiveExpire ?? now.subtract(const Duration(seconds: 1)));
      }

      await _profileDataSource.edit(
        active.id,
        ProfileEntriesCompanion(
          name: () {
            if (normalizedName.isEmpty || _looksObfuscatedName(normalizedName)) {
              return const Value<String>.absent();
            }
            return Value(normalizedName);
          }(),
          upload: Value(effectiveExpire == null ? (active.upload ?? 0) : 0),
          download: Value(effectiveExpire == null ? (active.download ?? 0) : 0),
          total: Value(effectiveExpire == null ? (active.total ?? 920233720369) : 920233720369),
          expire: Value(effectiveExpire ?? active.expire),
        ),
      );
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<_LookupSummary?> _lookupSubscriptionByUserId(int userId) async {
    try {
      final uri = Uri.parse(
        _apiBaseUrl,
      ).resolve("/api/v1/subscriptions/lookup").replace(queryParameters: {"user_id": userId.toString()});
      final response = await _httpClient.get<Map<String, dynamic>>(
        uri.toString(),
        headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
        directOnly: true,
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

  Future<_CreateResult> _createOrReuseUser({int? userId}) async {
    final deviceId = await _stableDeviceId.getOrCreate();
    final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/users/create").toString();
    final body = <String, dynamic>{
      "user": {if (userId != null && userId > 0) "user_id": userId},
      "subscription": {"create_if_missing": true},
      "device_id": deviceId,
      "platform": PlatformUtils.isAndroid
          ? "android"
          : PlatformUtils.isIOS
          ? "ios"
          : PlatformUtils.isWindows
          ? "windows"
          : PlatformUtils.isMacOS
          ? "macos"
          : PlatformUtils.isLinux
          ? "linux"
          : "unknown",
    };
    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: body,
      headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
      directOnly: true,
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

    final rawUrl = (connMap["raw_url"]?.toString() ?? "").trim();
    final fallbackVpnUuid = (subMap["vpn_uuid"]?.toString() ?? "").trim();
    final fallbackUrl = fallbackVpnUuid.isEmpty
        ? ""
        : Uri.parse(_apiBaseUrl).resolve("/subscription/$fallbackVpnUuid").toString();

    return _CreateResult(
      userId: _parseInt(userMap["user_id"]),
      login: userMap["login"]?.toString(),
      status: subMap["status"]?.toString(),
      expiresAt: _parseFlexibleExpire(subMap["expires_at"]?.toString() ?? ""),
      rawUrl: rawUrl.isNotEmpty ? rawUrl : fallbackUrl,
    );
  }

  Future<void> _syncNameFromApiLogin(String? login) async {
    try {
      final normalizedName = parseProfileName(login).trim();
      if (normalizedName.isEmpty || _looksObfuscatedName(normalizedName)) return;
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null) return;
      await _profileDataSource.edit(active.id, ProfileEntriesCompanion(name: Value(normalizedName)));
    } catch (_) {
      // Best-effort only.
    }
  }

  static bool _looksObfuscatedName(String value) {
    final v = value.trim();
    if (v.length < 14) return false;
    if (v.contains(' ')) return false;
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(v)) return false;
    return RegExp('[A-Za-z]').hasMatch(v) && RegExp('[0-9]').hasMatch(v);
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

  static Map<String, dynamic>? _decodeAsJsonMap(String content) {
    try {
      final normalized = _decodeOuterBase64Json(content);
      final decoded = jsonDecode(normalized);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _decodeOuterBase64Json(String content) {
    final raw = content.trim();
    if (raw.isEmpty) return raw;
    if (raw.startsWith("{") || raw.startsWith("[")) return raw;
    final decoded = safeDecodeBase64(raw).trim();
    if (decoded.startsWith("{") || decoded.startsWith("[")) return decoded;
    return raw;
  }

  static Map<String, dynamic>? _extractZeonScriptJson(String content) {
    try {
      final idIndex = content.indexOf('id="zeon-data"');
      final altIdIndex = content.indexOf("id='zeon-data'");
      final targetIndex = idIndex >= 0 ? idIndex : altIdIndex;
      if (targetIndex < 0) return null;
      final openTagEnd = content.indexOf(">", targetIndex);
      if (openTagEnd < 0) return null;
      final closeTagIndex = content.indexOf("</script>", openTagEnd + 1);
      if (closeTagIndex < 0) return null;
      final jsonText = content.substring(openTagEnd + 1, closeTagIndex).trim();
      if (jsonText.isEmpty) return null;
      final parsed = jsonDecode(jsonText);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasAnyProfile() async {
    try {
      final result = await _profileRepository.watchHasAnyProfile().first;
      return result.getOrElse((_) => false);
    } catch (_) {
      return false;
    }
  }
}

class MobileBootstrapImportException implements Exception {
  const MobileBootstrapImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ConnLinkMeta {
  const _ConnLinkMeta({
    required this.status,
    required this.expiresAt,
    required this.login,
    required this.webPageUrl,
    required this.supportUrl,
  });

  final String? status;
  final DateTime? expiresAt;
  final String? login;
  final String? webPageUrl;
  final String? supportUrl;
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
