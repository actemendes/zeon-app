import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/db/db.dart';

void main() {
  test('database waits for transient write locks', () async {
    final db = Db(NativeDatabase.memory());
    addTearDown(db.close);

    final rows = await db.customSelect('PRAGMA busy_timeout').get();

    expect(rows.single.data.values.single, 5000);
  });

  test('independent background connections preserve reads and competing writes', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-db-contention-');
    final file = File('${directory.path}/contention.sqlite');
    final foreground = Db(NativeDatabase.createInBackground(file));
    final background = Db(NativeDatabase.createInBackground(file));
    final releaseWriter = Completer<void>();
    final writerLocked = Completer<void>();
    Future<void>? firstWrite;
    try {
      await foreground.customStatement('CREATE TABLE contention_probe (value INTEGER NOT NULL)');
      await foreground.customStatement('INSERT INTO contention_probe VALUES (1)');
      // Open the second independent SQLite connection before holding the lock.
      await background.customSelect('SELECT value FROM contention_probe').getSingle();
      firstWrite = foreground.transaction(() async {
        await foreground.customStatement('UPDATE contention_probe SET value = 2');
        writerLocked.complete();
        await releaseWriter.future;
      });
      await writerLocked.future;
      final visible = await background.customSelect('SELECT value FROM contention_probe').getSingle();
      expect(visible.read<int>('value'), 1);

      var secondFinished = false;
      final secondWrite = background.customStatement('UPDATE contention_probe SET value = value + 10');
      // Attach the error expectation immediately, including on an implementation
      // that fails with SQLITE_BUSY instead of waiting for the first writer.
      final secondResult = expectLater(secondWrite.whenComplete(() => secondFinished = true), completes);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(secondFinished, isFalse);
      releaseWriter.complete();
      await firstWrite;
      await secondResult;
      final committed = await foreground.customSelect('SELECT value FROM contention_probe').getSingle();
      expect(committed.read<int>('value'), 12);
    } finally {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
      await firstWrite;
      await background.close();
      await foreground.close();
      await directory.delete(recursive: true);
    }
  });
}
