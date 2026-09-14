// Shared test-only probes for the dedicated Android and Windows runtime builds.
// Never import this file from a production entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/db/provider/db_providers.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/diagnostics/data/error_report_queue.dart';
import 'package:zeon/features/diagnostics/data/error_report_redactor.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/utils/link_parsers.dart';

class RuntimeP03R17Validation {
  RuntimeP03R17Validation(this.container);

  static const _secureKeyName = 'profile_config_encryption_key_v1';
  static const _dummyConfig = '{"runtime":"p03-key-loss-probe"}';

  final ProviderContainer container;
  final Sha256 _sha256 = Sha256();

  Future<Map<String, Object?>> runDataAndErrorChecks() async {
    final database = await _checkDatabaseContentionAndIntegrity();
    final uri = _checkUriDecoding();
    final errors = await _checkErrorQueueAndRedaction();
    return {'database': database, 'uri': uri, 'errors': errors};
  }

  Future<Map<String, Object?>> refreshActiveRemoteProfile() async {
    final profile = await container.read(activeProfileProvider.future);
    if (profile is! RemoteProfileEntity) {
      throw StateError('R17 requires an isolated remote profile fixture');
    }
    final repository = await container.read(profileRepositoryProvider.future);
    final beforeConfig = await repository
        .getRawConfig(profile.id)
        .run()
        .then(
          (result) => result.match(
            (failure) => throw StateError('R17 could not read the cached config: ${failure.runtimeType}'),
            (content) => content,
          ),
        );
    final beforeHash = await _digest(beforeConfig);
    final started = DateTime.now().toUtc();

    await container
        .read(updateProfileNotifierProvider(profile.id).notifier)
        .updateProfile(profile)
        .timeout(const Duration(minutes: 3));
    final updateState = container.read(updateProfileNotifierProvider(profile.id));
    if (updateState.hasError) {
      throw StateError('R17 profile update failed: ${updateState.error.runtimeType}');
    }

    final refreshed = await repository
        .getById(profile.id)
        .run()
        .then(
          (result) => result.match(
            (failure) => throw StateError('R17 could not read refreshed metadata: ${failure.runtimeType}'),
            (value) => value,
          ),
        );
    if (refreshed is! RemoteProfileEntity) {
      throw StateError('R17 refresh replaced the remote profile type');
    }
    if (refreshed.lastUpdate.toUtc().isBefore(started.subtract(const Duration(seconds: 2)))) {
      throw StateError('R17 refresh did not advance profile metadata');
    }
    final afterConfig = await repository
        .getRawConfig(profile.id)
        .run()
        .then(
          (result) => result.match(
            (failure) => throw StateError('R17 could not read refreshed config: ${failure.runtimeType}'),
            (content) => content,
          ),
        );
    if (afterConfig.trim().isEmpty) throw StateError('R17 refresh produced an empty cached config');

    final source = Uri.tryParse(refreshed.url);
    if (source == null || source.scheme != 'https' || source.host.isEmpty) {
      throw StateError('R17 persisted a non-HTTPS profile source');
    }
    return {
      'source_host': source.host.toLowerCase(),
      'last_update_advanced': true,
      'cached_config_present': true,
      'cached_config_changed': beforeHash != await _digest(afterConfig),
    };
  }

  Future<Map<String, Object?>> runKeyLossCheckAndRestore() async {
    final active = await container.read(activeProfileProvider.future);
    if (active == null) throw StateError('P03 key-loss probe requires an active isolated profile');
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      ),
    );
    final originalKey = await secureStorage.read(key: _secureKeyName);
    if (originalKey == null || originalKey.trim().isEmpty) {
      throw StateError('P03 secure profile key was unavailable before the key-loss probe');
    }

    final directories = await container.read(appDirectoriesProvider.future);
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    final working = Directory(p.join(directories.tempDir.path, 'zeon-p03-keyloss-$token'));
    final temporary = Directory(p.join(directories.tempDir.path, 'zeon-p03-keyloss-temp-$token'));
    final resolver = ProfilePathResolver(working, temporary);
    final preferences = container.read(sharedPreferencesProvider).requireValue;
    final store = ProfileConfigStore(pathResolver: resolver, preferences: preferences, secureStorage: secureStorage);
    var refusedReplacement = false;
    String? beforeHash;
    String? afterHash;
    try {
      await store.init();
      await store.write('probe', _dummyConfig);
      final encrypted = resolver.encryptedFile('probe');
      beforeHash = await _digestBytes(await encrypted.readAsBytes());

      await secureStorage.delete(key: _secureKeyName);
      final afterLoss = ProfileConfigStore(
        pathResolver: resolver,
        preferences: preferences,
        secureStorage: secureStorage,
      );
      try {
        await afterLoss.init();
      } on ProfileConfigStoreException catch (error) {
        refusedReplacement = error.message.contains('refusing to replace the key');
      }
      if (!refusedReplacement) throw StateError('P03 key loss did not fail closed');
      if (await secureStorage.read(key: _secureKeyName) != null) {
        throw StateError('P03 key loss silently generated a replacement key');
      }
      afterHash = await _digestBytes(await encrypted.readAsBytes());
      if (beforeHash != afterHash) throw StateError('P03 encrypted artifact changed after key loss');
    } finally {
      await secureStorage.write(key: _secureKeyName, value: originalKey);
      if (await working.exists()) await working.delete(recursive: true);
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }

    final restored = await container.read(profileConfigStoreProvider).read(active.id);
    if (restored.trim().isEmpty) throw StateError('P03 original profile key was not restored');
    return {
      'replacement_refused': refusedReplacement,
      'encrypted_artifact_preserved': beforeHash == afterHash,
      'original_key_restored': true,
      'profile_read_after_restore': true,
    };
  }

  Future<Map<String, Object?>> _checkDatabaseContentionAndIntegrity() async {
    final primary = container.read(dbProvider);
    final databaseDirectory = await AppDirectories.getDatabaseDirectory();
    final databaseFile = File(p.join(databaseDirectory.path, 'db.sqlite'));
    if (!await databaseFile.exists()) throw StateError('P03 application database file is missing');
    final secondary = Db(NativeDatabase.createInBackground(databaseFile));
    const table = 'runtime_p03_probe';
    final releaseWriter = Completer<void>();
    final writerLocked = Completer<void>();
    Future<void>? firstWrite;
    try {
      await primary.customStatement('DROP TABLE IF EXISTS $table');
      await primary.customStatement('CREATE TABLE $table (value INTEGER NOT NULL)');
      await primary.customStatement('INSERT INTO $table VALUES (1)');
      await secondary.customSelect('SELECT value FROM $table').getSingle();

      firstWrite = primary.transaction(() async {
        await primary.customStatement('UPDATE $table SET value = 2');
        writerLocked.complete();
        await releaseWriter.future;
      });
      await writerLocked.future.timeout(const Duration(seconds: 10));
      final visible = await secondary.customSelect('SELECT value FROM $table').getSingle();
      if (visible.read<int>('value') != 1) throw StateError('P03 reader observed uncommitted data');

      var competingFinished = false;
      final competingWrite = secondary
          .customStatement('UPDATE $table SET value = value + 10')
          .whenComplete(() => competingFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (competingFinished) throw StateError('P03 competing writer did not wait for the transient lock');
      releaseWriter.complete();
      await firstWrite.timeout(const Duration(seconds: 10));
      await competingWrite.timeout(const Duration(seconds: 10));

      final committed = await primary.customSelect('SELECT value FROM $table').getSingle();
      final busyTimeout = await secondary.customSelect('PRAGMA busy_timeout').getSingle();
      final journalMode = await secondary.customSelect('PRAGMA journal_mode').getSingle();
      final integrity = await primary.customSelect('PRAGMA integrity_check').getSingle();
      if (committed.read<int>('value') != 12) throw StateError('P03 competing writes lost data');
      if (busyTimeout.data.values.single != 5000) throw StateError('P03 busy_timeout is not 5000 ms');
      if (journalMode.data.values.single.toString().toLowerCase() != 'wal') {
        throw StateError('P03 application database is not using WAL');
      }
      if (integrity.data.values.single.toString().toLowerCase() != 'ok') {
        throw StateError('P03 SQLite integrity_check failed');
      }
      return {
        'journal_mode': 'wal',
        'busy_timeout_ms': 5000,
        'reader_isolation': true,
        'competing_write_waited': true,
        'committed_value': 12,
        'integrity_check': 'ok',
      };
    } finally {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
      if (firstWrite != null) await firstWrite.catchError((_) {});
      try {
        await primary.customStatement('DROP TABLE IF EXISTS $table');
      } catch (_) {}
      await secondary.close();
    }
  }

  Map<String, Object?> _checkUriDecoding() {
    final segments = normalizedUriPathSegments(Uri.parse('https://example.invalid/open/value%2525tail'));
    final malformed = Uri.tryParse('https://example.invalid/open/value%tail');
    final malformedSegments = malformed == null ? const <String>[] : normalizedUriPathSegments(malformed);
    if (segments.length != 2 || segments.last != 'value%25tail') {
      throw StateError('P03 URI path was decoded more than once');
    }
    if (malformedSegments.length != 2 || malformedSegments.last != 'value%tail') {
      throw StateError('P03 malformed percent input was not preserved safely');
    }
    return {'decoded_once': true, 'malformed_percent_preserved': true};
  }

  Future<Map<String, Object?>> _checkErrorQueueAndRedaction() async {
    final preferences = container.read(sharedPreferencesProvider).requireValue;
    final queue = ErrorReportQueue(preferences: preferences);
    final eventId = 'runtime-p03-${DateTime.now().microsecondsSinceEpoch}';
    await Future.wait(List.generate(8, (_) => queue.enqueue({'event_id': eventId, 'trigger': 'runtime-p03'})));
    final matches = queue
        .dueReports(DateTime.now().toUtc().add(const Duration(days: 1)))
        .where((report) => report.eventId == eventId)
        .length;
    await queue.remove(eventId);
    if (matches != 1) throw StateError('P03 concurrent error queue writes were not deduplicated');

    const redactor = ErrorReportRedactor();
    final redacted = redactor.redactMap({
      'token': 'runtime-p03-dummy-secret',
      'message': 'Authorization: Bearer runtime-p03-dummy-secret',
      'app': {'version': '1.5.0'},
    });
    final encoded = jsonEncode(redacted);
    if (encoded.contains('runtime-p03-dummy-secret')) throw StateError('P03 error redaction leaked a credential');
    if (!encoded.contains('<redacted>')) throw StateError('P03 error redaction marker is missing');
    return {'concurrent_queue_deduplicated': true, 'dummy_credential_redacted': true};
  }

  Future<String> _digest(String value) => _digestBytes(utf8.encode(value));

  Future<String> _digestBytes(List<int> value) async {
    final digest = await _sha256.hash(value);
    return digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
