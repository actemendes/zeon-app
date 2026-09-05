#include "system_proxy_recovery_registry.h"

#include <cassert>
#include <iostream>
#include <string>

int wmain() {
  const std::wstring child =
      L"DeleteValuedTree_" + std::to_wstring(::GetCurrentProcessId()) + L"_" +
      std::to_wstring(::GetTickCount64());
  const std::wstring parent = L"Software\\ZEON\\RecoveryTests";
  const std::wstring full_path = parent + L"\\" + child;

  HKEY key = nullptr;
  DWORD disposition = 0;
  assert(::RegCreateKeyExW(HKEY_CURRENT_USER, full_path.c_str(), 0, nullptr, 0,
                           KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &key,
                           &disposition) == ERROR_SUCCESS);
  const DWORD armed = 1;
  assert(::RegSetValueExW(key, L"Armed", 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&armed),
                          sizeof(armed)) == ERROR_SUCCESS);

  const std::wstring proxy = L"http://127.0.0.1:55432";
  assert(::RegSetValueExW(
             key, L"ExpectedProxyServer", 0, REG_SZ,
             reinterpret_cast<const BYTE*>(proxy.c_str()),
             static_cast<DWORD>(proxy.size() * sizeof(wchar_t))) ==
         ERROR_SUCCESS);
  const wchar_t empty[] = L"";
  assert(::RegSetValueExW(key, L"ExpectedProxyBypass", 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(empty),
                          0) == ERROR_SUCCESS);

  std::wstring read_proxy;
  std::wstring read_empty;
  const bool proxy_read = zeon::system_proxy::ReadRegistryString(
      key, L"ExpectedProxyServer", &read_proxy);
  if (!proxy_read) {
    DWORD debug_type = 0;
    DWORD debug_size = 0;
    const LSTATUS debug_status = ::RegQueryValueExW(
        key, L"ExpectedProxyServer", nullptr, &debug_type, nullptr,
        &debug_size);
    std::wcerr << L"ReadRegistryString failed: status=" << debug_status
               << L" type=" << debug_type << L" size=" << debug_size
               << L'\n';
  }
  assert(proxy_read);
  assert(zeon::system_proxy::ReadRegistryString(
      key, L"ExpectedProxyBypass", &read_empty));
  assert(read_proxy == proxy);
  assert(read_proxy.size() == proxy.size());
  assert(read_empty.empty());
  ::RegCloseKey(key);

  assert(zeon::system_proxy::DeleteRegistryTree(
             HKEY_CURRENT_USER, parent.c_str(), child.c_str()) ==
         ERROR_SUCCESS);
  assert(::RegOpenKeyExW(HKEY_CURRENT_USER, full_path.c_str(), 0,
                         KEY_QUERY_VALUE, &key) == ERROR_FILE_NOT_FOUND);

  // Best-effort removal of the now-empty test parent.
  ::RegDeleteKeyW(HKEY_CURRENT_USER, parent.c_str());
  return 0;
}
