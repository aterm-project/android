import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/auth/session_startup.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _hint = SessionResumeHint(
  username: 'alice',
  accountId: 'account-a',
  deviceId: 'device-a',
);
SessionCredentials _credentials({
  bool expired = false,
  String account = 'account-a',
}) => SessionCredentials(
  accountId: account,
  deviceId: 'device-a',
  accessToken: 'stored-access',
  refreshToken: 'stored-refresh',
  accessExpiresAt: DateTime.now().toUtc().add(
    Duration(minutes: expired ? -2 : 10),
  ),
);

class _Store extends ClientSecureStore {
  SessionResumeHint? hint = _hint;
  late SessionSnapshotRead snapshot;
  int pendingWrites = 0;
  int readyWrites = 0;
  @override
  Future<String?> lastServer() async => 'https://example.test/tenant';
  @override
  Future<SessionResumeHint?> sessionResumeHint(String base) async => hint;
  @override
  Future<SessionSnapshotRead> readSessionSnapshot(
    String base,
    String username,
    String device,
  ) async {
    expect(username, 'alice');
    expect(device, 'device-a');
    return snapshot;
  }

  @override
  Future<void> markSessionRotationPending(
    String base,
    String username,
    SessionScope scope,
  ) async {
    pendingWrites++;
    snapshot = const SessionSnapshotRead.rotationPending();
  }

  @override
  Future<void> saveSessionCredentials(
    String base,
    String username,
    SessionCredentials value,
  ) async {
    readyWrites++;
    snapshot = SessionSnapshotRead.ready(value);
  }

  @override
  Future<void> clearSessionResumeHint(
    String base, {
    String? accountId,
    String? deviceId,
  }) async {
    hint = null;
  }

  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String base,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async {
    snapshot = const SessionSnapshotRead.missing();
    return true;
  }
}

class _Lock implements SessionRefreshLock {
  Future<void>? _tail;
  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}

class _Notifier implements SessionUpdateNotifier {
  @override
  Stream<SessionUpdateEvent> get updates => const Stream.empty();
  @override
  void signal(SessionUpdateEvent event) {}
  @override
  void dispose() {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test/tenant');
  int profiles = 0;
  int refreshes = 0;
  bool rejected = false;
  bool wrongAccount = false;
  Completer<void>? profileGate;
  @override
  Future<AccountProfile> accountProfile() async {
    profiles++;
    await profileGate?.future;
    if (rejected) {
      throw const ApiException(
        statusCode: 401,
        code: 'AUTH_REQUIRED',
        message: 'private token detail',
        details: {},
      );
    }
    return AccountProfile(
      accountId: wrongAccount ? 'another-account' : 'account-a',
      deviceId: 'device-a',
      accountKeyEnvelopeVersion: 1,
      accountKeyEnvelope: const {},
    );
  }

  @override
  Future<AuthSession> refresh(String token) async {
    refreshes++;
    expect(token, 'stored-refresh');
    if (rejected) {
      throw const ApiException(
        statusCode: 401,
        code: 'AUTH_REQUIRED',
        message: 'private token detail',
        details: {},
      );
    }
    return const AuthSession(
      accountId: 'account-a',
      deviceId: 'device-a',
      accessToken: 'rotated-access',
      refreshToken: 'rotated-refresh',
      expiresIn: 900,
      vaults: [],
    );
  }

  @override
  Future<void> logout() async {}
}

class _Controller extends AppController {
  _Controller({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required this.client,
  }) : super(
         sessionRefreshLockForTesting: _Lock(),
         sessionUpdateNotifierForTesting: _Notifier(),
       );
  final _Api client;
  @override
  Future<void> configureServer(String value, {bool showBusy = true}) async {
    // Instance pin verification is separately covered by instance identity
    // tests; here the activation boundary is already trusted.
    api = client;
    serverUrl = value;
    stage = ClientStage.login;
  }
}

class _ModeStore implements WorkspaceModeStore {
  WorkspaceMode value = WorkspaceMode.local;
  @override
  Future<WorkspaceMode?> read() async => value;
  @override
  Future<void> write(WorkspaceMode value) async {
    this.value = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late ClientDatabase database;
  late _Store store;
  late _Api api;
  late _Controller controller;
  setUpAll(() async => sodium = await SodiumSumoInit.init());
  setUp(() {
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    store = _Store()..snapshot = SessionSnapshotRead.ready(_credentials());
    api = _Api();
    controller = _Controller(
      sodium: sodium,
      database: database,
      secureStore: store,
      client: api,
    );
  });
  tearDown(() async {
    await controller.closeWorkspace();
  });

  test(
    'restores validated session to locked workspace without device or vault keys',
    () async {
      await controller.restoreLastServer();
      expect(controller.stage, ClientStage.workspace);
      expect(controller.workspaceLocked, isTrue);
      expect(controller.authenticatedUsername, 'alice');
      expect(controller.session?.accessToken, 'stored-access');
      expect(controller.identity, isNull);
      expect(controller.account, isNull);
      expect(controller.hosts, isEmpty);
      expect(api.profiles, 1);
      expect(api.refreshes, 0);
      expect(store.pendingWrites, 0);
    },
  );
  test(
    'expired access rotates the persisted snapshot before restoring',
    () async {
      store.snapshot = SessionSnapshotRead.ready(_credentials(expired: true));
      await controller.restoreLastServer();
      expect(controller.workspaceLocked, isTrue);
      expect(controller.session?.accessToken, 'rotated-access');
      expect(api.refreshes, 1);
      expect(store.pendingWrites, 1);
      expect(store.readyWrites, 1);
    },
  );
  test(
    'revoked refresh leaves normal login and no secret error disclosure',
    () async {
      store.snapshot = SessionSnapshotRead.ready(_credentials(expired: true));
      api.rejected = true;
      await controller.restoreLastServer();
      expect(controller.stage, ClientStage.login);
      expect(controller.session, isNull);
      expect(controller.workspaceLocked, isFalse);
      expect(api.accessToken, isNull);
      expect(controller.noticeMessage, isNot(contains('private token')));
      expect(store.snapshot.status, SessionSnapshotStatus.rotationPending);
    },
  );
  for (final status in [
    const SessionSnapshotRead.missing(),
    const SessionSnapshotRead.invalid(),
    const SessionSnapshotRead.rotationPending(),
  ]) {
    test(
      'non-ready snapshot ${status.status} cannot authorize refresh or restore',
      () async {
        store.snapshot = status;
        await controller.restoreLastServer();
        expect(controller.stage, ClientStage.login);
        expect(controller.session, isNull);
        expect(api.refreshes, 0);
        expect(api.profiles, 0);
      },
    );
  }
  test(
    'snapshot account mismatch and live account mismatch fail closed',
    () async {
      store.snapshot = SessionSnapshotRead.ready(
        _credentials(account: 'other'),
      );
      await controller.restoreLastServer();
      expect(controller.session, isNull);
      expect(api.profiles, 0);
      store.snapshot = SessionSnapshotRead.ready(_credentials());
      api.wrongAccount = true;
      await controller.restoreLastServer();
      expect(controller.session, isNull);
      expect(api.accessToken, isNull);
    },
  );
  test(
    'logout during live startup validation cannot resurrect the session',
    () async {
      api.profileGate = Completer<void>();
      final restoring = controller.restoreLastServer();
      while (api.profiles == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.logout();
      api.profileGate!.complete();
      await restoring;
      expect(controller.session, isNull);
      expect(controller.stage, ClientStage.login);
      expect(store.hint, isNull);
    },
  );
  testWidgets(
    'switching remembered local mode to server resumes the locked session without chooser',
    (tester) async {
      final mode = _ModeStore();
      await tester.pumpWidget(
        AtermiusApp(
          modeStore: mode,
          enableProfileModeSelection: true,
          crypto: VaultCrypto(sodium),
          localProfileCatalogInitializer: () async =>
              LocalProfileCatalog.forTesting(NativeDatabase.memory()),
          serverInitializer: () async => controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(api.profiles, 0);
      await tester.tap(find.byTooltip('Host menu · click to open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_profile_preferences_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace_mode_switch')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a workspace'), findsNothing);
      expect(
        controller.workspaceLocked,
        isTrue,
        reason:
            'stage=${controller.stage} profiles=${api.profiles} notice=${controller.noticeMessage} error=${controller.errorMessage}',
      );
      expect(find.text('Workspace locked'), findsOneWidget);
      expect(mode.value, WorkspaceMode.server);
      expect(controller.identity, isNull);
      expect(controller.workspaceLocked, isTrue);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Unlock workspace'));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => controller.closeWorkspace());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
