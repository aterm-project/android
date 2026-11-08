import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'session_credentials.dart';

const _sessionSignalKey = 'atermius.session.event.v1';

/// Uses token-free, identity-scoped BroadcastChannel messages with a
/// localStorage storage-event fallback. Credential snapshots remain in
/// FlutterSecureStorage; this transport carries no bearer material. The
/// default Web storage plugin keeps its wrapping AES key beside the values in
/// same-origin localStorage, so this is not an XSS confidentiality boundary.
class _WebSessionUpdateNotifier implements SessionUpdateNotifier {
  _WebSessionUpdateNotifier() {
    if (web.window.hasProperty('BroadcastChannel'.toJS).toDart) {
      _channel = web.BroadcastChannel('atermius.session-updates.v1')
        ..onmessage = ((web.MessageEvent event) {
          final message = _messageString(event.data);
          if (message != null) _publish(message);
        }).toJS;
    }
    _onStorage = ((web.Event event) {
      final storageEvent = event as web.StorageEvent;
      if (storageEvent.key == _sessionSignalKey) {
        final message = storageEvent.newValue;
        if (message != null) _publish(message);
      }
    }).toJS;
    web.window.addEventListener('storage', _onStorage);
  }

  final StreamController<SessionUpdateEvent> _controller =
      StreamController<SessionUpdateEvent>.broadcast();
  web.BroadcastChannel? _channel;
  late final JSFunction _onStorage;
  int _eventSequence = 0;

  @override
  Stream<SessionUpdateEvent> get updates => _controller.stream;

  @override
  void signal(SessionUpdateEvent event) {
    final message = jsonEncode({
      'server': event.scope.serverNamespace,
      'account_id': event.scope.accountId,
      'device_id': event.scope.deviceId,
      'kind': event.kind.name,
      'event_id':
          '${DateTime.now().microsecondsSinceEpoch}-${_eventSequence++}',
    });
    try {
      _channel?.postMessage(message.toJS);
    } catch (_) {
      // The storage-event fallback may still deliver the token-free signal.
    }
    try {
      web.window.localStorage.setItem(_sessionSignalKey, message);
    } catch (_) {
      // BroadcastChannel remains available if localStorage is unavailable.
    }
  }

  void _publish(String message) {
    if (_controller.isClosed) return;
    final event = _decode(message);
    if (event != null) _controller.add(event);
  }

  SessionUpdateEvent? _decode(String message) {
    if (message.length > 2048) return null;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic> ||
          decoded['server'] is! String ||
          (decoded['server'] as String).isEmpty ||
          decoded['account_id'] is! String ||
          (decoded['account_id'] as String).isEmpty ||
          decoded['device_id'] is! String ||
          (decoded['device_id'] as String).isEmpty ||
          decoded['kind'] is! String) {
        return null;
      }
      SessionUpdateKind? kind;
      for (final candidate in SessionUpdateKind.values) {
        if (candidate.name == decoded['kind']) {
          kind = candidate;
          break;
        }
      }
      if (kind == null) return null;
      return SessionUpdateEvent(
        scope: SessionScope(
          serverNamespace: decoded['server'] as String,
          accountId: decoded['account_id'] as String,
          deviceId: decoded['device_id'] as String,
        ),
        kind: kind,
      );
    } on FormatException {
      return null;
    }
  }

  String? _messageString(JSAny? value) {
    if (value == null || !value.isA<JSString>()) return null;
    return (value as JSString).toDart;
  }

  @override
  void dispose() {
    web.window.removeEventListener('storage', _onStorage);
    _channel?.close();
    unawaited(_controller.close());
  }
}

SessionUpdateNotifier createSessionUpdateNotifier() =>
    _WebSessionUpdateNotifier();
