import '../domain/window_placement.dart';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

class LiveTerminalWindowLaunch {
  const LiveTerminalWindowLaunch({
    required this.port,
    required this.sessionId,
    required this.capability,
  });
  final int port;
  final String sessionId;
  final String capability;
}

enum LiveTerminalWindowCloseReason {
  user,
  transportLost,
  parentClosed,
  startupFailed,
}

class LiveTerminalWindowHandle {
  const LiveTerminalWindowHandle({
    required this.ready,
    required this.closed,
    required this.close,
    required this.port,
    required this.sessionId,
    required this.outcome,
    Future<void>? processExited,
    this.capturePlacement,
    this.applyPlacement,
  }) : processExited = processExited ?? closed;
  final Future<SavedWindowPlacement?> Function()? capturePlacement;
  final Future<bool> Function(SavedWindowPlacement)? applyPlacement;
  final Future<bool> ready;
  final Future<void> closed;
  final Future<LiveTerminalWindowCloseReason> outcome;

  /// Physical process termination, distinct from a disconnected mirror socket.
  final Future<void> processExited;
  final Future<void> Function() close;
  final int port;
  final String sessionId;
}

abstract class LiveTerminalWindowClient extends ChangeNotifier {
  Terminal get terminal;
  String get title;
  bool get connected;
  bool get historyTruncated;
  void confirmReady();
  void openFiles();
  Future<void> close();
  Future<void> requestUserClose();
}
