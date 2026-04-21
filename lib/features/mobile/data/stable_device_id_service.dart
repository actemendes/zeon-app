import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class StableDeviceIdService {
  StableDeviceIdService({
    required SharedPreferences preferences,
    FlutterSecureStorage? secureStorage,
  }) : _preferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _prefKeyDeviceId = "mobile_auto_import_device_id";
  static const _secureKeyDeviceId = "stable_device_id_v1";
  static const _platformChannel = MethodChannel("com.hiddify.app/platform");

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;

  Future<String> getOrCreate() async {
    final stored = _preferences.getString(_prefKeyDeviceId);
    if (stored != null && stored.isNotEmpty) return stored;

    final nativeStable = await _readNativeStableId();
    if (nativeStable != null && nativeStable.isNotEmpty) {
      await _preferences.setString(_prefKeyDeviceId, nativeStable);
      await _tryWriteSecure(nativeStable);
      return nativeStable;
    }

    final secureStored = await _tryReadSecure();
    if (secureStored != null && secureStored.isNotEmpty) {
      await _preferences.setString(_prefKeyDeviceId, secureStored);
      return secureStored;
    }

    final generated = "${_platformPrefix()}_${const Uuid().v4().replaceAll('-', '')}";
    await _preferences.setString(_prefKeyDeviceId, generated);
    await _tryWriteSecure(generated);
    return generated;
  }

  Future<String> rotateForRebind() async {
    final generated = "${_platformPrefix()}_${const Uuid().v4().replaceAll('-', '')}";
    await _preferences.setString(_prefKeyDeviceId, generated);
    await _tryWriteSecure(generated);
    return generated;
  }

  Future<String?> _readNativeStableId() async {
    if (PlatformUtils.isWeb) return null;
    try {
      final raw = (await _platformChannel.invokeMethod<String>("get_stable_device_id"))?.trim() ?? "";
      if (raw.isEmpty) return null;
      final normalized = raw.replaceAll(RegExp('[^A-Za-z0-9]'), '').toLowerCase();
      if (normalized.isEmpty) return null;
      final short = normalized.length > 32 ? normalized.substring(0, 32) : normalized;
      return "${_platformPrefix()}_$short";
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryReadSecure() async {
    try {
      final value = (await _secureStorage.read(key: _secureKeyDeviceId))?.trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _tryWriteSecure(String value) async {
    try {
      await _secureStorage.write(key: _secureKeyDeviceId, value: value);
    } catch (_) {
      // Ignore secure storage failures and keep shared preferences fallback.
    }
  }

  String _platformPrefix() {
    if (PlatformUtils.isAndroid) return "android";
    if (PlatformUtils.isIOS) return "ios";
    if (PlatformUtils.isWindows) return "windows";
    if (PlatformUtils.isMacOS) return "macos";
    if (PlatformUtils.isLinux) return "linux";
    return "device";
  }
}
