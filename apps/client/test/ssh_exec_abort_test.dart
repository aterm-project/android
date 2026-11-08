import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancel during exec channel open returns and destroys a late channel',
    () async {
      final opening = Completer<SSHSession>();
      final terminalMessages = <SSHMessage>[];
      final terminalSession = _trackingSession(terminalMessages);
      final execMessages = <SSHMessage>[];
      final client = _OpeningSshClient((_) => opening.future);
      final connection = SshConnection(
        client: client,
        session: terminalSession,
      );
      final cancellation = SshExecCancellation();

      final execution = connection.executeRemoteCommand(
        'fixed command',
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();

      final result = await execution.timeout(const Duration(milliseconds: 250));
      expect(result.cancelled, isTrue);
      expect(result.timedOut, isFalse);
      expect(connection.hasUnresolvedExecOpen, isTrue);
      await expectLater(
        connection.executeRemoteCommand(
          'second command must not be queued',
          cancellation: SshExecCancellation(),
        ),
        throwsA(isA<StateError>()),
      );

      final lateSession = _trackingSession(execMessages);
      final lateChannelClosed = _consumeChannelDone(lateSession);
      opening.complete(lateSession);
      await lateChannelClosed.timeout(const Duration(seconds: 1));

      expect(lateSession.stdoutStream.listenCount, 0);
      expect(lateSession.stderrStream.listenCount, 0);
      expect(
        execMessages.whereType<SSH_Message_Channel_Request>().any(
          (request) =>
              request.requestType == SSHChannelRequestType.signal &&
              request.signalName == SSHSignal.TERM.name,
        ),
        isTrue,
      );
      expect(execMessages.whereType<SSH_Message_Channel_Close>(), isNotEmpty);
      expect(connection.hasUnresolvedExecOpen, isFalse);

      terminalSession.channel.destroy();
      await _consumeChannelDone(terminalSession);
    },
  );

  test('stdin close failure destroys the channel and detaches both drains', () async {
    final terminalMessages = <SSHMessage>[];
    final terminalSession = _trackingSession(terminalMessages);
    final execMessages = <SSHMessage>[];
    final execSession = _FailingStdinSession(_trackingChannel(execMessages));
    final client = _OpeningSshClient((_) async => execSession);
    final connection = SshConnection(
      client: client,
      session: terminalSession,
    );

    await expectLater(
      connection.executeRemoteCommand(
        'fixed command',
        cancellation: SshExecCancellation(),
      ),
      throwsA(isA<StateError>()),
    );

    expect(execSession.stdoutStream.listenCount, 1);
    expect(execSession.stdoutStream.cancelCount, 1);
    expect(execSession.stderrStream.listenCount, 1);
    expect(execSession.stderrStream.cancelCount, 1);
    expect(
      execMessages.whereType<SSH_Message_Channel_Request>().any(
        (request) =>
            request.requestType == SSHChannelRequestType.signal &&
            request.signalName == SSHSignal.TERM.name,
      ),
      isTrue,
    );
    expect(execMessages.whereType<SSH_Message_Channel_Close>(), isNotEmpty);

    terminalSession.channel.destroy();
    await _consumeChannelDone(terminalSession);
  });
}

Future<void> _consumeChannelDone(SSHSession session) => session.channel.done
    .then<void>((_) {}, onError: (Object _, StackTrace _) {});

_TrackingSession _trackingSession(List<SSHMessage> messages) {
  return _TrackingSession(_trackingChannel(messages));
}

SSHChannel _trackingChannel(List<SSHMessage> messages) {
  final controller = SSHChannelController(
    localId: messages.length + 1,
    localMaximumPacketSize: 32768,
    localInitialWindowSize: 1024 * 1024,
    remoteId: messages.length + 101,
    remoteMaximumPacketSize: 32768,
    remoteInitialWindowSize: 1024 * 1024,
    sendMessage: messages.add,
  );
  return controller.channel;
}

class _TrackingSession extends SSHSession {
  _TrackingSession(super.channel);

  final stdoutStream = _CountingStream();
  final stderrStream = _CountingStream();

  @override
  Stream<Uint8List> get stdout => stdoutStream;

  @override
  Stream<Uint8List> get stderr => stderrStream;
}

class _FailingStdinSession extends _TrackingSession {
  _FailingStdinSession(super.channel);

  @override
  StreamSink<Uint8List> get stdin => _FailingStdinSink();
}

class _FailingStdinSink implements StreamSink<Uint8List> {
  @override
  void add(Uint8List event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {}

  @override
  Future<void> close() => Future<void>.error(StateError('stdin close failed'));

  @override
  Future<void> get done => Future<void>.value();

}

class _CountingStream extends Stream<Uint8List> {
  int listenCount = 0;
  int cancelCount = 0;
  late final StreamController<Uint8List> _controller =
      StreamController<Uint8List>(
        onListen: () => listenCount++,
        onCancel: () => cancelCount++,
      );

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _OpeningSshClient implements SSHClient {
  _OpeningSshClient(this.open);

  final Future<SSHSession> Function(String command) open;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #execute) {
      return open(invocation.positionalArguments.single as String);
    }
    return super.noSuchMethod(invocation);
  }
}
