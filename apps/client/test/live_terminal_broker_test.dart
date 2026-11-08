import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealNetwork extends HttpOverrides {}

class _PoisonProxy extends HttpOverrides {
  int proxyLookups = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (_) {
          proxyLookups++;
          return 'PROXY 127.0.0.1:1';
        };
}

void _networkTest(String name, Future<void> Function() body) => test(
  name,
  () => HttpOverrides.runWithHttpOverrides(body, _RealNetwork()),
  timeout: const Timeout(Duration(seconds: 15)),
);
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _networkTest(
    'authenticated child replays output and forwards input/resize to the same SSH callbacks',
    () async {
      final input = <String>[];
      final sizes = <(int, int)>[];
      var fileRequests = 0;
      final terminal = MirroredTerminal(
        onOutput: input.add,
        onResize: (columns, rows, _, _) => sizes.add((columns, rows)),
      );
      terminal.write('before-window\r\n');
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'test session',
        onOpenFiles: () => fileRequests++,
      );
      final client = await connectLiveTerminalWindow(broker.launch);
      expect(client.terminal.buffer.getText(), contains('before-window'));
      var sourceReady = false;
      unawaited(broker.ready.then((value) => sourceReady = value));
      expect(
        sourceReady,
        isFalse,
        reason: 'A socket alone is not a painted child terminal.',
      );
      client.confirmReady();
      expect(await broker.ready, isTrue);
      await _until(() => terminal.onOutput == null);
      client.terminal.textInput('echo live\n');
      await _until(() => input.contains('echo live\n'));
      client.openFiles();
      await _until(() => fileRequests == 1);
      client.terminal.resize(120, 40, 1200, 800);
      await _until(() => sizes.contains((120, 40)));
      terminal.write('after-window\r\n');
      await _until(
        () => client.terminal.buffer.getText().contains('after-window'),
      );
      await client.close();
      expect(await broker.outcome, LiveTerminalWindowCloseReason.transportLost);
      expect(terminal.onOutput, isNotNull);
      terminal.textInput('still-alive');
      expect(input.last, 'still-alive');
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'historical VT queries are silent and each live query replies exactly once',
    () async {
      final replies = <String>[];
      final terminal = MirroredTerminal(onOutput: replies.add);
      terminal.write('\x1b[6n');
      expect(replies, hasLength(1));
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'queries',
      );
      final client = await connectLiveTerminalWindow(broker.launch);
      expect(
        replies,
        hasLength(1),
        reason: 'History must never replay device replies into SSH.',
      );
      client.confirmReady();
      await broker.ready;
      // owner packet precedes this live output on the same ordered socket.
      terminal.write('\x1b[6n');
      await _until(() => replies.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(replies, hasLength(2));
      await client.close();
      await broker.closed;
      terminal.write('\x1b[6n');
      expect(
        replies,
        hasLength(3),
        reason: 'Transport loss restores source reply ownership.',
      );
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'wrong capability and browser Origin are rejected without consuming the one-use receiver',
    () async {
      final terminal = MirroredTerminal(onOutput: (_) {});
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'auth',
      );
      final launch = broker.launch;
      final url = 'ws://127.0.0.1:${launch.port}/live/${launch.sessionId}';
      Future<WebSocket> connect(String cap, String origin) => WebSocket.connect(
        url,
        protocols: ['atermius-terminal-v1'],
        headers: {'Origin': origin, 'Authorization': 'Bearer $cap'},
      );
      await expectLater(
        connect('x' * 43, 'atermius://terminal-window'),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        connect(launch.capability, 'https://evil.example'),
        throwsA(isA<WebSocketException>()),
      );
      final client = await connectLiveTerminalWindow(launch);
      client.confirmReady();
      await broker.ready;
      await expectLater(
        connect(launch.capability, 'atermius://terminal-window'),
        throwsA(isA<WebSocketException>()),
      );
      await client.close();
      await broker.closed;
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'explicit child close intent is distinguished from transport loss',
    () async {
      final terminal = MirroredTerminal(onOutput: (_) {});
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'user close',
      );
      final client = await connectLiveTerminalWindow(broker.launch);
      client.confirmReady();
      await broker.ready;
      await closeLiveTerminalWindowClient();
      expect(await broker.outcome, LiveTerminalWindowCloseReason.user);
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'a receiver that does not acknowledge output is disconnected without stopping source SSH',
    () async {
      final input = <String>[];
      final terminal = MirroredTerminal(onOutput: input.add);
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'backpressure',
      );
      final launch = broker.launch;
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${launch.port}/live/${launch.sessionId}',
        protocols: ['atermius-terminal-v1'],
        headers: {
          'Origin': 'atermius://terminal-window',
          'Authorization': 'Bearer ${launch.capability}',
        },
      );
      final subscription = socket.listen(
        (_) {},
      ); // Deliberately omit ready/acks.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      terminal.write('x' * (1024 * 1024));
      await broker.closed;
      expect(await broker.ready, isFalse);
      expect(await broker.outcome, LiveTerminalWindowCloseReason.transportLost);
      terminal.textInput('source-survives');
      expect(input.last, 'source-survives');
      expect(terminal.retainedBytes, lessThanOrEqualTo(512 * 1024));
      await subscription.cancel();
      await socket.close();
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'unclaimed child launch times out and leaves original terminal callbacks intact',
    () async {
      final input = <String>[];
      final terminal = MirroredTerminal(onOutput: input.add);
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'timeout',
        readyTimeout: const Duration(milliseconds: 20),
      );
      expect(await broker.ready, isFalse);
      expect(await broker.outcome, LiveTerminalWindowCloseReason.startupFailed);
      terminal.textInput('still-here');
      expect(input, ['still-here']);
      await terminal.closeMirror();
    },
  );
  test(
    'mirrored raw history is bounded and preserves multi-byte characters at chunk boundaries',
    () async {
      final terminal = MirroredTerminal(maxHistoryBytes: 8192);
      final chunks = <String>[];
      final subscription = terminal.mirroredOutput.listen(
        (chunk) => chunks.add(chunk.data),
      );
      final output = '${'x' * 4095}🌍${'界' * 5000}';
      terminal.write(output);
      expect(chunks.join(), output);
      expect(chunks.any((chunk) => chunk.contains('\ufffd')), isFalse);
      expect(terminal.retainedBytes, lessThanOrEqualTo(8192));
      expect(terminal.historyTruncated, isTrue);
      expect(
        utf8.encode(terminal.history.join()).length,
        terminal.retainedBytes,
      );
      await subscription.cancel();
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'terminal capability connection bypasses inherited proxy configuration',
    () async {
      final terminal = MirroredTerminal(onOutput: (_) {});
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'direct only',
      );
      final poison = _PoisonProxy();
      final client = await HttpOverrides.runWithHttpOverrides(
        () => connectLiveTerminalWindow(broker.launch),
        poison,
      );
      client.confirmReady();
      expect(await broker.ready, isTrue);
      expect(
        poison.proxyLookups,
        0,
        reason: 'No proxy may observe a loopback capability.',
      );
      await client.close();
      await broker.closed;
      await terminal.closeMirror();
    },
  );
  _networkTest(
    'oversized authenticated frames are rejected by the native WebSocket parser',
    () async {
      final input = <String>[];
      final terminal = MirroredTerminal(onOutput: input.add);
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'native frame bound',
      );
      final launch = broker.launch;
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${launch.port}/live/${launch.sessionId}',
        protocols: ['atermius-terminal-v1'],
        headers: {
          'Origin': 'atermius://terminal-window',
          'Authorization': 'Bearer ${launch.capability}',
        },
      );
      final initialized = Completer<int>(), done = Completer<void>();
      final subscription = socket.listen(
        (message) {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          if (data['type'] == 'init')
            initialized.complete(data['sequence'] as int);
        },
        onDone: () {
          done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );
      socket.add(
        jsonEncode({'type': 'ready', 'sequence': await initialized.future}),
      );
      await broker.ready;
      socket.add(jsonEncode({'type': 'input', 'data': 'x' * 100000}));
      await done.future.timeout(const Duration(seconds: 3));
      // Dart's maxPayloadLength contract rejects the frame as protocolError
      // (1002), before our application-level normal close path can run.
      expect(socket.closeCode, WebSocketStatus.protocolError);
      expect(await broker.outcome, LiveTerminalWindowCloseReason.transportLost);
      expect(input, isEmpty);
      await subscription.cancel();
      await socket.close();
      await terminal.closeMirror();
    },
  );
}
