// Owner-operation lifetimes on the REAL AppController against the REAL server
// binary: a successful server answer that arrives after the session or the
// Vault selection changed must not be installed into the newer scope, and a
// select-away-and-back (A→B→A) must not let an operation continue or restore
// an older choice. Responses are held AFTER the server answered (committed).
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/cloud_access_scope_lifetime_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/cloud/cloud_access_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Matcher _code(String code) =>
    throwsA(isA<CloudAccessException>().having((e) => e.code, 'code', code));

bool _post(http.BaseRequest r, bool Function(String path) path) =>
    r.method == 'POST' && path(r.url.path);

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'owner operation lifetimes on a real server',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  late SodiumSumo sodium;
  late TestServer server;
  late Party owner;
  late String sourceVaultId;
  late String orgId;
  late HostRecord h1;
  late HostRecord h2;
  late String sharedVaultId;
  var grantees = 0;

  Set<String> vaultIds() => owner.app.vaults.map((v) => v.id).toSet();

  Future<void> backToSource() async {
    await owner.app.selectVault(sourceVaultId);
    expect(owner.app.activeVault?.id, sourceVaultId);
    await idle(owner.app);
  }

  /// A fresh org member with a published device card and a viewer grant on
  /// the shared Vault; returns the party and the card the owner confirms.
  Future<(Party, Map<String, dynamic>)> grantee() async {
    final name = 'grantee${++grantees}@example.test';
    final party_ = await party(
      sodium,
      server.baseUrl,
      username: name,
      storagePrefix: 'g$grantees.',
      invitation: server.accountInvitation(name),
    );
    final api = owner.service.api;
    final invite = await api.createInvitation(orgId, role: 'member', username: name);
    await party_.service.api.acceptInvitation(invite['token'] as String);
    await party_.service.publishDeviceCard();
    final grants = await api.grants(sharedVaultId);
    await api.setGrant(sharedVaultId, 'user', party_.app.account!.accountId, 'viewer', grants['grants_revision'] as int);
    final pending = ((await api.keyDistribution(sharedVaultId))['pending_additions'] as List)
        .cast<Map>()
        .firstWhere((p) => p['user_id'] == party_.app.account!.accountId);
    return (party_, Map<String, dynamic>.from((pending['device_cards'] as List).first['card'] as Map));
  }

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    owner = await party(sodium, server.baseUrl, username: 'owner@example.test', bootstrap: server.bootstrapToken());
    sourceVaultId = owner.app.activeVault!.id;
    h1 = testHost('H1');
    h2 = testHost('H2-private');
    await owner.app.saveHost(h1);
    await owner.app.saveHost(h2);
    await owner.app.synchronize();
    await idle(owner.app);
    orgId = (await owner.service.api.createOrg('Lifetime org'))['org_id'] as String;
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('a same-Vault membership refresh during sharing is still supported', () async {
    final plan = owner.service.planShare([owner.app.hosts.firstWhere((h) => h.id == h1.id)]);
    owner.service.checkpointForTesting = (stage) async {
      // Legitimate refresh of the same selection (no new selection request):
      // it rebuilds the repository and must not abort the operation.
      if (stage == 'sharing_vault_created') await owner.app.reloadVaultsForTesting();
    };
    sharedVaultId = await owner.service.createSharingVault(plan, 'Shared H1');
    owner.service.checkpointForTesting = null;
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect((await hostsIn(owner.app, sharedVaultId)).map((h) => h.name), ['H1']);
    await backToSource();
    await owner.service.api.attachVault(sharedVaultId, orgId);
  });

  test('createVault: response held past sign-out and another account\'s sign-in installs nothing there', () async {
    // A separate device, so the shared owner session stays intact.
    final solo = await party(
      sodium,
      server.baseUrl,
      username: 'solo@example.test',
      storagePrefix: 'solo.',
      invitation: server.accountInvitation('solo@example.test'),
    );
    final soloVaults = solo.app.vaults.map((v) => v.id).toSet();
    solo.client.holdResponse((r) => _post(r, (p) => p == '/api/v1/vaults'));
    final attempt = solo.app.createVaultInScope('Held across accounts');
    await solo.client.responseHeld!.future;
    expect(solo.client.heldResponseStatus, inInclusiveRange(200, 299), reason: 'the server committed the Vault');
    final createdId = (jsonDecode(solo.client.heldRequestBody!) as Map)['vault_id'] as String;
    expect(soloVaults, isNot(contains(createdId)));

    await solo.app.logout();
    // Server re-activation (refreshes the instance info) and a different
    // account on the same device.
    await solo.app.configureServer(server.baseUrl);
    await solo.app.register(
      username: 'switched@example.test',
      password: realServerPassword,
      instanceInvitationToken: server.accountInvitation('switched@example.test'),
    );
    await idle(solo.app);
    final switchedAccount = solo.app.account!.accountId;
    final switchedActive = solo.app.activeVault?.id;
    final switchedVaults = solo.app.vaults.map((v) => v.id).toSet();
    expect(switchedVaults, isNot(contains(createdId)));

    solo.client.responseRelease!.complete();
    await expectLater(
      attempt,
      throwsA(isA<OperationScopeEndedException>().having((e) => e.serverCommitted, 'serverCommitted', isTrue)),
    );
    await idle(solo.app);
    expect(solo.app.account!.accountId, switchedAccount);
    expect(solo.app.vaults.map((v) => v.id).toSet(), switchedVaults, reason: 'no descriptor of the old account entered the new session');
    expect(solo.app.vaultKeyForTesting(createdId), isNull, reason: 'the generated key was not installed');
    expect(solo.app.activeVault?.id, switchedActive, reason: 'no selection or projection of the old Vault');
  });

  test('createVault: response held past sign-out alone installs nothing either', () async {
    final solo = await party(
      sodium,
      server.baseUrl,
      username: 'solo2@example.test',
      storagePrefix: 'solo2.',
      invitation: server.accountInvitation('solo2@example.test'),
    );
    solo.client.holdResponse((r) => _post(r, (p) => p == '/api/v1/vaults'));
    final attempt = solo.app.createVaultInScope('Held across sign-out');
    await solo.client.responseHeld!.future;
    final createdId = (jsonDecode(solo.client.heldRequestBody!) as Map)['vault_id'] as String;
    await solo.app.logout();
    solo.client.responseRelease!.complete();
    await expectLater(
      attempt,
      throwsA(isA<OperationScopeEndedException>().having((e) => e.serverCommitted, 'serverCommitted', isTrue)),
    );
    expect(solo.app.account, isNull);
    expect(solo.app.vaults.map((v) => v.id), isNot(contains(createdId)));
    expect(solo.app.vaultKeyForTesting(createdId), isNull);
    expect(solo.app.activeVault, isNull);
    // Honest: the same account sees the Vault the server created.
    await solo.app.login(username: 'solo2@example.test', password: realServerPassword);
    await idle(solo.app);
    expect(solo.app.vaults.map((v) => v.id), contains(createdId));
  });

  test('createVault: response held while the user selects away and back is not selected and gets no copies', () async {
    final plan = owner.service.planShare([owner.app.hosts.firstWhere((h) => h.id == h1.id)]);
    owner.client.holdResponse((r) => _post(r, (p) => p == '/api/v1/vaults'));
    final attempt = owner.service.createSharingVault(plan, 'ABA during creation');
    await owner.client.responseHeld!.future;
    final createdId = (jsonDecode(owner.client.heldRequestBody!) as Map)['vault_id'] as String;
    // A → B → A on the source while the committed response is held.
    await owner.app.selectVault(sharedVaultId);
    await owner.app.selectVault(sourceVaultId);
    owner.client.responseRelease!.complete();
    await expectLater(attempt, _code('scope_ended_committed'));
    expect(owner.app.activeVault?.id, sourceVaultId, reason: 'the user choice stays; the new Vault is not selected over it');
    expect(await hostsIn(owner.app, createdId), isEmpty, reason: 'no copy reached the new Vault');
    expect((await hostsIn(owner.app, sourceVaultId)).map((h) => h.id).toSet(), {h1.id, h2.id});
    await backToSource();
  });

  test('sharing: select-away-and-back while the copy push is held stops and restores nothing', () async {
    final plan = owner.service.planShare([owner.app.hosts.firstWhere((h) => h.id == h1.id)]);
    final before = vaultIds();
    owner.client.holdResponse((r) => _post(r, (p) => p.endsWith('/sync/push') && !p.contains(sourceVaultId)));
    final attempt = owner.service.createSharingVault(plan, 'ABA during push');
    await owner.client.responseHeld!.future;
    final target = vaultIds().difference(before).single;
    expect(owner.app.activeVault?.id, target);
    // A → B → A requested on the sharing Vault while its push answer is
    // held. (Switching away waits for the in-flight push of the retired
    // repository to drain, so the requests complete after the release.)
    final outcome = expectLater(attempt, _code('scope_ended_committed'));
    final away = owner.app.selectVault(sourceVaultId);
    final back = owner.app.selectVault(target);
    owner.client.requests.clear();
    owner.client.responseRelease!.complete();
    await away;
    await back;
    await outcome;
    await idle(owner.app);
    expect(
      owner.app.activeVault?.id,
      target,
      reason: 'the older source selection is not restored over the newer user choice',
    );
    await backToSource();
  });

  test('delivery: invitation answer held while the user selects another Vault — no delivery, no forced re-selection', () async {
    final (party_, card) = await grantee();
    await backToSource();
    owner.client.holdResponse((r) => _post(r, (p) => p == '/api/v1/vaults/$sharedVaultId/invitations'));
    final attempt = owner.service.deliverKey(vaultId: sharedVaultId, card: card, role: 'viewer');
    await owner.client.responseHeld!.future;
    expect(owner.client.heldResponseStatus, inInclusiveRange(200, 299), reason: 'the invitation was committed');
    expect(owner.app.activeVault?.id, sharedVaultId);
    await owner.app.selectVault(sourceVaultId);
    owner.client.requests.clear();
    owner.client.responseRelease!.complete();
    await expectLater(attempt, _code('scope_ended_committed'));
    await idle(owner.app);
    expect(owner.app.activeVault?.id, sourceVaultId, reason: 'the old Vault is not forced back into view');
    expect(owner.app.hosts.map((h) => h.id).toSet(), {h1.id, h2.id}, reason: 'the projection is still the source Vault');
    expect(owner.client.sent('POST', '/key-deliveries'), isFalse);
    expect(await party_.service.acceptDeliveries(), 0);
  });

  test('delivery: select-away-and-back while the invitation answer is held stops before delivery and keeps the newer choice', () async {
    final (party_, card) = await grantee();
    await backToSource();
    owner.client.holdResponse((r) => _post(r, (p) => p == '/api/v1/vaults/$sharedVaultId/invitations'));
    final attempt = owner.service.deliverKey(vaultId: sharedVaultId, card: card, role: 'viewer');
    await owner.client.responseHeld!.future;
    // A → B → A on the shared Vault.
    await owner.app.selectVault(sourceVaultId);
    await owner.app.selectVault(sharedVaultId);
    owner.client.requests.clear();
    owner.client.responseRelease!.complete();
    await expectLater(attempt, _code('scope_ended_committed'));
    await idle(owner.app);
    expect(owner.client.sent('POST', '/key-deliveries'), isFalse);
    expect(owner.app.activeVault?.id, sharedVaultId, reason: 'the older source choice is not restored over the newer one');
    expect(await party_.service.acceptDeliveries(), 0);
    await backToSource();
  });

  test('an undisturbed delivery still completes and returns to the source Vault', () async {
    final (party_, card) = await grantee();
    await backToSource();
    await owner.service.deliverKey(vaultId: sharedVaultId, card: card, role: 'viewer');
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect(await party_.service.acceptDeliveries(), 1);
    expect((await hostsIn(party_.app, sharedVaultId)).map((h) => h.name), ['H1']);
  });
}
