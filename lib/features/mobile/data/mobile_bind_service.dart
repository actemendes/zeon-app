import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final mobileBindServiceProvider = Provider<MobileBindService>((ref) {
  return MobileBindService(
    httpClient: ref.read(httpClientProvider),
    profileRepository: ref.read(profileRepositoryProvider).requireValue,
    profileDataSource: ref.read(profileDataSourceProvider),
    preferences: ref.read(sharedPreferencesProvider).requireValue,
  );
});

class MobileBindService with InfraLogger {
  MobileBindService({
    required DioHttpClient httpClient,
    required ProfileRepository profileRepository,
    required ProfileDataSource profileDataSource,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _profileRepository = profileRepository,
       _profileDataSource = profileDataSource,
       _preferences = preferences;

  static const _apiBaseUrl = String.fromEnvironment("mobile_api_base_url", defaultValue: "https://130.49.151.173");
  static const _mobileApiKey = String.fromEnvironment(
    "mobile_api_key",
    defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7",
  );
  static const _bindJwtEnv = String.fromEnvironment("mobile_bind_jwt");
  static const _bindJwtPrefKey = "mobile_bind_jwt";
  static const _bindJwtExpiresPrefKey = "mobile_bind_jwt_expires_at";
  static const _prefDone = "mobile_auto_import_done";
  static const _prefUserId = "mobile_auto_import_user_id";
  static const _prefConnLink = "mobile_auto_import_conn_link";
  static const _prefManagedProfileId = "mobile_managed_profile_id";
  static const _prefBindSessionCache = "mobile_bind_session_cache_v1";

  final DioHttpClient _httpClient;
  final ProfileRepository _profileRepository;
  final ProfileDataSource _profileDataSource;
  final SharedPreferences _preferences;
  StableDeviceIdService get _stableDeviceId => StableDeviceIdService(preferences: _preferences);

  Future<BindCreateResult> createSession() async {
    final cached = _readCachedSession();
    if (cached != null) {
      final now = DateTime.now().toUtc();
      if (cached.expiresAt.isAfter(now.add(const Duration(seconds: 5)))) {
        return cached;
      }
      await _clearCachedSession();
    }

    final payload = await _request(
      method: "POST",
      path: "/bind/session/create",
      body: {
        "device_id": await _stableDeviceId.getOrCreate(),
        "client_meta": {"platform": _platformName()},
      },
    );

    final bindSessionId = payload["bind_session_id"]?.toString() ?? "";
    final bindCode = payload["bind_code"]?.toString() ?? "";
    final expiresAt = _parseIso(payload["expires_at"]?.toString());
    final wsChannel = payload["ws_channel"]?.toString();

    if (bindSessionId.isEmpty || bindCode.isEmpty || expiresAt == null) {
      throw const MobileBindException("invalid_create_response");
    }

    final result = BindCreateResult(
      bindSessionId: bindSessionId,
      bindCode: bindCode,
      expiresAt: expiresAt,
      wsChannel: wsChannel,
    );
    await _saveCachedSession(result);
    return result;
  }

  Future<BindConfirmResult> confirmCode(String bindCode) async {
    loggy.info("bind confirm started [code_len=${bindCode.trim().length}]");
    var deviceId = await _stableDeviceId.getOrCreate();
    Map<String, dynamic> payload;
    try {
      payload = await _confirmWithDevice(deviceId: deviceId, bindCode: bindCode);
    } on MobileBindException catch (e) {
      if (e.code == "device_already_bound") {
        loggy.warning("bind confirm: current device is already bound, rotating bind device id and retrying");
        deviceId = await _rotateBindDeviceIdForRebind();
        payload = await _confirmWithDevice(deviceId: deviceId, bindCode: bindCode);
      } else {
        rethrow;
      }
    }

    final ownerUserId = _parseInt(payload["owner_user_id"]);
    final status = payload["status"]?.toString();
    final subscriptionRaw = payload["subscription"];
    final subscription = subscriptionRaw is Map<String, dynamic> ? subscriptionRaw : const <String, dynamic>{};
    final connLink = subscription["conn_link"]?.toString() ?? "";
    final expiresAt = _parseIso(subscription["expires_at"]?.toString());

    loggy.info(
      "bind confirm response [owner_user_id=$ownerUserId, status=$status, "
      "conn_link=${_maskLink(connLink)}, expires_at=${expiresAt?.toIso8601String()}]",
    );

    if (ownerUserId == null || ownerUserId <= 0 || connLink.isEmpty) {
      throw const MobileBindException("invalid_confirm_response");
    }

    var effectiveConnLink = connLink;
    var imported = false;
    var effectiveLinkStatus = await _probeConnLinkStatus(effectiveConnLink);
    imported = await _importFromConnLink(effectiveConnLink);
    if (!imported && effectiveLinkStatus == 404) {
      loggy.warning("bind confirm: conn_link probe returned 404 [link=${_maskLink(effectiveConnLink)}]");
    }
    if (!imported && ownerUserId > 0) {
      final fetchedConnLink = await _fetchMobileConnLinkByUserId(ownerUserId);
      if (fetchedConnLink != null && fetchedConnLink.isNotEmpty) {
        loggy.warning(
          "bind confirm: primary import failed, trying mobile link fallback "
          "[owner_user_id=$ownerUserId, link=$fetchedConnLink]",
        );
        effectiveConnLink = fetchedConnLink;
        effectiveLinkStatus = await _probeConnLinkStatus(effectiveConnLink);
        imported = await _importFromConnLink(effectiveConnLink);
        if (!imported && effectiveLinkStatus == 404) {
          loggy.warning("bind confirm: fallback conn_link probe returned 404 [link=${_maskLink(effectiveConnLink)}]");
        }
      }
    }
    if (!imported) {
      if (effectiveLinkStatus == 404) {
        throw const MobileBindException("bind_link_not_found");
      }
      loggy.warning(
        "bind confirm import failed after all attempts "
        "[owner_user_id=$ownerUserId, conn_link=${_maskLink(effectiveConnLink)}]",
      );
      throw const MobileBindException("import_failed");
    }

    await _replaceManagedProfileWithActive();
    await _preferences.setBool(_prefDone, true);
    await _preferences.setString(_prefUserId, ownerUserId.toString());
    await _preferences.setString(_prefConnLink, effectiveConnLink);
    await _clearCachedSession();
    await _syncActiveProfileMetaFromBind(status: status, expiresAt: expiresAt);

    return BindConfirmResult(
      ownerUserId: ownerUserId,
      status: status ?? "confirmed",
      connLink: effectiveConnLink,
      expiresAt: expiresAt,
    );
  }

  Future<void> importConnectionLink(String rawInput) async {
    final normalizedLink = _normalizeAccountLinkInput(rawInput);
    if (normalizedLink.isEmpty || Uri.tryParse(normalizedLink) == null) {
      throw const MobileBindException("validation_error");
    }

    final imported = await _importFromConnLink(normalizedLink);
    if (!imported) {
      throw const MobileBindException("import_failed");
    }

    await _replaceManagedProfileWithActive();
    await _preferences.setBool(_prefDone, true);
    await _clearCachedSession();
  }

  Future<Map<String, dynamic>> _confirmWithDevice({required String deviceId, required String bindCode}) {
    return _request(
      method: "POST",
      path: "/bind/session/confirm",
      body: {
        "device_id": deviceId,
        "bind_code": bindCode,
        "client_meta": {"platform": _platformName()},
      },
    );
  }

  String _normalizeAccountLinkInput(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) return "";
    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme && (parsed.scheme == "http" || parsed.scheme == "https")) {
      return parsed.toString();
    }

    final codeOnly = RegExp(r'^[A-Za-z0-9_-]{4,}$');
    if (codeOnly.hasMatch(input)) {
      return "https://zeon-vps.link/open/$input";
    }

    String candidate = input;
    if (candidate.startsWith('/')) {
      candidate = candidate.substring(1);
    }
    if (candidate.isEmpty) return "";
    return "https://zeon-vps.link/$candidate";
  }

  Future<String> _rotateBindDeviceIdForRebind() async {
    await _preferences.remove(_bindJwtPrefKey);
    await _preferences.remove(_bindJwtExpiresPrefKey);
    final rotated = await _stableDeviceId.rotateForRebind();
    loggy.info("bind rebind device id rotated [device_id=$rotated]");
    return rotated;
  }

  Future<BindStatusResult> getStatus(String bindSessionId) async {
    final payload = await _request(
      method: "GET",
      path: "/bind/session/status",
      query: {"bind_session_id": bindSessionId},
    );
    return BindStatusResult(
      status: payload["status"]?.toString() ?? "unknown",
      expiresAt: _parseIso(payload["expires_at"]?.toString()),
    );
  }

  Future<void> cancelSession(String bindSessionId) async {
    await _request(method: "POST", path: "/bind/session/cancel", body: {"bind_session_id": bindSessionId});
    await _clearCachedSession();
  }

  Future<BindWsConnection?> connectSessionEvents(String bindSessionId) async {
    if (PlatformUtils.isWeb) return null;
    final jwt = await _bindJwt();
    if (_apiBaseUrl.isEmpty || jwt.isEmpty) return null;

    final base = Uri.parse(_apiBaseUrl);
    final wsUri = base.replace(
      scheme: base.scheme == "https" ? "wss" : "ws",
      path: "/ws/bind",
      queryParameters: {"bind_session_id": bindSessionId},
    );
    Future<WebSocket> openSocket(String token) {
      return WebSocket.connect(wsUri.toString(), headers: {"Authorization": "Bearer $token"});
    }

    WebSocket socket;
    try {
      socket = await openSocket(jwt);
    } catch (e, st) {
      loggy.warning("bind ws connect failed, trying token refresh [session=$bindSessionId]", e, st);
      final refreshedJwt = await _bindJwt(forceRefresh: true);
      if (refreshedJwt.isEmpty) rethrow;
      socket = await openSocket(refreshedJwt);
    }
    socket.pingInterval = const Duration(seconds: 20);

    final controller = StreamController<BindWsEvent>.broadcast();
    socket.listen(
      (dynamic raw) {
        try {
          final text = raw?.toString() ?? "";
          if (text.isEmpty) return;
          final map = jsonDecode(text);
          if (map is! Map<String, dynamic>) return;
          final event = map["event"]?.toString() ?? "";
          if (event.isEmpty) return;
          final targetRaw = map["target"];
          final target = targetRaw is Map<String, dynamic> ? targetRaw : const <String, dynamic>{};
          controller.add(
            BindWsEvent(
              event: event,
              bindSessionId: map["bind_session_id"]?.toString(),
              at: _parseIso(map["at"]?.toString()),
              targetPlatform: target["platform"]?.toString(),
              targetDeviceMask: target["device_mask"]?.toString(),
            ),
          );
        } catch (_) {
          // Ignore malformed websocket payloads.
        }
      },
      onError: controller.addError,
      onDone: () async {
        if (!controller.isClosed) {
          await controller.close();
        }
      },
      cancelOnError: false,
    );

    Future<void> close() async {
      try {
        await socket.close();
      } catch (_) {
        // ignore close race
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    return BindWsConnection(events: controller.stream, close: close);
  }

  Future<Map<String, dynamic>> _request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) {
    if (_apiBaseUrl.isEmpty) {
      loggy.warning("bind request skipped: not configured [base=empty]");
      throw const MobileBindException("bind_not_configured");
    }

    final base = Uri.parse(_apiBaseUrl);
    final uri = base.resolve(path).replace(queryParameters: query).toString();
    loggy.info("bind request: $method $uri");
    Future<Response<Map<String, dynamic>>> send({required bool directOnly, required String jwt}) {
      final headers = {"Authorization": "Bearer $jwt", "Content-Type": "application/json"};
      return switch (method) {
        "GET" => _httpClient.get<Map<String, dynamic>>(uri, headers: headers, directOnly: directOnly),
        "POST" => _httpClient.post<Map<String, dynamic>>(
          uri,
          data: body ?? const {},
          headers: headers,
          directOnly: directOnly,
        ),
        _ => throw const MobileBindException("unsupported_method"),
      };
    }

    Future<Response<Map<String, dynamic>>> sendWithFallback(String jwt) async {
      try {
        return await send(directOnly: true, jwt: jwt);
      } on DioException catch (e, st) {
        if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.connectionError) {
          loggy.warning("bind request fallback to proxy-aware mode: $method $uri ${_dioDebug(e)}", e, st);
          return await send(directOnly: false, jwt: jwt);
        }
        rethrow;
      }
    }

    Future<Map<String, dynamic>> execute({required bool allowRefresh}) async {
      final jwt = await _bindJwt();
      if (jwt.isEmpty) {
        throw const MobileBindException("bind_not_configured");
      }
      try {
        final response = await sendWithFallback(jwt);
        final bodyMap = response.data;
        loggy.info("bind response [$method $uri] status=${response.statusCode}");
        if (bodyMap == null) throw const MobileBindException("empty_response");
        if (bodyMap["ok"] == false) {
          final serverError = _extractApiErrorFromBody(bodyMap) ?? "request_failed";
          loggy.warning("bind server error [endpoint=$path status=${response.statusCode} error=$serverError]");
          throw MobileBindException(serverError);
        }
        if (bodyMap["ok"] != true) {
          throw const MobileBindException("invalid_response");
        }
        final data = bodyMap["data"];
        if (data is Map<String, dynamic>) return data;
        return bodyMap;
      } on DioException catch (e, st) {
        loggy.warning("bind request failed (dio): $method $uri ${_dioDebug(e)}", e, st);
        final apiError = _extractApiErrorFromDio(e);
        if (allowRefresh && (apiError == "jwt_expired" || apiError == "unauthorized")) {
          await _bindJwt(forceRefresh: true);
          return execute(allowRefresh: false);
        }
        if (apiError != null) {
          throw MobileBindException(apiError);
        }
        throw MobileBindException("network_${e.type.name}");
      } on SocketException catch (e, st) {
        loggy.warning("bind request failed (socket): $method $uri", e, st);
        throw const MobileBindException("network_socket");
      } on HandshakeException catch (e, st) {
        loggy.warning("bind request failed (tls): $method $uri", e, st);
        throw const MobileBindException("network_tls");
      } on MobileBindException {
        rethrow;
      } catch (e, st) {
        loggy.warning("bind request failed (unknown): $method $uri", e, st);
        throw const MobileBindException("network_unknown");
      }
    }

    return execute(allowRefresh: true);
  }

  String _platformName() {
    if (PlatformUtils.isAndroid) return "android";
    if (PlatformUtils.isIOS) return "ios";
    if (PlatformUtils.isWindows) return "windows";
    if (PlatformUtils.isMacOS) return "macos";
    if (PlatformUtils.isLinux) return "linux";
    return "unknown";
  }

  Future<String> _bindJwt({bool forceRefresh = false}) async {
    final prefToken = (_preferences.getString(_bindJwtPrefKey) ?? "").trim();
    final prefExpiresAt = _parseIso(_preferences.getString(_bindJwtExpiresPrefKey));
    final envToken = _bindJwtEnv.trim();
    final now = DateTime.now().toUtc();

    final prefFresh =
        prefToken.isNotEmpty &&
        prefExpiresAt != null &&
        prefExpiresAt.isAfter(now.add(const Duration(seconds: 20))) &&
        !_isJwtExpired(prefToken);
    if (!forceRefresh && prefFresh) {
      return prefToken;
    }

    if (_apiBaseUrl.isNotEmpty && _mobileApiKey.isNotEmpty) {
      final deviceId = await _stableDeviceId.getOrCreate();
      final rawUserId = (_preferences.getString(_prefUserId) ?? "").trim();
      final knownUserId = int.tryParse(rawUserId);
      try {
        final token = await _fetchBindToken(deviceId: deviceId, userId: knownUserId);
        if (token != null && token.isNotEmpty) {
          return token;
        }
      } on DioException catch (e, st) {
        final apiError = _extractApiErrorFromDio(e);
        if (apiError == "device_user_mismatch") {
          try {
            await _preferences.remove(_prefUserId);
            final token = await _fetchBindToken(deviceId: deviceId);
            if (token != null && token.isNotEmpty) {
              return token;
            }
          } on DioException catch (retryE, retrySt) {
            final retryError = _extractApiErrorFromDio(retryE);
            if (retryError == "device_not_registered") {
              try {
                final userId = await _registerDeviceForBind(deviceId);
                final token = await _fetchBindToken(deviceId: deviceId, userId: userId);
                if (token != null && token.isNotEmpty) {
                  return token;
                }
              } catch (registerError, registerStack) {
                loggy.warning("bind token refresh retry failed [after_register]", registerError, registerStack);
              }
            }
            loggy.warning(
              "bind token refresh retry failed [after_mismatch error=${retryError ?? retryE.type.name}]",
              retryE,
              retrySt,
            );
          } catch (retryError, retryStack) {
            loggy.warning("bind token refresh retry failed [after_mismatch]", retryError, retryStack);
          }
        } else if (apiError == "device_not_registered" || apiError == "user_id_required") {
          try {
            final userId =
                knownUserId ??
                await _registerDeviceForBind(deviceId) ??
                _parseInt(_preferences.getString(_prefUserId));
            if (userId == null || userId <= 0) {
              throw const MobileBindException("user_id_required");
            }
            final token = await _fetchBindToken(deviceId: deviceId, userId: userId);
            if (token != null && token.isNotEmpty) {
              return token;
            }
          } catch (retryError, retryStack) {
            loggy.warning("bind token refresh retry failed [after_register]", retryError, retryStack);
          }
        }
        loggy.warning("bind token refresh failed [error=${apiError ?? e.type.name}]", e, st);
      } catch (e, st) {
        loggy.warning("bind token refresh failed", e, st);
      }
    }

    if (!forceRefresh && prefToken.isNotEmpty && !_isJwtExpired(prefToken)) {
      return prefToken;
    }
    if (envToken.isNotEmpty && !_isJwtExpired(envToken)) {
      return envToken;
    }
    if (prefToken.isNotEmpty) {
      return prefToken;
    }
    return envToken;
  }

  Future<String?> _fetchBindToken({required String deviceId, int? userId}) async {
    final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/bind/token").toString();
    final payload = <String, dynamic>{"device_id": deviceId, "sub": "mobile-client"};
    if (userId != null && userId > 0) {
      payload["user_id"] = userId;
    }
    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: payload,
      headers: {"x-api-key": _mobileApiKey, "Content-Type": "application/json"},
      directOnly: true,
    );
    final body = response.data;
    if (body == null || body["ok"] != true) {
      return null;
    }
    final data = body["data"];
    if (data is! Map<String, dynamic>) return null;
    final token = (data["token"]?.toString() ?? "").trim();
    final expiresAt = _parseIso(data["expires_at"]?.toString());
    final ownerUserId = _parseInt(data["user_id"]);
    if (token.isEmpty) return null;

    await _preferences.setString(_bindJwtPrefKey, token);
    if (expiresAt != null) {
      await _preferences.setString(_bindJwtExpiresPrefKey, expiresAt.toIso8601String());
    }
    if (ownerUserId != null && ownerUserId > 0) {
      await _preferences.setString(_prefUserId, ownerUserId.toString());
    }
    loggy.info(
      "bind token refreshed [source=mobile_api user_id=${ownerUserId ?? "-"} "
      "expires_at=${expiresAt?.toIso8601String() ?? "-"}]",
    );
    return token;
  }

  Future<int?> _registerDeviceForBind(String deviceId) async {
    if (_apiBaseUrl.isEmpty || _mobileApiKey.isEmpty || deviceId.trim().isEmpty) return null;
    final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/users/create").toString();
    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: {
        "device_id": deviceId,
        "platform": _platformName(),
        "subscription": {"create_if_missing": true},
      },
      headers: {"x-api-key": _mobileApiKey, "Content-Type": "application/json"},
      directOnly: true,
    );
    final body = response.data;
    if (body == null || body["ok"] != true) return null;
    final data = body["data"];
    if (data is! Map<String, dynamic>) return null;
    final userMap = data["user"];
    final user = userMap is Map<String, dynamic> ? userMap : const <String, dynamic>{};
    final userId = _parseInt(user["user_id"]);
    if (userId != null && userId > 0) {
      await _preferences.setString(_prefUserId, userId.toString());
    }
    final connectionMap = data["connection"];
    final connection = connectionMap is Map<String, dynamic> ? connectionMap : const <String, dynamic>{};
    final connLink = connection["raw_url"]?.toString().trim();
    if (connLink != null && connLink.isNotEmpty) {
      await _preferences.setString(_prefConnLink, connLink);
    }
    loggy.info("bind token preflight: device registered [device_id=$deviceId user_id=${userId ?? "-"}]");
    return userId;
  }

  BindCreateResult? _readCachedSession() {
    final raw = (_preferences.getString(_prefBindSessionCache) ?? "").trim();
    if (raw.isEmpty) return null;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return null;
      final sessionId = parsed["bind_session_id"]?.toString() ?? "";
      final bindCode = parsed["bind_code"]?.toString() ?? "";
      final expiresAt = _parseIso(parsed["expires_at"]?.toString());
      final wsChannel = parsed["ws_channel"]?.toString();
      if (sessionId.isEmpty || bindCode.isEmpty || expiresAt == null) return null;
      return BindCreateResult(bindSessionId: sessionId, bindCode: bindCode, expiresAt: expiresAt, wsChannel: wsChannel);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedSession(BindCreateResult session) async {
    final payload = jsonEncode({
      "bind_session_id": session.bindSessionId,
      "bind_code": session.bindCode,
      "expires_at": session.expiresAt.toIso8601String(),
      "ws_channel": session.wsChannel,
    });
    await _preferences.setString(_prefBindSessionCache, payload);
  }

  Future<void> _clearCachedSession() async {
    await _preferences.remove(_prefBindSessionCache);
  }

  Future<bool> _importFromConnLink(String connLink) async {
    final attempts = <String>[connLink, _appendPlatformHint(connLink)].where((e) => e.isNotEmpty).toSet().toList();

    for (final attemptLink in attempts) {
      loggy.info("bind import attempt [link=${_maskLink(attemptLink)}]");
      final directImport = await _profileRepository.upsertRemote(attemptLink).run();
      if (directImport.isRight()) {
        loggy.info("bind import success: upsertRemote(default)");
        return true;
      }
      loggy.warning("bind import fail: upsertRemote(default) ${_eitherError(directImport)}");

      final importUrl = await _resolveImportUrl(attemptLink);
      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        loggy.info("bind import resolved url [from=${_maskLink(attemptLink)} to=${_maskLink(importUrl)}]");
        final resolvedImport = await _profileRepository.upsertRemote(importUrl).run();
        if (resolvedImport.isRight()) {
          loggy.info("bind import success: upsertRemote(resolved/default)");
          return true;
        }
        loggy.warning("bind import fail: upsertRemote(resolved/default) ${_eitherError(resolvedImport)}");
      }

      final directOnlyImport = await _profileRepository.upsertRemote(attemptLink, directOnly: true).run();
      if (directOnlyImport.isRight()) {
        loggy.info("bind import success: upsertRemote(directOnly)");
        return true;
      }
      loggy.warning("bind import fail: upsertRemote(directOnly) ${_eitherError(directOnlyImport)}");

      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        final resolvedDirectOnlyImport = await _profileRepository.upsertRemote(importUrl, directOnly: true).run();
        if (resolvedDirectOnlyImport.isRight()) {
          loggy.info("bind import success: upsertRemote(resolved/directOnly)");
          return true;
        }
        loggy.warning("bind import fail: upsertRemote(resolved/directOnly) ${_eitherError(resolvedDirectOnlyImport)}");
      }

      final fallbackDirect = await _profileRepository.upsertRemote(attemptLink, validateConfigOnImport: false).run();
      if (fallbackDirect.isRight()) {
        loggy.info("bind import success: upsertRemote(no-validate)");
        return true;
      }
      loggy.warning("bind import fail: upsertRemote(no-validate) ${_eitherError(fallbackDirect)}");

      if (importUrl.isNotEmpty && importUrl != attemptLink) {
        final fallbackResolved = await _profileRepository.upsertRemote(importUrl, validateConfigOnImport: false).run();
        if (fallbackResolved.isRight()) {
          loggy.info("bind import success: upsertRemote(resolved/no-validate)");
          return true;
        }
        loggy.warning("bind import fail: upsertRemote(resolved/no-validate) ${_eitherError(fallbackResolved)}");
      }
    }

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
          loggy.info("bind import: removed previous managed profile [id=${previousManaged.id}]");
        }
      }

      if (previousConnLink.isNotEmpty) {
        final previousByUrl = await _profileDataSource.getByUrl(previousConnLink);
        if (previousByUrl != null && previousByUrl.id != active.id) {
          await _profileRepository.deleteById(previousByUrl.id, previousByUrl.active).run();
          loggy.info("bind import: removed previous profile by conn_link [id=${previousByUrl.id}]");
        }
      }
    } catch (e, st) {
      loggy.warning("bind import: failed to replace managed profile", e, st);
    }
  }

  Future<void> _syncActiveProfileMetaFromBind({String? status, DateTime? expiresAt}) async {
    try {
      final active = await _profileDataSource.watchActiveProfile().first;
      if (active == null || active.type != ProfileType.remote) return;

      final normalizedStatus = status?.trim().toLowerCase();
      final now = DateTime.now().toUtc();
      var effectiveExpire = expiresAt?.toUtc();

      if (normalizedStatus == "inactive") {
        effectiveExpire = (effectiveExpire != null && effectiveExpire.isAfter(now))
            ? now.subtract(const Duration(seconds: 1))
            : (effectiveExpire ?? now.subtract(const Duration(seconds: 1)));
      }

      if (effectiveExpire == null) return;

      await _profileDataSource.edit(
        active.id,
        ProfileEntriesCompanion(
          upload: Value(effectiveExpire.isAfter(now) ? 0 : (active.upload ?? 0)),
          download: Value(effectiveExpire.isAfter(now) ? 0 : (active.download ?? 0)),
          total: Value(effectiveExpire.isAfter(now) ? 920233720369 : (active.total ?? 920233720369)),
          expire: Value(effectiveExpire),
        ),
      );
    } catch (_) {
      // best effort
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

  Future<String?> _fetchMobileConnLinkByUserId(int userId) async {
    try {
      if (_apiBaseUrl.isEmpty || _mobileApiKey.isEmpty || userId <= 0) return null;
      final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/subscriptions/lookup?user_id=$userId").toString();
      final response = await _httpClient.get<Map<String, dynamic>>(
        uri,
        headers: {"x-api-key": _mobileApiKey},
        directOnly: true,
      );
      final body = response.data;
      if (body == null || body["ok"] != true) return null;
      final data = body["data"];
      if (data is! Map<String, dynamic>) return null;
      final connLink = data["connection_link"]?.toString().trim() ?? "";
      if (connLink.isEmpty || Uri.tryParse(connLink) == null) return null;
      return connLink;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _probeConnLinkStatus(String connLink) async {
    try {
      final response = await _httpClient.get<String>(connLink, headers: {"Accept": "text/html"}, directOnly: true);
      return response.statusCode;
    } on DioException catch (e) {
      return e.response?.statusCode;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveImportUrl(String connLink) async {
    try {
      final response = await _httpClient.get<String>(connLink, headers: {"Accept": "text/html"});
      loggy.info("bind resolveImportUrl fetched [link=${_maskLink(connLink)}, status=${response.statusCode}]");
      final content = response.data;
      if (content == null || content.isEmpty) {
        loggy.warning("bind resolveImportUrl empty content [link=${_maskLink(connLink)}]");
        return connLink;
      }

      final idIndex = content.indexOf('id="zeon-data"');
      final altIdIndex = content.indexOf("id='zeon-data'");
      final targetIndex = idIndex >= 0 ? idIndex : altIdIndex;
      if (targetIndex < 0) return connLink;

      final openTagEnd = content.indexOf(">", targetIndex);
      if (openTagEnd < 0) return connLink;
      final closeTagIndex = content.indexOf("</script>", openTagEnd + 1);
      if (closeTagIndex < 0) return connLink;

      final jsonText = content.substring(openTagEnd + 1, closeTagIndex).trim();
      if (jsonText.isEmpty) return connLink;
      final parsed = jsonDecode(jsonText);
      if (parsed is! Map<String, dynamic>) return connLink;

      final subscriptionUrl = parsed["subscriptionUrl"]?.toString() ?? "";
      if (subscriptionUrl.isEmpty || Uri.tryParse(subscriptionUrl) == null) return connLink;
      return subscriptionUrl;
    } catch (_) {
      loggy.warning("bind resolveImportUrl failed [link=${_maskLink(connLink)}]");
      return connLink;
    }
  }
}

class MobileBindException implements Exception {
  const MobileBindException(this.code);

  final String code;

  @override
  String toString() => code;
}

class BindCreateResult {
  const BindCreateResult({
    required this.bindSessionId,
    required this.bindCode,
    required this.expiresAt,
    this.wsChannel,
  });

  final String bindSessionId;
  final String bindCode;
  final DateTime expiresAt;
  final String? wsChannel;
}

class BindConfirmResult {
  const BindConfirmResult({
    required this.ownerUserId,
    required this.status,
    required this.connLink,
    required this.expiresAt,
  });

  final int ownerUserId;
  final String status;
  final String connLink;
  final DateTime? expiresAt;
}

class BindStatusResult {
  const BindStatusResult({required this.status, required this.expiresAt});

  final String status;
  final DateTime? expiresAt;
}

class BindWsEvent {
  const BindWsEvent({
    required this.event,
    required this.bindSessionId,
    required this.at,
    required this.targetPlatform,
    required this.targetDeviceMask,
  });

  final String event;
  final String? bindSessionId;
  final DateTime? at;
  final String? targetPlatform;
  final String? targetDeviceMask;
}

class BindWsConnection {
  const BindWsConnection({required this.events, required this.close});

  final Stream<BindWsEvent> events;
  final Future<void> Function() close;
}

DateTime? _parseIso(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim())?.toUtc();
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? "");
}

String? _extractApiErrorFromDio(DioException e) {
  if (e.type != DioExceptionType.badResponse) return null;
  final data = e.response?.data;
  if (data is Map<String, dynamic>) return _extractApiErrorFromBody(data);
  if (data is String && data.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        return _extractApiErrorFromBody(decoded);
      }
    } catch (_) {
      return null;
    }
  }
  return null;
}

String? _extractApiErrorFromBody(Map<String, dynamic> body) {
  final errorField = body["error"];
  if (errorField is String) {
    final normalized = errorField.trim();
    return normalized.isEmpty ? null : _normalizeErrorCode(normalized);
  }
  if (errorField is Map<String, dynamic>) {
    final code = errorField["code"]?.toString().trim();
    if (code != null && code.isNotEmpty) return _normalizeErrorCode(code);
    final message = errorField["message"]?.toString().trim();
    if (message != null && message.isNotEmpty) return _normalizeErrorCode(message);
  }
  final topCode = body["code"]?.toString().trim();
  if (topCode != null && topCode.isNotEmpty) return _normalizeErrorCode(topCode);
  return null;
}

String _normalizeErrorCode(String raw) {
  final code = raw.trim();
  if (code.isEmpty) return code;
  return code.toLowerCase().replaceAll("-", "_").replaceAll(" ", "_");
}

String _dioDebug(DioException e) {
  final status = e.response?.statusCode;
  final type = e.type.name;
  final data = e.response?.data;
  String body = "";
  if (data is String) {
    body = data;
  } else if (data != null) {
    body = jsonEncode(data);
  }
  if (body.length > 300) {
    body = "${body.substring(0, 300)}...";
  }
  return "[type=$type status=${status ?? "-"} body=${body.isEmpty ? "-" : body}]";
}

String _maskLink(String link) {
  if (link.isEmpty) return "-";
  try {
    final uri = Uri.parse(link);
    final host = uri.host;
    final path = uri.path;
    return "$host$path";
  } catch (_) {
    return link.length > 80 ? "${link.substring(0, 80)}..." : link;
  }
}

String _eitherError(dynamic either) {
  return "[result=$either]";
}

bool _isJwtExpired(String token) {
  try {
    final parts = token.split(".");
    if (parts.length < 2) return false;
    final payload = parts[1];
    final normalized = base64Url.normalize(payload);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final map = jsonDecode(decoded);
    if (map is! Map<String, dynamic>) return false;
    final exp = map["exp"];
    final expSeconds = exp is int ? exp : int.tryParse(exp?.toString() ?? "");
    if (expSeconds == null || expSeconds <= 0) return false;
    final expUtc = DateTime.fromMillisecondsSinceEpoch(expSeconds * 1000, isUtc: true);
    return DateTime.now().toUtc().isAfter(expUtc);
  } catch (_) {
    return false;
  }
}
