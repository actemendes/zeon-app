import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
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

  static const _enabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _seedUrl = String.fromEnvironment("debug_seed_profile_url");
  static const _seedName = String.fromEnvironment("debug_seed_profile_name", defaultValue: "UI Debug Profile");
  static const _prefDone = "debug_seed_profile_bootstrap_done";

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

    final existing = await _profileDataSource.getByUrl(url);
    if (existing != null) {
      await _profileDataSource.edit(existing.id, const ProfileEntriesCompanion(active: Value(true)));
      await _preferences.setBool(_prefDone, true);
      loggy.info("debug profile bootstrap: existing profile activated");
      return;
    }

    final alreadyDone = _preferences.getBool(_prefDone) ?? false;
    if (!alreadyDone) {
      try {
        final importResult = await _profileRepository.upsertRemote(url).run();
        if (importResult.isRight()) {
          await _preferences.setBool(_prefDone, true);
          loggy.info("debug profile bootstrap: imported from remote url");
          return;
        }
      } catch (e, st) {
        loggy.warning("debug profile bootstrap: remote import threw, using fallback", e, st);
      }
    }

    await _insertFallback(url);
    await _preferences.setBool(_prefDone, true);
    loggy.warning("debug profile bootstrap: remote import failed, fallback profile inserted");
  }

  Future<void> _insertFallback(String url) async {
    final fallbackProfile = ProfileEntity.remote(
      id: const Uuid().v4(),
      active: true,
      name: _seedName,
      url: url,
      lastUpdate: DateTime.now(),
      options: const ProfileOptions(updateInterval: Duration(hours: 6)),
      subInfo: SubscriptionInfo(
        upload: 0,
        download: 0,
        total: 1024 * 1024 * 1024,
        expire: DateTime.now().add(const Duration(days: 3650)),
        webPageUrl: url,
        supportUrl: url,
      ),
      profileOverride: "{}",
      populatedHeaders: const {"profile-title": _seedName},
    );
    await _profileDataSource.insert(fallbackProfile.toInsertEntry());
  }
}
