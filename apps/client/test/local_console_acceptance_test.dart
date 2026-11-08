import 'dart:async';
import 'dart:io';

import 'package:aterm_client/console/local_console.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip =
      !Platform.isLinux || !const bool.fromEnvironment('CONSOLE_ACCEPTANCE');
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
    skip: skip,
  );

  test(
    'selected shell + working directory start an owned PTY; cwd, bounds, close',
    () async {
      final dir = await Directory.systemTemp.createTemp('atermius-shell-smoke-');
      addTearDown(() => dir.delete(recursive: true));
      final launch = LocalShellLaunch(
        kind: LocalShellKind.sh,
        workingDirectory: dir.path,
      );
      final console = openLocalConsole(launch: launch);
      addTearDown(console.close);
      final output = StringBuffer();
      var done = false;
      final subscription = console.output.listen(
        output.write,
        onDone: () => done = true,
      );
      addTearDown(subscription.cancel);
      Future<void> waitFor(Pattern needle) async {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!output.toString().contains(needle)) {
          if (DateTime.now().isAfter(deadline)) {
            final text = output.toString();
            fail(
              'timed out waiting for $needle; tail: '
              '${text.substring(text.length > 400 ? text.length - 400 : 0)}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      // Synthetic commands only. argv[0] proves the selected shell ran
      // without any command-string evaluation by Atermius itself.
      console.input("printf 'cwd=%s\\n' \"\$PWD\"; printf 'term=%s\\n' \"\$TERM\"\r");
      final resolvedDir = dir.resolveSymbolicLinksSync();
      await waitFor('cwd=${dir.path}');
      await waitFor('term=xterm-256color');
      expect(console, isA<LocalConsoleWorkingDirectory>());
      final probe = console as LocalConsoleWorkingDirectory;
      expect(await probe.currentWorkingDirectory(), resolvedDir);
      console.input("cd / && printf 'moved\\n'\r");
      await waitFor('moved');
      expect(await probe.currentWorkingDirectory(), '/');
      // Oversized paste is refused locally with a notice, not written.
      console.input('x' * (1024 * 1024 + 1));
      await waitFor('[Input too large');
      // A large-but-allowed paste is written in chunks without blocking.
      // (Multi-line so each tty line stays under the canonical 4095 limit.)
      final lines = List.filled(200, 'y' * 99).join('\r');
      console.input("wc -c <<'ATERMIUS_EOF'\r$lines\rATERMIUS_EOF\r");
      await waitFor(RegExp(r'\b20000\b'));
      await console.close();
      final code = await console.exitCode.timeout(const Duration(seconds: 3));
      expect(code, isNot(0));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done, isTrue, reason: 'PTY output port must be released');
      expect(await probe.currentWorkingDirectory(), isNull);
    },
    skip: skip,
  );

  test('missing working directory refuses to start any process', () {
    expect(
      () => openLocalConsole(
        launch: const LocalShellLaunch(
          kind: LocalShellKind.sh,
          workingDirectory: '/definitely/not/here/atermius',
        ),
      ),
      throwsA(isA<LocalShellException>()),
    );
  }, skip: !Platform.isLinux);
}
