import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/link_parsers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final mobileConnLinkImportServiceProvider = Provider<MobileConnLinkImportService>((ref) {
  return MobileConnLinkImportService(
    httpClient: ref.read(httpClientProvider),
    profileRepository: ref.read(profileRepositoryProvider).requireValue,
    profileDataSource: ref.read(profileDataSourceProvider),
    preferences: ref.read(sharedPreferencesProvider).requireValue,
  );
});

class MobileConnLinkImportService with InfraLogger {
  MobileConnLinkImportService({
    required DioHttpClient httpClient,
    required ProfileRepository profileRepository,
    required ProfileDataSource profileDataSource,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _profileRepository = profileRepository,
       _profileDataSource = profileDataSource,
       _preferences = preferences;

  static const apiBaseUrl = String.fromEnvironment("mobile_api_base_url", defaultValue: "https://130.49.151.173");
  static const publicOpenBaseUrl = "https://zeon-vps.link";

  static const prefDone = "mobile_auto_import_done";
  static const prefUserId = "mobile_auto_import_user_id";
  static const prefConnLink = "mobile_auto_import_conn_link";
  static const prefManagedProfileId = "mobile_managed_profile_id";

  final DioHttpClient _httpClient;
  final ProfileRepository _profileRepository;
  final ProfileDataSource _profileDataSource;
  final SharedPreferences _preferences;

  MobileConnLinkInput normalizeConnectionLink(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return const MobileConnLinkInput(primaryConnLink: "", fallbackConnLink: null, openId: null);
    }

    final openId = _extractOpenId(input);
    if (openId != null && openId.isNotEmpty) {
      return MobileConnLinkInput(
        primaryConnLink: Uri.parse(apiBaseUrl).resolve("/open/$openId").toString(),
        fallbackConnLink: Uri.parse(publicOpenBaseUrl).resolve("/open/$openId").toString(),
        openId: openId,
      );
    }

    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme && (parsed.scheme == "http" || parsed.scheme == "https")) {
      return MobileConnLinkInput(primaryConnLink: parsed.toString(), fallbackConnLink: null, openId: null);
    }

    String candidate = input;
    if (candidate.startsWith('/')) {
      candidate = candidate.substring(1);
    }
    if (candidate.isEmpty) {
      return const MobileConnLinkInput(primaryConnLink: "", fallbackConnLink: null, openId: null);
    }
    return MobileConnLinkInput(
      primaryConnLink: Uri.parse(apiBaseUrl).resolve("/$candidate").toString(),
      fallbackConnLink: null,
      openId: null,
    );
  }

  Future<MobileConnLinkImportResult> importConnectionLink(
    String rawInput, {
    int? userId,
    String? apiStatus,
    DateTime? apiExpiresAt,
    String? apiLogin,
    bool clearUserIdWhenMissing = true,
  }) async {
    final normalized = normalizeConnectionLink(rawInput);
    if (normalized.primaryConnLink.isEmpty || Uri.tryParse(normalized.primaryConnLink) == null) {
      throw const MobileConnLinkImportException("validation_error");
    }

    String? importedUrl;
    for (final connLink in normalized.importCandidates) {
      final imported = await _importFromConnLink(connLink, allowNoValidateFallback: false);
      if (imported) {
        importedUrl = connLink;
        break;
      }
      if (connLink == normalized.primaryConnLink && normalized.fallbackConnLink != null) {
        loggy.warning(
          "mobile conn_link import: primary failed, trying public fallback "
          "[primary=${_maskLink(normalized.primaryConnLink)}, fallback=${_maskLink(normalized.fallbackConnLink!)}]",
        );
      }
    }

    if (importedUrl == null) {
      for (final connLink in normalized.importCandidates) {
        final imported = await _importFromConnLink(connLink, allowNoValidateFallback: true);
        if (imported) {
          importedUrl = connLink;
          break;
        }
      }
    }

    if (importedUrl == null) {
      loggy.warning("mobile conn_link import: all candidates failed [link=${_maskLink(normalized.primaryConnLink)}]");
      throw const MobileConnLinkImportException("import_failed");
    }

    await _replaceManagedProfileWithActive();
    await _removeExtraProfilesKeepActive();
    await refreshActiveProfileMetadata(
      normalized.primaryConnLink,
      importedUrl: importedUrl,
      apiStatus: apiStatus,
      apiExpiresAt: apiExpiresAt,
      apiLogin: apiLogin,
    );

    await _preferences.setBool(prefDone, true);
    await _preferences.setString(prefConnLink, normalized.primaryConnLink);
    if (userId != null && userId > 0) {
      await _preferences.setString(prefUserId, userId.toString());
    } else if (clearUserIdWhenMissing) {
      await _preferences.remove(prefUserId);
    }

    loggy.info(
      "mobile conn_link import succeeded "
      "[conn_link=${_maskLink(normalized.primaryConnLink)}, imported=${_maskLink(importedUrl)}]",
    );
    return MobileConnLinkImportResult(
      connLink: normalized.primaryConnLink,
      importedUrl: importedUrl,
      openId: normalized.openId,
      userId: userId,
    );
  }

  Future<void> refreshActiveProfileMetadata(
    String connLink, {
    String? importedUrl,
    String? apiStatus,
    DateTime? apiExpiresAt,
    String? apiLogin,
  }) async {
    final normalized = normalizeConnectionLink(connLink);
    final primary = normalized.primaryConnLink.isNotEmpty ? normalized.primaryConnLink : connLink.trim();
    if (primary.isEmpty) {
      await _syncMetaFromApiSummary(status: apiStatus, expiresAt: apiExpiresAt, login: apiLogin);
      return;
    }

    if (primary.isNotEmpty) {
      await _syncMetaFromConnLink(primary);
    }

    final resolvedPrimary = await resolveImportUrl(primary);
    if (resolvedPrimary.isNotEmpty && resolvedPrimary != primary) {
      await _syncMetaFromConnLink(resolvedPrimary);
    }

    final effectiveImportedUrl = importedUrl?.trim();
    if (effectiveImportedUrl != null && effectiveImportedUrl.isNotEmpty && effectiveImportedUrl != primary) {
      await _syncMetaFromConnLink(effectiveImportedUrl);
      final resolvedImported = await resolveImportUrl(effectiveImportedUrl);
      if (resolvedImported.isNotEmpty &&
          resolvedImported != effectiveImportedUrl &&
          resolvedImported != resolvedPrimary) {
        await _syncMetaFromConnLink(resolvedImported);
      }
    }

    await _syncMetaFromApiSummary(status: apiStatus, expiresAt: apiExpiresAt, login: apiLogin);
  }

  Future<String> resolveImportUrl(String connLink) async {
    try {
      final response = await _httpClient.get<String>(connLink, headers: {"Accept": "text/html"});
      final content = response.data;
      if (content == null || content.isEmpty) {
        return connLink;
      }

      final root = _extractZeonScriptJson(content);
      if (root == null) {
        return connLink;
      }

      final subscriptionUrl = root["subscriptionUrl"]?.toString() ?? "";
      if (subscriptionUrl.isEmpty || Uri.tryParse(subscriptionUrl) == null) {
        return connLink;
      }

      return subscriptionUrl;
    } catch (_) {
      return connLink;
    }
  }

  Future<bool> _importFromConnLink(String connLink, {required bool allowNoValidateFallback}) async {
    final attempts = <String>[connLink, _appendPlatformHint(connLink)].where((e) => e.isNotEmpty).toSet().toList();

    for (final attemptLink in attempts) {
      if (await _tryUpsert(attemptLink, "default")) {
        return true;
      }

      final importUrl = await resolveImportUrl(attemptLink);
      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        loggy.info("mobile conn_link resolved url [from=${_maskLink(attemptLink)} to=${_maskLink(importUrl)}]");
        if (await _tryUpsert(importUrl, "resolved/default")) {
          return true;
        }
      }

      if (await _tryUpsert(attemptLink, "directOnly", directOnly: true)) {
        return true;
      }

      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        if (await _tryUpsert(importUrl, "resolved/directOnly", directOnly: true)) {
          return true;
        }
      }
    }

    if (!allowNoValidateFallback) {
      return false;
    }

    // Keep no-validate as a last-resort fallback only after all validated
    // attempts (including resolved/fallback URLs) are exhausted.
    for (final attemptLink in attempts) {
      if (await _tryUpsert(attemptLink, "no-validate", validateConfigOnImport: false)) {
        return true;
      }

      final importUrl = await resolveImportUrl(attemptLink);
      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        if (await _tryUpsert(importUrl, "resolved/no-validate", validateConfigOnImport: false)) {
          return true;
        }
      }

      if (await _tryUpsert(attemptLink, "directOnly/no-validate", directOnly: true, validateConfigOnImport: false)) {
        return true;
      }

      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        if (await _tryUpsert(
          importUrl,
          "resolved/directOnly/no-validate",
          directOnly: true,
          validateConfigOnImport: false,
        )) {
          return true;
        }
      }
    }

    return false;
  }

  Future<bool> _tryUpsert(
    String link,
    String label, {
    bool directOnly = false,
    bool validateConfigOnImport = true,
  }) async {
    try {
      loggy.info("mobile conn_link import attempt [$label, link=${_maskLink(link)}]");
      final result = await _profileRepository
          .upsertRemote(link, directOnly: directOnly, validateConfigOnImport: validateConfigOnImport)
          .run();
      if (result.isRight()) {
        loggy.info("mobile conn_link import success: upsertRemote($label)");
        return true;
      }
      loggy.warning("mobile conn_link import fail: upsertRemote($label) ${_eitherError(result)}");
      return false;
    } catch (e, st) {
      loggy.warning("mobile conn_link import threw: upsertRemote($label)", e, st);
      return false;
    }
  }

  Future<void> _replaceManagedProfileWithActive() async {
    try {
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null || active.type != ProfileType.remote) return;

      final previousManagedId = (_preferences.getString(prefManagedProfileId) ?? "").trim();
      final previousConnLink = (_preferences.getString(prefConnLink) ?? "").trim();

      await _preferences.setString(prefManagedProfileId, active.id);

      if (previousManagedId.isNotEmpty && previousManagedId != active.id) {
        final previousManaged = await _profileDataSource.getById(previousManagedId);
        if (previousManaged != null) {
          await _profileRepository.deleteById(previousManaged.id, previousManaged.active).run();
          loggy.info("mobile conn_link import: removed previous managed profile [id=${previousManaged.id}]");
        }
      }

      if (previousConnLink.isNotEmpty) {
        final previousByUrl = await _profileDataSource.getByUrl(previousConnLink);
        if (previousByUrl != null && previousByUrl.id != active.id) {
          await _profileRepository.deleteById(previousByUrl.id, previousByUrl.active).run();
          loggy.info("mobile conn_link import: removed previous profile by conn_link [id=${previousByUrl.id}]");
        }
      }
    } catch (e, st) {
      loggy.warning("mobile conn_link import: failed to replace managed profile", e, st);
    }
  }

  Future<void> pruneToSingleProfileIfManaged() async {
    final managedId = (_preferences.getString(prefManagedProfileId) ?? "").trim();
    final done = _preferences.getBool(prefDone) ?? false;
    if (!done && managedId.isEmpty) return;
    await _removeExtraProfilesKeepActive();
  }

  Future<void> enforceSingleProfile() async {
    await _removeExtraProfilesKeepActive();
  }

  Future<void> _removeExtraProfilesKeepActive() async {
    try {
      final allProfiles = await _profileDataSource
          .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.descending)
          .first;
      if (allProfiles.isEmpty) return;
      final activeProfile = await _profileDataSource.watchActiveProfile().first;
      final keepProfile = activeProfile ?? allProfiles.first;
      await _profileRepository.setAsActive(keepProfile.id).run();
      await _preferences.setString(prefManagedProfileId, keepProfile.id);

      for (final profile in allProfiles) {
        if (profile.id == keepProfile.id) continue;
        await _profileRepository.deleteById(profile.id, profile.active).run();
        loggy.info("mobile conn_link import: removed extra profile [id=${profile.id}]");
      }
    } catch (e, st) {
      loggy.warning("mobile conn_link import: failed to remove extra profiles", e, st);
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
        "mobile conn_link import: synced meta from conn_link "
        "[status=${status ?? "unknown"}, expires_at=${effectiveExpire?.toIso8601String() ?? "null"}]",
      );
    } catch (e, st) {
      loggy.warning("mobile conn_link import: failed to sync conn_link meta", e, st);
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

      if (effectiveExpire == null && (normalizedName.isEmpty || _looksObfuscatedName(normalizedName))) {
        return;
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

  String _appendPlatformHint(String link) {
    try {
      final uri = Uri.parse(link);
      final q = Map<String, String>.from(uri.queryParameters);
      q.putIfAbsent("platform", () => "hiddify");
      return uri.replace(queryParameters: q).toString();
    } catch (_) {
      return link;
    }
  }

  static String? _extractOpenId(String input) {
    final normalized = input.trim();
    if (normalized.isEmpty) return null;
    final direct = RegExp(r'^[A-Za-z0-9_-]{4,}$').firstMatch(normalized);
    if (direct != null) return direct.group(0);
    final parsed = Uri.tryParse(normalized);
    if (parsed != null) {
      final segments = parsed.pathSegments
          .map((segment) => Uri.decodeComponent(segment).trim())
          .where((segment) => segment.isNotEmpty)
          .toList();
      final openIndex = segments.lastIndexWhere((segment) => segment.toLowerCase() == "open");
      if (openIndex != -1 && openIndex + 1 < segments.length) {
        final candidate = segments[openIndex + 1];
        if (RegExp('^[A-Za-z0-9_-]{4,}\$').hasMatch(candidate)) return candidate;
      }
    }
    final match = RegExp('/open/([A-Za-z0-9_-]{4,})').firstMatch(normalized);
    return match?.group(1);
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

  static bool _looksObfuscatedName(String value) {
    final v = value.trim();
    if (v.length < 14) return false;
    if (v.contains(' ')) return false;
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(v)) return false;
    return RegExp('[A-Za-z]').hasMatch(v) && RegExp('[0-9]').hasMatch(v);
  }
}

class MobileConnLinkInput {
  const MobileConnLinkInput({required this.primaryConnLink, required this.fallbackConnLink, required this.openId});

  final String primaryConnLink;
  final String? fallbackConnLink;
  final String? openId;

  List<String> get importCandidates => <String>[
    primaryConnLink,
    if (fallbackConnLink != null && fallbackConnLink!.isNotEmpty && fallbackConnLink != primaryConnLink)
      fallbackConnLink!,
  ];
}

class MobileConnLinkImportResult {
  const MobileConnLinkImportResult({
    required this.connLink,
    required this.importedUrl,
    required this.openId,
    required this.userId,
  });

  final String connLink;
  final String importedUrl;
  final String? openId;
  final int? userId;
}

class MobileConnLinkImportException implements Exception {
  const MobileConnLinkImportException(this.code);

  final String code;

  @override
  String toString() => code;
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

String _maskLink(String link) {
  if (link.isEmpty) return "-";
  try {
    final uri = Uri.parse(link);
    return "${uri.host}${uri.path}";
  } catch (_) {
    return link.length > 80 ? "${link.substring(0, 80)}..." : link;
  }
}

String _eitherError(dynamic either) {
  return "[result=$either]";
}
