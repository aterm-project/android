import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../platform/native_coordination.dart';
import 'session_credentials.dart';

/// Token-free markers. Scope identities only appear in hashed file names.
class _NativeSessionUpdateNotifier
    implements SessionUpdateNotifier, ScopedSessionUpdateNotifier {
  final _controller = StreamController<SessionUpdateEvent>.broadcast();
  SessionScope? _scope;
  Timer? _timer;
  String? _generation;
  bool _baseline = true;
  bool _reading = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  Future<File> _file(SessionScope scope) async {
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([scope.serverNamespace, scope.accountId, scope.deviceId]),
      ),
    );
    final directory = await coordinationDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$digest.event');
  }

  @override
  void watchScope(SessionScope? scope) {
    if (_scope == scope || _disposed) return;
    _scope = scope;
    _generation = null;
    _baseline = true;
    _timer?.cancel();
    if (scope != null) {
      unawaited(_poll());
      _timer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => unawaited(_poll()),
      );
    }
  }

  Future<void> _poll() async {
    final scope = _scope;
    if (scope == null || _reading || _disposed) return;
    _reading = true;
    try {
      final file = await _file(scope);
      if (!await file.exists()) {
        _baseline = false;
        return;
      }
      if (await file.length() > 512) return;
      final data = jsonDecode(await file.readAsString());
      if (_disposed || _scope != scope || data is! Map<String, dynamic>) return;
      final generation = data['generation'];
      final kind = data['kind'];
      if (generation is! String || generation.length > 128) return;
      final matches = SessionUpdateKind.values.where(
        (value) => value.name == kind,
      );
      if (matches.isEmpty || generation == _generation) return;
      _generation = generation;
      if (_baseline) {
        _baseline = false;
        return;
      }
      _controller.add(SessionUpdateEvent(scope: scope, kind: matches.single));
    } on FileSystemException {
      // Concurrent writes are retried. Secure storage remains authoritative.
    } on FormatException {
      // A partially written marker is retried on the next tick.
    } catch (_) {
      // Platform support-folder availability may be transient during startup.
    } finally {
      _reading = false;
    }
  }

  @override
  Stream<SessionUpdateEvent> get updates => _controller.stream;
  @override
  void signal(SessionUpdateEvent event) {
    if (_disposed) return;
    final random = Random.secure();
    final generation = base64UrlEncode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final message = jsonEncode({
      'kind': event.kind.name,
      'generation': generation,
    });
    _writes = _writes
        .then((_) async {
          await (await _file(event.scope)).writeAsString(message, flush: true);
        })
        .catchError((Object _) {
          /* Secure-store operations still revalidate. */
        });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_controller.close());
  }
}

SessionUpdateNotifier createSessionUpdateNotifier() =>
    _NativeSessionUpdateNotifier();
