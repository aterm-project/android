#include "window_identity.h"

// Defines (rather than only declares) the PKEY_AppUserModel_* keys used
// below; DECLSPEC_SELECTANY keeps them link-safe in any other unit.
#include <initguid.h>
#include <propkey.h>

#include <propsys.h>
#include <propvarutil.h>
#include <shellapi.h>

#include <cstring>  // memset behind PropVariantInit

#include "resource.h"

namespace {

constexpr char kDesktopWindowArgument[] = "--desktop-window-port=";
constexpr char kTerminalWindowArgument[] = "--terminal-window-port=";
constexpr char kFilesWindowArgument[] = "--files-window";

bool StartsWith(const std::string &value, const char *prefix) {
  return value.rfind(prefix, 0) == 0;
}

struct KindDetails {
  int icon_resource;
  const wchar_t *app_user_model_id;
  const wchar_t *display_name;
};

KindDetails DetailsFor(WindowKind kind) {
  if (kind == WindowKind::kRemoteDesktop) {
    return {IDI_REMOTE_DESKTOP_ICON, L"Atermius.RemoteDesktop",
            L"Atermius Remote Desktop"};
  }
  return {IDI_SESSION_ICON, L"Atermius.Session", L"Atermius Sessions"};
}

using LoadIconWithScaleDownProc = HRESULT(WINAPI *)(HINSTANCE, PCWSTR, int,
                                                    int, HICON *);

// LoadIconWithScaleDown lives in comctl32 v6; this executable does not opt
// into v6 by manifest, so resolve it at runtime instead of importing it.
LoadIconWithScaleDownProc ResolveLoadIconWithScaleDown() {
  HMODULE comctl32 = GetModuleHandleW(L"comctl32.dll");
  if (!comctl32) {
    return nullptr;
  }
  return reinterpret_cast<LoadIconWithScaleDownProc>(
      GetProcAddress(comctl32, "LoadIconWithScaleDown"));
}

// Returns an owned icon (DestroyIcon) of |size| x |size| px, scaled down from
// the closest larger frame of the resource when there is no exact frame.
HICON LoadIconAtSize(int resource, int size) {
  if (size <= 0) {
    return nullptr;
  }
  static const LoadIconWithScaleDownProc load_scaled =
      ResolveLoadIconWithScaleDown();
  HINSTANCE instance = GetModuleHandleW(nullptr);
  HICON icon = nullptr;
  if (load_scaled &&
      SUCCEEDED(load_scaled(instance, MAKEINTRESOURCEW(resource), size, size,
                            &icon)) &&
      icon) {
    return icon;
  }
  return static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(resource),
                                       IMAGE_ICON, size, size,
                                       LR_DEFAULTCOLOR));
}

std::wstring ExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  while (path.size() <= 32768) {
    const DWORD length =
        GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
  return std::wstring();
}

// Swaps the window's icon for |type| and destroys the one this object owned.
void ReplaceIcon(HWND window, WPARAM type, HICON icon, HICON *owned) {
  SendMessageW(window, WM_SETICON, type, reinterpret_cast<LPARAM>(icon));
  if (*owned && *owned != icon) {
    DestroyIcon(*owned);
  }
  *owned = icon;
}

} // namespace

WindowKind WindowKindFromArguments(const std::vector<std::string> &arguments) {
  bool session = false;
  for (const auto &argument : arguments) {
    if (StartsWith(argument, kDesktopWindowArgument)) {
      return WindowKind::kRemoteDesktop;
    }
    if (StartsWith(argument, kTerminalWindowArgument) ||
        StartsWith(argument, kFilesWindowArgument)) {
      session = true;
    }
  }
  return session ? WindowKind::kSession : WindowKind::kMain;
}

TaskbarIdentity::TaskbarIdentity(WindowKind kind) : kind_(kind) {}

TaskbarIdentity::~TaskbarIdentity() {
  // The window is gone by now; only the icon handles remain to free.
  if (big_icon_) {
    DestroyIcon(big_icon_);
  }
  if (small_icon_) {
    DestroyIcon(small_icon_);
  }
}

void TaskbarIdentity::Apply(HWND window) {
  if (kind_ == WindowKind::kMain || !window) {
    return;
  }
  UpdateIcons(window, GetDpiForWindow(window));
  SetProperties(window, true);
}

void TaskbarIdentity::UpdateIcons(HWND window, UINT dpi) {
  if (kind_ == WindowKind::kMain || !window) {
    return;
  }
  if (dpi == 0) {
    dpi = USER_DEFAULT_SCREEN_DPI;
  }
  const int resource = DetailsFor(kind_).icon_resource;
  if (HICON icon =
          LoadIconAtSize(resource, GetSystemMetricsForDpi(SM_CXICON, dpi))) {
    ReplaceIcon(window, ICON_BIG, icon, &big_icon_);
  }
  if (HICON icon =
          LoadIconAtSize(resource, GetSystemMetricsForDpi(SM_CXSMICON, dpi))) {
    ReplaceIcon(window, ICON_SMALL, icon, &small_icon_);
  }
}

void TaskbarIdentity::Release(HWND window) {
  if (window && IsWindow(window)) {
    if (properties_set_) {
      SetProperties(window, false);
    }
    // Detach before destroying so the window never refers to a freed icon.
    if (big_icon_) {
      ReplaceIcon(window, ICON_BIG, nullptr, &big_icon_);
    }
    if (small_icon_) {
      ReplaceIcon(window, ICON_SMALL, nullptr, &small_icon_);
    }
  }
}

void TaskbarIdentity::SetProperties(HWND window, bool set) {
  IPropertyStore *store = nullptr;
  if (FAILED(SHGetPropertyStoreForWindow(window, IID_PPV_ARGS(&store))) ||
      !store) {
    return;
  }
  const KindDetails details = DetailsFor(kind_);
  if (set) {
    // Relaunch details and pinning first: the taskbar reads them when the ID
    // is assigned. These windows are ephemeral (bound to a live session), so
    // they cannot be pinned and have no relaunch command.
    properties_set_ = true;
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(InitPropVariantFromBoolean(TRUE, &value))) {
      store->SetValue(PKEY_AppUserModel_PreventPinning, value);
      PropVariantClear(&value);
    }
    const std::wstring executable = ExecutablePath();
    if (!executable.empty()) {
      const std::wstring icon =
          executable + L",-" + std::to_wstring(details.icon_resource);
      if (SUCCEEDED(InitPropVariantFromString(icon.c_str(), &value))) {
        store->SetValue(PKEY_AppUserModel_RelaunchIconResource, value);
        PropVariantClear(&value);
      }
    }
    if (SUCCEEDED(InitPropVariantFromString(details.display_name, &value))) {
      store->SetValue(PKEY_AppUserModel_RelaunchDisplayNameResource, value);
      PropVariantClear(&value);
    }
    if (SUCCEEDED(
            InitPropVariantFromString(details.app_user_model_id, &value))) {
      store->SetValue(PKEY_AppUserModel_ID, value);
      PropVariantClear(&value);
    }
  } else {
    // Documented requirement: remove the window's AppUserModel properties
    // (VT_EMPTY) before the window is destroyed.
    PROPVARIANT empty;
    PropVariantInit(&empty);
    store->SetValue(PKEY_AppUserModel_ID, empty);
    store->SetValue(PKEY_AppUserModel_RelaunchIconResource, empty);
    store->SetValue(PKEY_AppUserModel_RelaunchDisplayNameResource, empty);
    store->SetValue(PKEY_AppUserModel_PreventPinning, empty);
    properties_set_ = false;
  }
  store->Commit();
  store->Release();
}
