import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DebugProfileBootstrapService with InfraLogger {
  DebugProfileBootstrapService({
    required Environment environment,
    required ProfileRepository profileRepository,
    required ProfileDataSource profileDataSource,
    required SharedPreferences preferences,
  }) : _environment = environment,
       _profileRepository = profileRepository,
       _profileDataSource = profileDataSource,
       _preferences = preferences;

  static const _defaultSeedName = "UI Debug Profile";
  static const _defaultSeedProfilesCount = 4;
  static const _maxSeedProfilesCount = 12;
  static const _variantDays = <int>[0, 3, 7, 14, 30, 60, 120];
  static const _enabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _seedUrl = String.fromEnvironment("debug_seed_profile_url");
  static const _seedName = String.fromEnvironment("debug_seed_profile_name", defaultValue: _defaultSeedName);
  static const _seedProfilesCount = int.fromEnvironment(
    "debug_seed_profiles_count",
    defaultValue: _defaultSeedProfilesCount,
  );
  static const _prefDone = "debug_seed_profile_bootstrap_done_v2";

  final Environment _environment;
  final ProfileRepository _profileRepository;
  final ProfileDataSource _profileDataSource;
  final SharedPreferences _preferences;

  Future<void> run() async {
    if (!_enabled || !kDebugMode || _environment != Environment.dev) {
      return;
    }

    final url = _seedUrl.trim();
    if (url.isEmpty || Uri.tryParse(url) == null) {
      loggy.warning("debug profile bootstrap skipped: invalid debug_seed_profile_url");
      return;
    }
    final seedName = _resolveSeedName();
    await _ensurePrimaryProfile(url, seedName);
    await _ensureDebugVariants(url, seedName);
  }

  String _resolveSeedName() {
    final parsedSeedName = parseProfileName(_seedName);
    return parsedSeedName.isEmpty ? _defaultSeedName : parsedSeedName;
  }

  Future<void> _ensurePrimaryProfile(String url, String seedName) async {
    final existing = await _findByExactUrl(url);
    if (existing != null) {
      await _profileDataSource.edit(
        existing.id,
        ProfileEntriesCompanion(active: const Value(true), name: Value(seedName)),
      );
      await _preferences.setBool(_prefDone, true);
      loggy.info("debug profile bootstrap: existing profile activated and renamed");
      return;
    }

    final alreadyDone = _preferences.getBool(_prefDone) ?? false;
    if (!alreadyDone) {
      try {
        final importResult = await _profileRepository.upsertRemote(url).run();
        if (importResult.isRight()) {
          final imported = await _findByExactUrl(url);
          if (imported != null) {
            await _profileDataSource.edit(
              imported.id,
              ProfileEntriesCompanion(active: const Value(true), name: Value(seedName)),
            );
          }
          await _preferences.setBool(_prefDone, true);
          loggy.info("debug profile bootstrap: imported from remote url and renamed");
          return;
        }
      } catch (e, st) {
        loggy.warning("debug profile bootstrap: remote import threw, using fallback", e, st);
      }
    }

    await _insertFallback(url, seedName, active: true, remainingDays: 3650);
    await _preferences.setBool(_prefDone, true);
    loggy.warning("debug profile bootstrap: remote import failed, fallback profile inserted");
  }

  Future<void> _ensureDebugVariants(String baseUrl, String seedName) async {
    final desiredCount = _seedProfilesCount.clamp(1, _maxSeedProfilesCount);
    if (desiredCount <= 1) {
      return;
    }

    final existingNames = <String>{};
    for (final profile in await _loadProfiles()) {
      existingNames.add(profile.name.trim());
    }

    for (var i = 2; i <= desiredCount; i++) {
      final variantName = "$seedName $i";
      if (existingNames.contains(variantName)) continue;
      await _insertFallback(
        _variantUrl(baseUrl, i),
        variantName,
        active: false,
        remainingDays: _variantDays[(i - 2) % _variantDays.length],
      );
      existingNames.add(variantName);
    }
  }

  String _variantUrl(String baseUrl, int index) {
    final uri = Uri.parse(baseUrl);
    final marker = "debug_profile_$index";
    final fragment = uri.fragment.isEmpty ? marker : "${uri.fragment}-$marker";
    return uri.replace(fragment: fragment).toString();
  }

  Future<List<ProfileEntry>> _loadProfiles() async {
    return await _profileDataSource.watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.descending).first;
  }

  Future<ProfileEntry?> _findByExactUrl(String url) async {
    final normalized = url.trim();
    for (final profile in await _loadProfiles()) {
      if ((profile.url ?? "").trim() == normalized) {
        return profile;
      }
    }
    return null;
  }

  Future<void> _insertFallback(
    String url,
    String fallbackName, {
    required bool active,
    required int remainingDays,
  }) async {
    final now = DateTime.now();
    final expire = remainingDays > 0 ? now.add(Duration(days: remainingDays)) : now.subtract(const Duration(days: 1));
    final fallbackProfile = ProfileEntity.remote(
      id: const Uuid().v4(),
      active: active,
      name: fallbackName,
      url: url,
      lastUpdate: now,
      options: const ProfileOptions(updateInterval: Duration(hours: 6)),
      subInfo: SubscriptionInfo(
        upload: 0,
        download: 0,
        total: 1024 * 1024 * 1024,
        expire: expire,
        webPageUrl: url,
        supportUrl: url,
      ),
      profileOverride: "{}",
      populatedHeaders: {"profile-title": fallbackName},
    );
    await _profileDataSource.insert(fallbackProfile.toInsertEntry());
  }
}
