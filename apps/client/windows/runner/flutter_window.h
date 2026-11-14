#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "keyboard_capture.h"
#include "win32_window.h"
#include "window_geometry.h"
#include "window_identity.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |kind| selects the taskbar identity (icon and group) of the window.
  explicit FlutterWindow(const flutter::DartProject &project,
                         WindowKind kind = WindowKind::kMain);
  virtual ~FlutterWindow();

protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

private:
  flutter::EncodableValue ChromeState();
  void NotifyChromeState();
  // Teardown that needs the live HWND and engine (WM_DESTROY at the latest).
  void ReleaseWindowResources(HWND window);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      chrome_channel_;
  std::unique_ptr<WindowGeometryChannel> geometry_channel_;
  std::unique_ptr<KeyboardCapture> keyboard_capture_;
  TaskbarIdentity taskbar_identity_;

  bool close_guard_enabled_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif // RUNNER_FLUTTER_WINDOW_H_
