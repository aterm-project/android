// Admin escrow flows against a scripted server that stores exactly what the
// spec's routes store: key setup with the recovery code, a user deposit, the
// viewer decrypting a real record envelope, a second admin unlocking with the
// recovery code, and the failure codes the UI localizes.
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/credential_visibility/credential_escrow_admin.dart';
import 'package:aterm_client/credential_visibility/credential_escrow_crypto.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_motion.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/credential_visibility/credential_visibility_admin_ui.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/credential_visibility_fixtures.dart';

const _password = 'correct horse battery staple';
const _secondAdminId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _hostId = '12121212-1212-4121-8121-121212121212';
const _credentialId = '13131313-1313-4131-8131-131313131313';

class _Admin {
  _Admin(this.app, this.accountId, this.params);
  final AppController app;
  final String accountId;
  final KdfParameters params;
}

class _EscrowServer {
  _EscrowServer(this.sodium, this.instance);

  final SodiumSumo sodium;
  final EscrowTestInstance instance;
  Map<String, dynamic>? key;
  Map<String, dynamic>? recoveryWrap;
  final Map<String, Map<String, dynamic>> wraps = {};
  final Map<String, KdfParameters> kdf = {};

  /// (vault_id, epoch) → deposit body plus depositor key.
  final Map<String, Map<String, dynamic>> envelopes = {};
  final List<Map<String, dynamic>> records = [];
  Map<String, dynamic>? vaultNameEnvelope;
  int recordReads = 0;

  ApiClient clientFor(String accountId) => ApiClient(
    baseUrl: 'https://escrow-admin.example.test',
    client: MockClient((request) => _handle(accountId, request)),
  )..accessToken = 'token-$accountId';

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code) => _json({
    'error': {'code': code, 'message': code, 'request_id': 'r'},
  }, status);

  Future<http.Response> _handle(String caller, http.Request request) async {
    final path = request.url.path;
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (path == '/api/v1/auth/prelogin') {
      final account = body['username'] == 'second@example.test'
          ? _secondAdminId
          : escrowAdminId;
      return _json({'account_id': account, 'kdf': kdf[account]!.toJson()});
    }
    if (path == '/api/v1/admin/credential-visibility') {
      return _json({
        'default_mode': 'private',
        'escrow_key': key,
        'caller_wrap': wraps[caller],
        'recovery_wrap': recoveryWrap,
        'counts': {'admin_visible': 1, 'private': 0, 'pending': 0},
      });
    }
    if (path == '/api/v1/admin/credential-escrow/key' &&
        request.method == 'POST') {
      if (key != null) return _error(409, 'CREDENTIAL_ESCROW_KEY_EXISTS');
      key = instance.descriptor(
        keyId: body['key_id'] as String,
        publicKey: decodeBase64Url(body['public_key'] as String),
      );
      wraps[caller] = Map<String, dynamic>.from(body['account_wrap'] as Map);
      recoveryWrap = Map<String, dynamic>.from(body['recovery_wrap'] as Map);
      return _json({'escrow_key': key}, 201);
    }
    if (path == '/api/v1/admin/credential-escrow/key/wrap') {
      if (key?['key_id'] != body['key_id']) {
        return _error(409, 'CREDENTIAL_ESCROW_KEY_MISMATCH');
      }
      wraps[caller] = Map<String, dynamic>.from(body['account_wrap'] as Map);
      return _json({'status': 'stored'});
    }
    if (path ==
        '/api/v1/admin/credential-escrow/accounts/$escrowUserId/vaults') {
      return _json({
        'account': {
          'user_id': escrowUserId,
          'username': 'alice@example.test',
          'mode': 'admin_visible',
        },
        'vaults': [
          {
            'vault_id': escrowVaultId,
            'role': 'owner',
            'owner_user_id': escrowUserId,
            'name_envelope': vaultNameEnvelope,
            'active_epoch': 1,
            'escrow': [
              for (final entry in envelopes.entries)
                if (entry.key.startsWith('$escrowVaultId:')) entry.value,
            ],
          },
        ],
      });
    }
    if (path ==
        '/api/v1/admin/credential-escrow/vaults/$escrowVaultId/records') {
      if (envelopes.isEmpty) {
        return _error(404, 'CREDENTIAL_ESCROW_NOT_AVAILABLE');
      }
      recordReads++;
      return _json({'records': records, 'next_after': null});
    }
    throw StateError('unexpected ${request.method} $path');
  }
}

void main() {
  late SodiumSumo sodium;
  late VaultCrypto crypto;
  late EscrowTestInstance instance;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
    instance = EscrowTestInstance(sodium);
  });

  Future<_Admin> admin(
    _EscrowServer server, {
    required String accountId,
    required String username,
    Uint8List? accountKey,
  }) async {
    final params = KdfParameters.defaults(sodium);
    server.kdf[accountId] = params;
    final key = accountKey ?? sodium.randombytes.buf(32);
    final envelope = await crypto.wrapAccountKey(
      password: _password,
      params: params,
      accountKey: key,
    );
    final identity = DeviceIdentity.create(sodium);
    final app =
        AppController(
            sodium: sodium,
            database: ClientDatabase.forTesting(NativeDatabase.memory()),
            secureStore: ClientSecureStore(),
          )
          ..api = server.clientFor(accountId)
          ..instance = InstanceInfo(
            instanceId: escrowInstanceId,
            serverSpaceId: escrowServerSpaceId,
            generation: '1',
            protocolVersion: 1,
            setupRequired: false,
            capabilities: const ['credential_visibility'],
            signingPublicKey: instance.signingPublicKey,
          )
          ..account = AccountProfile(
            accountId: accountId,
            deviceId: identity.deviceId,
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: Map<String, dynamic>.from(envelope),
            policy: const {'instance_admin': true},
          )
          ..identity = identity
          ..authenticatedUsernameForTesting = username;
    return _Admin(app, accountId, params);
  }

  test('key setup, deposit, viewer decrypts, second admin unlocks', () async {
    final server = _EscrowServer(sodium, instance);
    final first = await admin(
      server,
      accountId: escrowAdminId,
      username: 'root@example.test',
    );
    final escrowAdmin = CredentialEscrowAdmin(first.app);
    expect(escrowAdmin.available, isTrue);

    // A wrong password never reaches key generation.
    await expectLater(
      escrowAdmin.prepareEscrowKey('wrong password'),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'wrong_password',
        ),
      ),
    );

    final prepared = await escrowAdmin.prepareEscrowKey(_password);
    final recoveryCode = prepared.recoveryCode!;
    expect(recoveryCode, matches(RegExp(r'^([A-Z2-7]{4}-){7}[A-Z2-7]{4}$')));
    final verifiedKey = await escrowAdmin.uploadEscrowKey(prepared);
    expect(prepared.recoveryCode, isNull, reason: 'dropped after upload');
    expect(verifiedKey.keyId, prepared.keyId);
    // Creating a second key fails with the stable code.
    final again = await escrowAdmin.prepareEscrowKey(_password);
    await expectLater(
      escrowAdmin.uploadEscrowKey(again),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'key_exists',
        ),
      ),
    );

    // The user's device: deposits epoch 1 and writes a Host with a password.
    final userDevice = DeviceIdentity.create(sodium);
    final vaultKey = sodium.randombytes.buf(32);
    final deposit = buildEscrowDeposit(
      sodium,
      key: verifiedKey,
      identity: userDevice,
      instanceId: escrowInstanceId,
      vaultId: escrowVaultId,
      keyEpoch: 1,
      vaultKey: vaultKey,
    );
    server.envelopes['$escrowVaultId:1'] = {
      'key_epoch': 1,
      'sealed': deposit['sealed'],
      'signature': deposit['signature'],
      'depositor_device_id': userDevice.deviceId,
      'depositor_signing_public_key': userDevice.signingPublicKey,
    };
    server.vaultNameEnvelope = Map<String, dynamic>.from(
      await crypto.encryptVaultName(
        vaultId: escrowVaultId,
        vaultKey: vaultKey,
        name: 'Production',
      ),
    );
    Future<Map<String, dynamic>> record(Map<String, Object?> plaintext) async {
      final envelope = await crypto.encryptRecord(
        vaultKey: vaultKey,
        serverSpaceId: escrowServerSpaceId,
        vaultId: escrowVaultId,
        recordId: plaintext['id']! as String,
        baseRevisionId: null,
        deviceId: userDevice.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: plaintext,
        identity: userDevice,
      );
      final header = envelope['header']! as Map<String, Object?>;
      return {
        'record_id': plaintext['id'],
        'revision_id': header['revision_id'],
        'envelope': envelope,
        'author_device_id': userDevice.deviceId,
        'author_signing_public_key': userDevice.signingPublicKey,
      };
    }

    const host = HostRecord(
      id: _hostId,
      name: 'db-01',
      address: '10.0.0.5',
      port: 2222,
      username: 'ops',
      credentialId: _credentialId,
      login: HostLogin(kind: AuthKind.password, password: 'SENTINEL-PW'),
    );
    const credential = CredentialRecord(
      id: _credentialId,
      name: 'deploy key',
      username: 'deploy',
      kind: AuthKind.privateKey,
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nSENTINEL\n-----END OPENSSH PRIVATE KEY-----',
      passphrase: 'SENTINEL-PASS',
    );
    final records =
        [await record(host.toJson()), await record(credential.toJson())]..sort(
          (a, b) =>
              (a['record_id'] as String).compareTo(b['record_id'] as String),
        );
    server.records.addAll(records);

    final session = await escrowAdmin.openViewer(
      password: _password,
      targetUserId: escrowUserId,
    );
    final vaults = await session.loadVaults();
    expect(server.recordReads, 0, reason: 'listing vaults is not a view');
    expect(vaults.single.name, 'Production');
    expect(vaults.single.openedEpochs, [1]);
    expect(vaults.single.failedEpochs, isEmpty);
    final items = await session.loadItems(escrowVaultId);
    expect(server.recordReads, 1);
    expect(items.undecryptable, 0);
    expect(items.hosts.single.login!.password, 'SENTINEL-PW');
    expect(items.hosts.single.port, 2222);
    expect(items.credentials.single.passphrase, 'SENTINEL-PASS');
    session.dispose();
    expect(session.disposed, isTrue);
    await expectLater(
      session.loadItems(escrowVaultId),
      throwsA(isA<CredentialEscrowAdminException>()),
    );

    // The server reports null signing keys when neither the device row nor
    // the Vault device archive exists. Such a deposit or record is never
    // trusted, and the rest of the Vault stays readable.
    server.envelopes['$escrowVaultId:2'] = {
      'key_epoch': 2,
      'sealed': deposit['sealed'],
      'signature': deposit['signature'],
      'depositor_device_id': null,
      'depositor_signing_public_key': null,
    };
    final orphan = await record(
      const HostRecord(
        id: '14141414-1414-4141-8141-141414141414',
        name: 'orphan',
        address: '10.0.0.6',
        login: HostLogin(kind: AuthKind.password, password: 'ORPHAN-PW'),
      ).toJson(),
    );
    server.records.add({...orphan, 'author_signing_public_key': null});
    final partial = await escrowAdmin.openViewer(
      password: _password,
      targetUserId: escrowUserId,
    );
    final partialVaults = await partial.loadVaults();
    expect(partialVaults.single.openedEpochs, [1]);
    expect(partialVaults.single.failedEpochs, [2]);
    expect(partialVaults.single.name, 'Production');
    final partialItems = await partial.loadItems(escrowVaultId);
    expect(partialItems.undecryptable, 1);
    expect(partialItems.hosts.map((h) => h.name), ['db-01']);
    expect(partialItems.credentials, hasLength(1));
    partial.dispose();
    server.envelopes.remove('$escrowVaultId:2');
    server.records.removeLast();

    // A forged deposit (wrong depositor key) is never trusted.
    server.envelopes['$escrowVaultId:1'] = {
      ...server.envelopes['$escrowVaultId:1']!,
      'depositor_signing_public_key': DeviceIdentity.create(sodium)
          .signingPublicKey,
    };
    final forged = await escrowAdmin.openViewer(
      password: _password,
      targetUserId: escrowUserId,
    );
    final forgedVaults = await forged.loadVaults();
    expect(forgedVaults.single.readable, isFalse);
    expect(forgedVaults.single.failedEpochs, [1]);
    expect(forgedVaults.single.name, isNull);
    await expectLater(
      forged.loadItems(escrowVaultId),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'not_available',
        ),
      ),
    );
    forged.dispose();

    // A second admin has no wrap yet, then unlocks with the recovery code.
    final second = await admin(
      server,
      accountId: _secondAdminId,
      username: 'second@example.test',
    );
    final secondAdmin = CredentialEscrowAdmin(second.app);
    await expectLater(
      secondAdmin.openViewer(password: _password, targetUserId: escrowUserId),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'wrap_missing',
        ),
      ),
    );
    await expectLater(
      secondAdmin.unlockWithRecoveryCode(
        recoveryCode: 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA',
        password: _password,
      ),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'wrong_recovery_code',
        ),
      ),
    );
    await secondAdmin.unlockWithRecoveryCode(
      recoveryCode: recoveryCode.toLowerCase().replaceAll('-', ' '),
      password: _password,
    );
    expect(server.wraps[_secondAdminId], isNotNull);
    final secondSession = await secondAdmin.openViewer(
      password: _password,
      targetUserId: escrowUserId,
    );
    expect(secondSession.key.keyId, verifiedKey.keyId);
    secondSession.dispose();

    // A wrap made for another account key (e.g. after full account
    // recovery) is reported as such, with the right password.
    server.wraps[_secondAdminId] = server.wraps[escrowAdminId]!;
    await expectLater(
      secondAdmin.openViewer(password: _password, targetUserId: escrowUserId),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'wrap_invalid',
        ),
      ),
    );

    // A key the pinned instance key did not sign is refused.
    server.key = EscrowTestInstance(sodium)
        .descriptor(keyId: verifiedKey.keyId, publicKey: verifiedKey.publicKey);
    await expectLater(
      escrowAdmin.openViewer(password: _password, targetUserId: escrowUserId),
      throwsA(
        isA<CredentialEscrowAdminException>().having(
          (e) => e.code,
          'code',
          'key_invalid',
        ),
      ),
    );
    first.app.dispose();
    second.app.dispose();
  });

  testWidgets(
    'the viewer closes and releases its keys when the admin session ends',
    (tester) async {
      void notify(AppController app) =>
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          app.notifyListeners();
      final server = _EscrowServer(sodium, instance);
      final first = (await tester.runAsync(
        () => admin(
          server,
          accountId: escrowAdminId,
          username: 'root@example.test',
        ),
      ))!;
      final app = first.app;
      final signedIn = AuthSession(
        accountId: escrowAdminId,
        accessToken: 'token',
        expiresIn: 900,
        refreshToken: 'refresh',
        deviceId: app.identity!.deviceId,
        vaults: const [],
      );
      app.session = signedIn;
      final account = app.account!;
      final client = app.api!;
      final escrowAdmin = CredentialEscrowAdmin(app);
      final key = (await tester.runAsync(
        () async => escrowAdmin.uploadEscrowKey(
          await escrowAdmin.prepareEscrowKey(_password),
        ),
      ))!;
      final userDevice = DeviceIdentity.create(sodium);
      final deposit = buildEscrowDeposit(
        sodium,
        key: key,
        identity: userDevice,
        instanceId: escrowInstanceId,
        vaultId: escrowVaultId,
        keyEpoch: 1,
        vaultKey: sodium.randombytes.buf(32),
      );
      server.envelopes['$escrowVaultId:1'] = {
        'key_epoch': 1,
        'sealed': deposit['sealed'],
        'signature': deposit['signature'],
        'depositor_device_id': userDevice.deviceId,
        'depositor_signing_public_key': userDevice.signingPublicKey,
      };

      final endings = <String, void Function()>{
        'sign-out or revocation': () {
          app.session = null;
          app.account = null;
        },
        'workspace lock': () => app.workspaceLocked = true,
        'admin role removed': () => app.account = AccountProfile(
          accountId: escrowAdminId,
          deviceId: account.deviceId,
          accountKeyEnvelopeVersion: 1,
          accountKeyEnvelope: account.accountKeyEnvelope,
          policy: const {'instance_admin': false},
        ),
        'server switch': () => app.api = server.clientFor(escrowAdminId),
      };
      const viewer = ValueKey('credential_escrow_viewer');
      for (final MapEntry(key: reason, value: end) in endings.entries) {
        final session = (await tester.runAsync(
          () => escrowAdmin.openViewer(
            password: _password,
            targetUserId: escrowUserId,
          ),
        ))!;
        var returned = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    await showAppDialog<void>(
                      context: context,
                      builder: (_) => CredentialEscrowViewerDialog(
                        app: app,
                        session: session,
                        username: 'alice@example.test',
                      ),
                    );
                    returned = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const ValueKey('credential_escrow_viewer_vault_$escrowVaultId'),
          ),
          findsOneWidget,
          reason: reason,
        );
        // Unrelated controller changes keep the viewer open.
        notify(app);
        await tester.pumpAndSettle();
        expect(find.byKey(viewer), findsOneWidget, reason: reason);
        expect(session.disposed, isFalse, reason: reason);

        end();
        notify(app);
        // The escrow key is released before the next frame.
        expect(session.disposed, isTrue, reason: reason);
        await tester.pump();
        expect(find.byKey(viewer), findsNothing, reason: reason);
        await tester.pumpAndSettle();
        expect(
          returned,
          isTrue,
          reason: '$reason: the dialog future completes',
        );
        await expectLater(
          session.loadItems(escrowVaultId),
          throwsA(isA<CredentialEscrowAdminException>()),
        );
        app
          ..session = signedIn
          ..account = account
          ..workspaceLocked = false
          ..api = client;
      }
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'the recovery code and viewer secrets leave the clipboard on close',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return clipboard == null ? null : {'text': clipboard};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final server = _EscrowServer(sodium, instance);
      final first = (await tester.runAsync(
        () => admin(
          server,
          accountId: escrowAdminId,
          username: 'root@example.test',
        ),
      ))!;
      final app = first.app
        ..session = AuthSession(
          accountId: escrowAdminId,
          accessToken: 'token',
          expiresIn: 900,
          refreshToken: 'refresh',
          deviceId: first.app.identity!.deviceId,
          vaults: const [],
        );
      final escrowAdmin = CredentialEscrowAdmin(app);
      final prepared = (await tester.runAsync(
        () => escrowAdmin.prepareEscrowKey(_password),
      ))!;
      final code = prepared.recoveryCode!;
      Widget host(Widget Function() dialog) => MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAppDialog<Object?>(
                context: context,
                builder: (_) => dialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      final l10n = currentL10n;

      // Recovery code: copied, then gone once the dialog is confirmed.
      await tester.pumpWidget(
        host(() => CredentialEscrowRecoveryCodeDialog(prepared: prepared)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('credential_escrow_recovery_copy')),
      );
      await tester.pump();
      expect(clipboard, code);
      expect(find.textContaining(l10n.cvClipboardAutoClear), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('credential_escrow_recovery_stored')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('credential_escrow_recovery_confirm')),
      );
      await tester.pumpAndSettle();
      expect(clipboard, '');

      // Viewer: a revealed password is copied, then gone on Close.
      final key = (await tester.runAsync(
        () => escrowAdmin.uploadEscrowKey(prepared),
      ))!;
      final userDevice = DeviceIdentity.create(sodium);
      final vaultKey = sodium.randombytes.buf(32);
      final deposit = buildEscrowDeposit(
        sodium,
        key: key,
        identity: userDevice,
        instanceId: escrowInstanceId,
        vaultId: escrowVaultId,
        keyEpoch: 1,
        vaultKey: vaultKey,
      );
      server.envelopes['$escrowVaultId:1'] = {
        'key_epoch': 1,
        'sealed': deposit['sealed'],
        'signature': deposit['signature'],
        'depositor_device_id': userDevice.deviceId,
        'depositor_signing_public_key': userDevice.signingPublicKey,
      };
      const hostRecord = HostRecord(
        id: _hostId,
        name: 'db-01',
        address: '10.0.0.5',
        login: HostLogin(kind: AuthKind.password, password: 'SENTINEL-PW'),
      );
      final envelope = (await tester.runAsync(
        () => crypto.encryptRecord(
          vaultKey: vaultKey,
          serverSpaceId: escrowServerSpaceId,
          vaultId: escrowVaultId,
          recordId: _hostId,
          baseRevisionId: null,
          deviceId: userDevice.deviceId,
          deviceSequence: '1',
          keyEpoch: '1',
          membershipVersion: '1',
          operation: 'create',
          plaintext: hostRecord.toJson(),
          identity: userDevice,
        ),
      ))!;
      server.records.add({
        'record_id': _hostId,
        'revision_id': (envelope['header']! as Map)['revision_id'],
        'envelope': envelope,
        'author_device_id': userDevice.deviceId,
        'author_signing_public_key': userDevice.signingPublicKey,
      });
      final session = (await tester.runAsync(
        () => escrowAdmin.openViewer(
          password: _password,
          targetUserId: escrowUserId,
        ),
      ))!;
      await tester.pumpWidget(
        host(
          () => CredentialEscrowViewerDialog(
            app: app,
            session: session,
            username: 'alice@example.test',
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cvViewerOpenVault));
      await tester.pumpAndSettle();
      final card = find.byKey(
        const ValueKey('credential_escrow_viewer_host_$_hostId'),
      );
      expect(card, findsOneWidget);
      expect(find.text('SENTINEL-PW'), findsNothing, reason: 'masked');
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip(l10n.copy)),
      );
      await tester.pump();
      expect(clipboard, 'SENTINEL-PW');
      await tester.tap(
        find.byKey(const ValueKey('credential_escrow_viewer_close')),
      );
      await tester.pumpAndSettle();
      expect(clipboard, '');
      session.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  test(
    'non-admins and signed-out sessions cannot use admin operations',
    () async {
      final server = _EscrowServer(sodium, instance);
      final user = await admin(
        server,
        accountId: escrowAdminId,
        username: 'root@example.test',
      );
      user.app.account = AccountProfile(
        accountId: escrowAdminId,
        deviceId: user.app.identity!.deviceId,
        accountKeyEnvelopeVersion: 1,
        accountKeyEnvelope: user.app.account!.accountKeyEnvelope,
        policy: const {'instance_admin': false},
      );
      final escrowAdmin = CredentialEscrowAdmin(user.app);
      expect(escrowAdmin.available, isFalse);
      await expectLater(
        escrowAdmin.loadOverview(),
        throwsA(
          isA<CredentialEscrowAdminException>().having(
            (e) => e.code,
            'code',
            'not_admin',
          ),
        ),
      );
      user.app.api = null;
      await expectLater(
        escrowAdmin.loadOverview(),
        throwsA(
          isA<CredentialEscrowAdminException>().having(
            (e) => e.code,
            'code',
            'signed_out',
          ),
        ),
      );
      user.app.dispose();
    },
  );
}
