import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/session_generation.dart';

void main() {
  group('SessionGenerationGate', () {
    test('start then restart makes the start callback stale', () {
      final stale = <String>[];
      final gate = SessionGenerationGate(
        seed: 100,
        onStale: (value, current, source) => stale.add('$value/$current/$source'),
      );

      final start = gate.next();
      final restart = gate.next();

      expect(gate.isCurrent(start, source: 'start_result'), isFalse);
      expect(gate.isCurrent(restart, source: 'restart_result'), isTrue);
      expect(stale, ['101/102/start_result']);
    });

    test('start then stop rejects a late start callback', () {
      final gate = SessionGenerationGate(seed: 200);
      final start = gate.next();
      final stop = gate.next();

      expect(gate.isCurrent(start, source: 'start_result'), isFalse);
      expect(gate.isCurrent(stop, source: 'stop_result'), isTrue);
    });

    test('restart then restart keeps only the newest attempt', () {
      final gate = SessionGenerationGate(seed: 300);
      final first = gate.next();
      final second = gate.next();

      expect(gate.isCurrent(first, source: 'first_restart'), isFalse);
      expect(gate.isCurrent(second, source: 'second_restart'), isTrue);
    });

    test('profile switch invalidates results from the old profile session', () {
      final gate = SessionGenerationGate(seed: 400);
      final profileA = gate.next();
      final profileB = gate.next();

      expect(gate.isCurrent(profileA, source: 'profile_a_callback'), isFalse);
      expect(gate.isCurrent(profileB, source: 'profile_b_callback'), isTrue);
    });

    test('manual reselect invalidates an older background test result', () {
      final gate = SessionGenerationGate(seed: 500);
      final backgroundTest = gate.current;
      final manualSession = gate.next();

      expect(gate.isCurrent(backgroundTest, source: 'background_url_test'), isFalse);
      expect(gate.isCurrent(manualSession, source: 'manual_reselect'), isTrue);
    });

    test('callback from a closed session cannot affect the new session', () {
      final gate = SessionGenerationGate(seed: 600);
      final closed = gate.next();
      final active = gate.next();

      expect(gate.isCurrent(closed, source: 'closed_session_callback'), isFalse);
      expect(gate.isCurrent(active, source: 'active_session_callback'), isTrue);
    });
  });

  group('Stage 2.1 stale completion and serialized mode switch', () {
    test('Smart to Round Robin closes old body before new body starts', () async {
      final queue = SerialLifecycleQueue();
      final oldMayClose = Completer<void>();
      final oldStarted = Completer<void>();
      final order = <String>[];

      final smartToRoundRobin = queue.enqueue(() async {
        order.add('old-start');
        oldStarted.complete();
        await oldMayClose.future;
        order.add('old-close');
      });
      await oldStarted.future;
      final roundRobinToSmart = queue.enqueue(() async => order.add('new-start'));
      expect(order, ['old-start']);
      oldMayClose.complete();
      await Future.wait([smartToRoundRobin, roundRobinToSmart]);
      expect(order, ['old-start', 'old-close', 'new-start']);
    });

    test('20 rapid switches execute at most one lifecycle body at a time', () async {
      final queue = SerialLifecycleQueue();
      var active = 0;
      var maxActive = 0;
      final barriers = List.generate(20, (_) => Completer<void>());
      final started = List.generate(20, (_) => Completer<void>());
      final futures = <Future<void>>[];

      for (var index = 0; index < 20; index++) {
        futures.add(
          queue.enqueue(() async {
            active++;
            if (active > maxActive) maxActive = active;
            started[index].complete();
            await barriers[index].future;
            active--;
          }),
        );
      }
      for (var index = 0; index < 20; index++) {
        await started[index].future;
        expect(active, 1);
        barriers[index].complete();
      }
      await Future.wait(futures);
      expect(maxActive, 1);
      expect(active, 0);
    });

    test('stale openTun exception is cancellation and cannot reach UI', () {
      final gate = SessionGenerationGate(seed: 1000);
      final old = gate.next();
      gate.next();
      var dialogShown = false;
      final disposition = gate.classifyCompletion(old, source: 'open_tun_exception');
      if (disposition == SessionCompletionDisposition.current) dialogShown = true;
      expect(disposition, SessionCompletionDisposition.stale);
      expect(dialogShown, isFalse);
    });

    test('stale Mobile.start exception does not stop new generation', () {
      final gate = SessionGenerationGate(seed: 1100);
      final old = gate.next();
      final current = gate.next();
      var currentRunning = true;
      if (gate.classifyCompletion(old, source: 'mobile_start_exception') == SessionCompletionDisposition.current) {
        currentRunning = false;
      }
      expect(gate.isCurrent(current, source: 'current_session'), isTrue);
      expect(currentRunning, isTrue);
    });

    test('stale command timeout and stale close cannot mutate current state', () {
      final gate = SessionGenerationGate(seed: 1200);
      final old = gate.next();
      gate.next();
      var state = 'connected';
      for (final source in ['command_timeout', 'close_callback']) {
        if (gate.classifyCompletion(old, source: source) == SessionCompletionDisposition.current) {
          state = 'stopped';
        }
      }
      expect(state, 'connected');
    });

    test('switch during start and TUN open only publishes newest generation', () {
      final gate = SessionGenerationGate(seed: 1300);
      final starting = gate.next();
      final tunOpening = starting;
      final latest = gate.next();
      expect(gate.classifyCompletion(starting, source: 'start'), SessionCompletionDisposition.stale);
      expect(gate.classifyCompletion(tunOpening, source: 'tun'), SessionCompletionDisposition.stale);
      expect(gate.classifyCompletion(latest, source: 'latest'), SessionCompletionDisposition.current);
    });

    test('late error immediately after old core success cannot replace new session', () {
      final gate = SessionGenerationGate(seed: 1400);
      final old = gate.next();
      final latest = gate.next();
      var selectedGeneration = latest;
      if (gate.classifyCompletion(old, source: 'late_core_success_error') == SessionCompletionDisposition.current) {
        selectedGeneration = old;
      }
      expect(selectedGeneration, latest);
    });
  });
}
