import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/stable_device_id_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final mobileDeviceRebindServiceProvider = Provider<MobileDeviceRebindService>((ref) {
  final preferences = ref.read(sharedPreferencesProvider).requireValue;
  return MobileDeviceRebindService(
    httpClient: ref.read(httpClientProvider),
    stableDeviceIdService: StableDeviceIdService(preferences: preferences),
    preferences: preferences,
  );
});

class MobileDeviceRebindService with InfraLogger {
  MobileDeviceRebindService({
    required DioHttpClient httpClient,
    required StableDeviceIdService stableDeviceIdService,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _stableDeviceIdService = stableDeviceIdService,
       _preferences = preferences;

  static const _apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const prefManualRebindDone = "mobile_manual_rebind_done";
  static const prefManualRebindUserId = "mobile_manual_rebind_user_id";
  static const prefManualRebindConnLink = "mobile_manual_rebind_conn_link";

  final DioHttpClient _httpClient;
  final StableDeviceIdService _stableDeviceIdService;
  final SharedPreferences _preferences;

  Future<bool> syncManualImportRebind(
    MobileConnLinkImportResult importResult, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ownerUserId = _resolveOwnerUserId(importResult);
    if (ownerUserId == null || ownerUserId <= 0) {
      loggy.info("manual rebind skipped: no numeric open_id/user_id");
      return false;
    }

    final connLink = importResult.connLink.trim();
    if (connLink.isEmpty || Uri.tryParse(connLink) == null) {
      loggy.warning("manual rebind skipped: invalid conn_link [conn_link=$connLink]");
      return false;
    }

    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) {
      loggy.warning("manual rebind skipped: mobile api is not configured");
      return false;
    }

    try {
      await _postRebind(ownerUserId: ownerUserId, connLink: connLink).timeout(timeout);

      await _preferences.setBool(prefManualRebindDone, true);
      await _preferences.setString(prefManualRebindUserId, ownerUserId.toString());
      await _preferences.setString(prefManualRebindConnLink, connLink);

      loggy.info(
        "manual rebind synced [owner_user_id=$ownerUserId, conn_link=${_maskLink(connLink)}, source=manual_import]",
      );
      return true;
    } on TimeoutException catch (e, st) {
      loggy.warning("manual rebind warning: timeout", e, st);
      return false;
    } on DioException catch (e, st) {
      loggy.warning("manual rebind warning: backend request failed ${_dioDebug(e)}", e, st);
      return false;
    } catch (e, st) {
      loggy.warning("manual rebind warning: unexpected error", e, st);
      return false;
    }
  }

  Future<void> _postRebind({required int ownerUserId, required String connLink}) async {
    final deviceId = await _stableDeviceIdService.getOrCreate();
    final uri = Uri.parse(_apiBaseUrl).resolve("/api/v1/devices/rebind").toString();
    final response = await _httpClient.post<Map<String, dynamic>>(
      uri,
      data: {
        "device_id": deviceId,
        "owner_user_id": ownerUserId,
        "conn_link": connLink,
        "source": "manual_import",
        "platform": _platformName(),
      },
      headers: {"x-api-key": _apiKey, "Content-Type": "application/json"},
      directOnly: true,
    );

    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw MobileDeviceRebindException("devices/rebind returned status $statusCode");
    }

    final body = response.data;
    if (body is Map<String, dynamic> && body["ok"] == false) {
      throw const MobileDeviceRebindException("devices/rebind returned error response");
    }
  }

  int? _resolveOwnerUserId(MobileConnLinkImportResult importResult) {
    final directUserId = importResult.userId;
    if (directUserId != null && directUserId > 0) {
      return directUserId;
    }

    final openId = importResult.openId?.trim() ?? "";
    if (openId.isEmpty) {
      return null;
    }
    final parsedOpenId = int.tryParse(openId);
    return parsedOpenId != null && parsedOpenId > 0 ? parsedOpenId : null;
  }

  String _platformName() {
    if (PlatformUtils.isAndroid) return "android";
    if (PlatformUtils.isIOS) return "ios";
    if (PlatformUtils.isWindows) return "windows";
    if (PlatformUtils.isMacOS) return "macos";
    if (PlatformUtils.isLinux) return "linux";
    return "unknown";
  }
}

class MobileDeviceRebindException implements Exception {
  const MobileDeviceRebindException(this.message);

  final String message;

  @override
  String toString() => message;
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

String _dioDebug(DioException e) {
  final status = e.response?.statusCode;
  return "[type=${e.type.name} status=${status ?? "-"}]";
}
