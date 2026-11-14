#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject &project,
                             WindowKind kind)
    : taskbar_identity_(kind), project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // Before the first Show(): the taskbar groups the window by these.
  taskbar_identity_.Apply(GetHandle());

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

  geometry_channel_ = std::make_unique<WindowGeometryChannel>(
      flutter_controller_->engine()->messenger(), [this]() { return GetHandle(); });
  keyboard_capture_ = std::make_unique<KeyboardCapture>(
      flutter_controller_->engine()->messenger(), GetHandle());
  chrome_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "atermius/window_chrome",
          &flutter::StandardMethodCodec::GetInstance());
  chrome_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue> &call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto window = GetHandle();
        if (!window) {
          result->Error("window_unavailable", "Window is closed");
          return;
        }
        const auto &method = call.method_name();
        if (method == "enable") {
          SetCustomChrome(true);
          result->Success(ChromeState());
        } else if (method == "getState") {
          result->Success(ChromeState());
        } else if (method == "minimize") {
          ShowWindow(window, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          result->Success();
          PostMessage(window, WM_SYSCOMMAND, SC_CLOSE, 0);
        } else if (method == "enableCloseGuard") {
          const auto args = call.arguments();
          const auto map =
              args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
          if (!map) {
            result->Error("invalid_arguments", "Expected enabled boolean");
            return;
          }
          const auto item = map->find(flutter::EncodableValue("enabled"));
          if (item == map->end() ||
              !std::holds_alternative<bool>(item->second)) {
            result->Error("invalid_arguments", "Expected enabled boolean");
            return;
          }
          close_guard_enabled_ = std::get<bool>(item->second);
          result->Success();
        } else if (method == "hide") {
          ShowWindow(window, SW_HIDE);
          result->Success();
        } else if (method == "show") {
          ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
          SetForegroundWindow(window);
          result->Success();
        } else if (method == "closeNow") {
          close_guard_enabled_ = false;
          result->Success();
          PostMessage(window, WM_CLOSE, 0, 0);
        } else if (method == "beginDrag") {
          POINT point{};
          GetCursorPos(&point);
          ReleaseCapture();
          result->Success();
          PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION,
                      MAKELPARAM(point.x, point.y));
        } else if (method == "showSystemMenu") {
          POINT point{};
          GetCursorPos(&point);
          HMENU menu = GetSystemMenu(window, FALSE);
          const bool zoomed = IsZoomed(window) != FALSE;
          EnableMenuItem(menu, SC_RESTORE,
                         MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
          EnableMenuItem(menu, SC_MAXIMIZE,
                         MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          EnableMenuItem(menu, SC_SIZE,
                         MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          const UINT command =
              TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x,
                             point.y, 0, window, nullptr);
          result->Success();
          if (command)
            PostMessage(window, WM_SYSCOMMAND, command, 0);
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ReleaseWindowResources(GetHandle());
  geometry_channel_.reset();
  keyboard_capture_.reset();
  chrome_channel_.reset();
  Win32Window::OnDestroy();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Before the Dart handshake, closing remains standard Windows behavior.
  // Once enabled, every close route (including Alt+F4 / SC_CLOSE) reaches Dart.
  if (message == WM_CLOSE && close_guard_enabled_ && chrome_channel_) {
    chrome_channel_->InvokeMethod("closeRequested", nullptr);
    return 0;
  }
  if (message == WM_DESTROY) {
    ReleaseWindowResources(hwnd);
  } else if (keyboard_capture_) {
    // Forwarded keys, activation (capture follows foreground) and menu mode.
    if (const auto handled =
            keyboard_capture_->HandleMessage(message, wparam, lparam)) {
      return *handled;
    }
  }
  if (message == WM_DPICHANGED) {
    taskbar_identity_.UpdateIcons(hwnd, LOWORD(wparam));
  }
  // Frame layout must be resolved before plugin handlers consume NC messages.
  if (custom_chrome_enabled() &&
      (message == WM_NCCALCSIZE || message == WM_GETMINMAXINFO ||
       message == WM_NCHITTEST)) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  if (message == WM_SIZE || message == WM_ACTIVATE ||
      message == WM_DPICHANGED || message == WM_SETTINGCHANGE ||
      message == WM_THEMECHANGED) {
    // Plugins may consume a message; the caption must still observe OS state.
    // DPI, non-client metric (SPI_SETNONCLIENTMETRICS) and theme changes
    // alter the native caption height that Flutter mirrors.
    UpdateWindowCorners();
    NotifyChromeState();
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
    if (flutter_controller_)
      flutter_controller_->engine()->ReloadSystemFonts();
    break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

flutter::EncodableValue FlutterWindow::ChromeState() {
  const auto window = GetHandle();
  flutter::EncodableMap state{
      {flutter::EncodableValue("enabled"),
       flutter::EncodableValue(custom_chrome_enabled())},
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(window && IsZoomed(window) != FALSE)},
      {flutter::EncodableValue("minimized"),
       flutter::EncodableValue(window && IsIconic(window) != FALSE)},
      {flutter::EncodableValue("focused"),
       flutter::EncodableValue(window && GetForegroundWindow() == window)},
  };
  // Own-window system metric only; omitted when unavailable so Dart keeps its
  // fallback instead of receiving an invented height.
  const double caption_height = CaptionHeightLogical();
  if (caption_height > 0) {
    state[flutter::EncodableValue("captionHeight")] =
        flutter::EncodableValue(caption_height);
  }
  return flutter::EncodableValue(state);
}

void FlutterWindow::ReleaseWindowResources(HWND window) {
  // Forwarded keys are released to Dart while the engine can still hear it.
  if (keyboard_capture_) {
    keyboard_capture_->Shutdown();
  }
  if (window) {
    taskbar_identity_.Release(window);
  }
}

void FlutterWindow::NotifyChromeState() {
  if (chrome_channel_) {
    chrome_channel_->InvokeMethod(
        "stateChanged",
        std::make_unique<flutter::EncodableValue>(ChromeState()));
  }
}
