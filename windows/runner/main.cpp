#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl_core.h>

#include <chrono>
#include <fstream>
#include <string>
#include <thread>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"
// #include <protocol_handler_windows/protocol_handler_windows_plugin_c_api.h>

constexpr wchar_t kZeonAppUserModelId[] = L"ZEON.ZEON";
constexpr wchar_t kZeonMutexName[] = L"ZEONMutex";
constexpr wchar_t kZeonWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kZeonWindowTitle[] = L"ZEON";

void WriteStartupMarker(const char* marker)
{
  wchar_t path[32768] = {};
  const DWORD length = ::GetEnvironmentVariableW(
      L"ZEON_STARTUP_DIAGNOSTICS_FILE", path, ARRAYSIZE(path));
  if (length == 0 || length >= ARRAYSIZE(path))
  {
    return;
  }

  std::ofstream stream(path, std::ios::app);
  if (!stream)
  {
    return;
  }
  stream << ::GetTickCount64() << " pid=" << ::GetCurrentProcessId()
         << " marker=" << marker << '\n';
}

void HardenDllSearchPath()
{
  // Keep application DLLs loadable while removing the current working
  // directory from the process-wide search order. Resolve dynamically so the
  // runner remains compatible with systems where the API is unavailable.
  HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll");
  if (kernel32 != nullptr)
  {
    using SetDefaultDllDirectoriesFn = BOOL(WINAPI *)(DWORD);
    auto set_default_dll_directories = reinterpret_cast<SetDefaultDllDirectoriesFn>(
        ::GetProcAddress(kernel32, "SetDefaultDllDirectories"));
    if (set_default_dll_directories != nullptr)
    {
      set_default_dll_directories(
          LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
          LOAD_LIBRARY_SEARCH_SYSTEM32 |
          LOAD_LIBRARY_SEARCH_USER_DIRS);
    }
  }
  ::SetDllDirectoryW(L"");
}

HWND FindZeonWindow()
{
  return ::FindWindowW(kZeonWindowClass, kZeonWindowTitle);
}

bool ActivateExistingInstance(HWND hwnd)
{
  if (hwnd == nullptr)
  {
    return false;
  }

  SendAppLink(hwnd);

  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  if (::GetWindowPlacement(hwnd, &place) && place.showCmd == SW_SHOWMINIMIZED)
  {
    ::ShowWindow(hwnd, SW_RESTORE);
  }
  else
  {
    ::ShowWindow(hwnd, SW_SHOW);
  }

  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  ::SetForegroundWindow(hwnd);
  WriteStartupMarker("existing_instance_activated");
  return true;
}

bool WaitForAndActivateExistingInstance()
{
  // The primary process owns the mutex before Flutter creates its HWND.
  // Bound the wait so a crashed primary can never leave secondary launches
  // blocked indefinitely.
  for (int attempt = 0; attempt < 100; ++attempt)
  {
    if (ActivateExistingInstance(FindZeonWindow()))
    {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command)
{
  HardenDllSearchPath();
  SetCurrentProcessExplicitAppUserModelID(kZeonAppUserModelId);
  WriteStartupMarker("process_entry");

  if (ActivateExistingInstance(FindZeonWindow()))
  {
    return EXIT_SUCCESS;
  }

  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kZeonMutexName);
  if (instance_mutex == nullptr)
  {
    WriteStartupMarker("mutex_create_failed");
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS)
  {
    WriteStartupMarker("secondary_waiting_for_window");
    const bool activated = WaitForAndActivateExistingInstance();
    ::CloseHandle(instance_mutex);
    WriteStartupMarker(activated ? "secondary_exit_success"
                                 : "secondary_window_timeout");
    return activated ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  WriteStartupMarker("primary_mutex_acquired");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent())
  {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ZEON", origin, size))
  {
    WriteStartupMarker("window_create_failed");
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  WriteStartupMarker("window_created");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0))
  {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::ReleaseMutex(instance_mutex);
  ::CloseHandle(instance_mutex);
  WriteStartupMarker("process_exit_clean");
  return EXIT_SUCCESS;
}
