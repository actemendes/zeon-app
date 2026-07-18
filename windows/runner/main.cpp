#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl_core.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"
// #include <protocol_handler_windows/protocol_handler_windows_plugin_c_api.h>

constexpr wchar_t kZeonAppUserModelId[] = L"ZEON.ZEON";

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

bool SendAppLinkToInstance(const std::wstring &title)
{
  // Find our exact window
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  if (hwnd)
  {
    // Dispatch new link to current window
    SendAppLink(hwnd);

    // (Optional) Restore our window to front in same state
    WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
    GetWindowPlacement(hwnd, &place);

    switch (place.showCmd)
    {
    case SW_SHOWMAXIMIZED:
      ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      break;
    case SW_SHOWMINIMIZED:
      ShowWindow(hwnd, SW_RESTORE);
      break;
    default:
      ShowWindow(hwnd, SW_NORMAL);
      break;
    }

    SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);
    // END (Optional) Restore

    // Window has been found, don't create another one.
    return true;
  }

  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command)
{
  HardenDllSearchPath();
  SetCurrentProcessExplicitAppUserModelID(kZeonAppUserModelId);

  // Replace "example" with the generated title found as parameter of `window.Create` in this file.
  // You may ignore the result if you need to create another window.
  if (SendAppLinkToInstance(L"ZEON"))
  {
    return EXIT_SUCCESS;
  }

  HANDLE hMutexInstance = CreateMutex(NULL, TRUE, L"ZEONMutex");
  HWND handle = FindWindowA(NULL, "ZEON");

  if (GetLastError() == ERROR_ALREADY_EXISTS)
  {
    flutter::DartProject project(L"data");
    std::vector<std::string> command_line_arguments = GetCommandLineArguments();
    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
    FlutterWindow window(project);
    if (window.SendAppLinkToInstance(L"ZEON"))
    {
      return false;
    }

    WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
    GetWindowPlacement(handle, &place);
    ShowWindow(handle, SW_NORMAL);
    return 0;
  }

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
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0))
  {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ReleaseMutex(hMutexInstance);
  return EXIT_SUCCESS;
}
