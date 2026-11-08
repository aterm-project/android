import 'dart:async';

/// The bearer credentials shared by tabs for one account/device session.
///
/// The value is persisted only through [ClientSecureStore] (which encrypts it
/// on Web). Inter-tab notifications carry identity and event type only.
class SessionCredentials {
  const SessionCredentials({
    required this.accountId,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  final String accountId;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;

  bool isAccessUsable({
    DateTime? now,
    Duration skew = const Duration(seconds: 45),
  }) => accessExpiresAt.isAfter(
    (now ?? DateTime.now().toUtc()).toUtc().add(skew),
  );
}

/// Public, non-credential identity used to scope same-origin messages.
class SessionScope {
  const SessionScope({
    required this.serverNamespace,
    required this.accountId,
    required this.deviceId,
  });

  final String serverNamespace;
  final String accountId;
  final String deviceId;

  bool matches(SessionCredentials credentials) =>
      credentials.accountId == accountId && credentials.deviceId == deviceId;

  @override
  bool operator ==(Object other) =>
      other is SessionScope &&
      other.serverNamespace == serverNamespace &&
      other.accountId == accountId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(serverNamespace, accountId, deviceId);
}

enum SessionUpdateKind {
  updated,
  removed,
  rotationPending,
  refreshUnrecoverable,
}

class SessionUpdateEvent {
  const SessionUpdateEvent({required this.scope, required this.kind});

  final SessionScope scope;
  final SessionUpdateKind kind;
}

enum SessionSnapshotStatus { ready, missing, invalid, rotationPending }

/// A secure-store read distinguishes an absent key from corrupt or unsafe
/// state. Only [SessionSnapshotStatus.ready] can authorize a refresh request.
class SessionSnapshotRead {
  const SessionSnapshotRead._(this.status, [this.credentials]);

  const SessionSnapshotRead.ready(SessionCredentials credentials)
    : this._(SessionSnapshotStatus.ready, credentials);

  const SessionSnapshotRead.missing() : this._(SessionSnapshotStatus.missing);

  const SessionSnapshotRead.invalid() : this._(SessionSnapshotStatus.invalid);

  const SessionSnapshotRead.rotationPending()
    : this._(SessionSnapshotStatus.rotationPending);

  final SessionSnapshotStatus status;
  final SessionCredentials? credentials;
}

/// Raised before a Web refresh request when cross-tab serialization is not
/// available. Callers can keep the current session and show recovery guidance.
class SessionCoordinationUnavailableException implements Exception {
  const SessionCoordinationUnavailableException();

  @override
  String toString() => 'Secure multi-tab session coordination is unavailable.';
}

/// The stored session is missing, malformed, or records an interrupted token
/// rotation. Refreshing the caller's in-memory token could replay a consumed
/// single-use token, so the user must authenticate again.
class SessionRecoveryRequiredException implements Exception {
  const SessionRecoveryRequiredException();

  @override
  String toString() => 'The stored session cannot be safely resumed.';
}

/// Raised when the pre-request rotation marker could not be made durable.
/// The refresh request is not sent in this case.
class SessionSnapshotPersistenceException implements Exception {
  const SessionSnapshotPersistenceException();

  @override
  String toString() => 'The session rotation state could not be persisted.';
}

/// Serializes refresh-token rotations across browser tabs.
abstract interface class SessionRefreshLock {
  Future<T> run<T>(Future<T> Function() action);
}

/// Announces scoped, token-free session events. Implementations must never
/// include access or refresh credentials in messages.
abstract interface class SessionUpdateNotifier {
  Stream<SessionUpdateEvent> get updates;

  void signal(SessionUpdateEvent event);

  void dispose();
}

typedef ReadSessionSnapshot = Future<SessionSnapshotRead> Function();
typedef WriteSessionCredentials =
    Future<void> Function(SessionCredentials credentials);
typedef MarkSessionRotationPending = Future<void> Function();
typedef RefreshSessionCredentials =
    Future<SessionCredentials> Function(String refreshToken);

class SessionRefreshOutcome {
  const SessionRefreshOutcome({
    required this.credentials,
    required this.rotated,
    required this.persisted,
  });

  final SessionCredentials credentials;
  final bool rotated;

  /// False means the server returned new credentials but the ready snapshot
  /// could not replace the durable rotation-pending state. The caller may keep
  /// the credentials in memory for this tab, but other tabs must reauthenticate.
  final bool persisted;
}

/// Coordinates the server's single-use refresh token without relaxing replay
/// detection. The caller's token is only a hint: after entering the shared lock
/// the coordinator checks the last encrypted ready snapshot, persists an
/// interruption marker before HTTP, and never rotates a caller-only token.
class SessionRefreshCoordinator {
  SessionRefreshCoordinator({
    required this.lock,
    required this.scope,
    required this.readLatest,
    required this.markRotationPending,
    required this.writeLatest,
    required this.refresh,
    required this.signalOtherTabs,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SessionRefreshLock lock;
  final SessionScope scope;
  final ReadSessionSnapshot readLatest;
  final MarkSessionRotationPending markRotationPending;
  final WriteSessionCredentials writeLatest;
  final RefreshSessionCredentials refresh;
  final void Function(SessionUpdateKind kind) signalOtherTabs;
  final DateTime Function() _now;

  Future<SessionRefreshOutcome> refreshIfNeeded(
    SessionCredentials callerCredentials, {
    bool force = true,
  }) => lock.run(() async {
    if (!scope.matches(callerCredentials)) {
      throw const SessionRecoveryRequiredException();
    }

    final snapshot = await readLatest();
    if (snapshot.status != SessionSnapshotStatus.ready) {
      throw const SessionRecoveryRequiredException();
    }
    final latest = snapshot.credentials;
    if (latest == null || !scope.matches(latest)) {
      throw const SessionRecoveryRequiredException();
    }

    if (latest.isAccessUsable(now: _now()) &&
        (!force ||
            latest.refreshToken != callerCredentials.refreshToken ||
            latest.accessToken != callerCredentials.accessToken)) {
      return SessionRefreshOutcome(
        credentials: latest,
        rotated: false,
        persisted: true,
      );
    }

    // Persisting this state in the same secure-store key as the ready snapshot
    // prevents any waking tab from mistaking the previous token for current.
    // A crash after this write requires reauthentication, which is safer than
    // replaying a refresh token whose request outcome may be unknown.
    try {
      await markRotationPending();
    } catch (_) {
      throw const SessionSnapshotPersistenceException();
    }
    signalOtherTabs(SessionUpdateKind.rotationPending);

    late final SessionCredentials rotated;
    try {
      rotated = await refresh(latest.refreshToken);
    } catch (_) {
      signalOtherTabs(SessionUpdateKind.refreshUnrecoverable);
      rethrow;
    }

    var persisted = true;
    try {
      await writeLatest(rotated);
    } catch (_) {
      persisted = false;
    }
    signalOtherTabs(
      persisted
          ? SessionUpdateKind.updated
          : SessionUpdateKind.refreshUnrecoverable,
    );
    return SessionRefreshOutcome(
      credentials: rotated,
      rotated: true,
      persisted: persisted,
    );
  });
}

/// Observes scoped session events and adopts only a fresh, exact session
/// snapshot. Removal and uncertain refresh outcomes clear only matching tabs.
class SessionCredentialsObserver {
  SessionCredentialsObserver({
    required Stream<SessionUpdateEvent> updates,
    required this.readLatest,
    required this.currentScope,
    required this.currentCredentials,
    required this.apply,
    required this.onExpiredSnapshot,
    required this.onSessionRemoved,
    required this.onRefreshUnrecoverable,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _subscription = updates.listen((event) => _enqueue(event));
  }

  final ReadSessionSnapshot readLatest;
  final SessionScope? Function() currentScope;
  final SessionCredentials? Function() currentCredentials;
  final void Function(SessionCredentials credentials) apply;
  final void Function() onExpiredSnapshot;
  final void Function(SessionCredentials expectedCredentials) onSessionRemoved;
  final void Function(SessionCredentials expectedCredentials)
  onRefreshUnrecoverable;
  final DateTime Function() _now;
  late final StreamSubscription<SessionUpdateEvent> _subscription;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  void _enqueue(SessionUpdateEvent event) {
    _tail = _tail.catchError((_) {}).then((_) => _handleUpdate(event));
  }

  Future<void> _handleUpdate(SessionUpdateEvent event) async {
    if (_disposed || currentScope() != event.scope) return;
    switch (event.kind) {
      case SessionUpdateKind.removed:
      case SessionUpdateKind.refreshUnrecoverable:
        await _handleTerminalEvent(event);
        return;
      case SessionUpdateKind.rotationPending:
        return;
      case SessionUpdateKind.updated:
        break;
    }

    SessionSnapshotRead snapshot;
    try {
      snapshot = await readLatest();
    } catch (_) {
      // Storage I/O errors do not mean the session was removed. Leave the
      // current session untouched and let the next authenticated action retry.
      return;
    }
    // Scope can change while secure storage is being read (for example the
    // user switches server or account). The event's original scope is no
    // longer authoritative after that await.
    if (_disposed ||
        currentScope() != event.scope ||
        snapshot.status != SessionSnapshotStatus.ready) {
      return;
    }
    final latest = snapshot.credentials;
    if (latest == null || !event.scope.matches(latest)) return;
    if (!latest.isAccessUsable(now: _now())) {
      onExpiredSnapshot();
      return;
    }
    apply(latest);
  }

  Future<void> _handleTerminalEvent(SessionUpdateEvent event) async {
    final credentialsAtEvent = currentCredentials();
    if (credentialsAtEvent == null ||
        !event.scope.matches(credentialsAtEvent)) {
      return;
    }
    SessionSnapshotRead snapshot;
    try {
      snapshot = await readLatest();
    } catch (_) {
      // A failed read cannot prove that a newer login was not saved.
      return;
    }
    // Terminal messages are also delayed reads. Never clear or adopt a session
    // after this controller has moved to another server/account/device.
    if (_disposed || currentScope() != event.scope) return;
    // A login or a ready shared-session update may win while the secure-store
    // read is in flight. A stale pending/missing snapshot must not end that
    // newer in-memory session.
    final liveCredentials = currentCredentials();
    if (!_sameSessionCredentials(liveCredentials, credentialsAtEvent)) return;
    if (snapshot.status == SessionSnapshotStatus.ready) {
      final latest = snapshot.credentials;
      if (latest == null || !event.scope.matches(latest)) return;
      final current = currentCredentials();
      if (current != null &&
          (latest.accessToken != current.accessToken ||
              latest.refreshToken != current.refreshToken)) {
        if (latest.isAccessUsable(now: _now())) {
          apply(latest);
        } else {
          onExpiredSnapshot();
        }
        return;
      }
      // A refresh-failure signal is only a hint; the durable pending state is
      // the authority. If the snapshot is ready and still current, retain it.
      if (event.kind == SessionUpdateKind.refreshUnrecoverable) return;
    }
    if (event.kind == SessionUpdateKind.removed) {
      onSessionRemoved(credentialsAtEvent);
    } else {
      onRefreshUnrecoverable(credentialsAtEvent);
    }
  }

  bool _sameSessionCredentials(
    SessionCredentials? left,
    SessionCredentials right,
  ) =>
      left != null &&
      left.accountId == right.accountId &&
      left.deviceId == right.deviceId &&
      left.accessToken == right.accessToken &&
      left.refreshToken == right.refreshToken;

  Future<void> dispose() async {
    _disposed = true;
    await _subscription.cancel();
    await _tail;
  }
}

/// Optional native subscription for the active credential scope.
abstract interface class ScopedSessionUpdateNotifier {
  void watchScope(SessionScope? scope);
}
