#include "flutter_window.h"

#include <optional>
#include <wininet.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The core enables the WinINet proxy for System Proxy mode. Windows can end
// the process during logoff/reboot before the core gets a chance to stop,
// leaving the proxy pointed at a now-dead localhost listener. Disable it from
// the runner as a synchronous, last-resort cleanup so the next Windows session
// retains direct Internet access even when ZEON is not launched.
void DisableSystemProxy() {
  INTERNET_PER_CONN_OPTION option{};
  option.dwOption = INTERNET_PER_CONN_FLAGS;
  option.Value.dwValue = PROXY_TYPE_DIRECT;

  INTERNET_PER_CONN_OPTION_LIST option_list{};
  option_list.dwSize = sizeof(option_list);
  option_list.pszConnection = nullptr;
  option_list.dwOptionCount = 1;
  option_list.pOptions = &option;

  InternetSetOption(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                    &option_list, sizeof(option_list));
  InternetSetOption(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOption(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Recover from an interrupted previous Windows shutdown before Flutter and
  // the core are initialized. The active connection, if any, will set the
  // proxy again after the core starts.
  DisableSystemProxy();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // this->Show(); window_manager hidden at launch
    "";
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DisableSystemProxy();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // WM_ENDSESSION is sent only after Windows confirms the session is ending.
  // Do this before dispatching to Flutter: teardown time is limited and Dart
  // cleanup is asynchronous.
  if (message == WM_ENDSESSION && wparam) {
    DisableSystemProxy();
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
