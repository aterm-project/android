#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See:
/// https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] =
    L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling *>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

} // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar *GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t *GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar *instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar *WindowClassRegistrar::instance_ = nullptr;

const wchar_t *WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() { ++g_active_window_count; }

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring &title, const Point &origin,
                         const Size &size) {
  Destroy();

  const wchar_t *window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() { return ShowWindow(window_handle_, SW_SHOWNORMAL); }

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT *>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window *>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window *that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
  case WM_NCCALCSIZE:
    // WS_CAPTION/THICKFRAME/SYSMENU remain set for native resize, taskbar,
    // Alt+Space, Alt+F4 and Windows snapping. Only the visible NC layout goes.
    if (custom_chrome_enabled_) {
      // A maximized overlapped window includes invisible resize borders outside
      // rcWork. Keep Flutter's client inside the monitor work area even though
      // the native outer frame may extend beyond it.
      if (IsZoomed(hwnd)) {
        auto client = wparam
                          ? &reinterpret_cast<NCCALCSIZE_PARAMS *>(lparam)->rgrc[0]
                          : reinterpret_cast<RECT *>(lparam);
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (GetMonitorInfo(MonitorFromRect(client, MONITOR_DEFAULTTONEAREST),
                           &monitor)) {
          RECT visible_client;
          if (IntersectRect(&visible_client, client, &monitor.rcWork))
            *client = visible_client;
        }
      }
      return 0;
    }
    break;
  case WM_NCHITTEST:
    if (custom_chrome_enabled_)
      return HitTestResizeBorder(lparam);
    break;
  case WM_GETMINMAXINFO:
    if (custom_chrome_enabled_) {
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                         &monitor)) {
        auto limits = reinterpret_cast<MINMAXINFO *>(lparam);
        limits->ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
        limits->ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
        limits->ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
        limits->ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
        return 0;
      }
    }
    break;
  case WM_DESTROY:
    window_handle_ = nullptr;
    Destroy();
    if (quit_on_close_) {
      PostQuitMessage(0);
    }
    return 0;

  case WM_DPICHANGED: {
    auto newRectSize = reinterpret_cast<RECT *>(lparam);
    LONG newWidth = newRectSize->right - newRectSize->left;
    LONG newHeight = newRectSize->bottom - newRectSize->top;

    SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                 newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

    return 0;
  }
  case WM_SIZE: {
    UpdateWindowCorners();
    RECT rect = GetClientArea();
    if (child_content_ != nullptr) {
      // Size and position the child window.
      MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, TRUE);
    }
    return 0;
  }

  case WM_ACTIVATE:
    if (child_content_ != nullptr) {
      SetFocus(child_content_);
    }
    return 0;

  case WM_DWMCOLORIZATIONCOLORCHANGED:
    UpdateTheme(hwnd);
    return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window *Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window *>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  child_subclass_installed_ =
      SetWindowSubclass(content, ChildSubclassProc, 1,
                        reinterpret_cast<DWORD_PTR>(this)) != FALSE;
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() { return window_handle_; }

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  if (child_content_ && IsWindow(child_content_)) {
    RemoveWindowSubclass(child_content_, ChildSubclassProc, 1);
  }
  child_content_ = nullptr;
  child_subclass_installed_ = false;
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result =
      RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                  kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr,
                  &light_mode, &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::SetCustomChrome(bool enabled) {
  // Keep the original native frame if edge forwarding could not be installed.
  if (enabled && !child_subclass_installed_)
    return;
  if (custom_chrome_enabled_ == enabled || !window_handle_)
    return;
  custom_chrome_enabled_ = enabled;
  MARGINS margins{enabled ? 1 : 0, enabled ? 1 : 0, enabled ? 1 : 0,
                  enabled ? 1 : 0};
  DwmExtendFrameIntoClientArea(window_handle_, &margins);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  UpdateWindowCorners();
}

double Win32Window::CaptionHeightLogical() const {
  if (!window_handle_)
    return 0;
  const UINT dpi = GetDpiForWindow(window_handle_);
  if (dpi == 0)
    return 0;
  const int caption = GetSystemMetricsForDpi(SM_CYCAPTION, dpi);
  const int frame = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                    GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  if (caption <= 0 || frame < 0)
    return 0;
  return static_cast<double>(caption + frame) * 96.0 /
         static_cast<double>(dpi);
}

void Win32Window::UpdateWindowCorners() {
  if (!window_handle_ || updating_corners_ || IsIconic(window_handle_))
    return;

  updating_corners_ = true;
  // Documented Windows 11 values. Numeric constants allow building against
  // older SDK headers; unsupported systems reject the attribute at runtime.
  constexpr DWORD kCornerPreferenceAttribute = 33;
  constexpr int kDefaultCorners = 0;
  constexpr int kSquareCorners = 1;
  constexpr int kRoundCorners = 2;
  const bool rounded = custom_chrome_enabled_ && !IsZoomed(window_handle_);
  const int preference = !custom_chrome_enabled_ ? kDefaultCorners
                         : rounded ? kRoundCorners : kSquareCorners;
  if (corner_preference_ != preference &&
      SUCCEEDED(DwmSetWindowAttribute(window_handle_,
          kCornerPreferenceAttribute, &preference, sizeof(preference)))) {
    corner_preference_ = preference;
  }

  if (!rounded) {
    // Maximized windows must fill the monitor work area without clipped gaps.
    if (corner_region_applied_ &&
        SetWindowRgn(window_handle_, nullptr, TRUE)) {
      corner_region_applied_ = false;
      corner_region_width_ = corner_region_height_ = 0;
    }
  } else {
    // DWM accepts the corner preference even when it declines to draw corners
    // (notably virtual machines and remote sessions). Enforce the same native
    // region for every restored app window; its Flutter child is clipped too.
    // Do not modify system-wide DWM settings or the user's remote session.
    RECT rect{};
    if (GetWindowRect(window_handle_, &rect)) {
      const int width = rect.right - rect.left;
      const int height = rect.bottom - rect.top;
      const UINT dpi = GetDpiForWindow(window_handle_);
      if (width > 0 && height > 0 &&
          (!corner_region_applied_ || width != corner_region_width_ ||
           height != corner_region_height_ || dpi != corner_region_dpi_)) {
        const int diameter = std::max(2, MulDiv(16, static_cast<int>(dpi), 96));
        HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                       diameter, diameter);
        if (region) {
          if (SetWindowRgn(window_handle_, region, TRUE)) {
            // SetWindowRgn takes ownership on success.
            corner_region_applied_ = true;
            corner_region_width_ = width;
            corner_region_height_ = height;
            corner_region_dpi_ = dpi;
          } else {
            DeleteObject(region);
          }
        }
      }
    }
  }
  updating_corners_ = false;
}

LRESULT Win32Window::HitTestResizeBorder(LPARAM position) const {
  if (!custom_chrome_enabled_ || !window_handle_ || IsZoomed(window_handle_) ||
      IsIconic(window_handle_))
    return HTCLIENT;
  RECT bounds{};
  if (!GetWindowRect(window_handle_, &bounds))
    return HTCLIENT;
  const UINT dpi = GetDpiForWindow(window_handle_);
  const int horizontal =
      std::max(1, GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                      GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi));
  const int vertical =
      std::max(1, GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                      GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi));
  const int x = GET_X_LPARAM(position);
  const int y = GET_Y_LPARAM(position);
  if (x < bounds.left || x >= bounds.right || y < bounds.top ||
      y >= bounds.bottom)
    return HTNOWHERE;
  const bool left = x >= bounds.left && x < bounds.left + horizontal;
  const bool right = x < bounds.right && x >= bounds.right - horizontal;
  const bool top = y >= bounds.top && y < bounds.top + vertical;
  const bool bottom = y < bounds.bottom && y >= bounds.bottom - vertical;
  if (top && left)
    return HTTOPLEFT;
  if (top && right)
    return HTTOPRIGHT;
  if (bottom && left)
    return HTBOTTOMLEFT;
  if (bottom && right)
    return HTBOTTOMRIGHT;
  if (left)
    return HTLEFT;
  if (right)
    return HTRIGHT;
  if (top)
    return HTTOP;
  if (bottom)
    return HTBOTTOM;
  return HTCLIENT;
}

LRESULT CALLBACK Win32Window::ChildSubclassProc(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam,
                                                UINT_PTR id,
                                                DWORD_PTR reference) {
  auto parent = reinterpret_cast<Win32Window *>(reference);
  if (parent && parent->custom_chrome_enabled() && message == WM_SYSKEYDOWN &&
      wparam == VK_F4 && (lparam & (static_cast<LPARAM>(1) << 29)) != 0) {
    // Alt+F4 belongs to the top-level window even while xterm owns key focus.
    PostMessage(parent->GetHandle(), WM_SYSCOMMAND, SC_CLOSE, 0);
    return 0;
  }

  if (message == WM_NCHITTEST && parent &&
      parent->HitTestResizeBorder(lparam) != HTCLIENT) {
    // Let the owning top-level HWND perform native non-client resizing. A hit
    // code returned directly by this child would resize the Flutter surface.
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY)
    RemoveWindowSubclass(window, ChildSubclassProc, id);
  return DefSubclassProc(window, message, wparam, lparam);
}
