import 'local_console_contract.dart';
import '../l10n/l10n.dart';

bool get localConsoleSupported => false;
LocalConsole openLocalConsole() =>
    throw UnsupportedError(currentL10n.theBrowserCantStartALocal);
LocalConsole openSerialConsole(String port, {int baudRate = 115200}) =>
    throw UnsupportedError(currentL10n.theComSerialConsoleRequiresThe);
