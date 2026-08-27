#include "system_proxy_recovery.h"

#include <iostream>

int wmain() {
  const SystemProxyRecoveryResult result = RecoverZeonSystemProxy(false);
  std::wcout << L"recovery.result=" << static_cast<int>(result) << L'\n';
  return SystemProxyRecoveryFailed(result) ? 1 : 0;
}
