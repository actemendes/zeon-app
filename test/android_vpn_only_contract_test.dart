import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:zeon/singbox/model/singbox_config_enum.dart";

void main() {
  test("Android exposes only VPN mode while Windows retains all modes", () {
    expect(ServiceMode.choicesForPlatform(isApple: false, isAndroid: true, isWindows: false, isLinux: false), [
      ServiceMode.tun,
    ]);
    expect(
      ServiceMode.choicesForPlatform(isApple: false, isAndroid: false, isWindows: true, isLinux: false),
      ServiceMode.values,
    );
  });

  test("Android manifest and native dispatcher expose no proxy service path", () async {
    final manifest = await File("android/app/src/main/AndroidManifest.xml").readAsString();
    final settings = await File("android/app/src/main/kotlin/com/zeon/zeon/Settings.kt").readAsString();

    expect(manifest, isNot(contains(".bg.ProxyService")));
    expect(settings, contains("fun serviceClass(): Class<*> = VPNService::class.java"));
    expect(settings, isNot(contains("ProxyService::class.java")));
  });
}
