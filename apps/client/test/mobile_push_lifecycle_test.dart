import 'support/settings_navigation.dart';

import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/mobile_push/mobile_push_registration.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _apnsToken = '0123456789abcdef0123456789abcdef';
const _nextApnsToken = 'fedcba9876543210fedcba9876543210';
const _fcmToken = 'fcm-token-0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'iOS prefers APNs and removes the previous provider after refresh',
    () async {
      final harness = await _Harness.create(sodium);
      harness.registration.requested = const MobilePushToken(
        provider: MobilePushToken.apnsProvider,
        value: _apnsToken,
      );
      try {
        await harness.app.setMobilePushEnabled(true);

        expect(harness.registration.permissionRequests, 1);
        expect(harness.api.registered.map((item) => item.provider), ['apns']);
        expect(harness.api.registered.single.token, _apnsToken);
        expect(harness.api.registered.single.deviceId, harness.deviceId);
        expect(harness.registration.fallbackRequests, 0);
        expect(harness.api.removedProviders, ['fcm_v1']);
        expect(harness.store.optIns, {harness.optInKey: true});
        expect(harness.app.mobilePushEnabled, isTrue);

        harness.registration.addRefresh(
          const MobilePushToken(
            provider: MobilePushToken.apnsProvider,
            value: _nextApnsToken,
          ),
        );
        await pumpEventQueue();
        expect(harness.api.registered.last.token, _nextApnsToken);
        expect(harness.api.registered.last.provider, 'apns');
        expect(harness.api.removedProviders.last, 'fcm_v1');

        final requestCount = harness.api.registered.length;
        await harness.app.setMobilePushEnabled(false);
        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.optIns, {harness.optInKey: false});
        expect(
          harness.api.removedProviders.sublist(
            harness.api.removedProviders.length - 2,
          ),
          ['apns', 'fcm_v1'],
        );
        harness.registration.addRefresh(
          const MobilePushToken(
            provider: MobilePushToken.apnsProvider,
            value: _apnsToken,
          ),
        );
        await pumpEventQueue();
        expect(harness.api.registered, hasLength(requestCount));
      } finally {
        await harness.dispose();
      }
    },
  );

  test('iOS falls back to FCM only when APNs delivery is disabled', () async {
    final harness = await _Harness.create(sodium);
    harness.registration.requested = const MobilePushToken(
      provider: MobilePushToken.apnsProvider,
      value: _apnsToken,
    );
    harness.registration.fallbackToken = _fcmToken;
    harness.api.disabledProviders.add('apns');
    try {
      await harness.app.setMobilePushEnabled(true);

      expect(harness.api.registered.map((item) => item.provider), [
        'apns',
        'fcm_v1',
      ]);
      expect(harness.api.registered.last.token, _fcmToken);
      expect(harness.registration.fallbackRequests, 1);
      expect(harness.api.removedProviders, ['apns']);
      expect(harness.store.optIns, {harness.optInKey: true});
    } finally {
      await harness.dispose();
    }
  });

  test(
    'other APNs errors do not trigger FCM fallback and leave opt-in off',
    () async {
      final harness = await _Harness.create(sodium);
      harness.registration.requested = const MobilePushToken(
        provider: MobilePushToken.apnsProvider,
        value: _apnsToken,
      );
      harness.registration.fallbackToken = _fcmToken;
      harness.api.apnsError = const ApiException(
        statusCode: 409,
        code: 'PUSH_ENDPOINT_IN_USE',
        message: 'endpoint already registered',
      );
      try {
        await expectLater(
          harness.app.setMobilePushEnabled(true),
          throwsA(isA<ApiException>()),
        );
        expect(harness.registration.fallbackRequests, 0);
        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.optIns, {harness.optInKey: false});
        expect(harness.api.removedProviders, ['apns', 'fcm_v1']);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'logout removes both possible providers and clears the local opt-in',
    () async {
      final harness = await _Harness.create(sodium);
      harness.registration.requested = const MobilePushToken(
        provider: MobilePushToken.apnsProvider,
        value: _apnsToken,
      );
      try {
        await harness.app.setMobilePushEnabled(true);
        final optInKey = harness.optInKey;
        harness.api.removedProviders.clear();

        await harness.app.logout();

        expect(harness.api.removedProviders, ['apns', 'fcm_v1']);
        expect(harness.api.logoutCalled, isTrue);
        expect(harness.store.optIns, {optInKey: false});
        expect(harness.app.mobilePushEnabled, isFalse);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'logout keeps failed cleanup pending for the next authenticated restore',
    () async {
      final harness = await _Harness.create(sodium);
      try {
        await harness.app.setMobilePushEnabled(true);
        harness.api.removedProviders.clear();
        harness.api.failRemoveProviders.add('apns');
        final deviceId = harness.deviceId;
        final optInKey = harness.optInKey;

        await harness.app.logout();

        expect(harness.api.logoutCalled, isTrue);
        expect(harness.store.optIns[optInKey], isFalse);
        expect(harness.store.cleanupPendings[optInKey], isTrue);
        expect(harness.api.removedProviders, ['fcm_v1']);

        final replacementKeys = DeviceIdentity.create(sodium);
        harness.app
          ..identity = DeviceIdentity(
            deviceId: deviceId,
            signing: replacementKeys.signing,
            encryption: replacementKeys.encryption,
          )
          ..session = AuthSession(
            accountId: _accountId,
            accessToken: 'restored-access-token',
            expiresIn: 900,
            refreshToken: 'restored-refresh-token',
            deviceId: deviceId,
            vaults: const [],
          )
          ..stage = ClientStage.workspace;
        harness.api.accessToken = 'restored-access-token';
        harness.api.failRemoveProviders.clear();

        await harness.app.restoreMobilePushRegistrationForTesting();

        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.cleanupPendings[optInKey], isFalse);
        expect(harness.registration.permissionRequests, 1);
        expect(
          harness.api.removalCalls
              .where((call) => call.accessToken == 'restored-access-token')
              .map((call) => call.provider),
          ['apns', 'fcm_v1'],
        );
      } finally {
        await harness.dispose();
      }
    },
  );

  test('stale logout cannot remove or clear a replacement session', () async {
    final harness = await _Harness.create(sodium);
    final deletionGate = Completer<void>();
    final deletionStarted = Completer<void>();
    try {
      await harness.app.setMobilePushEnabled(true);
      final deviceId = harness.deviceId;
      final previousSession = harness.app.session!;
      harness.api
        ..blockNextRemovalProvider = 'apns'
        ..blockedRemoval = deletionGate
        ..removalStarted = deletionStarted;

      final logout = harness.app.logout();
      await deletionStarted.future;
      expect(harness.api.removalCalls.last, (
        accessToken: 'access-token',
        deviceId: deviceId,
        provider: 'apns',
      ));

      harness.app.session = AuthSession(
        accountId: previousSession.accountId,
        accessToken: 'replacement-access-token',
        expiresIn: 900,
        refreshToken: 'replacement-refresh-token',
        deviceId: deviceId,
        vaults: const [],
      );
      harness.api.accessToken = 'replacement-access-token';
      await harness.app.setMobilePushEnabled(true);
      expect(harness.app.mobilePushEnabled, isTrue);
      expect(harness.registration.messages.hasListener, isTrue);

      deletionGate.complete();
      await logout;

      expect(harness.api.logoutCalled, isFalse);
      expect(harness.api.accessToken, 'replacement-access-token');
      expect(harness.app.mobilePushEnabled, isTrue);
      expect(harness.app.mobilePushBusy, isFalse);
      expect(harness.registration.messages.hasListener, isTrue);
      expect(harness.store.optIns[harness.optInKey], isTrue);
      expect(
        harness.api.removalCalls
            .where((call) => call.accessToken == 'replacement-access-token')
            .map((call) => call.provider),
        ['apns'],
      );
    } finally {
      if (!deletionGate.isCompleted) deletionGate.complete();
      await harness.dispose();
    }
  });

  test(
    'failed opt-out endpoint cleanup retries from durable pending state',
    () async {
      final harness = await _Harness.create(sodium);
      try {
        await harness.app.setMobilePushEnabled(true);
        harness.api.failRemoveProviders.add('apns');

        await expectLater(
          harness.app.setMobilePushEnabled(false),
          throwsA(isA<StateError>()),
        );

        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.optIns[harness.optInKey], isFalse);
        expect(harness.store.cleanupPendings[harness.optInKey], isTrue);
        expect(
          harness.api.removalCalls
              .sublist(harness.api.removalCalls.length - 2)
              .map((call) => call.provider),
          ['apns', 'fcm_v1'],
        );

        harness.api.failRemoveProviders.clear();
        await harness.app.restoreMobilePushRegistrationForTesting();

        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.cleanupPendings[harness.optInKey], isFalse);
        expect(harness.registration.messages.hasListener, isFalse);
        expect(harness.api.registered, hasLength(1));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'restore denied by OS revokes both providers without prompting',
    () async {
      final harness = await _Harness.create(sodium);
      harness.store.optIns[harness.optInKey] = true;
      harness.registration.authorizationStatus =
          MobilePushAuthorizationStatus.denied;
      try {
        await harness.app.restoreMobilePushRegistrationForTesting();

        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.optIns[harness.optInKey], isFalse);
        expect(harness.store.cleanupPendings[harness.optInKey], isFalse);
        expect(harness.api.removedProviders, ['apns', 'fcm_v1']);
        expect(harness.registration.permissionRequests, 0);
        expect(harness.registration.messages.hasListener, isFalse);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'resume reconciles revoked authorization without prompting again',
    () async {
      final harness = await _Harness.create(sodium);
      try {
        await harness.app.setMobilePushEnabled(true);
        expect(harness.registration.messages.hasListener, isTrue);
        harness.registration.authorizationStatus =
            MobilePushAuthorizationStatus.denied;

        await harness.app.onForegroundResumed();

        expect(harness.app.mobilePushEnabled, isFalse);
        expect(harness.store.optIns[harness.optInKey], isFalse);
        expect(harness.store.cleanupPendings[harness.optInKey], isFalse);
        expect(
          harness.api.removalCalls
              .where((call) => call.accessToken == 'access-token')
              .map((call) => call.provider),
          containsAll(['apns', 'fcm_v1']),
        );
        expect(harness.registration.permissionRequests, 1);
        expect(harness.registration.messages.hasListener, isFalse);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('token refresh after authorization revoke removes endpoints', () async {
    final harness = await _Harness.create(sodium);
    try {
      await harness.app.setMobilePushEnabled(true);
      final registeredBeforeRevoke = harness.api.registered.length;
      harness.registration.authorizationStatus =
          MobilePushAuthorizationStatus.denied;

      harness.registration.addRefresh(
        const MobilePushToken(
          provider: MobilePushToken.fcmProvider,
          value: _fcmToken,
        ),
      );
      await pumpEventQueue();

      expect(harness.api.registered, hasLength(registeredBeforeRevoke));
      expect(harness.app.mobilePushEnabled, isFalse);
      expect(harness.store.cleanupPendings[harness.optInKey], isFalse);
      expect(harness.registration.permissionRequests, 1);
      expect(harness.registration.messages.hasListener, isFalse);
      expect(
        harness.api.removalCalls
            .where((call) => call.accessToken == 'access-token')
            .map((call) => call.provider),
        containsAll(['apns', 'fcm_v1']),
      );
    } finally {
      await harness.dispose();
    }
  });

  test('unknown authorization preserves opt-in and active listeners', () async {
    final harness = await _Harness.create(sodium);
    try {
      await harness.app.setMobilePushEnabled(true);
      final registeredBeforeRefresh = harness.api.registered.length;
      harness.registration.throwAuthorizationStatus = true;

      harness.registration.addRefresh(
        const MobilePushToken(
          provider: MobilePushToken.fcmProvider,
          value: _fcmToken,
        ),
      );
      await pumpEventQueue();

      expect(harness.app.mobilePushEnabled, isTrue);
      expect(harness.store.optIns[harness.optInKey], isTrue);
      expect(harness.registration.messages.hasListener, isTrue);
      expect(harness.api.registered, hasLength(registeredBeforeRefresh));
      expect(harness.api.removalCalls, hasLength(1));
    } finally {
      await harness.dispose();
    }
  });

  test(
    'late permission result after logout cannot clear the next session',
    () async {
      final harness = await _Harness.create(sodium);
      final oldPermission = Completer<MobilePushToken?>();
      harness.registration.pendingPermission = oldPermission;
      final oldOptIn = harness.app.setMobilePushEnabled(true);
      try {
        await pumpEventQueue();
        final deviceId = harness.deviceId;
        await harness.app.logout();

        final replacementKeys = DeviceIdentity.create(sodium);
        harness.app
          ..identity = DeviceIdentity(
            deviceId: deviceId,
            signing: replacementKeys.signing,
            encryption: replacementKeys.encryption,
          )
          ..session = AuthSession(
            accountId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            accessToken: 'next-access-token',
            expiresIn: 900,
            refreshToken: 'next-refresh-token',
            deviceId: deviceId,
            vaults: const [],
          )
          ..stage = ClientStage.workspace;
        harness.api.accessToken = 'next-access-token';
        harness.registration.pendingPermission = null;
        await harness.app.restoreMobilePushRegistrationForTesting();
        await harness.app.setMobilePushEnabled(true);
        expect(harness.app.mobilePushEnabled, isTrue);
        expect(harness.registration.messages.hasListener, isTrue);

        final nextSessionRemovalCount = harness.api.removalCalls
            .where((call) => call.accessToken == 'next-access-token')
            .length;
        oldPermission.complete(
          const MobilePushToken(
            provider: MobilePushToken.fcmProvider,
            value: 'stale-session-provider-token-12345',
          ),
        );
        await oldOptIn;

        expect(harness.app.mobilePushEnabled, isTrue);
        expect(harness.app.mobilePushBusy, isFalse);
        expect(harness.registration.messages.hasListener, isTrue);
        expect(
          harness.store.optIns[harness.optInKeyFor(
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          )],
          isTrue,
        );
        expect(
          harness.api.removalCalls.where(
            (call) => call.accessToken == 'next-access-token',
          ),
          hasLength(nextSessionRemovalCount),
        );
        expect(harness.api.registered.last.token, _fcmToken);
      } finally {
        if (!oldPermission.isCompleted) {
          oldPermission.complete(null);
          await oldOptIn;
        }
        await harness.dispose();
      }
    },
  );

  test('old listener hints do not abort a newer opt-in attempt', () async {
    var syncCount = 0;
    final harness = await _Harness.create(
      sodium,
      mobilePushAutoSyncForTesting: () async => syncCount++,
    );
    try {
      await harness.app.setMobilePushEnabled(true);
      expect(harness.registration.messages.hasListener, isTrue);

      final permission = Completer<MobilePushToken?>();
      harness.registration.pendingPermission = permission;
      final reenable = harness.app.setMobilePushEnabled(true);
      harness.registration.addMessage({'type': 'sync_available'});
      await pumpEventQueue();

      permission.complete(
        const MobilePushToken(
          provider: MobilePushToken.fcmProvider,
          value: _fcmToken,
        ),
      );
      await reenable;

      expect(syncCount, 0);
      expect(harness.app.mobilePushEnabled, isTrue);
      expect(harness.store.optIns[harness.optInKey], isTrue);
      expect(harness.registration.messages.hasListener, isTrue);
    } finally {
      await harness.dispose();
    }
  });

  test(
    'foreground sync hints require the exact payload and coalesce',
    () async {
      final firstSync = Completer<void>();
      var syncCount = 0;
      final harness = await _Harness.create(
        sodium,
        mobilePushAutoSyncForTesting: () {
          syncCount++;
          if (syncCount == 1) return firstSync.future;
          return Future<void>.value();
        },
      );
      try {
        expect(harness.registration.messages.hasListener, isFalse);
        await harness.app.setMobilePushEnabled(true);
        expect(harness.registration.messages.hasListener, isTrue);

        for (final invalid in <Map<String, dynamic>>[
          {},
          {'type': 'SYNC_AVAILABLE'},
          {'type': 'other'},
          {'type': 'sync_available', 'message_id': 'secret-id'},
          {'type': 'sync_available', 'payload': 'ignored'},
        ]) {
          harness.registration.addMessage(invalid);
        }
        await pumpEventQueue();
        expect(syncCount, 0);

        harness.registration.addMessage({'type': 'sync_available'});
        await pumpEventQueue();
        expect(syncCount, 1);

        harness.registration.addMessage({'type': 'sync_available'});
        harness.registration.addMessage({'type': 'sync_available'});
        await pumpEventQueue();
        expect(syncCount, 1);

        firstSync.complete();
        await pumpEventQueue();
        expect(syncCount, 2);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('locked and opted-out clients ignore foreground sync hints', () async {
    var syncCount = 0;
    final harness = await _Harness.create(
      sodium,
      mobilePushAutoSyncForTesting: () async => syncCount++,
    );
    try {
      await harness.app.setMobilePushEnabled(true);
      harness.app.stage = ClientStage.login;
      harness.registration.addMessage({'type': 'sync_available'});
      await pumpEventQueue();
      expect(syncCount, 0);

      harness.app.stage = ClientStage.workspace;
      await harness.app.setMobilePushEnabled(false);
      expect(harness.registration.messages.hasListener, isFalse);
      harness.registration.addMessage({'type': 'sync_available'});
      await pumpEventQueue();
      expect(syncCount, 0);
    } finally {
      await harness.dispose();
    }
  });

  test('account switch invalidates an old push listener', () async {
    var syncCount = 0;
    final harness = await _Harness.create(
      sodium,
      mobilePushAutoSyncForTesting: () async => syncCount++,
    );
    try {
      await harness.app.setMobilePushEnabled(true);
      final oldSession = harness.app.session!;
      harness.app.session = AuthSession(
        accountId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        accessToken: 'other-access-token',
        expiresIn: 900,
        refreshToken: 'other-refresh-token',
        deviceId: oldSession.deviceId,
        vaults: const [],
      );
      harness.registration.addMessage({'type': 'sync_available'});
      await pumpEventQueue();
      expect(syncCount, 0);
      expect(harness.app.mobilePushEnabled, isFalse);
      expect(harness.registration.messages.hasListener, isFalse);
    } finally {
      await harness.dispose();
    }
  });

  test('device switch invalidates an old push listener', () async {
    var syncCount = 0;
    final harness = await _Harness.create(
      sodium,
      mobilePushAutoSyncForTesting: () async => syncCount++,
    );
    try {
      await harness.app.setMobilePushEnabled(true);
      final oldSession = harness.app.session!;
      harness.app.session = AuthSession(
        accountId: oldSession.accountId,
        accessToken: 'other-access-token',
        expiresIn: 900,
        refreshToken: 'other-refresh-token',
        deviceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        vaults: const [],
      );
      harness.registration.addMessage({'type': 'sync_available'});
      await pumpEventQueue();
      expect(syncCount, 0);
      expect(harness.app.mobilePushEnabled, isFalse);
      expect(harness.registration.messages.hasListener, isFalse);
    } finally {
      await harness.dispose();
    }
  });

  test('controller disposal cancels the foreground message listener', () async {
    final harness = await _Harness.create(sodium);
    try {
      await harness.app.setMobilePushEnabled(true);
      expect(harness.registration.messages.hasListener, isTrue);

      harness.app.dispose();
      await pumpEventQueue();
      expect(harness.registration.messages.hasListener, isFalse);
    } finally {
      await harness.dispose(disposeApp: false);
    }
  });

  testWidgets(
    'Settings makes FCM unavailable explicit and prompts only on opt-in',
    (tester) async {
      final harness = await _Harness.create(sodium);
      harness.registration.configured = false;
      try {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: harness.app),
          ),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('cloud_settings'))
            .evaluate()
            .isNotEmpty) {
          await openSettingsCategory(
            tester,
            'notifications',
            ifAvailable: true,
          );
        }
        await tester.pump();

        expect(find.text('Background sync notifications'), findsOneWidget);
        expect(
          find.textContaining('has no Firebase project configured'),
          findsOneWidget,
        );
        var tile = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('mobile_push_enabled')),
        );
        expect(tile.onChanged, isNull);
        expect(harness.registration.permissionRequests, 0);

        harness.registration.configured = true;
        harness.app.notifyListeners();
        await tester.pump();
        tile = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('mobile_push_enabled')),
        );
        expect(tile.onChanged, isNotNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('mobile_push_enabled')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('mobile_push_enabled')));
        await tester.pumpAndSettle();
        expect(harness.registration.permissionRequests, 1);
        expect(harness.app.mobilePushEnabled, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await harness.dispose();
      }
    },
  );
}

class _Harness {
  _Harness(this.app, this.api, this.store, this.registration, this.database);

  final AppController app;
  final _PushApi api;
  final _PushSecureStore store;
  final _FakeMobilePushRegistration registration;
  final ClientDatabase database;

  String get deviceId => app.identity!.deviceId;
  String optInKeyFor(String accountId) => '${api.baseUrl}|$accountId|$deviceId';
  String get optInKey => optInKeyFor(_accountId);

  static Future<_Harness> create(
    SodiumSumo sodium, {
    Future<void> Function()? mobilePushAutoSyncForTesting,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _PushApi();
    final store = _PushSecureStore();
    final registration = _FakeMobilePushRegistration();
    final identity = DeviceIdentity.create(sodium);
    final session = AuthSession(
      accountId: _accountId,
      accessToken: 'access-token',
      expiresIn: 900,
      refreshToken: 'refresh-token',
      deviceId: identity.deviceId,
      vaults: const [],
    );
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: store,
            mobilePushRegistrationForTesting: registration,
            mobilePushAutoSyncForTesting: mobilePushAutoSyncForTesting,
          )
          ..api = api
          ..session = session
          ..identity = identity
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..account = AccountProfile(
            accountId: _accountId,
            deviceId: identity.deviceId,
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
          );
    api.accessToken = 'access-token';
    return _Harness(app, api, store, registration, database);
  }

  Future<void> dispose({bool disposeApp = true}) async {
    if (disposeApp) app.dispose();
    await registration.dispose();
    api.close();
    await database.close();
  }
}

class _FakeMobilePushRegistration implements MobilePushRegistration {
  @override
  bool configured = true;
  MobilePushAuthorizationStatus authorizationStatus =
      MobilePushAuthorizationStatus.authorized;
  bool throwAuthorizationStatus = false;
  MobilePushToken? requested = const MobilePushToken(
    provider: MobilePushToken.fcmProvider,
    value: _fcmToken,
  );
  String? fallbackToken;
  int permissionRequests = 0;
  int fallbackRequests = 0;
  Completer<MobilePushToken?>? pendingPermission;
  final StreamController<MobilePushToken> _refreshes =
      StreamController<MobilePushToken>.broadcast();
  final StreamController<Map<String, dynamic>> messages =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<MobilePushToken> get refreshes => _refreshes.stream;

  void addRefresh(MobilePushToken token) => _refreshes.add(token);

  void addMessage(Map<String, dynamic> data) => messages.add(data);

  @override
  bool get supported => true;

  @override
  Future<String?> getFcmFallbackToken() async {
    fallbackRequests++;
    return fallbackToken;
  }

  @override
  Future<MobilePushToken?> getTokenIfAuthorized() async => requested;

  @override
  Future<MobilePushAuthorizationStatus>
  notificationAuthorizationStatus() async {
    if (throwAuthorizationStatus) throw StateError('authorization unavailable');
    return authorizationStatus;
  }

  @override
  Future<MobilePushToken?> requestPermissionAndGetToken() async {
    permissionRequests++;
    final pending = pendingPermission;
    if (pending != null) return pending.future;
    return requested;
  }

  @override
  Future<Stream<MobilePushToken>> tokenRefreshes() async => _refreshes.stream;

  @override
  Future<Stream<Map<String, dynamic>>> incomingMessages() async =>
      messages.stream;

  Future<void> dispose() async {
    await _refreshes.close();
    await messages.close();
  }
}

class _PushSecureStore extends ClientSecureStore {
  final Map<String, bool> optIns = {};
  final Map<String, bool> cleanupPendings = {};

  String _scope(String baseUrl, String accountId, String deviceId) =>
      '$baseUrl|$accountId|$deviceId';

  @override
  Future<bool> mobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) async => optIns[_scope(baseUrl, accountId, deviceId)] ?? false;

  @override
  Future<void> setMobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required bool enabled,
  }) async {
    optIns[_scope(baseUrl, accountId, deviceId)] = enabled;
  }

  @override
  Future<void> clearMobilePushEnabled({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) async {
    optIns.remove(_scope(baseUrl, accountId, deviceId));
  }

  @override
  Future<bool> mobilePushCleanupPending({
    required String baseUrl,
    required String accountId,
    required String deviceId,
  }) async => cleanupPendings[_scope(baseUrl, accountId, deviceId)] ?? false;

  @override
  Future<void> setMobilePushCleanupPending({
    required String baseUrl,
    required String accountId,
    required String deviceId,
    required bool pending,
  }) async {
    cleanupPendings[_scope(baseUrl, accountId, deviceId)] = pending;
  }

  @override
  Future<bool> deleteSessionCredentialsIfCurrent(
    String baseUrl,
    String username, {
    required String deviceId,
    required String expectedRefreshToken,
  }) async => true;
}

class _PushApi extends ApiClient {
  _PushApi()
    : super(
        baseUrl: 'https://push.example.test',
        client: MockClient((_) async => http.Response('{}', 200)),
      );

  final List<({String deviceId, String provider, String token})> registered =
      [];
  final List<String> removedProviders = [];
  final List<({String? accessToken, String deviceId, String provider})>
  removalCalls = [];
  final Set<String> failRemoveProviders = {};
  final Set<String> disabledProviders = {};
  String? blockNextRemovalProvider;
  Completer<void>? blockedRemoval;
  Completer<void>? removalStarted;
  ApiException? apnsError;
  bool logoutCalled = false;

  @override
  Future<MobilePushEndpointResult> registerMobilePushEndpoint({
    required String deviceId,
    required String provider,
    required String token,
  }) async {
    registered.add((deviceId: deviceId, provider: provider, token: token));
    final error = provider == MobilePushToken.apnsProvider ? apnsError : null;
    if (error != null) throw error;
    if (disabledProviders.contains(provider)) {
      throw const ApiException(
        statusCode: 503,
        code: 'PUSH_DELIVERY_DISABLED',
        message: 'provider disabled',
      );
    }
    return MobilePushEndpointResult(
      status: 'registered',
      deviceId: deviceId,
      provider: provider,
    );
  }

  @override
  Future<MobilePushEndpointResult> removeMobilePushEndpoint({
    required String deviceId,
    required String provider,
  }) async {
    removalCalls.add((
      accessToken: accessToken,
      deviceId: deviceId,
      provider: provider,
    ));
    if (blockNextRemovalProvider == provider) {
      blockNextRemovalProvider = null;
      final started = removalStarted;
      if (started != null && !started.isCompleted) started.complete();
      final gate = blockedRemoval;
      if (gate != null) await gate.future;
    }
    if (failRemoveProviders.contains(provider)) {
      throw const ApiException(
        statusCode: 503,
        code: 'TEMPORARY_FAILURE',
        message: 'temporary delete failure',
      );
    }
    removedProviders.add(provider);
    return MobilePushEndpointResult(
      status: 'removed',
      deviceId: deviceId,
      provider: provider,
    );
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
    accessToken = null;
  }
}
