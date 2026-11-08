// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverUrl = 'https://restore.example.test/tenant';
const _instanceId = '11111111-1111-4111-8111-111111111111';
const _serverSpaceId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late Map<String, String> storageValues;
  late ClientSecureStore secureStore;
  late ClientDatabase database;
  late AppController app;
  late List<InstanceInfo> instanceResponses;
  late List<String> requests;
  late List<_FakeInstanceApi> clients;
  late bool appDisposed;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() {
    storageValues = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      storageValues,
    );
    secureStore = ClientSecureStore(const FlutterSecureStorage());
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    instanceResponses = [];
    requests = [];
    clients = [];
    appDisposed = false;
    app = AppController(
      sodium: sodium,
      database: database,
      secureStore: secureStore,
      apiClientFactoryForTesting: (baseUrl) {
        final client = _FakeInstanceApi(
          baseUrl: baseUrl,
          instanceResponses: instanceResponses,
          requests: requests,
        );
        clients.add(client);
        return client;
      },
    );
  });

  tearDown(() async {
    if (!appDisposed) app.dispose();
    await database.close();
  });

  test(
    'same instance key rollback is isolated until exact out-of-band fingerprint confirmation',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));

      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );

      final pending = app.pendingInstanceIdentityRecovery!;
      expect(
        pending.pinnedIdentity.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(pending.candidate.signingPublicKey, restored.signingPublicKey);
      expect(app.api, isNull);
      expect(app.instance, isNull);
      expect(app.stage, ClientStage.server);
      expect(requests, ['instance']);

      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint: 'SHA256:wrong',
        ),
        throwsFormatException,
      );
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(app.pendingInstanceIdentityRecovery, same(pending));
      expect(requests, ['instance']);

      await app.cancelPendingInstanceIdentityRecovery();
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.single.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      final approvedCandidateFingerprint =
          app.pendingInstanceIdentityRecovery!.candidateFingerprint;

      await app.confirmPendingInstanceIdentityRecovery(
        candidateFingerprint: approvedCandidateFingerprint,
      );

      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(app.api, same(clients.last));
      expect(app.instance?.signingPublicKey, restored.signingPublicKey);
      expect(app.serverUrl, _serverUrl);
      expect(app.stage, ClientStage.login);
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(requests, ['instance', 'instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));
      expect(
        storageValues.keys.where((key) => key.contains('.device.')),
        isEmpty,
      );
      expect(
        storageValues.keys.where((key) => key.contains('.session.')),
        isEmpty,
      );
    },
  );

  test(
    'startup preserves the identity mismatch and exposes its candidate',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      await secureStore.saveLastServer(_serverUrl);
      instanceResponses.add(_instance(restored.signingPublicKey));

      await app.restoreLastServer();

      expect(app.pendingInstanceIdentityRecovery, isNotNull);
      expect(app.errorMessage, contains('separate trusted channel'));
      expect(app.errorMessage, isNot(contains('Couldn\'t read local security settings. Check browser storage and try again.')));
      expect(app.api, isNull);
      expect(requests, ['instance']);
    },
  );

  test('server identity pins persist per canonical URL namespace', () async {
    final oldKey = DeviceIdentity.create(sodium);
    final candidateKey = DeviceIdentity.create(sodium);
    addTearDown(oldKey.dispose);
    addTearDown(candidateKey.dispose);
    const anotherTenant = 'https://restore.example.test/other';
    await secureStore.saveServerIdentityPin(
      _serverUrl,
      _pin(oldKey.signingPublicKey),
    );

    final reloadedStore = ClientSecureStore(const FlutterSecureStorage());
    expect(
      (await reloadedStore.readServerIdentityPin(
        'HTTPS://RESTORE.EXAMPLE.TEST:443/tenant/',
      ))?.signingPublicKey,
      oldKey.signingPublicKey,
    );
    expect(await reloadedStore.readServerIdentityPin(anotherTenant), isNull);

    await reloadedStore.saveServerIdentityPin(
      _serverUrl,
      _pin(candidateKey.signingPublicKey),
    );
    expect(
      (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
      candidateKey.signingPublicKey,
    );
    expect(await reloadedStore.readServerIdentityPin(anotherTenant), isNull);
  });

  test(
    'candidate change during confirmation keeps pin unchanged and review recoverable',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final reviewed = DeviceIdentity.create(sodium);
      final changed = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(reviewed.dispose);
      addTearDown(changed.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(reviewed.signingPublicKey));

      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      final recovery = app.pendingInstanceIdentityRecovery!;
      instanceResponses.add(_instance(changed.signingPublicKey));

      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint: recovery.candidateFingerprint,
        ),
        throwsStateError,
      );

      expect(app.pendingInstanceIdentityRecovery, same(recovery));
      expect(app.api, isNull);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));
    },
  );

  test(
    'confirmation is single-flight and blocks cancel or server changes',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      final client = clients.single;
      client.fetchGate = Completer<void>();

      final confirmation = app.confirmPendingInstanceIdentityRecovery(
        candidateFingerprint:
            app.pendingInstanceIdentityRecovery!.candidateFingerprint,
      );
      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint:
              app.pendingInstanceIdentityRecovery!.candidateFingerprint,
        ),
        throwsStateError,
      );
      await expectLater(
        app.cancelPendingInstanceIdentityRecovery(),
        throwsStateError,
      );
      await expectLater(app.configureServer(_serverUrl), throwsStateError);
      expect(requests, ['instance', 'instance']);

      client.fetchGate!.complete();
      await confirmation;
      expect(app.stage, ClientStage.login);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
    },
  );

  test('disposing controller closes its isolated candidate API', () async {
    final previous = DeviceIdentity.create(sodium);
    final restored = DeviceIdentity.create(sodium);
    addTearDown(previous.dispose);
    addTearDown(restored.dispose);
    await secureStore.saveServerIdentityPin(
      _serverUrl,
      _pin(previous.signingPublicKey),
    );
    instanceResponses.add(_instance(restored.signingPublicKey));
    await expectLater(
      app.configureServer(_serverUrl),
      throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
    );

    final pending = app.pendingInstanceIdentityRecovery;
    app.dispose();
    appDisposed = true;

    expect(pending, isNotNull);
    expect(clients.single.closed, isTrue);
    expect(app.pendingInstanceIdentityRecovery, isNull);
    expect(
      (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
      previous.signingPublicKey,
    );
  });

  test(
    'different instance or server-space IDs never offer key repinning',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final candidate = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(candidate.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(
        _instance(
          candidate.signingPublicKey,
          instanceId: '33333333-3333-4333-8333-333333333333',
        ),
      );

      await expectLater(app.configureServer(_serverUrl), throwsFormatException);

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.single.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      const differentSpaceUrl = 'https://restore.example.test/space-mismatch';
      await secureStore.saveServerIdentityPin(
        differentSpaceUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(
        _instance(
          candidate.signingPublicKey,
          serverSpaceId: '33333333-3333-4333-8333-333333333333',
        ),
      );
      await expectLater(
        app.configureServer(differentSpaceUrl),
        throwsFormatException,
      );

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.last.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(
          differentSpaceUrl,
        ))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
    },
  );

  test(
    'valid old-key transition still updates pin without a confirmation prompt',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final intermediate = DeviceIdentity.create(sodium);
      final current = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(intermediate.dispose);
      addTearDown(current.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      final first = _transition(
        sodium,
        previous,
        intermediate.signingPublicKey,
      );
      final second = _transition(
        sodium,
        intermediate,
        current.signingPublicKey,
        fromPublicKey: intermediate.signingPublicKey,
      );
      instanceResponses.add(
        _instance(current.signingPublicKey, transitions: [first, second]),
      );

      await app.configureServer(_serverUrl);

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(app.stage, ClientStage.login);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        current.signingPublicKey,
      );
      expect(requests, ['instance']);
    },
  );

  testWidgets(
    'recovery review is accessible, cancel preserves the pin, confirmation proceeds to login without auth',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AnimatedBuilder(
            animation: app,
            builder: (context, _) => AuthFlow(controller: app),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstReview = app.pendingInstanceIdentityRecovery!;
      expect(
        find.text('Restored server identity needs confirmation'),
        findsOneWidget,
      );
      expect(
        find.text('Previously trusted fingerprint · SHA-256'),
        findsOneWidget,
      );
      expect(
        find.text('Fingerprint returned by this server · SHA-256'),
        findsOneWidget,
      );
      expect(find.text(firstReview.pinnedFingerprint), findsOneWidget);
      expect(find.text(firstReview.candidateFingerprint), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNull,
      );

      await tester.ensureVisible(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      instanceResponses.add(_instance(restored.signingPublicKey));
      await tester.enterText(_textFieldWithLabel('Server URL'), _serverUrl);
      await tester.tap(find.text('Connect securely'));
      await tester.pumpAndSettle();
      instanceResponses.add(_instance(restored.signingPublicKey));
      final secondReview = app.pendingInstanceIdentityRecovery!;
      final fingerprintField = _textFieldWithLabel(
        'Type the candidate fingerprint exactly',
      );
      await tester.enterText(
        fingerprintField,
        ' ${secondReview.candidateFingerprint} ',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        fingerprintField,
        secondReview.candidateFingerprint,
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm_instance_identity_recovery')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm_instance_identity_recovery')),
      );
      await tester.pumpAndSettle();

      expect(app.stage, ClientStage.login);
      expect(find.text('Email or username'), findsOneWidget);
      expect(
        find.text('Restored server identity needs confirmation'),
        findsNothing,
      );
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(requests, ['instance', 'instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    },
  );
}

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labeled "$label"',
);

ServerIdentityPin _pin(String publicKey) => ServerIdentityPin(
  instanceId: _instanceId,
  serverSpaceId: _serverSpaceId,
  signingPublicKey: publicKey,
);

InstanceInfo _instance(
  String signingPublicKey, {
  String instanceId = _instanceId,
  String serverSpaceId = _serverSpaceId,
  List<Map<String, dynamic>> transitions = const [],
}) => InstanceInfo(
  instanceId: instanceId,
  serverSpaceId: serverSpaceId,
  generation: '44444444-4444-4444-8444-444444444444',
  protocolVersion: 1,
  setupRequired: false,
  capabilities: const [],
  signingPublicKey: signingPublicKey,
  signingKeyTransitions: transitions,
);

Map<String, dynamic> _transition(
  SodiumSumo sodium,
  DeviceIdentity signer,
  String toPublicKey, {
  String? fromPublicKey,
}) {
  final unsigned = <String, Object?>{
    'format': 'atermius-instance-key-transition-v1',
    'instance_id': _instanceId,
    'from_public_key': fromPublicKey ?? signer.signingPublicKey,
    'to_public_key': toPublicKey,
    'issued_at': '2026-10-07T10:00:00Z',
  };
  return {
    ...unsigned,
    'signature': encodeBase64Url(
      sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: signer.signing.secretKey,
      ),
    ),
  };
}

class _FakeInstanceApi extends ApiClient {
  _FakeInstanceApi({
    required super.baseUrl,
    required this.instanceResponses,
    required this.requests,
  });

  final List<InstanceInfo> instanceResponses;
  final List<String> requests;
  bool closed = false;
  Completer<void>? fetchGate;

  @override
  Future<InstanceInfo> fetchInstance() async {
    requests.add('instance');
    await fetchGate?.future;
    return instanceResponses.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    requests.add('prelogin');
    throw StateError('unexpected authenticated-path request');
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
