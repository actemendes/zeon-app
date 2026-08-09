import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

/// Production sent 16 `vpn_unexpected_disconnect` reports while the core was
/// still `Stopping` (11 config restarts, 4 profile reconnects, 1 manual
/// disconnect). A core in `Stopping` is completing a teardown it already
/// announced, so reaching `Disconnected` there is that teardown finishing -
/// not the tunnel dropping on its own.
///
/// This check is on the authoritative core lifecycle, which is deliberately
/// independent of the connection states the UI observed: those reports carried
/// `status_before = CONNECTED` while `core_status` said `Stopping`, so the two
/// disagreed.
void main() {
  group('mid-Stopping unexpected-disconnect classification', () {
    test('CASE A: core still Stopping is not an outage', () {
      expect(coreStatusAllowsUnexpectedDisconnectReport(const CoreStopping()), isFalse);
    });

    test('CASE B: a stopped core stays reportable', () {
      expect(
        coreStatusAllowsUnexpectedDisconnectReport(const CoreStopped()),
        isTrue,
        reason: 'a genuine drop lands in Stopped and must remain visible',
      );
    });

    test('CASE D: a stopped core carrying failure evidence stays reportable', () {
      expect(
        coreStatusAllowsUnexpectedDisconnectReport(
          const CoreStopped(alert: CoreAlert.startService, message: 'teardown_timeout'),
        ),
        isTrue,
      );
    });

    test('a started core stays reportable', () {
      // Dart believing the tunnel is gone while the core reports Started is a
      // desync worth seeing, not something to hide.
      expect(coreStatusAllowsUnexpectedDisconnectReport(const CoreStarted()), isTrue);
    });

    test('a starting core stays reportable', () {
      expect(coreStatusAllowsUnexpectedDisconnectReport(const CoreStarting()), isTrue);
    });
  });
}
