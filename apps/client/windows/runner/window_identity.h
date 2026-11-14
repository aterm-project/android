#ifndef RUNNER_WINDOW_IDENTITY_H_
#define RUNNER_WINDOW_IDENTITY_H_

#include <windows.h>

#include <string>
#include <vector>

// What this process's window is. Detached windows are separate processes of
// the same executable; their command line says which kind they are.
enum class WindowKind {
  // Workspace window (also --new-window): executable icon, default taskbar
  // group.
  kMain,
  // --desktop-window-port=...: an RDP/VNC remote desktop.
  kRemoteDesktop,
  // --terminal-window-port=... / --files-window...: terminal-type sessions
  // (SSH, Telnet, serial, local shell) and file windows.
  kSession,
};

WindowKind WindowKindFromArguments(const std::vector<std::string> &arguments);

// Gives remote-desktop and session windows their own taskbar icon and group
// (a window-level AppUserModelID). The main window is left untouched.
class TaskbarIdentity {
public:
  explicit TaskbarIdentity(WindowKind kind);
  ~TaskbarIdentity();

  TaskbarIdentity(const TaskbarIdentity &) = delete;
  TaskbarIdentity &operator=(const TaskbarIdentity &) = delete;

  // Sets the icons and taskbar properties. Call once the window exists and
  // before it is first shown.
  void Apply(HWND window);

  // Reloads the icons at |dpi| (WM_DPICHANGED).
  void UpdateIcons(HWND window, UINT dpi);

  // Clears the taskbar properties and releases the icons. Must run before the
  // window is destroyed (WM_DESTROY at the latest). Safe to call repeatedly.
  void Release(HWND window);

private:
  void SetProperties(HWND window, bool set);

  const WindowKind kind_;
  HICON big_icon_ = nullptr;
  HICON small_icon_ = nullptr;
  bool properties_set_ = false;
};

#endif // RUNNER_WINDOW_IDENTITY_H_
