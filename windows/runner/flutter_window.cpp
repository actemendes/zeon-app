#include "flutter_window.h"

#include <cstdint>
#include <optional>

#include <flutter/standard_method_codec.h>

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
  caption_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "zeon/window_caption",
          &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setCaptionAppearance") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("invalid_arguments", "Expected caption colors");
          return;
        }
        const auto read_color = [args](const char* key)
            -> std::optional<COLORREF> {
          const auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return std::nullopt;
          uint32_t argb;
          if (const auto* int32_value = std::get_if<int32_t>(&it->second)) {
            argb = static_cast<uint32_t>(*int32_value);
          } else if (const auto* int64_value =
                         std::get_if<int64_t>(&it->second)) {
            argb = static_cast<uint32_t>(*int64_value);
          } else {
            return std::nullopt;
          }
          return RGB((argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff);
        };
        const auto background = read_color("background");
        const auto foreground = read_color("foreground");
        const auto dark_it = args->find(flutter::EncodableValue("dark"));
        const auto* dark = dark_it == args->end()
                               ? nullptr
                               : std::get_if<bool>(&dark_it->second);
        if (!background || !foreground || !dark) {
          result->Error("invalid_arguments", "Expected colors and brightness");
          return;
        }
        SetCaptionAppearance(*background, *foreground, *dark);
        result->Success();
      });
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

  caption_channel_.reset();
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
