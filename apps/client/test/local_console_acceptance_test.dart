import 'dart:async';
import 'dart:io';

import 'package:aterm_client/console/local_console.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real local PTY accepts input, resizes and exits on tab close',
    () async {
      final console = openLocalConsole();
      addTearDown(console.close);
      final output = StringBuffer();
      final ready = Completer<void>();
      final subscription = console.output.listen((text) {
        output.write(text);
        if (output.toString().contains('pty-is-terminal') &&
            output.toString().contains('41 101') &&
            !ready.isCompleted)
          ready.complete();
      });
      addTearDown(subscription.cancel);
      console.resize(101, 41);
      console.input("test -t 0 && printf 'pty-is-%s\\n' terminal; stty size\r");
      await ready.future.timeout(const Duration(seconds: 8));
      await console.close();
      await console.exitCode.timeout(const Duration(seconds: 3));
      await console.close();
    },
    skip:
        !Platform.isLinux || !const bool.fromEnvironment('CONSOLE_ACCEPTANCE'),
  );
}
