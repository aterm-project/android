import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../api/api_client.dart';
import 'sync_hint_socket.dart';
import 'sync_hint_socket_factory.dart';

class SyncHintScope {
  const SyncHintScope({
    required this.serverSpaceId,
    required this.accountId,
    required this.deviceId,
    required this.vaultId,
    required this.websocketUri,
    required this.origin,
  });

  final String serverSpaceId;
  final String accountId;
  final String deviceId;
  final String vaultId;
  final Uri websocketUri;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is SyncHintScope &&
      other.serverSpaceId == serverSpaceId &&
      other.accountId == accountId &&
      other.deviceId == deviceId &&
      other.vaultId == vaultId &&
      other.websocketUri == websocketUri &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(
    serverSpaceId,
    accountId,
    deviceId,
    vaultId,
    websocketUri,
    origin,
  );
}

class SyncHint {
  const SyncHint({required this.vaultId, this.membershipChanged = false});

  /// Null means a membership-set change and requires GET /vaults first.
  final String? vaultId;
  final bool membershipChanged;
}

typedef SyncHintCallback = Future<void> Function(SyncHint hint);
typedef SyncHintTicketProvider = Future<String> Function();
typedef SyncHintSessionRefresh = Future<bool> Function();

/// Long-lived invalidation-hint connection. It never treats a notification as
/// data authority: every accepted hint calls the existing sync coordinator.
class SyncHintClient {
  SyncHintClient({
    required this._fetchTicket,
    required this._onHint,
    required this._refreshSession,
    SyncHintSocketFactory? connect,
    this._retryDelay,
    Random? random,
    this.handshakeTimeout = const Duration(seconds: 10),
  }) : _connect = connect ?? connectSyncHintSocket,
       _random = random ?? Random();

  final SyncHintTicketProvider _fetchTicket;
  final SyncHintCallback _onHint;
  final SyncHintSessionRefresh _refreshSession;
  final SyncHintSocketFactory _connect;
  final Duration Function(int attempt)? _retryDelay;
  final Random _random;
  final Duration handshakeTimeout;

  SyncHintScope? _scope;
  SyncHintSocket? _socket;
  Timer? _retryTimer;
  int _runId = 0;
  bool _active = false;

  bool get isRunning => _active;
  SyncHintScope? get scope => _scope;

  void start(SyncHintScope nextScope) {
    if (_active && _scope == nextScope) return;
    stop();
    _scope = nextScope;
    _active = true;
    final runId = ++_runId;
    unawaited(_connectOnce(runId, 0));
  }

  void stop() {
    ++_runId;
    _active = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _scope = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(_closeQuietly(socket));
  }

  Future<void> _connectOnce(int runId, int attempt) async {
    final scope = _scope;
    if (!_isCurrent(runId) || scope == null) return;
    SyncHintSocket? socket;
    var reconnectImmediately = false;
    try {
      // A ticket is single-use and is deliberately kept only in this stack
      // frame until it is sent as the first JSON message.
      final ticket = await _fetchTicket();
      if (!_isCurrent(runId)) return;
      socket = await _connect(scope.websocketUri, origin: scope.origin);
      if (!_isCurrent(runId)) {
        await _closeQuietly(socket);
        return;
      }
      _socket = socket;
      await socket.ready.timeout(handshakeTimeout);
      if (!_isCurrent(runId)) return;
      socket.sendText(jsonEncode({'type': 'authenticate', 'ticket': ticket}));
      await _listenUntilClosed(socket, scope, runId);
      if (!_isCurrent(runId)) return;
      final closeCode = socket.closeCode;
      if (closeCode == 1000 || closeCode == 1008) {
        _stopForPolicy(runId);
        return;
      }
      if (closeCode == 4001) {
        reconnectImmediately = await _refreshSafely();
        if (!reconnectImmediately) {
          _stopForPolicy(runId);
          return;
        }
      }
      // 4008, 1011, abnormal close (1006), and all other transient closes
      // reconnect with a fresh single-use ticket.
    } on ApiException catch (error) {
      if (!_isCurrent(runId)) return;
      if (_isPermanent(error.statusCode, error.code)) {
        _stopForPolicy(runId);
        return;
      }
      if (error.statusCode == 401) {
        reconnectImmediately = await _refreshSafely();
        if (!reconnectImmediately) {
          _stopForPolicy(runId);
          return;
        }
      }
    } on SyncHintHandshakeException catch (error) {
      if (!_isCurrent(runId)) return;
      if (_isPermanent(error.statusCode, error.code)) {
        _stopForPolicy(runId);
        return;
      }
    } catch (_) {
      if (!_isCurrent(runId)) return;
      // Network/timeout failures are transient. This also covers Web browsers,
      // which hide HTTP status details for failed WebSocket handshakes.
    } finally {
      if (socket != null) {
        if (identical(_socket, socket)) _socket = null;
        await _closeQuietly(socket);
      }
    }
    if (_isCurrent(runId)) {
      _scheduleReconnect(runId, reconnectImmediately ? 0 : attempt + 1);
    }
  }

  Future<void> _listenUntilClosed(
    SyncHintSocket socket,
    SyncHintScope scope,
    int runId,
  ) async {
    final done = Completer<void>();
    final subscription = socket.stream.listen(
      (message) {
        if (!_isCurrent(runId)) return;
        _handleMessage(message, scope, runId);
      },
      onError: (Object _, StackTrace _) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    try {
      await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  void _handleMessage(Object? raw, SyncHintScope scope, int runId) {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['type']) {
      case 'ready':
        if (decoded['server_generation'] is! String ||
            !_uuid.hasMatch(decoded['server_generation'] as String) ||
            decoded['sync_required'] != true ||
            decoded['heartbeat_seconds'] is! int ||
            (decoded['heartbeat_seconds'] as int) < 1 ||
            decoded['poll_interval_seconds'] is! int ||
            (decoded['poll_interval_seconds'] as int) < 1) {
          return;
        }
        _dispatchHint(SyncHint(vaultId: scope.vaultId), runId);
      case 'sync_required':
        final commitShape = _hasExactKeys(decoded, const {
          'type',
          'vault_id',
          'commit_seq',
        });
        final conflictShape = _hasExactKeys(decoded, const {
          'type',
          'vault_id',
          'conflict_seq',
        });
        if (!commitShape && !conflictShape) {
          return;
        }
        final vaultId = decoded['vault_id'];
        final sequence = decoded[commitShape ? 'commit_seq' : 'conflict_seq'];
        if (commitShape && vaultId == null && sequence == null) {
          _dispatchHint(
            const SyncHint(vaultId: null, membershipChanged: true),
            runId,
          );
          return;
        }
        if (vaultId is! String ||
            !_uuid.hasMatch(vaultId) ||
            sequence is! String ||
            !_decimal.hasMatch(sequence)) {
          return;
        }
        // Hints for another active Vault are ignored. After the user changes
        // Vault a fresh scoped connection is opened and ready triggers a pull.
        if (vaultId == scope.vaultId) {
          _dispatchHint(SyncHint(vaultId: vaultId), runId);
        }
      case 'error':
        final code = decoded['code'];
        if (code == 'NOTIFICATIONS_DISABLED' || code == 'ORIGIN_DENIED') {
          _stopForPolicy(runId);
        }
    }
  }

  static bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) =>
      value.length == expected.length &&
      value.keys.toSet().containsAll(expected);

  void _dispatchHint(SyncHint hint, int runId) {
    unawaited(() async {
      if (!_isCurrent(runId)) return;
      try {
        await _onHint(hint);
      } catch (_) {
        // The automatic sync/repository owns visible error state. A failed
        // pull must not tear down the notification transport.
      }
    }());
  }

  void _scheduleReconnect(int runId, int attempt) {
    if (!_isCurrent(runId)) return;
    _retryTimer?.cancel();
    final delay = _retryDelay?.call(attempt) ?? _fullJitter(attempt);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_isCurrent(runId)) unawaited(_connectOnce(runId, attempt));
    });
  }

  Duration _fullJitter(int attempt) {
    final exponent = attempt.clamp(0, 5);
    final ceilingSeconds = min(30, 1 << exponent);
    return Duration(seconds: 1 + _random.nextInt(ceilingSeconds));
  }

  bool _isCurrent(int runId) => _active && runId == _runId;

  void _stopForPolicy(int runId) {
    if (!_isCurrent(runId)) return;
    stop();
  }

  Future<bool> _refreshSafely() async {
    try {
      return await _refreshSession();
    } catch (_) {
      return false;
    }
  }

  bool _isPermanent(int statusCode, String code) =>
      statusCode == 403 ||
      code == 'ORIGIN_DENIED' ||
      code == 'NOTIFICATIONS_DISABLED';

  Future<void> _closeQuietly(SyncHintSocket socket) async {
    try {
      await socket.close();
    } catch (_) {
      // Closing is best effort during stop/reconnect.
    }
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');
