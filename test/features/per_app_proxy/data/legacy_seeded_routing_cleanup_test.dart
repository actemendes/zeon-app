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
  test("DAO clears only userSelection and deletes only empty seeded rows", () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);
    final dataSource = AppProxyDao(db);
    await db
        .into(db.appProxyEntries)
        .insert(
          AppProxyEntriesCompanion.insert(
            mode: AppProxyMode.exclude,
            pkgName: "com.example.seeded-only",
            flags: Value(PkgFlag.userSelection.value),
          ),
        );
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
            pkgName: "com.example.explicit",
            flags: Value(PkgFlag.userSelection.value),
          ),
        );

    final updated = await dataSource.clearUserSelectionFromPkgs(
      pkgs: const ["com.example.seeded-only", "com.example.seeded-auto"],
      mode: AppProxyMode.exclude,
    );
    final remaining = await db.select(db.appProxyEntries).get();

    expect(updated, 2);
    expect(
      remaining.map((entry) => entry.pkgName),
      containsAll(<String>["com.example.seeded-auto", "com.example.explicit"]),
    );
    expect(remaining.map((entry) => entry.pkgName), isNot(contains("com.example.seeded-only")));
    expect(
      remaining.singleWhere((entry) => entry.pkgName == "com.example.seeded-auto").flags,
      PkgFlag.autoSelection.value,
    );
    expect(
      remaining.singleWhere((entry) => entry.pkgName == "com.example.explicit").flags,
      PkgFlag.userSelection.value,
    );
  });

  test("removes only seed-owned exclude rows and preserves every other rule", () async {
    SharedPreferences.setMockInitialValues({
      "per_app_proxy_include_list": ["com.example.include"],
      "per_app_proxy_exclude_list": ["com.example.exclude"],
      PreferencesMigration.v16RoutingCleanupPendingKey: true,
      PreferencesMigration.v16RoutingCleanupOwnedKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded", "com.example.seeded-auto"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(
      include: {"com.example.include"},
      exclude: {
        PreferencesMigration.v16RemovedRoutingPackage,
        "com.example.seeded",
        "com.example.seeded-auto",
        "com.example.exclude",
      },
      extraExcludeFlags: {"com.example.seeded-auto": PkgFlag.autoSelection.value},
    );

    final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.include, {"com.example.include"});
    expect(dataSource.exclude, {"com.example.seeded-auto", "com.example.exclude"});
    expect(result.shouldDisableExcludeMode, false);
    expect(prefs.getBool(PreferencesMigration.v16RoutingCleanupPendingKey), false);
    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), false);
    expect(prefs.containsKey(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), false);
  });

  test("allows exclude mode to turn off only when no preference or database rules remain", () async {
    SharedPreferences.setMockInitialValues({
      "per_app_proxy_include_list": <String>[],
      "per_app_proxy_exclude_list": <String>[],
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.seeded"});

    final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.include, isEmpty);
    expect(dataSource.exclude, isEmpty);
    expect(result.shouldDisableExcludeMode, true);
  });

  test("keeps exclude mode when a rule remains in either persistence layer", () async {
    for (final testCase in [
      (preferences: <String>["com.example.preference-only"], database: <String>{}),
      (preferences: <String>[], database: <String>{"com.example.database-only"}),
    ]) {
      SharedPreferences.setMockInitialValues({
        "per_app_proxy_include_list": testCase.preferences,
        "per_app_proxy_exclude_list": <String>[],
        PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
        PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
      });
      final prefs = await SharedPreferences.getInstance();
      final dataSource = _FakeAppProxyDataSource(include: testCase.database, exclude: {"com.example.seeded"});

      final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

      expect(result.shouldDisableExcludeMode, false);
    }
  });

  test("does not change state without the one-shot v17 marker", () async {
    SharedPreferences.setMockInitialValues({
      "per_app_proxy_include_list": <String>[],
      "per_app_proxy_exclude_list": <String>[],
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: false,
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.user"});

    final result = await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, {"com.example.user"});
    expect(result.shouldDisableExcludeMode, false);
  });

  test("does not remove a v16 package row without an ownership marker", () async {
    SharedPreferences.setMockInitialValues({
      PreferencesMigration.v16RoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: false,
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {PreferencesMigration.v16RemovedRoutingPackage});

    await LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run();

    expect(dataSource.exclude, {PreferencesMigration.v16RemovedRoutingPackage});
    expect(prefs.getBool(PreferencesMigration.v16RoutingCleanupPendingKey), false);
  });

  test("retains the one-shot marker when cleanup verification fails", () async {
    SharedPreferences.setMockInitialValues({
      "per_app_proxy_include_list": <String>[],
      "per_app_proxy_exclude_list": <String>[],
      PreferencesMigration.v17SeededRoutingCleanupPendingKey: true,
      PreferencesMigration.v17SeededRoutingCleanupPackagesKey: ["com.example.seeded"],
    });
    final prefs = await SharedPreferences.getInstance();
    final dataSource = _FakeAppProxyDataSource(exclude: {"com.example.seeded"}, failVerification: true);

    await expectLater(LegacySeededRoutingCleanup(preferences: prefs, dataSource: dataSource).run(), throwsStateError);

    expect(prefs.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey), true);
    expect(prefs.getStringList(PreferencesMigration.v17SeededRoutingCleanupPackagesKey), ["com.example.seeded"]);
  });
}

final class _FakeAppProxyDataSource extends Fake implements AppProxyDataSource {
  _FakeAppProxyDataSource({
    Set<String>? include,
    Set<String>? exclude,
    Map<String, int> extraExcludeFlags = const {},
    this.failVerification = false,
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
  final bool failVerification;

  Set<String> get include => _includeEntries.keys.toSet();
  Set<String> get exclude => _excludeEntries.keys.toSet();

  Map<String, int> _entries(AppProxyMode mode) => switch (mode) {
    AppProxyMode.include => _includeEntries,
    AppProxyMode.exclude => _excludeEntries,
  };

  @override
  Future<bool> hasAnyPkgs({required AppProxyMode mode}) async {
    if (failVerification) throw StateError("verification failed");
    return _entries(mode).isNotEmpty;
  }

  @override
  Future<int> clearUserSelectionFromPkgs({required Iterable<String> pkgs, required AppProxyMode mode}) async {
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
