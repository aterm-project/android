import 'local_console_stub.dart'
    if (dart.library.io) 'local_console_io.dart'
    as platform;
import 'local_shell.dart';
export 'local_console_contract.dart';
export 'local_shell.dart';
import 'local_console_contract.dart';

bool get localConsoleSupported => platform.localConsoleSupported;

/// Starts the embedded local shell described by [launch] in an owned PTY.
/// Throws [LocalShellException] / [UnsupportedError] when it cannot start.
LocalConsole openLocalConsole({
  LocalShellLaunch launch = LocalShellLaunch.systemDefault,
}) => platform.openLocalConsole(launch: launch);

/// Shell kinds installed on this desktop (empty on web/mobile).
List<LocalShellKind> availableLocalShellKinds() =>
    platform.availableLocalShellKinds();

LocalConsole openSerialConsole(String port, {int baudRate = 115200}) =>
    platform.openSerialConsole(port, baudRate: baudRate);
