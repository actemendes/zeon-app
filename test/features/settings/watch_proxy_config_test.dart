import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/device/android_watch_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final watch in [true, false]) {
    test('watch=$watch preserves preferences and applies the correct transport', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final configured = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) => prefs),
          androidWatchProvider.overrideWith((_) => Future.value(watch)),
        ],
      );
      addTearDown(configured.dispose);
      await configured.read(sharedPreferencesProvider.future);
      await configured.read(androidWatchProvider.future);
      await configured.read(ConfigOptions.serviceMode.notifier).update(ServiceMode.tun);
      await configured.read(ConfigOptions.mixedPort.notifier).update(23456);
      await configured.read(ConfigOptions.allowConnectionFromLan.notifier).update(true);
      final options = configured.read(ConfigOptions.singboxConfigOptions);
      expect(options.enableTun, !watch);
      expect(options.setSystemProxy, false);
      expect(options.mixedPort, watch ? 12334 : 23456);
      expect(options.allowConnectionFromLan, !watch);
      expect(configured.read(ConfigOptions.serviceMode), ServiceMode.tun);
      expect(configured.read(ConfigOptions.mixedPort), 23456);
    });
  }
}
