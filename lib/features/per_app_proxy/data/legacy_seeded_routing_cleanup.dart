import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_migration.dart';
import 'package:zeon/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';

final class LegacySeededRoutingCleanup {
  LegacySeededRoutingCleanup({required this.preferences, required this.dataSource});

  final SharedPreferences preferences;
  final AppProxyDataSource dataSource;

  static const _includeAppsKey = "per_app_proxy_include_list";
  static const _excludeAppsKey = "per_app_proxy_exclude_list";

  Future<LegacySeededRoutingCleanupResult> run() async {
    if (preferences.getBool(PreferencesMigration.v16RoutingCleanupPendingKey) ?? false) {
      if (preferences.getBool(PreferencesMigration.v16RoutingCleanupOwnedKey) ?? false) {
        await dataSource.clearUserSelectionFromPkgs(
          pkgs: const [PreferencesMigration.v16RemovedRoutingPackage],
          mode: AppProxyMode.exclude,
        );
      }
      await preferences.remove(PreferencesMigration.v16RoutingCleanupOwnedKey);
      await preferences.setBool(PreferencesMigration.v16RoutingCleanupPendingKey, false);
    }

    if (!(preferences.getBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey) ?? false)) {
      return const LegacySeededRoutingCleanupResult(shouldDisableExcludeMode: false);
    }

    final cleanupPackages =
        preferences
            .getStringList(PreferencesMigration.v17SeededRoutingCleanupPackagesKey)
            ?.where((pkg) => pkg.isNotEmpty)
            .toSet() ??
        const <String>{};

    await dataSource.clearUserSelectionFromPkgs(pkgs: cleanupPackages, mode: AppProxyMode.exclude);

    final hasPreferenceRules =
        (preferences.getStringList(_includeAppsKey)?.isNotEmpty ?? false) ||
        (preferences.getStringList(_excludeAppsKey)?.isNotEmpty ?? false);
    final hasDatabaseRules =
        await dataSource.hasAnyPkgs(mode: AppProxyMode.include) ||
        await dataSource.hasAnyPkgs(mode: AppProxyMode.exclude);

    // Clear the retry state only after both deletion and verification succeed.
    await preferences.remove(PreferencesMigration.v17SeededRoutingCleanupPackagesKey);
    await preferences.setBool(PreferencesMigration.v17SeededRoutingCleanupPendingKey, false);

    return LegacySeededRoutingCleanupResult(
      shouldDisableExcludeMode: cleanupPackages.isNotEmpty && !hasPreferenceRules && !hasDatabaseRules,
    );
  }
}

final class LegacySeededRoutingCleanupResult {
  const LegacySeededRoutingCleanupResult({required this.shouldDisableExcludeMode});

  final bool shouldDisableExcludeMode;
}
