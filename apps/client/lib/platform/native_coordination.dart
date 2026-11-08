import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'process_file_lock.dart';

/// Injectable for tests; production always uses this app's user support folder.
Future<Directory> Function() coordinationDirectory = () async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}coordination');
};

Future<ProcessFileLock> nativeProcessLock() async =>
    ProcessFileLock(await coordinationDirectory());
