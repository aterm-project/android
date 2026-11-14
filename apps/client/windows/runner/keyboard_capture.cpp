#include "keyboard_capture.h"

#include <flutter/standard_method_codec.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <variant>

#include "utils.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Window messages (UI thread).
//
// A key event the hook thread posts to the window:
// WPARAM = virtual key | down flag | extended flag | modifiers << 10 |
//          generation << 16,
// LPARAM = hardware scan code | event time << 32.
constexpr UINT kKeyMessage = WM_APP + 0x2B1;
// The hook thread asks the window to release every forwarded key.
constexpr UINT kReleaseMessage = WM_APP + 0x2B2;
constexpr WPARAM kVirtualKeyMask = 0xFF;
constexpr WPARAM kDownFlag = 0x100;
constexpr WPARAM kExtendedFlag = 0x200;
// Dart's modifier bits (Shift 1, Control 2, Alt 4), see LocalModifiers().
constexpr int kModifierShift = 10;
constexpr WPARAM kModifierMask = 0x7;
constexpr int kShiftBit = 1;
constexpr int kControlBit = 2;
constexpr int kAltBit = 4;
constexpr int kGenerationShift = 16;
constexpr WPARAM kGenerationMask = 0xFFFF;
constexpr int kTimeShift = 32;
constexpr uint64_t kScanMask = 0xFFFFFFFF;
static_assert(sizeof(LPARAM) >= 8, "key events carry their time in LPARAM");

// Thread messages (hook thread). kSyncMessage re-reads the published state;
// WPARAM != 0 also replaces the hook.
constexpr UINT kSyncMessage = WM_APP + 1;
constexpr UINT kQuitMessage = WM_APP + 2;

// Hook thread timing, in milliseconds.
constexpr UINT kTickMs = 100;
// A longer gap between ticks means the hook thread was not running. Windows
// passes an event on when the hook misses LowLevelHooksTimeout and (Windows
// 7 and later) silently removes the hook.
constexpr ULONGLONG kStallMs = 250;
// A hook without callbacks for this long is replaced: Windows gives no
// notice when it removes one.
constexpr ULONGLONG kRefreshMs = 1000;
// A key released early (to Dart) stays swallowed until its physical release,
// or until it has sent no event for this long. Held keys auto-repeat at
// least every 400 ms after a delay of at most 1 s.
constexpr ULONGLONG kDrainMs = 1500;

// Keyboard messages dispatched at most ahead of one captured key.
constexpr int kMaxDispatchedInput = 64;

UINT KeyId(UINT vk, bool extended) {
  return (vk & 0xFF) | (extended ? 0x100u : 0u);
}

bool IsKeyInput(UINT message) {
  return message == WM_KEYDOWN || message == WM_KEYUP ||
         message == WM_SYSKEYDOWN || message == WM_SYSKEYUP;
}

// IME and input-mode toggles. Some keyboards report only their press, so
// they are forwarded as a press and release at once.
bool IsToggleKey(UINT vk) {
  switch (vk) {
  case 0x15: // VK_KANA / VK_HANGUL
  case 0x16: // VK_IME_ON
  case 0x19: // VK_KANJI / VK_HANJA
  case 0x1A: // VK_IME_OFF
  case 0xF0: // VK_OEM_ATTN (Japanese Eisu)
  case 0xF1: // VK_OEM_FINISH (Katakana)
  case 0xF2: // VK_OEM_COPY (Hiragana)
  case 0xF3: // VK_OEM_AUTO (Hankaku/Zenkaku)
  case 0xF4: // VK_OEM_ENLW (Hankaku/Zenkaku)
  case 0xF5: // VK_OEM_BACKTAB (Romaji)
    return true;
  default:
    return false;
  }
}

// Whether the OS has |vk| down. Read in the hook, the async key state does
// not include the event being decided yet (it is updated after the hooks
// ran), and keys the hook swallowed never reach it.
bool DownLocally(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

// Shift, Control and Alt the OS has down (Dart's modifier bits). These keys
// reach Dart through Flutter, which handles one key event at a time and may
// deliver them after a captured key that followed them; Dart holds such a
// captured press back until Flutter has delivered them.
int LocalModifiers() {
  return (DownLocally(VK_SHIFT) ? kShiftBit : 0) |
         (DownLocally(VK_CONTROL) ? kControlBit : 0) |
         (DownLocally(VK_MENU) ? kAltBit : 0);
}

// Whether any user input happened at or after |tick| (GetTickCount64).
bool InputSince(ULONGLONG tick) {
  LASTINPUTINFO info{sizeof(LASTINPUTINFO), 0};
  if (!GetLastInputInfo(&info)) {
    return true;
  }
  return static_cast<LONG>(info.dwTime - static_cast<DWORD>(tick)) >= 0;
}

// Unmodified, lowercased base character of |vk| in the active layout, or ""
// for keys without a printable one.
std::string BaseCharacter(UINT vk) {
  // The top bit marks dead keys; the character itself is in the low word.
  const UINT mapped = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0x7FFFFFFF;
  wchar_t text[2] = {static_cast<wchar_t>(mapped & 0xFFFF), L'\0'};
  if (text[0] < 0x20 || text[0] == 0x7F) {
    return std::string();
  }
  CharLowerBuffW(text, 1);
  return Utf8FromUtf16(text);
}

} // namespace

// The low-level keyboard hook and the thread it runs on. The hook is called
// on the thread that installed it, through that thread's message loop, so
// this thread never waits for the UI thread or Dart. It decides each event
// from the state the UI thread publishes (armed and active, generation) and
// the keys it swallowed itself, and posts captured keys to the window.
class KeyboardCapture::HookThread {
public:
  explicit HookThread(HWND window);
  ~HookThread();

  HookThread(const HookThread &) = delete;
  HookThread &operator=(const HookThread &) = delete;

  // UI thread. |armed|: Dart armed capture and the window is active.
  // |reinstall| replaces the hook, which also restores one Windows removed.
  void Update(bool armed, bool reinstall);

  // UI thread, before Dart is told that every forwarded key is up. Events
  // posted earlier are dropped; the keys stay swallowed until their release.
  void NewGeneration() { generation_.fetch_add(1); }
  UINT CurrentGeneration() const { return generation_.load(); }

private:
  struct Key {
    // Its press was swallowed and its release has not been seen.
    bool held = false;
    // Forwarded as a press and release at once; the rest is only swallowed.
    bool toggle = false;
    // Generation it was forwarded in. Once that is over, the key is only
    // swallowed until its release or |deadline|.
    UINT generation = 0;
    ULONGLONG deadline = 0;
  };

  static LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam);

  void Run();
  void Sync(bool reinstall);
  void Tick();
  bool OnKey(WPARAM message, const KBDLLHOOKSTRUCT &event);
  bool Gate() const;
  bool ShouldCapture(UINT vk, const KBDLLHOOKSTRUCT &event) const;
  bool Held(UINT vk) const;
  void Post(UINT vk, bool down, const KBDLLHOOKSTRUCT &event, UINT generation,
            int modifiers = 0) const;
  void Clear(Key &key);
  void Drain(ULONGLONG now);
  bool Install(ULONGLONG now);
  void Uninstall();
  void HookLost() const;

  // One low-level hook per process.
  static std::atomic<HookThread *> owner_;

  const HWND window_;
  // Published by the UI thread.
  std::atomic<bool> armed_{false};
  std::atomic<UINT> generation_{0};

  std::mutex start_mutex_;
  std::condition_variable started_;
  DWORD thread_id_ = 0;
  std::thread thread_;

  // Hook thread only.
  HHOOK hook_ = nullptr;
  UINT_PTR timer_ = 0;
  ULONGLONG last_tick_ = 0;
  ULONGLONG last_event_ = 0;
  ULONGLONG last_install_ = 0;
  std::array<Key, kKeyIds> keys_{};
  size_t held_ = 0;
};

std::atomic<KeyboardCapture::HookThread *> KeyboardCapture::HookThread::owner_{
    nullptr};

KeyboardCapture::HookThread::HookThread(HWND window) : window_(window) {
  thread_ = std::thread([this] {
    MSG msg;
    // Creates this thread's message queue before anyone posts to it.
    PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    {
      std::lock_guard<std::mutex> lock(start_mutex_);
      thread_id_ = GetCurrentThreadId();
      started_.notify_one();
    }
    Run();
  });
  std::unique_lock<std::mutex> lock(start_mutex_);
  started_.wait(lock, [this] { return thread_id_ != 0; });
}

KeyboardCapture::HookThread::~HookThread() {
  armed_.store(false);
  PostThreadMessageW(thread_id_, kQuitMessage, 0, 0);
  thread_.join();
}

void KeyboardCapture::HookThread::Update(bool armed, bool reinstall) {
  armed_.store(armed);
  PostThreadMessageW(thread_id_, kSyncMessage,
                     static_cast<WPARAM>(reinstall ? 1 : 0), 0);
}

void KeyboardCapture::HookThread::Run() {
  // The hook must answer within LowLevelHooksTimeout; it does little work.
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (msg.hwnd) {
      DispatchMessageW(&msg);
    } else if (msg.message == kQuitMessage) {
      break;
    } else if (msg.message == kSyncMessage) {
      Sync(msg.wParam != 0);
    } else if (msg.message == WM_TIMER) {
      Tick();
    }
  }
  Uninstall();
}

void KeyboardCapture::HookThread::Sync(bool reinstall) {
  const ULONGLONG now = GetTickCount64();
  Drain(now);
  if (!armed_.load() && held_ == 0) {
    Uninstall();
    return;
  }
  // Swallowed keys keep the hook alive after disarming until released.
  if ((!hook_ || reinstall) && Install(now)) {
    HookLost();
  }
  if (!timer_) {
    timer_ = SetTimer(nullptr, 0, kTickMs, nullptr);
    last_tick_ = now;
  }
}

void KeyboardCapture::HookThread::Tick() {
  const ULONGLONG now = GetTickCount64();
  const ULONGLONG previous = last_tick_;
  last_tick_ = now;
  if (previous != 0 && now - previous >= kStallMs && InputSince(previous)) {
    // This thread did not run for a while (system load, sleep) and a key may
    // have been pressed meanwhile: Windows may have timed the hook out and
    // removed it, and the releases it would have seen went to the OS.
    Install(now);
    HookLost();
  }
  Drain(now);
  if (!armed_.load() && held_ == 0) {
    Uninstall();
    return;
  }
  if (!hook_ ||
      (now - last_event_ >= kRefreshMs && now - last_install_ >= kRefreshMs)) {
    // Replacing an idle hook restores one Windows removed, and reveals that
    // it was removed (see Install).
    if (Install(now)) {
      HookLost();
    }
  }
}

// static
LRESULT CALLBACK KeyboardCapture::HookThread::HookProc(int code, WPARAM wparam,
                                                       LPARAM lparam) {
  HookThread *const owner = owner_.load();
  if (code == HC_ACTION && owner &&
      owner->OnKey(wparam,
                   *reinterpret_cast<const KBDLLHOOKSTRUCT *>(lparam))) {
    // Swallowed: neither the shell nor this window's Flutter view sees it.
    return 1;
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool KeyboardCapture::HookThread::OnKey(WPARAM message,
                                        const KBDLLHOOKSTRUCT &event) {
  const ULONGLONG now = GetTickCount64();
  last_event_ = now;
  const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  if ((!down && message != WM_KEYUP && message != WM_SYSKEYUP) ||
      (event.flags & LLKHF_INJECTED) != 0) {
    // Synthesized input is never captured and never ends a captured key.
    return false;
  }
  const UINT vk = static_cast<UINT>(event.vkCode & 0xFF);
  Key &key = keys_[KeyId(vk, (event.flags & LLKHF_EXTENDED) != 0)];
  const UINT generation = generation_.load();
  bool swallow = false;
  if (key.held && !key.toggle) {
    // The rest of a captured key's life (auto-repeat and release) belongs to
    // the remote as well, even if the gate has closed in the meantime. Once
    // Dart was told it is up, it is only swallowed: neither the local OS
    // (Start menu, Win+<key>) nor Dart sees it again.
    if (key.generation == generation) {
      Post(vk, down, event, generation);
    } else {
      key.deadline = now + kDrainMs;
    }
    if (!down) {
      Clear(key);
    }
    swallow = true;
  } else if (key.held && !down) {
    Clear(key); // The release of a forwarded toggle, if it reports one.
    swallow = true;
  } else {
    if (key.held) {
      Clear(key); // A toggle pressed again: it may never report a release.
    }
    // Only a fresh press starts a capture. A key the OS already has down was
    // pressed before the gate opened: its auto-repeat and release stay local,
    // or the OS would never see it go up (a Win key stuck down locally turns
    // later keys into Win+L, Win+D, ...). IME toggles may never report a
    // release, so their local state is not trusted.
    if (down && Gate() && ShouldCapture(vk, event) &&
        (IsToggleKey(vk) || !DownLocally(static_cast<int>(vk)))) {
      key.held = true;
      key.toggle = IsToggleKey(vk);
      key.generation = generation;
      key.deadline = key.toggle ? now + kDrainMs : 0;
      ++held_;
      Post(vk, true, event, generation, LocalModifiers());
      if (key.toggle) {
        Post(vk, false, event, generation);
      }
      swallow = true;
    }
  }
  if (held_ == 0 && !armed_.load()) {
    // Nothing left to drain: remove the hook (outside of this callback).
    PostThreadMessageW(GetCurrentThreadId(), kSyncMessage, 0, 0);
  }
  return swallow;
}

bool KeyboardCapture::HookThread::Gate() const {
  if (!armed_.load() || GetForegroundWindow() != window_) {
    return false;
  }
  POINT cursor{};
  RECT client{};
  return GetCursorPos(&cursor) && ScreenToClient(window_, &cursor) &&
         GetClientRect(window_, &client) && PtInRect(&client, cursor);
}

bool KeyboardCapture::HookThread::Held(UINT vk) const {
  return keys_[KeyId(vk, false)].held || keys_[KeyId(vk, true)].held;
}

bool KeyboardCapture::HookThread::ShouldCapture(
    UINT vk, const KBDLLHOOKSTRUCT &event) const {
  if (vk == VK_LWIN || vk == VK_RWIN || vk == VK_SNAPSHOT) {
    return true;
  }
  // Swallowed keys never reach the async key state, so every key pressed
  // while a Win key is held (Win+D, Win+Shift+S, ...) and modifiers that
  // were swallowed are decided from our own state.
  if (Held(VK_LWIN) || Held(VK_RWIN)) {
    return true;
  }
  // Alt+Tab, Alt+Shift+Tab, Alt+Esc, Alt+Space (system menu), Alt+F4.
  const bool alt = (event.flags & LLKHF_ALTDOWN) != 0 || Held(VK_LMENU) ||
                   Held(VK_RMENU);
  if (alt &&
      (vk == VK_TAB || vk == VK_ESCAPE || vk == VK_SPACE || vk == VK_F4)) {
    return true;
  }
  // Ctrl+Esc (Start) and Ctrl+Shift+Esc (Task Manager).
  return vk == VK_ESCAPE && ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
                             Held(VK_LCONTROL) || Held(VK_RCONTROL));
}

void KeyboardCapture::HookThread::Post(UINT vk, bool down,
                                       const KBDLLHOOKSTRUCT &event,
                                       UINT generation, int modifiers) const {
  const WPARAM stamp = static_cast<WPARAM>(generation) & kGenerationMask;
  WPARAM packed =
      (stamp << kGenerationShift) |
      ((static_cast<WPARAM>(modifiers) & kModifierMask) << kModifierShift) |
      (static_cast<WPARAM>(vk) & kVirtualKeyMask);
  if (down) {
    packed |= kDownFlag;
  }
  if ((event.flags & LLKHF_EXTENDED) != 0) {
    packed |= kExtendedFlag;
  }
  const uint64_t data = (static_cast<uint64_t>(event.time) << kTimeShift) |
                        (static_cast<uint64_t>(event.scanCode) & kScanMask);
  PostMessageW(window_, kKeyMessage, packed, static_cast<LPARAM>(data));
}

void KeyboardCapture::HookThread::Clear(Key &key) {
  if (key.held && held_ > 0) {
    --held_;
  }
  key = Key{};
}

void KeyboardCapture::HookThread::Drain(ULONGLONG now) {
  if (held_ == 0) {
    return;
  }
  const UINT generation = generation_.load();
  for (Key &key : keys_) {
    if (!key.held || (!key.toggle && key.generation == generation)) {
      continue;
    }
    if (key.deadline == 0) {
      key.deadline = now + kDrainMs;
    } else if (now >= key.deadline) {
      Clear(key); // Its release went unseen (or never comes).
    }
  }
}

// Installs a new hook ahead of the current one, then removes that one, so no
// event slips through. Returns true when the replaced hook was already gone:
// Windows removed it, and key releases may have been missed.
bool KeyboardCapture::HookThread::Install(ULONGLONG now) {
  HookThread *expected = nullptr;
  if (!owner_.compare_exchange_strong(expected, this) && expected != this) {
    return false; // Another window of this process holds the hook.
  }
  HHOOK const next = SetWindowsHookExW(WH_KEYBOARD_LL, HookProc,
                                       GetModuleHandleW(nullptr), 0);
  if (!next) {
    if (!hook_) {
      owner_.store(nullptr);
    }
    return false; // Retried by the next tick.
  }
  last_install_ = now;
  HHOOK const previous = hook_;
  hook_ = next;
  return previous && !UnhookWindowsHookEx(previous);
}

void KeyboardCapture::HookThread::Uninstall() {
  if (hook_) {
    UnhookWindowsHookEx(hook_);
    hook_ = nullptr;
  }
  if (owner_.load() == this) {
    owner_.store(nullptr); // Others only take it over from nullptr.
  }
  if (timer_) {
    KillTimer(nullptr, timer_);
    timer_ = 0;
  }
  last_tick_ = 0;
}

void KeyboardCapture::HookThread::HookLost() const {
  PostMessageW(window_, kReleaseMessage, 0, 0);
}

KeyboardCapture::KeyboardCapture(flutter::BinaryMessenger *messenger,
                                 HWND window)
    : window_(window) {
  active_ = window_ && GetForegroundWindow() == window_;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "atermius/keyboard_capture",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleCall(call, std::move(result));
  });
}

KeyboardCapture::~KeyboardCapture() {
  Shutdown();
  *alive_ = false;
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void KeyboardCapture::HandleCall(
    const flutter::MethodCall<EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto &method = call.method_name();
  if (method == "configure") {
    const auto args = call.arguments();
    const auto map = args ? std::get_if<EncodableMap>(args) : nullptr;
    if (!map) {
      result->Error("invalid_arguments", "Expected armed boolean");
      return;
    }
    const auto item = map->find(EncodableValue("armed"));
    if (item == map->end() || !std::holds_alternative<bool>(item->second)) {
      result->Error("invalid_arguments", "Expected armed boolean");
      return;
    }
    armed_ = std::get<bool>(item->second) && !shut_down_;
    active_ = GetForegroundWindow() == window_;
    if (!armed_ || !active_) {
      ReleaseKeys();
    }
    UpdateHook(/*reinstall=*/true);
    result->Success(State(false));
  } else if (method == "getState") {
    result->Success(State(true));
  } else if (method == "requestPermission") {
    // No permission is involved on Windows.
    result->Success(State(false));
  } else {
    result->NotImplemented();
  }
}

EncodableValue KeyboardCapture::State(bool include_focus) const {
  EncodableMap state{
      {EncodableValue("supported"), EncodableValue(true)},
      {EncodableValue("permission"), EncodableValue("notRequired")},
  };
  if (include_focus) {
    state[EncodableValue("windowFocused")] =
        EncodableValue(GetForegroundWindow() == window_);
  }
  return EncodableValue(state);
}

std::optional<LRESULT> KeyboardCapture::HandleMessage(UINT message,
                                                      WPARAM wparam,
                                                      LPARAM lparam) {
  switch (message) {
  case kKeyMessage:
    Deliver(wparam, lparam);
    return 0;
  case kReleaseMessage:
    // The hook was gone for a while; releases may have been missed.
    if (!shut_down_) {
      ReleaseKeys();
      UpdateHook(/*reinstall=*/false);
    }
    return 0;
  case WM_ACTIVATE:
    SetActive(LOWORD(wparam) != WA_INACTIVE);
    break;
  case WM_SYSCOMMAND:
    // Releasing Alt after a forwarded Alt combination (or F10) would put
    // this window into menu mode and swallow the next keys locally.
    if (armed_ && (wparam & 0xFFF0) == static_cast<WPARAM>(SC_KEYMENU)) {
      return 0;
    }
    break;
  }
  return std::nullopt;
}

void KeyboardCapture::Shutdown() {
  if (shut_down_) {
    return;
  }
  armed_ = false;
  ReleaseKeys();
  shut_down_ = true;
  pending_.clear();
  // Removes the hook (also for keys still held) and joins its thread.
  hook_.reset();
}

void KeyboardCapture::Deliver(WPARAM packed, LPARAM data) {
  pending_.emplace_back(packed, data);
  if (delivering_) {
    return; // Forwarded by the outer call, after the keys before it.
  }
  delivering_ = true;
  const std::shared_ptr<bool> alive = alive_;
  while (!pending_.empty() && !shut_down_) {
    const auto [next_packed, next_data] = pending_.front();
    pending_.pop_front();
    // Keyboard input is retrieved after posted messages. A modifier pressed
    // before a captured key (Alt for Alt+Tab, Ctrl for Ctrl+Esc) may still
    // be queued: dispatch it to Flutter first. Flutter may still hold it back
    // behind an earlier key event; the press carries the local modifiers so
    // Dart waits for them (see LocalModifiers).
    DispatchInputUntil(
        static_cast<DWORD>(static_cast<uint64_t>(next_data) >> kTimeShift),
        alive);
    if (!*alive) {
      return;
    }
    Forward(next_packed, next_data);
    if (!*alive) {
      return;
    }
  }
  pending_.clear();
  delivering_ = false;
}

// Dispatches queued keyboard input that happened no later than |event_time|,
// the time of a captured key event. Later input stays queued (a modifier
// released after the captured key must still follow it). Event times have
// the system timer's resolution, so input in the same tick counts as earlier.
void KeyboardCapture::DispatchInputUntil(DWORD event_time,
                                         const std::shared_ptr<bool> &alive) {
  MSG msg;
  for (int count = 0; count < kMaxDispatchedInput; ++count) {
    if (!PeekMessageW(&msg, nullptr, WM_KEYFIRST, WM_KEYLAST, PM_NOREMOVE)) {
      return;
    }
    // Character messages belong to a key that was dispatched already.
    if (IsKeyInput(msg.message) &&
        static_cast<LONG>(msg.time - event_time) > 0) {
      return;
    }
    if (!PeekMessageW(&msg, nullptr, WM_KEYFIRST, WM_KEYLAST, PM_REMOVE)) {
      return;
    }
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
    if (!*alive || shut_down_) {
      return;
    }
  }
}

void KeyboardCapture::Forward(WPARAM packed, LPARAM data) {
  if (shut_down_ || !hook_ ||
      ((packed >> kGenerationShift) & kGenerationMask) !=
          (static_cast<WPARAM>(hook_->CurrentGeneration()) & kGenerationMask)) {
    // Posted before the forwarded keys were released; replaying it would
    // press a key again that Dart was already told is up.
    return;
  }
  const UINT vk = static_cast<UINT>(packed & kVirtualKeyMask);
  const bool down = (packed & kDownFlag) != 0;
  const bool extended = (packed & kExtendedFlag) != 0;
  const UINT scan = static_cast<UINT>(static_cast<uint64_t>(data) & kScanMask);
  const UINT id = KeyId(vk, extended);
  if (down) {
    forwarded_.set(id);
    forwarded_scan_[id] = scan;
    SendKey(vk, true, scan, extended,
            static_cast<int>((packed >> kModifierShift) & kModifierMask));
  } else if (forwarded_.test(id)) {
    forwarded_.reset(id);
    SendKey(vk, false, scan, extended, 0);
  }
}

void KeyboardCapture::SendKey(UINT vk, bool down, UINT scan, bool extended,
                              int modifiers) {
  if (!channel_) {
    return;
  }
  channel_->InvokeMethod(
      "key", std::make_unique<EncodableValue>(EncodableMap{
                 {EncodableValue("platform"), EncodableValue("windows")},
                 {EncodableValue("down"), EncodableValue(down)},
                 {EncodableValue("code"), EncodableValue(static_cast<int>(vk))},
                 {EncodableValue("scan"),
                  EncodableValue(static_cast<int>(scan))},
                 {EncodableValue("extended"), EncodableValue(extended)},
                 {EncodableValue("char"), EncodableValue(BaseCharacter(vk))},
                 {EncodableValue("modifiers"), EncodableValue(modifiers)},
             }));
}

void KeyboardCapture::SetActive(bool active) {
  active_ = active;
  if (!active_) {
    ReleaseKeys();
  }
  UpdateHook(/*reinstall=*/active_);
  if (channel_) {
    channel_->InvokeMethod(
        "windowFocus", std::make_unique<EncodableValue>(EncodableMap{
                           {EncodableValue("focused"), EncodableValue(active)},
                       }));
  }
}

void KeyboardCapture::ReleaseKeys() {
  // Events the hook posted before this point are dropped; the released keys
  // stay swallowed until their physical release.
  if (hook_) {
    hook_->NewGeneration();
  }
  for (UINT id = 0; id < kKeyIds; ++id) {
    if (forwarded_.test(id)) {
      forwarded_.reset(id);
      SendKey(id & 0xFF, false, forwarded_scan_[id], (id & 0x100) != 0, 0);
    }
  }
}

void KeyboardCapture::UpdateHook(bool reinstall) {
  const bool wanted = armed_ && active_ && !shut_down_;
  if (!hook_) {
    if (!wanted) {
      return;
    }
    hook_ = std::make_unique<HookThread>(window_);
  }
  hook_->Update(wanted, reinstall && wanted);
}
