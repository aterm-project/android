// Session-0-only probe of the production channel through Flutter's real codec.
// Creates two own HWNDs; never enumerates or operates on another user's windows.
#include "window_geometry.h"
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

using flutter::EncodableMap;
using flutter::EncodableList;
using flutter::EncodableValue;

class Messenger final : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply reply = nullptr) const override {
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string& name,
                         flutter::BinaryMessageHandler handler) override {
    if (handler) handlers[name] = std::move(handler);
    else handlers.erase(name);
  }
  struct Reply {
    bool completed = false, success = false, unimplemented = false;
    std::string error;
    EncodableValue value;
  };
  Reply Call(const std::string& method, const EncodableValue* args = nullptr) {
    Reply response;
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto bytes = codec.EncodeMethodCall(flutter::MethodCall<EncodableValue>(
        method, args ? std::make_unique<EncodableValue>(*args) : nullptr));
    flutter::MethodResultFunctions<EncodableValue> result(
        [&](const EncodableValue* value) {
          response.completed = response.success = true;
          if (value) response.value = *value;
        },
        [&](const std::string& code, const std::string&, const EncodableValue*) {
          response.completed = true;
          response.error = code;
        },
        [&] { response.completed = response.unimplemented = true; });
    const auto found = handlers.find("atermius/window_geometry");
    if (found == handlers.end()) return response;
    found->second(bytes->data(), bytes->size(), [&](const uint8_t* data, size_t size) {
      if (!size) result.NotImplemented();
      else codec.DecodeAndProcessResponseEnvelope(data, size, &result);
    });
    return response;
  }
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
};

static int failures = 0, checks = 0;
static void Check(bool ok, const char* name) {
  ++checks;
  if (!ok) { ++failures; std::fprintf(stderr, "FAIL %s (win32=%lu)\n", name, GetLastError()); }
}
static EncodableValue RectArg(const RECT& r) {
  return EncodableValue(EncodableMap{
      {EncodableValue("x"), EncodableValue(static_cast<int>(r.left))},
      {EncodableValue("y"), EncodableValue(static_cast<int>(r.top))},
      {EncodableValue("width"), EncodableValue(static_cast<int>(r.right-r.left))},
      {EncodableValue("height"), EncodableValue(static_cast<int>(r.bottom-r.top))}});
}
static const EncodableValue* Field(const EncodableValue& value, const char* key) {
  const auto* map = std::get_if<EncodableMap>(&value);
  if (!map) return nullptr;
  const auto i = map->find(EncodableValue(key));
  return i == map->end() ? nullptr : &i->second;
}
static bool Flag(const EncodableValue& value, const char* key) {
  const auto* field = Field(value,key);
  const auto* flag = field ? std::get_if<bool>(field) : nullptr;
  return flag && *flag;
}
static bool Matches(const EncodableValue& value, const RECT& expected) {
  return value == RectArg(expected);
}
static bool BoundsMatch(const Messenger::Reply& reply, const char* field, const RECT& expected) {
  const auto* rect = Field(reply.value,field);
  return reply.success && rect && Matches(*rect,expected);
}
static bool BoolResult(const Messenger::Reply& reply, bool expected) {
  const auto* value = std::get_if<bool>(&reply.value);
  return reply.success && value && *value == expected;
}
static void Pump() {
  MSG message;
  while (PeekMessage(&message,nullptr,0,0,PM_REMOVE)) {
    TranslateMessage(&message); DispatchMessage(&message);
  }
}

int main() {
  DWORD session = ~0u;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session != 0) return 90;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const HINSTANCE module = GetModuleHandle(nullptr);
  WNDCLASSW cls{};
  cls.lpfnWndProc = DefWindowProcW;
  cls.hInstance = module;
  cls.lpszClassName = L"AtermiusGeometryOwnWindowProbe";
  if (!RegisterClassW(&cls)) return 91;
  MONITORINFO monitor{};
  monitor.cbSize=sizeof(monitor);
  if (!GetMonitorInfo(MonitorFromPoint(POINT{0,0},MONITOR_DEFAULTTOPRIMARY),&monitor)) return 92;
  const int width=static_cast<int>(monitor.rcWork.right-monitor.rcWork.left);
  const int height=static_cast<int>(monitor.rcWork.bottom-monitor.rcWork.top);
  if (width<320 || height<240) return 93;
  HWND first=CreateWindowExW(0,cls.lpszClassName,L"Geometry probe",WS_OVERLAPPEDWINDOW,
      monitor.rcWork.left+10,monitor.rcWork.top+10,300,200,nullptr,nullptr,module,nullptr);
  HWND second=CreateWindowExW(WS_EX_TOOLWINDOW,cls.lpszClassName,L"Geometry untouched peer",
      WS_OVERLAPPEDWINDOW,monitor.rcWork.left+20,monitor.rcWork.top+20,280,180,nullptr,nullptr,module,nullptr);
  if (!first || !second) return 94;
  ShowWindow(first,SW_SHOWNOACTIVATE); ShowWindow(second,SW_SHOWNOACTIVATE); Pump();
  RECT peer{}; GetWindowRect(second,&peer);
  const LONG_PTR peer_style=GetWindowLongPtr(second,GWL_STYLE);
  const LONG_PTR peer_ex=GetWindowLongPtr(second,GWL_EXSTYLE);
  WINDOWPLACEMENT peer_placement{}; peer_placement.length=sizeof(peer_placement);
  GetWindowPlacement(second,&peer_placement);
  {
    Messenger messenger;
    HWND target=first;
    WindowGeometryChannel channel(&messenger,[&]{return target;});
    auto monitors=messenger.Call("getMonitors");
    const auto* list=std::get_if<EncodableList>(&monitors.value);
    Check(monitors.success && list && !list->empty() && list->size()<=16,"codec monitor list");
    RECT original{}; GetWindowRect(first,&original);
    auto bounds=messenger.Call("getBounds");
    Check(BoundsMatch(bounds,"bounds",original),"current screen bounds");
    Check(BoundsMatch(bounds,"normal",original),"normal screen bounds (workspace offset)");
    // Tool windows use screen rather than workspace placement coordinates.
    { Messenger tool_messenger; WindowGeometryChannel tool(&tool_messenger,[&]{return second;});
      Check(BoundsMatch(tool_messenger.Call("getBounds"),"normal",peer),"tool-window screen normal"); }

    const RECT desired{monitor.rcWork.left+15,monitor.rcWork.top+15,
                       monitor.rcWork.left+315,monitor.rcWork.top+215};
    auto arg=RectArg(desired);
    Check(BoolResult(messenger.Call("setBounds",&arg),true),"set normal bounds");
    Check(BoundsMatch(messenger.Call("getBounds"),"normal",desired),"set/read normal roundtrip");
    ShowWindow(first,SW_MAXIMIZE); Pump();
    bounds=messenger.Call("getBounds");
    Check(Flag(bounds.value,"maximized") && BoundsMatch(bounds,"normal",desired),"max retains screen normal");
    const auto monitor_arg=RectArg(monitor.rcMonitor);
    Check(BoolResult(messenger.Call("coverMonitor",&monitor_arg),true),"cover from maximized");
    bounds=messenger.Call("getBounds");
    Check(Flag(bounds.value,"covering") && !Flag(bounds.value,"maximized") &&
          BoundsMatch(bounds,"bounds",monitor.rcMonitor) && BoundsMatch(bounds,"normal",desired),
          "cover exact monitor, saved screen normal, normal show state");
    Check(BoolResult(messenger.Call("uncover"),true),"uncover success");
    bounds=messenger.Call("getBounds");
    Check(!Flag(bounds.value,"covering") && Flag(bounds.value,"maximized") &&
          BoundsMatch(bounds,"normal",desired),"uncover restores maximize and original normal");
    Check(BoolResult(messenger.Call("setBounds",&arg),true),"set bounds restores from maximize");
    bounds=messenger.Call("getBounds");
    Check(!Flag(bounds.value,"maximized") && BoundsMatch(bounds,"bounds",desired),"restored final screen rectangle");

    ShowWindow(first,SW_MINIMIZE); Pump();
    Check(BoundsMatch(messenger.Call("getBounds"),"normal",desired),"minimized normal screen bounds");
    Check(BoolResult(messenger.Call("coverMonitor",&monitor_arg),true),"cover from minimized");
    Check(BoundsMatch(messenger.Call("getBounds"),"bounds",monitor.rcMonitor),"minimized cover exact monitor");
    Check(BoolResult(messenger.Call("uncover"),true) && IsIconic(first),"uncover restores minimized");
    Check(BoolResult(messenger.Call("setBounds",&arg),true),"restore minimized by setBounds");

    RECT not_monitor=monitor.rcMonitor; --not_monitor.right;
    auto invalid_cover=RectArg(not_monitor);
    Check(BoolResult(messenger.Call("coverMonitor",&invalid_cover),false),"non-exact monitor rejected");
    auto malformed=EncodableValue(EncodableMap{{EncodableValue("x"),EncodableValue(0)}});
    Check(messenger.Call("setBounds",&malformed).error=="invalid_bounds","malformed bounds rejected");
    auto undersized=RectArg(RECT{0,0,199,149});
    Check(messenger.Call("setBounds",&undersized).error=="invalid_bounds","undersized bounds rejected");
    const RECT candidates[]={{32700,32700,32900,32850},{-32766,-32766,-32566,-32616}};
    bool offscreen_checked=false;
    for (const auto& candidate:candidates) {
      if (!MonitorFromRect(&candidate,MONITOR_DEFAULTTONULL)) {
        auto outside=RectArg(candidate);
        Check(BoolResult(messenger.Call("setBounds",&outside),false),"removed/offscreen monitor rejected");
        offscreen_checked=true; break;
      }
    }
    Check(offscreen_checked,"offscreen test rectangle available");
    Check(BoundsMatch(messenger.Call("getBounds"),"bounds",desired),"rejected requests leave own bounds unchanged");
    Check(messenger.Call("unknown").unimplemented,"unknown method fallback");
    target=nullptr;
    Check(messenger.Call("getBounds").error=="window_unavailable","null HWND fallback");
    target=first;
    Check(BoolResult(messenger.Call("uncover"),true),"uncover idempotent");
    RECT after{}; GetWindowRect(second,&after);
    WINDOWPLACEMENT after_placement{}; after_placement.length=sizeof(after_placement);
    GetWindowPlacement(second,&after_placement);
    Check(EqualRect(&peer,&after) && peer_style==GetWindowLongPtr(second,GWL_STYLE) &&
          peer_ex==GetWindowLongPtr(second,GWL_EXSTYLE) &&
          EqualRect(&peer_placement.rcNormalPosition,&after_placement.rcNormalPosition) &&
          peer_placement.showCmd==after_placement.showCmd,"second own window never mutated");
  }
  DestroyWindow(first); DestroyWindow(second); UnregisterClassW(cls.lpszClassName,module);
  std::printf("{\"passed\":%s,\"session\":0,\"checks\":%d,\"failures\":%d,"
              "\"workspace_offset_x\":%ld,\"workspace_offset_y\":%ld}\n",
      failures ? "false":"true",checks,failures,
      monitor.rcWork.left-monitor.rcMonitor.left,monitor.rcWork.top-monitor.rcMonitor.top);
  return failures ? 1:0;
}
