import 'dart:js_interop';

@JS('atermiusTakeShareFragment')
external JSString? _take();

/// Returns the captured fragment once (then null). The bootstrap already
/// removed it from the address bar and history entry.
String? takeShareFragment() {
  try {
    return _take()?.toDart;
  } catch (_) {
    return null;
  }
}
