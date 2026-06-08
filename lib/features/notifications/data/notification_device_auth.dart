import 'dart:convert';

import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationDeviceAuth {
  NotificationDeviceAuth({required DioHttpClient httpClient, required SharedPreferences preferences})
    : _httpClient = httpClient,
      _preferences = preferences,
      _stableDeviceId = StableDeviceIdService(preferences: preferences);

  static const apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;
  static const _mobileApiKey = String.fromEnvironment(
    'mobile_api_key',
    defaultValue: 'mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7',
  );
  static const _prefToken = 'mobile_bind_jwt';
  static const _prefExpiresAt = 'mobile_bind_jwt_expires_at';
  static const _prefUserId = MobileConnLinkImportService.prefUserId;

  final DioHttpClient _httpClient;
  final SharedPreferences _preferences;
  final StableDeviceIdService _stableDeviceId;

  Future<String> resolveDeviceJwt({bool forceRefresh = false}) async {
    final now = DateTime.now().toUtc();
    final cached = (_preferences.getString(_prefToken) ?? '').trim();
    final expiresAt = DateTime.tryParse((_preferences.getString(_prefExpiresAt) ?? '').trim())?.toUtc();
    if (!forceRefresh && cached.isNotEmpty && !_isJwtExpired(cached)) {
      if (expiresAt == null || expiresAt.isAfter(now.add(const Duration(seconds: 20)))) {
        return cached;
      }
    }

    final deviceId = await _stableDeviceId.getOrCreate();
    if (apiBaseUrl.isEmpty || _mobileApiKey.isEmpty || deviceId.isEmpty) return cached;

    final userId = int.tryParse((_preferences.getString(_prefUserId) ?? '').trim());
    final token = await _fetchBindToken(deviceId: deviceId, userId: userId);
    return token ?? cached;
  }

  Future<String?> _fetchBindToken({required String deviceId, int? userId}) async {
    final uri = Uri.parse(apiBaseUrl).resolve('/api/v1/bind/token').toString();
    final payload = <String, dynamic>{'device_id': deviceId, 'sub': 'mobile-client'};
    if (userId != null && userId > 0) payload['user_id'] = userId;

    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: payload,
      headers: {'x-api-key': _mobileApiKey, 'Content-Type': 'application/json'},
      directOnly: true,
      disableRetry: true,
    );
    final body = response.data;
    if (body == null || body['ok'] != true) return null;
    final data = body['data'];
    if (data is! Map<String, dynamic>) return null;
    final token = (data['token']?.toString() ?? '').trim();
    if (token.isEmpty) return null;

    await _preferences.setString(_prefToken, token);
    final expiresAt = DateTime.tryParse((data['expires_at']?.toString() ?? '').trim())?.toUtc();
    if (expiresAt != null) {
      await _preferences.setString(_prefExpiresAt, expiresAt.toIso8601String());
    }
    final ownerUserId = _parseInt(data['user_id']);
    if (ownerUserId != null && ownerUserId > 0) {
      await _preferences.setString(_prefUserId, ownerUserId.toString());
    }
    return token;
  }
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _isJwtExpired(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return false;
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) return false;
    final exp = _parseInt(payload['exp']);
    if (exp == null || exp <= 0) return false;
    return DateTime.now().toUtc().isAfter(DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true));
  } catch (_) {
    return false;
  }
}
