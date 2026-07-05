import 'package:drift/drift.dart';
import 'package:fpdart/fpdart.dart';
import 'package:loggy/loggy.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/model/profile_sort_enum.dart';
import 'package:zeon/utils/utils.dart';

part 'profile_data_source.g.dart';

abstract interface class ProfileDataSource {
  Future<ProfileEntry?> getById(String id);
  Future<ProfileEntry?> getByUrl(String url);
  Future<ProfileEntry?> getByName(String name);
  Stream<ProfileEntry?> watchActiveProfile();
  Stream<int> watchProfilesCount();
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode});
  Future<void> migrateSensitiveFields();
  Future<void> insert(ProfileEntriesCompanion entry);
  Future<void> edit(String id, ProfileEntriesCompanion entry);
  Future<void> deleteById(String id, bool isActive);
}

Map<SortMode, OrderingMode> orderMap = {SortMode.ascending: OrderingMode.asc, SortMode.descending: OrderingMode.desc};

@DriftAccessor(tables: [ProfileEntries])
class ProfileDao extends DatabaseAccessor<Db> with _$ProfileDaoMixin, InfraLogger implements ProfileDataSource {
  ProfileDao(super.db);

  @override
  Future<ProfileEntry?> getById(String id) async {
    return await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getByUrl(String url) async {
    return await (select(profileEntries)
          ..where((tbl) => tbl.url.like('%$url%'))
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getByName(String name) async {
    return await (select(profileEntries)
          ..where((tbl) => tbl.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Stream<ProfileEntry?> watchActiveProfile() {
    return (profileEntries.select()
          ..where((tbl) => tbl.active.equals(true))
          ..limit(1))
        .watchSingleOrNull()
        .distinct();
  }

  @override
  Stream<int> watchProfilesCount() {
    final count = profileEntries.id.count();
    return (profileEntries.selectOnly()..addColumns([count])).map((exp) => exp.read(count)!).watchSingle().distinct();
  }

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) {
    return (profileEntries.select()..orderBy([
          (tbl) => OrderingTerm(expression: tbl.active, mode: OrderingMode.desc),
          (tbl) {
            final trafficRatio = (tbl.download + tbl.upload) / tbl.total;
            final isExpired = tbl.expire.isSmallerOrEqualValue(DateTime.now());
            return OrderingTerm(
              expression:
                  (trafficRatio.isNull() | trafficRatio.isSmallerThanValue(1)) &
                  (isExpired.isNull() | isExpired.equals(false)),
              mode: OrderingMode.desc,
            );
          },
          switch (sort) {
            ProfilesSort.name => (tbl) => OrderingTerm(expression: tbl.name, mode: orderMap[sortMode]!),
            ProfilesSort.lastUpdate => (tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: orderMap[sortMode]!),
          },
        ]))
        .watch();
  }

  @override
  Future<void> migrateSensitiveFields() async {}

  @override
  Future<void> insert(ProfileEntriesCompanion entry) async {
    await transaction(() async {
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      final name = StringBuffer(entry.name.value);
      while (await getByName(name.toString()) != null) {
        name.write('${randomInt(0, 9).run()}');
      }
      await into(profileEntries).insert(entry.copyWith(name: Value(name.toString())));
    });
  }

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async {
    await transaction(() async {
      final profile = await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (profile == null) {
        loggy.log(LogLevel.info, 'profile with id : [$id] deleted');
        return;
      }
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      await (update(profileEntries)..where((tbl) => tbl.id.equals(id))).write(entry);
    });
  }

  @override
  Future<void> deleteById(String id, bool isActive) async {
    await transaction(() async {
      await (delete(profileEntries)..where((tbl) => tbl.id.equals(id))).go();

      if (isActive) {
        final profiles = await (profileEntries.select()..where((tbl) => tbl.id.equals(id).not())).get();
        if (profiles.isEmpty) return;
        final prof = profiles.first;
        await (update(
          profileEntries,
        )..where((tbl) => tbl.id.equals(prof.id))).write(const ProfileEntriesCompanion(active: Value(true)));
      }
    });
  }
}

class ProtectedProfileDataSource implements ProfileDataSource {
  ProtectedProfileDataSource({
    required ProfileDataSource delegate,
    required ProfileConfigStore configStore,
    required bool enabled,
  }) : _delegate = delegate,
       _configStore = configStore,
       _enabled = enabled;

  final ProfileDataSource _delegate;
  final ProfileConfigStore _configStore;
  final bool _enabled;

  @override
  Future<ProfileEntry?> getById(String id) async {
    final entry = await _delegate.getById(id);
    return _revealEntry(entry);
  }

  @override
  Future<ProfileEntry?> getByUrl(String url) async {
    if (!_enabled) return _delegate.getByUrl(url);

    final entries = await _rawEntries();
    for (final entry in entries) {
      final revealed = await _revealEntry(entry);
      if (revealed?.url?.contains(url) == true) return revealed;
    }
    return null;
  }

  @override
  Future<ProfileEntry?> getByName(String name) async {
    if (!_enabled) return _delegate.getByName(name);

    final entries = await _rawEntries();
    for (final entry in entries) {
      final revealed = await _revealEntry(entry);
      if (revealed?.name == name) return revealed;
    }
    return null;
  }

  @override
  Stream<ProfileEntry?> watchActiveProfile() {
    return _delegate.watchActiveProfile().asyncMap(_revealEntry);
  }

  @override
  Stream<int> watchProfilesCount() => _delegate.watchProfilesCount();

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) {
    return _delegate.watchAll(sort: sort, sortMode: sortMode).asyncMap((entries) async {
      final revealed = await _revealEntries(entries);
      revealed.sort((a, b) => _compareProfiles(a, b, sort: sort, sortMode: sortMode));
      return revealed;
    });
  }

  @override
  Future<void> migrateSensitiveFields() async {
    if (!_enabled) return;

    final entries = await _rawEntries();
    for (final entry in entries) {
      if (!_needsProtection(entry)) continue;
      await _delegate.edit(entry.id, await _protectEntryForUpdate(entry));
    }
  }

  @override
  Future<void> insert(ProfileEntriesCompanion entry) async {
    if (!_enabled) {
      await _delegate.insert(entry);
      return;
    }

    var protectedEntry = entry;
    if (entry.name.present) {
      final name = StringBuffer(entry.name.value);
      while (await getByName(name.toString()) != null) {
        name.write('${randomInt(0, 9).run()}');
      }
      protectedEntry = protectedEntry.copyWith(name: Value(name.toString()));
    }
    await _delegate.insert(await _protectCompanion(protectedEntry));
  }

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async {
    if (!_enabled) {
      await _delegate.edit(id, entry);
      return;
    }
    await _delegate.edit(id, await _protectCompanion(entry));
  }

  @override
  Future<void> deleteById(String id, bool isActive) => _delegate.deleteById(id, isActive);

  Future<List<ProfileEntry>> _rawEntries() {
    return _delegate.watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending).first;
  }

  Future<List<ProfileEntry>> _revealEntries(List<ProfileEntry> entries) {
    return Future.wait(entries.map((entry) async => (await _revealEntry(entry))!));
  }

  Future<ProfileEntry?> _revealEntry(ProfileEntry? entry) async {
    if (!_enabled || entry == null) return entry;

    return entry.copyWith(
      name: await _configStore.revealMetadata(entry.name),
      url: Value(await _configStore.revealNullableMetadata(entry.url)),
      webPageUrl: Value(await _configStore.revealNullableMetadata(entry.webPageUrl)),
      supportUrl: Value(await _configStore.revealNullableMetadata(entry.supportUrl)),
      populatedHeaders: Value(await _configStore.revealNullableMetadata(entry.populatedHeaders)),
      profileOverride: Value(await _configStore.revealNullableMetadata(entry.profileOverride)),
      userOverride: Value(await _configStore.revealNullableMetadata(entry.userOverride)),
    );
  }

  Future<ProfileEntriesCompanion> _protectEntryForUpdate(ProfileEntry entry) {
    return _protectCompanion(
      ProfileEntriesCompanion(
        name: Value(entry.name),
        url: Value(entry.url),
        webPageUrl: Value(entry.webPageUrl),
        supportUrl: Value(entry.supportUrl),
        populatedHeaders: Value(entry.populatedHeaders),
        profileOverride: Value(entry.profileOverride),
        userOverride: Value(entry.userOverride),
      ),
    );
  }

  Future<ProfileEntriesCompanion> _protectCompanion(ProfileEntriesCompanion entry) async {
    if (!_enabled) return entry;

    return entry.copyWith(
      name: entry.name.present ? Value(await _configStore.protectMetadata(entry.name.value)) : const Value.absent(),
      url: entry.url.present
          ? Value(await _configStore.protectNullableMetadata(entry.url.value))
          : const Value.absent(),
      webPageUrl: entry.webPageUrl.present
          ? Value(await _configStore.protectNullableMetadata(entry.webPageUrl.value))
          : const Value.absent(),
      supportUrl: entry.supportUrl.present
          ? Value(await _configStore.protectNullableMetadata(entry.supportUrl.value))
          : const Value.absent(),
      populatedHeaders: entry.populatedHeaders.present
          ? Value(await _configStore.protectNullableMetadata(entry.populatedHeaders.value))
          : const Value.absent(),
      profileOverride: entry.profileOverride.present
          ? Value(await _configStore.protectNullableMetadata(entry.profileOverride.value))
          : const Value.absent(),
      userOverride: entry.userOverride.present
          ? Value(await _configStore.protectNullableMetadata(entry.userOverride.value))
          : const Value.absent(),
    );
  }

  bool _needsProtection(ProfileEntry entry) {
    if (!_enabled) return false;
    final values = [
      entry.name,
      entry.url,
      entry.webPageUrl,
      entry.supportUrl,
      entry.populatedHeaders,
      entry.profileOverride,
      entry.userOverride,
    ];
    return values.whereType<String>().any((value) => !value.startsWith(ProfileConfigStore.metadataPrefix));
  }

  int _compareProfiles(ProfileEntry a, ProfileEntry b, {required ProfilesSort sort, required SortMode sortMode}) {
    final activeCompare = _compareBoolDesc(a.active, b.active);
    if (activeCompare != 0) return activeCompare;

    final availabilityCompare = _compareBoolDesc(_isProfileAvailable(a), _isProfileAvailable(b));
    if (availabilityCompare != 0) return availabilityCompare;

    final direction = sortMode == SortMode.ascending ? 1 : -1;
    return direction *
        switch (sort) {
          ProfilesSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ProfilesSort.lastUpdate => a.lastUpdate.compareTo(b.lastUpdate),
        };
  }

  int _compareBoolDesc(bool a, bool b) {
    if (a == b) return 0;
    return a ? -1 : 1;
  }

  bool _isProfileAvailable(ProfileEntry entry) {
    final hasTraffic = entry.upload != null && entry.download != null && entry.total != null && entry.total != 0;
    final trafficAvailable = !hasTraffic || ((entry.upload! + entry.download!) / entry.total!) < 1;
    final timeAvailable = entry.expire == null || entry.expire!.isAfter(DateTime.now());
    return trafficAvailable && timeAvailable;
  }
}
