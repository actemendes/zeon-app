#include "system_proxy_recovery.h"
#include "system_proxy_recovery_logic.h"
#include "system_proxy_recovery_registry.h"

#include <windows.h>
#include <wininet.h>

#include <cstdint>
#include <string>

namespace {

constexpr wchar_t kRecoveryKey[] =
    L"Software\\ZEON\\SystemProxyRecovery";
constexpr wchar_t kRunOnceKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
constexpr wchar_t kRunOnceValue[] = L"ZEONSystemProxyRecovery";
constexpr wchar_t kRecoveryMutex[] =
    L"Local\\ZEONSystemProxyRecoveryMutex";
constexpr DWORD kRecoverySchema = 1;

using ProxyState = zeon::system_proxy::ProxyState;

struct OwnershipRecord {
  DWORD owner_pid = 0;
  std::uint64_t owner_creation_time = 0;
  std::uint64_t generation = 0;
  DWORD mixed_port = 0;
  std::wstring executable_path;
  ProxyState baseline;
  ProxyState expected;
};

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE value) : value_(value) {}
  ~ScopedHandle() {
    if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) {
      ::CloseHandle(value_);
    }
  }
  HANDLE get() const { return value_; }

 private:
  HANDLE value_;
};

class ScopedRegistryKey {
 public:
  explicit ScopedRegistryKey(HKEY value) : value_(value) {}
  ~ScopedRegistryKey() {
    if (value_ != nullptr) {
      ::RegCloseKey(value_);
    }
  }
  HKEY get() const { return value_; }

 private:
  HKEY value_;
};

bool ReadDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD size = sizeof(*value);
  return ::RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, nullptr, value,
                        &size) == ERROR_SUCCESS;
}

bool ReadQword(HKEY key, const wchar_t* name, std::uint64_t* value) {
  DWORD size = sizeof(*value);
  return ::RegGetValueW(key, nullptr, name, RRF_RT_REG_QWORD, nullptr, value,
                        &size) == ERROR_SUCCESS;
}

bool ReadString(HKEY key, const wchar_t* name, std::wstring* value) {
  return zeon::system_proxy::ReadRegistryString(key, name, value);
}

bool ReadProxyState(HKEY key, const wchar_t* prefix, ProxyState* state) {
  const std::wstring base(prefix);
  DWORD flags = 0;
  const bool success =
      ReadDword(key, (base + L"Flags").c_str(), &flags) &&
      ReadString(key, (base + L"ProxyServer").c_str(),
                 &state->proxy_server) &&
      ReadString(key, (base + L"ProxyBypass").c_str(),
                 &state->proxy_bypass) &&
      ReadString(key, (base + L"AutoConfigURL").c_str(),
                 &state->auto_config_url);
  state->flags = flags;
  return success;
}

bool ReadOwnershipRecord(OwnershipRecord* record, bool* found) {
  HKEY raw_key = nullptr;
  const LSTATUS open_status = ::RegOpenKeyExW(
      HKEY_CURRENT_USER, kRecoveryKey, 0, KEY_QUERY_VALUE, &raw_key);
  if (open_status == ERROR_FILE_NOT_FOUND) {
    *found = false;
    return true;
  }
  if (open_status != ERROR_SUCCESS) {
    return false;
  }
  ScopedRegistryKey key(raw_key);
  DWORD schema = 0;
  DWORD armed = 0;
  if (!ReadDword(key.get(), L"Armed", &armed) || armed != 1) {
    // Armed is committed last and before WinINet is changed. An interrupted
    // record write cannot own the current proxy.
    *found = false;
    return true;
  }
  if (!ReadDword(key.get(), L"Schema", &schema) || schema != kRecoverySchema ||
      !ReadDword(key.get(), L"OwnerPid", &record->owner_pid) ||
      !ReadQword(key.get(), L"OwnerCreationTime",
                 &record->owner_creation_time) ||
      !ReadQword(key.get(), L"Generation", &record->generation) ||
      record->generation == 0 ||
      !ReadDword(key.get(), L"MixedPort", &record->mixed_port) ||
      !ReadString(key.get(), L"ExecutablePath", &record->executable_path) ||
      !ReadProxyState(key.get(), L"Baseline", &record->baseline) ||
      !ReadProxyState(key.get(), L"Expected", &record->expected)) {
    return false;
  }
  *found = true;
  return true;
}

bool ArmRecoveryRunOnce(const std::wstring& executable_path) {
  if (executable_path.empty() || executable_path.find(L'"') !=
                                     std::wstring::npos) {
    return false;
  }
  HKEY raw_key = nullptr;
  DWORD disposition = 0;
  const LSTATUS status = ::RegCreateKeyExW(
      HKEY_CURRENT_USER, kRunOnceKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
      &raw_key, &disposition);
  if (status != ERROR_SUCCESS) {
    return false;
  }
  ScopedRegistryKey key(raw_key);
  const std::wstring command =
      L"\"" + executable_path + L"\" --recover-system-proxy";
  return ::RegSetValueExW(
             key.get(), kRunOnceValue, 0, REG_SZ,
             reinterpret_cast<const BYTE*>(command.c_str()),
             static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

std::wstring CopyAndFreeWinInetString(LPWSTR value) {
  if (value == nullptr) {
    return L"";
  }
  std::wstring copy(value);
  ::GlobalFree(value);
  return copy;
}

bool QueryProxyState(ProxyState* state) {
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
  if (!::InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, &size)) {
    return false;
  }
  state->flags = options[0].Value.dwValue;
  state->proxy_server = CopyAndFreeWinInetString(options[1].Value.pszValue);
  state->proxy_bypass = CopyAndFreeWinInetString(options[2].Value.pszValue);
  state->auto_config_url =
      CopyAndFreeWinInetString(options[3].Value.pszValue);
  return true;
}

bool SetProxyState(const ProxyState& state) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = state.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue =
      const_cast<wchar_t*>(state.proxy_server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue =
      const_cast<wchar_t*>(state.proxy_bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue =
      const_cast<wchar_t*>(state.auto_config_url.c_str());

  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = ARRAYSIZE(options);
  list.pOptions = options;
  return ::InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, sizeof(list)) &&
         ::InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED,
                              nullptr, 0) &&
         ::InternetSetOptionW(nullptr,
                              INTERNET_OPTION_PROXY_SETTINGS_CHANGED, nullptr,
                              0) &&
         ::InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

bool DeleteRecoveryState() {
  const LSTATUS delete_status = zeon::system_proxy::DeleteRegistryTree(
      HKEY_CURRENT_USER, L"Software\\ZEON", L"SystemProxyRecovery");
  if (delete_status != ERROR_SUCCESS &&
      delete_status != ERROR_FILE_NOT_FOUND) {
    return false;
  }

  HKEY raw_run_once = nullptr;
  const LSTATUS run_once_status = ::RegOpenKeyExW(
      HKEY_CURRENT_USER, kRunOnceKey, 0, KEY_SET_VALUE, &raw_run_once);
  if (run_once_status == ERROR_FILE_NOT_FOUND) {
    return true;
  }
  if (run_once_status != ERROR_SUCCESS) {
    return false;
  }
  ScopedRegistryKey run_once(raw_run_once);
  const LSTATUS delete_value_status =
      ::RegDeleteValueW(run_once.get(), kRunOnceValue);
  return delete_value_status == ERROR_SUCCESS ||
         delete_value_status == ERROR_FILE_NOT_FOUND;
}

std::uint64_t FileTimeValue(const FILETIME& value) {
  return static_cast<std::uint64_t>(value.dwHighDateTime) << 32 |
         value.dwLowDateTime;
}

bool IsRecordedOwnerRunning(const OwnershipRecord& record) {
  ScopedHandle process(::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                     record.owner_pid));
  if (process.get() == nullptr) {
    return false;
  }
  FILETIME creation = {};
  FILETIME exit = {};
  FILETIME kernel = {};
  FILETIME user = {};
  if (!::GetProcessTimes(process.get(), &creation, &exit, &kernel, &user)) {
    // Failure to prove that the PID is stale must not tear down a potentially
    // live ZEON connection.
    return true;
  }
  return FileTimeValue(creation) == record.owner_creation_time;
}

}  // namespace

SystemProxyRecoveryResult RecoverZeonSystemProxy(
    bool allow_current_process_owner) noexcept {
  ScopedHandle mutex(::CreateMutexW(nullptr, FALSE, kRecoveryMutex));
  if (mutex.get() == nullptr) {
    return SystemProxyRecoveryResult::kMutexFailed;
  }
  const DWORD wait = ::WaitForSingleObject(mutex.get(), 5000);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
    return SystemProxyRecoveryResult::kMutexFailed;
  }

  OwnershipRecord record;
  bool found = false;
  SystemProxyRecoveryResult result =
      SystemProxyRecoveryResult::kRecordReadFailed;
  if (!ReadOwnershipRecord(&record, &found)) {
    result = SystemProxyRecoveryResult::kRecordReadFailed;
  } else if (!found) {
    result = SystemProxyRecoveryResult::kNoRecord;
  } else {
    const bool current_owner = record.owner_pid == ::GetCurrentProcessId();
    ProxyState current;
    if (!QueryProxyState(&current)) {
      result = SystemProxyRecoveryResult::kProxyQueryFailed;
    } else {
      const zeon::system_proxy::RecoveryDecision decision =
          zeon::system_proxy::DecideRecovery(
              current, record.expected, record.mixed_port,
              IsRecordedOwnerRunning(record),
              allow_current_process_owner && current_owner);
      if (decision ==
          zeon::system_proxy::RecoveryDecision::kWaitForLiveOwner) {
        result = SystemProxyRecoveryResult::kOwnerStillRunning;
      } else if (decision ==
                 zeon::system_proxy::RecoveryDecision::kRejectInvalidMarker) {
        result = SystemProxyRecoveryResult::kInvalidMarker;
      } else if (decision ==
                 zeon::system_proxy::RecoveryDecision::kPreserveForeignState) {
        result = DeleteRecoveryState()
                     ? SystemProxyRecoveryResult::kForeignStatePreserved
                     : SystemProxyRecoveryResult::kStateCleanupFailed;
      } else if (!SetProxyState(record.baseline)) {
        // RunOnce deletes its value before launching us. Re-arm on a transient
        // WinINet failure so the next logon can retry from the intact marker.
        ArmRecoveryRunOnce(record.executable_path);
        result = SystemProxyRecoveryResult::kProxyRestoreFailed;
      } else {
        result = DeleteRecoveryState()
                     ? SystemProxyRecoveryResult::kBaselineRestored
                     : SystemProxyRecoveryResult::kStateCleanupFailed;
      }
    }
  }
  ::ReleaseMutex(mutex.get());
  return result;
}
