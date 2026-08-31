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
}
