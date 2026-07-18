import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/security/secure_storage_mutex.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/utils/custom_loggers.dart';

class ProfileConfigStoreException implements Exception {
  ProfileConfigStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class ProfileConfigStore with InfraLogger {
  ProfileConfigStore({
    required ProfilePathResolver pathResolver,
    required SharedPreferences preferences,
    FlutterSecureStorage? secureStorage,
  }) : _pathResolver = pathResolver,
       _preferences = preferences,
       _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(
               encryptedSharedPreferences: true,
               storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
             ),
           );

  static const formatVersion = 1;
  static const algorithmName = 'AES-256-GCM';
  static const metadataPrefix = 'enc:v1:';
  static const _secureKeyName = 'profile_config_encryption_key_v1';
  static const _fallbackKeyName = 'profile_config_encryption_key_v1_insecure_fallback';
  static const _fallbackMarkerName = 'profile_config_encryption_key_uses_insecure_fallback';
  static const _nonceLength = 12;
  static const _keyLength = 32;

  final ProfilePathResolver _pathResolver;
  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final AesGcm _cipher = AesGcm.with256bits();
  List<int>? _cachedKeyBytes;

  bool get _allowInsecureFallback => kDebugMode;

  Future<void> init() async {
    await _pathResolver.directory.create(recursive: true);
    await _pathResolver.tempDirectory.create(recursive: true);
    await _pathResolver.runtimeDirectory.create(recursive: true);
    await cleanupStaleTempFiles();
    await _getOrCreateKeyBytes();
    await migrateLegacyPlaintextConfigs();
  }

  Future<void> migrateLegacyPlaintextConfigs() async {
    if (!await _pathResolver.directory.exists()) return;

    await for (final entity in _pathResolver.directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.json') continue;
      if (p.basename(entity.path).endsWith('.tmp.json')) continue;

      final profileId = p.basenameWithoutExtension(entity.path);
      final encrypted = _pathResolver.encryptedFile(profileId);
      try {
        if (await encrypted.exists()) {
          await read(profileId);
          await entity.delete();
          continue;
        }

        final plaintext = await entity.readAsString();
        await write(profileId, plaintext);
        final verified = await read(profileId);
        if (verified != plaintext) {
          throw ProfileConfigStoreException('encrypted profile verification failed');
        }
        await entity.delete();
      } catch (error, stackTrace) {
        loggy.warning(
          'failed to migrate plaintext profile config ${_safeFileName(entity.path)}; leaving original file in place',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<void> cleanupStaleTempFiles() async {
    for (final dir in [_pathResolver.directory, _pathResolver.tempDirectory]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !p.basename(entity.path).endsWith('.tmp.json')) continue;
        try {
          await entity.delete();
        } catch (error, stackTrace) {
          loggy.warning(
            'failed to delete stale temporary profile config ${_safeFileName(entity.path)}',
            error,
            stackTrace,
          );
        }
      }
    }
  }

  Future<void> write(String profileId, String plaintext) async {
    final keyBytes = await _getOrCreateKeyBytes();
    final nonce = _randomBytes(_nonceLength);
    final secretBox = await _cipher.encrypt(utf8.encode(plaintext), secretKey: SecretKey(keyBytes), nonce: nonce);
    final payload = <String, Object?>{
      'version': formatVersion,
      'algorithm': algorithmName,
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'tag': base64Encode(secretBox.mac.bytes),
    };
    final file = _pathResolver.encryptedFile(profileId);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  Future<String> read(String profileId) async {
    final encrypted = _pathResolver.encryptedFile(profileId);
    if (await encrypted.exists()) {
      return _decryptFile(encrypted);
    }

    final legacy = _pathResolver.legacyPlaintextFile(profileId);
    if (await legacy.exists()) {
      return legacy.readAsString();
    }

    throw ProfileConfigStoreException('profile config not found');
  }

  Future<void> delete(String profileId) async {
    for (final file in [
      _pathResolver.encryptedFile(profileId),
      _pathResolver.legacyPlaintextFile(profileId),
      _pathResolver.tempFile(profileId),
      _pathResolver.legacyTempFile(profileId),
      _pathResolver.runtimeConnectionFile(profileId),
    ]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (error, stackTrace) {
        loggy.warning('failed to delete profile config file ${_safeFileName(file.path)}', error, stackTrace);
      }
    }
  }

  Future<File> createPlaintextTempFile(String profileId, {String? content}) async {
    final plaintext = content ?? await read(profileId);
    final file = _pathResolver.tempFile(profileId);
    await file.parent.create(recursive: true);
    await file.writeAsString(plaintext, flush: true);
    await _restrictOwnerOnly(file);
    return file;
  }

  Future<File> createRuntimeConnectionFile(String profileId, {String? content}) async {
    final plaintext = content ?? await read(profileId);
    final file = _pathResolver.runtimeConnectionFile(profileId);
    await file.parent.create(recursive: true);
    await file.writeAsString(plaintext, flush: true);
    await _restrictOwnerOnly(file);
    return file;
  }

  Future<void> refreshRuntimeConnectionFileIfExists(String profileId, {String? content}) async {
    final file = _pathResolver.runtimeConnectionFile(profileId);
    if (!await file.exists()) return;
    await createRuntimeConnectionFile(profileId, content: content);
  }

  Future<void> deletePlaintextTempFile(String profileId) async {
    final file = _pathResolver.tempFile(profileId);
    try {
      if (await file.exists()) await file.delete();
    } catch (error, stackTrace) {
      loggy.warning(
        'failed to delete temporary plaintext profile config ${_safeFileName(file.path)}',
        error,
        stackTrace,
      );
    }
  }

  Future<String> protectMetadata(String plaintext) async {
    if (plaintext.startsWith(metadataPrefix)) return plaintext;

    final keyBytes = await _getOrCreateKeyBytes();
    final nonce = _randomBytes(_nonceLength);
    final secretBox = await _cipher.encrypt(utf8.encode(plaintext), secretKey: SecretKey(keyBytes), nonce: nonce);
    final payload = jsonEncode(<String, Object?>{
      'n': base64Encode(secretBox.nonce),
      'c': base64Encode(secretBox.cipherText),
      't': base64Encode(secretBox.mac.bytes),
    });
    return '$metadataPrefix${base64UrlEncode(utf8.encode(payload))}';
  }

  Future<String?> protectNullableMetadata(String? plaintext) async {
    if (plaintext == null) return null;
    return protectMetadata(plaintext);
  }

  Future<String> revealMetadata(String value) async {
    if (!value.startsWith(metadataPrefix)) return value;

    try {
      final encoded = value.substring(metadataPrefix.length);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (decoded is! Map<String, dynamic>) {
        throw ProfileConfigStoreException('encrypted metadata has invalid envelope');
      }
      final nonce = _decodeShortField(decoded, 'n');
      final cipherText = _decodeShortField(decoded, 'c');
      final tag = _decodeShortField(decoded, 't');
      final keyBytes = await _getExistingKeyBytes();
      final clearBytes = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(keyBytes),
      );
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError catch (error) {
      throw ProfileConfigStoreException('encrypted metadata integrity check failed', error);
    } on FormatException catch (error) {
      throw ProfileConfigStoreException('encrypted metadata envelope is corrupted', error);
    }
  }

  Future<String?> revealNullableMetadata(String? value) async {
    if (value == null) return null;
    return revealMetadata(value);
  }

  Future<String> _decryptFile(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw ProfileConfigStoreException('encrypted profile has invalid envelope');
      }
      if (decoded['version'] != formatVersion || decoded['algorithm'] != algorithmName) {
        throw ProfileConfigStoreException('unsupported encrypted profile format');
      }

      final nonce = _decodeField(decoded, 'nonce');
      final cipherText = _decodeField(decoded, 'ciphertext');
      final tag = _decodeField(decoded, 'tag');
      final keyBytes = await _getExistingKeyBytes();
      final clearBytes = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(keyBytes),
      );
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError catch (error) {
      throw ProfileConfigStoreException('encrypted profile integrity check failed', error);
    } on FormatException catch (error) {
      throw ProfileConfigStoreException('encrypted profile envelope is corrupted', error);
    } on ProfileConfigStoreException {
      rethrow;
    } catch (error) {
      throw ProfileConfigStoreException('failed to decrypt profile config', error);
    }
  }

  List<int> _decodeField(Map<String, dynamic> decoded, String field) {
    final value = decoded[field];
    if (value is! String || value.isEmpty) {
      throw ProfileConfigStoreException('encrypted profile missing $field');
    }
    return base64Decode(value);
  }

  List<int> _decodeShortField(Map<String, dynamic> decoded, String field) {
    final value = decoded[field];
    if (value is! String || value.isEmpty) {
      throw ProfileConfigStoreException('encrypted metadata missing $field');
    }
    return base64Decode(value);
  }

  Future<List<int>> _getOrCreateKeyBytes() async {
    final cached = _cachedKeyBytes;
    if (cached != null) return cached;

    final secure = await _tryReadSecureKey();
    if (secure != null) return _cacheKey(secure);

    if (_allowInsecureFallback) {
      final fallback = _readFallbackKey();
      if (fallback != null) return _cacheKey(fallback);
    } else if (_hasFallbackKey()) {
      throw ProfileConfigStoreException(
        'secure profile key storage is unavailable; refusing insecure SharedPreferences fallback',
      );
    }

    final generated = _randomBytes(_keyLength);
    if (await _tryWriteSecureKey(generated)) return _cacheKey(generated);

    if (!_allowInsecureFallback) {
      throw ProfileConfigStoreException('secure profile key storage is unavailable; profile config was not saved');
    }

    await _writeFallbackKey(generated);
    return _cacheKey(generated);
  }

  Future<List<int>> _getExistingKeyBytes() async {
    final cached = _cachedKeyBytes;
    if (cached != null) return cached;

    final secure = await _tryReadSecureKey();
    if (secure != null) return _cacheKey(secure);

    if (_allowInsecureFallback) {
      final fallback = _readFallbackKey();
      if (fallback != null) return _cacheKey(fallback);
    }

    throw ProfileConfigStoreException('secure profile key storage is unavailable; profile config was not decrypted');
  }

  Future<List<int>?> _tryReadSecureKey() async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final encoded = (await SecureStorageMutex.protect(() => _secureStorage.read(key: _secureKeyName)))?.trim();
        if (encoded == null || encoded.isEmpty) return null;
        final key = base64Decode(encoded);
        if (key.length != _keyLength) {
          throw ProfileConfigStoreException('secure profile key has an invalid length');
        }
        return key;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
        }
      }
    }

    loggy.warning(
      _allowInsecureFallback
          ? 'secure profile key storage is unavailable; trying insecure debug fallback'
          : 'secure profile key storage is unavailable; insecure fallback is disabled',
      lastError,
      lastStackTrace,
    );
    if (!_allowInsecureFallback) {
      throw ProfileConfigStoreException('secure profile key storage is unavailable', lastError);
    }
    return null;
  }

  List<int> _cacheKey(List<int> key) {
    final cached = List<int>.unmodifiable(key);
    _cachedKeyBytes = cached;
    return cached;
  }

  Future<bool> _tryWriteSecureKey(List<int> keyBytes) async {
    try {
      final encoded = base64Encode(keyBytes);
      final verified = await SecureStorageMutex.protect(() async {
        await _secureStorage.write(key: _secureKeyName, value: encoded);
        return _secureStorage.read(key: _secureKeyName);
      });
      if (verified == encoded) {
        await _preferences.remove(_fallbackMarkerName);
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      loggy.warning(
        _allowInsecureFallback
            ? 'secure profile key storage write failed; using insecure debug fallback'
            : 'secure profile key storage write failed; insecure fallback is disabled',
        error,
        stackTrace,
      );
      return false;
    }
  }

  bool _hasFallbackKey() {
    final encoded = _preferences.getString(_fallbackKeyName);
    return encoded != null && encoded.isNotEmpty;
  }

  List<int>? _readFallbackKey() {
    final encoded = _preferences.getString(_fallbackKeyName);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final key = base64Decode(encoded);
      if (key.length != _keyLength) return null;
      loggy.warning('profile encryption key is loaded from insecure SharedPreferences fallback');
      return key;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeFallbackKey(List<int> keyBytes) async {
    await _preferences.setString(_fallbackKeyName, base64Encode(keyBytes));
    await _preferences.setBool(_fallbackMarkerName, true);
    loggy.warning('profile encryption key stored in insecure SharedPreferences fallback');
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256), growable: false);
  }

  Future<void> _restrictOwnerOnly(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {
      // Best effort only; temp file is still created outside the profile store.
    }
  }

  String _safeFileName(String path) => p.basename(path);
}
