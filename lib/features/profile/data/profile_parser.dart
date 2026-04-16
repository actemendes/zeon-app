import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// parse profile subscription url and headers for data
///
/// ***name parser hierarchy:***
/// - UserOverride.name
/// - `profile-title` header
/// - `content-disposition` header
/// - url fragment (example: `https://example.com/config#user`) -> name=`user`
/// - url filename extension (example: `https://example.com/config.json`) -> name=`config`
/// - if none of these methods return a non-blank string, switch(profileType)
/// - remote:  fallback to `Remote Profile`
/// - local: fallback to protocol, extracted from content by protocol()

class ProfileParser {
  static const infiniteTrafficThreshold = 920_233_720_368;
  static const infiniteTimeThreshold = 92_233_720_368;
  static const allowedOverrideConfigs = [
    'connection-test-url',
    'direct-dns-address',
    'remote-dns-address',
    'warp',
    'warp2',
    'tls-tricks',
  ];
  static const allowedProfileHeaders = [
    'profile-title',
    'content-disposition',
    'subscription-userinfo',
    'profile-update-interval',
    'support-url',
    'profile-web-page-url',
    'enable-warp',
    'enable-fragment',
    'ok24-status',
    'ok24-expires-at',
  ];

  final Ref _ref;
  final DioHttpClient _httpClient;

  ProfileParser({required Ref ref, required DioHttpClient httpClient}) : _ref = ref, _httpClient = httpClient;
  TaskEither<ProfileFailure, ProfileEntriesCompanion> addLocal({
    required String id,
    required String content,
    required String tempFilePath,
    required UserOverride? userOverride,
  }) {
    return TaskEither.tryCatch(() async {
          await expandRemoteLinesInParallel(
            tempFilePath: tempFilePath,
            httpClient: _httpClient,
            cancelToken: CancelToken(),
            ref: _ref,
          );
        }, (error, stackTrace) => const ProfileFailure.unexpected())
        .flatMap((_) => TaskEither.fromEither(populateHeaders(content: content)))
        .flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.local(
                id: id,
                active: true,
                name: '',
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        );
  }

  TaskEither<ProfileFailure, ProfileEntriesCompanion> addRemote({
    required String id,
    required String url,
    required String tempFilePath,
    required UserOverride? userOverride,
    CancelToken? cancelToken,
    bool directOnly = false,
  }) => _downloadProfile(url, tempFilePath, cancelToken, directOnly: directOnly).flatMap(
    (remoteHeaders) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: remoteHeaders),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.remote(
                id: id,
                active: true,
                name: '',
                url: url,
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
    bool directOnly = false,
  }) => _downloadProfile(rp.url, tempFilePath, cancelToken, directOnly: directOnly).flatMap(
    (remoteHeaders) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: remoteHeaders),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: rp.copyWith(populatedHeaders: populatedHeaders),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) => profile
      .map(
        remote: (rp) => parse(profile: rp, tempFilePath: tempFilePath),
        local: (lp) => parse(tempFilePath: tempFilePath, profile: lp),
      )
      .flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected));

  TaskEither<ProfileFailure, Map<String, dynamic>> _downloadProfile(
    String url,
    String tempFilePath,
    CancelToken? cancelToken, {
    bool directOnly = false,
  }) => TaskEither.tryCatch(() async {
    // if (url.startsWith("http://"))
    //   throw const ProfileFailure.invalidUrl('HTTP is not supported. Please use HTTPS for secure connection.');

    final rs = await _httpClient
        .download(
          url.trim(),
          tempFilePath,
          cancelToken: cancelToken,
          userAgent: _ref.read(ConfigOptions.useXrayCoreWhenPossible)
              ? _httpClient.userAgent.replaceAll("HiddifyNext", "HiddifyNextX")
              : null,
          directOnly: directOnly,
        )
        .catchError((err) {
          if (CancelToken.isCancel(err as DioException)) {
            throw const ProfileFailure.cancelByUser('HTTP request for getting profile content canceled by user.');
          }
          throw err;
        });
    // Some providers return the profile payload as outer base64 text.
    // Normalize early so core validation and metadata parsing work on real JSON.
    try {
      final downloaded = File(tempFilePath).readAsStringSync();
      final normalized = _decodeOuterBase64Json(downloaded);
      if (normalized != downloaded) {
        File(tempFilePath).writeAsStringSync(normalized);
      }
    } catch (_) {
      // Keep original content if normalization fails.
    }
    await expandRemoteLinesInParallel(
      tempFilePath: tempFilePath,
      httpClient: _httpClient,
      cancelToken: cancelToken ?? CancelToken(),
      ref: _ref,
      directOnly: directOnly,
    );
    final rawContent = File(tempFilePath).readAsStringSync();
    final ok24MetaHeaders = _extractOk24MetaHeaders(rawContent);
    _sanitizeUnsupportedConfigFields(tempFilePath);
    // fixing headers before return
    final responseHeaders = rs.headers.map.map((key, value) {
      if (value.length == 1) return MapEntry(key, value.first);
      return MapEntry(key, value);
    });
    for (final entry in ok24MetaHeaders.entries) {
      // Parsed metadata from body should override stale/missing transport headers.
      responseHeaders[entry.key] = entry.value;
    }
    return responseHeaders;
  }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st));

  static Map<String, String> _extractOk24MetaHeaders(String content) {
    try {
      final decodedContent = _decodeOuterBase64Json(content);
      final decoded = jsonDecode(decodedContent);
      if (decoded is! Map<String, dynamic>) return const {};
      final ok24 = decoded["ok24_meta"];
      final ok24Map = ok24 is Map<String, dynamic> ? ok24 : const <String, dynamic>{};
      final profile = decoded["profile"];
      final profileMap = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};

      String? decodeMaybeBase64(dynamic value) {
        final raw = value?.toString();
        if (raw == null || raw.trim().isEmpty) return null;
        final v = raw.trim();

        // Keep plain status/date fields as-is.
        final lower = v.toLowerCase();
        if (lower == "active" || lower == "inactive") return lower;
        if (v.contains("-") || v.contains(":") || v.contains("T") || v.contains(" ")) return v;

        // Decode only if it really looks like base64/base64url token.
        final base64Like = RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(v);
        if (!base64Like) return v;

        return safeDecodeBase64(v).trim();
      }

      String? firstNonEmpty(List<String?> values) {
        for (final v in values) {
          if (v != null && v.isNotEmpty) return v;
        }
        return null;
      }

      final login = firstNonEmpty([
        decodeMaybeBase64(ok24Map["login"]),
        decodeMaybeBase64(decoded["login"]),
        decodeMaybeBase64(profileMap["login"]),
      ]);
      final status = firstNonEmpty([
        decodeMaybeBase64(ok24Map["status"]),
        decodeMaybeBase64(decoded["status"]),
        decodeMaybeBase64(profileMap["status"]),
      ]);
      final expiresAt = firstNonEmpty([
        decodeMaybeBase64(ok24Map["expires_at"]),
        decodeMaybeBase64(decoded["expires_at"]),
        decodeMaybeBase64(profileMap["expires_at"]),
        decodeMaybeBase64(profileMap["expiresAt"]),
      ]);

      final headers = <String, String>{};
      if (login != null && login.isNotEmpty) {
        headers["profile-title"] = login;
      }
      if (status != null && status.isNotEmpty) {
        headers["ok24-status"] = status.toLowerCase();
      }
      if (expiresAt != null && expiresAt.isNotEmpty) {
        headers["ok24-expires-at"] = expiresAt;
      }
      final parsedExpire = expiresAt == null ? null : _parseFlexibleExpire(expiresAt);
      if (parsedExpire != null) {
        final now = DateTime.now().toUtc();
        final normalizedStatus = (status ?? "").toLowerCase();
        final effectiveExpire = normalizedStatus == "inactive" && parsedExpire.isAfter(now)
            ? now.subtract(const Duration(seconds: 1))
            : parsedExpire;
        final expireSeconds = (effectiveExpire.millisecondsSinceEpoch / 1000).floor();
        // Route metadata through the canonical parser path used by UI contract.
        headers["subscription-userinfo"] =
            "upload=0; download=0; total=${infiniteTrafficThreshold + 1}; expire=$expireSeconds";
      }
      final profileWebPageUrl =
          decoded["profile-web-page-url"]?.toString() ??
          decoded["profileWebPageUrl"]?.toString() ??
          decoded["openUrl"]?.toString();
      if (profileWebPageUrl != null && profileWebPageUrl.isNotEmpty && isUrl(profileWebPageUrl)) {
        headers["profile-web-page-url"] = profileWebPageUrl;
      }
      final supportUrl =
          decoded["support-url"]?.toString() ??
          decoded["supportUrl"]?.toString() ??
          decoded["siteFaqTroubleshootingUrl"]?.toString();
      if (supportUrl != null && supportUrl.isNotEmpty && isUrl(supportUrl)) {
        headers["support-url"] = supportUrl;
      }
      return headers;
    } catch (_) {
      return const {};
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

  static void _sanitizeUnsupportedConfigFields(String tempFilePath) {
    try {
      final bytes = File(tempFilePath).readAsBytesSync();
      final content = utf8.decode(bytes, allowMalformed: true).trim();
      if (content.isEmpty || !content.startsWith("{")) {
        return;
      }
      final decoded = jsonDecode(content);
      final sanitized = _removeKeyRecursively(decoded, "ok24_meta");
      File(tempFilePath).writeAsStringSync(jsonEncode(sanitized));
    } catch (_) {
      // Not a JSON profile; keep original content.
    }
  }

  static dynamic _removeKeyRecursively(dynamic value, String keyToRemove) {
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (key == keyToRemove) continue;
        out[key] = _removeKeyRecursively(entry.value, keyToRemove);
      }
      return out;
    }
    if (value is List) {
      return value.map((e) => _removeKeyRecursively(e, keyToRemove)).toList();
    }
    return value;
  }

  Future<void> expandRemoteLinesInParallel({
    required String tempFilePath,
    required DioHttpClient httpClient,
    required CancelToken cancelToken,
    required Ref ref,
    int parallelism = 4,
    bool directOnly = false,
  }) async {
    final content = await File(tempFilePath).readAsString();
    final lines = content.split('\n');

    final results = List<String?>.filled(lines.length, null);

    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;

        final currentIndex = index++;
        if (currentIndex >= lines.length) return;

        final line = lines[currentIndex];

        // Non-URL
        if (!line.startsWith('http://') && !line.startsWith('https://')) {
          results[currentIndex] = line.trim();
          continue;
        }

        try {
          final tmpPath = '$tempFilePath.$currentIndex';

          await httpClient.download(
            line,
            tmpPath,
            cancelToken: cancelToken,
            userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                ? httpClient.userAgent.replaceAll('HiddifyNext', 'HiddifyNextX')
                : null,
            directOnly: directOnly,
          );

          results[currentIndex] = (await File(tmpPath).readAsString()).trim();
        } catch (err) {
          if (err is DioException && CancelToken.isCancel(err)) {
            return;
          }
          results[currentIndex] = '';
        }
      }
    }

    // Start workers
    await Future.wait(List.generate(parallelism, (_) => worker()));

    if (results.any((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
  }

  static Either<ProfileFailure, Map<String, dynamic>> populateHeaders({
    required String content,
    Map<String, dynamic>? remoteHeaders,
  }) => Either.tryCatch(() {
    final contentHeaders = _parseHeadersFromContent(content);
    return _mergeAndValidateHeaders(contentHeaders, remoteHeaders ?? {});
  }, ProfileFailure.unexpected);

  static Map<String, dynamic> _mergeAndValidateHeaders(
    Map<String, dynamic> contentHeaders,
    Map<String, dynamic> remoteHeaders,
  ) {
    for (final entry in contentHeaders.entries) {
      if (!remoteHeaders.keys.contains(entry.key)) {
        remoteHeaders[entry.key] = entry.value;
      }
    }
    final headers = <String, dynamic>{};
    for (final entry in remoteHeaders.entries) {
      if (allowedProfileHeaders.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        headers[entry.key] = entry.value;
      }
    }
    return headers;
  }

  static Map<String, dynamic> _parseHeadersFromContent(String content) {
    final headers = <String, dynamic>{};
    final content_ = safeDecodeBase64(content);
    final lines = content_.split("\n");
    final linesToProcess = lines.length < 10 ? lines.length : 10;
    for (int i = 0; i < linesToProcess; i++) {
      final line = lines[i];
      if (line.startsWith("#") || line.startsWith("//")) {
        final index = line.indexOf(':');
        if (index == -1) continue;
        final key = line.substring(0, index).replaceFirst(RegExp("^#|//"), "").trim().toLowerCase();
        final value = line.substring(index + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  static SubscriptionInfo? _parseSubscriptionInfo(String subInfoStr) {
    final values = subInfoStr.split(';');
    final map = {for (final v in values) v.split('=').first.trim(): num.tryParse(v.split('=').second.trim())?.toInt()};
    if (map case {"upload": final upload?, "download": final download?, "total": final total, "expire": var expire}) {
      final total1 = (total == null || total == 0) ? infiniteTrafficThreshold + 1 : total;
      expire = (expire == null || expire == 0) ? infiniteTimeThreshold : expire;
      return SubscriptionInfo(
        upload: upload,
        download: download,
        total: total1,
        expire: DateTime.fromMillisecondsSinceEpoch(expire * 1000),
      );
    }
    return null;
  }

  static DateTime? _parseFlexibleExpire(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed.toUtc();
    }

    final asInt = int.tryParse(value);
    if (asInt != null) {
      // Accept both unix seconds and unix milliseconds.
      final ms = asInt >= 1_000_000_000_000 ? asInt : asInt * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }

    final asDouble = double.tryParse(value);
    if (asDouble != null) {
      final intVal = asDouble.toInt();
      final ms = intVal >= 1_000_000_000_000 ? intVal : intVal * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }

    return null;
  }

  static String? _readNormalizedStatus(Map<String, dynamic> root) {
    final ok24 = root["ok24_meta"];
    final profile = root["profile"];
    final ok24Map = ok24 is Map<String, dynamic> ? ok24 : const <String, dynamic>{};
    final profileMap = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
    final candidates = <dynamic>[
      ok24Map["status"],
      root["status"],
      profileMap["status"],
    ];
    for (final candidate in candidates) {
      final raw = candidate?.toString().trim();
      if (raw == null || raw.isEmpty) continue;
      final decoded = safeDecodeBase64(raw).trim().toLowerCase();
      if (decoded == "active" || decoded == "inactive") return decoded;
      final plain = raw.toLowerCase();
      if (plain == "active" || plain == "inactive") return plain;
    }
    return null;
  }

  static DateTime? _readExpiresAt(Map<String, dynamic> root) {
    final ok24 = root["ok24_meta"];
    final profile = root["profile"];
    final ok24Map = ok24 is Map<String, dynamic> ? ok24 : const <String, dynamic>{};
    final profileMap = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
    final candidates = <dynamic>[
      ok24Map["expires_at"],
      root["expires_at"],
      root["expiresAt"],
      profileMap["expires_at"],
      profileMap["expiresAt"],
    ];
    for (final candidate in candidates) {
      final raw = candidate?.toString().trim();
      if (raw == null || raw.isEmpty) continue;
      final decoded = safeDecodeBase64(raw).trim();
      final parsed = _parseFlexibleExpire(decoded) ?? _parseFlexibleExpire(raw);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static SubscriptionInfo? _parseSubscriptionInfoFromZeonHtml(String content) {
    final normalizedContent = _decodeOuterBase64Json(content);
    final idIndex = normalizedContent.indexOf('id="zeon-data"');
    final altIdIndex = normalizedContent.indexOf("id='zeon-data'");
    final targetIndex = idIndex >= 0 ? idIndex : altIdIndex;
    if (targetIndex < 0) {
      return null;
    }

    final openTagStart = normalizedContent.lastIndexOf("<script", targetIndex);
    if (openTagStart < 0) {
      return null;
    }
    final openTagEnd = normalizedContent.indexOf(">", targetIndex);
    if (openTagEnd < 0) {
      return null;
    }

    final closeTagIndex = normalizedContent.indexOf("</script>", openTagEnd + 1);
    if (closeTagIndex == -1) {
      return null;
    }
    final rawJson = normalizedContent.substring(openTagEnd + 1, closeTagIndex).trim();
    if (rawJson.isEmpty) {
      return null;
    }

    try {
      final root = jsonDecode(rawJson);
      if (root is! Map<String, dynamic>) {
        return null;
      }
      final profile = root["profile"];
      final profileMap = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};

      final rawExpire =
          profileMap["expires_at"]?.toString() ??
          profileMap["expiresAt"]?.toString() ??
          root["expires_at"]?.toString() ??
          root["expiresAt"]?.toString();
      if (rawExpire == null || rawExpire.isEmpty) {
        return null;
      }
      final parsedExpire = _parseFlexibleExpire(rawExpire);
      if (parsedExpire == null) return null;

      final now = DateTime.now().toUtc();
      final status = (profileMap["status"]?.toString() ?? root["status"]?.toString())?.toLowerCase();
      final expire = status == "inactive" && parsedExpire.isAfter(now)
          ? now.subtract(const Duration(seconds: 1))
          : parsedExpire.toUtc();

      return SubscriptionInfo(
        upload: 0,
        download: 0,
        total: infiniteTrafficThreshold + 1,
        expire: expire,
        webPageUrl:
            root["profile-web-page-url"]?.toString() ??
            root["profileWebPageUrl"]?.toString() ??
            root["openUrl"]?.toString(),
        supportUrl:
            root["support-url"]?.toString() ??
            root["supportUrl"]?.toString() ??
            root["siteFaqTroubleshootingUrl"]?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Either<ProfileFailure, ProfileEntity> parse({required String tempFilePath, required ProfileEntity profile}) =>
      Either.tryCatch(() {
        final rawContent = File(tempFilePath).readAsStringSync();
        final normalizedContent = _decodeOuterBase64Json(rawContent);
        final headers = Map<String, dynamic>.from(profile.populatedHeaders ?? {});
        // Ensure metadata from raw JSON body always reaches parse stage.
        headers.addAll(_extractOk24MetaHeaders(normalizedContent));
        var name = '';
        if (profile.userOverride?.name case final String oName when oName.isNotEmpty) {
          name = oName;
        }

        if (headers['profile-title'] case final String titleHeader when name.isEmpty) {
          if (titleHeader.startsWith("base64:")) {
            name = utf8.decode(base64.decode(titleHeader.replaceFirst("base64:", "")));
          } else {
            name = titleHeader.trim();
          }
        }
        if (headers['content-disposition'] case final String contentDispositionHeader when name.isEmpty) {
          final regExp = RegExp('filename="([^"]*)"');
          final match = regExp.firstMatch(contentDispositionHeader);
          if (match != null && match.groupCount >= 1) {
            name = match.group(1) ?? '';
          }
        }
        if (profile case RemoteProfileEntity(:final url)) {
          if (Uri.parse(url).fragment case final fragment when name.isEmpty) {
            name = fragment;
          }
          if (url.split("/").lastOrNull case final part? when name.isEmpty) {
            final pattern = RegExp(r"\.(json|yaml|yml|txt)[\s\S]*");
            name = part.replaceFirst(pattern, "");
          }
        }
        name = parseProfileName(name);
        if (name.isBlank) {
          switch (profile) {
            case RemoteProfileEntity():
              name = "Remote Profile";

            case LocalProfileEntity():
              name = protocol(File(tempFilePath).readAsStringSync());
          }
        }
        name = parseProfileName(name);

        if (headers['enable-warp'].toString() == 'true' || profile.userOverride?.enableWarp == true) {
          final value = {'enable': true, 'mode': 'warp_over_proxy'};
          headers['warp'] = value;
          headers['warp2'] = value;
        }

        if (headers['enable-fragment'].toString() == 'true' || profile.userOverride?.enableFragment == true) {
          headers['tls-tricks'] = {'enable-fragment': true};
        }

        final isAutoUpdateDisable = profile.userOverride?.isAutoUpdateDisable ?? false;
        ProfileOptions? options;
        if (profile.userOverride?.updateInterval case final int updateInterval
            when updateInterval > 0 && !isAutoUpdateDisable) {
          options = ProfileOptions(updateInterval: Duration(hours: updateInterval));
        }
        if (headers['profile-update-interval'] case final String updateIntervalStr
            when options == null && !isAutoUpdateDisable) {
          final updateInterval = Duration(hours: int.parse(updateIntervalStr));
          options = ProfileOptions(updateInterval: updateInterval);
        }

        SubscriptionInfo? subInfo;
        if (headers['subscription-userinfo'] case final String subInfoStr) {
          subInfo = _parseSubscriptionInfo(subInfoStr);
        }
        subInfo ??= _parseSubscriptionInfoFromZeonHtml(normalizedContent);
        try {
          final decoded = jsonDecode(normalizedContent);
          if (decoded is Map<String, dynamic>) {
            final jsonStatus = _readNormalizedStatus(decoded);
            final jsonExpire = _readExpiresAt(decoded);
            final now = DateTime.now().toUtc();
            if (jsonStatus == "inactive") {
              final expire = (jsonExpire != null && jsonExpire.isAfter(now))
                  ? now.subtract(const Duration(seconds: 1))
                  : (jsonExpire ?? now.subtract(const Duration(seconds: 1)));
              subInfo = subInfo == null
                  ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: expire)
                  : subInfo.copyWith(expire: expire);
            } else if (jsonStatus == "active" && jsonExpire != null) {
              subInfo = subInfo == null
                  ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: jsonExpire)
                  : subInfo.copyWith(expire: jsonExpire);
            } else if (jsonExpire != null) {
              subInfo = subInfo == null
                  ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: jsonExpire)
                  : subInfo.copyWith(expire: jsonExpire);
            }
          }
        } catch (_) {
          // Non-JSON content; ignore.
        }
        final ok24Status = headers['ok24-status']?.toString().toLowerCase();
        final now = DateTime.now().toUtc();
        DateTime? ok24Expire;
        if (headers['ok24-expires-at'] case final String ok24ExpiresAt) {
          ok24Expire = _parseFlexibleExpire(ok24ExpiresAt);
        }
        if (ok24Status != null) {
          if (ok24Status == "inactive") {
            final inactiveExpire = (ok24Expire != null && ok24Expire.isAfter(now))
                ? now.subtract(const Duration(seconds: 1))
                : (ok24Expire ?? now.subtract(const Duration(seconds: 1)));
            subInfo = subInfo == null
                ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: inactiveExpire)
                : subInfo.copyWith(expire: inactiveExpire);
          } else if (ok24Status == "active") {
            final activeExpire = ok24Expire ?? subInfo?.expire;
            if (activeExpire != null) {
              subInfo = subInfo == null
                  ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: activeExpire)
                  : subInfo.copyWith(expire: activeExpire);
            }
          }
        } else if (ok24Expire != null) {
          subInfo = subInfo == null
              ? SubscriptionInfo(upload: 0, download: 0, total: infiniteTrafficThreshold + 1, expire: ok24Expire)
              : subInfo.copyWith(expire: ok24Expire);
        }

        if (subInfo != null) {
          if (headers['profile-web-page-url'] case final String profileWebPageUrl when isUrl(profileWebPageUrl)) {
            subInfo = subInfo.copyWith(webPageUrl: profileWebPageUrl);
          }
          if (headers['support-url'] case final String profileSupportUrl when isUrl(profileSupportUrl)) {
            subInfo = subInfo.copyWith(supportUrl: profileSupportUrl);
          }
        }

        headers.removeWhere(
          (key, value) => !allowedOverrideConfigs.contains(key) || value == null || value.toString().isEmpty,
        );

        final profileOverrideStr = jsonEncode({for (final key in headers.keys) key: headers[key]});

        return profile.map(
          remote: (rp) => rp.copyWith(
            name: name,
            lastUpdate: DateTime.now(),
            options: options,
            subInfo: subInfo,
            profileOverride: profileOverrideStr,
          ),
          local: (lp) => lp.copyWith(name: name, lastUpdate: DateTime.now(), profileOverride: profileOverrideStr),
        );
      }, ProfileFailure.unexpected);

  static String protocol(String content) {
    if (content.contains("[Interface]")) {
      return ProxyType.wireguard.label;
    }
    final lines = content.split('\n');
    String? name;
    for (final line in lines) {
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      final fragment = uri.hasFragment ? Uri.decodeComponent(uri.fragment.split(" -> ")[0]) : null;
      name ??= switch (uri.scheme) {
        'ss' => fragment ?? ProxyType.shadowsocks.label,
        'ssconf' => fragment ?? ProxyType.shadowsocks.label,
        'vmess' => ProxyType.vmess.label,
        'vless' => fragment ?? ProxyType.vless.label,
        'trojan' => fragment ?? ProxyType.trojan.label,
        'tuic' => fragment ?? ProxyType.tuic.label,
        'hy2' || 'hysteria2' => fragment ?? ProxyType.hysteria2.label,
        'hy' || 'hysteria' => fragment ?? ProxyType.hysteria.label,
        'ssh' => fragment ?? ProxyType.ssh.label,
        'wg' => fragment ?? ProxyType.wireguard.label,
        'awg' => fragment ?? ProxyType.awg.label,
        'shadowtls' => fragment ?? ProxyType.shadowtls.label,
        'mieru' => fragment ?? ProxyType.mieru.label,
        'warp' => fragment ?? ProxyType.warp.label,
        _ => null,
      };
    }
    return name ?? ProxyType.unknown.label;
  }

  static Map<String, dynamic> applyProfileOverride(Map<String, dynamic> main, String? profileOverride) {
    if (profileOverride == null) return main;
    if (profileOverride.contains("{")) {
      final profileOverrideMap = jsonDecode(profileOverride) as Map<String, dynamic>;
      return _mergeJson(main, profileOverrideMap);
    } else {
      return main;
    }
  }

  static Map<String, dynamic> _mergeJson(Map<String, dynamic> main, Map<String, dynamic> override) {
    override.forEach((key, value) {
      if (main.containsKey(key)) {
        if (main[key] is Map<String, dynamic> && value is Map<String, dynamic>) {
          main[key] = _mergeJson(main[key] as Map<String, dynamic>, value);
        } else {
          main[key] = value;
        }
      } else {
        main[key] = value;
      }
    });
    return main;
  }
}
