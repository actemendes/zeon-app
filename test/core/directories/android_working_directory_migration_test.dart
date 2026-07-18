import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zeon/core/directories/android_working_directory_migration.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('zeon-working-dir-test-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('moves all legacy working data into private storage', () async {
    final source = Directory(p.join(sandbox.path, 'external'));
    final destination = Directory(p.join(sandbox.path, 'internal'));
    await File(p.join(source.path, 'configs', 'profile.zcfg')).create(recursive: true);
    await File(p.join(source.path, 'configs', 'profile.zcfg')).writeAsString('encrypted-profile');
    await File(p.join(source.path, 'runtime-configs', 'active.json')).create(recursive: true);
    await File(p.join(source.path, 'runtime-configs', 'active.json')).writeAsString('runtime-secret');

    final migrated = await AndroidWorkingDirectoryMigration.migrate(source: source, destination: destination);

    expect(migrated, isTrue);
    expect(await source.exists(), isFalse);
    expect(await File(p.join(destination.path, 'configs', 'profile.zcfg')).readAsString(), 'encrypted-profile');
    expect(await File(p.join(destination.path, 'runtime-configs', 'active.json')).readAsString(), 'runtime-secret');
  });

  test('replaces a partial destination left by an interrupted migration', () async {
    final source = Directory(p.join(sandbox.path, 'external'));
    final destination = Directory(p.join(sandbox.path, 'internal'));
    final sourceFile = File(p.join(source.path, 'data', 'core.db'));
    final destinationFile = File(p.join(destination.path, 'data', 'core.db'));
    await sourceFile.create(recursive: true);
    await sourceFile.writeAsString('current-data');
    await destinationFile.create(recursive: true);
    await destinationFile.writeAsString('partial');

    final migrated = await AndroidWorkingDirectoryMigration.migrate(source: source, destination: destination);

    expect(migrated, isTrue);
    expect(await source.exists(), isFalse);
    expect(await destinationFile.readAsString(), 'current-data');
  });

  test('completion marker prevents stale external data overwriting private data', () async {
    final source = Directory(p.join(sandbox.path, 'external'));
    final destination = Directory(p.join(sandbox.path, 'internal'));
    final sourceFile = File(p.join(source.path, 'data', 'core.db'));
    final destinationFile = File(p.join(destination.path, 'data', 'core.db'));
    await sourceFile.create(recursive: true);
    await sourceFile.writeAsString('legacy-data');

    expect(await AndroidWorkingDirectoryMigration.migrate(source: source, destination: destination), isTrue);

    await destinationFile.writeAsString('new-private-data');
    await sourceFile.create(recursive: true);
    await sourceFile.writeAsString('stale-external-data');

    expect(await AndroidWorkingDirectoryMigration.migrate(source: source, destination: destination), isTrue);
    expect(await destinationFile.readAsString(), 'new-private-data');
    expect(await source.exists(), isFalse);
  });

  test('does nothing when source and destination are the same directory', () async {
    final directory = Directory(p.join(sandbox.path, 'same'));
    final file = File(p.join(directory.path, 'keep.txt'));
    await file.create(recursive: true);
    await file.writeAsString('keep');

    final migrated = await AndroidWorkingDirectoryMigration.migrate(source: directory, destination: directory);

    expect(migrated, isTrue);
    expect(await file.readAsString(), 'keep');
  });
}
