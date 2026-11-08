import 'dart:io';
import '../lib/platform/process_file_lock.dart';

// Real independent processes exercise the OS lock, including crash release.
Future<void> main(List<String> args) async {
  stdout.writeln('ready');
  final directory = Directory(args[0]);
  final log = File('${directory.path}/events');
  await ProcessFileLock(directory).run('probe', () async {
    await log.writeAsString(
      'enter ${args[1]}\n',
      mode: FileMode.append,
      flush: true,
    );
    if (args[1] == 'crash') exit(7);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await log.writeAsString(
      'leave ${args[1]}\n',
      mode: FileMode.append,
      flush: true,
    );
  });
}
