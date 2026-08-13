import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:zeon/core/db/db.dart";
import "package:zeon/core/preferences/preferences_migration.dart";
import "package:zeon/features/per_app_proxy/data/app_proxy_data_source.dart";
import "package:zeon/features/per_app_proxy/data/legacy_seeded_routing_cleanup.dart";
import "package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart";
import "package:zeon/features/per_app_proxy/model/pkg_flag.dart";

void main() {
  test("unchanged exactly seed-owned row is removed", () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);
    final dataSource = AppProxyDao(db);
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.seeded",
            flags: Value(PkgFlag.userSelection.value),
          ),
        );

    SharedPreferences.setMockInitialValues({
      "per_app_proxy_mode": "exclude",
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();

    final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();
    final remaining = await db.select(db.appProxyEntries).get();

    expect(remaining, isEmpty);
    expect(result.shouldDisableExcludeMode, false);
    expect(prefs.getString("per_app_proxy_mode"), "exclude");
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
  });

  test("explicit user row is preserved while an exactly owned seed row is removed", () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);
    final dataSource = AppProxyDao(db);
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.seeded",
            flags: Value(PkgFlag.userSelection.value),
          ),
        );
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.explicit",
            flags: Value(PkgFlag.userSelection.value),
          ),
        );

    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();
    final remaining = await db.select(db.appProxyEntries).get();

    expect(remaining.single.pkgName, "com.example.explicit");
    expect(remaining.single.flags, PkgFlag.userSelection.value);
  });

  test("user re-selected former seed package is preserved", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.former-seed"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: <String>[],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.former-seed"});

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, {"com.example.former-seed"});
    expect(dataSource.excludeFlags["com.example.former-seed"], PkgFlag.userSelection.value);
  });

  test("automatic and forced bits survive removal of an exactly owned seed bit", () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);
    final dataSource = AppProxyDao(db);
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.seeded-auto",
            flags: Value(PkgFlag.userSelection.value | PkgFlag.autoSelection.value),
          ),
        );
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.seeded-forced",
            flags: Value(PkgFlag.userSelection.value | PkgFlag.forceDeselection.value),
          ),
        );
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded-auto", "com.example.seeded-forced"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: [
        "com.example.seeded-auto",
        "com.example.seeded-forced",
      ],
    });
    final prefs = await SharedPreferences.getInstance();

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();
    final remaining = await db.select(db.appProxyEntries).get();

    expect(
      remaining.singleWhere((entry) => entry.pkgName == "com.example.seeded-auto").flags,
      PkgFlag.autoSelection.value,
    );
    expect(
      remaining.singleWhere((entry) => entry.pkgName == "com.example.seeded-forced").flags,
      PkgFlag.forceDeselection.value,
    );
  });

  test("nonempty explicit user mode is preserved after exact row cleanup", () async {
    SharedPreferences.setMockInitialValues({
      "per_app_proxy_mode": "exclude",
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.seeded"});

    final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, isEmpty);
    expect(prefs.getString("per_app_proxy_mode"), "exclude");
    expect(result.shouldDisableExcludeMode, false);
  });

  test("unknown package origin favors preserving userSelection", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.unknown"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.unknown"});

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, {"com.example.unknown"});
    expect(dataSource.excludeFlags["com.example.unknown"], PkgFlag.userSelection.value);
  });

  test("v17 cleanup is idempotent when run repeatedly", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.seeded", "com.example.user"});
    final cleanup = LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource);

    await cleanup.run();
    final afterFirstRun = Map<String, int>.from(dataSource.excludeFlags);
    await cleanup.run();

    expect(dataSource.excludeFlags, afterFirstRun);
    expect(dataSource.exclude, {"com.example.user"});
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), false);
  });

  test("ambiguous v16 retry marker cannot remove a current user selection", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v16RoutingCleanupPendingKey: true,
      PreferencesMigration.v16RoutingCleanupOwnedKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: false,
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {PreferencesMigration.v16RemovedRoutingPackage});

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, {PreferencesMigration.v16RemovedRoutingPackage});
    expect(prefs.getBool(PreferencesMigration.v16RoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v16RoutingCleanupOwnedKey), false);
  });

  test("retains exact proof markers when database cleanup fails", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.seeded"}, failCleanup: true);

    await expectLater(LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run(), throwsStateError);

    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), true);
    expect(prefs.getStringList(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), ["com.example.seeded"]);
    expect(prefs.getStringList(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey), ["com.example.seeded"]);
  });
}

final class _FakeAppProxyDataSource extends Fake implements AppProxyDataSource {
  _FakeAppProxyDataSource({
    Set<String>? include,
    Set<String>? exclude,
    Map<String, int> extraExcludeFlags = const {},
    this.failCleanup = false,
  }) {
    for (final pkg in include ?? const <String>{}) {
      _includeEntries[pkg] = PkgFlag.userSelection.value;
    }
    for (final pkg in exclude ?? const <String>{}) {
      _excludeEntries[pkg] = PkgFlag.userSelection.value | (extraExcludeFlags[pkg] ?? 0);
    }
  }

  final Map<String, int> _includeEntries = {};
  final Map<String, int> _excludeEntries = {};
  final bool failCleanup;

  Set<String> get include => _includeEntries.keys.toSet();
  Set<String> get exclude => _excludeEntries.keys.toSet();
  Map<String, int> get excludeFlags => Map.unmodifiable(_excludeEntries);

  Map<String, int> _entries(AppProxyMode mode) => switch (mode) {
    AppProxyMode.include => _includeEntries,
    AppProxyMode.exclude => _excludeEntries,
  };

  @override
  Future<bool> hasAnyPkgs({required AppProxyMode mode}) async {
    return _entries(mode).isNotEmpty;
  }

  @override
  Future<int> clearUserSelectionFromPkgs({required Iterable<String> pkgs, required AppProxyMode mode}) async {
    if (failCleanup) throw StateError("cleanup failed");
    final entries = _entries(mode);
    var updated = 0;
    for (final pkg in pkgs) {
      final flags = entries[pkg];
      if (flags == null || !PkgFlag.userSelection.check(flags)) continue;
      updated++;
      final remainingFlags = PkgFlag.userSelection.remove(flags);
      if (remainingFlags == 0) {
        entries.remove(pkg);
      } else {
        entries[pkg] = remainingFlags;
      }
    }
    return updated;
  }
}
