import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../apps/client/lib/console/local_console.dart';

Future<void> main() async {
  if (!Platform.isWindows) throw StateError('Windows probe requires Windows');
  final console = openLocalConsole();
  final buffer = StringBuffer();
  final subscription = console.output.listen(buffer.write);
  Future<void> until(bool Function(String) predicate) async {
    final timeout = DateTime.now().add(const Duration(seconds: 10));
    while (!predicate(buffer.toString())) {
      if (DateTime.now().isAfter(timeout)) throw StateError('Windows console output timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  try {
    // Input contains %OS%, only output of a running cmd.exe contains Windows_NT.
    console.input('echo CONPTY-%OS%-ATERMIUS\r');
    await until((text) => text.contains('CONPTY-Windows_NT-ATERMIUS'));
    buffer.clear();
    console.resize(101,41);
    console.input('mode con\r');
    await until((text) => RegExp(r'\b101\b').hasMatch(text) && RegExp(r'\b41\b').hasMatch(text));
    await console.close();
    await console.exitCode.timeout(const Duration(seconds: 5));
    stdout.writeln(jsonEncode({'conpty_input':true,'resize':'101x41','closed':true}));
  } finally { await console.close(); await subscription.cancel(); }
}
