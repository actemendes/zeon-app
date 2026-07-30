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

  test("v16 enables ad blocking without deleting ambiguous former seed selections", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 15,
      "block-ads": false,
      "per_app_proxy_exclude_list": ["com.example.other", PreferencesMigration.v16RemovedRoutingPackage],
      "per_app_proxy_seeded_exclude_list": [PreferencesMigration.v16RemovedRoutingPackage, "com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getBool("block-ads"), true);
    expect(prefs.getStringList("per_app_proxy_exclude_list"), [
      "com.example.other",
      PreferencesMigration.v16RemovedRoutingPackage,
    ]);
    expect(prefs.getStringList("per_app_proxy_seeded_exclude_list"), isEmpty);
    expect(prefs.getBool(PreferencesMigration.v16RoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v16RoutingCleanupOwnedKey), false);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), false);
  });

  test("v16 preserves an explicit Rutube rule without seed ownership evidence", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 15,
      "per_app_proxy_mode": "exclude",
      "per_app_proxy_exclude_list": [PreferencesMigration.v16RemovedRoutingPackage],
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getStringList("per_app_proxy_exclude_list"), [PreferencesMigration.v16RemovedRoutingPackage]);
    expect(prefs.containsKey(PreferencesMigration.v16RoutingCleanupOwnedKey), false);
    expect(prefs.getBool(PreferencesMigration.v16RoutingCleanupPendingKey), false);
  });

  test("v17 preserves ambiguous legacy seed rows and explicit user state", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 16,
      "per_app_proxy_mode": "exclude",
      "per_app_proxy_include_list": ["com.example.explicit.include"],
      "per_app_proxy_exclude_list": [
        "com.example.seeded.one",
        "com.example.explicit.exclude",
        "com.example.seeded.two",
      ],
      "per_app_proxy_seeded_exclude_list": ["com.example.seeded.one", "com.example.seeded.two"],
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("per_app_proxy_mode"), "exclude");
    expect(prefs.getStringList("per_app_proxy_include_list"), ["com.example.explicit.include"]);
    expect(prefs.getStringList("per_app_proxy_exclude_list"), [
      "com.example.seeded.one",
      "com.example.explicit.exclude",
      "com.example.seeded.two",
    ]);
    expect(prefs.getStringList("per_app_proxy_seeded_exclude_list"), isEmpty);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), false);
  });

  test("v17 keeps a cleanup request only for packages with separate exact ownership proof", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 16,
      "per_app_proxy_mode": "exclude",
      "per_app_proxy_exclude_list": ["com.example.proven", "com.example.ambiguous"],
      "per_app_proxy_seeded_exclude_list": ["com.example.proven", "com.example.ambiguous"],
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.ambiguous", "com.example.proven"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.proven"],
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getStringList("per_app_proxy_exclude_list"), ["com.example.proven", "com.example.ambiguous"]);
    expect(prefs.getStringList("per_app_proxy_seeded_exclude_list"), isEmpty);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), true);
    expect(prefs.getStringList(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), ["com.example.proven"]);
    expect(prefs.getStringList(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), ["com.example.proven"]);
  });

  test("v17 preserves all per-app state when no seed ownership marker exists", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.versionKey: 16,
      "per_app_proxy_mode": "exclude",
      "per_app_proxy_include_list": ["com.example.explicit.include"],
      "per_app_proxy_exclude_list": ["com.example.explicit.exclude"],
    });
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getString("per_app_proxy_mode"), "exclude");
    expect(prefs.getStringList("per_app_proxy_include_list"), ["com.example.explicit.include"]);
    expect(prefs.getStringList("per_app_proxy_exclude_list"), ["com.example.explicit.exclude"]);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
  });

  test("fresh install reaches v17 without creating RU package exclusions", () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await PreferencesMigration(sharedPreferences: prefs).migrate();

    expect(prefs.getInt(PreferencesMigration.versionKey), 17);
    expect(prefs.getBool("block-ads"), true);
    expect(prefs.containsKey("per_app_proxy_mode"), false);
    expect(prefs.getStringList("per_app_proxy_exclude_list"), isNull);
    expect(prefs.getStringList("per_app_proxy_seeded_exclude_list"), isEmpty);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), false);
  });
}
