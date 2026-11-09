// End-to-end owner workflows with the REAL AppController and CloudAccessService
// against the REAL Atermius server binary (SQLite, disposable data dir).
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/cloud_access_real_server_test.dart
// Without the variable the suite reports itself as skipped (it needs the
// server binary); it never fakes the server.
import 'dart:async';
import 'dart:io';

import 'package:aterm_client/cloud/cloud_access_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Future<Map<String, dynamic>> _member(
  Party owner,
  String vaultId,
  String userId,
) async {
  final members = await owner.app.api!.vaultMembers(vaultId);
  return members.firstWhere((m) => m['user_id'] == userId);
}

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'real-server owner workflows',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  late SodiumSumo sodium;
  late TestServer server;
  late Party owner;
  late Party recipient;
  late String sourceVaultId;
  late HostRecord h1;
  late HostRecord h2;
  String? sharingVaultId;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    owner = await party(
      sodium,
      server.baseUrl,
      username: 'owner@example.test',
      bootstrap: server.bootstrapToken(),
    );
    // A different (equally loopback) origin keeps the two devices' secure
    // storage namespaces apart inside one test process.
    final recipientUrl = server.baseUrl.replaceFirst('127.0.0.1', 'localhost');
    recipient = await party(
      sodium,
      recipientUrl,
      username: 'recipient@example.test',
      invitation: server.accountInvitation('recipient@example.test'),
    );
    sourceVaultId = owner.app.activeVault!.id;
    h1 = testHost('H1');
    h2 = testHost('H2-unrelated');
    await owner.app.saveHost(h1);
    await owner.app.saveHost(h2);
    await owner.app.synchronize();
    await idle(owner.app);
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('superseded selection after creating the sharing Vault copies nothing and keeps the user choice', () async {
    final before = owner.app.vaults.map((v) => v.id).toSet();
    final plan = owner.service.planShare([
      owner.app.hosts.firstWhere((h) => h.id == h1.id),
    ]);
    owner.service.checkpointForTesting = (stage) async {
      if (stage == 'sharing_vault_created')
        await owner.app.selectVault(sourceVaultId);
    };
    // The Vault itself was already created on the server: reported honestly.
    await expectLater(
      owner.service.createSharingVault(plan, 'Superseded'),
      throwsA(
        isA<CloudAccessException>().having(
          (e) => e.code,
          'code',
          'scope_ended_committed',
        ),
      ),
    );
    owner.service.checkpointForTesting = null;
    expect(
      owner.app.activeVault?.id,
      sourceVaultId,
      reason: 'the newer user choice is kept',
    );
    final created = owner.app.vaults
        .map((v) => v.id)
        .toSet()
        .difference(before)
        .single;
    expect(
      await hostsIn(owner.app, created),
      isEmpty,
      reason: 'no copy reached the new Vault',
    );
    final source = await hostsIn(owner.app, sourceVaultId);
    expect(source.map((h) => h.id).toSet(), {
      h1.id,
      h2.id,
    }, reason: 'nothing was added to the source Vault');
  });

  test('a plan from another Vault is refused before any write', () async {
    final plan = owner.service.planShare([
      owner.app.hosts.firstWhere((h) => h.id == h1.id),
    ]);
    final other = owner.app.vaults.firstWhere((v) => v.id != sourceVaultId).id;
    await owner.app.selectVault(other);
    final before = owner.client.requests.length;
    await expectLater(
      owner.service.createSharingVault(plan, 'Wrong source'),
      throwsA(
        isA<CloudAccessException>().having(
          (e) => e.code,
          'code',
          'selection_superseded',
        ),
      ),
    );
    expect(
      owner.client.requests
          .skip(before)
          .where((r) => r.startsWith('POST /api/v1/vaults')),
      isEmpty,
    );
    await owner.app.selectVault(sourceVaultId);
  });

  test('sharing H1 creates a synchronized Vault with only H1', () async {
    final plan = owner.service.planShare([
      owner.app.hosts.firstWhere((h) => h.id == h1.id),
    ]);
    sharingVaultId = await owner.service.createSharingVault(plan, 'Shared H1');
    expect(sharingVaultId, isNot(sourceVaultId));
    expect(
      owner.app.activeVault?.id,
      sourceVaultId,
      reason: 'returned to the source Vault',
    );
    final shared = await hostsIn(owner.app, sharingVaultId!);
    expect(shared.map((h) => h.name), ['H1']);
    expect(shared.single.login?.password, 'SENTINEL-H1');
    expect(shared.single.id, isNot(h1.id));
    await owner.app.selectVault(sourceVaultId);
  });

  test('owner-confirmed key delivery, recipient acceptance and signed viewer→editor→viewer changes', () async {
    final vaultId = sharingVaultId!;
    final api = owner.service.api;
    final org = await api.createOrg('Real server org');
    final orgId = org['org_id'] as String;
    final invite = await api.createInvitation(
      orgId,
      role: 'member',
      username: 'recipient@example.test',
    );
    await recipient.service.api.acceptInvitation(invite['token'] as String);
    await recipient.service.publishDeviceCard();
    await api.attachVault(vaultId, orgId);
    var grants = await api.grants(vaultId);
    final recipientId = recipient.app.account!.accountId;
    await api.setGrant(
      vaultId,
      'user',
      recipientId,
      'viewer',
      grants['grants_revision'] as int,
    );
    var dist = await api.keyDistribution(vaultId);
    final pending = (dist['pending_additions'] as List).cast<Map>().single;
    expect(pending['status'], 'waiting_for_owner');
    // Owner delivers after confirming the fingerprint (UI dialog); the
    // service selects the sharing Vault and returns to the source Vault.
    await owner.service.deliverKey(
      vaultId: vaultId,
      card: Map<String, dynamic>.from(
        (pending['device_cards'] as List).first['card'] as Map,
      ),
      role: 'viewer',
    );
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect(await recipient.service.acceptDeliveries(), 1);
    await recipient.app.synchronize();
    final seen = await hostsIn(recipient.app, vaultId);
    expect(seen.map((h) => h.name), [
      'H1',
    ], reason: 'the recipient sees H1 only, never H2');
    expect((await _member(owner, vaultId, recipientId))['role'], 'viewer');

    // viewer → editor: desired grant first, then the owner-signed rotation.
    grants = await api.grants(vaultId);
    await api.setGrant(
      vaultId,
      'user',
      recipientId,
      'editor',
      grants['grants_revision'] as int,
    );
    dist = await api.keyDistribution(vaultId);
    expect(
      (dist['pending_additions'] as List).cast<Map>().single['status'],
      'role_differs',
    );
    await owner.service.changeMemberRole(
      vaultId: vaultId,
      userId: recipientId,
      role: 'editor',
    );
    expect((await _member(owner, vaultId, recipientId))['role'], 'editor');
    dist = await api.keyDistribution(vaultId);
    expect(dist['pending_additions'], isEmpty);
    final listed = (await recipient.app.api!.vaults()).firstWhere(
      (v) => v.id == vaultId,
    );
    expect(listed.canWrite, isTrue);

    // editor → viewer: the server restricts at once; the signed change follows.
    grants = await api.grants(vaultId);
    await api.setGrant(
      vaultId,
      'user',
      recipientId,
      'viewer',
      grants['grants_revision'] as int,
    );
    dist = await api.keyDistribution(vaultId);
    expect(
      (dist['restricted_to_viewer'] as List).single['user_id'],
      recipientId,
    );
    expect(
      (await recipient.app.api!.vaults())
          .firstWhere((v) => v.id == vaultId)
          .canWrite,
      isFalse,
    );
    await owner.service.changeMemberRole(
      vaultId: vaultId,
      userId: recipientId,
      role: 'viewer',
    );
    expect((await _member(owner, vaultId, recipientId))['role'], 'viewer');
    dist = await api.keyDistribution(vaultId);
    expect(dist['pending_additions'], isEmpty);
    expect(dist['restricted_to_viewer'], isEmpty);
    expect(owner.app.activeVault?.id, sourceVaultId);
  });

  test(
    'switching Vault while a Host is being sealed sends no capsule',
    () async {
      final rdp = testHost(
        'RDP-host',
        protocol: HostProtocol.rdp,
        cert: 'ab' * 32,
      );
      await owner.app.saveHost(rdp);
      await owner.app.synchronize();
      await idle(owner.app);
      owner.service.checkpointForTesting = (stage) async {
        if (stage == 'host_synced')
          await owner.app.selectVault(sharingVaultId!);
      };
      await expectLater(
        owner.service.createLink([rdp], const ShareLinkOptions()),
        throwsA(
          isA<CloudAccessException>().having(
            (e) => e.code,
            'code',
            'selection_superseded',
          ),
        ),
      );
      owner.service.checkpointForTesting = null;
      expect(owner.client.sent('PUT', '/gateway-capsule'), isFalse);
      expect(owner.client.sent('POST', '/share-links'), isFalse);
      await owner.app.selectVault(sourceVaultId);
      // Same Host, undisturbed: the capsule and link are created normally.
      final created = await owner.service.createLink([
        rdp,
      ], const ShareLinkOptions());
      expect(created.url, contains('/s/'));
      expect(
        owner.client.sent('PUT', '/hosts/${rdp.id}/gateway-capsule'),
        isTrue,
      );
    },
  );

  test('sign-out while the gateway key request is held sends no capsule and no link', () async {
    final rdp = owner.app.hosts.firstWhere((h) => h.name == 'RDP-host');
    owner.client.requests.clear();
    owner.client
      ..held = Completer<void>()
      ..release = Completer<void>()
      ..holdWhen = (request) =>
          request.url.path == '/api/v1/share-gateway/keys';
    final attempt = owner.service.createLink([rdp], const ShareLinkOptions());
    await owner.client.held!.future;
    await owner.app.logout();
    owner.client.release!.complete();
    await expectLater(attempt, throwsA(isA<CloudAccessException>()));
    expect(owner.client.sent('PUT', '/gateway-capsule'), isFalse);
    expect(owner.client.sent('POST', '/share-links'), isFalse);
  });

  test(
    'sign-out after the invitation is created sends no key delivery',
    () async {
      await owner.app.login(
        username: 'owner@example.test',
        password: realServerPassword,
      );
      await idle(owner.app);
      final api = owner.service.api;
      final vaultId = sharingVaultId!;
      final third = await party(
        sodium,
        server.baseUrl,
        username: 'third@example.test',
        storagePrefix: 'third.',
        invitation: server.accountInvitation('third@example.test'),
      );
      final orgId =
          (await api.grants(vaultId))['organization']['org_id'] as String;
      final invite = await api.createInvitation(
        orgId,
        role: 'member',
        username: 'third@example.test',
      );
      await third.service.api.acceptInvitation(invite['token'] as String);
      await third.service.publishDeviceCard();
      final grants = await api.grants(vaultId);
      await api.setGrant(
        vaultId,
        'user',
        third.app.account!.accountId,
        'viewer',
        grants['grants_revision'] as int,
      );
      final dist = await api.keyDistribution(vaultId);
      final pending = (dist['pending_additions'] as List)
          .cast<Map>()
          .firstWhere((p) => p['user_id'] == third.app.account!.accountId);
      owner.client.requests.clear();
      owner.service.checkpointForTesting = (stage) async {
        if (stage == 'delivery_invited') await owner.app.logout();
      };
      await expectLater(
        owner.service.deliverKey(
          vaultId: vaultId,
          card: Map<String, dynamic>.from(
            (pending['device_cards'] as List).first['card'] as Map,
          ),
          role: 'viewer',
        ),
        // The signed invitation already exists on the server: reported
        // honestly, and it is never delivered.
        throwsA(
          isA<CloudAccessException>().having(
            (e) => e.code,
            'code',
            'scope_ended_committed',
          ),
        ),
      );
      expect(owner.client.sent('POST', '/key-deliveries'), isFalse);
      expect(
        await third.service.acceptDeliveries(),
        0,
        reason: 'nothing was delivered',
      );
    },
  );
}
