/// Cross-platform facade for one-click local Termius Desktop vault discovery
/// and decryption.
library;

export 'termius_local_app_import_io.dart'
    if (dart.library.js_interop) 'termius_local_app_import_web.dart';
