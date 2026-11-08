import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/ssh/tmux_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart'
    show SSH_Message_Channel_Window_Adjust;
import 'package:dartssh2/src/ssh_channel.dart'
    show SSHChannel, SSHChannelController;
import 'package:flutter_test/flutter_test.dart';

const _sessionName = 'atermius_0123456789abcdef0123456789abcdef';

void main() {
  group('SshTmuxService management commands', () {
    test(
      'emits only reviewed commands and targets an exact session name',
      () async {
        final connection = _UnusedSshConnection();
        final runner = _RecordingCommandRunner([
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 0),
        ]);
        final service = SshTmuxService(commandRunner: runner);

        expect(await service.probe(connection), TmuxProbeStatus.available);
        expect(
          await service.hasSession(connection, _sessionName),
          TmuxSessionStatus.exists,
        );
        await service.createSession(connection, _sessionName);
        await service.killSession(connection, _sessionName);

        expect(runner.commands.map((command) => command.command), [
          'tmux -V',
          'tmux -V',
          'tmux has-session -t =$_sessionName',
          'tmux -V',
          'tmux new-session -d -s $_sessionName',
          'tmux -V',
          'tmux kill-session -t =$_sessionName',
        ]);
        expect(runner.connections, everyElement(same(connection)));
        expect(runner.timeouts, everyElement(const Duration(seconds: 5)));
        expect(
          runner.commands.map((command) => command.operation).toSet(),
          TmuxManagementOperation.values.toSet(),
        );
      },
    );

    test(
      'probe nonzero reports unavailable and does not issue has-session',
      () async {
        final runner = _RecordingCommandRunner([
          const TmuxCommandOutcome(exitCode: 127),
          const TmuxCommandOutcome(exitCode: 127),
        ]);
        final service = SshTmuxService(commandRunner: runner);
        final connection = _UnusedSshConnection();

        expect(await service.probe(connection), TmuxProbeStatus.unavailable);
        expect(
          await service.hasSession(connection, _sessionName),
          TmuxSessionStatus.unavailable,
        );
        expect(runner.commands.map((command) => command.command), [
          'tmux -V',
          'tmux -V',
        ]);
      },
    );

    test(
      'has-session nonzero after a successful probe reports absent',
      () async {
        final runner = _RecordingCommandRunner([
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 1),
        ]);
        final service = SshTmuxService(commandRunner: runner);

        expect(
          await service.hasSession(_UnusedSshConnection(), _sessionName),
          TmuxSessionStatus.absent,
        );
        expect(
          runner.commands.last.command,
          'tmux has-session -t =$_sessionName',
        );
      },
    );

    test(
      'create and kill nonzero results throw a typed sanitized failure',
      () async {
        final runner = _RecordingCommandRunner([
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 1),
          const TmuxCommandOutcome(exitCode: 0),
          const TmuxCommandOutcome(exitCode: 1),
        ]);
        final service = SshTmuxService(commandRunner: runner);

        for (final operation in [
          () => service.createSession(_UnusedSshConnection(), _sessionName),
          () => service.killSession(_UnusedSshConnection(), _sessionName),
        ]) {
          await expectLater(
            operation(),
            throwsA(
              isA<TmuxServiceException>().having(
                (error) => error.reason,
                'reason',
                TmuxServiceFailureReason.commandFailure,
              ),
            ),
          );
        }
        expect(
          runner.commands[1].command,
          'tmux new-session -d -s $_sessionName',
        );
        expect(
          runner.commands[3].command,
          'tmux kill-session -t =$_sessionName',
        );
      },
    );

    test(
      'create refuses an unavailable tmux binary with a typed failure',
      () async {
        final runner = _RecordingCommandRunner([
          const TmuxCommandOutcome(exitCode: 127),
        ]);
        final service = SshTmuxService(commandRunner: runner);

        await expectLater(
          service.createSession(_UnusedSshConnection(), _sessionName),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.commandFailure,
            ),
          ),
        );
        expect(runner.commands.map((command) => command.command), ['tmux -V']);
      },
    );

    test(
      'rejects every name outside the generated session-name format locally',
      () async {
        final runner = _RecordingCommandRunner(const []);
        final service = SshTmuxService(commandRunner: runner);
        const invalidNames = [
          '',
          'session',
          'atermius_',
          'atermius_0123456789abcdef0123456789abcdeG',
          'atermius_0123456789abcdef0123456789abcdef-more',
          'atermius_0123456789abcdef0123456789abcdef;id',
          'atermius_0123456789abcdef0123456789abcdef`id`',
          'atermius_0123456789abcdef0123456789abcdef\n',
          'atermius_0123456789abcdef0123456789abcde',
          'atermius_0123456789abcdef0123456789abcdef0',
        ];

        for (final name in invalidNames) {
          await expectLater(
            service.hasSession(_UnusedSshConnection(), name),
            throwsA(
              isA<TmuxServiceException>().having(
                (error) => error.reason,
                'reason',
                TmuxServiceFailureReason.invalidSessionName,
              ),
            ),
            reason: 'Expected the name to fail locally: $name',
          );
        }
        expect(runner.commands, isEmpty);
      },
    );

    test('transport errors are translated without remote error text', () async {
      final runner = _RecordingCommandRunner([
        StateError('REMOTE-STDOUT-MARKER and REMOTE-STDERR-MARKER'),
      ]);
      final service = SshTmuxService(commandRunner: runner);
      TmuxServiceException? caught;

      try {
        await service.probe(_UnusedSshConnection());
      } on TmuxServiceException catch (error) {
        caught = error;
      }

      expect(caught?.reason, TmuxServiceFailureReason.transportFailure);
      expect(caught.toString(), isNot(contains('REMOTE-STDOUT-MARKER')));
      expect(caught.toString(), isNot(contains('REMOTE-STDERR-MARKER')));
    });

    test(
      'timeout, cancellation and truncated output map to typed failures',
      () async {
        final timeoutService = SshTmuxService(
          commandRunner: _RecordingCommandRunner([
            const TmuxCommandOutcome(exitCode: null, timedOut: true),
          ]),
        );
        await expectLater(
          timeoutService.probe(_UnusedSshConnection()),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.timeout,
            ),
          ),
        );

        final cancel = SshExecCancellation()..cancel();
        final cancelledService = SshTmuxService(
          commandRunner: _RecordingCommandRunner(const []),
        );
        await expectLater(
          cancelledService.probe(_UnusedSshConnection(), cancellation: cancel),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.cancelled,
            ),
          ),
        );

        final truncatedService = SshTmuxService(
          commandRunner: _RecordingCommandRunner([
            const TmuxCommandOutcome(exitCode: null, outputTruncated: true),
          ]),
        );
        await expectLater(
          truncatedService.probe(_UnusedSshConnection()),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.commandFailure,
            ),
          ),
        );
      },
    );
  });

  group('SshTmuxService PTY attach', () {
    test(
      'opens only explicit attach using the shared connection and dimensions',
      () async {
        final connection = _UnusedSshConnection();
        final handle = _FakeAttachHandle();
        final opener = _RecordingPtyOpener(handle: handle);
        final service = SshTmuxService(ptyOpener: opener);

        final opened = await service.openAttach(
          connection,
          _sessionName,
          columns: 132,
          rows: 43,
        );

        expect(opened, same(handle));
        expect(opener.connection, same(connection));
        expect(
          opener.command?.command,
          'tmux attach-session -t =$_sessionName',
        );
        expect(opener.columns, 132);
        expect(opener.rows, 43);
        expect(opener.openCount, 1);
        opened.resize(120, 40);
        await opened.input(Uint8List.fromList([1, 2, 3]));
        opened.close();
        expect(handle.lastSize, (120, 40));
        expect(handle.lastInput, [1, 2, 3]);
        expect(handle.closed, isTrue);
      },
    );

    test(
      'preserves owned tmux bytes until a zero-window SSH channel can send',
      () async {
        final ssh = _RecordingSshSession(remoteInitialWindowSize: 0);
        final handle = SshTmuxAttachHandle(ssh.session);
        final callerBytes = Uint8List.fromList([0x65, 0xcc, 0x81, 0x0d]);
        final pendingWrite = handle.input(callerBytes);

        // Input is copied before it is handed to dartssh2's async stream.
        callerBytes.fillRange(0, callerBytes.length, 0);
        await pendingWrite;

        expect(callerBytes, everyElement(0));
        expect(ssh.inputMessages, isEmpty);
        final channel = ssh.session.channel;
        ssh.channelController.handleMessage(
          SSH_Message_Channel_Window_Adjust(
            recipientChannel: channel.remoteChannelId,
            bytesToAdd: 4,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ssh.inputMessages, [
          [0x65, 0xcc, 0x81, 0x0d],
        ]);
        channel.destroy();
      },
    );

    test(
      'rejects unsafe name and terminal dimensions before opening a PTY',
      () async {
        final opener = _RecordingPtyOpener(handle: _FakeAttachHandle());
        final service = SshTmuxService(ptyOpener: opener);

        await expectLater(
          service.openAttach(
            _UnusedSshConnection(),
            'atermius_0123456789abcdef0123456789abcdef;id',
            columns: 80,
            rows: 24,
          ),
          throwsA(isA<TmuxServiceException>()),
        );
        await expectLater(
          service.openAttach(
            _UnusedSshConnection(),
            _sessionName,
            columns: 0,
            rows: 24,
          ),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.invalidTerminalSize,
            ),
          ),
        );
        await expectLater(
          service.openAttach(
            _UnusedSshConnection(),
            _sessionName,
            columns: 501,
            rows: 24,
          ),
          throwsA(isA<TmuxServiceException>()),
        );
        expect(opener.openCount, 0);
      },
    );

    test(
      'attach timeout TERM and destroys only a channel that resolves late',
      () async {
        final pending = Completer<TmuxAttachHandle>();
        final opener = _RecordingPtyOpener(pending: pending);
        final service = SshTmuxService(
          ptyOpener: opener,
          attachOpenTimeout: const Duration(milliseconds: 10),
        );

        await expectLater(
          service.openAttach(
            _UnusedSshConnection(),
            _sessionName,
            columns: 80,
            rows: 24,
          ),
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.timeout,
            ),
          ),
        );
        final lateSession = _RecordingSshSession();
        final siblingSession = _RecordingSshSession();
        var siblingClosed = false;
        siblingSession.session.done.then((_) => siblingClosed = true);
        pending.complete(SshTmuxAttachHandle(lateSession.session));
        await Future<void>.delayed(Duration.zero);

        expect(lateSession.signalAttempts, ['TERM']);
        expect(lateSession.events, contains('SSH_Message_Channel_Close'));
        expect(lateSession.events, contains('SSH_Message_Channel_EOF'));
        await lateSession.session.done;
        expect(siblingSession.events, isEmpty);
        expect(siblingClosed, isFalse);
      },
    );

    test(
      'cancelling attach open closes a channel that resolves late',
      () async {
        final pending = Completer<TmuxAttachHandle>();
        final opener = _RecordingPtyOpener(pending: pending);
        final service = SshTmuxService(ptyOpener: opener);
        final cancellation = SshExecCancellation();
        final open = service.openAttach(
          _UnusedSshConnection(),
          _sessionName,
          columns: 80,
          rows: 24,
          cancellation: cancellation,
        );
        await Future<void>.delayed(Duration.zero);
        cancellation.cancel();

        await expectLater(
          open,
          throwsA(
            isA<TmuxServiceException>().having(
              (error) => error.reason,
              'reason',
              TmuxServiceFailureReason.cancelled,
            ),
          ),
        );
        final lateSession = _RecordingSshSession();
        final siblingSession = _RecordingSshSession();
        var siblingClosed = false;
        siblingSession.session.done.then((_) => siblingClosed = true);
        pending.complete(SshTmuxAttachHandle(lateSession.session));
        await Future<void>.delayed(Duration.zero);

        expect(lateSession.signalAttempts, ['TERM']);
        expect(lateSession.events, contains('SSH_Message_Channel_Close'));
        expect(lateSession.events, contains('SSH_Message_Channel_EOF'));
        await lateSession.session.done;
        expect(siblingSession.events, isEmpty);
        expect(siblingClosed, isFalse);
      },
    );

    test(
      'explicit close terminates only its channel and hides signal errors',
      () async {
        final attachSession = _RecordingSshSession(failSignal: true);
        final siblingSession = _RecordingSshSession();
        var siblingClosed = false;
        siblingSession.session.done.then((_) => siblingClosed = true);
        final handle = SshTmuxAttachHandle(attachSession.session);

        expect(handle.close, returnsNormally);
        await attachSession.session.done;

        expect(attachSession.signalAttempts, ['TERM']);
        expect(attachSession.events, contains('SSH_Message_Channel_Close'));
        expect(attachSession.events, contains('SSH_Message_Channel_EOF'));
        expect(siblingSession.events, isEmpty);
        expect(siblingClosed, isFalse);
      },
    );

    test('opener failure is sanitized', () async {
      final opener = _RecordingPtyOpener(
        error: StateError('REMOTE-ERROR-MARKER'),
      );
      final service = SshTmuxService(ptyOpener: opener);
      TmuxServiceException? caught;

      try {
        await service.openAttach(
          _UnusedSshConnection(),
          _sessionName,
          columns: 80,
          rows: 24,
        );
      } on TmuxServiceException catch (error) {
        caught = error;
      }

      expect(caught?.reason, TmuxServiceFailureReason.transportFailure);
      expect(caught.toString(), isNot(contains('REMOTE-ERROR-MARKER')));
    });
  });
}

class _RecordingCommandRunner implements TmuxCommandRunner {
  _RecordingCommandRunner(Iterable<Object> results)
    : _results = Queue<Object>.of(results);

  final Queue<Object> _results;
  final List<SshConnection> connections = [];
  final List<TmuxManagementCommand> commands = [];
  final List<Duration> timeouts = [];

  @override
  Future<TmuxCommandOutcome> run(
    SshConnection connection,
    TmuxManagementCommand command, {
    required Duration timeout,
    SshExecCancellation? cancellation,
  }) async {
    connections.add(connection);
    commands.add(command);
    timeouts.add(timeout);
    if (_results.isEmpty) throw StateError('No fake command result remains.');
    final result = _results.removeFirst();
    if (result is Error) throw result;
    return result as TmuxCommandOutcome;
  }
}

class _RecordingPtyOpener implements TmuxPtyOpener {
  _RecordingPtyOpener({this.handle, this.pending, this.error});

  final TmuxAttachHandle? handle;
  final Completer<TmuxAttachHandle>? pending;
  final Object? error;
  SshConnection? connection;
  TmuxAttachCommand? command;
  int? columns;
  int? rows;
  int openCount = 0;

  @override
  Future<TmuxAttachHandle> open(
    SshConnection connection,
    TmuxAttachCommand command, {
    required int columns,
    required int rows,
  }) {
    this.connection = connection;
    this.command = command;
    this.columns = columns;
    this.rows = rows;
    openCount++;
    if (error != null) return Future<TmuxAttachHandle>.error(error!);
    if (pending != null) return pending!.future;
    return Future<TmuxAttachHandle>.value(handle!);
  }
}

class _FakeAttachHandle implements TmuxAttachHandle {
  final StreamController<Uint8List> _stdout =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _stderr =
      StreamController<Uint8List>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool closed = false;
  (int columns, int rows)? lastSize;
  List<int>? lastInput;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> input(Uint8List bytes) async => lastInput = List<int>.of(bytes);

  @override
  void resize(int columns, int rows) => lastSize = (columns, rows);

  @override
  void close() {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

class _RecordingSshSession {
  _RecordingSshSession({
    bool failSignal = false,
    int remoteInitialWindowSize = 0,
  }) {
    channelController = SSHChannelController(
      localId: _nextChannelId++,
      localMaximumPacketSize: 32 * 1024,
      localInitialWindowSize: 2 * 1024 * 1024,
      remoteId: _nextChannelId++,
      remoteInitialWindowSize: remoteInitialWindowSize,
      remoteMaximumPacketSize: 32 * 1024,
      sendMessage: (message) {
        final kind = message.runtimeType.toString();
        final dynamic request = message;
        if (kind == 'SSH_Message_Channel_Request' &&
            request.requestType == 'signal') {
          final signal = request.signalName as String;
          signalAttempts.add(signal);
          if (failSignal) {
            throw StateError('REMOTE-SIGNAL-FAILURE-MARKER');
          }
        }
        if (kind == 'SSH_Message_Channel_Data') {
          inputMessages.add(List<int>.of(request.data as Uint8List));
        }
        events.add(kind);
      },
    );
    session = SSHSession(SSHChannel(channelController));
  }

  static int _nextChannelId = 1;

  late final SSHChannelController channelController;
  late final SSHSession session;
  final List<String> events = [];
  final List<String> signalAttempts = [];
  final List<List<int>> inputMessages = [];
}

class _UnusedSshConnection implements SshConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
