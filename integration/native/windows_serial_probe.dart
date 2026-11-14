import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../apps/client/lib/console/serial_console_io.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) throw StateError('Windows only');
  // The runner checks this intentionally nonexistent port is not enumerated.
  final console = openSerialConsole('COM9999');
  final output = StringBuffer();
  final sub = console.output.listen(output.write);
  try {
    final code = await console.exitCode.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (code == 0 || !output.toString().contains('无法打开 COM9999'))
      throw StateError('Missing-port failure not surfaced');
    await console.close();
    stdout.writeln(
      jsonEncode({
        'missing_port_error_visible': true,
        'exit_code': code,
        'close_completed': true,
      }),
    );
  } finally {
    await console.close();
    await sub.cancel();
  }
}
