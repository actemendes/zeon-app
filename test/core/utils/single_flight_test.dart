import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/utils/single_flight.dart';

void main() {
  test('coalesces concurrent operations and allows a later retry', () async {
    final gate = Completer<void>();
    final singleFlight = SingleFlight<int>();
    var calls = 0;

    Future<int> operation() async {
      calls++;
      await gate.future;
      return calls;
    }

    final first = singleFlight.run(operation);
    final second = singleFlight.run(operation);

    expect(identical(first, second), isTrue);
    expect(calls, 1);
    expect(singleFlight.isRunning, isTrue);

    gate.complete();
    expect(await Future.wait([first, second]), [1, 1]);
    expect(singleFlight.isRunning, isFalse);

    expect(await singleFlight.run(operation), 2);
    expect(calls, 2);
  });

  test('clears a failed operation so it can be retried', () async {
    final singleFlight = SingleFlight<void>();
    var calls = 0;

    Future<void> operation() async {
      calls++;
      if (calls == 1) throw StateError('first attempt failed');
    }

    await expectLater(singleFlight.run(operation), throwsStateError);
    await singleFlight.run(operation);

    expect(calls, 2);
  });
}
