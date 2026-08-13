import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_migration.dart';
import 'package:zeon/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';

final class LegacySeededRoutingCleanup {
  LegacySeededRoutingCleanup({required this.preferences, required this.dataSource});

  final SharedPreferences preferences;
  final AppProxyDataSource dataSource;

  Future<LegacySeededRoutingCleanupResult> run() async {
    if (preferences.getBool(PreferencesMigration.v16RoutingCleanupPendingKey) ?? false) {
      // v16's legacy boolean cannot prove that the current row was not
      // re-selected by the user. Retire the ambiguous retry state only.
      await preferences.remove(PreferencesMigration.v16RoutingCleanupOwnedKey);
      await preferences.setBool(PreferencesMigration.v16RoutingCleanupPendingKey, false);
    }

    if (!(preferences.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey) ?? false)) {
      return const LegacySeededRoutingCleanupResult(shouldDisableExcludeMode: false);
    }

    final requestedCleanup =
        preferences
            .getStringList(PreferencesMigration.v17SeededRoutingCleanupPackagesKey)
            ?.where((pkg) => pkg.isNotEmpty)
            .toSet() ??
        const <String>{};
    final exactOwnedPackages =
        preferences
            .getStringList(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey)
            ?.where((pkg) => pkg.isNotEmpty)
            .toSet() ??
        const <String>{};
    final cleanupPackages = requestedCleanup.intersection(exactOwnedPackages);

    await dataSource.clearUserSelectionFromPkgs(pkgs: cleanupPackages, mode: AppProxyMode.exclude);

    // Clear the retry state only after the database mutation succeeds.
    await preferences.remove(PreferencesMigration.v17SeededRoutingCleanupPackagesKey);
    await preferences.remove(PreferencesMigration.v17SeededRoutingExactOwnedPackagesKey);
    await preferences.setBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey, false);

    // The legacy format also cannot prove that exclude mode itself was seeded.
    // Preserve the user's explicit mode even when no package rows remain.
    return const LegacySeededRoutingCleanupResult(shouldDisableExcludeMode: false);
  }
}

final class LegacySeededRoutingCleanupResult {
  const LegacySeededRoutingCleanupResult({required this.shouldDisableExcludeMode});

  final bool shouldDisableExcludeMode;
}
