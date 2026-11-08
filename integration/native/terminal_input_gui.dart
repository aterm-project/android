// Isolated opt-in native GUI acceptance harness; no credential persistence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:xterm/xterm.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _InputHarness()));
}

class _InputHarness extends StatefulWidget {
  const _InputHarness();
  @override
  State<_InputHarness> createState() => _InputHarnessState();
}

class _InputHarnessState extends State<_InputHarness> {
  final terminal = Terminal();
  final focus = FocusNode();
  SshConnection? connection;
  StreamSubscription<String>? subscription;
  String status = 'Connecting';
  String received = '';
  bool ready = false;
  static const expected = 'x\x03\x01\x0e\x16\x1bb\t\x1b\x1b[A\r中文🙂';
  final result = File(
    '${Platform.environment['ATERMIUS_INPUT_RESULT_DIR']}\\gui-result.json',
  );
  @override
  void initState() {
    super.initState();
    unawaited(connect());
  }

  Future<void> record(String phase, {bool? pass}) async {
    await result.writeAsString(
      jsonEncode({
        'phase': phase,
        'pass': pass,
        'runtime': Platform.operatingSystem,
        'focus': focus.hasFocus,
        'expectedBytes': utf8.encode(expected).length,
      }),
    );
    if (mounted) setState(() => status = phase);
  }

  Future<void> connect() async {
    try {
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(
          Platform.environment['ATERMIUS_INPUT_FIXTURE_CA']!,
        );
      final http = HttpClient(context: context);
      late Map<String, dynamic> fixture;
      try {
        final r = await (await http.getUrl(
          Uri.parse(Platform.environment['ATERMIUS_INPUT_FIXTURE_URL']!),
        )).close();
        if (r.statusCode != 200) throw StateError('fixture');
        fixture = jsonDecode(
          await utf8.decoder.bind(r).join(),
        ) as Map<String, dynamic>;
      } finally {
        http.close(force: true);
      }
      connection =
          await SshService(
            api: null,
            deviceId: 'gui-input-acceptance',
            useRelay: false,
          ).connect(
            host: HostRecord(
              id: 'gui-input',
              name: 'Isolated input acceptance',
              address: fixture['host'] as String,
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
                type == 'ssh-ed25519' && fingerprint == fixture['fingerprint'],
          );
      fixture.remove('password');
      terminal.onOutput = connection!.input;
      subscription = connection!.output.listen((chunk) {
        terminal.write(chunk);
        received += chunk;
        if (received.length > 32768) {
          unawaited(record('output-bound', pass: false));
          unawaited(connection!.close());
          return;
        }
        if (!ready && received.contains('__INPUT_READY__')) {
          ready = true;
          focus.requestFocus();
          unawaited(record('ready'));
        }
        final hex = RegExp(r'__INPUT_HEX__([0-9a-f]+)__').firstMatch(received);
        if (hex != null) {
          final want = utf8
              .encode(expected)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          unawaited(record('completed', pass: hex[1] == want));
          unawaited(connection!.close());
        }
      });
      final python =
          '''import os,select,sys,termios,tty
fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); data=b''
try:
 tty.setraw(fd); print('__INPUT_'+'READY__',flush=True)
 while len(data)<${utf8.encode(expected).length}:
  if not select.select([fd],[],[],90)[0]: raise TimeoutError()
  data+=os.read(fd,${utf8.encode(expected).length}-len(data))
 print('__INPUT_'+'HEX__'+data.hex()+'__',flush=True)
finally:
 termios.tcsetattr(fd,termios.TCSANOW,old)
''';
      connection!.input(
        "HISTFILE=/dev/null; python3 -c \"import base64;exec(base64.b64decode('${base64Encode(utf8.encode(python))}'))\"\r",
      );
    } catch (error) {
      await record('failed-${error.runtimeType}', pass: false);
    }
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel() ?? Future<void>.value());
    unawaited(connection?.close() ?? Future<void>.value());
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Isolated Windows input acceptance: $status')),
    body: Column(
      children: [
        Expanded(
          child: TerminalView(terminal, focusNode: focus, autofocus: true),
        ),
        TerminalKeybar(terminal: terminal, focusNode: focus),
      ],
    ),
  );
}
