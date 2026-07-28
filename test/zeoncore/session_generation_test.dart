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
}
