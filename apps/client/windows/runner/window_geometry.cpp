#include "window_geometry.h"

#include <flutter/standard_method_codec.h>

#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue RectValue(const RECT& r) {
  return EncodableValue(EncodableMap{
      {EncodableValue("x"), EncodableValue(static_cast<int>(r.left))},
      {EncodableValue("y"), EncodableValue(static_cast<int>(r.top))},
      {EncodableValue("width"), EncodableValue(static_cast<int>(r.right - r.left))},
      {EncodableValue("height"), EncodableValue(static_cast<int>(r.bottom - r.top))},
  });
}

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* list = reinterpret_cast<EncodableList*>(data);
  if (list->size() >= 16) return FALSE;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) return TRUE;
  UINT dpi = 96;
  // GetDpiForWindow/Monitor need newer headers; derive from a DC fallback.
  HDC dc = GetDC(nullptr);
  if (dc) {
    dpi = static_cast<UINT>(GetDeviceCaps(dc, LOGPIXELSX));
    ReleaseDC(nullptr, dc);
  }
  list->push_back(EncodableValue(EncodableMap{
      {EncodableValue("bounds"), RectValue(info.rcMonitor)},
      {EncodableValue("work"), RectValue(info.rcWork)},
      {EncodableValue("primary"), EncodableValue((info.dwFlags & MONITORINFOF_PRIMARY) != 0)},
      {EncodableValue("dpi"), EncodableValue(static_cast<int>(dpi))},
  }));
  return TRUE;
}

// WINDOWPLACEMENT uses workspace coordinates for ordinary top-level
// windows, while our channel and SetWindowPos use screen coordinates.
// Keep WINDOWPLACEMENT itself unchanged for SetWindowPlacement on uncover.
bool NormalScreenRect(HWND window, const WINDOWPLACEMENT& placement, RECT* normal) {
  *normal = placement.rcNormalPosition;
  if ((GetWindowLongPtr(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info))
    return false;
  OffsetRect(normal, info.rcWork.left - info.rcMonitor.left,
             info.rcWork.top - info.rcMonitor.top);
  return true;
}

bool SetStyle(HWND window, LONG_PTR style) {
  SetLastError(ERROR_SUCCESS);
  return SetWindowLongPtr(window, GWL_STYLE, style) != 0 || GetLastError() == ERROR_SUCCESS;
}

bool ReadRect(const EncodableValue* args, RECT* out) {
  const auto* map = std::get_if<EncodableMap>(args);
  if (!map) return false;
  int values[4];
  const char* keys[4] = {"x", "y", "width", "height"};
  for (int i = 0; i < 4; i++) {
    const auto item = map->find(EncodableValue(keys[i]));
    if (item == map->end()) return false;
    const auto* number = std::get_if<int>(&item->second);
    if (!number) return false;
    values[i] = *number;
  }
  if (values[2] < 200 || values[3] < 150 || values[2] > 32766 || values[3] > 32766 ||
      values[0] < -32766 || values[1] < -32766 || values[0] > 32766 || values[1] > 32766)
    return false;
  *out = RECT{values[0], values[1], values[0] + values[2], values[1] + values[3]};
  return true;
}

}  // namespace

WindowGeometryChannel::WindowGeometryChannel(flutter::BinaryMessenger* messenger,
                                             std::function<HWND()> window)
    : window_(std::move(window)) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "atermius/window_geometry", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

WindowGeometryChannel::~WindowGeometryChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

void WindowGeometryChannel::Handle(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const HWND window = window_();
  DWORD process = 0;
  if (!window || !IsWindow(window) ||
      !GetWindowThreadProcessId(window, &process) || process != GetCurrentProcessId()) {
    result->Error("window_unavailable", "Window is closed");
    return;
  }
  const auto& method = call.method_name();
  if (method == "getMonitors") {
    EncodableList monitors;
    EnumDisplayMonitors(nullptr, nullptr, CollectMonitor, reinterpret_cast<LPARAM>(&monitors));
    result->Success(EncodableValue(monitors));
  } else if (method == "getBounds") {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    RECT current{};
    if (!GetWindowPlacement(window, &placement) || !GetWindowRect(window, &current)) {
      result->Error("geometry_unavailable", "Window placement unavailable");
      return;
    }
    // When covering a monitor, report the saved normal placement so restore
    // never captures the borderless state as the window's own bounds.
    RECT normal = saved_normal_screen_;
    if (!covering_ && !NormalScreenRect(window, placement, &normal)) {
      result->Error("geometry_unavailable", "Normal placement unavailable");
      return;
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("bounds"), RectValue(current)},
        {EncodableValue("normal"), RectValue(normal)},
        {EncodableValue("maximized"), EncodableValue(placement.showCmd == SW_SHOWMAXIMIZED)},
        {EncodableValue("minimized"), EncodableValue(placement.showCmd == SW_SHOWMINIMIZED)},
        {EncodableValue("covering"), EncodableValue(covering_)},
    }));
  } else if (method == "setBounds") {
    RECT rect{};
    if (!ReadRect(call.arguments(), &rect)) {
      result->Error("invalid_bounds", "Bounds out of range");
      return;
    }
    // Refuse bounds that are not on any current monitor (e.g. a saved layout
    // from a disconnected display) instead of placing the window off-screen.
    if (!MonitorFromRect(&rect, MONITOR_DEFAULTTONULL)) {
      result->Success(EncodableValue(false));
      return;
    }
    if (covering_ && !Uncover(window)) {
      result->Success(EncodableValue(false));
      return;
    }
    if (IsZoomed(window) || IsIconic(window)) ShowWindow(window, SW_RESTORE);
    const BOOL moved = SetWindowPos(window, nullptr, rect.left, rect.top, rect.right - rect.left,
                                    rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
    result->Success(EncodableValue(moved != FALSE));
  } else if (method == "coverMonitor") {
    RECT rect{};
    if (!ReadRect(call.arguments(), &rect)) {
      result->Error("invalid_bounds", "Bounds out of range");
      return;
    }
    // Only an exact current monitor rectangle can be covered.
    HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!monitor || !GetMonitorInfo(monitor, &info) || !EqualRect(&info.rcMonitor, &rect)) {
      result->Success(EncodableValue(false));
      return;
    }
    result->Success(EncodableValue(Cover(window, rect)));
  } else if (method == "uncover") {
    result->Success(EncodableValue(!covering_ || Uncover(window)));
  } else {
    result->NotImplemented();
  }
}

bool WindowGeometryChannel::Cover(HWND window, const RECT& monitor) {
  const bool was_covering = covering_;
  RECT previous{};
  if (!GetWindowRect(window, &previous)) return false;
  if (!covering_) {
    saved_placement_ = WINDOWPLACEMENT{};
    saved_placement_.length = sizeof(saved_placement_);
    if (!GetWindowPlacement(window, &saved_placement_) ||
        !NormalScreenRect(window, saved_placement_, &saved_normal_screen_)) return false;
    saved_style_ = GetWindowLongPtr(window, GWL_STYLE);
    // A maximized/minimized style must not override the exact monitor rect.
    // The original show state is restored by SetWindowPlacement on uncover.
    if (IsZoomed(window) || IsIconic(window)) ShowWindow(window, SW_RESTORE);
  }
  const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  if (SetStyle(window, style & ~(WS_CAPTION | WS_THICKFRAME)) &&
      SetWindowPos(window, nullptr, monitor.left, monitor.top,
                   monitor.right - monitor.left, monitor.bottom - monitor.top,
                   SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER)) {
    covering_ = true;
    return true;
  }
  // Do not strand a failed first cover in a borderless/partially moved state.
  if (!was_covering) {
    covering_ = true;
    Uncover(window);
  } else {
    SetWindowPos(window, nullptr, previous.left, previous.top,
                 previous.right - previous.left, previous.bottom - previous.top,
                 SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  }
  return false;
}

bool WindowGeometryChannel::Uncover(HWND window) {
  if (!SetStyle(window, saved_style_)) return false;
  const BOOL framed = SetWindowPos(window, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
      SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  const BOOL placed = SetWindowPlacement(window, &saved_placement_);
  if (!framed || !placed) return false;
  covering_ = false;
  return true;
}
