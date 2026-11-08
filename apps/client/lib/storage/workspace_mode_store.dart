import 'workspace_mode.dart';
import 'workspace_mode_store_native.dart'
    if (dart.library.js_interop) 'workspace_mode_store_web.dart'
    as platform;

export 'workspace_mode.dart';

WorkspaceModeStore createWorkspaceModeStore() => platform.createModeStore();
