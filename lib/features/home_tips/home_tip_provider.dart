import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/home_tips/home_tip.dart';
import 'package:zeon/features/home_tips/home_tip_controller.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';

final homeTipProvider = StateNotifierProvider<HomeTipController, HomeTipContent?>((ref) {
  final preferences = ref.watch(sharedPreferencesProvider).requireValue;
  final client = ref.watch(httpClientProvider);
  final origin = Uri.parse(MobileConnLinkImportService.apiBaseUrl);
  return HomeTipController(
    preferences: preferences,
    currentUser: () => preferences.getString(MobileConnLinkImportService.prefUserId) ?? '',
    fetchTip: () async {
      // Secure-storage instances cache tokens in memory. Recreate on every check
      // so a completed rebind cannot reuse another account's cached bearer.
      final auth = NotificationDeviceAuth(
        httpClient: client,
        preferences: preferences,
        directOnly: false,
        allowVpnRecovery: false,
      );
      final owner = preferences.getString(MobileConnLinkImportService.prefUserId) ?? '';
      for (var attempt = 0; attempt < 2; attempt++) {
        final token = await auth.resolveDeviceJwt(forceRefresh: attempt > 0).timeout(const Duration(seconds: 10));
        if (token.isEmpty) return null;
        if (!homeTipTokenMatchesUser(token, owner)) continue;
        final cancel = CancelToken();
        final timeout = Timer(const Duration(seconds: 10), () => cancel.cancel('tips deadline'));
        try {
          final response = await client.get<Map<String, dynamic>>(
            origin.resolve('/api/v1/tips/home').toString(),
            headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
            cancelToken: cancel,
            disableRetry: true,
            operation: 'home_tip',
            allowVpnRecovery: false,
          );
          return HomeTip.parse(response.data, origin);
        } on DioException catch (error) {
          if (error.response?.statusCode != 401 || attempt > 0) rethrow;
        } finally {
          timeout.cancel();
        }
      }
      return null;
    },
    fetchImage: (tip) async {
      final cancel = CancelToken();
      final timeout = Timer(const Duration(seconds: 10), () => cancel.cancel('tip image deadline'));
      try {
        final bytes = await client.getBytes(tip.imageUrl.toString(), cancelToken: cancel);
        if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Invalid tip image size');
        }
        final hash = await Sha256().hash(bytes);
        final digest = hash.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        if (digest != tip.imageSha256) {
          throw const FormatException('Invalid tip image');
        }
        // Decode before reserving any space on Home; broken media stays invisible.
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1040);
        codec.dispose();
        return bytes;
      } finally {
        timeout.cancel();
      }
    },
  );
});

// This is only a local identity fence; the server verifies the JWT signature.
bool homeTipTokenMatchesUser(String token, String userId) {
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))));
    return payload is Map && payload['user_id']?.toString() == userId;
  } catch (_) {
    return false;
  }
}
