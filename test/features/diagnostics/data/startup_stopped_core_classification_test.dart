import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

/// `vpn_not_running_on_startup` fired whenever the persisted `started_by_user`
/// intent was set and the core happened to be stopped. That intent survives
/// process death, app restart and reboot, and nothing restores the tunnel
/// automatically on launch, so the combination describes the ordinary state
/// after any restart. All 905 production reports of this kind carried a bare
/// `Stopped` with no alert and no message - no evidence of a failure at all.
///
/// A start that really failed leaves the core's own alert/message behind, and
/// that must keep reporting.
void main() {
  group('startup stopped-core classification', () {
    test('CASE A: cold startup with no restore attempted is not a failure', () {
      expect(stoppedCoreIndicatesFailedStart(const CoreStopped()), isFalse);
    });

    test('CASE B: normal reconciliation after process restart is not a failure', () {
      // Matches the shape seen in production: `Stopped message=` (empty).
      expect(stoppedCoreIndicatesFailedStart(const CoreStopped(message: '')), isFalse);
      expect(stoppedCoreIndicatesFailedStart(const CoreStopped(message: '   ')), isFalse);
    });

    test('CASE C: a start that actually failed is still reported', () {
      expect(
        stoppedCoreIndicatesFailedStart(
          const CoreStopped(alert: CoreAlert.startService, message: 'configure tun interface: Access is denied.'),
        ),
        isTrue,
      );
    });

    test('CASE C2: a failure message without an alert is still reported', () {
      expect(
        stoppedCoreIndicatesFailedStart(const CoreStopped(message: 'failed to start background core')),
        isTrue,
      );
    });

    test('CASE D: an alert with no message is still reported', () {
      expect(stoppedCoreIndicatesFailedStart(const CoreStopped(alert: CoreAlert.startService)), isTrue);
    });
  });
}
