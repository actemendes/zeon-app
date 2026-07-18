import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/security/secure_storage_mutex.dart';

/// Stores mobile credentials outside plaintext SharedPreferences.
///
/// Existing installations are migrated lazily. If platform secure storage is
/// temporarily unavailable, legacy values remain readable so an update does
/// not sign the user out, but newly issued secrets are never written back to
/// plaintext preferences.
class MobileSensitiveStorage {
  MobileSensitiveStorage({required SharedPreferences preferences, FlutterSecureStorage? secureStorage})
    : _preferences = preferences,
      _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              encryptedSharedPreferences: true,
              resetOnError: true,
              storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
              sharedPreferencesName: 'zeon_mobile_sensitive',
              preferencesKeyPrefix: 'zeon_',
            ),
          );

  static const legacyDeviceJwtKey = 'mobile_bind_jwt';
  static const legacyConnectionLinkKey = 'mobile_auto_import_conn_link';
  static const legacyManualRebindConnectionLinkKey = 'mobile_manual_rebind_conn_link';

  static const _deviceJwtKey = 'device_jwt_v1';
  static const _connectionLinkKey = 'connection_link_v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final Map<String, String> _memory = <String, String>{};

  Future<String> readDeviceJwt() => _read(_deviceJwtKey, legacyDeviceJwtKey);

  Future<void> writeDeviceJwt(String value) => _write(_deviceJwtKey, legacyDeviceJwtKey, value);

  Future<void> deleteDeviceJwt() => _delete(_deviceJwtKey, legacyDeviceJwtKey);

  Future<String> readConnectionLink() => _read(_connectionLinkKey, legacyConnectionLinkKey);

  Future<void> writeConnectionLink(String value) async {
    await _write(_connectionLinkKey, legacyConnectionLinkKey, value);
    await _preferences.remove(legacyManualRebindConnectionLinkKey);
  }

  Future<void> deleteConnectionLink() async {
    await _delete(_connectionLinkKey, legacyConnectionLinkKey);
    await _preferences.remove(legacyManualRebindConnectionLinkKey);
  }

  Future<String> _read(String secureKey, String legacyKey) async {
    final inMemory = _memory[secureKey]?.trim() ?? '';
    if (inMemory.isNotEmpty) return inMemory;

    try {
      final secureValue = (await SecureStorageMutex.protect(() => _secureStorage.read(key: secureKey)))?.trim() ?? '';
      if (secureValue.isNotEmpty) {
        _memory[secureKey] = secureValue;
        await _preferences.remove(legacyKey);
        return secureValue;
      }
    } catch (_) {
      // A legacy value may still be available during an in-place migration.
    }

    final legacyValue = (_preferences.getString(legacyKey) ?? '').trim();
    if (legacyValue.isEmpty) return '';

    _memory[secureKey] = legacyValue;
    await _tryPersistSecurely(secureKey, legacyKey, legacyValue);
    return legacyValue;
  }

  Future<void> _write(String secureKey, String legacyKey, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      await _delete(secureKey, legacyKey);
      return;
    }

    // Keep the current session working even if a device keystore is
    // temporarily unavailable. No plaintext fallback is created.
    _memory[secureKey] = normalized;
    await _tryPersistSecurely(secureKey, legacyKey, normalized);
  }

  Future<void> _tryPersistSecurely(String secureKey, String legacyKey, String value) async {
    try {
      final verified = await SecureStorageMutex.protect(() async {
        await _secureStorage.write(key: secureKey, value: value);
        return _secureStorage.read(key: secureKey);
      });
      if (verified == value) {
        await _preferences.remove(legacyKey);
      }
    } catch (_) {
      // Do not downgrade new credentials to plaintext storage.
    }
  }

  Future<void> _delete(String secureKey, String legacyKey) async {
    _memory.remove(secureKey);
    await _preferences.remove(legacyKey);
    try {
      await SecureStorageMutex.protect(() => _secureStorage.delete(key: secureKey));
    } catch (_) {
      // The server-side credential refresh/revocation path remains authoritative.
    }
  }
}
