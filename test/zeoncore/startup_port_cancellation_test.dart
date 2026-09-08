import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_mobile.dart';

void main() {
  test('cancelled startup rejects late open port and does not retry or clean a newer session', () async {
    final probe = Completer<bool>();
    var current = true;
    var probes = 0;
    var cleanupCalls = 0;
    final pending = waitUntilPort(
      18179,
      true,
      () async => cleanupCalls++,
      portProbe: (_, _) {
        probes++;
        return probe.future;
      },
      isCurrent: () => current,
    );
    current = false;
    probe.complete(true);
    expect(await pending, isFalse);
    expect(probes, 1);
    expect(cleanupCalls, 0);
    expect(await waitUntilPort(18179, true, null, portProbe: (_, _) async => true, isCurrent: () => true), isTrue);
  });
}
