import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/diagnostics/data/diagnostics_log_printer.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';

void main() {
  test('diagnostic events and Go stack frames stay in log tails only', () {
    expect(
      shouldCaptureDiagnosticLogMessage(
        'event=grpc_transport_outcome monotonic_ms=42 pid=7 generation=99 source=listener outcome=realFailure',
      ),
      isFalse,
    );
    expect(shouldCaptureDiagnosticLogMessage('github.com/sagernet/sing-box/box.go:496 +0x28'), isFalse);
    expect(shouldCaptureDiagnosticLogMessage('runtime/debug/stack.go:26 +0x64'), isFalse);
    expect(shouldCaptureDiagnosticLogMessage('encrypted metadata integrity check failed'), isTrue);
  });

  test('fingerprint normalization removes volatile process data', () {
    final first = normalizeErrorFingerprintText(
      'event=failure monotonic_ms=12 pid=100 generation=200 address = host, port = 51387 sequence_number=1',
    );
    final second = normalizeErrorFingerprintText(
      'event=failure monotonic_ms=99 pid=101 generation=201 address = other, port = 65205 sequence_number=2',
    );

    expect(first, second);
  });

  test('deduplicator accepts an incident again after its cooldown', () {
    final limiter = ErrorReportDeduplicator();
    final now = DateTime.utc(2026, 8, 24, 10);

    expect(limiter.shouldCapture('same', now), isTrue);
    expect(limiter.shouldCapture('same', now.add(const Duration(minutes: 9))), isFalse);
    expect(limiter.shouldCapture('same', now.add(const Duration(minutes: 10))), isTrue);
  });

  test('device id is pseudonymous and stable', () async {
    final first = await pseudonymousDeviceId('android-private-device-id');
    final second = await pseudonymousDeviceId('android-private-device-id');

    expect(first, second);
    expect(first, startsWith('sha256:'));
    expect(first, isNot(contains('android-private-device-id')));
  });
}
