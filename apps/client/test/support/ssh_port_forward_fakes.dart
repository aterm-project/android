import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for one SSH `direct-tcpip`/`forwarded-tcpip` channel.
///
/// * Bytes the tunnel writes to [sink] arrive on [received] (server side).
///   Closing [sink] is the SSH `CHANNEL_EOF` from the client.
/// * The test plays the server with [serverSend] / [serverEof] /
///   [serverClose]. Pausing a listener of [stream] withholds window, so
///   [serverOutPaused] reports downstream backpressure.
class FakeSshForwardChannel implements SSHForwardChannel {
  final StreamController<List<int>> _fromClient = StreamController();
  final StreamController<Uint8List> _toClient = StreamController();
  final Completer<void> _done = Completer<void>();
  bool isDestroyed = false;

  Stream<List<int>> get received => _fromClient.stream;
  bool get serverOutPaused => _toClient.isPaused;
  bool get serverOutHasListener => _toClient.hasListener;

  void serverSend(List<int> bytes) => _toClient.add(Uint8List.fromList(bytes));

  /// Server half-close (SSH EOF): no more data from the server.
  void serverEof() {
    if (!_toClient.isClosed) unawaited(_toClient.close());
  }

  /// Server closed the channel (EOF + CHANNEL_CLOSE).
  void serverClose() {
    serverEof();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Stream<Uint8List> get stream => _toClient.stream;

  @override
  StreamSink<List<int>> get sink => _fromClient.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async => destroy();

  @override
  Future<void> flush() async {}

  @override
  void destroy() {
    if (isDestroyed) return;
    isDestroyed = true;
    serverEof();
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeRemoteForward implements SSHRemoteForward {
  FakeRemoteForward(this.host, this.port);

  @override
  final String host;
  @override
  final int port;
  @override
  SSHRemoteConnectionFilter? get filter => null;

  final StreamController<SSHForwardChannel> incoming = StreamController();
  bool closed = false;

  @override
  Stream<SSHForwardChannel> get connections => incoming.stream;

  @override
  void close() {
    closed = true;
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

typedef FakeDialHandler = Future<SSHForwardChannel> Function(
  String host,
  int port,
);

class FakeForwardingSshClient extends Fake implements SSHClient {
  FakeForwardingSshClient({FakeDialHandler? onDial}) : _onDial = onDial;

  final FakeDialHandler? _onDial;
  final Completer<void> _done = Completer<void>();
  final List<(String, int)> dials = [];
  final List<FakeSshForwardChannel> channels = [];
  final List<FakeSshForwardChannel> _unclaimed = [];
  final List<Completer<FakeSshForwardChannel>> _claims = [];
  final StreamController<FakeSshForwardChannel> _opened =
      StreamController.broadcast();
  bool rejectRemoteForward = false;

  /// When set, the `tcpip-forward` reply is delayed until it completes.
  Completer<void>? remoteReplyGate;
  bool rejectRemoteCancel = false;
  String? remoteBindHost;
  int? remoteBindPort;
  FakeRemoteForward? remoteForward;
  int remoteCancelCount = 0;
  int closeCount = 0;

  /// Every opened channel, for listeners registered before connections.
  Stream<FakeSshForwardChannel> get opened => _opened.stream;

  /// The next opened channel not yet claimed, even if it opened earlier.
  Future<FakeSshForwardChannel> nextChannel() {
    if (_unclaimed.isNotEmpty) return Future.value(_unclaimed.removeAt(0));
    final claim = Completer<FakeSshForwardChannel>();
    _claims.add(claim);
    return claim.future.timeout(const Duration(seconds: 3));
  }

  /// Simulates the SSH transport ending (network loss, server exit).
  void endTransport() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    dials.add((remoteHost, remotePort));
    final handler = _onDial;
    if (handler != null) return handler(remoteHost, remotePort);
    final channel = FakeSshForwardChannel();
    channels.add(channel);
    _opened.add(channel);
    if (_claims.isNotEmpty) {
      _claims.removeAt(0).complete(channel);
    } else {
      _unclaimed.add(channel);
    }
    return channel;
  }

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    remoteBindHost = host;
    remoteBindPort = port;
    final gate = remoteReplyGate;
    if (gate != null) await gate.future;
    if (rejectRemoteForward) return null;
    return remoteForward = FakeRemoteForward(
      host ?? '',
      port == null || port == 0 ? 62001 : port,
    );
  }

  /// When set, `cancel-tcpip-forward` replies only when it completes (a
  /// dead transport may never answer).
  Completer<void>? remoteCancelGate;

  @override
  Future<bool> cancelForwardRemote(SSHRemoteForward forward) async {
    remoteCancelCount++;
    final gate = remoteCancelGate;
    if (gate != null) await gate.future;
    return !rejectRemoteCancel;
  }

  @override
  Future<void> close() async {
    closeCount++;
    endTransport();
  }
}

/// Echo server-side behaviour for a fake channel: every byte received is sent
/// back; client EOF becomes server EOF and then channel close.
void echoOnFakeChannel(FakeSshForwardChannel channel) {
  channel.received.listen(channel.serverSend, onDone: channel.serverClose);
}
