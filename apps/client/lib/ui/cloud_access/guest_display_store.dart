// Per-tab storage of the display key (labels only, not an access credential)
// so a refreshed guest tab can show the owner's labels again.
export 'guest_display_store_stub.dart'
    if (dart.library.js_interop) 'guest_display_store_web.dart';
