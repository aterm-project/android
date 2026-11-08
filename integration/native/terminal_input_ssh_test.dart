import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// Opt-in: a one-use HTTPS fixture supplies the password in memory. Its public
// CA certificate and endpoint are supplied out of band. Never log the fixture,
// write it to disk, or place the password in an environment variable/argument.
void main() {
  final fixtureUrl = Platform.environment['ATERMIUS_INPUT_FIXTURE_URL'];
  final caPath = Platform.environment['ATERMIUS_INPUT_FIXTURE_CA'];
  testWidgets('native TerminalView and keybar bytes survive real SSH PTY', (
    tester,
  ) async {
    SshConnection? connection;
    StreamSubscription<String>? subscription;
    final focus = FocusNode();
    try {
      final fixture = await tester.runAsync(() async {
        return HttpOverrides.runWithHttpOverrides(() async {
          final context = SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(caPath!);
          final http = HttpClient(context: context);
          try {
            final response = await (await http.getUrl(Uri.parse(fixtureUrl!)))
                .close()
                .timeout(const Duration(seconds: 15));
            if (response.statusCode != 200)
              throw StateError('fixture unavailable');
            return jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
          } finally {
            http.close(force: true);
          }
        }, _NativeNetwork());
      });
      connection = await tester.runAsync(
        () =>
            SshService(
              api: null,
              deviceId: 'native-input-acceptance',
              useRelay: false,
            ).connect(
              host: HostRecord(
                id: 'input-acceptance',
                name: 'Input acceptance',
                address: fixture!['host'] as String,
                port: fixture['port'] as int,
                username: fixture['username'] as String,
              ),
              credential: CredentialRecord(
                id: 'memory-only',
                name: 'Memory only',
                username: fixture['username'] as String,
                kind: AuthKind.password,
                secret: fixture['password'] as String,
              ),
              verifyHostKey: (type, fingerprint) async =>
                  type == 'ssh-ed25519' &&
                  fingerprint == fixture['fingerprint'],
            ),
      );
      // Drop the extra reference as soon as authentication finishes. The product
      // connection owns its auth callback until close; no persistence is used.
      fixture!.remove('password');
      final terminal = Terminal()..onOutput = connection!.input;
      // Complete inside the real socket zone without scheduling fakeAsync microtasks.
      final ready = Completer<void>.sync();
      final observed = Completer<String>.sync();
      var output = '';
      await tester.runAsync(() async {
        subscription = connection!.output.listen((chunk) {
          output += chunk;
          if (output.length > 32768) {
            if (!observed.isCompleted)
              observed.completeError(StateError('output bound'));
            return;
          }
          if (output.contains('__INPUT_READY__') && !ready.isCompleted)
            ready.complete();
          final hex = RegExp(r'__INPUT_HEX__([0-9a-f]+)__').firstMatch(output);
          if (hex != null && !observed.isCompleted) observed.complete(hex[1]!);
        });
      });
      const expected = 'x\x03\x01\x0e\x16\x1bb\t\x1b\x1b[A\r中文🙂';
      final python =
          '''import os,select,sys,termios,tty
fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); data=b''
try:
 tty.setraw(fd); print('__INPUT_'+'READY__',flush=True)
 while len(data)<${utf8.encode(expected).length}:
  if not select.select([fd],[],[],15)[0]: raise TimeoutError()
  data+=os.read(fd,${utf8.encode(expected).length}-len(data))
 print('__INPUT_'+'HEX__'+data.hex()+'__',flush=True)
finally:
 termios.tcsetattr(fd,termios.TCSANOW,old)
''';
      await tester.runAsync(() async {
        connection!.input(
          "HISTFILE=/dev/null; python3 -c \"import base64;exec(base64.b64decode('${base64Encode(utf8.encode(python))}'))\"\r",
        );
        await ready.future.timeout(const Duration(seconds: 20));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: TerminalView(
                    terminal,
                    focusNode: focus,
                    autofocus: true,
                  ),
                ),
                TerminalKeybar(terminal: terminal, focusNode: focus),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'x'),
      );
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      for (final character in ['c', 'a', 'n', 'v']) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(text: character),
        );
        await tester.pump();
      }
      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.tap(find.text('Alt'));
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'b'),
      );
      await tester.pump();
      await tester.tap(find.text('Reset'));
      await tester.pump();
      for (final label in ['Tab', 'Esc', '↑']) {
        await tester.tap(find.text(label));
        await tester.pump();
      }
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'zhong',
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '中文🙂'),
      );
      await tester.pump();
      final actual = await tester.runAsync(
        () => observed.future.timeout(const Duration(seconds: 20)),
      );
      expect(
        actual,
        utf8
            .encode(expected)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
      );
      expect(focus.hasFocus, isTrue);
      // Only the bounded synthetic input bytes are reported, never shell output.
      debugPrint(
        'INPUT_SSH_PASS bytes=${utf8.encode(expected).length} runtime=${Platform.operatingSystem}',
      );
    } catch (error) {
      // SSH libraries may attach server text or auth details to exceptions.
      fail('Native input acceptance failed (${error.runtimeType})');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      await tester.runAsync(() async {
        await subscription?.cancel();
        connection?.input('exit\r');
        await connection?.close();
      });
    }
  }, skip: fixtureUrl == null || caPath == null);
}

class _NativeNetwork extends HttpOverrides {}
