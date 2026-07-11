import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:zeon/core/preferences/preferences_migration.dart";

void main() {
  test("migrates execute-config-as-is to enable-full-config without data loss", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 0, "execute-config-as-is": true});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getBool("enable-full-config"), true);
    expect(prefs.getBool("execute-config-as-is"), true);
  });

  test("v10 mirrors canonical full-config key back to legacy alias", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 9, "enable-full-config": true});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getBool("enable-full-config"), true);
    expect(prefs.getBool("execute-config-as-is"), true);
  });

  test("fresh installations use platform default balancer strategy", () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "smart-active-auto");
    expect(prefs.getBool("bypass-lan"), true);
  });

  test("existing installations migrate to smart-active-auto", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 11, "balancer-strategy": "round-robin"});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "smart-active-auto");
  });

  test("v12 replaces legacy explicitly selected balancer strategies", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 11,
      "balancer-strategy": "consistent-hashing",
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "smart-active-auto");
  });

  test("v11 enables LAN bypass", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 10, "bypass-lan": false});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getBool("bypass-lan"), true);
  });

  test("v15 does not change non-Android round-robin values", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 14, "balancer-strategy": "round-robin"});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "round-robin");
  });

  test("latest migration version is 16", () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getInt(PreferencesMigration.versionKey), 16);
  });
}
