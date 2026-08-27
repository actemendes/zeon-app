import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_start_signal_tracker.dart';

void main() {
  test('requires STARTING then STARTED for the current generation', () {
    final tracker = CoreStartSignalTracker()..reset(42);

    tracker.observe(42, const CoreStatus.started());
    expect(tracker.confirmsStarted(42), isFalse);

    tracker.observe(42, const CoreStatus.starting());
    expect(tracker.confirmsStarted(42), isFalse);

    tracker.observe(42, const CoreStatus.started());
    expect(tracker.confirmsStarted(42), isTrue);
  });

  test('ignores stale generations and reset invalidates old evidence', () {
    final tracker = CoreStartSignalTracker()..reset(10);
    tracker
      ..observe(9, const CoreStatus.starting())
      ..observe(9, const CoreStatus.started());
    expect(tracker.confirmsStarted(10), isFalse);

    tracker
      ..observe(10, const CoreStatus.starting())
      ..observe(10, const CoreStatus.started());
    expect(tracker.confirmsStarted(10), isTrue);

    tracker.reset(11);
    expect(tracker.confirmsStarted(10), isFalse);
    expect(tracker.confirmsStarted(11), isFalse);
  });
}
