import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/utils/preferences_utils.dart';

void main() {
  test('a hung preference write does not block a newer value and repairs if it completes late', () async {
    final writes = <bool>[];
    final pending = <Completer<bool>>[];
    final commits = <bool>[];
    final coordinator = LatestPreferenceWriteCoordinator<bool>(
      persist: (value) {
        writes.add(value);
        final completer = Completer<bool>();
        pending.add(completer);
        return completer.future;
      },
      commit: commits.add,
    );

    final oldUpdate = coordinator.update(false);
    expect(coordinator.latestRequested, isFalse);
    final newUpdate = coordinator.update(true);
    expect(coordinator.latestRequested, isTrue);

    expect(writes, [false, true]);
    pending[1].complete(true);
    await newUpdate;
    expect(commits, [true]);

    pending[0].complete(true);
    await oldUpdate;
    await Future<void>.delayed(Duration.zero);

    expect(writes, [false, true, true], reason: 'the late stale write must reassert the latest value');
    pending[2].complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(commits, [true, true]);
  });

  test('reset invalidation prevents a late write from restoring removed state', () async {
    final write = Completer<bool>();
    final commits = <bool>[];
    final coordinator = LatestPreferenceWriteCoordinator<bool>(persist: (_) => write.future, commit: commits.add);

    final update = coordinator.update(true);
    coordinator.invalidate();
    write.complete(true);
    await update;

    expect(commits, isEmpty);
  });
}
