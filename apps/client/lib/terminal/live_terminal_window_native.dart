import '../platform/window_launch_environment.dart';
import '../domain/window_placement.dart';
import '../platform/window_geometry_rpc.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';
import 'live_terminal_window_contract.dart';
import 'mirrored_terminal.dart';

const _origin = 'atermius://terminal-window';
const _protocol = 'atermius-terminal-v1';
const _capabilityEnv = 'ATERMIUS_TERMINAL_WINDOW_CAPABILITY';
const _maxFrameBytes = 4 * 1024 * 1024;
const _maxInputBytes = 64 * 1024;
const _maxOutstandingBytes = 512 * 1024;

// The owning engine can be hidden safely only by the Windows close-guard bridge.
bool get supportsLiveTerminalWindows => Platform.isWindows;
String _nonce(int bytes) => base64UrlEncode(
  List<int>.generate(bytes, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');
bool _validId(String value) => RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value);
bool _validCapability(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
bool _equalCapability(String supplied, String expected) {
  if (supplied.length != expected.length) return false;
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= supplied.codeUnitAt(index) ^ expected.codeUnitAt(index);
  }
  return difference == 0;
}

LiveTerminalWindowLaunch? detectLiveTerminalWindow(List<String> arguments) {
  final ports = arguments
      .where((arg) => arg.startsWith('--terminal-window-port='))
      .toList();
  final sessions = arguments
      .where((arg) => arg.startsWith('--terminal-window-session='))
      .toList();
  if (ports.isEmpty && sessions.isEmpty) return null;
  if (ports.length != 1 || sessions.length != 1) {
    throw const FormatException('Invalid terminal window launch.');
  }
  final port = int.tryParse(ports.single.split('=').last);
  final sessionId = sessions.single.split('=').last;
  final capability = Platform.environment[_capabilityEnv] ?? '';
  if (port == null ||
      port < 1 ||
      port > 65535 ||
      !_validId(sessionId) ||
      !_validCapability(capability)) {
    throw const FormatException('Invalid terminal window launch.');
  }
  return LiveTerminalWindowLaunch(
    port: port,
    sessionId: sessionId,
    capability: capability,
  );
}

/// Testable loopback endpoint. It never owns, reconnects, or closes SSH.
class LiveTerminalBroker {
  LiveTerminalBroker._(
    this._server,
    this.terminal,
    this.title,
    this.sessionId,
    this._capability,
    this._onReady,
    this._onClosed,
    this._onOpenFiles,
  );
  final HttpServer _server;
  final MirroredTerminal terminal;
  final String title, sessionId, _capability;
  final VoidCallback? _onReady;
  final ValueChanged<LiveTerminalWindowCloseReason>? _onClosed;
  final VoidCallback? _onOpenFiles;
  final _geometry = WindowGeometryRpcOwner();
  final _ready = Completer<bool>();
  final _closed = Completer<void>();
  final _outcome = Completer<LiveTerminalWindowCloseReason>();
  WebSocket? _socket;
  void Function(String)? _sshInput;
  void Function(int, int, int, int)? _ptyResize;
  bool _ownsTerminalCallbacks = false;
  StreamSubscription<MirroredTerminalChunk>? _output;
  bool _claimed = false, _disposed = false, _clientReady = false;
  final Queue<({int sequence, int bytes})> _unacknowledged = Queue();
  int _outstandingBytes = 0, _lastSent = 0, _lastAcknowledged = 0;
  int _inputBytes = 0, _messages = 0;
  DateTime _rateWindow = DateTime.now();
  Timer? _timer;
  int get port => _server.port;
  Future<bool> get ready => _ready.future;
  Future<void> get closed => _closed.future;
  Future<LiveTerminalWindowCloseReason> get outcome => _outcome.future;
  LiveTerminalWindowLaunch get launch => LiveTerminalWindowLaunch(
    port: port,
    sessionId: sessionId,
    capability: _capability,
  );

  Future<SavedWindowPlacement?> capturePlacement() async {
    if (_disposed || !_clientReady) return null;
    return _geometry.capture((message) => _socket?.add(jsonEncode(message)));
  }

  Future<bool> applyPlacement(SavedWindowPlacement value) async {
    if (_disposed || !_clientReady) return false;
    return _geometry.apply((message) => _socket?.add(jsonEncode(message)), value);
  }

  static Future<LiveTerminalBroker> bind({
    required MirroredTerminal terminal,
    required String title,
    VoidCallback? onReady,
    ValueChanged<LiveTerminalWindowCloseReason>? onClosed,
    VoidCallback? onOpenFiles,
    Duration readyTimeout = const Duration(seconds: 30),
  }) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final broker = LiveTerminalBroker._(
      server,
      terminal,
      title.substring(0, title.length.clamp(0, 256)),
      _nonce(16),
      _nonce(32),
      onReady,
      onClosed,
      onOpenFiles,
    );
    server.listen(
      (request) {
        unawaited(
          broker._request(request).catchError((Object _) async {
            try {
              request.response.statusCode = HttpStatus.forbidden;
              await request.response.close();
            } catch (_) {}
          }),
        );
      },
      onError: (_) => unawaited(
        broker.close(reason: LiveTerminalWindowCloseReason.transportLost),
      ),
    );
    broker._timer = Timer(
      readyTimeout,
      () => unawaited(
        broker.close(reason: LiveTerminalWindowCloseReason.startupFailed),
      ),
    );
    return broker;
  }

  Future<void> _request(HttpRequest request) async {
    // Browser origins cannot attach to this endpoint, including localhost web
    // pages. Capability material never appears in URLs, argv, disk or errors.
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final supplied = authorization.startsWith('Bearer ')
        ? authorization.substring(7)
        : '';
    final valid =
        !_disposed &&
        !_claimed &&
        request.method == 'GET' &&
        request.connectionInfo?.remoteAddress.isLoopback == true &&
        request.headers.value(HttpHeaders.hostHeader) == '127.0.0.1:$port' &&
        request.headers.value('origin') == _origin &&
        request.uri.path == '/live/$sessionId' &&
        !request.uri.hasQuery &&
        (request.headers.value('sec-websocket-protocol') ?? '')
            .split(',')
            .map((v) => v.trim())
            .contains(_protocol) &&
        _equalCapability(supplied, _capability) &&
        WebSocketTransformer.isUpgradeRequest(request);
    if (!valid) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    _claimed = true;
    try {
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => _protocol,
        compression: CompressionOptions.compressionOff,
        maxPayloadLength: _maxInputBytes + 1024,
      );
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 10);
      // This subscription/snapshot/send block is synchronous. Dart's event
      // loop cannot interleave an SSH write between these operations.
      _output = terminal.mirroredOutput.listen(
        _sendOutput,
        onDone: () => unawaited(close()),
        onError: (_) => unawaited(
          close(reason: LiveTerminalWindowCloseReason.transportLost),
        ),
      );
      _lastSent = terminal.sequence;
      _lastAcknowledged = _lastSent;
      socket.add(
        jsonEncode({
          'type': 'init',
          'title': title,
          'columns': terminal.viewWidth,
          'rows': terminal.viewHeight,
          'sequence': _lastSent,
          'truncated': terminal.historyTruncated,
          'history': terminal.history,
        }),
      );
      socket.listen(
        _message,
        onDone: () => unawaited(
          close(reason: LiveTerminalWindowCloseReason.transportLost),
        ),
        onError: (_) => unawaited(
          close(reason: LiveTerminalWindowCloseReason.transportLost),
        ),
        cancelOnError: true,
      );
    } catch (_) {
      await close();
    }
  }

  void _sendOutput(MirroredTerminalChunk chunk) {
    if (_disposed || _socket == null) return;
    final encoded = jsonEncode({
      'type': 'output',
      'sequence': chunk.sequence,
      'data': chunk.data,
    });
    final bytes = utf8.encode(encoded).length;
    if (_outstandingBytes + bytes > _maxOutstandingBytes ||
        _unacknowledged.length >= 256) {
      unawaited(
        close(reason: LiveTerminalWindowCloseReason.transportLost),
      ); // Disconnect a stalled receiver; never block SSH.
      return;
    }
    _lastSent = chunk.sequence;
    _unacknowledged.addLast((sequence: chunk.sequence, bytes: bytes));
    _outstandingBytes += bytes;
    _socket!.add(encoded);
  }

  void _message(dynamic message) {
    if (_disposed ||
        message is! String ||
        utf8.encode(message).length > _maxInputBytes + 1024) {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
      return;
    }
    final now = DateTime.now();
    if (now.difference(_rateWindow) >= const Duration(seconds: 1)) {
      _rateWindow = now;
      _inputBytes = 0;
      _messages = 0;
    }
    if (++_messages > 512) {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
      return;
    }
    try {
      final data = jsonDecode(message);
      if (data is! Map<String, dynamic>) throw const FormatException();
      switch (data['type']) {
        case 'window_geometry_reply':
          if (!_clientReady || !_geometry.receive(data)) throw const FormatException();
        case 'ready':
          if (_clientReady || data['sequence'] != _lastAcknowledged) {
            throw const FormatException();
          }
          _clientReady = true;
          _sshInput = terminal.onOutput;
          _ptyResize = terminal.onResize;
          terminal.onOutput = null;
          terminal.onResize = null;
          _ownsTerminalCallbacks = true;
          _socket?.add(
            jsonEncode({'type': 'owner', 'after_sequence': terminal.sequence}),
          );
          _timer?.cancel();
          if (!_ready.isCompleted) _ready.complete(true);
          _onReady?.call();
        case 'ack':
          final sequence = data['sequence'];
          if (sequence is! int ||
              sequence < _lastAcknowledged ||
              sequence > _lastSent) {
            throw const FormatException();
          }
          _lastAcknowledged = sequence;
          while (_unacknowledged.isNotEmpty &&
              _unacknowledged.first.sequence <= sequence) {
            _outstandingBytes -= _unacknowledged.removeFirst().bytes;
          }
        case 'input':
          if (!_clientReady || data['data'] is! String) {
            throw const FormatException();
          }
          final input = data['data'] as String;
          final bytes = utf8.encode(input).length;
          _inputBytes += bytes;
          if (bytes > _maxInputBytes || _inputBytes > 256 * 1024) {
            throw const FormatException();
          }
          _sshInput?.call(input);
        case 'resize':
          final columns = data['columns'], rows = data['rows'];
          final width = data['pixel_width'], height = data['pixel_height'];
          if (columns is! int ||
              rows is! int ||
              width is! int ||
              height is! int ||
              columns < 2 ||
              columns > 500 ||
              rows < 1 ||
              rows > 300 ||
              width < 0 ||
              width > 16384 ||
              height < 0 ||
              height > 16384) {
            throw const FormatException();
          }
          terminal.resize(columns, rows, width, height);
          if (_ownsTerminalCallbacks) {
            _ptyResize?.call(columns, rows, width, height);
          }
        case 'open_files':
          if (!_clientReady) throw const FormatException();
          _onOpenFiles?.call();
        case 'close':
          if (!_clientReady) throw const FormatException();
          _socket?.add(jsonEncode({'type': 'close_ack'}));
          unawaited(close(reason: LiveTerminalWindowCloseReason.user));
        default:
          throw const FormatException();
      }
    } catch (_) {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
    }
  }

  Future<void> close({
    LiveTerminalWindowCloseReason reason =
        LiveTerminalWindowCloseReason.parentClosed,
  }) async {
    if (_disposed) return _closed.future;
    _geometry.close();
    _disposed = true;
    _timer?.cancel();
    if (!_ready.isCompleted) _ready.complete(false);
    try {
      await _output?.cancel();
    } catch (_) {}
    try {
      await _socket
          ?.close(WebSocketStatus.normalClosure, 'Terminal window closed.')
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    if (_ownsTerminalCallbacks) {
      terminal.onOutput ??= _sshInput;
      terminal.onResize ??= _ptyResize;
      _ownsTerminalCallbacks = false;
    }
    try {
      await _server.close(force: true);
    } catch (_) {}
    if (!_closed.isCompleted) _closed.complete();
    if (!_outcome.isCompleted) _outcome.complete(reason);
    try {
      _onClosed?.call(reason);
    } catch (_) {}
  }
}

/// Owns only the Process.start child supplied by the caller. Socket loss never
/// kills it; explicit owner revocation does, even if the socket was lost first.
class OwnedLiveTerminalChild {
  OwnedLiveTerminalChild({
    required Process process,
    required Future<void> Function() stopBroker,
    required Future<void> Function() onProcessExit,
    this.exitTimeout = const Duration(seconds: 3),
  }) : _process = process,
       // Keep the callback private while allowing scoped lifecycle tests.
       // ignore: prefer_initializing_formals
       _stopBroker = stopBroker {
    exited = process.exitCode.then<void>((_) {
      _hasExited = true;
      unawaited(onProcessExit().catchError((Object _) {}));
    });
  }
  final Process _process;
  final Future<void> Function() _stopBroker;
  final Duration exitTimeout;
  late final Future<void> exited;
  bool _hasExited = false;
  Future<void>? _closing;
  Future<void> closeOwner() => _closing ??= _closeOwner();
  Future<void> _closeOwner() async {
    try {
      await _stopBroker();
    } finally {
      if (!_hasExited) _process.kill();
      // A timeout is a failure, never a false report that a plaintext window
      // disappeared. The manager retains its lifetime record until real exit.
      await exited.timeout(exitTimeout);
    }
  }
}

Future<LiveTerminalWindowHandle> openLiveTerminalWindow({
  required MirroredTerminal terminal,
  required String title,
  VoidCallback? onReady,
  ValueChanged<LiveTerminalWindowCloseReason>? onClosed,
  VoidCallback? onOpenFiles,
  Duration readyTimeout = const Duration(seconds: 30),
}) async {
  if (!supportsLiveTerminalWindows) {
    throw UnsupportedError('Live terminal windows require a desktop.');
  }
  final broker = await LiveTerminalBroker.bind(
    terminal: terminal,
    title: title,
    onReady: onReady,
    onOpenFiles: onOpenFiles,
    readyTimeout: readyTimeout,
  );
  Process? process;
  try {
    final executable = File(Platform.resolvedExecutable);
    process = await Process.start(
      executable.path,
      [
        '--terminal-window-port=${broker.port}',
        '--terminal-window-session=${broker.sessionId}',
      ],
      workingDirectory: executable.parent.path,
      environment: windowLaunchEnvironment(Platform.environment,capability:{_capabilityEnv: broker.launch.capability}),
      includeParentEnvironment: false,
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final owned = OwnedLiveTerminalChild(
      process: process,
      stopBroker: broker.close,
      onProcessExit: () =>
          broker.close(reason: LiveTerminalWindowCloseReason.transportLost),
    );
    final outcome = broker.outcome.then((reason) async {
      if (reason == LiveTerminalWindowCloseReason.parentClosed ||
          reason == LiveTerminalWindowCloseReason.startupFailed) {
        try {
          await owned.closeOwner();
        } catch (_) {}
        // Do not notify the manager that an owner-revoked window is gone until
        // its OS process actually exited. closeOwner itself remains bounded.
        await owned.exited;
      }
      try {
        onClosed?.call(reason);
      } catch (_) {}
      return reason;
    });
    unawaited(
      broker.ready.then((ready) async {
        if (!ready) {
          try {
            await owned.closeOwner();
          } catch (_) {}
        }
      }),
    );
    return LiveTerminalWindowHandle(
      capturePlacement: broker.capturePlacement,
      applyPlacement: broker.applyPlacement,
      ready: broker.ready,
      closed: outcome.then<void>((_) {}),
      outcome: outcome,
      processExited: owned.exited,
      close: owned.closeOwner,
      port: broker.port,
      sessionId: broker.sessionId,
    );
  } catch (_) {
    process?.kill();
    await broker.close();
    rethrow;
  }
}

class _LiveTerminalClient extends LiveTerminalWindowClient {
  _LiveTerminalClient(this._socket) {
    terminal.onOutput = (input) {
      if (_connected &&
          _confirmed &&
          (!_remoteWrite ||
              (_ownsReplies && _parsingSequence > _ownershipAfterSequence))) {
        _socket.add(jsonEncode({'type': 'input', 'data': input}));
      }
    };
    terminal.onResize = (columns, rows, width, height) {
      if (_remoteWrite || !_connected) return;
      _resizeTimer?.cancel();
      _resizeTimer = Timer(const Duration(milliseconds: 40), () {
        if (_connected) {
          _socket.add(
            jsonEncode({
              'type': 'resize',
              'columns': columns.clamp(2, 500),
              'rows': rows.clamp(1, 300),
              'pixel_width': width.clamp(0, 16384),
              'pixel_height': height.clamp(0, 16384),
            }),
          );
        }
      });
    };
    _subscription = _socket.listen(
      _message,
      onDone: _disconnected,
      onError: (_) => _disconnected(),
      cancelOnError: true,
    );
  }
  final WebSocket _socket;
  @override
  final Terminal terminal = Terminal(maxLines: 10000);
  final _initialized = Completer<void>();
  final _closeAcknowledged = Completer<void>();
  late final StreamSubscription<dynamic> _subscription;
  bool _connected = true,
      _remoteWrite = false,
      _confirmed = false,
      _disposed = false;
  bool _truncated = false;
  bool _ownsReplies = false;
  int _ownershipAfterSequence = 0, _parsingSequence = 0;
  bool _notifierDisposed = false;
  String _title = 'SSH terminal';
  int _sequence = 0;
  Timer? _resizeTimer;
  @override
  bool get connected => _connected;
  @override
  String get title => _title;
  @override
  bool get historyTruncated => _truncated;
  void _message(dynamic message) {
    if (message is! String || utf8.encode(message).length > _maxFrameBytes) {
      unawaited(close());
      return;
    }
    try {
      final data = jsonDecode(message);
      if (data is! Map<String, dynamic>) throw const FormatException();
      if (data['type'] == 'init' && !_initialized.isCompleted) {
        final history = data['history'],
            columns = data['columns'],
            rows = data['rows'],
            sequence = data['sequence'];
        if (history is! List ||
            history.any((chunk) => chunk is! String) ||
            columns is! int ||
            rows is! int ||
            columns < 1 ||
            columns > 500 ||
            rows < 1 ||
            rows > 300 ||
            sequence is! int ||
            sequence < 0 ||
            data['title'] is! String) {
          throw const FormatException();
        }
        _title = data['title'] as String;
        _truncated = data['truncated'] == true;
        _sequence = sequence;
        _remoteWrite = true;
        try {
          terminal.resize(columns, rows);
          if (_truncated) terminal.write('\x1bc');
          for (final chunk in history.cast<String>()) {
            terminal.write(chunk);
          }
        } finally {
          _remoteWrite = false;
        }
        _initialized.complete();
        notifyListeners();
      } else if (data['type'] == 'window_geometry_request' && _confirmed) {
        unawaited(handleWindowGeometryRequest(data).then((reply) {
          if (_connected) _socket.add(jsonEncode(reply));
        }).catchError((Object _) { unawaited(close()); }));
      } else if (data['type'] == 'owner' && _confirmed) {
        final cutoff = data['after_sequence'];
        if (cutoff is! int || cutoff < _sequence) throw const FormatException();
        _ownershipAfterSequence = cutoff;
        _ownsReplies = true;
      } else if (data['type'] == 'close_ack' && _confirmed) {
        if (!_closeAcknowledged.isCompleted) _closeAcknowledged.complete();
      } else if (data['type'] == 'output' && _initialized.isCompleted) {
        final sequence = data['sequence'], output = data['data'];
        if (sequence is! int ||
            sequence != _sequence + 1 ||
            output is! String) {
          throw const FormatException();
        }
        _remoteWrite = true;
        _parsingSequence = sequence;
        try {
          terminal.write(output);
        } finally {
          _remoteWrite = false;
        }
        _sequence = sequence;
        _socket.add(jsonEncode({'type': 'ack', 'sequence': sequence}));
      } else {
        throw const FormatException();
      }
    } catch (_) {
      unawaited(close());
    }
  }

  @override
  void openFiles() {
    if (_connected && _confirmed) {
      _socket.add(jsonEncode({'type': 'open_files'}));
    }
  }

  @override
  void confirmReady() {
    if (_confirmed || !_connected || !_initialized.isCompleted) return;
    _confirmed = true;
    _socket.add(jsonEncode({'type': 'ready', 'sequence': _sequence}));
  }

  void _disconnected() {
    if (!_connected) return;
    _connected = false;
    _resizeTimer?.cancel();
    if (!_initialized.isCompleted) {
      _initialized.completeError(
        const SocketException('Terminal window unavailable.'),
      );
    }
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> requestUserClose() async {
    if (_disposed) return;
    if (_connected && _confirmed) {
      _socket.add(jsonEncode({'type': 'close'}));
      try {
        await _closeAcknowledged.future.timeout(
          const Duration(milliseconds: 700),
        );
      } catch (_) {}
    }
    await close();
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_activeClient, this)) _activeClient = null;
    _resizeTimer?.cancel();
    await _socket.close().timeout(const Duration(seconds: 1), onTimeout: () {});
    await _subscription.cancel();
    _disconnected();
    if (!_notifierDisposed) dispose();
  }

  @override
  void dispose() {
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    unawaited(close());
  }
}

Future<LiveTerminalWindowClient> connectLiveTerminalWindow(
  LiveTerminalWindowLaunch launch,
) async {
  if (!_validId(launch.sessionId) ||
      !_validCapability(launch.capability) ||
      launch.port < 1 ||
      launch.port > 65535) {
    throw const FormatException('Invalid terminal window launch.');
  }
  // Environment proxy settings must never route this local capability or
  // terminal content off-device. The upgraded socket owns its transport.
  final direct = HttpClient()..findProxy = (_) => 'DIRECT';
  late final WebSocket socket;
  var upgraded = false;
  try {
    socket = await WebSocket.connect(
      'ws://127.0.0.1:${launch.port}/live/${launch.sessionId}',
      protocols: [_protocol],
      headers: {
        'Origin': _origin,
        'Authorization': 'Bearer ${launch.capability}',
      },
      compression: CompressionOptions.compressionOff,
      customClient: direct,
      maxPayloadLength: _maxFrameBytes,
    ).timeout(const Duration(seconds: 10));
    upgraded = true;
  } finally {
    direct.close(force: !upgraded);
  }
  final client = _LiveTerminalClient(socket);
  try {
    await client._initialized.future.timeout(const Duration(seconds: 10));
    _activeClient = client;
    return client;
  } catch (_) {
    await client.close();
    rethrow;
  }
}

_LiveTerminalClient? _activeClient;
Future<void> closeLiveTerminalWindowClient() async {
  final client = _activeClient;
  _activeClient = null;
  try {
    await client?.requestUserClose().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
  } catch (_) {}
}
