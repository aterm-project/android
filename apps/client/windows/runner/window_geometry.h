#ifndef RUNNER_WINDOW_GEOMETRY_H_
#define RUNNER_WINDOW_GEOMETRY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>

// "atermius/window_geometry": read/restore this window's own bounds and list
// monitors. Used by RDP monitor windows and saved window combinations. Acts
// only on this process's top-level window; never on other windows or on
// display settings.
class WindowGeometryChannel {
 public:
  WindowGeometryChannel(flutter::BinaryMessenger* messenger,
                        std::function<HWND()> window);
  ~WindowGeometryChannel();

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool Cover(HWND window, const RECT& monitor);
  bool Uncover(HWND window);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<HWND()> window_;
  bool covering_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_{};
  RECT saved_normal_screen_{};
};

#endif  // RUNNER_WINDOW_GEOMETRY_H_
