import 'dart:async';

/// Serializes secure-storage operations inside the application isolate.
///
/// The Windows implementation used by flutter_secure_storage 9.x stores all
/// values in one DPAPI-protected file and is not safe under concurrent access.
/// Keeping the lock above individual service instances prevents lost updates,
/// transient decryption failures, and destructive recovery races.
abstract final class SecureStorageMutex {
  static Future<void> _tail = Future<void>.value();

  static Future<T> protect<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
