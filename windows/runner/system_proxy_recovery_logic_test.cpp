#include "system_proxy_recovery_logic.h"

#include <cassert>

namespace {

using zeon::system_proxy::DecideRecovery;
using zeon::system_proxy::ProxyState;
using zeon::system_proxy::RecoveryDecision;

ProxyState ZeonState() {
  return ProxyState{3U, L"http://127.0.0.1:12346", L"<local>",
                    L"http://corp.test/proxy.pac"};
}

}  // namespace

int main() {
  const ProxyState expected = ZeonState();
  assert(DecideRecovery(expected, expected, 12346, false, false) ==
         RecoveryDecision::kRestoreBaseline);
  assert(DecideRecovery(expected, expected, 12346, true, false) ==
         RecoveryDecision::kWaitForLiveOwner);
  assert(DecideRecovery(expected, expected, 12346, true, true) ==
         RecoveryDecision::kRestoreBaseline);

  ProxyState changed = expected;
  changed.proxy_server = L"http://corp.test:8080";
  assert(DecideRecovery(changed, expected, 12346, false, false) ==
         RecoveryDecision::kPreserveForeignState);
  changed = expected;
  changed.proxy_bypass = L"*.corp.test;<local>";
  assert(DecideRecovery(changed, expected, 12346, false, false) ==
         RecoveryDecision::kPreserveForeignState);
  changed = expected;
  changed.auto_config_url = L"http://policy.test/new.pac";
  assert(DecideRecovery(changed, expected, 12346, false, false) ==
         RecoveryDecision::kPreserveForeignState);
  changed = expected;
  changed.flags = 5U;
  assert(DecideRecovery(changed, expected, 12346, false, false) ==
         RecoveryDecision::kPreserveForeignState);

  assert(DecideRecovery(expected, expected, 0, false, false) ==
         RecoveryDecision::kRejectInvalidMarker);
  assert(DecideRecovery(expected, expected, 12347, false, false) ==
         RecoveryDecision::kRejectInvalidMarker);
  ProxyState ipv6 = expected;
  ipv6.proxy_server = L"http://[::1]:12346";
  assert(DecideRecovery(ipv6, ipv6, 12346, false, false) ==
         RecoveryDecision::kRejectInvalidMarker);
  return 0;
}
