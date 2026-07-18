import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/security/secure_storage_mutex.dart';

void main() {
  test('serializes operations from independent storage services', () async {
    var active = 0;
    var maxActive = 0;

    final operations = List.generate(12, (index) {
      return SecureStorageMutex.protect(() async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        return index;
      });
    });

    expect(await Future.wait(operations), List.generate(12, (index) => index));
    expect(maxActive, 1);
  });

  test('continues processing after an operation fails', () async {
    final failed = SecureStorageMutex.protect<void>(() async => throw StateError('expected'));
    final next = SecureStorageMutex.protect(() async => 'ok');

    await expectLater(failed, throwsStateError);
    expect(await next, 'ok');
  });
}
