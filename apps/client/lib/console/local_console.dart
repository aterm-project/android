import 'local_console_stub.dart'
    if (dart.library.io) 'local_console_io.dart'
    as platform;
export 'local_console_contract.dart';
import 'local_console_contract.dart';

bool get localConsoleSupported => platform.localConsoleSupported;
LocalConsole openLocalConsole() => platform.openLocalConsole();
LocalConsole openSerialConsole(String port, {int baudRate = 115200}) =>
    platform.openSerialConsole(port, baudRate: baudRate);
