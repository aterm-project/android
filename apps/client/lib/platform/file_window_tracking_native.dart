import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/window_placement.dart';
import 'files_window_launch.dart';
import 'file_window_tracking_contract.dart';
import 'window_geometry.dart';
import 'window_launch_environment.dart';
import '../l10n/l10n.dart';

const _origin = 'atermius://file-window-geometry',
    _protocol = 'atermius-file-geometry-v1';
const fileWindowCapabilityEnvironment = 'ATERMIUS_FILE_WINDOW_CAPABILITY';
const _maxMessageBytes = 16384;
String _nonce(int length) =>
    base64UrlEncode(List.generate(length, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
bool _sameSecret(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

bool _sameScope(FilesWindowLaunch a, FilesWindowLaunch b) => a.matchesScope(
  b.workspace,
  b.scopeId,
  serverNamespace: b.serverNamespace,
  accountId: b.accountId,
);
FileTrackingLaunch? detectFileTrackingLaunch(
  List<String> arguments, {
  Map<String, String>? environment,
}) {
  final ports = arguments
          .where((a) => a.startsWith('--file-geometry-port='))
          .toList(),
      ids = arguments
          .where((a) => a.startsWith('--file-geometry-id='))
          .toList();
  if (ports.isEmpty && ids.isEmpty) return null;
  if (ports.length != 1 || ids.length != 1)
    throw const FormatException('Invalid file geometry arguments.');
  return FileTrackingLaunch(
    port:
        int.tryParse(ports.single.substring('--file-geometry-port='.length)) ??
        0,
    id: ids.single.substring('--file-geometry-id='.length),
    capability:
        (environment ??
            Platform.environment)[fileWindowCapabilityEnvironment] ??
        '',
  );
}

void validateFileTrackingArguments(
  List<String> arguments,
  FilesWindowLaunch? expected,
) {
  if (detectFileTrackingLaunch(arguments) != null && expected == null)
    throw const FormatException('File geometry requires a scoped file launch.');
}

typedef TrackedFileProcessStarter = Future<void> Function(
  List<String> arguments,
  Map<String, String> environment,
);
Future<void> _startProcess(
  List<String> arguments,
  Map<String, String> environment,
) async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    throw UnsupportedError(currentL10n.fileWindowsRequireADesktop);
  }
  final executable = File(Platform.resolvedExecutable);
  await Process.start(
    executable.path,
    arguments,
    workingDirectory: executable.parent.path,
    mode: ProcessStartMode.detached,
    includeParentEnvironment: false,
    environment: environment,
  );
}

class TrackedFilesWindows extends ChangeNotifier {
  TrackedFilesWindows({TrackedFileProcessStarter? startProcess})
    : _start = startProcess ?? _startProcess;
  static final instance = TrackedFilesWindows();
  final TrackedFileProcessStarter _start;
  final Map<String, ({Object owner, FileGeometryBroker broker})> _entries = {};
  int readyWindowCount(Object owner) => _entries.values
      .where((entry) => identical(entry.owner, owner) && entry.broker.isReady)
      .length;
  int ownedWindowCount(Object owner) =>
      _entries.values.where((entry) => identical(entry.owner, owner)).length;
  bool hasWindows(Object owner) => ownedWindowCount(owner) > 0;
  Future<TrackedFileWindowHandle> open({
    required Object owner,
    required FilesWindowLaunch launch,
    SavedWindowPlacement? placement,
    bool Function()? isCurrent,
  }) async {
    if (_entries.length >= 64 ||
        _entries.values
                .where((entry) => identical(entry.owner, owner))
                .length >=
            32)
      throw StateError('Too many tracked file windows.');
    if (isCurrent?.call() == false) throw StateError('Workspace changed.');
    final broker = await FileGeometryBroker.bind(
      expected: launch,
      initialPlacement: placement,
    );
    final entry = (owner: owner, broker: broker);
    _entries[broker.launch.id] = entry;
    unawaited(
      broker.closed.then((_) {
        if (identical(_entries[broker.launch.id]?.broker, broker)) {
          _entries.remove(broker.launch.id);
          notifyListeners();
        }
      }),
    );
    unawaited(
      broker.ready.then((_) {
        if (_entries[broker.launch.id]?.broker == broker) notifyListeners();
      }),
    );
    try {
      if (isCurrent?.call() == false) throw StateError('Workspace changed.');
      await _start(
        [...launch.toArguments(), ...broker.launch.toArguments()],
        windowLaunchEnvironment(
          Platform.environment,
          capability: {
            fileWindowCapabilityEnvironment: broker.launch.capability,
          },
        ),
      );
      if (isCurrent?.call() == false) await broker.close();
      return broker.handle;
    } catch (_) {
      await broker.close();
      rethrow;
    }
  }

  Future<List<FileWindowSnapshot>> capture(Object owner) async {
    final entries = _entries.values
        .where((entry) => identical(entry.owner, owner) && entry.broker.isReady)
        .toList();
    final values = await Future.wait(
      entries.map((entry) async {
        final snapshot = await entry.broker.snapshot();
        return _entries[entry.broker.launch.id]?.broker == entry.broker &&
                entry.broker.isReady
            ? snapshot
            : null;
      }),
    );
    return List.unmodifiable(values.whereType<FileWindowSnapshot>());
  }

  Future<void> releaseOwner(Object owner) async {
    final entries = _entries.values
        .where((entry) => identical(entry.owner, owner))
        .toList();
    for (final entry in entries) {
      _entries.remove(entry.broker.launch.id);
    }
    if (entries.isNotEmpty) notifyListeners();
    await Future.wait(entries.map((entry) => entry.broker.close()));
  }
}

/// Authenticated geometry/intent metadata only. Closing this broker never sends
/// an application-close command and never owns/kills the child process.
class FileGeometryBroker {
  FileGeometryBroker._(
    this._server,
    this.launch,
    this.expected,
    this.initialPlacement,
  );
  final HttpServer _server;
  final FileTrackingLaunch launch;
  final FilesWindowLaunch expected;
  final SavedWindowPlacement? initialPlacement;
  final _ready = Completer<bool>(),
      _placed = Completer<bool>(),
      _closed = Completer<void>();
  WebSocket? _socket;
  Timer? _startup;
  bool _claimed = false, _disposed = false, _clientReady = false;
  Completer<FileWindowSnapshot?>? _pending;
  int _serial = 0, _messages = 0;
  DateTime _rateWindow = DateTime.now();
  bool get isReady => _clientReady && !_disposed;
  Future<bool> get ready => _ready.future;
  Future<void> get closed => _closed.future;
  TrackedFileWindowHandle get handle => TrackedFileWindowHandle(
    id: launch.id,
    ready: ready,
    initialPlacementApplied: _placed.future,
    closed: closed,
    stopTracking: close,
  );
  static Future<FileGeometryBroker> bind({
    required FilesWindowLaunch expected,
    SavedWindowPlacement? initialPlacement,
    Duration readyTimeout = const Duration(seconds: 30),
  }) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final broker = FileGeometryBroker._(
      server,
      FileTrackingLaunch(
        port: server.port,
        id: _nonce(16),
        capability: _nonce(32),
      ),
      expected,
      initialPlacement,
    );
    server.listen(
      (request) => unawaited(
        broker._request(request).catchError((Object _) async {
          try {
            request.response.statusCode = 403;
            await request.response.close();
          } catch (_) {}
        }),
      ),
    );
    broker._startup = Timer(readyTimeout, () => unawaited(broker.close()));
    return broker;
  }

  Future<void> _request(HttpRequest request) async {
    final supplied =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final valid =
        !_disposed &&
        !_claimed &&
        request.method == 'GET' &&
        request.connectionInfo?.remoteAddress.isLoopback == true &&
        request.headers.value(HttpHeaders.hostHeader) ==
            '127.0.0.1:${launch.port}' &&
        request.headers.value('origin') == _origin &&
        request.uri.path == '/file-geometry/${launch.id}' &&
        !request.uri.hasQuery &&
        (request.headers.value('sec-websocket-protocol') ?? '')
            .split(',')
            .map((v) => v.trim())
            .contains(_protocol) &&
        _sameSecret(supplied, 'Bearer ${launch.capability}') &&
        WebSocketTransformer.isUpgradeRequest(request);
    if (!valid) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    _claimed = true;
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) =>
          protocols.contains(_protocol) ? _protocol : null,
      compression: CompressionOptions.compressionOff,
      maxPayloadLength: _maxMessageBytes,
    );
    if (_disposed) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 10);
    socket.listen(
      _message,
      onDone: () => unawaited(close()),
      onError: (_) => unawaited(close()),
      cancelOnError: true,
    );
    socket.add(
      jsonEncode({
        'type': 'init',
        'version': 1,
        'placement': initialPlacement?.toJson(),
      }),
    );
  }

  void _message(dynamic message) {
    try {
      if (_disposed ||
          message is! String ||
          utf8.encode(message).length > _maxMessageBytes)
        throw const FormatException();
      final now = DateTime.now();
      if (now.difference(_rateWindow) >= const Duration(seconds: 1)) {
        _rateWindow = now;
        _messages = 0;
      }
      if (++_messages > 64) throw const FormatException();
      final data = jsonDecode(message);
      if (data is! Map<String, dynamic>) throw const FormatException();
      if (data['type'] == 'ready') {
        if (_clientReady || data.length != 2 || data['applied'] is! bool)
          throw const FormatException();
        _clientReady = true;
        _startup?.cancel();
        _ready.complete(true);
        _placed.complete(data['applied'] as bool);
        return;
      }
      if (!_clientReady ||
          data['type'] != 'snapshot' ||
          data.length != 4 ||
          !data.keys.toSet().containsAll({
            'type',
            'request',
            'launch',
            'placement',
          }) ||
          data['request'] is! int ||
          data['request'] < 1 ||
          data['request'] > 0x7fffffff)
        throw const FormatException();
      FileWindowSnapshot? snapshot;
      if (data['launch'] != null) {
        if (data['launch'] is! Map ||
            (data['placement'] != null && data['placement'] is! Map))
          throw const FormatException();
        final current = FilesWindowLaunch.fromJson(
          Map<String, Object?>.from(data['launch'] as Map),
        );
        if (!_sameScope(current, expected)) throw const FormatException();
        snapshot = FileWindowSnapshot(
          windowId: launch.id,
          launch: current,
          placement: data['placement'] == null
              ? null
              : SavedWindowPlacement.fromJson(
                  Map<String, Object?>.from(data['placement'] as Map),
                ),
        );
      } else if (data['placement'] != null)
        throw const FormatException();
      if (data['request'] == _serial && _pending?.isCompleted == false)
        _pending!.complete(snapshot);
    } catch (_) {
      unawaited(close());
    }
  }

  Future<FileWindowSnapshot?> snapshot({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!isReady || _pending != null) return null;
    final pending = Completer<FileWindowSnapshot?>();
    _pending = pending;
    try {
      _socket?.add(jsonEncode({'type': 'snapshot', 'request': ++_serial}));
      return await pending.future.timeout(timeout, onTimeout: () => null);
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<void> close() async {
    if (_disposed) return closed;
    _disposed = true;
    _clientReady = false;
    _startup?.cancel();
    if (!_ready.isCompleted) _ready.complete(false);
    if (!_placed.isCompleted) _placed.complete(false);
    if (_pending?.isCompleted == false) _pending!.complete(null);
    _pending = null;
    try {
      await _socket?.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await _server.close(force: true);
    if (!_closed.isCompleted) _closed.complete();
  }
}

class FileWindowTrackingClient {
  FileWindowTrackingClient._(this._socket, this.expected, this.geometry) {
    _socket.listen(
      _message,
      onDone: _lost,
      onError: (_) => _lost(),
      cancelOnError: true,
    );
  }
  final WebSocket _socket;
  final FilesWindowLaunch expected;
  final WindowGeometry geometry;
  final _initialized = Completer<void>();
  FilesWindowLaunch? Function()? _provider;
  Object? Function()? _scopeEpoch;
  int _generation = 0;
  bool _connected = true,
      _initializing = false,
      _ready = false,
      _snapshotBusy = false;
  int _received = 0;
  DateTime _receiveWindow = DateTime.now();
  bool get connected => _connected;
  VoidCallback provide(
    FilesWindowLaunch? Function() provider, {
    Object? Function()? scopeEpoch,
  }) {
    _provider = provider;
    _scopeEpoch = scopeEpoch;
    _generation++;
    return () {
      if (identical(_provider, provider)) {
        _provider = null;
        _scopeEpoch = null;
        _generation++;
      }
    };
  }

  static Future<FileWindowTrackingClient> connect(
    FileTrackingLaunch launch, {
    required FilesWindowLaunch expected,
    WindowGeometry? geometry,
  }) async {
    final direct = HttpClient()..findProxy = (_) => 'DIRECT';
    var upgraded = false;
    late WebSocket socket;
    try {
      socket = await WebSocket.connect(
        'ws://127.0.0.1:${launch.port}/file-geometry/${launch.id}',
        headers: {
          'Origin': _origin,
          'Authorization': 'Bearer ${launch.capability}',
        },
        protocols: [_protocol],
        compression: CompressionOptions.compressionOff,
        customClient: direct,
        maxPayloadLength: _maxMessageBytes,
      ).timeout(const Duration(seconds: 5));
      upgraded = true;
    } finally {
      direct.close(force: !upgraded);
    }
    final client = FileWindowTrackingClient._(
      socket,
      expected,
      geometry ?? WindowGeometry.instance,
    );
    try {
      await client._initialized.future.timeout(const Duration(seconds: 5));
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  void _message(dynamic message) {
    unawaited(_handle(message).catchError((Object _) => close()));
  }

  Future<void> _handle(dynamic message) async {
    final now = DateTime.now();
    if (now.difference(_receiveWindow) >= const Duration(seconds: 1)) {
      _received = 0;
      _receiveWindow = now;
    }
    if (++_received > 64) throw const FormatException();
    if (!_connected ||
        message is! String ||
        utf8.encode(message).length > _maxMessageBytes)
      throw const FormatException();
    final data = jsonDecode(message);
    if (data is! Map<String, dynamic>) throw const FormatException();
    if (data['type'] == 'init') {
      if (_initializing ||
          _ready ||
          data.length != 3 ||
          data['version'] is! int ||
          data['version'] != 1 ||
          !data.keys.toSet().containsAll({'type', 'version', 'placement'}) ||
          (data['placement'] != null && data['placement'] is! Map))
        throw const FormatException();
      _initializing = true;
      // main() awaits this handshake before auth/UI initialization. The initial
      // move is geometry only; no Host/path/provider metadata exists yet.
      var applied = true;
      if (data['placement'] != null)
        applied = await geometry.restorePlacement(
          SavedWindowPlacement.fromJson(
            Map<String, Object?>.from(data['placement'] as Map),
          ),
          isCurrent: () => _connected && _provider == null,
        );
      if (!_connected) return;
      _ready = true;
      _socket.add(jsonEncode({'type': 'ready', 'applied': applied}));
      _initialized.complete();
      return;
    }
    if (!_ready ||
        data['type'] != 'snapshot' ||
        data.length != 2 ||
        data['request'] is! int ||
        data['request'] < 1 ||
        data['request'] > 0x7fffffff)
      throw const FormatException();
    final request = data['request'];
    if (_snapshotBusy) {
      _socket.add(
        jsonEncode({
          'type': 'snapshot',
          'request': request,
          'launch': null,
          'placement': null,
        }),
      );
      return;
    }
    _snapshotBusy = true;
    try {
      final generation = _generation,
          epoch = _scopeEpoch?.call(),
          current = _provider?.call();
      FilesWindowLaunch? valid =
          current != null && _sameScope(current, expected) ? current : null;
      SavedWindowPlacement? placement;
      if (valid != null) {
        placement = await geometry.capturePlacement();
        final latest = _provider?.call();
        if (!_connected) return;
        if (generation != _generation ||
            epoch != _scopeEpoch?.call() ||
            latest == null ||
            !_sameScope(latest, expected) ||
            jsonEncode(latest.toJson()) != jsonEncode(valid.toJson())) {
          valid = null;
          placement = null;
        }
      }
      if (_connected)
        _socket.add(
          jsonEncode({
            'type': 'snapshot',
            'request': request,
            'launch': valid?.toJson(),
            'placement': placement?.toJson(),
          }),
        );
    } finally {
      _snapshotBusy = false;
    }
  }

  void _lost() {
    _connected = false;
    _provider = null;
    _scopeEpoch = null;
    _generation++;
    if (!_initialized.isCompleted)
      _initialized.completeError(
        const SocketException('File geometry tracking unavailable.'),
      );
  }

  Future<void> close() async {
    _lost();
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}

FileWindowTrackingClient? _activeTrackingClient;
VoidCallback registerTrackedFileProvider(
  FilesWindowLaunch? Function() provider, {
  Object? Function()? scopeEpoch,
}) => _activeTrackingClient?.connected == true
    ? _activeTrackingClient!.provide(provider, scopeEpoch: scopeEpoch)
    : () {};

Future<void> startFileWindowTracking(
  List<String> arguments,
  FilesWindowLaunch? expected,
) async {
  final launch = detectFileTrackingLaunch(arguments);
  if (launch == null) return;
  if (expected == null)
    throw const FormatException('Missing scoped file request.');
  try {
    _activeTrackingClient = await FileWindowTrackingClient.connect(
      launch,
      expected: expected,
    );
  } catch (_) {
    /* Independent file app continues if the parent is already gone. */
  }
}

void validateTrackedFileScope(
  FilesWindowWorkspace workspace,
  String scopeId, {
  String? serverNamespace,
  String? accountId,
}) {
  final client = _activeTrackingClient;
  if (client?.connected == true &&
      !client!.expected.matchesScope(
        workspace,
        scopeId,
        serverNamespace: serverNamespace,
        accountId: accountId,
      ))
    unawaited(client.close());
}
