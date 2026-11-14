// End-to-end Credential visibility v1 with the REAL AppController,
// CredentialVisibilityService and CredentialEscrowAdmin against the REAL
// Atermius server binary (SQLite, disposable data dir). The whole suite runs
// twice: on a plaintext database and on a SQLCipher database whose key the
// binary generated (`database-key-generate`) outside the data directory.
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/credential_visibility_real_server_test.dart
// Without the variable the suite reports itself as skipped (it needs the
// server binary); it never fakes the server. One widget test per variant
// renders the admin UI against the real server, so the flutter_test HTTP
// mock is removed in setUpAll.
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/credential_visibility/credential_escrow_admin.dart';
import 'package:aterm_client/credential_visibility/credential_escrow_crypto.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_ack_store.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_api.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/credential_visibility/credential_visibility_admin_ui.dart';
import 'package:aterm_client/ui/credential_visibility/database_encryption_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'support/cloud_real_server.dart';

const _adminUsername = 'admin@example.test';
const _visibleUsername = 'escrowed@example.test';
const _privateUsername = 'private@example.test';
const _escrowKeyFormat = 'atermius-credential-escrow-key-v1';
const _sqliteHeader = 'SQLite format 3\u0000';

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'real-server credential visibility',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  late SodiumSumo sodium;

  setUpAll(() async {
    // Declaring a widget test installs flutter_test's HTTP mock; every test
    // here talks to the real server.
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
  });

  _suite('plaintext database', encrypted: false, sodium: () => sodium);
  _suite('SQLCipher-encrypted database', encrypted: true, sodium: () => sodium);
}

Matcher _apiError(int statusCode, [String? code]) => isA<ApiException>()
    .having((error) => error.statusCode, 'statusCode', statusCode)
    .having((error) => error.code, 'code', code ?? anything);

Matcher _adminError(String code) => isA<CredentialEscrowAdminException>()
    .having((error) => error.code, 'code', code);

Future<void> _waitFor(String what, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Waits until the service has had no refresh running for a few polls (a
/// trigger schedules its refresh in a microtask).
Future<void> _settle(CredentialVisibilityService service) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  var quiet = 0;
  while (quiet < 4) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the credential visibility service did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
    quiet = service.refreshing ? 0 : quiet + 1;
  }
}

int _deposits(RecordingClient client, [String vaultId = '']) => client.requests
    .where(
      (request) => request.startsWith(
        'PUT /api/v1/credential-visibility/escrow/$vaultId',
      ),
    )
    .length;

void _suite(
  String name, {
  required bool encrypted,
  required SodiumSumo Function() sodium,
}) {
  group(name, () {
    final tag = encrypted ? 'enc' : 'plain';
    late TestServer server;
    late Party admin;
    late CredentialEscrowAdmin escrowAdmin;
    late CredentialVisibilityApi adminApi;
    late VerifiedEscrowKey escrowKey;

    late Party visible;
    late String visibleUserId;
    late String visibleVaultId;
    late CredentialVisibilityService visibleService;
    final visibleAcks = MemoryCredentialVisibilityAckStore();
    late HostRecord visibleHost;
    late CredentialRecord visibleKey;

    late Party privateUser;
    late String privateUserId;
    late String privateVaultId;
    late CredentialVisibilityService privateService;
    final privateAcks = MemoryCredentialVisibilityAckStore();
    late HostRecord privateHost;

    // Moves the services' clock forward so a completed sync finds their
    // status stale (the background refresh path of a running app).
    var skew = Duration.zero;
    DateTime clock() => DateTime.now().add(skew);
    final services = <CredentialVisibilityService>[];
    final parties = <Party>[];

    setUpAll(() async {
      server = await TestServer.start(
        extraEnv: const {'ATERMIUS_ADMIN_USERNAMES': _adminUsername},
        encryptedDatabase: encrypted,
      );
    });

    tearDownAll(() async {
      for (final service in services) {
        service.dispose();
      }
      for (final party in parties) {
        party.app.dispose();
      }
      await server.stop();
    });

    test('the admin sets up the escrow key; the recovery code is shown once '
        'and opens the key', () async {
      admin = await party(
        sodium(),
        server.baseUrl,
        username: _adminUsername,
        bootstrap: server.bootstrapToken(),
        storagePrefix: '$tag.admin.',
      );
      parties.add(admin);
      expect(admin.app.isInstanceAdmin, isTrue);
      expect(
        admin.app.instance!.capabilities,
        contains(credentialVisibilityCapability),
      );
      expect(admin.app.instance!.credentialVisibilityDefault, 'private');
      escrowAdmin = CredentialEscrowAdmin(admin.app);
      expect(escrowAdmin.available, isTrue);
      adminApi = CredentialVisibilityApi(admin.app.api!);

      final before = await escrowAdmin.loadOverview();
      expect(before.defaultMode, CredentialVisibilityMode.private);
      expect(before.escrowKey, isNull);
      expect(before.callerWrap, isNull);
      expect(before.recoveryWrap, isNull);
      // The bootstrap account takes the instance default.
      final adminStatus = await adminApi.status();
      expect(adminStatus.mode, CredentialVisibilityMode.private);
      expect(adminStatus.escrowStatus, CredentialEscrowStatus.notRequired);
      expect(adminStatus.escrowKey, isNull);

      final prepared = await escrowAdmin.prepareEscrowKey(realServerPassword);
      final shown = prepared.recoveryCode!;
      expect(shown, matches(RegExp(r'^[A-Z2-7]{4}(-[A-Z2-7]{4}){7}$')));
      expect(
        admin.client.sent('POST', '/api/v1/admin/credential-escrow/key'),
        isFalse,
      );
      escrowKey = await escrowAdmin.uploadEscrowKey(prepared);
      // Shown once: the upload drops the only reference to the code.
      expect(prepared.recoveryCode, isNull);

      final withKey = await escrowAdmin.loadOverview();
      expect(withKey.escrowKey!.keyId, escrowKey.keyId);
      expect(withKey.escrowKey!.publicKey, escrowKey.publicKeyText);
      expect(withKey.callerWrap, isNotNull);
      expect(withKey.recoveryWrap, isNotNull);
      final normalized = normalizeEscrowRecoveryCode(shown);
      expect(jsonEncode(withKey.recoveryWrap), isNot(contains(normalized)));
      expect(jsonEncode(withKey.callerWrap), isNot(contains(normalized)));

      // At most one key: a second creation is refused.
      final second = await escrowAdmin.prepareEscrowKey(realServerPassword);
      second.discardRecoveryCode();
      await expectLater(
        escrowAdmin.uploadEscrowKey(second),
        throwsA(_adminError('key_exists')),
      );
      expect(
        (await escrowAdmin.loadOverview()).escrowKey!.keyId,
        escrowKey.keyId,
      );

      // A different (well-formed) code does not open the key; the shown one
      // does, in any case and grouping, and re-stores this admin's own wrap.
      await expectLater(
        escrowAdmin.unlockWithRecoveryCode(
          recoveryCode: EscrowRecoveryCode.generate(sodium()).display,
          password: realServerPassword,
        ),
        throwsA(_adminError('wrong_recovery_code')),
      );
      expect(
        admin.client.sent('PUT', '/api/v1/admin/credential-escrow/key/wrap'),
        isFalse,
      );
      await escrowAdmin.unlockWithRecoveryCode(
        recoveryCode: shown.toLowerCase().replaceAll('-', ' '),
        password: realServerPassword,
      );
      expect(
        admin.client.sent('PUT', '/api/v1/admin/credential-escrow/key/wrap'),
        isTrue,
      );
      final rewrapped = await escrowAdmin.loadOverview();
      expect(rewrapped.callerWrap, isNotNull);
      expect(rewrapped.callerWrap, isNot(equals(withKey.callerWrap)));
    });

    test(
      '(a) an invited admin_visible user\'s own client deposits by itself; '
      'the admin reads the exact saved secrets; the user sees the view',
      () async {
        expect(
          await admin.app.issueAdminAccountInvitation(
            username: _visibleUsername,
            expiresInDays: 1,
            credentialVisibility: CredentialVisibilityMode.adminVisible,
          ),
          isTrue,
        );
        final token = admin.app.adminAccountInvitationToken!;
        // A separate loopback origin plus storage prefix = a separate device.
        visible = await party(
          sodium(),
          server.baseUrl.replaceFirst('127.0.0.1', 'localhost'),
          username: _visibleUsername,
          invitation: token,
          storagePrefix: '$tag.visible.',
        );
        parties.add(visible);
        visibleUserId = visible.app.account!.accountId;
        visibleVaultId = visible.app.activeVault!.id;
        expect(visible.app.isInstanceAdmin, isFalse);
        expect(
          CredentialVisibilityPolicy.fromAccountPolicy(
            visible.app.account!.policy,
          )!.mode,
          CredentialVisibilityMode.adminVisible,
        );

        // No explicit refresh: the service sees the signed-in scope and
        // deposits the Vault key on its own.
        visibleService = CredentialVisibilityService(
          visible.app,
          ackStore: visibleAcks,
          clock: clock,
        );
        services.add(visibleService);
        debugInstallCredentialVisibilityService(visible.app, visibleService);
        await _waitFor(
          'the automatic deposit',
          () =>
              visibleService.status?.escrowStatus ==
              CredentialEscrowStatus.complete,
        );
        await _settle(visibleService);
        expect(visibleService.mode, CredentialVisibilityMode.adminVisible);
        expect(visibleService.adminVisible, isTrue);
        expect(visibleService.escrowKeyRejected, isFalse);
        expect(visibleService.lastError, isNull);
        expect(visibleService.status!.missing, isEmpty);
        expect(visibleService.status!.escrowKey!.keyId, escrowKey.keyId);
        expect(visibleService.depositedThisScope, greaterThanOrEqualTo(1));
        expect(_deposits(visible.client, '$visibleVaultId/'), 1);
        // First sign-in on this device: the admin-visible notice, once.
        expect(
          visibleService.pendingNotice,
          CredentialVisibilityNotice.adminVisible,
        );
        await visibleService.acknowledge();
        expect(visibleService.pendingNotice, isNull);

        // A Host with a password and a keychain key with a passphrase, synced.
        visibleHost = testHost('Escrowed');
        visibleKey = CredentialRecord(
          id: const Uuid().v4(),
          name: 'Deploy key',
          username: 'deploy',
          kind: AuthKind.privateKey,
          privateKey:
              '-----BEGIN OPENSSH PRIVATE KEY-----\n'
              'SENTINEL-PRIVATE-KEY\n'
              '-----END OPENSSH PRIVATE KEY-----',
          passphrase: 'SENTINEL-PASSPHRASE',
        );
        await visible.app.saveHost(visibleHost);
        await visible.app.saveCredential(visibleKey);
        await visible.app.synchronize();
        await idle(visible.app);
        await _settle(visibleService);
        // Already complete: the sync deposits nothing again.
        expect(_deposits(visible.client), visibleService.depositedThisScope);
        expect(visibleService.lastError, isNull);

        final listed = await visible.app.api!.vaults();
        expect(
          listed.firstWhere((vault) => vault.id == visibleVaultId).adminVisible,
          isTrue,
        );

        // The admin's account directory shows the mode and escrow status.
        await admin.app.loadAdminAccounts();
        final row = admin.app.adminAccountsPage!.accounts.firstWhere(
          (account) => account.userId == visibleUserId,
        );
        expect(row.credentialVisibility, 'admin_visible');
        expect(row.escrowStatus, 'complete');
        final counts = (await escrowAdmin.loadOverview()).counts;
        expect(counts.adminVisible, 1);
        expect(counts.private, 1);
        expect(counts.pending, 0);

        // The admin opens the viewer with the master password.
        final session = await escrowAdmin.openViewer(
          password: realServerPassword,
          targetUserId: visibleUserId,
        );
        try {
          final vaults = await session.loadVaults();
          expect(session.username, _visibleUsername);
          final vault = vaults.firstWhere(
            (item) => item.vaultId == visibleVaultId,
          );
          expect(vault.readable, isTrue);
          expect(vault.failedEpochs, isEmpty);
          expect(vault.name, visible.app.vaultNameFor(visibleVaultId));
          // Listing the Vaults is not a view.
          expect(
            (await CredentialVisibilityApi(
              visible.app.api!,
            ).status()).adminViews,
            isEmpty,
          );
          final items = await session.loadItems(visibleVaultId);
          expect(items.undecryptable, 0);
          final seenHost = items.hosts.singleWhere(
            (item) => item.id == visibleHost.id,
          );
          expect(seenHost.login!.password, 'SENTINEL-Escrowed');
          expect(seenHost.address, visibleHost.address);
          expect(seenHost.port, visibleHost.port);
          expect(seenHost.username, visibleHost.username);
          final seenKey = items.credentials.singleWhere(
            (item) => item.id == visibleKey.id,
          );
          expect(seenKey.privateKey, visibleKey.privateKey);
          expect(seenKey.passphrase, 'SENTINEL-PASSPHRASE');
          expect(seenKey.username, 'deploy');
        } finally {
          session.dispose();
        }
        expect(session.disposed, isTrue);

        // The user's GET /credential-visibility shows who viewed it.
        await visibleService.refresh();
        final views = visibleService.status!.adminViews;
        expect(views, hasLength(1));
        expect(views.single.adminUsername, _adminUsername);
        expect(views.single.vaultId, visibleVaultId);
        expect(
          DateTime.now().toUtc().difference(views.single.viewedAt).inMinutes,
          lessThan(5),
        );

        // A second read by the same admin within 10 minutes is coalesced.
        final again = await escrowAdmin.openViewer(
          password: realServerPassword,
          targetUserId: visibleUserId,
        );
        try {
          await again.loadVaults();
          await again.loadItems(visibleVaultId);
        } finally {
          again.dispose();
        }
        await visibleService.refresh();
        expect(visibleService.status!.adminViews, hasLength(1));
      },
    );

    test(
      '(b) a private user: the client deposits nothing and reports '
      'private; the admin cannot read; a forced deposit is refused',
      () async {
        // No explicit mode: the instance default (private) applies.
        expect(
          await admin.app.issueAdminAccountInvitation(
            username: _privateUsername,
            expiresInDays: 1,
          ),
          isTrue,
        );
        privateUser = await party(
          sodium(),
          server.baseUrl.replaceFirst('127.0.0.1', 'localhost'),
          username: _privateUsername,
          invitation: admin.app.adminAccountInvitationToken!,
          storagePrefix: '$tag.private.',
        );
        parties.add(privateUser);
        privateUserId = privateUser.app.account!.accountId;
        privateVaultId = privateUser.app.activeVault!.id;
        privateService = CredentialVisibilityService(
          privateUser.app,
          ackStore: privateAcks,
          clock: clock,
        );
        services.add(privateService);
        debugInstallCredentialVisibilityService(
          privateUser.app,
          privateService,
        );
        await _waitFor('the first status', () => privateService.status != null);
        await _settle(privateService);
        expect(privateService.mode, CredentialVisibilityMode.private);
        expect(privateService.adminVisible, isFalse);
        expect(privateService.changedAt, isNull);
        expect(
          privateService.status!.escrowStatus,
          CredentialEscrowStatus.notRequired,
        );
        expect(privateService.status!.missing, isEmpty);
        expect(
          privateService.pendingNotice,
          CredentialVisibilityNotice.private,
        );
        await privateService.acknowledge();
        expect(privateService.pendingNotice, isNull);

        privateHost = testHost('Private-only');
        await privateUser.app.saveHost(privateHost);
        await privateUser.app.synchronize();
        await idle(privateUser.app);
        await _settle(privateService);
        expect(_deposits(privateUser.client), 0);
        expect(privateService.depositedThisScope, 0);
        expect(privateService.lastError, isNull);
        expect(
          (await privateUser.app.api!.vaults())
              .firstWhere((vault) => vault.id == privateVaultId)
              .adminVisible,
          isFalse,
        );

        // The admin sees nothing escrowed and every read is refused.
        final account = await adminApi.escrowAccountVaults(privateUserId);
        expect(account.mode, CredentialVisibilityMode.private);
        expect(
          account.vaults.map((vault) => vault.vaultId),
          contains(privateVaultId),
        );
        expect(account.vaults.every((vault) => vault.escrow.isEmpty), isTrue);
        await expectLater(
          adminApi.escrowRecords(
            vaultId: privateVaultId,
            userId: privateUserId,
          ),
          throwsA(_apiError(404, 'CREDENTIAL_ESCROW_NOT_AVAILABLE')),
        );
        final viewer = await escrowAdmin.openViewer(
          password: realServerPassword,
          targetUserId: privateUserId,
        );
        try {
          final vaults = await viewer.loadVaults();
          expect(
            vaults
                .firstWhere((vault) => vault.vaultId == privateVaultId)
                .readable,
            isFalse,
          );
          await expectLater(
            viewer.loadItems(privateVaultId),
            throwsA(_adminError('not_available')),
          );
        } finally {
          viewer.dispose();
        }

        // A modified client that deposits anyway (valid seal and device
        // signature) is refused by the server.
        final epoch = int.parse(privateUser.app.activeVault!.activeKeyEpoch);
        final vaultKey = privateUser.app.copyVaultKeyForCredentialEscrow(
          privateVaultId,
          epoch,
        )!;
        final Map<String, Object?> body;
        try {
          body = buildEscrowDeposit(
            sodium(),
            key: escrowKey,
            identity: privateUser.app.identity!,
            instanceId: privateUser.app.instance!.instanceId,
            vaultId: privateVaultId,
            keyEpoch: epoch,
            vaultKey: vaultKey,
          );
        } finally {
          vaultKey.fillRange(0, vaultKey.length, 0);
        }
        await expectLater(
          CredentialVisibilityApi(privateUser.app.api!)
              .deposit(vaultId: privateVaultId, keyEpoch: epoch, body: body),
          throwsA(_apiError(409, 'CREDENTIAL_ESCROW_NOT_REQUIRED')),
        );
        expect(
          (await adminApi.escrowAccountVaults(privateUserId)).vaults
              .every((vault) => vault.escrow.isEmpty),
          isTrue,
        );
        await privateService.refresh();
        expect(privateService.status!.adminViews, isEmpty);
        expect(privateService.mode, CredentialVisibilityMode.private);
      },
    );

    test('(c) admin_visible → private deletes the escrow, the admin read is '
        'refused, and the user\'s client shows the one-time notice', () async {
      final depositsBefore = _deposits(visible.client);
      final receipt = await escrowAdmin.setAccountMode(
        userId: visibleUserId,
        mode: CredentialVisibilityMode.private,
      );
      expect(receipt.mode, CredentialVisibilityMode.private);
      expect(receipt.escrowStatus, CredentialEscrowStatus.notRequired);
      expect(receipt.changedAt, isNotNull);
      // Idempotent: unchanged mode keeps changed_at.
      final repeated = await escrowAdmin.setAccountMode(
        userId: visibleUserId,
        mode: CredentialVisibilityMode.private,
      );
      expect(repeated.changedAt, receipt.changedAt);

      final after = await adminApi.escrowAccountVaults(visibleUserId);
      expect(after.mode, CredentialVisibilityMode.private);
      expect(after.vaults.every((item) => item.escrow.isEmpty), isTrue);
      await expectLater(
        adminApi.escrowRecords(vaultId: visibleVaultId, userId: visibleUserId),
        throwsA(_apiError(404, 'CREDENTIAL_ESCROW_NOT_AVAILABLE')),
      );
      final denied = await escrowAdmin.openViewer(
        password: realServerPassword,
        targetUserId: visibleUserId,
      );
      try {
        final deniedVaults = await denied.loadVaults();
        expect(
          deniedVaults
              .firstWhere((item) => item.vaultId == visibleVaultId)
              .readable,
          isFalse,
        );
        await expectLater(
          denied.loadItems(visibleVaultId),
          throwsA(_adminError('not_available')),
        );
      } finally {
        denied.dispose();
      }
      await admin.app.loadAdminAccounts();
      final row = admin.app.adminAccountsPage!.accounts.firstWhere(
        (account) => account.userId == visibleUserId,
      );
      expect(row.credentialVisibility, 'private');
      expect(row.escrowStatus, 'not_required');

      // The user's client learns it on the next unlock.
      await visible.app.lock();
      await visible.app.unlockLockedWorkspace(password: realServerPassword);
      await idle(visible.app);
      await _waitFor(
        'the private mode on the user\'s client',
        () => visibleService.mode == CredentialVisibilityMode.private,
      );
      await _settle(visibleService);
      expect(visibleService.changedAt, receipt.changedAt);
      expect(visibleService.adminVisible, isFalse);
      expect(
        visibleService.pendingNotice,
        CredentialVisibilityNotice.switchedToPrivate,
      );
      await visibleService.acknowledge();
      expect(visibleService.pendingNotice, isNull);
      // One-time: later refreshes do not bring it back.
      await visibleService.refresh();
      expect(visibleService.pendingNotice, isNull);
      // The earlier view stays listed; nothing is deposited any more.
      expect(visibleService.status!.adminViews, isNotEmpty);
      expect(
        visibleService.status!.escrowStatus,
        CredentialEscrowStatus.notRequired,
      );
      expect(_deposits(visible.client), depositsBefore);
      expect(
        (await visible.app.api!.vaults())
            .firstWhere((item) => item.id == visibleVaultId)
            .adminVisible,
        isFalse,
      );
    });

    test('(a) a private user assigned admin_visible deposits after the next '
        'sync; the admin reads the earlier saved password', () async {
      // (b) already sent one refused, hand-built deposit from this device.
      final depositsBefore = _deposits(privateUser.client, '$privateVaultId/');
      final receipt = await escrowAdmin.setAccountMode(
        userId: privateUserId,
        mode: CredentialVisibilityMode.adminVisible,
      );
      expect(receipt.mode, CredentialVisibilityMode.adminVisible);
      expect(receipt.escrowStatus, CredentialEscrowStatus.pending);
      expect(
        (await escrowAdmin.loadOverview()).counts.pending,
        greaterThanOrEqualTo(1),
      );

      // A running app: the first completed sync after the status went stale
      // refreshes it, sees `pending` and deposits.
      skew += privateService.statusMaxAge + const Duration(seconds: 1);
      await privateUser.app.synchronize();
      await idle(privateUser.app);
      await _waitFor(
        'the deposit after the assignment',
        () =>
            privateService.status?.escrowStatus ==
            CredentialEscrowStatus.complete,
      );
      await _settle(privateService);
      expect(privateService.mode, CredentialVisibilityMode.adminVisible);
      expect(privateService.lastError, isNull);
      expect(
        _deposits(privateUser.client, '$privateVaultId/'),
        depositsBefore + 1,
      );
      expect(
        privateService.pendingNotice,
        CredentialVisibilityNotice.switchedToAdminVisible,
      );
      await privateService.acknowledge();
      expect(privateService.pendingNotice, isNull);
      expect((await escrowAdmin.loadOverview()).counts.pending, 0);

      final session = await escrowAdmin.openViewer(
        password: realServerPassword,
        targetUserId: privateUserId,
      );
      try {
        final vaults = await session.loadVaults();
        expect(
          vaults
              .firstWhere((vault) => vault.vaultId == privateVaultId)
              .readable,
          isTrue,
        );
        final items = await session.loadItems(privateVaultId);
        expect(
          items.hosts
              .singleWhere((item) => item.id == privateHost.id)
              .login!
              .password,
          'SENTINEL-Private-only',
        );
      } finally {
        session.dispose();
      }
      await privateService.refresh();
      expect(
        privateService.status!.adminViews.single.adminUsername,
        _adminUsername,
      );
    });

    test('(d) a non-admin is refused on every admin escrow route', () async {
      expect(visible.app.isInstanceAdmin, isFalse);
      // The client hides and guards the admin flows...
      final userEscrowAdmin = CredentialEscrowAdmin(visible.app);
      expect(userEscrowAdmin.available, isFalse);
      await expectLater(
        userEscrowAdmin.loadOverview(),
        throwsA(_adminError('not_admin')),
      );
      // ...and the server refuses well-formed, device-signed requests.
      final userApi = CredentialVisibilityApi(visible.app.api!);
      final forbidden = throwsA(_apiError(403, 'INSTANCE_ADMIN_REQUIRED'));
      await expectLater(userApi.adminOverview(), forbidden);
      await expectLater(
        userApi.setDefaultMode(CredentialVisibilityMode.adminVisible),
        forbidden,
      );
      // Users cannot change their own mode, nor anyone else's.
      await expectLater(
        userApi.setAccountMode(
          userId: visibleUserId,
          mode: CredentialVisibilityMode.adminVisible,
        ),
        forbidden,
      );
      await expectLater(
        userApi.setAccountMode(
          userId: privateUserId,
          mode: CredentialVisibilityMode.private,
        ),
        forbidden,
      );
      await expectLater(
        userApi.createAccountInvitation(
          username: 'third@example.test',
          expiresInSeconds: 3600,
          mode: CredentialVisibilityMode.adminVisible,
        ),
        throwsA(_apiError(403)),
      );
      final generated = GeneratedEscrowKey.generate(sodium());
      final accountKey = sodium().randombytes.buf(32);
      try {
        final instanceId = visible.app.instance!.instanceId;
        final accountWrap = await wrapEscrowSecretKeyForAccount(
          visible.app.crypto,
          accountKey: accountKey,
          secretKey: generated.keyPair.secretKey,
          instanceId: instanceId,
          keyId: generated.keyId,
          accountId: visibleUserId,
        );
        await expectLater(
          userApi.createEscrowKey(
            keyId: generated.keyId,
            publicKey: generated.publicKeyText,
            creatorSignature: signEscrowKeyCreation(
              sodium(),
              identity: visible.app.identity!,
              instanceId: instanceId,
              accountId: visibleUserId,
              keyId: generated.keyId,
              publicKey: generated.publicKeyText,
            ),
            accountWrap: accountWrap,
            recoveryWrap: wrapEscrowSecretKeyForRecovery(
              visible.app.crypto,
              code: EscrowRecoveryCode.generate(sodium()),
              secretKey: generated.keyPair.secretKey,
              instanceId: instanceId,
              keyId: generated.keyId,
            ),
          ),
          forbidden,
        );
        await expectLater(
          userApi.storeOwnWrap(
            keyId: escrowKey.keyId,
            accountWrap: await wrapEscrowSecretKeyForAccount(
              visible.app.crypto,
              accountKey: accountKey,
              secretKey: generated.keyPair.secretKey,
              instanceId: instanceId,
              keyId: escrowKey.keyId,
              accountId: visibleUserId,
            ),
          ),
          forbidden,
        );
      } finally {
        generated.dispose();
        accountKey.fillRange(0, accountKey.length, 0);
      }
      await expectLater(
        userApi.resetEscrowKey(keyId: escrowKey.keyId),
        forbidden,
      );
      await expectLater(userApi.escrowAccountVaults(privateUserId), forbidden);
      await expectLater(userApi.escrowAccountVaults(visibleUserId), forbidden);
      await expectLater(
        userApi.escrowRecords(vaultId: privateVaultId, userId: privateUserId),
        forbidden,
      );
      await expectLater(
        userApi.escrowRecords(vaultId: visibleVaultId, userId: visibleUserId),
        forbidden,
      );

      // Without a session: 401 on admin and user routes alike.
      final anonymous = CredentialVisibilityApi(
        ApiClient(baseUrl: server.baseUrl),
      );
      await expectLater(anonymous.adminOverview(), throwsA(_apiError(401)));
      await expectLater(anonymous.status(), throwsA(_apiError(401)));
      await expectLater(
        anonymous.escrowRecords(vaultId: privateVaultId, userId: privateUserId),
        throwsA(_apiError(401)),
      );

      // Nothing changed, and the refused reads were not recorded as views.
      final overview = await escrowAdmin.loadOverview();
      expect(overview.escrowKey!.keyId, escrowKey.keyId);
      expect(overview.defaultMode, CredentialVisibilityMode.private);
      final privateAccount = await adminApi.escrowAccountVaults(privateUserId);
      expect(privateAccount.mode, CredentialVisibilityMode.adminVisible);
      expect(
        privateAccount.vaults
            .firstWhere((vault) => vault.vaultId == privateVaultId)
            .escrow,
        isNotEmpty,
      );
      expect(
        (await adminApi.escrowAccountVaults(visibleUserId)).mode,
        CredentialVisibilityMode.private,
      );
      await privateService.refresh();
      expect(privateService.status!.adminViews, hasLength(1));
    });

    test('(e) a private owner is warned before sharing with an admin_visible '
        'account; afterwards its client names the exception and the badge '
        'follows', () async {
      // Since (c) the visible user is private; since the later (a) the
      // private user is admin_visible.
      expect(visibleService.mode, CredentialVisibilityMode.private);
      expect(visible.app.activeVault!.id, visibleVaultId);
      final ownerApi = CredentialVisibilityApi(visible.app.api!);
      final recipientDevice = privateUser.app.identity!.deviceId;
      final check = await ownerApi.shareRecipient(
        vaultId: visibleVaultId,
        deviceId: recipientDevice,
      );
      expect(check.recipientAdminVisible, isTrue);
      expect(check.vaultAdminVisible, isFalse);
      // The other direction: a private recipient, an admin-visible Vault.
      final otherOwnerApi = CredentialVisibilityApi(privateUser.app.api!);
      final reverse = await otherOwnerApi.shareRecipient(
        vaultId: privateVaultId,
        deviceId: visible.app.identity!.deviceId,
      );
      expect(reverse.recipientAdminVisible, isFalse);
      expect(reverse.vaultAdminVisible, isTrue);
      // Only the Vault's owner may ask.
      await expectLater(
        otherOwnerApi.shareRecipient(
          vaultId: visibleVaultId,
          deviceId: visible.app.identity!.deviceId,
        ),
        throwsA(_apiError(404)),
      );

      await visibleService.refresh();
      expect(visibleService.status!.adminVisibleVaults, 0);
      expect(visibleService.privateWithAdminVisibleVaults, isFalse);

      // The owner confirms and shares anyway; the recipient joins.
      final recipient = visible.app.verifyVaultShareRequest(
        privateUser.app.exportVaultShareRequest(),
      );
      expect(recipient.deviceId, recipientDevice);
      final invitation = await visible.app.createVaultInvitation(
        recipient: recipient,
        role: 'viewer',
      );
      // The invitation changed the owner's descriptor, which schedules a
      // refresh of its own; let it finish before the recipient joins.
      await _settle(visibleService);
      await privateUser.app.acceptVaultInvitation(
        invitation['token'] as String,
      );
      await idle(privateUser.app);
      expect(
        (await visible.app.api!.vaults())
            .firstWhere((vault) => vault.id == visibleVaultId)
            .adminVisible,
        isTrue,
      );

      // The owner's next status refresh sees the changed count and refreshes
      // the stale cached badge; its private-mode text names the exception.
      await visibleService.refresh();
      await _settle(visibleService);
      expect(visibleService.status!.mode, CredentialVisibilityMode.private);
      expect(visibleService.status!.adminVisibleVaults, 1);
      await _waitFor(
        'the refreshed Vault badge',
        () => visible.app.vaults
            .firstWhere((vault) => vault.id == visibleVaultId)
            .adminVisible,
      );
      expect(visible.app.activeVault!.adminVisible, isTrue);
      expect(visibleService.privateWithAdminVisibleVaults, isTrue);
    });

    testWidgets('the admin UI shows the database encryption state', (
      tester,
    ) async {
      final expected = encrypted
          ? const ValueKey('database_encryption_enabled')
          : const ValueKey('database_encryption_disabled_warning');
      final other = encrypted
          ? const ValueKey('database_encryption_disabled_warning')
          : const ValueKey('database_encryption_enabled');
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 300 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(done(), isTrue);
      }

      // The real overview, through the real controller.
      await tester.runAsync(admin.app.loadInstanceAdminOverview);
      final overview = admin.app.instanceAdminOverview!;
      expect(overview.databaseEncryption, encrypted ? 'enabled' : 'disabled');
      expect(
        databaseEncryptionNoticeFor(overview.databaseEncryption),
        encrypted
            ? DatabaseEncryptionNotice.encrypted
            : DatabaseEncryptionNotice.warning,
      );
      try {
        // The overview card's status widget with the real value.
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: DatabaseEncryptionStatus(
                databaseEncryption: overview.databaseEncryption,
              ),
            ),
          ),
        );
        expect(find.byKey(expected), findsOneWidget);
        expect(find.byKey(other), findsNothing);
        // The escrow administration card loads it from the server itself.
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: CredentialVisibilityAdminCard(app: admin.app),
              ),
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('credential_visibility_admin_load')),
        );
        await until(() => find.byKey(expected).evaluate().isNotEmpty);
        expect(find.byKey(other), findsNothing);
        expect(
          find.byKey(const ValueKey('credential_visibility_admin_counts')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(seconds: 1));
        }
      }
    });

    if (encrypted) {
      test('SQLCipher: the binary made the key outside the data dir and no '
          'escrow data is readable in any data-dir file', () async {
        final keyFile = server.databaseKeyFile!;
        expect(File(keyFile).lengthSync(), 32);
        expect(File(keyFile).statSync().modeString(), 'rw-------');
        expect(keyFile.startsWith('${server.dataDir}/'), isFalse);
        final keyHex = File(keyFile)
            .readAsBytesSync()
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(server.databaseKeyGenerateOutput, isNot(contains(keyHex)));
        await _expectDataDir(
          server,
          admin,
          encrypted: true,
          markers: {
            _adminUsername,
            _visibleUsername,
            _privateUsername,
            escrowKey.keyId,
            _escrowKeyFormat,
            keyHex,
          },
        );
      });
    } else {
      test(
        'control: the plaintext data dir does show the same markers',
        () async {
          await _expectDataDir(
            server,
            admin,
            encrypted: false,
            markers: {
              _adminUsername,
              _visibleUsername,
              _privateUsername,
              escrowKey.keyId,
              _escrowKeyFormat,
            },
          );
        },
      );
    }
  });
}

Future<void> _expectDataDir(
  TestServer server,
  Party admin, {
  required bool encrypted,
  required Set<String> markers,
}) async {
  final overview = await admin.app.api!.get('/api/v1/admin/overview');
  expect(overview['database_encryption'], encrypted ? 'enabled' : 'disabled');
  final database = File('${server.dataDir}/atermius.db');
  final header = latin1.decode(
    database.readAsBytesSync().take(_sqliteHeader.length).toList(),
  );
  final files = Directory(server.dataDir)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
  final found = <String, List<String>>{};
  for (final file in files) {
    final text = latin1.decode(file.readAsBytesSync());
    for (final marker in markers) {
      if (text.contains(marker)) {
        (found[marker] ??= []).add(file.uri.pathSegments.last);
      }
    }
  }
  if (encrypted) {
    expect(header, isNot(_sqliteHeader));
    expect(found, isEmpty, reason: 'plaintext markers in the data dir');
  } else {
    expect(header, _sqliteHeader);
    expect(found.keys.toSet(), markers, reason: 'control must see markers');
  }
}
