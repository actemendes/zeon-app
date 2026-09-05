#ifndef RUNNER_SYSTEM_PROXY_RECOVERY_H_
#define RUNNER_SYSTEM_PROXY_RECOVERY_H_

enum class SystemProxyRecoveryResult {
  kNoRecord,
  kOwnerStillRunning,
  kBaselineRestored,
  kForeignStatePreserved,
  kMutexFailed,
  kRecordReadFailed,
  kProxyQueryFailed,
  kInvalidMarker,
  kProxyRestoreFailed,
  kStateCleanupFailed,
};

inline bool SystemProxyRecoveryFailed(SystemProxyRecoveryResult result) {
  return result == SystemProxyRecoveryResult::kMutexFailed ||
         result == SystemProxyRecoveryResult::kRecordReadFailed ||
         result == SystemProxyRecoveryResult::kProxyQueryFailed ||
         result == SystemProxyRecoveryResult::kInvalidMarker ||
         result == SystemProxyRecoveryResult::kProxyRestoreFailed ||
         result == SystemProxyRecoveryResult::kStateCleanupFailed;
}

// Restores a persisted ZEON-owned WinINet proxy baseline. The current proxy is
// changed only when it exactly matches the expected ZEON loopback state.
// allow_current_process_owner is reserved for synchronous runner shutdown.
SystemProxyRecoveryResult RecoverZeonSystemProxy(
    bool allow_current_process_owner) noexcept;

#endif  // RUNNER_SYSTEM_PROXY_RECOVERY_H_
