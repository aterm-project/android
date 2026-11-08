import 'dart:ui' show Rect;

import '../../terminal/live_terminal_window_contract.dart';
import '../desktop_session.dart';
import 'desktop_window_contract.dart';

bool get supportsDesktopWindows => false;
DesktopWindowLaunch? detectDesktopWindow(List<String> arguments) => null;
Future<LiveTerminalWindowHandle> openDesktopWindow({
  required DesktopSession session,
  required DesktopWindowSpec spec,
  void Function()? onReady,
}) => throw UnsupportedError('Desktop windows require the desktop client.');

/// The child-window page is part of the shared application entry point. Its
/// types must remain available to the browser compiler even though native
/// child windows are never supported or detected in a browser.
abstract class MirroredDesktopSession extends DesktopSession {
  String get title;
  Rect? get viewport;
  Rect? get coverMonitor;
  void confirmReady();
}

Future<MirroredDesktopSession> connectDesktopWindow(
  DesktopWindowLaunch launch,
) async => throw UnsupportedError('Desktop windows require the desktop client.');

Future<void> closeDesktopWindowClient() async {}
