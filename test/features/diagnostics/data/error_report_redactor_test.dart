import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/diagnostics/data/error_report_redactor.dart';

void main() {
  test('redacts sensitive values while preserving report identifiers', () {
    const redactor = ErrorReportRedactor();
    const eventId = '4cbd3b0d-55c8-4de8-98db-1bb4f5f3a9b5';

    final redacted = redactor.redactMap({
      'event_id': eventId,
      'authorization': 'Bearer secret-token',
      'message': 'vless://secret@example.com token=abc public_key=def 192.0.2.1:443',
    });

    expect(redacted['event_id'], eventId);
    expect(redacted['authorization'], '<redacted>');
    expect(redacted['message'], isNot(contains('vless://secret@example.com')));
    expect(redacted['message'], isNot(contains('abc')));
    expect(redacted['message'], isNot(contains('def')));
    expect(redacted['message'], isNot(contains('192.0.2.1')));
  });

  test('replaces NUL characters before report serialization', () {
    const redactor = ErrorReportRedactor();

    final redacted = redactor.redactMap({
      'logs': {
        'app_file_tail': ['\u0000binary-prefix'],
      },
    });

    expect(redacted['logs'], {
      'app_file_tail': ['[NUL]binary-prefix'],
    });
  });
}
