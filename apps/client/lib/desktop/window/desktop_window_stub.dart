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
