import 'keyboard_capture_store_native.dart'
    if (dart.library.js_interop) 'keyboard_capture_store_web.dart'
    as platform;

/// Non-secret, device-local remote-desktop shortcut capture preference.
abstract interface class KeyboardCaptureStore {
  Future<String?> read();
  Future<void> write(String value);
}

KeyboardCaptureStore createKeyboardCaptureStore() => platform.createStore();

class MemoryKeyboardCaptureStore implements KeyboardCaptureStore {
  MemoryKeyboardCaptureStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}
