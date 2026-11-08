import 'dart:ui';

class DesktopWindowLaunch {
  const DesktopWindowLaunch({
    required this.port,
    required this.sessionId,
    required this.capability,
  });
  final int port;
  final String sessionId;
  final String capability;
}

/// What a detached desktop window shows: the whole desktop, or one remote
/// monitor region ([viewport]) optionally covering the local [coverMonitor].
class DesktopWindowSpec {
  const DesktopWindowSpec({required this.title, this.viewport, this.coverMonitor});
  final String title;
  final Rect? viewport;
  final Rect? coverMonitor;
}
