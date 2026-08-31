#include <windows.h>
#include <wininet.h>

#include <cstdint>
#include <iostream>
#include <string>

namespace {

constexpr wchar_t kRecoveryKey[] = L"Software\\ZEON\\SystemProxyRecovery";

std::wstring ReadString(HKEY key, const wchar_t* name, bool* ok) {
  DWORD type = 0;
  DWORD size = 0;
  const LSTATUS first = ::RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ,
                                       &type, nullptr, &size);
  std::wcout << L"registry.string name=" << name << L" first=" << first
             << L" type=" << type << L" size=" << size << L'\n';
  if (first != ERROR_SUCCESS || size < sizeof(wchar_t)) {
    *ok = false;
    return L"";
  }
  std::wstring buffer(size / sizeof(wchar_t), L'\0');
  const LSTATUS second = ::RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ,
                                        &type, buffer.data(), &size);
  std::wcout << L"registry.string.read name=" << name << L" status="
             << second << L" size=" << size << L'\n';
  if (second != ERROR_SUCCESS) {
    *ok = false;
    return L"";
  }
  if (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  return buffer;
}

std::uint64_t ReadInteger(HKEY key, const wchar_t* name, DWORD flags,
                          bool* ok) {
  std::uint64_t value = 0;
  DWORD type = 0;
  DWORD size = flags == RRF_RT_REG_DWORD ? sizeof(DWORD) : sizeof(value);
  const LSTATUS status = ::RegGetValueW(key, nullptr, name, flags, &type,
                                        &value, &size);
  std::wcout << L"registry.integer name=" << name << L" status=" << status
             << L" type=" << type << L" size=" << size << L" value="
             << value << L'\n';
  if (status != ERROR_SUCCESS) {
    *ok = false;
  }
  return value;
}

std::wstring CopyAndFree(LPWSTR value) {
  if (value == nullptr) {
    return L"";
  }
  std::wstring copy(value);
  ::GlobalFree(value);
  return copy;
}

bool QueryProxyState() {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = ARRAYSIZE(options);
  list.pOptions = options;
  DWORD size = sizeof(list);
  ::SetLastError(ERROR_SUCCESS);
  const BOOL success = ::InternetQueryOptionW(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size);
  const DWORD error = ::GetLastError();
  std::wcout << L"wininet.query success=" << success << L" error=" << error
             << L" size=" << size << L" option_error=" << list.dwOptionError
             << L'\n';
  if (!success) {
    return false;
  }
  const std::wstring server = CopyAndFree(options[1].Value.pszValue);
  const std::wstring bypass = CopyAndFree(options[2].Value.pszValue);
  const std::wstring pac = CopyAndFree(options[3].Value.pszValue);
  std::wcout << L"wininet.state flags=" << options[0].Value.dwValue
             << L" server=" << server << L" bypass=" << bypass
             << L" pac=" << pac << L'\n';
  return true;
}

bool ApplyDirectBaseline() {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = PROXY_TYPE_DIRECT;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(L"");
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(L"");
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = const_cast<wchar_t*>(L"");
  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = ARRAYSIZE(options);
  list.pOptions = options;

  ::SetLastError(ERROR_SUCCESS);
  const BOOL set_state = ::InternetSetOptionW(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list));
  const DWORD set_state_error = ::GetLastError();
  std::wcout << L"apply.per_connection success=" << set_state
             << L" error=" << set_state_error
             << L" option_error=" << list.dwOptionError << L'\n';

  ::SetLastError(ERROR_SUCCESS);
  const BOOL settings_changed = ::InternetSetOptionW(
      nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  const DWORD settings_changed_error = ::GetLastError();
  std::wcout << L"apply.settings_changed success=" << settings_changed
             << L" error=" << settings_changed_error << L'\n';

  ::SetLastError(ERROR_SUCCESS);
  const BOOL proxy_settings_changed = ::InternetSetOptionW(
      nullptr, INTERNET_OPTION_PROXY_SETTINGS_CHANGED, nullptr, 0);
  const DWORD proxy_settings_changed_error = ::GetLastError();
  std::wcout << L"apply.proxy_settings_changed success="
             << proxy_settings_changed << L" error="
             << proxy_settings_changed_error << L'\n';

  ::SetLastError(ERROR_SUCCESS);
  const BOOL refresh = ::InternetSetOptionW(
      nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  const DWORD refresh_error = ::GetLastError();
  std::wcout << L"apply.refresh success=" << refresh
             << L" error=" << refresh_error << L'\n';
  QueryProxyState();
  return set_state && settings_changed && proxy_settings_changed && refresh;
}

bool DeleteMarker() {
  HKEY key = nullptr;
  const LSTATUS open = ::RegOpenKeyExW(
      HKEY_CURRENT_USER, L"Software\\ZEON", 0,
      DELETE | KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE, &key);
  std::wcout << L"delete.open_parent status=" << open << L'\n';
  if (open != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = ::RegDeleteTreeW(key, L"SystemProxyRecovery");
  std::wcout << L"delete.tree status=" << status << L'\n';
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  HANDLE mutex = ::CreateMutexW(
      nullptr, FALSE, L"Local\\ZEONSystemProxyRecoveryMutex");
  if (mutex == nullptr) {
    std::wcout << L"mutex.create error=" << ::GetLastError() << L'\n';
    return 2;
  }
  const DWORD wait = ::WaitForSingleObject(mutex, 5000);
  std::wcout << L"mutex.wait=" << wait << L'\n';
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
    ::CloseHandle(mutex);
    return 3;
  }

  HKEY key = nullptr;
  const LSTATUS open = ::RegOpenKeyExW(HKEY_CURRENT_USER, kRecoveryKey, 0,
                                       KEY_QUERY_VALUE, &key);
  std::wcout << L"registry.open=" << open << L'\n';
  if (open != ERROR_SUCCESS) {
    ::ReleaseMutex(mutex);
    ::CloseHandle(mutex);
    return 4;
  }
  bool ok = true;
  ReadInteger(key, L"Armed", RRF_RT_REG_DWORD, &ok);
  ReadInteger(key, L"Schema", RRF_RT_REG_DWORD, &ok);
  const DWORD owner_pid = static_cast<DWORD>(
      ReadInteger(key, L"OwnerPid", RRF_RT_REG_DWORD, &ok));
  ReadInteger(key, L"OwnerCreationTime", RRF_RT_REG_QWORD, &ok);
  ReadInteger(key, L"Generation", RRF_RT_REG_QWORD, &ok);
  ReadInteger(key, L"MixedPort", RRF_RT_REG_DWORD, &ok);
  const wchar_t* names[] = {
      L"ExecutablePath", L"BaselineProxyServer", L"BaselineProxyBypass",
      L"BaselineAutoConfigURL", L"ExpectedProxyServer",
      L"ExpectedProxyBypass", L"ExpectedAutoConfigURL"};
  for (const wchar_t* name : names) {
    ReadString(key, name, &ok);
  }
  ReadInteger(key, L"BaselineFlags", RRF_RT_REG_DWORD, &ok);
  ReadInteger(key, L"ExpectedFlags", RRF_RT_REG_DWORD, &ok);
  ::RegCloseKey(key);

  HANDLE owner = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               owner_pid);
  std::wcout << L"owner.open=" << (owner != nullptr)
             << L" error=" << ::GetLastError() << L'\n';
  if (owner != nullptr) {
    FILETIME creation = {}, exit = {}, kernel = {}, user = {};
    const BOOL times =
        ::GetProcessTimes(owner, &creation, &exit, &kernel, &user);
    std::wcout << L"owner.times=" << times << L" creation="
               << (static_cast<std::uint64_t>(creation.dwHighDateTime) << 32 |
                   creation.dwLowDateTime)
               << L'\n';
    ::CloseHandle(owner);
  }
  const bool query_ok = QueryProxyState();
  bool apply_ok = true;
  if (argc == 2 && std::wstring(argv[1]) == L"--apply-direct") {
    apply_ok = ApplyDirectBaseline();
  } else if (argc == 2 && std::wstring(argv[1]) == L"--delete-marker") {
    apply_ok = DeleteMarker();
  }
  ::ReleaseMutex(mutex);
  ::CloseHandle(mutex);
  return ok && query_ok && apply_ok ? 0 : 1;
}
