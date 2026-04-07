import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class MobileBootstrapImportService with InfraLogger {
  MobileBootstrapImportService({
    required DioHttpClient httpClient,
    required ProfileRepository profileRepository,
    required SharedPreferences preferences,
  }) : _httpClient = httpClient,
       _profileRepository = profileRepository,
       _preferences = preferences;

  static const _apiBaseUrl = String.fromEnvironment("mobile_api_base_url", defaultValue: "https://zeon-vps.link");
  static const _apiKey = String.fromEnvironment("mobile_api_key", defaultValue: "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7");

  static const _prefDone = "mobile_auto_import_done";
  static const _prefDeviceId = "mobile_auto_import_device_id";
  static const _prefUserId = "mobile_auto_import_user_id";
  static const _prefConnLink = "mobile_auto_import_conn_link";

  final DioHttpClient _httpClient;
  final ProfileRepository _profileRepository;
  final SharedPreferences _preferences;

  Future<void> run() async {
    if (!PlatformUtils.isMobile) {
      return;
    }
    if (_preferences.getBool(_prefDone) ?? false) {
      return;
    }
    if (_apiBaseUrl.isEmpty || _apiKey.isEmpty) {
      loggy.warning("mobile auto import disabled: empty API base url or key");
      return;
    }

    final deviceId = await _ensureDeviceId();
    if (deviceId.isEmpty) {
      loggy.warning("mobile auto import aborted: empty device id");
      return;
    }

    final uri = Uri.parse(_apiBaseUrl).resolve("/api/mobile/users/create").toString();

    try {
      final response = await _httpClient.post<Map<String, dynamic>>(
        uri,
        data: {"device_id": deviceId},
        headers: {"X-API-Key": _apiKey, "Content-Type": "application/json"},
      );

      final statusCode = response.statusCode ?? 0;
      if (statusCode != 200 && statusCode != 201) {
        loggy.warning("mobile auto import failed: unexpected status [$statusCode]");
        return;
      }

      final body = response.data;
      if (body == null || body["ok"] != true) {
        loggy.warning("mobile auto import failed: invalid API body");
        return;
      }

      final data = body["data"];
      if (data is! Map<String, dynamic>) {
        loggy.warning("mobile auto import failed: missing [data] object");
        return;
      }

      final connLink = data["conn_link"]?.toString() ?? "";
      if (connLink.isEmpty || Uri.tryParse(connLink) == null) {
        loggy.warning("mobile auto import failed: invalid [conn_link]");
        return;
      }

      final addResult = await _profileRepository.upsertRemote(connLink).run();
      if (addResult.isLeft()) {
        loggy.warning("mobile auto import failed: could not import profile");
        return;
      }

      await _preferences.setBool(_prefDone, true);
      await _preferences.setString(_prefConnLink, connLink);
      await _preferences.setString(_prefUserId, data["user_id"]?.toString() ?? "");
      loggy.info("mobile auto import succeeded");
    } catch (e, st) {
      loggy.warning("mobile auto import failed with error", e, st);
    }
  }

  Future<String> _ensureDeviceId() async {
    final stored = _preferences.getString(_prefDeviceId);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    final platformPrefix = PlatformUtils.isAndroid
        ? "android"
        : PlatformUtils.isIOS
        ? "ios"
        : "mobile";
    final generated = "${platformPrefix}_${const Uuid().v4().replaceAll('-', '')}";
    await _preferences.setString(_prefDeviceId, generated);
    return generated;
  }
}
