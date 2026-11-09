import 'dart:io';

/// Android needs a user-visible foreground service to keep a local MCP
/// listener reachable while the activity is in the background.
bool get needsMcpForegroundService => Platform.isAndroid;
