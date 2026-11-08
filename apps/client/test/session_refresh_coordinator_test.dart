import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/auth/session_update_notifier.dart';

void main() {
  group('SessionRefreshCoordinator', () {
    test(
      'serializes concurrent tab refreshes and converges credentials',
      () async {
        final issuedAt = DateTime.utc(2026, 9, 28, 10);
        final now = issuedAt.add(const Duration(minutes: 16));
        final lock = _MemoryRefreshLock();
        final store = _MemorySessionStore(
          _credentials('access-0', 'refresh-0', issuedAt),
        );
        final server = _StrictRefreshServer(now);
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        var tabA = store.value!;
        var tabB = store.value!;
        String? tabAApiAccess = tabA.accessToken;
        String? tabBApiAccess = tabB.accessToken;

        final observerA = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: store.read,
          currentScope: () => _scope,
          currentCredentials: () => tabA,
          apply: (value) {
            tabA = value;
            tabAApiAccess = value.accessToken;
          },
          onExpiredSnapshot: () {},
          onSessionRemoved: (_) {},
          onRefreshUnrecoverable: (_) {},
          now: () => now,
        );
        final observerB = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: store.read,
          currentScope: () => _scope,
          currentCredentials: () => tabB,
          apply: (value) {
            tabB = value;
            tabBApiAccess = value.accessToken;
          },
          onExpiredSnapshot: () {},
          onSessionRemoved: (_) {},
          onRefreshUnrecoverable: (_) {},
          now: () => now,
        );

        SessionRefreshCoordinator coordinator() => SessionRefreshCoordinator(
          lock: lock,
          scope: _scope,
          readLatest: store.read,
          markRotationPending: store.markPending,
          writeLatest: store.write,
          refresh: server.rotate,
          signalOtherTabs: (kind) =>
              updates.add(SessionUpdateEvent(scope: _scope, kind: kind)),
          now: () => now,
        );

        final outcomes = await Future.wait([
          coordinator().refreshIfNeeded(tabA),
          coordinator().refreshIfNeeded(tabB),
        ]);
        tabA = outcomes[0].credentials;
        tabAApiAccess = outcomes[0].credentials.accessToken;
        await Future<void>.delayed(Duration.zero);

        expect(server.rotations, 1);
        expect(server.familyRevoked, isFalse);
        expect(outcomes.map((result) => result.rotated).toSet(), {false, true});
        expect(tabA.refreshToken, 'refresh-1');
        expect(tabB.refreshToken, 'refresh-1');
        expect(tabAApiAccess, 'access-1');
        expect(tabBApiAccess, 'access-1');

        // A tab that slept through the signal rereads the shared snapshot
        // under the lock instead of replaying refresh-0.
        final lateOutcome = await coordinator().refreshIfNeeded(
          _credentials('access-0', 'refresh-0', now),
        );
        expect(lateOutcome.rotated, isFalse);
        expect(lateOutcome.credentials.accessToken, 'access-1');
        expect(server.rotations, 1);
        expect(server.familyRevoked, isFalse);

        await observerA.dispose();
        await observerB.dispose();
        await updates.close();
      },
    );

    test(
      'expired ready snapshot rotates its latest token, never the stale one',
      () async {
        final issuedAt = DateTime.utc(2026, 9, 28, 10);
        var now = issuedAt.add(const Duration(minutes: 16));
        final store = _MemorySessionStore(
          _credentials('access-0', 'refresh-0', issuedAt),
        );
        final server = _StrictRefreshServer(now);
        SessionRefreshCoordinator coordinator() => SessionRefreshCoordinator(
          lock: _MemoryRefreshLock(),
          scope: _scope,
          readLatest: store.read,
          markRotationPending: store.markPending,
          writeLatest: store.write,
          refresh: (token) {
            server.now = now;
            return server.rotate(token);
          },
          signalOtherTabs: (_) {},
          now: () => now,
        );

        await coordinator().refreshIfNeeded(
          _credentials('access-0', 'refresh-0', issuedAt),
        );
        now = now.add(const Duration(minutes: 16));
        store.value = SessionCredentials(
          accountId: store.value!.accountId,
          deviceId: store.value!.deviceId,
          accessToken: store.value!.accessToken,
          refreshToken: store.value!.refreshToken,
          accessExpiresAt: now.subtract(const Duration(seconds: 1)),
        );

        final outcome = await coordinator().refreshIfNeeded(
          _credentials('stale-access', 'refresh-0', now),
        );
        expect(outcome.rotated, isTrue);
        expect(outcome.credentials.refreshToken, 'refresh-2');
        expect(server.rotations, 2);
        expect(server.familyRevoked, isFalse);
      },
    );

    test(
      'missing, malformed, or pending snapshot never falls back to caller',
      () async {
        for (final status in [
          SessionSnapshotStatus.missing,
          SessionSnapshotStatus.invalid,
          SessionSnapshotStatus.rotationPending,
        ]) {
          var refreshCalls = 0;
          final store = _MemorySessionStore(
            _credentials('access-0', 'refresh-0', DateTime.now()),
          )..status = status;
          final coordinator = _coordinator(
            store: store,
            refresh: (token) async {
              refreshCalls++;
              return _credentials('access-1', '$token-next', DateTime.now());
            },
          );

          await expectLater(
            coordinator.refreshIfNeeded(
              _credentials('stale', 'caller-only-token', DateTime.now()),
            ),
            throwsA(isA<SessionRecoveryRequiredException>()),
          );
          expect(refreshCalls, 0);
          expect(store.markPendingCalls, 0);
        }
      },
    );

    test('does not call server when pending-state write fails', () async {
      var refreshCalls = 0;
      final store = _MemorySessionStore(
        _credentials('access-0', 'refresh-0', DateTime.now()),
      )..failPendingWrite = true;
      final coordinator = _coordinator(
        store: store,
        refresh: (_) async {
          refreshCalls++;
          return _credentials('access-1', 'refresh-1', DateTime.now());
        },
      );

      await expectLater(
        coordinator.refreshIfNeeded(
          _credentials('access-0', 'refresh-0', DateTime.now()),
        ),
        throwsA(isA<SessionSnapshotPersistenceException>()),
      );
      expect(refreshCalls, 0);
      expect(store.status, SessionSnapshotStatus.ready);
    });

    test(
      'failed ready write leaves durable pending state and prevents replay',
      () async {
        final now = DateTime.utc(2026, 9, 28, 10);
        final store = _MemorySessionStore(
          _credentials('access-0', 'refresh-0', now),
        )..failReadyWrite = true;
        final server = _StrictRefreshServer(now);
        final events = <SessionUpdateKind>[];
        final coordinator = _coordinator(
          store: store,
          refresh: server.rotate,
          onSignal: events.add,
        );

        final outcome = await coordinator.refreshIfNeeded(
          _credentials('access-0', 'refresh-0', now),
        );
        expect(outcome.rotated, isTrue);
        expect(outcome.persisted, isFalse);
        expect(store.status, SessionSnapshotStatus.rotationPending);
        expect(server.rotations, 1);
        expect(server.familyRevoked, isFalse);
        expect(events, [
          SessionUpdateKind.rotationPending,
          SessionUpdateKind.refreshUnrecoverable,
        ]);

        await expectLater(
          _coordinator(
            store: store,
            refresh: server.rotate,
          ).refreshIfNeeded(_credentials('access-0', 'refresh-0', now)),
          throwsA(isA<SessionRecoveryRequiredException>()),
        );
        expect(server.rotations, 1);
        expect(server.familyRevoked, isFalse);
      },
    );

    test(
      'uncertain refresh response remains pending and is never retried',
      () async {
        final store = _MemorySessionStore(
          _credentials('access-0', 'refresh-0', DateTime.now()),
        );
        var refreshCalls = 0;
        final coordinator = _coordinator(
          store: store,
          refresh: (_) async {
            refreshCalls++;
            throw StateError('response outcome is uncertain');
          },
        );

        await expectLater(
          coordinator.refreshIfNeeded(
            _credentials('access-0', 'refresh-0', DateTime.now()),
          ),
          throwsStateError,
        );
        expect(store.status, SessionSnapshotStatus.rotationPending);
        await expectLater(
          coordinator.refreshIfNeeded(
            _credentials('access-0', 'refresh-0', DateTime.now()),
          ),
          throwsA(isA<SessionRecoveryRequiredException>()),
        );
        expect(refreshCalls, 1);
      },
    );

    test(
      'fails before network rotation when no shared lock is available',
      () async {
        var refreshCalls = 0;
        final store = _MemorySessionStore(
          _credentials('access-0', 'refresh-0', DateTime.now()),
        );
        final coordinator = _coordinator(
          lock: _UnavailableRefreshLock(),
          store: store,
          refresh: (_) async {
            refreshCalls++;
            return _credentials('access-1', 'refresh-1', DateTime.now());
          },
        );

        await expectLater(
          coordinator.refreshIfNeeded(
            _credentials('access-0', 'refresh-0', DateTime.now()),
          ),
          throwsA(isA<SessionCoordinationUnavailableException>()),
        );
        expect(refreshCalls, 0);
        expect(store.markPendingCalls, 0);
      },
    );

    test(
      'observer ignores unrelated, missing, malformed, and failed reads',
      () async {
        final now = DateTime.utc(2026, 9, 28, 10);
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        var removeCalls = 0;
        var recoveryCalls = 0;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () async => const SessionSnapshotRead.missing(),
          currentScope: () => _scope,
          currentCredentials: () =>
              _credentials('old-access', 'old-refresh', now),
          apply: (_) => fail('A missing snapshot must not be adopted.'),
          onExpiredSnapshot: () => fail('No snapshot can mean expiry.'),
          onSessionRemoved: (_) => removeCalls++,
          onRefreshUnrecoverable: (_) => recoveryCalls++,
          now: () => now,
        );
        final otherScope = SessionScope(
          serverNamespace: _scope.serverNamespace,
          accountId: 'other-account',
          deviceId: _scope.deviceId,
        );

        updates.add(
          const SessionUpdateEvent(
            scope: SessionScope(
              serverNamespace: 'https://sync.example.test',
              accountId: 'other-account',
              deviceId: 'device-1',
            ),
            kind: SessionUpdateKind.removed,
          ),
        );
        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.updated,
          ),
        );
        updates.add(
          SessionUpdateEvent(
            scope: otherScope,
            kind: SessionUpdateKind.refreshUnrecoverable,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(removeCalls, 0);
        expect(recoveryCalls, 0);
        await observer.dispose();
        await updates.close();
      },
    );

    test(
      'observer does not interpret secure-store I/O error as logout',
      () async {
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        var removed = false;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () => Future<SessionSnapshotRead>.error(StateError('io')),
          currentScope: () => _scope,
          currentCredentials: () =>
              _credentials('old-access', 'old-refresh', DateTime.now()),
          apply: (_) =>
              fail('No credentials are available after a read error.'),
          onExpiredSnapshot: () => fail('Read error is not expiry.'),
          onSessionRemoved: (_) => removed = true,
          onRefreshUnrecoverable: (_) => removed = true,
        );
        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.updated,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(removed, isFalse);
        await observer.dispose();
        await updates.close();
      },
    );

    test(
      'updated snapshot is ignored if scope changes during secure read',
      () async {
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        final readStarted = Completer<void>();
        final finishRead = Completer<SessionSnapshotRead>();
        var activeScope = _scope;
        var applied = false;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () {
            readStarted.complete();
            return finishRead.future;
          },
          currentScope: () => activeScope,
          currentCredentials: () =>
              _credentials('old-access', 'old-refresh', DateTime.now()),
          apply: (_) => applied = true,
          onExpiredSnapshot: () => fail('An out-of-scope snapshot is ignored.'),
          onSessionRemoved: (_) => fail('An update cannot clear the session.'),
          onRefreshUnrecoverable: (_) =>
              fail('An update cannot clear the session.'),
        );

        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.updated,
          ),
        );
        await readStarted.future;
        activeScope = const SessionScope(
          serverNamespace: 'https://other.example.test',
          accountId: 'account-1',
          deviceId: 'device-1',
        );
        finishRead.complete(
          SessionSnapshotRead.ready(
            _credentials('new-access', 'new-refresh', DateTime.now()),
          ),
        );
        await observer.dispose();

        expect(applied, isFalse);
        await updates.close();
      },
    );

    test(
      'terminal removal is ignored if scope changes during secure read',
      () async {
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        final readStarted = Completer<void>();
        final finishRead = Completer<SessionSnapshotRead>();
        var activeScope = _scope;
        var removed = false;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () {
            readStarted.complete();
            return finishRead.future;
          },
          currentScope: () => activeScope,
          currentCredentials: () =>
              _credentials('old-access', 'old-refresh', DateTime.now()),
          apply: (_) => fail('A terminal removal cannot adopt credentials.'),
          onExpiredSnapshot: () => fail('A missing snapshot is not expired.'),
          onSessionRemoved: (_) => removed = true,
          onRefreshUnrecoverable: (_) => fail('This was a removal event.'),
        );

        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.removed,
          ),
        );
        await readStarted.future;
        activeScope = const SessionScope(
          serverNamespace: 'https://other.example.test',
          accountId: 'account-1',
          deviceId: 'device-1',
        );
        finishRead.complete(const SessionSnapshotRead.missing());
        await observer.dispose();

        expect(removed, isFalse);
        await updates.close();
      },
    );

    test(
      'delayed removal adopts a newer ready login instead of clearing it',
      () async {
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        final oldCredentials = _credentials(
          'old-access',
          'old-refresh',
          DateTime.now(),
        );
        final newerCredentials = _credentials(
          'new-access',
          'new-refresh',
          DateTime.now(),
        );
        var current = oldCredentials;
        var removed = false;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () async => SessionSnapshotRead.ready(newerCredentials),
          currentScope: () => _scope,
          currentCredentials: () => current,
          apply: (value) => current = value,
          onExpiredSnapshot: () => fail('The new access snapshot is fresh.'),
          onSessionRemoved: (_) => removed = true,
          onRefreshUnrecoverable: (_) => removed = true,
        );

        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.removed,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(removed, isFalse);
        expect(current.accessToken, 'new-access');
        expect(current.refreshToken, 'new-refresh');
        await observer.dispose();
        await updates.close();
      },
    );

    test(
      'stale terminal snapshot cannot clear credentials adopted during its read',
      () async {
        final updates = StreamController<SessionUpdateEvent>.broadcast();
        final readStarted = Completer<void>();
        final finishRead = Completer<SessionSnapshotRead>();
        final oldCredentials = _credentials(
          'old-access',
          'old-refresh',
          DateTime.now(),
        );
        final newerCredentials = _credentials(
          'new-access',
          'new-refresh',
          DateTime.now(),
        );
        var current = oldCredentials;
        var terminalCalls = 0;
        final observer = SessionCredentialsObserver(
          updates: updates.stream,
          readLatest: () {
            readStarted.complete();
            return finishRead.future;
          },
          currentScope: () => _scope,
          currentCredentials: () => current,
          apply: (value) => current = value,
          onExpiredSnapshot: () => fail('A pending snapshot is not expiry.'),
          onSessionRemoved: (_) => terminalCalls++,
          onRefreshUnrecoverable: (_) => terminalCalls++,
        );

        updates.add(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.refreshUnrecoverable,
          ),
        );
        await readStarted.future;
        current = newerCredentials;
        finishRead.complete(const SessionSnapshotRead.rotationPending());
        await observer.dispose();

        expect(current.accessToken, 'new-access');
        expect(current.refreshToken, 'new-refresh');
        expect(terminalCalls, 0);
        await updates.close();
      },
    );

    test('unrecoverable hint cannot clear a matching ready snapshot', () async {
      final updates = StreamController<SessionUpdateEvent>.broadcast();
      final current = _credentials('access-1', 'refresh-1', DateTime.now());
      var recoveryRequested = false;
      final observer = SessionCredentialsObserver(
        updates: updates.stream,
        readLatest: () async => SessionSnapshotRead.ready(current),
        currentScope: () => _scope,
        currentCredentials: () => current,
        apply: (_) => fail('The ready snapshot already matches.'),
        onExpiredSnapshot: () => fail('The ready snapshot is fresh.'),
        onSessionRemoved: (_) => fail('A matching ready snapshot is current.'),
        onRefreshUnrecoverable: (_) => recoveryRequested = true,
      );

      updates.add(
        const SessionUpdateEvent(
          scope: _scope,
          kind: SessionUpdateKind.refreshUnrecoverable,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(recoveryRequested, isFalse);
      await observer.dispose();
      await updates.close();
    });

    test(
      'native session notifier does not echo its own login signal',
      () async {
        final notifier = createSessionUpdateNotifier();
        var events = 0;
        final subscription = notifier.updates.listen((_) => events++);

        notifier.signal(
          const SessionUpdateEvent(
            scope: _scope,
            kind: SessionUpdateKind.updated,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(events, 0);
        await subscription.cancel();
        notifier.dispose();
      },
    );
  });
}

const _scope = SessionScope(
  serverNamespace: 'https://sync.example.test',
  accountId: 'account-1',
  deviceId: 'device-1',
);

SessionCredentials _credentials(String access, String refresh, DateTime now) =>
    SessionCredentials(
      accountId: _scope.accountId,
      deviceId: _scope.deviceId,
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: now.toUtc().add(const Duration(minutes: 15)),
    );

SessionRefreshCoordinator _coordinator({
  required _MemorySessionStore store,
  required Future<SessionCredentials> Function(String) refresh,
  void Function(SessionUpdateKind)? onSignal,
  SessionRefreshLock? lock,
}) => SessionRefreshCoordinator(
  lock: lock ?? _MemoryRefreshLock(),
  scope: _scope,
  readLatest: store.read,
  markRotationPending: store.markPending,
  writeLatest: store.write,
  refresh: refresh,
  signalOtherTabs: onSignal ?? (_) {},
);

class _MemorySessionStore {
  _MemorySessionStore(this.value);

  SessionCredentials? value;
  SessionSnapshotStatus status = SessionSnapshotStatus.ready;
  bool failPendingWrite = false;
  bool failReadyWrite = false;
  int markPendingCalls = 0;

  Future<SessionSnapshotRead> read() async {
    switch (status) {
      case SessionSnapshotStatus.ready:
        final credentials = value;
        return credentials == null
            ? const SessionSnapshotRead.invalid()
            : SessionSnapshotRead.ready(credentials);
      case SessionSnapshotStatus.missing:
        return const SessionSnapshotRead.missing();
      case SessionSnapshotStatus.invalid:
        return const SessionSnapshotRead.invalid();
      case SessionSnapshotStatus.rotationPending:
        return const SessionSnapshotRead.rotationPending();
    }
  }

  Future<void> markPending() async {
    markPendingCalls++;
    if (failPendingWrite) throw StateError('pending write failed');
    status = SessionSnapshotStatus.rotationPending;
  }

  Future<void> write(SessionCredentials credentials) async {
    if (failReadyWrite) throw StateError('ready write failed');
    value = credentials;
    status = SessionSnapshotStatus.ready;
  }
}

class _MemoryRefreshLock implements SessionRefreshLock {
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}

class _UnavailableRefreshLock implements SessionRefreshLock {
  @override
  Future<T> run<T>(Future<T> Function() action) =>
      Future<T>.error(const SessionCoordinationUnavailableException());
}

class _StrictRefreshServer {
  _StrictRefreshServer(this.now);

  DateTime now;
  int rotations = 0;
  bool familyRevoked = false;
  String currentRefreshToken = 'refresh-0';
  final Set<String> _consumed = {};

  Future<SessionCredentials> rotate(String refreshToken) async {
    if (refreshToken != currentRefreshToken) {
      if (_consumed.contains(refreshToken)) familyRevoked = true;
      throw StateError('Refresh rejected');
    }
    _consumed.add(refreshToken);
    rotations++;
    currentRefreshToken = 'refresh-$rotations';
    return _credentials('access-$rotations', currentRefreshToken, now);
  }
}
