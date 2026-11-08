import 'dart:async';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('server onboarding presents the secure endpoint form', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AuthFlow(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connect to your server'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Connect securely'), findsOneWidget);
    expect(
      find.text(
        'Remote servers require HTTPS. HTTP is allowed only for localhost, 127.0.0.1 or ::1 development.',
      ),
      findsOneWidget,
    );

    controller.dispose();
    await database.close();
  });

  testWidgets('remote HTTP server URL fails with an actionable error', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AuthFlow(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'http://192.168.1.20:8080',
    );
    final connect = find.widgetWithText(FilledButton, 'Connect securely');
    await tester.ensureVisible(connect);
    await tester.tap(connect);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Remote server URLs must use HTTPS'),
      findsWidgets,
    );
    expect(controller.api, isNull);
    expect(controller.stage, ClientStage.server);

    controller.dispose();
    await database.close();
  });

  test(
    'early login update signal cannot clear a new in-memory session',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final notifier = _RecordingSessionNotifier();
      final api = ApiClient(baseUrl: 'https://sync.example.test');
      final controller = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        sessionUpdateNotifierForTesting: notifier,
      )..api = api;
      const loggedIn = AuthSession(
        accountId: 'account-1',
        accessToken: 'access-1',
        expiresIn: 900,
        refreshToken: 'refresh-1',
        deviceId: 'device-1',
        vaults: [],
      );
      // This models the short login/register interval after the API returned and
      // set session, before authenticatedUsername is assigned. The old native
      // notifier echoed its own signal in this window; a missing storage read
      // must never interpret that as logout.
      controller
        ..session = loggedIn
        ..stage = ClientStage.workspace;

      notifier.signal(
        const SessionUpdateEvent(
          scope: SessionScope(
            serverNamespace: 'https://sync.example.test',
            accountId: 'account-1',
            deviceId: 'device-1',
          ),
          kind: SessionUpdateKind.updated,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.session, same(loggedIn));
      expect(controller.stage, ClientStage.workspace);

      controller.dispose();
      api.close();
      await database.close();
    },
  );

  test(
    'old logout cannot broadcast removal after a newer snapshot wins',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final notifier = _RecordingSessionNotifier();
      final api = _NoopLogoutApi();
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _LogoutSnapshotStore(result: false),
              sessionUpdateNotifierForTesting: notifier,
            )
            ..api = api
            ..session = const AuthSession(
              accountId: 'account-1',
              accessToken: 'old-access',
              expiresIn: 900,
              refreshToken: 'old-refresh',
              deviceId: 'device-1',
              vaults: [],
            )
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace;

      await controller.logout();

      expect(controller.session, isNull);
      expect(notifier.sent.map((event) => event.kind), isEmpty);
      controller.dispose();
      notifier.dispose();
      api.close();
      await database.close();
    },
  );

  test(
    'confirmed logout still broadcasts when local deletion throws',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final notifier = _RecordingSessionNotifier();
      final api = _NoopLogoutApi();
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: _LogoutSnapshotStore(throwOnDelete: true),
              sessionUpdateNotifierForTesting: notifier,
            )
            ..api = api
            ..session = const AuthSession(
              accountId: 'account-1',
              accessToken: 'access-1',
              expiresIn: 900,
              refreshToken: 'refresh-1',
              deviceId: 'device-1',
              vaults: [],
            )
            ..authenticatedUsernameForTesting = 'alice'
            ..stage = ClientStage.workspace;

      await controller.logout();

      expect(notifier.sent.map((event) => event.kind), [
        SessionUpdateKind.removed,
      ]);
      controller.dispose();
      notifier.dispose();
      api.close();
      await database.close();
    },
  );
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

class _LogoutSnapshotStore extends ClientSecureStore {
  _LogoutSnapshotStore({this.result = true, this.throwOnDelete = false});

  final bool result;
  final bool throwOnDelete;

  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async {
    if (throwOnDelete) throw StateError('secure storage unavailable');
    return result;
  }
}

class _NoopLogoutApi extends ApiClient {
  _NoopLogoutApi() : super(baseUrl: 'https://sync.example.test');

  @override
  Future<void> logout() async {}
}
