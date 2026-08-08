import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';

/// `vpn_unexpected_disconnect` is meant to record the tunnel going away on its
/// own. Production telemetry showed 202 of these reports arriving from a
/// `Disconnecting -> Disconnected` transition - i.e. the orderly completion of
/// a shutdown that had already been announced - including plain
/// `manual_disconnect` and `config_restart` teardowns. They were reported only
/// because the expected-stop window is anchored to the last user action and a
/// slow teardown (measured at ~6s, and longer for restart flows that chain a
/// stop and a start) can outlive it.
///
/// The 103 `Connected -> Disconnected` reports are the genuine outages and
/// must keep being reported.
void main() {
  group('unexpected disconnect classification', () {
    test('CASE A: orderly teardown after a manual disconnect is not an outage', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Disconnecting(),
          wasUpBefore: true,
          expectedRunning: true,
          // The user action happened long enough ago that the 30s window lapsed.
          isExpectedStop: false,
        ),
        isFalse,
      );
    });

    test('CASE B: teardown belonging to a config restart is not an outage', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Disconnecting(),
          wasUpBefore: true,
          expectedRunning: true,
          isExpectedStop: false,
        ),
        isFalse,
      );
    });

    test('CASE C: replacement/reconnect teardown is not an outage', () {
      // A reconnect keeps the user intent set to running while the old session
      // is torn down; the Disconnecting hop still makes it an orderly stop.
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Disconnecting(),
          wasUpBefore: true,
          expectedRunning: true,
          isExpectedStop: false,
        ),
        isFalse,
      );
    });

    test('CASE D: a drop straight from Connected is still reported', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Connected(),
          wasUpBefore: true,
          expectedRunning: true,
          isExpectedStop: false,
        ),
        isTrue,
        reason: 'no shutdown was ever announced, so the tunnel dropped on its own',
      );
    });

    test('CASE E: a drop inside the expected-stop window is not an outage', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Connected(),
          wasUpBefore: true,
          expectedRunning: true,
          isExpectedStop: true,
        ),
        isFalse,
      );
    });

    test('never reported when the user did not want the VPN running', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Connected(),
          wasUpBefore: true,
          expectedRunning: false,
          isExpectedStop: false,
        ),
        isFalse,
      );
    });

    test('never reported when the tunnel was never up', () {
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Connecting(),
          wasUpBefore: false,
          expectedRunning: true,
          isExpectedStop: false,
        ),
        isFalse,
      );
    });

    test('a Connecting -> Disconnected failure is still reported once it had been up', () {
      // Reconnect attempt after the tunnel had been established: nothing
      // announced a shutdown, so this stays visible.
      expect(
        shouldCaptureUnexpectedDisconnect(
          previousStatus: const Connecting(),
          wasUpBefore: true,
          expectedRunning: true,
          isExpectedStop: false,
        ),
        isTrue,
      );
    });
  });
}
