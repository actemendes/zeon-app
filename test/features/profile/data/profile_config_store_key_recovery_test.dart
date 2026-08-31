import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workingDirectory;
  late Directory tempDirectory;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    workingDirectory = await Directory.systemTemp.createTemp('zeon-profile-key-working-');
    tempDirectory = await Directory.systemTemp.createTemp('zeon-profile-key-temp-');
  });

  tearDown(() async {
    await workingDirectory.delete(recursive: true);
    await tempDirectory.delete(recursive: true);
  });

  test('does not replace a missing key after encrypted storage was initialized', () async {
    final preferences = await SharedPreferences.getInstance();
    final resolver = ProfilePathResolver(workingDirectory, tempDirectory);
    final initial = ProfileConfigStore(pathResolver: resolver, preferences: preferences);
    await initial.init();
    await initial.write('profile', '{"outbounds":[]}');

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final afterKeyLoss = ProfileConfigStore(pathResolver: resolver, preferences: preferences);

    await expectLater(
      afterKeyLoss.init(),
      throwsA(
        isA<ProfileConfigStoreException>().having(
          (error) => error.message,
          'message',
          contains('refusing to replace the key'),
        ),
      ),
    );
  });

  test('encrypted artifact prevents first-run key regeneration without a marker', () async {
    final preferences = await SharedPreferences.getInstance();
    final resolver = ProfilePathResolver(workingDirectory, tempDirectory);
    await resolver.directory.create(recursive: true);
    await resolver.encryptedFile('existing').writeAsString('{}');

    final store = ProfileConfigStore(pathResolver: resolver, preferences: preferences);

    await expectLater(store.init(), throwsA(isA<ProfileConfigStoreException>()));
  });
}
