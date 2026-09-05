#ifndef RUNNER_SYSTEM_PROXY_RECOVERY_REGISTRY_H_
#define RUNNER_SYSTEM_PROXY_RECOVERY_REGISTRY_H_

#include <windows.h>

#include <string>

namespace zeon::system_proxy {

inline bool ReadRegistryString(HKEY key, const wchar_t* name,
                               std::wstring* value) {
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status =
      ::RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (status != ERROR_SUCCESS || type != REG_SZ ||
      size % sizeof(wchar_t) != 0 || size > MAXDWORD - sizeof(wchar_t)) {
    return false;
  }
  // Leave room for a terminator even when a REG_SZ writer persisted bytes
  // without one. RegQueryValueExW reports the stored byte count unchanged.
  DWORD read_size = size + sizeof(wchar_t);
  std::wstring buffer(read_size / sizeof(wchar_t), L'\0');
  status = ::RegQueryValueExW(
      key, name, nullptr, &type, reinterpret_cast<BYTE*>(buffer.data()),
      &read_size);
  if (status != ERROR_SUCCESS || read_size % sizeof(wchar_t) != 0) {
    return false;
  }
  // Discard untouched allocation padding before removing terminators,
  // otherwise exact ownership comparisons can retain an invisible NUL.
  buffer.resize(read_size / sizeof(wchar_t));
  while (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  *value = std::move(buffer);
  return true;
}

// Deletes a child tree whose key may contain values. RegDeleteTreeW requires
// KEY_SET_VALUE in addition to the documented recursive-enumeration rights
// when values are present in the target tree.
inline LSTATUS DeleteRegistryTree(HKEY root, const wchar_t* parent_path,
                                  const wchar_t* child_name) {
  HKEY parent = nullptr;
  const LSTATUS open_status = ::RegOpenKeyExW(
      root, parent_path, 0,
      DELETE | KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE | KEY_SET_VALUE,
      &parent);
  if (open_status != ERROR_SUCCESS) {
    return open_status;
  }
  const LSTATUS delete_status = ::RegDeleteTreeW(parent, child_name);
  ::RegCloseKey(parent);
  return delete_status;
}

}  // namespace zeon::system_proxy

#endif  // RUNNER_SYSTEM_PROXY_RECOVERY_REGISTRY_H_
