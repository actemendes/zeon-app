import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/mobile_payment_deep_link.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MobilePaymentService with InfraLogger {
  MobilePaymentService({
    required DioHttpClient httpClient,
    required SharedPreferences preferences,
    required MobileConnLinkImportService connLinkImportService,
  }) : _httpClient = httpClient,
       _preferences = preferences,
       _connLinkImportService = connLinkImportService;

  static const _apiBaseUrl = String.fromEnvironment(
    "mobile_payment_api_base_url",
    defaultValue: "https://zeon-vps.link",
  );
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const _prefCanonicalUserId = MobileConnLinkImportService.prefUserId;
  static const _prefLegacyPaymentUserId = "mobile_payment_user_id";
  static const _prefLastPaymentSessionId = "mobile_payment_session_id";
  static const _prefLastPaymentSessionCreatedAtMs = "mobile_payment_session_created_at_ms";
  static const paymentSessionRecoveryWindow = Duration(minutes: 15);
  static const _statusPendingBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 13),
    Duration(seconds: 21),
  ];

  final DioHttpClient _httpClient;
  final SharedPreferences _preferences;
  final MobileConnLinkImportService _connLinkImportService;
  StableDeviceIdService get _stableDeviceId => StableDeviceIdService(preferences: _preferences);

  Future<PaymentCheckout?> createPayment({required String plan}) async {
    if (PlatformUtils.isWeb) return null;
    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) return null;

    final normalizedPlan = _normalizePlan(plan);
    final userId = await _resolveCanonicalUserId(allowCreate: true);
    if (userId == null || userId <= 0) return null;
    final deviceId = await _ensureDeviceId();
    if (deviceId.isEmpty) return null;

    final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/payments/create").toString();
    final payload = {"user_id": userId, "device_id": deviceId, "plan": normalizedPlan, "source": "app"};

    loggy.info(
      "mobile payment create request prepared "
      "[canonical_user_id=$userId, user_id=${payload["user_id"]}, device_id=${payload["device_id"]}, plan=${payload["plan"]}]",
    );

    for (final directOnly in const [true, false]) {
      try {
        loggy.info(
          "mobile payments/create attempt "
          "[directOnly=$directOnly, user_id=${payload["user_id"]}, device_id=${payload["device_id"]}, plan=${payload["plan"]}]",
        );
        final response = await _httpClient.post<Map<String, dynamic>>(
          uri,
          data: payload,
          headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
          directOnly: directOnly,
        );
        final body = response.data;
        if (body == null || body["ok"] != true) continue;
        final data = body["data"];
        if (data is! Map<String, dynamic>) continue;

        final sessionId = _firstNonEmpty([
          data["payment_session_id"]?.toString(),
          data["paymentSessionId"]?.toString(),
          data["sid"]?.toString(),
        ]);
        final confirmationUrl = _firstNonEmpty([
          data["confirmation_url"]?.toString(),
          data["confirmationUrl"]?.toString(),
          data["payment_url"]?.toString(),
          data["url"]?.toString(),
        ]);
        if (confirmationUrl == null) continue;
        final normalizedConfirmationUrl = _normalizePaymentReturnDeepLink(confirmationUrl);
        if (Uri.tryParse(normalizedConfirmationUrl) == null) continue;
        if (sessionId != null) {
          await _rememberPaymentSession(sessionId);
        }
        loggy.info("mobile payment session created [sid=${sessionId ?? "-"}, user_id=$userId, directOnly=$directOnly]");

        return PaymentCheckout(
          confirmationUrl: normalizedConfirmationUrl,
          paymentSessionId: sessionId,
          orderId: _firstNonEmpty([data["order_id"]?.toString(), data["orderId"]?.toString()]),
          paymentId: _firstNonEmpty([data["payment_id"]?.toString(), data["paymentId"]?.toString()]),
        );
      } catch (e, st) {
        loggy.warning("mobile payments/create failed [directOnly=$directOnly]", e, st);
      }
    }
    return null;
  }

  Future<PaymentSessionProcessResult> processPaymentSessionReturn({required String sid, int maxAttempts = 7}) async {
    final normalizedSid = sid.trim();
    if (normalizedSid.isEmpty) {
      await _clearStoredPaymentSessionIfMatches(normalizedSid);
      return const PaymentSessionProcessResult(
        sid: "",
        state: PaymentSessionState.failed,
        reason: "invalid_sid",
        refreshTriggered: false,
      );
    }

    final canonicalUserId = await _resolveCanonicalUserId(allowCreate: false);
    if (canonicalUserId == null || canonicalUserId <= 0) {
      loggy.warning(
        "mobile payment return skipped: canonical user_id missing [sid=$normalizedSid, canonical_key=$_prefCanonicalUserId]",
      );
      return PaymentSessionProcessResult(
        sid: normalizedSid,
        state: PaymentSessionState.failed,
        canonicalUserId: canonicalUserId,
        reason: "canonical_user_id_missing",
        refreshTriggered: false,
      );
    }

    loggy.info(
      "mobile payment return processing started [sid=$normalizedSid, canonical_user_id=$canonicalUserId, max_attempts=$maxAttempts]",
    );

    final safeAttempts = maxAttempts.clamp(1, 8);
    var attemptsUsed = 0;
    while (attemptsUsed < safeAttempts) {
      attemptsUsed += 1;
      final status = await _fetchPaymentStatus(normalizedSid);
      if (status == null) {
        if (attemptsUsed >= safeAttempts) {
          return PaymentSessionProcessResult(
            sid: normalizedSid,
            state: PaymentSessionState.pending,
            canonicalUserId: canonicalUserId,
            reason: "status_unavailable",
            refreshTriggered: false,
          );
        }
        await _sleepForStatusRetry(attemptsUsed);
        continue;
      }

      loggy.info(
        "mobile payment status endpoint result "
        "[sid=$normalizedSid, status=${status.rawStatus}, status_user_id=${status.userId?.toString() ?? "-"}, "
        "subscription_status=${status.apiStatus ?? "-"}, subscription_expires_at=${status.apiExpiresAt?.toIso8601String() ?? "-"}, "
        "attempt=$attemptsUsed/$safeAttempts]",
      );

      switch (status.state) {
        case PaymentSessionState.pending:
          if (attemptsUsed >= safeAttempts) {
            return PaymentSessionProcessResult(
              sid: normalizedSid,
              state: PaymentSessionState.pending,
              canonicalUserId: canonicalUserId,
              statusUserId: status.userId,
              reason: "pending",
              refreshTriggered: false,
            );
          }
          await _sleepForStatusRetry(attemptsUsed);
          continue;
        case PaymentSessionState.succeeded:
          final statusUserId = status.userId;
          if (statusUserId != null && statusUserId > 0 && statusUserId != canonicalUserId) {
            loggy.warning(
              "mobile payment status user_id mismatch "
              "[sid=$normalizedSid, canonical_user_id=$canonicalUserId, status_user_id=$statusUserId]",
            );
            await _clearStoredPaymentSessionIfMatches(normalizedSid);
            return PaymentSessionProcessResult(
              sid: normalizedSid,
              state: PaymentSessionState.failed,
              canonicalUserId: canonicalUserId,
              statusUserId: statusUserId,
              reason: "user_id_mismatch",
              refreshTriggered: false,
            );
          }

          final refreshTriggered = await _refreshConnLinkAfterSuccess(
            sid: normalizedSid,
            canonicalUserId: canonicalUserId,
            statusConnLink: status.connLink,
            statusApiStatus: status.apiStatus,
            statusApiExpiresAt: status.apiExpiresAt,
            statusApiLogin: status.apiLogin,
          );
          await _clearStoredPaymentSessionIfMatches(normalizedSid);
          return PaymentSessionProcessResult(
            sid: normalizedSid,
            state: PaymentSessionState.succeeded,
            canonicalUserId: canonicalUserId,
            statusUserId: statusUserId,
            refreshTriggered: refreshTriggered,
          );
        case PaymentSessionState.canceled:
          await _clearStoredPaymentSessionIfMatches(normalizedSid);
          return PaymentSessionProcessResult(
            sid: normalizedSid,
            state: PaymentSessionState.canceled,
            canonicalUserId: canonicalUserId,
            statusUserId: status.userId,
            reason: status.reason,
            refreshTriggered: false,
          );
        case PaymentSessionState.failed:
          await _clearStoredPaymentSessionIfMatches(normalizedSid);
          return PaymentSessionProcessResult(
            sid: normalizedSid,
            state: PaymentSessionState.failed,
            canonicalUserId: canonicalUserId,
            statusUserId: status.userId,
            reason: status.reason,
            refreshTriggered: false,
          );
      }
    }

    return PaymentSessionProcessResult(
      sid: normalizedSid,
      state: PaymentSessionState.pending,
      canonicalUserId: canonicalUserId,
      reason: "pending",
      refreshTriggered: false,
    );
  }

  Future<String?> getRecoverablePaymentSessionId({
    Duration maxAge = paymentSessionRecoveryWindow,
    DateTime? now,
  }) async {
    final sid = (_preferences.getString(_prefLastPaymentSessionId) ?? "").trim();
    if (sid.isEmpty) return null;

    final createdAtMs = _preferences.getInt(_prefLastPaymentSessionCreatedAtMs);
    if (createdAtMs == null || createdAtMs <= 0) {
      await _rememberPaymentSession(sid);
      return sid;
    }

    final createdAt = DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true);
    final current = (now ?? DateTime.now()).toUtc();
    if (current.difference(createdAt) > maxAge) {
      loggy.info(
        "mobile payment recovery sid expired, removing [sid=$sid, age_seconds=${current.difference(createdAt).inSeconds}]",
      );
      await _clearStoredPaymentSessionIfMatches(sid);
      return null;
    }
    return sid;
  }

  Future<int?> _resolveCanonicalUserId({required bool allowCreate}) async {
    final canonical = int.tryParse((_preferences.getString(_prefCanonicalUserId) ?? "").trim());
    if (canonical != null && canonical > 0) {
      await _cleanupLegacyPaymentUserId(canonical);
      loggy.info("mobile payment user_id resolved [source=canonical user_id=$canonical]");
      return canonical;
    }

    final legacy = int.tryParse((_preferences.getString(_prefLegacyPaymentUserId) ?? "").trim());
    if (legacy != null && legacy > 0) {
      await _storeCanonicalUserId(legacy, source: "legacy_payment_pref");
      loggy.warning(
        "mobile payment user_id migrated from legacy key "
        "[legacy_key=$_prefLegacyPaymentUserId user_id=$legacy]",
      );
      return legacy;
    }

    if (!allowCreate) return null;

    final deviceId = await _ensureDeviceId();
    if (deviceId.isEmpty) return null;

    final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/users/create").toString();
    for (final directOnly in const [true, false]) {
      try {
        final response = await _httpClient.post<Map<String, dynamic>>(
          uri,
          data: {"device_id": deviceId},
          headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
          directOnly: directOnly,
        );
        final body = response.data;
        if (body == null || body["ok"] != true) continue;
        final data = body["data"];
        if (data is! Map<String, dynamic>) continue;
        final userId = (data["user_id"] as num?)?.toInt() ?? int.tryParse(data["user_id"]?.toString() ?? "");
        if (userId == null || userId <= 0) continue;
        await _storeCanonicalUserId(userId, source: "mobile_users_create");
        return userId;
      } catch (e, st) {
        loggy.warning("mobile users/create failed while ensuring user id [directOnly=$directOnly]", e, st);
      }
    }
    return null;
  }

  Future<PaymentSessionStatus?> _fetchPaymentStatus(String sid) async {
    final queryUri = Uri.parse(
      _apiBaseUrl,
    ).resolve("/api/mobile/payments/status").replace(queryParameters: {"sid": sid});
    for (final directOnly in const [true, false]) {
      try {
        final response = await _httpClient.get<Map<String, dynamic>>(
          queryUri.toString(),
          headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
          directOnly: directOnly,
        );
        final body = response.data;
        if (body == null) continue;
        final data = body["data"];
        final dataMap = data is Map<String, dynamic> ? data : body;
        final statusRaw = _firstNonEmpty([
          dataMap["status"]?.toString(),
          dataMap["payment_status"]?.toString(),
          dataMap["paymentStatus"]?.toString(),
        ]);
        if (statusRaw == null) continue;
        final normalizedState = _mapPaymentState(statusRaw);
        final userMap = dataMap["user"];
        final userData = userMap is Map<String, dynamic> ? userMap : const <String, dynamic>{};
        final subscriptionMap = dataMap["subscription"];
        final subscriptionData = subscriptionMap is Map<String, dynamic> ? subscriptionMap : const <String, dynamic>{};
        final connLink = _firstNonEmpty([
          dataMap["conn_link"]?.toString(),
          dataMap["connection_link"]?.toString(),
          dataMap["raw_url"]?.toString(),
          subscriptionData["conn_link"]?.toString(),
          subscriptionData["connection_link"]?.toString(),
          dataMap["url"]?.toString(),
        ]);
        return PaymentSessionStatus(
          sid: sid,
          state: normalizedState,
          rawStatus: statusRaw.toLowerCase(),
          userId: _parseInt(dataMap["user_id"]) ?? _parseInt(userData["user_id"]),
          connLink: connLink,
          apiStatus: _firstNonEmpty([
            subscriptionData["status"]?.toString(),
            dataMap["subscription_status"]?.toString(),
            dataMap["subscriptionStatus"]?.toString(),
          ])?.toLowerCase(),
          apiExpiresAt: _parseFlexibleDateTime(
            _firstNonEmpty([
              subscriptionData["expires_at"]?.toString(),
              subscriptionData["expiresAt"]?.toString(),
              dataMap["expires_at"]?.toString(),
              dataMap["expiresAt"]?.toString(),
            ]),
          ),
          apiLogin: _firstNonEmpty([
            userData["login"]?.toString(),
            userData["username"]?.toString(),
            userData["name"]?.toString(),
            dataMap["login"]?.toString(),
            dataMap["username"]?.toString(),
          ]),
          reason: _firstNonEmpty([
            dataMap["reason"]?.toString(),
            dataMap["error"]?.toString(),
            dataMap["message"]?.toString(),
            body["error"]?.toString(),
          ]),
        );
      } catch (e, st) {
        if (e is DioException && e.response?.statusCode == 404) {
          return PaymentSessionStatus(
            sid: sid,
            state: PaymentSessionState.failed,
            rawStatus: "not_found",
            reason: "payment_session_not_found",
          );
        }
        loggy.warning("mobile payments/status failed [sid=$sid, directOnly=$directOnly]", e, st);
      }
    }
    return null;
  }

  Future<void> _sleepForStatusRetry(int attemptNumber) async {
    final index = (attemptNumber - 1).clamp(0, _statusPendingBackoff.length - 1);
    await Future<void>.delayed(_statusPendingBackoff[index]);
  }

  Future<bool> _refreshConnLinkAfterSuccess({
    required String sid,
    required int canonicalUserId,
    required String? statusConnLink,
    required String? statusApiStatus,
    required DateTime? statusApiExpiresAt,
    required String? statusApiLogin,
  }) async {
    final savedConnLink = (_preferences.getString(MobileConnLinkImportService.prefConnLink) ?? "").trim();
    if (savedConnLink.isNotEmpty && Uri.tryParse(savedConnLink) != null) {
      loggy.info(
        "mobile payment success: starting saved conn_link metadata refresh "
        "[sid=$sid, conn_link=${_maskLink(savedConnLink)}]",
      );
      try {
        await _connLinkImportService.refreshActiveProfileMetadata(
          savedConnLink,
          apiStatus: statusApiStatus,
          apiExpiresAt: statusApiExpiresAt,
          apiLogin: statusApiLogin,
        );
        loggy.info("mobile payment success: saved conn_link metadata refresh completed [sid=$sid]");
        return true;
      } catch (e, st) {
        loggy.warning("mobile payment success: saved conn_link metadata refresh failed [sid=$sid]", e, st);
      }
    }

    final connLinkFromStatus = statusConnLink?.trim();
    if (connLinkFromStatus != null && connLinkFromStatus.isNotEmpty && Uri.tryParse(connLinkFromStatus) != null) {
      loggy.info(
        "mobile payment success: starting conn_link import refresh fallback "
        "[sid=$sid, canonical_user_id=$canonicalUserId, conn_link=${_maskLink(connLinkFromStatus)}]",
      );
      try {
        await _connLinkImportService.importConnectionLink(
          connLinkFromStatus,
          userId: canonicalUserId,
          apiStatus: statusApiStatus,
          apiExpiresAt: statusApiExpiresAt,
          apiLogin: statusApiLogin,
          clearUserIdWhenMissing: false,
        );
        loggy.info("mobile payment success: conn_link import refresh fallback completed [sid=$sid]");
        return true;
      } catch (e, st) {
        loggy.warning("mobile payment success: conn_link import refresh fallback failed [sid=$sid]", e, st);
      }
    }

    loggy.warning("mobile payment success: conn_link refresh skipped [sid=$sid, reason=missing_conn_link]");
    return false;
  }

  static PaymentSessionState _mapPaymentState(String value) {
    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case "succeeded":
      case "success":
      case "paid":
        return PaymentSessionState.succeeded;
      case "pending":
      case "processing":
      case "created":
        return PaymentSessionState.pending;
      case "canceled":
      case "cancelled":
        return PaymentSessionState.canceled;
      case "failed":
      case "error":
      case "expired":
        return PaymentSessionState.failed;
      default:
        return PaymentSessionState.pending;
    }
  }

  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? "");
  }

  static DateTime? _parseFlexibleDateTime(String? raw) {
    final value = raw?.trim() ?? "";
    if (value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toUtc();
    final asInt = int.tryParse(value);
    if (asInt == null) return null;
    final ms = asInt >= 1_000_000_000_000 ? asInt : asInt * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> _rememberPaymentSession(String sid) async {
    final normalizedSid = sid.trim();
    if (normalizedSid.isEmpty) return;
    await _preferences.setString(_prefLastPaymentSessionId, normalizedSid);
    await _preferences.setInt(_prefLastPaymentSessionCreatedAtMs, DateTime.now().toUtc().millisecondsSinceEpoch);
  }

  Future<void> _clearStoredPaymentSessionIfMatches(String sid) async {
    final normalizedSid = sid.trim();
    if (normalizedSid.isEmpty) return;
    final currentSid = (_preferences.getString(_prefLastPaymentSessionId) ?? "").trim();
    if (currentSid != normalizedSid) return;
    await _preferences.remove(_prefLastPaymentSessionId);
    await _preferences.remove(_prefLastPaymentSessionCreatedAtMs);
  }

  Future<void> _storeCanonicalUserId(int userId, {required String source}) async {
    await _preferences.setString(_prefCanonicalUserId, userId.toString());
    await _preferences.remove(_prefLegacyPaymentUserId);
    loggy.info("mobile payment user_id stored [source=$source canonical_key=$_prefCanonicalUserId user_id=$userId]");
  }

  Future<void> _cleanupLegacyPaymentUserId(int canonicalUserId) async {
    final legacyRaw = (_preferences.getString(_prefLegacyPaymentUserId) ?? "").trim();
    if (legacyRaw.isEmpty) return;
    final legacyUserId = int.tryParse(legacyRaw);
    await _preferences.remove(_prefLegacyPaymentUserId);
    if (legacyUserId == null || legacyUserId <= 0) {
      loggy.info("mobile payment legacy user_id key removed [reason=invalid_value]");
      return;
    }
    if (legacyUserId != canonicalUserId) {
      loggy.warning(
        "mobile payment legacy user_id key removed due canonical mismatch "
        "[canonical_user_id=$canonicalUserId legacy_user_id=$legacyUserId]",
      );
      return;
    }
    loggy.info("mobile payment legacy user_id key removed [reason=already_migrated user_id=$legacyUserId]");
  }

  Future<String> _ensureDeviceId() {
    return _stableDeviceId.getOrCreate();
  }

  static String _normalizePlan(String plan) {
    final p = plan.trim().toLowerCase();
    switch (p) {
      case "1":
      case "3":
      case "6":
      case "12":
      case "trial":
        return p;
      default:
        return "1";
    }
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static String _normalizePaymentReturnDeepLink(String confirmationUrl) {
    const legacyBase = '$legacyMobilePaymentResultDeepLinkScheme://$mobilePaymentResultDeepLinkHost';
    final singleEncodedLegacyBase = Uri.encodeComponent(legacyBase);
    final doubleEncodedLegacyBase = Uri.encodeComponent(singleEncodedLegacyBase);
    final singleEncodedZeonBase = Uri.encodeComponent(mobilePaymentResultDeepLinkBase);
    final doubleEncodedZeonBase = Uri.encodeComponent(singleEncodedZeonBase);

    return confirmationUrl
        .replaceAll(legacyBase, mobilePaymentResultDeepLinkBase)
        .replaceAll(singleEncodedLegacyBase, singleEncodedZeonBase)
        .replaceAll(doubleEncodedLegacyBase, doubleEncodedZeonBase);
  }

  static String _maskLink(String link) {
    if (link.isEmpty) return "-";
    try {
      final uri = Uri.parse(link);
      return "${uri.host}${uri.path}";
    } catch (_) {
      return link.length > 80 ? "${link.substring(0, 80)}..." : link;
    }
  }
}

enum PaymentSessionState { pending, succeeded, canceled, failed }

class PaymentSessionProcessResult {
  const PaymentSessionProcessResult({
    required this.sid,
    required this.state,
    required this.refreshTriggered,
    this.canonicalUserId,
    this.statusUserId,
    this.reason,
  });

  final String sid;
  final PaymentSessionState state;
  final int? canonicalUserId;
  final int? statusUserId;
  final String? reason;
  final bool refreshTriggered;
}

class PaymentSessionStatus {
  const PaymentSessionStatus({
    required this.sid,
    required this.state,
    required this.rawStatus,
    this.userId,
    this.connLink,
    this.apiStatus,
    this.apiExpiresAt,
    this.apiLogin,
    this.reason,
  });

  final String sid;
  final PaymentSessionState state;
  final String rawStatus;
  final int? userId;
  final String? connLink;
  final String? apiStatus;
  final DateTime? apiExpiresAt;
  final String? apiLogin;
  final String? reason;
}

class PaymentCheckout {
  const PaymentCheckout({required this.confirmationUrl, this.paymentSessionId, this.orderId, this.paymentId});

  final String confirmationUrl;
  final String? paymentSessionId;
  final String? orderId;
  final String? paymentId;
}
