import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MobilePaymentService with InfraLogger {
  MobilePaymentService({required DioHttpClient httpClient, required SharedPreferences preferences})
    : _httpClient = httpClient,
      _preferences = preferences;

  static const _apiBaseUrl = String.fromEnvironment(
    "mobile_payment_api_base_url",
    defaultValue: "https://zeon-vps.link",
  );
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const _prefCanonicalUserId = MobileConnLinkImportService.prefUserId;
  static const _prefLegacyPaymentUserId = "mobile_payment_user_id";

  final DioHttpClient _httpClient;
  final SharedPreferences _preferences;
  StableDeviceIdService get _stableDeviceId => StableDeviceIdService(preferences: _preferences);

  Future<PaymentCheckout?> createPayment({required String plan}) async {
    if (PlatformUtils.isWeb) return null;
    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) return null;

    final normalizedPlan = _normalizePlan(plan);
    final userId = await _ensureUserId();
    if (userId == null || userId <= 0) return null;
    final deviceId = await _ensureDeviceId();
    if (deviceId.isEmpty) return null;

    final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/payments/create").toString();
    final payload = {
      "user_id": userId,
      "device_id": deviceId,
      "plan": normalizedPlan == "trial" ? "trial" : int.parse(normalizedPlan),
    };

    loggy.info(
      "mobile payment create request prepared "
      "[canonical_user_id=$userId, device_id=$deviceId, plan=${payload["plan"]}]",
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

        final confirmationUrl = _firstNonEmpty([
          data["confirmation_url"]?.toString(),
          data["confirmationUrl"]?.toString(),
          data["payment_url"]?.toString(),
          data["url"]?.toString(),
        ]);
        if (confirmationUrl == null || Uri.tryParse(confirmationUrl) == null) continue;

        return PaymentCheckout(
          confirmationUrl: confirmationUrl,
          orderId: _firstNonEmpty([data["order_id"]?.toString(), data["orderId"]?.toString()]),
          paymentId: _firstNonEmpty([data["payment_id"]?.toString(), data["paymentId"]?.toString()]),
        );
      } catch (e, st) {
        loggy.warning("mobile payments/create failed [directOnly=$directOnly]", e, st);
      }
    }
    return null;
  }

  Future<int?> _ensureUserId() async {
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
}

class PaymentCheckout {
  const PaymentCheckout({required this.confirmationUrl, this.orderId, this.paymentId});

  final String confirmationUrl;
  final String? orderId;
  final String? paymentId;
}
