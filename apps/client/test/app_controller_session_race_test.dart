import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('logout compare-delete waits behind a newer session write', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final lock = _QueuedRefreshLock();
    final store = _MutableSessionStore(
      _credentials('old-access', 'old-refresh', DateTime.now()),
    );
    final notifier = _RecordingSessionNotifier();
    final api = _NoopLogoutApi();
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: store,
            sessionUpdateNotifierForTesting: notifier,
            sessionRefreshLockForTesting: lock,
          )
          ..api = api
          ..session = _auth('old-access', 'old-refresh')
          ..authenticatedUsernameForTesting = 'alice'
          ..stage = ClientStage.workspace;

    final releaseLock = Completer<void>();
    final lockHeld = Completer<void>();
    final blocker = lock.run(() async {
      lockHeld.complete();
      await releaseLock.future;
    });
    await lockHeld.future;

    final newest = _credentials('new-access', 'new-refresh', DateTime.now());
    final newerWrite = lock.run(
      () => store.saveSessionCredentials(api.baseUrl, 'alice', newest),
    );
    final logout = controller.logout();
    releaseLock.complete();
    await Future.wait([blocker, newerWrite, logout]);

    expect(store.value?.refreshToken, 'new-refresh');
    expect(store.deleteCalls, 1);
    expect(
      notifier.sent.where((event) => event.kind == SessionUpdateKind.removed),
      isEmpty,
    );

    controller.dispose();
    notifier.dispose();
    api.close();
    await database.close();
  });

  test('a tab retries sync hints after adopting another tab refresh', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final lock = _QueuedRefreshLock();
    final oldCredentials = _credentials(
      'old-access',
      'old-refresh',
      DateTime.now(),
    );
    final store = _MutableSessionStore(oldCredentials);
    final notifier = _RecordingSessionNotifier();
    final api = _ControlledRefreshApi();
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: store,
            sessionUpdateNotifierForTesting: notifier,
            sessionRefreshLockForTesting: lock,
          )
          ..api = api
          ..session = _auth('old-access', 'old-refresh')
          ..authenticatedUsernameForTesting = 'alice'
          ..stage = ClientStage.workspace;
    api.accessToken = 'old-access';

    final releaseLock = Completer<void>();
    final lockHeld = Completer<void>();
    final blocker = lock.run(() async {
      lockHeld.complete();
      await releaseLock.future;
    });
    await lockHeld.future;

    final refresh = controller.refreshSessionForTesting();
    final rotated = _credentials(
      'rotated-access',
      'rotated-refresh',
      DateTime.now(),
    );
    store
      ..value = rotated
      ..status = SessionSnapshotStatus.ready;
    notifier.signal(
      SessionUpdateEvent(
        scope: SessionScope(
          serverNamespace: secureStorageNamespace(api.baseUrl),
          accountId: 'account-1',
          deviceId: 'device-1',
        ),
        kind: SessionUpdateKind.updated,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.session?.accessToken, 'rotated-access');

    releaseLock.complete();
    await blocker;
    expect(await refresh, isTrue);
    expect(api.accessToken, 'rotated-access');
    expect(controller.session?.refreshToken, 'rotated-refresh');
    expect(controller.stage, ClientStage.workspace);
    expect(api.refreshStarted.isCompleted, isFalse);

    controller.dispose();
    notifier.dispose();
    api.close();
    await database.close();
  });

  test(
    'vault hydration retries after another tab rotates its devices bearer',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final oldSession = _sessionForDevice(
        identity.deviceId,
        'old-access',
        'old-refresh',
      );
      final store = _MutableSessionStore(
        SessionCredentials(
          accountId: 'account-1',
          deviceId: identity.deviceId,
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          accessExpiresAt: DateTime.now().toUtc().add(
            const Duration(minutes: 15),
          ),
        ),
      );
      final notifier = _RecordingSessionNotifier();
      final api = _DevicesRefreshRaceApi()..accessToken = 'old-access';
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: store,
              sessionUpdateNotifierForTesting: notifier,
              sessionRefreshLockForTesting: _QueuedRefreshLock(),
            )
            ..api = api
            ..session = oldSession
            ..identity = identity
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace;

      try {
        final vaultLoad = controller.loadVaultsForTesting();
        await api.firstDevicesRequest.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('devices hydration never started'),
        );

        // Model another tab finishing a refresh while this GET still carries
        // the old bearer. The active server hash and shared snapshot now point
        // at the new token, so the request's captured bearer will be rejected.
        store
          ..value = SessionCredentials(
            accountId: 'account-1',
            deviceId: identity.deviceId,
            accessToken: 'rotated-access',
            refreshToken: 'rotated-refresh',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(minutes: 15),
            ),
          )
          ..status = SessionSnapshotStatus.ready;
        api.accessToken = 'rotated-access';
        expect(api.accessToken, 'rotated-access');
        api.releaseFirstDevicesRequest.complete();

        await vaultLoad;

        expect(api.devicesBearerTokens, ['old-access', 'rotated-access']);
        expect(api.refreshTokens, isEmpty);
        expect(controller.session?.accessToken, 'rotated-access');
      } finally {
        controller.dispose();
        notifier.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test('unlock drains a locked-hint refresh before vault hydration', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final params = KdfParameters(
      salt: Uint8List.fromList(List<int>.filled(16, 0x42)),
      iterations: 3,
    );
    final accountKey = Uint8List.fromList(List<int>.filled(32, 0x37));
    final envelope = await VaultCrypto(sodium).wrapAccountKey(
      password: 'unlock-password',
      params: params,
      accountKey: accountKey,
    );
    final profile = AccountProfile(
      accountId: 'account-1',
      deviceId: identity.deviceId,
      accountKeyEnvelopeVersion: 1,
      accountKeyEnvelope: Map<String, dynamic>.from(envelope),
    );
    final oldSession = _sessionForDevice(
      identity.deviceId,
      'old-access',
      'old-refresh',
    );
    final store = _UnlockRaceStore(
      SessionCredentials(
        accountId: 'account-1',
        deviceId: identity.deviceId,
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        accessExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 15),
        ),
      ),
      identity,
    );
    final notifier = _RecordingSessionNotifier();
    final api = _UnlockRaceApi(profile: profile, kdf: params)
      ..accessToken = 'old-access';
    final controller =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: store,
            sessionUpdateNotifierForTesting: notifier,
            sessionRefreshLockForTesting: _QueuedRefreshLock(),
          )
          ..api = api
          ..session = oldSession
          ..authenticatedUsernameForTesting = 'alice'
          ..stage = ClientStage.workspace
          ..workspaceLocked = true;
    final rotatedSession = _sessionForDevice(
      identity.deviceId,
      'rotated-access',
      'rotated-refresh',
    );

    try {
      final lockedHintRefresh = controller.refreshSessionForTesting();
      await api.refreshStarted.future;

      final unlock = controller.unlockLockedWorkspace(
        password: 'unlock-password',
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.preloginCalls, 0);
      expect(api.devicesBearerTokens, isEmpty);

      api.refreshResponse.complete(rotatedSession);
      expect(await lockedHintRefresh, isTrue);
      await unlock;

      expect(api.preloginBearers, ['rotated-access']);
      expect(api.devicesBearerTokens, ['rotated-access']);
      expect(api.refreshTokens, ['old-refresh']);
      expect(controller.session?.accessToken, 'rotated-access');
      expect(controller.workspaceLocked, isFalse);
    } finally {
      controller.dispose();
      notifier.dispose();
      api.close();
      identity.dispose();
      accountKey.fillRange(0, accountKey.length, 0);
      params.salt.fillRange(0, params.salt.length, 0);
      await database.close();
    }
  });

  test(
    'replacement-session hydration does not join a stale refresh flight',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final lock = _ObservedQueuedRefreshLock();
      final oldCredentials = SessionCredentials(
        accountId: 'account-old',
        deviceId: identity.deviceId,
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        accessExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 15),
        ),
      );
      final store = _MutableSessionStore(oldCredentials);
      final notifier = _RecordingSessionNotifier();
      final api = _SupersededRefreshHydrationApi()..accessToken = 'old-access';
      final oldSession = AuthSession(
        accountId: 'account-old',
        accessToken: 'old-access',
        expiresIn: 900,
        refreshToken: 'old-refresh',
        deviceId: identity.deviceId,
        vaults: const [],
      );
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: store,
              sessionUpdateNotifierForTesting: notifier,
              sessionRefreshLockForTesting: lock,
            )
            ..api = api
            ..session = oldSession
            ..identity = identity
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace;

      Future<bool>? oldRefresh;
      Future<void>? hydration;
      try {
        oldRefresh = controller.refreshSessionForTesting();
        await api.oldRefreshStarted.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('old session refresh never started'),
        );

        final replacementSession = AuthSession(
          accountId: 'account-new',
          accessToken: 'new-access',
          expiresIn: 900,
          refreshToken: 'new-refresh',
          deviceId: identity.deviceId,
          vaults: const [],
        );
        final coordinatedCredentials = SessionCredentials(
          accountId: 'account-new',
          deviceId: identity.deviceId,
          accessToken: 'latest-access',
          refreshToken: 'latest-refresh',
          accessExpiresAt: DateTime.now().toUtc().add(
            const Duration(minutes: 15),
          ),
        );
        store
          ..value = coordinatedCredentials
          ..status = SessionSnapshotStatus.ready;
        controller
          ..session = replacementSession
          ..authenticatedUsernameForTesting = 'bob'
          ..stage = ClientStage.workspace;
        api.accessToken = 'new-access';

        hydration = controller.loadVaultsForTesting();
        await lock.secondRunQueued.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError(
            'replacement hydration joined the stale refresh instead of queuing',
          ),
        );

        api.oldRefreshResponse.completeError(
          const ApiException(
            statusCode: 401,
            code: 'AUTH_REQUIRED',
            message: 'old account session expired',
          ),
        );
        expect(await oldRefresh, isFalse);
        await lock.secondActionBlocked.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError(
            'replacement refresh did not reach the shared lock',
          ),
        );

        expect(controller.session, same(replacementSession));
        expect(api.accessToken, 'new-access');
        final coalescedRefresh = controller.refreshSessionForTesting();
        expect(lock.runCalls, 2);
        lock.releaseSecondAction.complete();

        await hydration;
        expect(await coalescedRefresh, isTrue);
        expect(api.refreshTokens, ['old-refresh']);
        expect(api.devicesBearerTokens, ['new-access', 'latest-access']);
        expect(controller.session?.accountId, 'account-new');
        expect(controller.session?.accessToken, 'latest-access');
        expect(controller.session?.refreshToken, 'latest-refresh');
        expect(api.accessToken, 'latest-access');
        expect(controller.stage, ClientStage.workspace);
      } finally {
        if (!api.oldRefreshResponse.isCompleted) {
          api.oldRefreshResponse.completeError(
            const ApiException(
              statusCode: 401,
              code: 'AUTH_REQUIRED',
              message: 'old account session expired',
            ),
          );
        }
        if (!lock.releaseSecondAction.isCompleted) {
          lock.releaseSecondAction.complete();
        }
        if (oldRefresh != null) {
          await oldRefresh.catchError((_) => false);
        }
        if (hydration != null) {
          await hydration.catchError((_) {});
        }
        controller.dispose();
        notifier.dispose();
        api.close();
        await database.close();
      }
    },
  );

  test(
    'unsafe missing session clears auth and shows reauthentication notice',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final store = _MutableSessionStore(null)
        ..status = SessionSnapshotStatus.missing;
      final api = _ControlledRefreshApi();
      final controller =
          AppController(sodium: sodium, database: database, secureStore: store)
            ..api = api
            ..session = _auth('old-access', 'old-refresh')
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace;
      api.accessToken = 'old-access';

      expect(await controller.refreshSessionForTesting(), isFalse);

      expect(controller.session, isNull);
      expect(controller.stage, ClientStage.login);
      expect(controller.noticeMessage, contains('请重新登录'));
      expect(api.accessToken, isNull);

      controller.dispose();
      api.close();
      await database.close();
    },
  );

  for (final failRefresh in [false, true]) {
    test(
      'old ${failRefresh ? 'failing' : 'successful'} refresh cannot replace a newer login',
      () async {
        final sodium = await SodiumSumoInit.init();
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        final lock = _QueuedRefreshLock();
        final oldCredentials = _credentials(
          'old-access',
          'old-refresh',
          DateTime.now().subtract(const Duration(minutes: 20)),
        );
        final store = _MutableSessionStore(oldCredentials);
        final api = _ControlledRefreshApi();
        final controller =
            AppController(
                sodium: sodium,
                database: database,
                secureStore: store,
                sessionRefreshLockForTesting: lock,
              )
              ..api = api
              ..session = _auth('old-access', 'old-refresh')
              ..authenticatedUsernameForTesting = 'alice'
              ..stage = ClientStage.workspace;
        api.accessToken = 'old-access';

        final oldRefresh = controller.refreshSessionForTesting();
        await api.refreshStarted.future;

        // Model logout followed by a successful login using the same account,
        // device, and ApiClient instance while the old HTTP response is blocked.
        final newer = _auth('new-access', 'new-refresh');
        controller
          ..session = newer
          ..authenticatedUsernameForTesting = 'alice'
          ..stage = ClientStage.workspace;
        api.accessToken = 'new-access';
        final newestCredentials = _credentials(
          'new-access',
          'new-refresh',
          DateTime.now(),
        );
        final newerWrite = lock.run(
          () => store.saveSessionCredentials(
            api.baseUrl,
            'alice',
            newestCredentials,
          ),
        );

        if (failRefresh) {
          api.response.completeError(
            const ApiException(
              statusCode: 401,
              code: 'AUTH_REQUIRED',
              message: 'expired',
            ),
          );
        } else {
          api.response.complete(_auth('rotated-access', 'rotated-refresh'));
        }

        expect(await oldRefresh, isFalse);
        await newerWrite;
        expect(controller.session, same(newer));
        expect(controller.session?.accessToken, 'new-access');
        expect(api.accessToken, 'new-access');
        expect(controller.stage, ClientStage.workspace);
        expect(store.value?.refreshToken, 'new-refresh');

        controller.dispose();
        api.close();
        await database.close();
      },
    );
  }
}

SessionCredentials _credentials(String access, String refresh, DateTime now) =>
    SessionCredentials(
      accountId: 'account-1',
      deviceId: 'device-1',
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: now.toUtc().add(const Duration(minutes: 15)),
    );

AuthSession _auth(String access, String refresh) => AuthSession(
  accountId: 'account-1',
  accessToken: access,
  expiresIn: 900,
  refreshToken: refresh,
  deviceId: 'device-1',
  vaults: const [],
);

AuthSession _sessionForDevice(String deviceId, String access, String refresh) =>
    AuthSession(
      accountId: 'account-1',
      accessToken: access,
      expiresIn: 900,
      refreshToken: refresh,
      deviceId: deviceId,
      vaults: const [],
    );

class _MutableSessionStore extends ClientSecureStore {
  _MutableSessionStore(this.value);

  SessionCredentials? value;
  SessionSnapshotStatus status = SessionSnapshotStatus.ready;
  int deleteCalls = 0;

  @override
  Future<SessionSnapshotRead> readSessionSnapshot(
    String baseUrl,
    String username,
    String deviceId,
  ) async {
    if (status == SessionSnapshotStatus.rotationPending) {
      return const SessionSnapshotRead.rotationPending();
    }
    final current = value;
    if (status != SessionSnapshotStatus.ready || current == null) {
      return const SessionSnapshotRead.missing();
    }
    return SessionSnapshotRead.ready(current);
  }

  @override
  Future<void> markSessionRotationPending(
    String baseUrl,
    String username,
    SessionScope scope,
  ) async {
    status = SessionSnapshotStatus.rotationPending;
  }

  @override
  Future<void> saveRefreshToken(
    String baseUrl,
    String username,
    String token,
  ) async {}

  @override
  Future<void> saveSessionSnapshot(
    String baseUrl,
    String username,
    SessionCredentials credentials,
  ) async {
    value = credentials;
    status = SessionSnapshotStatus.ready;
  }

  @override
  Future<void> saveSessionCredentials(
    String baseUrl,
    String username,
    SessionCredentials credentials,
  ) async {
    value = credentials;
    status = SessionSnapshotStatus.ready;
  }

  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async {
    deleteCalls++;
    if (value?.refreshToken != expectedRefreshToken) return false;
    value = null;
    status = SessionSnapshotStatus.missing;
    return true;
  }
}

class _QueuedRefreshLock implements SessionRefreshLock {
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

class _ObservedQueuedRefreshLock implements SessionRefreshLock {
  final _QueuedRefreshLock _queue = _QueuedRefreshLock();
  final Completer<void> secondRunQueued = Completer<void>();
  final Completer<void> secondActionBlocked = Completer<void>();
  final Completer<void> releaseSecondAction = Completer<void>();
  int runCalls = 0;

  @override
  Future<T> run<T>(Future<T> Function() action) {
    final callNumber = ++runCalls;
    if (callNumber == 2) secondRunQueued.complete();
    return _queue.run(() async {
      if (callNumber == 2) {
        secondActionBlocked.complete();
        await releaseSecondAction.future;
      }
      return action();
    });
  }
}

class _ControlledRefreshApi extends ApiClient {
  _ControlledRefreshApi() : super(baseUrl: 'https://sync.example.test');

  final Completer<void> refreshStarted = Completer<void>();
  final Completer<AuthSession> response = Completer<AuthSession>();

  @override
  Future<AuthSession> refresh(String refreshToken) {
    refreshStarted.complete();
    return response.future.then((session) {
      accessToken = session.accessToken;
      return session;
    });
  }
}

class _DevicesRefreshRaceApi extends ApiClient {
  _DevicesRefreshRaceApi() : super(baseUrl: 'https://sync.example.test');

  final Completer<void> firstDevicesRequest = Completer<void>();
  final Completer<void> releaseFirstDevicesRequest = Completer<void>();
  final List<String?> devicesBearerTokens = [];
  final List<String> refreshTokens = [];
  final List<AuthSession> refreshResponses = [];
  int _devicesCalls = 0;

  @override
  Future<List<VaultDescriptor>> vaults() async => const [];

  @override
  Future<List<Map<String, dynamic>>> devices() async {
    final requestBearer = accessToken;
    devicesBearerTokens.add(requestBearer);
    _devicesCalls++;
    if (_devicesCalls == 1) {
      firstDevicesRequest.complete();
      await releaseFirstDevicesRequest.future;
      if (requestBearer != accessToken) {
        throw const ApiException(
          statusCode: 401,
          code: 'AUTH_REQUIRED',
          message: 'Request bearer was replaced during refresh.',
        );
      }
    }
    return const [];
  }

  @override
  Future<AuthSession> refresh(String refreshToken) async {
    refreshTokens.add(refreshToken);
    final refreshed = refreshResponses.removeAt(0);
    accessToken = refreshed.accessToken;
    return refreshed;
  }
}

class _SupersededRefreshHydrationApi extends ApiClient {
  _SupersededRefreshHydrationApi()
    : super(baseUrl: 'https://sync.example.test');

  final Completer<void> oldRefreshStarted = Completer<void>();
  final Completer<AuthSession> oldRefreshResponse = Completer<AuthSession>();
  final List<String> refreshTokens = [];
  final List<String?> devicesBearerTokens = [];

  @override
  Future<AuthSession> refresh(String refreshToken) {
    refreshTokens.add(refreshToken);
    if (refreshToken != 'old-refresh') {
      return Future<AuthSession>.error(
        StateError('unexpected refresh token for replacement session'),
      );
    }
    oldRefreshStarted.complete();
    return oldRefreshResponse.future.then((session) {
      accessToken = session.accessToken;
      return session;
    });
  }

  @override
  Future<List<VaultDescriptor>> vaults() async => const [];

  @override
  Future<List<Map<String, dynamic>>> devices() async {
    devicesBearerTokens.add(accessToken);
    if (devicesBearerTokens.length == 1) {
      throw const ApiException(
        statusCode: 401,
        code: 'AUTH_REQUIRED',
        message: 'The request bearer was rotated.',
      );
    }
    if (devicesBearerTokens.length > 2) {
      throw StateError('hydration retried devices more than once');
    }
    return const [];
  }
}

class _UnlockRaceApi extends ApiClient {
  _UnlockRaceApi({required this.profile, required this.kdf})
    : super(baseUrl: 'https://sync.example.test');

  final AccountProfile profile;
  final KdfParameters kdf;
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<AuthSession> refreshResponse = Completer<AuthSession>();
  final List<String> refreshTokens = [];
  final List<String?> preloginBearers = [];
  final List<String?> devicesBearerTokens = [];
  int preloginCalls = 0;

  @override
  Future<AuthSession> refresh(String refreshToken) {
    refreshTokens.add(refreshToken);
    refreshStarted.complete();
    return refreshResponse.future.then((session) {
      accessToken = session.accessToken;
      return session;
    });
  }

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    preloginCalls++;
    preloginBearers.add(accessToken);
    return {'kdf': kdf.toJson()};
  }

  @override
  Future<AccountProfile> accountProfile() async => profile;

  @override
  Future<List<VaultDescriptor>> vaults() async => const [];

  @override
  Future<List<Map<String, dynamic>>> devices() async {
    devicesBearerTokens.add(accessToken);
    return const [];
  }

  @override
  Future<AccountRecoveryContexts> accountRecoveryContexts() async =>
      const AccountRecoveryContexts(
        generation: 0,
        required: [],
        present: [],
        status: 'disabled',
      );
}

class _UnlockRaceStore extends _MutableSessionStore {
  _UnlockRaceStore(super.initial, this.identity);

  final DeviceIdentity identity;

  @override
  Future<DeviceIdentity?> loadDevice(
    String baseUrl,
    VaultCrypto crypto,
  ) async =>
      DeviceIdentity.fromStorage(crypto.sodium, identity.toStorageJson());
}

class _NoopLogoutApi extends ApiClient {
  _NoopLogoutApi() : super(baseUrl: 'https://sync.example.test');

  @override
  Future<void> logout() async {}
}

class _RecordingSessionNotifier implements SessionUpdateNotifier {
  final StreamController<SessionUpdateEvent> _events =
      StreamController<SessionUpdateEvent>.broadcast();
  final List<SessionUpdateEvent> sent = [];

  @override
  Stream<SessionUpdateEvent> get updates => _events.stream;

  @override
  void signal(SessionUpdateEvent event) {
    sent.add(event);
    _events.add(event);
  }

  @override
  void dispose() => _events.close();
}
