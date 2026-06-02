import "package:flutter_test/flutter_test.dart";
import "package:hiddify/core/preferences/preferences_migration.dart";
import "package:shared_preferences/shared_preferences.dart";

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

  test("fresh installations use round-robin balancer strategy", () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "round-robin");
    expect(prefs.getBool("bypass-lan"), true);
  });

  test("v11 replaces sticky sessions with round-robin", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 10,
      "balancer-strategy": "sticky-sessions",
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "round-robin");
  });

  test("v11 preserves an explicitly selected balancer strategy", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 10,
      "balancer-strategy": "consistent-hashing",
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("balancer-strategy"), "consistent-hashing");
  });

  test("v11 enables LAN bypass", () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 10, "bypass-lan": false});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getBool("bypass-lan"), true);
  });
}
