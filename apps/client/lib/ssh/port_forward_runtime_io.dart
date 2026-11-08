import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/models.dart';
import 'port_forward_runtime_contract.dart';
import '../l10n/l10n.dart';

SshPortForwardPlatform createSshPortForwardPlatform() =>
    const IoSshPortForwardPlatform();

/// Per-forward limit on simultaneously bridged client connections. It bounds
/// file descriptors and SSH channels if a local client misbehaves.
const int sshPortForwardMaxConnections = 256;

/// Time allowed for an SSH `direct-tcpip` channel to be confirmed, or for the
/// device-side TCP connection of a remote forward to be established.
const Duration sshPortForwardConnectTimeout = Duration(seconds: 20);

/// Time allowed for a SOCKS client to send its greeting and request.
const Duration sshPortForwardSocksHandshakeTimeout = Duration(seconds: 10);

/// After the SSH side has fully closed, remaining bytes are flushed to the
/// local client for at most this long before the socket is destroyed.
const Duration _lingerTimeout = Duration(seconds: 30);

/// `dart:io` forwarding runtime (Windows, Android, Linux, macOS, iOS).
class IoSshPortForwardPlatform implements SshPortForwardPlatform {
  const IoSshPortForwardPlatform({
    this.remoteRequestTimeout = sshPortForwardConnectTimeout,
    this.lateRemoteReplyGrace = const Duration(seconds: 15),
  });

  /// How long a `tcpip-forward` request may take before start fails.
  final Duration remoteRequestTimeout;

  /// After [remoteRequestTimeout], how long a late reply is still awaited so
  /// a listener the server opens late can be cancelled. If the server stays
  /// silent the SSH transport is closed, because it may still open the
  /// listener and every later global request is queued behind this one.
  final Duration lateRemoteReplyGrace;

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => switch (profile.type) {
    SshPortForwardType.local => _startLocal(client, profile),
    SshPortForwardType.remote => _startRemote(
      client,
      profile,
      requestTimeout: remoteRequestTimeout,
      lateReplyGrace: lateRemoteReplyGrace,
    ),
    SshPortForwardType.dynamic => _startDynamic(client, profile),
  };
}

Future<ServerSocket> _bindListener(SshPortForwardProfile profile) async {
  try {
    // `localhost` resolves without DNS on every supported platform; other
    // values are IP literals (enforced by the profile validator).
    return await ServerSocket.bind(profile.bindAddress, profile.bindPort);
  } on SocketException catch (error) {
    throw SshPortForwardException(_describeBindError(profile, error));
  }
}

String _describeBindError(SshPortForwardProfile profile, SocketException e) {
  final endpoint = '${profile.bindAddress}:${profile.bindPort}';
  final code = e.osError?.errorCode;
  // Linux/Android, macOS/iOS, Windows (WSA*) error numbers.
  // Dart reports a same-process duplicate bind with code -1 and a hint about
  // the `shared` flag instead of the OS EADDRINUSE.
  final sameProcessDuplicate =
      code == -1 && (e.osError?.message.contains('shared') ?? false);
  if (sameProcessDuplicate || code == 98 || code == 48 || code == 10048) {
    return currentL10n.portEndpointIsAlreadyInUse(endpoint);
  }
  if (code == 13 || code == 10013) {
    return currentL10n.thisDeviceRefusedToListenOn(endpoint);
  }
  if (code == 99 || code == 49 || code == 10049) {
    return currentL10n.addressBindaddressIsNotAvailableOn(profile.bindAddress);
  }
  return currentL10n.thisDeviceCouldNotListenOn(endpoint);
}

Future<SshPortForwardHandle> _startLocal(
  SSHClient client,
  SshPortForwardProfile profile,
) async {
  final server = await _bindListener(profile);
  return _LocalForwardHandle(
    profile.id,
    server,
    client,
    profile.destinationAddress!,
    profile.destinationPort!,
  );
}

Future<SshPortForwardHandle> _startRemote(
  SSHClient client,
  SshPortForwardProfile profile, {
  required Duration requestTimeout,
  required Duration lateReplyGrace,
}) async {
  // Never inherit dartssh2's default empty bind address, which asks the server
  // for all interfaces. The profile carries an explicit address.
  final request = client.forwardRemote(
    host: profile.bindAddress,
    port: profile.bindPort,
  );
  final SSHRemoteForward? forward;
  try {
    forward = await request.timeout(requestTimeout);
  } on TimeoutException {
    // The request cannot be withdrawn. Track its outcome so a listener the
    // server opens late is cancelled instead of being left untracked.
    unawaited(_reclaimLateRemoteForward(client, request, lateReplyGrace));
    throw SshPortForwardException(currentL10n.theSshServerDidNotAnswer);
  } on SshPortForwardException {
    rethrow;
  } catch (_) {
    throw SshPortForwardException(currentL10n.theSshConnectionIsNoLonger);
  }
  if (forward == null) {
    throw SshPortForwardException(
      currentL10n.forwardRemoteListenerRejected(
        '${profile.bindAddress}:${profile.bindPort}',
      ),
    );
  }
  return _RemoteForwardHandle(
    profile.id,
    client,
    forward,
    profile.destinationAddress!,
    profile.destinationPort!,
  );
}

/// Settles a `tcpip-forward` request that timed out: a late success is
/// cancelled, and the SSH transport is closed whenever removal cannot be
/// confirmed (mirrors [_RemoteForwardHandle.close]).
Future<void> _reclaimLateRemoteForward(
  SSHClient client,
  Future<SSHRemoteForward?> request,
  Duration grace,
) async {
  SSHRemoteForward? late;
  try {
    late = await request.timeout(grace);
  } on TimeoutException {
    await _closeTransportQuietly(client);
    return;
  } catch (_) {
    return; // The request failed; the server opened nothing.
  }
  if (late == null) return; // The server rejected the listener.
  var cancelled = false;
  try {
    cancelled = await client
        .cancelForwardRemote(late)
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    cancelled = false;
  }
  // Closes the local connection stream; after a successful cancellation the
  // forward is no longer registered, so no second cancel request is sent.
  late.close();
  if (!cancelled) await _closeTransportQuietly(client);
}

Future<void> _closeTransportQuietly(SSHClient client) async {
  try {
    await client.close().timeout(const Duration(seconds: 3));
  } catch (_) {}
}

Future<SshPortForwardHandle> _startDynamic(
  SSHClient client,
  SshPortForwardProfile profile,
) async {
  final server = await _bindListener(profile);
  return _DynamicForwardHandle(profile.id, server, client);
}

/// Shared counters, tunnel tracking and change notification.
abstract class _ForwardHandleBase implements SshPortForwardHandle {
  _ForwardHandleBase(this.profileId);

  @override
  final String profileId;
  final Set<_Tunnel> _tunnels = {};
  int _pending = 0;
  int _total = 0;
  String? _lastError;
  bool _closed = false;
  void Function()? _onChanged;

  @override
  bool get isClosed => _closed;

  @override
  int get activeConnections => _tunnels.length + _pending;

  @override
  int get totalConnections => _total;

  @override
  String? get lastConnectionError => _lastError;

  @override
  set onChanged(void Function()? callback) => _onChanged = callback;

  void _notify() {
    final callback = _onChanged;
    if (callback == null) return;
    try {
      callback();
    } catch (_) {
      // A listener failure must not break the forwarding data path.
    }
  }

  /// Reserves a connection slot. Returns false when the limit is reached.
  bool _admit() {
    if (_closed) return false;
    if (activeConnections >= sshPortForwardMaxConnections) {
      _lastError = currentL10n
          .connectionLimitSshportforwardmaxconnectionsReachedNewClients(
            sshPortForwardMaxConnections,
          );
      _notify();
      return false;
    }
    _pending++;
    _total++;
    _notify();
    return true;
  }

  void _releasePending() {
    _pending--;
    _notify();
  }

  void _fail(String message) {
    _lastError = message;
    _notify();
  }

  void _attach(_Tunnel tunnel) {
    _pending--;
    _tunnels.add(tunnel);
    _notify();
    unawaited(
      tunnel.finished.whenComplete(() {
        if (_tunnels.remove(tunnel)) _notify();
      }),
    );
  }

  Future<void> _closeTunnels() async {
    final tunnels = _tunnels.toList(growable: false);
    _tunnels.clear();
    for (final tunnel in tunnels) {
      tunnel.abort();
    }
    try {
      await Future.wait(tunnels.map((tunnel) => tunnel.finished))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// Opens an SSH `direct-tcpip` channel with a timeout. A channel confirmed
/// after the timeout is destroyed instead of leaking inside the SSH client.
Future<SSHForwardChannel> _openDirectChannel(
  SSHClient client,
  String host,
  int port,
) {
  final opening = client.forwardLocal(host, port);
  final completer = Completer<SSHForwardChannel>();
  final timer = Timer(sshPortForwardConnectTimeout, () {
    if (completer.isCompleted) return;
    completer.completeError(
      TimeoutException(
        'SSH channel open timed out',
        sshPortForwardConnectTimeout,
      ),
    );
  });
  opening.then(
    (channel) {
      timer.cancel();
      if (completer.isCompleted) {
        channel.destroy();
      } else {
        completer.complete(channel);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  return completer.future;
}

String _describeChannelOpenError(Object error, String host, int port) {
  final target = _formatEndpoint(host, port);
  if (error is SSHChannelOpenError) {
    return switch (error.code) {
      1 => currentL10n.theSshServerDeniedForwardingTo(target),
      2 => currentL10n.theSshServerCouldNotConnect(target),
      4 => currentL10n.theSshServerIsOutOf,
      _ => currentL10n.theSshServerRefusedAChannel(target),
    };
  }
  if (error is TimeoutException) {
    return currentL10n.timedOutOpeningAnSshChannel(target);
  }
  return currentL10n.couldNotOpenAnSshChannel(target);
}

String _formatEndpoint(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

class _LocalForwardHandle extends _ForwardHandleBase {
  _LocalForwardHandle(
    super.profileId,
    this._server,
    this._client,
    this._destinationHost,
    this._destinationPort,
  ) {
    _port; // resolve while the socket is open
    _listener = _server.listen(
      _accept,
      onError: (Object _) => _listenerFailed(),
      onDone: _listenerFailed,
    );
  }

  final ServerSocket _server;
  // ServerSocket.port throws after close; keep the bound port readable.
  late final int _port = _server.port;
  final SSHClient _client;
  final String _destinationHost;
  final int _destinationPort;
  late final StreamSubscription<Socket> _listener;

  @override
  int get listeningPort => _port;

  void _listenerFailed() {
    if (_closed) return;
    _lastError = currentL10n.theDeviceListenerStoppedUnexpectedly;
    unawaited(close());
  }

  void _accept(Socket socket) {
    if (!_admit()) {
      socket.destroy();
      return;
    }
    unawaited(_openChannel(socket));
  }

  Future<void> _openChannel(Socket socket) async {
    _swallowSocketErrors(socket);
    SSHForwardChannel channel;
    try {
      channel = await _openDirectChannel(
        _client,
        _destinationHost,
        _destinationPort,
      );
    } catch (error) {
      socket.destroy();
      _releasePending();
      _fail(
        _describeChannelOpenError(error, _destinationHost, _destinationPort),
      );
      return;
    }
    if (_closed) {
      socket.destroy();
      channel.destroy();
      _releasePending();
      return;
    }
    _attach(_Tunnel(socket, channel, upstream: socket));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _listener.cancel();
    await _server.close();
    await _closeTunnels();
    _notify();
  }
}

class _RemoteForwardHandle extends _ForwardHandleBase {
  _RemoteForwardHandle(
    super.profileId,
    this._client,
    this._forward,
    this._destinationHost,
    this._destinationPort,
  ) {
    _listener = _forward.connections.listen(_accept);
  }

  final SSHClient _client;
  final SSHRemoteForward _forward;
  final String _destinationHost;
  final int _destinationPort;
  late final StreamSubscription<SSHForwardChannel> _listener;

  @override
  int get listeningPort => _forward.port;

  void _accept(SSHForwardChannel channel) {
    if (!_admit()) {
      channel.destroy();
      return;
    }
    unawaited(_connectLocal(channel));
  }

  Future<void> _connectLocal(SSHForwardChannel channel) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        _destinationHost,
        _destinationPort,
        timeout: sshPortForwardConnectTimeout,
      );
    } catch (_) {
      channel.destroy();
      _releasePending();
      _fail(
        currentL10n.forwardLocalDestinationUnreachable(
          _formatEndpoint(_destinationHost, _destinationPort),
        ),
      );
      return;
    }
    _swallowSocketErrors(socket);
    if (_closed) {
      socket.destroy();
      channel.destroy();
      _releasePending();
      return;
    }
    _attach(_Tunnel(socket, channel, upstream: socket));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _listener.cancel();
    var cancelled = false;
    try {
      try {
        cancelled = await _client
            .cancelForwardRemote(_forward)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        cancelled = false;
      }
    } finally {
      // SSHRemoteForward.close also closes its incoming stream controller. The
      // cancellation request above removed it from SSHClient first, so this
      // does not send a second request.
      _forward.close();
      await _closeTunnels();
      _notify();
    }
    if (!cancelled) {
      // The server may still be listening if it rejected cancellation. Close
      // this SSH transport so the remote listener is torn down with the
      // session; leaving it alive would make Stop appear successful while
      // the listener could still accept connections.
      try {
        await _client.close().timeout(const Duration(seconds: 3));
      } catch (_) {}
      throw StateError(currentL10n.theSshServerDidNotConfirm);
    }
  }
}

class _DynamicForwardHandle extends _ForwardHandleBase {
  _DynamicForwardHandle(super.profileId, this._server, this._client) {
    _port; // resolve while the socket is open
    _listener = _server.listen(
      _accept,
      onError: (Object _) => _listenerFailed(),
      onDone: _listenerFailed,
    );
  }

  final ServerSocket _server;
  // ServerSocket.port throws after close; keep the bound port readable.
  late final int _port = _server.port;
  final SSHClient _client;
  late final StreamSubscription<Socket> _listener;
  final Set<_SocksHandshake> _handshakes = {};

  @override
  int get listeningPort => _port;

  void _listenerFailed() {
    if (_closed) return;
    _lastError = currentL10n.theDeviceSocksListenerStoppedUnexpectedly;
    unawaited(close());
  }

  void _accept(Socket socket) {
    if (!_admit()) {
      socket.destroy();
      return;
    }
    _swallowSocketErrors(socket);
    late final _SocksHandshake handshake;
    handshake = _SocksHandshake(
      socket,
      (host, port) => _openDirectChannel(_client, host, port),
      (tunnel) {
        _handshakes.remove(handshake);
        if (_closed) {
          tunnel.abort();
          _releasePending();
          return;
        }
        _attach(tunnel);
      },
      (message) {
        _handshakes.remove(handshake);
        _releasePending();
        if (message != null) _fail(message);
      },
    );
    _handshakes.add(handshake);
    handshake.start();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _listener.cancel();
    await _server.close();
    for (final handshake in _handshakes.toList(growable: false)) {
      handshake.abort();
    }
    _handshakes.clear();
    await _closeTunnels();
    _notify();
  }
}

void _swallowSocketErrors(Socket socket) {
  // Write errors (peer reset) surface on `done`; they are handled by the
  // tunnel abort path and must not become unhandled zone errors.
  unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
}

/// Bridges one TCP socket and one SSH channel.
///
/// * Backpressure: socket → channel uses `addStream`, which pauses the socket
///   while dartssh2 waits for remote window; channel → socket pauses the
///   channel stream (withholding SSH window adjusts) until the socket flushed.
/// * Half-close: EOF from the socket becomes SSH `CHANNEL_EOF`; SSH EOF
///   becomes a TCP write shutdown. The tunnel ends when both directions have
///   ended, when the SSH channel is closed and its data flushed, or on abort.
class _Tunnel {
  _Tunnel(
    this._socket,
    this._channel, {
    required Stream<Uint8List> upstream,
    Uint8List? initialUpstream,
  }) {
    _start(upstream, initialUpstream);
  }

  final Socket _socket;
  final SSHForwardChannel _channel;
  final Completer<void> _finished = Completer<void>();
  StreamSubscription<Uint8List>? _downstream;
  bool _upstreamDone = false;
  bool _downstreamDone = false;
  bool _channelClosed = false;
  bool _aborted = false;

  Future<void> get finished => _finished.future;

  void _start(Stream<Uint8List> upstream, Uint8List? initialUpstream) {
    unawaited(
      _channel.done.then<void>(
        (_) => _onChannelClosed(),
        onError: (Object _) => _onChannelClosed(),
      ),
    );
    if (initialUpstream != null && initialUpstream.isNotEmpty) {
      _channel.sink.add(initialUpstream);
    }
    final guarded = upstream.transform(
      StreamTransformer<Uint8List, Uint8List>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          abort();
          sink.close();
        },
      ),
    );
    unawaited(
      _channel.sink
          .addStream(guarded)
          .then<void>((_) => _onUpstreamDone(), onError: (Object _) => abort()),
    );
    _downstream = _channel.stream.listen(
      _onDownstreamData,
      onError: (Object _) => abort(),
      onDone: () => unawaited(_onDownstreamDone()),
      cancelOnError: true,
    );
  }

  void _onDownstreamData(Uint8List data) {
    if (_aborted) return;
    try {
      _socket.add(data);
    } catch (_) {
      abort();
      return;
    }
    final subscription = _downstream;
    if (subscription == null) return;
    // Withhold further SSH window credit until the local client has taken
    // these bytes. Errors here mean the client reset the connection.
    subscription.pause(
      _socket.flush().then<void>((_) {}, onError: (Object _) => abort()),
    );
  }

  void _onUpstreamDone() {
    if (_aborted || _upstreamDone) return;
    _upstreamDone = true;
    // Queue SSH EOF after any buffered bytes. Not awaited: the future only
    // completes once dartssh2 has drained it, and abort() cancels that.
    unawaited(_channel.sink.close().then<void>((_) {}, onError: (Object _) {}));
    _maybeFinish();
  }

  Future<void> _onDownstreamDone() async {
    if (_aborted || _downstreamDone) return;
    try {
      await _socket.close().timeout(_lingerTimeout);
    } catch (_) {
      abort();
      return;
    }
    _downstreamDone = true;
    _maybeFinish();
  }

  void _onChannelClosed() {
    if (_channelClosed) return;
    _channelClosed = true;
    _maybeFinish();
  }

  void _maybeFinish() {
    if (_aborted) return;
    // The SSH side is gone once it closed the channel; after its data has
    // been flushed (downstream done) there is nothing left to deliver.
    if (_downstreamDone && (_upstreamDone || _channelClosed)) _teardown();
  }

  void abort() {
    if (_aborted) return;
    _teardown();
  }

  void _teardown() {
    _aborted = true;
    unawaited(_downstream?.cancel());
    _channel.destroy();
    _socket.destroy();
    if (!_finished.isCompleted) _finished.complete();
  }
}

typedef _SocksDial = Future<SSHForwardChannel> Function(String host, int port);

/// Minimal SOCKS server matching `ssh -D`: SOCKS4, SOCKS4a and SOCKS5 with
/// the CONNECT command and no authentication. Targets are resolved by the SSH
/// server; nothing is resolved on this device.
class _SocksHandshake {
  _SocksHandshake(this._socket, this._dial, this._onTunnel, this._onFailed);

  static const _maxHandshakeBytes = 1024;

  final Socket _socket;
  final _SocksDial _dial;
  final void Function(_Tunnel tunnel) _onTunnel;
  final void Function(String? message) _onFailed;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> _subscription;
  Timer? _timer;
  bool _greeted = false;
  bool _dialing = false;
  bool _done = false;

  void start() {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => _finishFailed(null),
      onDone: () => _finishFailed(null),
      cancelOnError: true,
    );
    _timer = Timer(sshPortForwardSocksHandshakeTimeout, () {
      _finishFailed('A SOCKS client did not finish its handshake in time.');
    });
  }

  void abort() => _finishFailed(null);

  void _onData(Uint8List chunk) {
    if (_done || _dialing) return;
    if (_buffer.length + chunk.length > _maxHandshakeBytes) {
      _finishFailed('A SOCKS client sent an oversized handshake.');
      return;
    }
    _buffer.add(chunk);
    _consume();
  }

  void _consume() {
    final data = _buffer.toBytes();
    if (data.isEmpty) return;
    switch (data[0]) {
      case 0x05:
        _consumeSocks5(data);
      case 0x04:
        if (_greeted) return _malformed();
        _consumeSocks4(data);
      default:
        _malformed();
    }
  }

  void _consumeSocks5(Uint8List data) {
    var offset = 0;
    if (!_greeted) {
      if (data.length < 2) return;
      final methods = data[1];
      if (data.length < 2 + methods) return;
      final offered = data.sublist(2, 2 + methods);
      if (!offered.contains(0x00)) {
        // RFC 1928: X'FF' NO ACCEPTABLE METHODS, then close.
        _replyAndClose(
          [0x05, 0xff],
          'A SOCKS client offered no supported '
          'authentication method (only "no authentication" is supported).',
        );
        return;
      }
      _write([0x05, 0x00]);
      _greeted = true;
      offset = 2 + methods;
    }
    final request = Uint8List.sublistView(data, offset);
    if (request.length < 4) return _keep(request);
    if (request[0] != 0x05 || request[2] != 0x00) {
      return _malformed(socks5: true);
    }
    final command = request[1];
    final addressType = request[3];
    int length;
    switch (addressType) {
      case 0x01:
        length = 4 + 4 + 2;
      case 0x03:
        if (request.length < 5) return _keep(request);
        if (request[4] == 0) return _malformed(socks5: true);
        length = 4 + 1 + request[4] + 2;
      case 0x04:
        length = 4 + 16 + 2;
      default:
        _replyAndClose(
          _socks5Reply(0x08),
          'A SOCKS client used an unsupported address type.',
        );
        return;
    }
    if (request.length < length) return _keep(request);
    if (command != 0x01) {
      _replyAndClose(
        _socks5Reply(0x07),
        'A SOCKS client requested an unsupported command (only CONNECT).',
      );
      return;
    }
    final String host;
    switch (addressType) {
      case 0x01:
        host = request.sublist(4, 8).join('.');
      case 0x03:
        final raw = request.sublist(5, 5 + request[4]);
        try {
          host = utf8.decode(raw);
        } on FormatException {
          return _malformed(socks5: true);
        }
        if (host.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
          return _malformed(socks5: true);
        }
      default:
        host = InternetAddress.fromRawAddress(
          Uint8List.fromList(request.sublist(4, 20)),
          type: InternetAddressType.IPv6,
        ).address;
    }
    final port = (request[length - 2] << 8) | request[length - 1];
    if (port == 0) return _malformed(socks5: true);
    final rest = Uint8List.fromList(request.sublist(length));
    unawaited(_connect(host, port, rest, socks5: true));
  }

  void _consumeSocks4(Uint8List data) {
    if (data.length < 9) return;
    if (data[1] != 0x01) {
      _replyAndClose(
        _socks4Reply(false),
        'A SOCKS4 client requested an unsupported command (only CONNECT).',
      );
      return;
    }
    final port = (data[2] << 8) | data[3];
    final ip = data.sublist(4, 8);
    final userEnd = data.indexOf(0, 8);
    if (userEnd < 0) return;
    var end = userEnd + 1;
    String host;
    final isSocks4a = ip[0] == 0 && ip[1] == 0 && ip[2] == 0 && ip[3] != 0;
    if (isSocks4a) {
      final hostEnd = data.indexOf(0, end);
      if (hostEnd < 0) return;
      final raw = data.sublist(end, hostEnd);
      if (raw.isEmpty) return _malformed();
      try {
        host = ascii.decode(raw);
      } on FormatException {
        return _malformed();
      }
      if (host.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) return _malformed();
      end = hostEnd + 1;
    } else {
      host = ip.join('.');
    }
    if (port == 0) {
      _replyAndClose(_socks4Reply(false), 'A SOCKS4 client sent port 0.');
      return;
    }
    final rest = Uint8List.fromList(data.sublist(end));
    unawaited(_connect(host, port, rest, socks5: false));
  }

  void _keep(Uint8List remaining) {
    _buffer.clear();
    _buffer.add(Uint8List.fromList(remaining));
  }

  Future<void> _connect(
    String host,
    int port,
    Uint8List pending, {
    required bool socks5,
  }) async {
    _dialing = true;
    _timer?.cancel();
    _timer = null;
    // Stop reading while dialing; bytes the client sends early stay in the
    // socket and are delivered through the tunnel afterwards.
    _subscription.pause();
    SSHForwardChannel channel;
    try {
      channel = await _dial(host, port);
    } catch (error) {
      if (_done) return;
      _replyAndClose(
        socks5 ? _socks5Reply(_socks5FailureCode(error)) : _socks4Reply(false),
        _describeChannelOpenError(error, host, port),
      );
      return;
    }
    if (_done) {
      channel.destroy();
      return;
    }
    _done = true;
    _write(socks5 ? _socks5Reply(0x00) : _socks4Reply(true));
    _onTunnel(
      _Tunnel(
        _socket,
        channel,
        upstream: _adoptSubscription(),
        initialUpstream: pending,
      ),
    );
  }

  /// Turns the paused handshake subscription into a stream for the tunnel,
  /// keeping pause/resume (backpressure) and cancellation connected.
  Stream<Uint8List> _adoptSubscription() {
    final subscription = _subscription;
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      sync: true,
      onListen: subscription.resume,
      onPause: subscription.pause,
      onResume: subscription.resume,
      onCancel: subscription.cancel,
    );
    subscription
      ..onData(controller.add)
      ..onError(controller.addError)
      ..onDone(controller.close);
    return controller.stream;
  }

  static int _socks5FailureCode(Object error) {
    if (error is SSHChannelOpenError) {
      return switch (error.code) {
        1 => 0x02, // connection not allowed by ruleset
        2 => 0x05, // connection refused / target unreachable from server
        _ => 0x01,
      };
    }
    if (error is TimeoutException) return 0x04; // host unreachable
    return 0x01; // general SOCKS server failure
  }

  static List<int> _socks5Reply(int code) => [
    0x05,
    code,
    0x00,
    0x01,
    0,
    0,
    0,
    0,
    0,
    0,
  ];

  static List<int> _socks4Reply(bool granted) => [
    0x00,
    granted ? 0x5a : 0x5b,
    0,
    0,
    0,
    0,
    0,
    0,
  ];

  void _malformed({bool socks5 = false}) {
    if (socks5 && _greeted) {
      _replyAndClose(
        _socks5Reply(0x01),
        'A SOCKS client sent a malformed request.',
      );
    } else {
      _finishFailed('A SOCKS client sent a malformed request.');
    }
  }

  void _write(List<int> bytes) {
    try {
      _socket.add(bytes);
    } catch (_) {}
  }

  void _replyAndClose(List<int> reply, String message) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    _write(reply);
    // Flush the reply, then close; destroy if the client stops reading.
    unawaited(
      _socket
          .close()
          .timeout(const Duration(seconds: 5))
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(_socket.destroy),
    );
    _onFailed(message);
  }

  void _finishFailed(String? message) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    _socket.destroy();
    _onFailed(message);
  }
}
