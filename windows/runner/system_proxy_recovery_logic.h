#ifndef RUNNER_SYSTEM_PROXY_RECOVERY_LOGIC_H_
#define RUNNER_SYSTEM_PROXY_RECOVERY_LOGIC_H_

#include <cstdint>
#include <string>

namespace zeon::system_proxy {

struct ProxyState {
  std::uint32_t flags = 0;
  std::wstring proxy_server;
  std::wstring proxy_bypass;
  std::wstring auto_config_url;

  bool operator==(const ProxyState& other) const {
    return flags == other.flags && proxy_server == other.proxy_server &&
           proxy_bypass == other.proxy_bypass &&
           auto_config_url == other.auto_config_url;
  }
};

enum class RecoveryDecision {
  kWaitForLiveOwner,
  kRestoreBaseline,
  kPreserveForeignState,
  kRejectInvalidMarker,
};

inline bool IsExpectedZeonLoopback(const ProxyState& expected,
                                   std::uint32_t mixed_port) {
  if (mixed_port == 0 || mixed_port > 65535 ||
      (expected.flags & 2U) == 0) {
    return false;
  }
  return expected.proxy_server ==
         L"http://127.0.0.1:" + std::to_wstring(mixed_port);
}

inline RecoveryDecision DecideRecovery(const ProxyState& current,
                                        const ProxyState& expected,
                                        std::uint32_t mixed_port,
                                        bool recorded_owner_running,
                                        bool allow_recorded_owner) {
  if (!IsExpectedZeonLoopback(expected, mixed_port)) {
    return RecoveryDecision::kRejectInvalidMarker;
  }
  if (recorded_owner_running && !allow_recorded_owner) {
    return RecoveryDecision::kWaitForLiveOwner;
  }
  return current == expected ? RecoveryDecision::kRestoreBaseline
                             : RecoveryDecision::kPreserveForeignState;
}

}  // namespace zeon::system_proxy

#endif  // RUNNER_SYSTEM_PROXY_RECOVERY_LOGIC_H_
