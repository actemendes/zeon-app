import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/mobile/data/mobile_sensitive_storage.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('migrates a legacy JWT out of plaintext preferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MobileSensitiveStorage.legacyDeviceJwtKey: 'header.payload.signature',
    });
    final preferences = await SharedPreferences.getInstance();
    final storage = MobileSensitiveStorage(preferences: preferences);

    expect(await storage.readDeviceJwt(), 'header.payload.signature');
    expect(preferences.getString(MobileSensitiveStorage.legacyDeviceJwtKey), isNull);

    final afterRestart = MobileSensitiveStorage(preferences: preferences);
    expect(await afterRestart.readDeviceJwt(), 'header.payload.signature');
  });

  test('stores a connection link without leaving a plaintext copy', () async {
    final preferences = await SharedPreferences.getInstance();
    final storage = MobileSensitiveStorage(preferences: preferences);

    await storage.writeConnectionLink('https://example.com/open/private-value');

    expect(preferences.getString(MobileSensitiveStorage.legacyConnectionLinkKey), isNull);
    expect(await storage.readConnectionLink(), 'https://example.com/open/private-value');
  });

  test('deletes secure and legacy JWT copies together', () async {
    final preferences = await SharedPreferences.getInstance();
    final storage = MobileSensitiveStorage(preferences: preferences);
    await storage.writeDeviceJwt('header.payload.signature');

    await storage.deleteDeviceJwt();

    expect(await storage.readDeviceJwt(), isEmpty);
    expect(preferences.getString(MobileSensitiveStorage.legacyDeviceJwtKey), isNull);
  });
}
