import 'package:flutter/foundation.dart';
import 'live_terminal_window_contract.dart';
import 'mirrored_terminal.dart';

bool get supportsLiveTerminalWindows => false;
LiveTerminalWindowLaunch? detectLiveTerminalWindow(List<String> arguments) =>
    null;
Future<LiveTerminalWindowHandle> openLiveTerminalWindow({
  required MirroredTerminal terminal,
  required String title,
  VoidCallback? onReady,
  ValueChanged<LiveTerminalWindowCloseReason>? onClosed,
  VoidCallback? onOpenFiles,
  Duration readyTimeout = const Duration(seconds: 30),
}) =>
    Future.error(UnsupportedError('Live terminal windows require a desktop.'));
Future<LiveTerminalWindowClient> connectLiveTerminalWindow(
  LiveTerminalWindowLaunch launch,
) => Future.error(UnsupportedError('Live terminal windows require a desktop.'));

Future<void> closeLiveTerminalWindowClient() async {}
