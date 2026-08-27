import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/utils/windows_tun_diagnostics.dart';

void main() {
  test('extracts FwpmFilterAdd0 HRESULT without retaining native error text', () {
    final result = windowsTunFailureDiagnostic(
      stage: 'core_start',
      elevated: false,
      error: 'secret profile data FwpmFilterAdd0 failed HRESULT=0x80320009 token=private',
    );

    expect(result['stage'], 'wfp_filter_add');
    expect(result['native_operation'], 'FwpmFilterAdd0');
    expect(result['hresult'], '0x80320009');
    expect(result.values.join(' '), isNot(contains('secret profile data')));
    expect(result.values.join(' '), isNot(contains('token=private')));
    expect(result['filter_owner_scope'], 'native_core_only');
    expect(result['bfe_state'], isNot(isEmpty));
  });

  test('maps BFE service states without mutating the service', () {
    expect(bfeStateNameForTesting(1), 'stopped');
    expect(bfeStateNameForTesting(4), 'running');
    expect(bfeStateNameForTesting(999), 'unknown');
  });
}
