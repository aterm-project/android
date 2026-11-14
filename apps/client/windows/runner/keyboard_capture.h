#ifndef RUNNER_KEYBOARD_CAPTURE_H_
#define RUNNER_KEYBOARD_CAPTURE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <array>
#include <bitset>
#include <deque>
#include <memory>
#include <optional>
#include <utility>

// "atermius/keyboard_capture": keyboard full-mapping mode for remote desktop
// sessions. While Dart has armed it, this window is the foreground window and
// the pointer is over its client area, a low-level keyboard hook takes the
// OS-reserved combinations (Win key and Win+any, Alt+Tab, Alt+Esc, Ctrl+Esc,
// Ctrl+Shift+Esc, Alt+Space, Alt+F4, PrintScreen) away from the shell and
// forwards them to Dart, which sends them to the remote computer. Plain
// modifiers keep reaching Flutter; a captured press reports the Shift, Ctrl
// and Alt the OS had down before it ("modifiers": 1, 2, 4), so Dart can hold
// it back until Flutter has delivered them. Only a fresh press is captured:
// a key already down locally stays local until its release. Ctrl+Alt+Del
// cannot be captured.
//
// The hook runs on a dedicated thread with its own message loop, so a busy
// UI thread (which also runs Dart) can never make Windows time it out. That
// thread decides every event on its own and posts captured keys to the
// window; this class, on the UI thread, forwards them to Dart and guarantees
// exactly one forwarded release for every forwarded press.
//
// Key data only travels in memory to Dart; it is never logged or stored.
class KeyboardCapture {
public:
  KeyboardCapture(flutter::BinaryMessenger *messenger, HWND window);
  ~KeyboardCapture();

  KeyboardCapture(const KeyboardCapture &) = delete;
  KeyboardCapture &operator=(const KeyboardCapture &) = delete;

  // Observes this window's top-level messages. Returns a result when the
  // message was consumed and must not be processed further.
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

  // Releases every forwarded key, removes the hook and stops its thread for
  // good. Call while the window and engine still exist (WM_DESTROY). Safe to
  // call repeatedly.
  void Shutdown();

private:
  // Owns the hook thread; defined in keyboard_capture.cpp.
  class HookThread;

  // Dart's identity of a key: virtual key | 0x100 for extended keys (main
  // and keypad Enter share VK_RETURN).
  static constexpr size_t kKeyIds = 0x200;

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableValue State(bool include_focus) const;

  void Deliver(WPARAM packed, LPARAM data);
  void DispatchInputUntil(DWORD event_time,
                          const std::shared_ptr<bool> &alive);
  void Forward(WPARAM packed, LPARAM data);
  void SendKey(UINT vk, bool down, UINT scan, bool extended, int modifiers);
  void SetActive(bool active);
  void ReleaseKeys();
  void UpdateHook(bool reinstall);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  const HWND window_;
  // Created on first arming; joined by Shutdown().
  std::unique_ptr<HookThread> hook_;
  bool armed_ = false;
  bool active_ = false;
  bool shut_down_ = false;
  // Cleared by the destructor, so a Deliver() that dispatched messages can
  // tell that it must not touch this object any more.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  // Posted key events waiting for Deliver(), oldest first (nested calls only
  // queue, so keys are forwarded in the order the hook saw them).
  std::deque<std::pair<WPARAM, LPARAM>> pending_;
  bool delivering_ = false;
  // Keys Dart has been told are down, by key id, with the scan code their
  // release must carry.
  std::bitset<kKeyIds> forwarded_;
  std::array<UINT, kKeyIds> forwarded_scan_{};
};

#endif // RUNNER_KEYBOARD_CAPTURE_H_
