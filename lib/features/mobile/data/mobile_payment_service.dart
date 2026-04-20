import 'package:hiddify/core/http_client/dio_http_client.dart';
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

  static const _prefUserId = "mobile_payment_user_id";

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

    try {
      final response = await _httpClient.post<Map<String, dynamic>>(
        uri,
        data: payload,
        headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
        directOnly: true,
      );
      final body = response.data;
      if (body == null || body["ok"] != true) return null;
      final data = body["data"];
      if (data is! Map<String, dynamic>) return null;

      final confirmationUrl = _firstNonEmpty([
        data["confirmation_url"]?.toString(),
        data["confirmationUrl"]?.toString(),
        data["payment_url"]?.toString(),
        data["url"]?.toString(),
      ]);
      if (confirmationUrl == null || Uri.tryParse(confirmationUrl) == null) return null;

      return PaymentCheckout(
        confirmationUrl: confirmationUrl,
        orderId: _firstNonEmpty([data["order_id"]?.toString(), data["orderId"]?.toString()]),
        paymentId: _firstNonEmpty([data["payment_id"]?.toString(), data["paymentId"]?.toString()]),
      );
    } catch (e, st) {
      loggy.warning("mobile payments/create failed", e, st);
      return null;
    }
  }

  Future<int?> _ensureUserId() async {
    final cached = int.tryParse(_preferences.getString(_prefUserId) ?? "");
    if (cached != null && cached > 0) {
      final valid = await _isExistingMobileUser(cached);
      if (valid) return cached;
    }

    final deviceId = await _ensureDeviceId();
    if (deviceId.isEmpty) return null;

    final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/users/create").toString();
    try {
      final response = await _httpClient.post<Map<String, dynamic>>(
        uri,
        data: {"device_id": deviceId},
        headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
        directOnly: true,
      );
      final body = response.data;
      if (body == null || body["ok"] != true) return null;
      final data = body["data"];
      if (data is! Map<String, dynamic>) return null;
      final userId = (data["user_id"] as num?)?.toInt() ?? int.tryParse(data["user_id"]?.toString() ?? "");
      if (userId == null || userId <= 0) return null;
      await _preferences.setString(_prefUserId, userId.toString());
      return userId;
    } catch (e, st) {
      loggy.warning("mobile users/create failed while ensuring user id", e, st);
      return null;
    }
  }

  Future<bool> _isExistingMobileUser(int userId) async {
    try {
      final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/users/$userId/link").toString();
      final response = await _httpClient.get<Map<String, dynamic>>(
        uri,
        headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
        directOnly: true,
      );
      final body = response.data;
      return (response.statusCode ?? 0) == 200 && body != null && body["ok"] == true;
    } catch (_) {
      return false;
    }
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
