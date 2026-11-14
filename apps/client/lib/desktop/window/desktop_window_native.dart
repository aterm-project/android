import '../../platform/window_launch_environment.dart';
import '../../domain/window_placement.dart';
import '../../platform/window_geometry_rpc.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../terminal/live_terminal_window_contract.dart';
import '../../terminal/live_terminal_window_native.dart'
    show OwnedLiveTerminalChild;
import '../desktop_session.dart';
import '../direct/connection.dart';
import 'desktop_window_contract.dart';
import '../../l10n/l10n.dart';

// A detached desktop window is a renderer process. The parent keeps the RDP/VNC
// session, Host record and credentials; the child receives framebuffer updates
// and returns input over a capability-guarded loopback WebSocket, using the
// same rules as live terminal windows.
const _origin = 'atermius://desktop-window';
const _protocol = 'atermius-desktop-v1';
const _capabilityEnv = 'ATERMIUS_DESKTOP_WINDOW_CAPABILITY';
const _maxInputBytes = 70 * 1024;
const _maxOutstandingBytes = 96 * 1024 * 1024;
const _maxOutstandingFrames = 6;
const _frameHeader = 32;
const _maxFrameBytes = 8192 * 4096 * 4 + _frameHeader;
const formatBgra = 0, formatRgba = 1;

bool get supportsDesktopWindows => Platform.isWindows || Platform.isMacOS;

String _nonce(int bytes) => base64UrlEncode(
  List<int>.generate(bytes, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');
bool _validId(String value) => RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value);
bool _validCapability(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
bool _equalCapability(String supplied, String expected) {
  if (supplied.length != expected.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= supplied.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return difference == 0;
}

DesktopWindowLaunch? detectDesktopWindow(List<String> arguments) {
  final ports = arguments.where((a) => a.startsWith('--desktop-window-port='));
  final sessions = arguments.where(
    (a) => a.startsWith('--desktop-window-session='),
  );
  if (ports.isEmpty && sessions.isEmpty) return null;
  if (ports.length != 1 || sessions.length != 1) {
    throw const FormatException('Invalid desktop window launch.');
  }
  final port = int.tryParse(ports.single.split('=').last);
  final sessionId = sessions.single.split('=').last;
  final capability = Platform.environment[_capabilityEnv] ?? '';
  if (port == null ||
      port < 1 ||
      port > 65535 ||
      !_validId(sessionId) ||
      !_validCapability(capability)) {
    throw const FormatException('Invalid desktop window launch.');
  }
  return DesktopWindowLaunch(
    port: port,
    sessionId: sessionId,
    capability: capability,
  );
}

Map<String, Object?>? _rectJson(ui.Rect? r) => r == null
    ? null
    : {
        'x': r.left.round(),
        'y': r.top.round(),
        'width': r.width.round(),
        'height': r.height.round(),
      };

ui.Rect? _rectFrom(Object? v) {
  if (v == null) return null;
  if (v is! Map) throw const FormatException();
  final x = v['x'], y = v['y'], w = v['width'], h = v['height'];
  if (x is! int || y is! int || w is! int || h is! int) {
    throw const FormatException();
  }
  if (w < 1 || h < 1 || w > 32766 || h > 32766 || x.abs() > 32766 || y.abs() > 32766) {
    throw const FormatException();
  }
  return ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
}

Uint8List encodeDesktopFrame({
  required int sequence,
  required int width,
  required int height,
  required int x,
  required int y,
  required int regionWidth,
  required int regionHeight,
  required int format,
  required Uint8List pixels,
}) {
  final out = Uint8List(_frameHeader + pixels.length);
  ByteData.sublistView(out)
    ..setUint32(0, sequence, Endian.little)
    ..setUint32(4, width, Endian.little)
    ..setUint32(8, height, Endian.little)
    ..setUint32(12, x, Endian.little)
    ..setUint32(16, y, Endian.little)
    ..setUint32(20, regionWidth, Endian.little)
    ..setUint32(24, regionHeight, Endian.little)
    ..setUint32(28, format, Endian.little);
  out.setRange(_frameHeader, out.length, pixels);
  return out;
}

/// Parent-side endpoint. It never owns, reconnects, or closes the session.
class DesktopWindowBroker {
  DesktopWindowBroker._(
    this._server,
    this.session,
    this.spec,
    this.sessionId,
    this._capability,
    this._onReady,
  );
  final HttpServer _server;
  final DesktopSession session;
  final DesktopWindowSpec spec;
  final String sessionId, _capability;
  final VoidCallback? _onReady;
  final _geometry = WindowGeometryRpcOwner();
  final _ready = Completer<bool>();
  final _outcome = Completer<LiveTerminalWindowCloseReason>();
  WebSocket? _socket;
  StreamSubscription<DesktopFrame>? _frames;
  bool _claimed = false, _disposed = false, _clientReady = false;
  bool _needFull = false, _snapshotting = false;
  int _sequence = 0, _acknowledged = 0, _outstandingBytes = 0;
  final Map<int, int> _sizes = {};
  int _messages = 0;
  DateTime _window = DateTime.now();
  String _lastClipboard = '';
  Timer? _timer;

  // Input this window has pressed on the shared session. Released on every
  // teardown (user close, crash, transport loss, revocation) so a dying
  // child can never leave Ctrl or a mouse button held for the other views.
  final Set<int> _keysDown = {};
  int _buttons = 0, _pointerX = 0, _pointerY = 0;

  void _releaseInput() {
    for (final sym in _keysDown) {
      session.send(['key', sym, 0]);
    }
    _keysDown.clear();
    if (_buttons != 0) {
      session.send(['mouse', _pointerX, _pointerY, 0]);
      _buttons = 0;
    }
  }
  int get port => _server.port;
  Future<bool> get ready => _ready.future;
  Future<LiveTerminalWindowCloseReason> get outcome => _outcome.future;
  DesktopWindowLaunch get launch => DesktopWindowLaunch(
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

  static Future<DesktopWindowBroker> bind({
    required DesktopSession session,
    required DesktopWindowSpec spec,
    VoidCallback? onReady,
    Duration readyTimeout = const Duration(seconds: 30),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final broker = DesktopWindowBroker._(
      server,
      session,
      spec,
      _nonce(16),
      _nonce(32),
      onReady,
    );
    server.listen(
      (request) => unawaited(
        broker._request(request).catchError((Object _) async {
          try {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
          } catch (_) {}
        }),
      ),
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
    session.addListener(broker._sessionChanged);
    return broker;
  }

  Future<void> _request(HttpRequest request) async {
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
        request.uri.path == '/desktop/$sessionId' &&
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
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (_) => _protocol,
      compression: CompressionOptions.compressionOff,
      maxPayloadLength: _maxInputBytes,
    );
    if (_disposed) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 10);
    socket.add(
      jsonEncode({
        'type': 'init',
        'title': spec.title.substring(0, spec.title.length.clamp(0, 256)),
        'viewport': _rectJson(spec.viewport),
        'cover': _rectJson(spec.coverMonitor),
        'follow': spec.viewport == null && session.followsWindowSize,
      }),
    );
    socket.listen(
      _message,
      onDone: () =>
          unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost)),
      onError: (_) =>
          unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost)),
      cancelOnError: true,
    );
  }

  void _sessionChanged() {
    if (_disposed || !_clientReady) return;
    final clipboard = session.display.clipboard;
    if (clipboard != _lastClipboard && clipboard.length <= 65536) {
      _lastClipboard = clipboard;
      _socket?.add(jsonEncode({'type': 'clipboard', 'text': clipboard}));
    }
    _socket?.add(
      jsonEncode({
        'type': 'state',
        'state': session.state,
        'error': session.error,
        'follow': spec.viewport == null && session.followsWindowSize,
      }),
    );
    if (session.state == 'disconnected') {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
    }
  }

  final List<DesktopFrame> _afterSnapshot = [];

  void _send(DesktopFrame frame) {
    if (_disposed || !_clientReady) return;
    if (_snapshotting) {
      // Updates painted after the snapshot was taken follow it, in order.
      if (_afterSnapshot.length < 64) {
        _afterSnapshot.add(frame);
      } else {
        _afterSnapshot.clear();
        _needFull = true;
      }
      return;
    }
    if (_needFull) return; // a full snapshot replaces everything pending
    if (_outstandingBytes + frame.bgra.length > _maxOutstandingBytes ||
        _sizes.length >= _maxOutstandingFrames) {
      // Never block the session for a slow window: skip and resynchronize
      // with one full snapshot once the child catches up.
      _needFull = true;
      return;
    }
    _emit(
      frame.width,
      frame.height,
      frame.x,
      frame.y,
      frame.regionWidth,
      frame.regionHeight,
      formatBgra,
      frame.bgra,
    );
  }

  void _emit(int w, int h, int x, int y, int rw, int rh, int format, Uint8List pixels) {
    final sequence = ++_sequence;
    final data = encodeDesktopFrame(
      sequence: sequence,
      width: w,
      height: h,
      x: x,
      y: y,
      regionWidth: rw,
      regionHeight: rh,
      format: format,
      pixels: pixels,
    );
    _sizes[sequence] = data.length;
    _outstandingBytes += data.length;
    _socket?.add(data);
  }

  Future<void> _sendSnapshot() async {
    if (_snapshotting || _disposed) return;
    final current = session.display.layer(0).snapshot();
    if (current == null || current.width < 2 || current.height < 2) {
      _needFull = false;
      return;
    }
    // The layer replaces (and disposes) its image on the next update.
    final image = current.clone();
    _snapshotting = true;
    _needFull = false;
    _afterSnapshot.clear();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null || _disposed) return;
      _emit(
        image.width,
        image.height,
        0,
        0,
        image.width,
        image.height,
        formatRgba,
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
      _snapshotting = false;
      final queued = List.of(_afterSnapshot);
      _afterSnapshot.clear();
      for (final frame in queued) {
        _send(frame);
      }
      if (_needFull && _sizes.isEmpty && !_disposed) unawaited(_sendSnapshot());
    }
  }

  void _message(dynamic message) {
    if (_disposed || message is! String || message.length > _maxInputBytes) {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
      return;
    }
    final now = DateTime.now();
    if (now.difference(_window) >= const Duration(seconds: 1)) {
      _window = now;
      _messages = 0;
    }
    if (++_messages > 4000) {
      unawaited(close(reason: LiveTerminalWindowCloseReason.transportLost));
      return;
    }
    try {
      final data = jsonDecode(message);
      if (data is! Map<String, dynamic>) throw const FormatException();
      final size = session.display.size;
      switch (data['type']) {
        case 'window_geometry_reply':
          if (!_clientReady || !_geometry.receive(data)) throw const FormatException();
        case 'ready':
          if (_clientReady) throw const FormatException();
          _clientReady = true;
          _timer?.cancel();
          _frames = session.frameUpdates.listen(_send);
          _needFull = true;
          unawaited(_sendSnapshot());
          _sessionChanged();
          if (!_ready.isCompleted) _ready.complete(true);
          _onReady?.call();
        case 'ack':
          final sequence = data['sequence'];
          if (sequence is! int || sequence <= _acknowledged || sequence > _sequence) {
            throw const FormatException();
          }
          for (var s = _acknowledged + 1; s <= sequence; s++) {
            _outstandingBytes -= _sizes.remove(s) ?? 0;
          }
          _acknowledged = sequence;
          if (_needFull && _sizes.isEmpty) unawaited(_sendSnapshot());
        case 'key':
          final sym = data['sym'], down = data['down'];
          if (!_clientReady ||
              sym is! int ||
              sym < 0 ||
              // X11 keysyms are 29-bit; XF86 media keys are 0x1008ffxx.
              sym > 0x1fffffff ||
              (down != 0 && down != 1)) {
            throw const FormatException();
          }
          if (down == 1) {
            if (_keysDown.length >= 64 && !_keysDown.contains(sym)) {
              throw const FormatException(); // no real keyboard holds 64 keys
            }
            _keysDown.add(sym);
          } else {
            _keysDown.remove(sym);
          }
          session.send(['key', sym, down as int]);
        case 'mouse':
          final x = data['x'], y = data['y'], buttons = data['buttons'];
          if (!_clientReady ||
              x is! int ||
              y is! int ||
              buttons is! int ||
              x < 0 ||
              y < 0 ||
              x > size.width ||
              y > size.height ||
              buttons < 0 ||
              buttons > 31) {
            throw const FormatException();
          }
          _pointerX = x;
          _pointerY = y;
          _buttons = buttons & 7; // wheel bits are momentary
          session.send(['mouse', x, y, buttons]);
        case 'paste':
          final text = data['text'];
          if (!_clientReady || text is! String) throw const FormatException();
          try {
            session.paste(text);
          } on FormatException catch (e) {
            _socket?.add(jsonEncode({'type': 'notice', 'text': e.message}));
          }
        case 'size':
          final w = data['width'], h = data['height'];
          if (!_clientReady || w is! int || h is! int) {
            throw const FormatException();
          }
          // Only the whole-desktop window may drive automatic resizing, and
          // only when the Host is in automatic mode.
          if (spec.viewport == null && session.followsWindowSize) {
            session.send(['size', w.clamp(200, 8192), h.clamp(200, 8192)]);
          }
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
    if (_disposed) return;
    _geometry.close();
    _disposed = true;
    _timer?.cancel();
    _releaseInput();
    session.removeListener(_sessionChanged);
    if (!_ready.isCompleted) _ready.complete(false);
    try {
      await _frames?.cancel();
    } catch (_) {}
    try {
      await _socket
          ?.close(WebSocketStatus.normalClosure, 'Desktop window closed.')
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    try {
      await _server.close(force: true);
    } catch (_) {}
    _sizes.clear();
    if (!_outcome.isCompleted) _outcome.complete(reason);
  }
}

typedef DesktopWindowProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments,
      Map<String, String> environment,
    );

Future<Process> _startProcess(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) => Process.start(
  executable,
  arguments,
  workingDirectory: File(executable).parent.path,
  environment: windowLaunchEnvironment(Platform.environment,capability:environment),
  includeParentEnvironment: false,
);

Future<LiveTerminalWindowHandle> openDesktopWindow({
  required DesktopSession session,
  required DesktopWindowSpec spec,
  VoidCallback? onReady,
  Duration readyTimeout = const Duration(seconds: 30),
  @visibleForTesting DesktopWindowProcessStarter? startProcess,
}) async {
  if (!supportsDesktopWindows && startProcess == null) {
    throw UnsupportedError('Desktop windows require the Windows client.');
  }
  final broker = await DesktopWindowBroker.bind(
    session: session,
    spec: spec,
    onReady: onReady,
    readyTimeout: readyTimeout,
  );
  Process? process;
  try {
    process = await (startProcess ?? _startProcess)(
      Platform.resolvedExecutable,
      [
        '--desktop-window-port=${broker.port}',
        '--desktop-window-session=${broker.sessionId}',
      ],
      {_capabilityEnv: broker.launch.capability},
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
      // A desktop renderer cannot outlive its mirror: on every outcome
      // (including the user's own close and transport loss) make sure the
      // process and its possibly borderless monitor window are gone. The
      // parent session is untouched; only the renderer ends.
      try {
        await owned.closeOwner();
      } catch (_) {}
      await owned.exited;
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

/// Child-side session: renders mirrored frames and forwards input. It has no
/// Host, credentials, certificate state or network connection of its own.
class MirroredDesktopSession extends DesktopSession {
  MirroredDesktopSession._(this._socket);
  final WebSocket _socket;
  final _initialized = Completer<void>();
  final _closeAck = Completer<void>();
  late final StreamSubscription<dynamic> _subscription;
  String title = 'Remote desktop';
  ui.Rect? viewport, coverMonitor;
  bool _follow = false, _confirmed = false, _disposedSocket = false;
  bool _painting = false;
  final List<Uint8List> _queue = [];

  @override
  bool get followsWindowSize => _follow && viewport == null;

  void confirmReady() {
    if (_confirmed || _disposedSocket) return;
    _confirmed = true;
    _socket.add(jsonEncode({'type': 'ready'}));
  }

  void _message(dynamic message) {
    try {
      if (message is List<int>) {
        if (!_confirmed || message.length < _frameHeader || message.length > _maxFrameBytes) {
          throw const FormatException();
        }
        _queue.add(message is Uint8List ? message : Uint8List.fromList(message));
        unawaited(_drain());
        return;
      }
      if (message is! String) throw const FormatException();
      final data = jsonDecode(message);
      if (data is! Map<String, dynamic>) throw const FormatException();
      switch (data['type']) {
        case 'window_geometry_request':
          if (!_confirmed || _disposedSocket) throw const FormatException();
          unawaited(handleWindowGeometryRequest(data).then((reply) {
            if (!_disposedSocket) _socket.add(jsonEncode(reply));
          }).catchError((Object _) { unawaited(close()); }));
        case 'init':
          if (_initialized.isCompleted || data['title'] is! String) {
            throw const FormatException();
          }
          title = data['title'] as String;
          viewport = _rectFrom(data['viewport']);
          coverMonitor = _rectFrom(data['cover']);
          _follow = data['follow'] == true;
          _initialized.complete();
        case 'state':
          final s = data['state'];
          if (s is! String) throw const FormatException();
          _follow = data['follow'] == true;
          error = data['error'] as String?;
          if (s == 'disconnected') state = 'disconnected';
          notifyListeners();
        case 'clipboard':
          final text = data['text'];
          if (text is! String) throw const FormatException();
          display.clipboard = text;
        case 'notice':
          final text = data['text'];
          if (text is String) onNotice?.call(text);
        case 'close_ack':
          if (!_closeAck.isCompleted) _closeAck.complete();
        default:
          throw const FormatException();
      }
    } catch (_) {
      unawaited(close());
    }
  }

  Future<void> _drain() async {
    if (_painting) return;
    _painting = true;
    try {
      while (_queue.isNotEmpty && !_disposedSocket) {
        final bytes = _queue.removeAt(0);
        final h = ByteData.sublistView(bytes, 0, _frameHeader);
        final sequence = h.getUint32(0, Endian.little);
        final w = h.getUint32(4, Endian.little), height = h.getUint32(8, Endian.little);
        final x = h.getUint32(12, Endian.little), y = h.getUint32(16, Endian.little);
        final rw = h.getUint32(20, Endian.little), rh = h.getUint32(24, Endian.little);
        final format = h.getUint32(28, Endian.little);
        if ((format != formatBgra && format != formatRgba) ||
            rw * rh * 4 != bytes.length - _frameHeader) {
          throw const FormatException();
        }
        final pixels = Uint8List.sublistView(bytes, _frameHeader);
        if (format == formatRgba) {
          // display.frame expects BGRA; swap R and B in place.
          for (var i = 0; i < pixels.length; i += 4) {
            final r = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = r;
          }
        }
        await display.frame(
          w,
          height,
          pixels,
          x: x,
          y: y,
          regionWidth: rw,
          regionHeight: rh,
        );
        if (state != 'connected') {
          state = 'connected';
          notifyListeners();
        }
        if (!_disposedSocket) {
          _socket.add(jsonEncode({'type': 'ack', 'sequence': sequence}));
        }
      }
    } catch (_) {
      unawaited(close());
    } finally {
      _painting = false;
    }
  }

  @override
  void send(List<Object> values) {
    if (_disposedSocket || !_confirmed) return;
    switch (values[0]) {
      case 'key':
        _socket.add(jsonEncode({'type': 'key', 'sym': values[1], 'down': values[2]}));
      case 'mouse':
        _socket.add(
          jsonEncode({
            'type': 'mouse',
            'x': values[1],
            'y': values[2],
            'buttons': values[3],
          }),
        );
      case 'size':
        _socket.add(jsonEncode({'type': 'size', 'width': values[1], 'height': values[2]}));
    }
  }

  @override
  void paste(String text) {
    if (utf8.encode(text).length > 65536) {
      throw const FormatException('Clipboard is limited to 64 KiB');
    }
    if (!_disposedSocket && _confirmed) {
      _socket.add(jsonEncode({'type': 'paste', 'text': text}));
    }
  }

  Future<void> requestUserClose() async {
    if (_disposedSocket) return;
    if (_confirmed) {
      _socket.add(jsonEncode({'type': 'close'}));
      try {
        await _closeAck.future.timeout(const Duration(milliseconds: 700));
      } catch (_) {}
    }
    await close();
  }

  @override
  Future<void> close() async {
    if (_disposedSocket) return;
    _disposedSocket = true;
    if (identical(_activeDesktopClient, this)) _activeDesktopClient = null;
    _queue.clear();
    try {
      await _socket.close().timeout(const Duration(seconds: 1), onTimeout: () {});
    } catch (_) {}
    await _subscription.cancel();
    if (!_initialized.isCompleted) {
      _initialized.completeError(const SocketException('Desktop window unavailable.'));
    }
    if (state != 'disconnected') {
      state = 'disconnected';
      error ??= currentL10n.theRemoteDesktopInTheMain;
      notifyListeners();
    }
  }
}

MirroredDesktopSession? _activeDesktopClient;

/// Close-guard hook for the child process (mirrors terminal windows).
Future<void> closeDesktopWindowClient() async {
  final client = _activeDesktopClient;
  _activeDesktopClient = null;
  try {
    await client?.requestUserClose().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
  } catch (_) {}
}

Future<MirroredDesktopSession> connectDesktopWindow(
  DesktopWindowLaunch launch,
) async {
  if (!_validId(launch.sessionId) ||
      !_validCapability(launch.capability) ||
      launch.port < 1 ||
      launch.port > 65535) {
    throw const FormatException('Invalid desktop window launch.');
  }
  final direct = HttpClient()..findProxy = (_) => 'DIRECT';
  late final WebSocket socket;
  var upgraded = false;
  try {
    socket = await WebSocket.connect(
      'ws://127.0.0.1:${launch.port}/desktop/${launch.sessionId}',
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
  final client = MirroredDesktopSession._(socket);
  client._subscription = socket.listen(
    client._message,
    onDone: () => unawaited(client.close()),
    onError: (_) => unawaited(client.close()),
    cancelOnError: true,
  );
  try {
    await client._initialized.future.timeout(const Duration(seconds: 10));
    _activeDesktopClient = client;
    return client;
  } catch (_) {
    await client.close();
    rethrow;
  }
}
