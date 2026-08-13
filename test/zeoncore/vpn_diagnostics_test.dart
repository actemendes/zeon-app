import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/vpn_diagnostics.dart';

void main() {
  test("VPN diagnostic envelope contains monotonic clock, pid and generation", () {
    final event = vpnDiagnosticEvent("core_start_success", 17, details: "owner=flutter");

    expect(event, contains("event=core_start_success"));
    expect(event, contains(RegExp(r"monotonic_ms=\d+")));
    expect(event, contains(RegExp(r"pid=\d+")));
    expect(event, contains("generation=17"));
  });

  test("selector diagnostics only forward approved opaque fields", () {
    final details = selectorDiagnosticDetails(
      "[SelectorSwitch] type=manual reason=user_reselect "
      "old_id=0123456789ab new_id=fedcba987654 "
      "interrupt_external=false closed_tcp=0 closed_udp=0 "
      "server=secret.example uuid=11111111-1111-1111-1111-111111111111",
    );

    expect(details, contains("old_id=0123456789ab"));
    expect(details, contains("new_id=fedcba987654"));
    expect(details, isNot(contains("secret.example")));
    expect(details, isNot(contains("uuid")));
  });
}
