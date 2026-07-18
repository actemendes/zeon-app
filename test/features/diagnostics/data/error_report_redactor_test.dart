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

  test('redacts standalone credentials and legacy preference logs', () {
    const redactor = ErrorReportRedactor();
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature_value';
    const apiKey = 'mob_aabbccddeeff001122334455';
    const input =
        'jwt=$jwt api_key: "$apiKey"\n'
        'updating preference [warp-access-token](String) to [cloudflare-secret]';

    final redacted = redactor.redactText(input);

    expect(redacted, isNot(contains(jwt)));
    expect(redacted, isNot(contains(apiKey)));
    expect(redacted, isNot(contains('cloudflare-secret')));
    expect(redacted, contains('<redacted>'));
  });

  test('preserves app version metadata even when it looks like an address', () {
    const redactor = ErrorReportRedactor();

    final redacted = redactor.redactMap({
      'app': {
        'name': 'ZEON',
        'version': '1.2.3.4',
        'build_number': '100300',
        'release': 'appStore',
        'environment': 'dev',
      },
      'message': 'connection failed 1.2.3.4:443',
    });

    expect(redacted['app'], {
      'name': 'ZEON',
      'version': '1.2.3.4',
      'build_number': '100300',
      'release': 'appStore',
      'environment': 'dev',
    });
    expect(redacted['message'], isNot(contains('1.2.3.4')));
  });
}
