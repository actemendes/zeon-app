// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = Db(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  group('_columnExists-backed migrations', () {
    test('migration from v3 to v4 adds test_url when missing', () async {
      final schema = await verifier.schemaAt(3);
      addTearDown(() => schema.rawDatabase.dispose());

      final oldDb = v3.DatabaseAtV3(schema.newConnection());
      final oldColumns = await oldDb
          .customSelect('PRAGMA table_info(profile_entries);')
          .get();

      expect(
        oldColumns.where((row) => row.data['name'] == 'test_url'),
        isEmpty,
      );
      await oldDb.close();

      final migratedDb = Db(schema.newConnection());
      await verifier.migrateAndValidate(migratedDb, 4);
      await migratedDb.close();

      final newDb = v4.DatabaseAtV4(schema.newConnection());
      final newColumns = await newDb
          .customSelect('PRAGMA table_info(profile_entries);')
          .get();
      expect(
        newColumns.where((row) => row.data['name'] == 'test_url'),
        hasLength(1),
      );
      await newDb.close();
    });

    test(
      'migration from v3 to v4 skips adding test_url when it already exists',
      () async {
        final schema = await verifier.schemaAt(3);
        addTearDown(() => schema.rawDatabase.dispose());

        schema.rawDatabase.execute(
          'ALTER TABLE profile_entries ADD COLUMN test_url TEXT NULL;',
        );

        final migratedDb = Db(schema.newConnection());
        await verifier.migrateAndValidate(migratedDb, 4);
        await migratedDb.close();

        final newDb = v4.DatabaseAtV4(schema.newConnection());
        final newColumns = await newDb
            .customSelect('PRAGMA table_info(profile_entries);')
            .get();
        expect(
          newColumns.where((row) => row.data['name'] == 'test_url'),
          hasLength(1),
        );
        await newDb.close();
      },
    );
  });
}
