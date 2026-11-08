import 'local_console_contract.dart';
import 'local_shell.dart';
import '../l10n/l10n.dart';

bool get localConsoleSupported => false;
LocalConsole openLocalConsole({
  LocalShellLaunch launch = LocalShellLaunch.systemDefault,
}) => throw UnsupportedError(currentL10n.theBrowserCantStartALocal);
List<LocalShellKind> availableLocalShellKinds() => const [];
LocalConsole openSerialConsole(String port, {int baudRate = 115200}) =>
    throw UnsupportedError(currentL10n.theComSerialConsoleRequiresThe);
