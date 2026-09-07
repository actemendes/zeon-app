#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "startup_diagnostics.h"
#include "system_proxy_recovery.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  WriteStartupMarker("flutter_window_on_create_begin");
  if (!Win32Window::OnCreate()) {
    WriteStartupMarker("flutter_window_base_create_failed");
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  WriteStartupMarker("flutter_controller_create_begin");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  WriteStartupMarker("flutter_controller_created");
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    WriteStartupMarker("flutter_controller_invalid");
    return false;
  }
  WriteStartupMarker("flutter_controller_valid");
  WriteStartupMarker("plugins_register_begin");
  RegisterPlugins(flutter_controller_->engine());
  WriteStartupMarker("plugins_registered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  WriteStartupMarker("flutter_child_attached");

  flutter_controller_->engine()->SetNextFrameCallback([]() {
    WriteStartupMarker("flutter_first_frame");
    // this->Show(); window_manager hidden at launch
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();
  WriteStartupMarker("flutter_force_redraw_requested");

  return true;
}

void FlutterWindow::OnDestroy() {
  // Core shutdown normally restores its recorded baseline. This synchronous
  // runner fallback covers forced window teardown while the current process
  // still owns the exact ZEON loopback proxy.
  RecoverZeonSystemProxy(true);

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_ENDSESSION && wparam) {
    // Windows grants only a bounded shutdown window. Restore synchronously;
    // the ownership check prevents changes to user/corporate proxy state.
    RecoverZeonSystemProxy(true);
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
