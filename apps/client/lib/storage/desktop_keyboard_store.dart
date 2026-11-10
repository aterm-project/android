import 'desktop_keyboard_store_native.dart'
    if (dart.library.js_interop) 'desktop_keyboard_store_web.dart'
    as platform;

/// Non-secret, device-local remote-desktop keyboard preference.
abstract interface class DesktopKeyboardStore {
  Future<String?> read();
  Future<void> write(String value);
}

DesktopKeyboardStore createDesktopKeyboardStore() => platform.createStore();

class MemoryDesktopKeyboardStore implements DesktopKeyboardStore {
  MemoryDesktopKeyboardStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}
