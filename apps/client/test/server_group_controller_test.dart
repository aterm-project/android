import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'support/l10n_fixture.dart';
import 'package:aterm_client/l10n/l10n.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _userId = '44444444-4444-4444-8444-444444444444';
const _rootId = '55555555-5555-4555-8555-555555555555';
const _childId = '66666666-6666-4666-8666-666666666666';
const _otherRootId = '77777777-7777-4777-8777-777777777777';
const _thirdId = '88888888-8888-4888-8888-888888888888';
const _revisionId = '99999999-9999-4999-8999-999999999999';
const _credentialOverrideId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _credentialMissingId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

String _routeId(int index) =>
    'aaaa1111-1111-4111-8111-${index.toString().padLeft(12, '0')}';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'create and edit Groups use encrypted records and revision CAS',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        await app.saveGroup(
          const GroupRecord(
            id: _rootId,
            name: '  Engineering  ',
            color: 0x4FC3F7,
          ),
        );
        expect(app.groups.single.name, 'Engineering');
        final rootStored = await database.encryptedRecord(_vaultId, _rootId);
        expect(rootStored, isNotNull);
        expect(rootStored!.envelopeJson, isNot(contains('Engineering')));
        final rootEnvelope =
            jsonDecode(rootStored.envelopeJson) as Map<String, dynamic>;
        final rootPlain = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: rootEnvelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(rootPlain['type'], 'group');
        expect(rootPlain['name'], 'Engineering');
        expect(rootPlain['parent_id'], isNull);

        await app.saveGroup(
          const GroupRecord(
            id: _childId,
            name: 'Production',
            parentId: _rootId,
          ),
        );
        final beforeEdit = await database.encryptedRecord(_vaultId, _childId);
        final beforeRevision = beforeEdit!.revisionId;

        await app.saveGroup(
          const GroupRecord(
            id: _childId,
            name: ' Production fleet ',
            color: 0x4DB6AC,
            parentId: _rootId,
          ),
        );

        final updated = app.groups.singleWhere((group) => group.id == _childId);
        expect(updated.name, 'Production fleet');
        expect(updated.color, 0x4DB6AC);
        final afterEdit = await database.encryptedRecord(_vaultId, _childId);
        expect(afterEdit!.revisionId, isNot(beforeRevision));
        final editedEnvelope =
            jsonDecode(afterEdit.envelopeJson) as Map<String, dynamic>;
        final editedHeader = editedEnvelope['header'] as Map<String, dynamic>;
        expect(editedHeader['base_revision_id'], beforeRevision);
        final editedPlain = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: editedEnvelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(editedPlain['name'], 'Production fleet');
        expect(editedPlain['parent_id'], _rootId);
        expect(await database.countPending(_vaultId), 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host port-forward profile edits enter the encrypted Vault sync outbox',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      const host = HostRecord(
        id: _thirdId,
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
      );
      const profile = SshPortForwardProfile(
        id: 'local-db',
        name: 'Private database',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 15432,
        destinationAddress: 'db.internal',
        destinationPort: 5432,
      );
      try {
        await app.saveHost(host);
        await app.saveHostPortForwardProfiles(
          hostId: host.id,
          profiles: const [profile],
        );

        expect(
          app.hosts.single.portForwardProfiles.single.toJson(),
          profile.toJson(),
        );
        expect(await database.countPending(_vaultId), 1);
        final stored = await database.encryptedRecord(_vaultId, host.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('db.internal')));
        expect(stored.envelopeJson, isNot(contains('Private database')));
        expect(stored.envelopeJson, isNot(contains('15432')));

        final envelope =
            jsonDecode(stored.envelopeJson) as Map<String, dynamic>;
        final opened = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(opened['port_forward_profiles'], [profile.toJson()]);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host editor rebases disjoint fields onto a sibling tab outbox head',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
      )..activeVault = app.activeVault;
      const original = HostRecord(
        id: _thirdId,
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
        tags: ['base'],
      );
      try {
        await app.saveHost(original);
        await _acknowledgeLocalCreate(database, _thirdId);
        await sibling.reloadRecords();
        final siblingEdit = sibling.hosts.single.copyWith(port: 2222);
        await sibling.saveHost(siblingEdit);
        final siblingHead = await database.encryptedRecord(_vaultId, _thirdId);
        expect(siblingHead, isNotNull);
        final siblingRevision = siblingHead!.revisionId;

        await app.saveHostFromEditor(
          original: original,
          edited: original.copyWith(tags: const ['primary', 'ops']),
        );

        final stored = await database.encryptedRecord(_vaultId, _thirdId);
        expect(stored, isNotNull);
        final envelope =
            jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
        final header = envelope['header'] as Map<String, dynamic>;
        expect(header['base_revision_id'], siblingRevision);
        final plaintext = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['port'], 2222);
        expect(plaintext['tags'], ['primary', 'ops']);
        expect(plaintext['name'], original.name);
        expect(await database.countPending(_vaultId), 2);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(2));
        final editorOperation = pending.singleWhere(
          (operation) => operation.baseRevisionId == siblingRevision,
        );
        expect(editorOperation.baseEnvelopeJson, siblingHead.envelopeJson);
      } finally {
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host editor retries its rebase when a sibling wins the local write race',
    () async {
      late AppController sibling;
      String? siblingRevision;
      var injectSiblingWrite = true;
      final fixture = await _fixture(
        sodium,
        beforeHostEditorSave: () async {
          if (!injectSiblingWrite) return;
          injectSiblingWrite = false;
          await sibling.saveHost(sibling.hosts.single.copyWith(port: 2222));
          siblingRevision = sibling.hosts.single.revisionId;
        },
      );
      final (app, database, _, identity, key) = fixture;
      sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: fixture.$3,
      )..activeVault = app.activeVault;
      const original = HostRecord(
        id: _thirdId,
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
        tags: ['base'],
      );
      try {
        await app.saveHost(original);
        await _acknowledgeLocalCreate(database, _thirdId);
        await sibling.reloadRecords();

        await app.saveHostFromEditor(
          original: original,
          edited: original.copyWith(tags: const ['primary']),
        );

        final stored = await database.encryptedRecord(_vaultId, _thirdId);
        expect(stored, isNotNull);
        final envelope =
            jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
        expect(siblingRevision, isNotNull);
        expect(
          (envelope['header'] as Map<String, dynamic>)['base_revision_id'],
          siblingRevision,
        );
        final plaintext = await fixture.$3.crypto.decryptRecord(
          vaultKey: key,
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['port'], 2222);
        expect(plaintext['tags'], ['primary']);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(2));
        final editorOperation = pending.singleWhere(
          (operation) => operation.baseRevisionId == siblingRevision,
        );
        expect(editorOperation.envelopeJson, stored.envelopeJson);
      } finally {
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'concurrent Jump Host edits atomically reject the second cycle and preserve outbox',
    () async {
      final hValidated = Completer<void>();
      final jValidated = Completer<void>();
      final releaseH = Completer<void>();
      final releaseJ = Completer<void>();
      var pauseH = true;
      var pauseJ = true;
      final fixture = await _fixture(
        sodium,
        beforeHostEditorSave: () async {
          if (!pauseH) return;
          pauseH = false;
          hValidated.complete();
          await releaseH.future;
        },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeHostEditorSaveForTesting: () async {
          if (!pauseJ) return;
          pauseJ = false;
          jValidated.complete();
          await releaseJ.future;
        },
      )..activeVault = app.activeVault;

      const h = HostRecord(
        id: _rootId,
        name: 'Host H',
        address: 'h.example.test',
        username: 'deploy',
      );
      const j = HostRecord(
        id: _thirdId,
        name: 'Host J',
        address: 'j.example.test',
        username: 'deploy',
      );
      try {
        await app.saveHost(h);
        await app.saveHost(j);
        await _acknowledgeLocalCreate(database, h.id);
        await _acknowledgeLocalCreate(database, j.id);
        await sibling.reloadRecords();

        final saveH = app.saveHostFromEditor(
          original: h,
          edited: h.copyWith(jumpHostId: j.id),
        );
        final saveJ = sibling.saveHostFromEditor(
          original: j,
          edited: j.copyWith(jumpHostId: h.id),
        );

        // Both validations observe the same acyclic graph before either write.
        await Future.wait([hValidated.future, jValidated.future]);
        releaseJ.complete();
        await saveJ;
        releaseH.complete();
        await expectLater(
          saveH,
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('循环'),
            ),
          ),
        );

        final rows = await repository.loadRecords();
        final hostsById = {
          for (final row in rows.where((row) => row['type'] == 'host'))
            row['_record_id'] as String: HostRecord.fromJson({
              ...row,
              'id': row['_record_id'],
              'revision_id': row['_revision_id'],
            }),
        };
        expect(hostsById[h.id]!.jumpHostId, isNull);
        expect(hostsById[j.id]!.jumpHostId, h.id);

        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, j.id);
        final pendingEnvelope =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        expect(
          (pendingEnvelope['header'] as Map<String, dynamic>)['operation'],
          'update',
        );
        expect(await database.countPending(_vaultId), 1);
      } finally {
        if (!releaseH.isCompleted) releaseH.complete();
        if (!releaseJ.isCompleted) releaseJ.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host Credential reference edit cannot race Credential deletion into a dangling reference',
    () async {
      final hostValidated = Completer<void>();
      final deleteValidated = Completer<void>();
      final releaseHost = Completer<void>();
      final releaseDelete = Completer<void>();
      var pauseHost = false;
      var pauseDelete = false;
      final fixture = await _fixture(
        sodium,
        beforeHostEditorSave: () async {
          if (!pauseHost) return;
          pauseHost = false;
          hostValidated.complete();
          await releaseHost.future;
        },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeVaultReferenceWriteForTesting:
            ({required recordId, required operation}) async {
              if (recordId != _credentialOverrideId ||
                  operation != 'delete' ||
                  !pauseDelete) {
                return;
              }
              pauseDelete = false;
              deleteValidated.complete();
              await releaseDelete.future;
            },
      )..activeVault = app.activeVault;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Host edit race credential',
        username: 'deploy',
        secret: 'host-edit-race-password',
      );
      const host = HostRecord(
        id: _thirdId,
        name: 'Host reference race',
        address: 'reference-race.example.test',
        username: 'deploy',
      );
      try {
        await app.saveCredential(credential);
        await app.saveHost(host);
        await _acknowledgeLocalCreate(database, credential.id);
        await _acknowledgeLocalCreate(database, host.id);
        await sibling.reloadRecords();

        pauseHost = true;
        pauseDelete = true;
        final editHost = app.saveHostFromEditor(
          original: host,
          edited: host.copyWith(credentialId: credential.id),
        );
        final deleteCredential = sibling.deleteCredential(credential);
        await Future.wait([hostValidated.future, deleteValidated.future]);

        // The delete wins its whole-head CAS. The Host editor rereads the
        // current catalog and refuses to create a reference to its tombstone.
        releaseDelete.complete();
        await deleteCredential;
        releaseHost.complete();
        await expectLater(
          editHost,
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('SSH 凭据已不存在'),
            ),
          ),
        );

        final rows = await repository.loadRecords();
        final storedHost = HostRecord.fromJson(
          rows.singleWhere((row) => row['_record_id'] == host.id),
        );
        expect(storedHost.credentialId, isNull);
        final credentialRow = await database.encryptedRecord(
          _vaultId,
          credential.id,
        );
        expect(credentialRow, isNotNull);
        expect(credentialRow!.isDeleted, isTrue);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, credential.id);
      } finally {
        if (!releaseHost.isCompleted) releaseHost.complete();
        if (!releaseDelete.isCompleted) releaseDelete.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host Group reference edit cannot race Group deletion into a dangling reference',
    () async {
      final hostValidated = Completer<void>();
      final deleteValidated = Completer<void>();
      final releaseHost = Completer<void>();
      final releaseDelete = Completer<void>();
      var pauseHost = false;
      var pauseDelete = false;
      final fixture = await _fixture(
        sodium,
        beforeHostEditorSave: () async {
          if (!pauseHost) return;
          pauseHost = false;
          hostValidated.complete();
          await releaseHost.future;
        },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeVaultReferenceWriteForTesting:
            ({required recordId, required operation}) async {
              if (recordId != _rootId ||
                  operation != 'delete' ||
                  !pauseDelete) {
                return;
              }
              pauseDelete = false;
              deleteValidated.complete();
              await releaseDelete.future;
            },
      )..activeVault = app.activeVault;
      const group = GroupRecord(id: _rootId, name: 'Host edit race group');
      const host = HostRecord(
        id: _thirdId,
        name: 'Host group reference race',
        address: 'group-reference-race.example.test',
        username: 'deploy',
      );
      try {
        await app.saveGroup(group);
        await app.saveHost(host);
        await _acknowledgeLocalCreate(database, group.id);
        await _acknowledgeLocalCreate(database, host.id);
        await sibling.reloadRecords();

        pauseHost = true;
        pauseDelete = true;
        final editHost = app.saveHostFromEditor(
          original: host,
          edited: host.copyWith(groupId: group.id),
        );
        final deleteGroup = sibling.deleteGroup(group);
        await Future.wait([hostValidated.future, deleteValidated.future]);

        releaseDelete.complete();
        await deleteGroup;
        releaseHost.complete();
        await expectLater(
          editHost,
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('分组已不存在'),
            ),
          ),
        );

        final rows = await repository.loadRecords();
        final storedHost = HostRecord.fromJson(
          rows.singleWhere((row) => row['_record_id'] == host.id),
        );
        expect(storedHost.groupId, isNull);
        final groupRow = await database.encryptedRecord(_vaultId, group.id);
        expect(groupRow, isNotNull);
        expect(groupRow!.isDeleted, isTrue);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, group.id);
      } finally {
        if (!releaseHost.isCompleted) releaseHost.complete();
        if (!releaseDelete.isCompleted) releaseDelete.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('Host favorite action rebases onto a sibling-tab local edit', () async {
    final fixture = await _fixture(sodium);
    final (app, database, repository, identity, key) = fixture;
    final sibling = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
      repositoryForTesting: repository,
    )..activeVault = app.activeVault;
    const original = HostRecord(
      id: _thirdId,
      name: 'Development host',
      address: 'ssh.example.test',
      username: 'developer',
      tags: ['base'],
    );
    try {
      await app.saveHost(original);
      await _acknowledgeLocalCreate(database, _thirdId);
      await sibling.reloadRecords();
      await sibling.saveHost(
        sibling.hosts.single.copyWith(tags: const ['sibling-edit']),
      );
      final siblingHead = await database.encryptedRecord(_vaultId, _thirdId);
      expect(siblingHead, isNotNull);

      await app.saveHostFromEditor(
        original: original,
        edited: original.copyWith(isFavorite: true),
      );

      final stored = await database.encryptedRecord(_vaultId, _thirdId);
      expect(stored, isNotNull);
      final envelope = jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
      expect(
        (envelope['header'] as Map<String, dynamic>)['base_revision_id'],
        siblingHead!.revisionId,
      );
      final plaintext = await repository.crypto.decryptRecord(
        vaultKey: key,
        envelope: envelope,
        authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
      );
      expect(plaintext['tags'], ['sibling-edit']);
      expect(plaintext['is_favorite'], isTrue);
      final pending = await database.queuedOperations(_vaultId);
      expect(pending, hasLength(2));
      final favoriteOperation = pending.singleWhere(
        (operation) => operation.baseRevisionId == siblingHead.revisionId,
      );
      expect(favoriteOperation.baseEnvelopeJson, siblingHead.envelopeJson);
    } finally {
      sibling.dispose();
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  testWidgets(
    'Favorite action updates its same-page card before status refresh completes',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _fixture(sodium, blockRefresh: true);
      final (app, database, _, identity, key) = fixture;
      final blockingApp = app as _RefreshBlockingGroupApp;
      const host = HostRecord(
        id: _thirdId,
        name: 'Favorite UI host',
        address: 'favorite-ui.example.test',
        username: 'developer',
      );
      app
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts;
      try {
        await app.saveHost(host);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip(currentL10n.favorite), findsOneWidget);

        blockingApp.blockNextRefresh = true;
        await tester.tap(find.byTooltip(currentL10n.favorite));
        await blockingApp.refreshStarted.future.timeout(
          const Duration(seconds: 10),
        );
        await tester.pump();

        expect(app.hosts.single.isFavorite, isTrue);
        expect(find.byTooltip(currentL10n.removeFavorite), findsOneWidget);
        expect(find.byTooltip(currentL10n.favorite), findsNothing);

        blockingApp.refreshGate.complete();
        await tester.pumpAndSettle();
      } finally {
        if (!blockingApp.refreshGate.isCompleted) {
          blockingApp.refreshGate.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host editor requires review when both tabs change the same field',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: fixture.$3,
      )..activeVault = app.activeVault;
      const original = HostRecord(
        id: _thirdId,
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
      );
      try {
        await app.saveHost(original);
        await sibling.reloadRecords();
        await sibling.saveHost(
          sibling.hosts.single.copyWith(name: 'Sibling name'),
        );
        final siblingHead = await database.encryptedRecord(_vaultId, _thirdId);
        expect(siblingHead, isNotNull);
        final siblingRevision = siblingHead!.revisionId;

        await expectLater(
          app.saveHostFromEditor(
            original: original,
            edited: original.copyWith(name: 'Editor name'),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('也被修改'),
            ),
          ),
        );
        final afterRejectedSave = await database.encryptedRecord(
          _vaultId,
          _thirdId,
        );
        expect(afterRejectedSave!.revisionId, siblingRevision);
      } finally {
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host editor accepts an identical same-field edit from another tab',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: fixture.$3,
      )..activeVault = app.activeVault;
      const original = HostRecord(
        id: _thirdId,
        name: 'Development host',
        address: 'ssh.example.test',
        username: 'developer',
      );
      try {
        await app.saveHost(original);
        await sibling.reloadRecords();
        await sibling.saveHost(
          sibling.hosts.single.copyWith(name: 'Shared name'),
        );
        final siblingHead = await database.encryptedRecord(_vaultId, _thirdId);
        expect(siblingHead, isNotNull);

        await app.saveHostFromEditor(
          original: original,
          edited: original.copyWith(name: 'Shared name'),
        );

        final stored = await database.encryptedRecord(_vaultId, _thirdId);
        expect(stored, isNotNull);
        final envelope =
            jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
        expect(
          (envelope['header'] as Map<String, dynamic>)['base_revision_id'],
          siblingHead!.revisionId,
        );
        final plaintext = await fixture.$3.crypto.decryptRecord(
          vaultKey: key,
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['name'], 'Shared name');
      } finally {
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('Host editor fails closed on deleted and corrupt local heads', () async {
    final fixture = await _fixture(sodium);
    final (app, database, _, identity, key) = fixture;
    const deletedHost = HostRecord(
      id: _thirdId,
      name: 'Deleted host',
      address: 'deleted.example.test',
      username: 'developer',
    );
    const unreadableHost = HostRecord(
      id: _otherRootId,
      name: 'Unreadable host',
      address: 'unreadable.example.test',
      username: 'developer',
    );
    try {
      await app.saveHost(deletedHost);
      await app.saveHost(unreadableHost);
      await app.deleteHost(deletedHost);
      final tombstone = await database.encryptedRecord(_vaultId, _thirdId);
      expect(tombstone?.isDeleted, isTrue);

      await expectLater(
        app.saveHostFromEditor(
          original: deletedHost,
          edited: deletedHost.copyWith(tags: const ['must-not-restore']),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('已不存在'),
          ),
        ),
      );

      await database.customStatement(
        'UPDATE encrypted_records SET revision_id = ? WHERE vault_id = ? AND record_id = ?',
        [_revisionId, _vaultId, _otherRootId],
      );
      final corruptEnvelope = await database.encryptedRecord(
        _vaultId,
        _otherRootId,
      );
      expect(corruptEnvelope, isNotNull);
      final envelopeBeforeRejectedSave = corruptEnvelope!.envelopeJson;
      await expectLater(
        app.saveHostFromEditor(
          original: unreadableHost,
          edited: unreadableHost.copyWith(tags: const ['must-not-overwrite']),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('无法验证'),
          ),
        ),
      );
      expect(
        (await database.encryptedRecord(_vaultId, _otherRootId))?.envelopeJson,
        envelopeBeforeRejectedSave,
      );
      expect(fixture.$3.unavailableRecordIds, contains(_otherRootId));
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'Host editor rejects jump-route validation with unreadable graph rows',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      const original = HostRecord(
        id: _thirdId,
        name: 'Target host',
        address: 'target.example.test',
        username: 'developer',
      );
      const jumpCandidate = HostRecord(
        id: _rootId,
        name: 'Jump host',
        address: 'jump.example.test',
        username: 'developer',
      );
      const unreadable = HostRecord(
        id: _otherRootId,
        name: 'Unreadable graph row',
        address: 'unreadable.example.test',
        username: 'developer',
      );
      try {
        await app.saveHost(original);
        await app.saveHost(jumpCandidate);
        await app.saveHost(unreadable);
        final originalHead = await database.encryptedRecord(
          _vaultId,
          original.id,
        );
        expect(originalHead, isNotNull);

        await database.customStatement(
          'UPDATE encrypted_records SET revision_id = ? WHERE vault_id = ? AND record_id = ?',
          [_revisionId, _vaultId, unreadable.id],
        );

        await expectLater(
          app.saveHostFromEditor(
            original: original,
            edited: original.copyWith(jumpHostId: jumpCandidate.id),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('无法验证'),
            ),
          ),
        );
        expect(
          (await database.encryptedRecord(_vaultId, original.id))?.revisionId,
          originalHead!.revisionId,
        );
        expect(fixture.$3.unavailableRecordIds, contains(unreadable.id));
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'validates normalized sibling names, parent references, and cycles',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      app.groups.addAll(const [
        GroupRecord(id: _rootId, name: 'Engineering'),
        GroupRecord(id: _childId, name: 'Production', parentId: _rootId),
        GroupRecord(id: _otherRootId, name: 'Research'),
      ]);
      try {
        expect(
          app.validateGroup(
            const GroupRecord(id: _thirdId, name: '  ENGINEERING  '),
          ),
          contains('同一父级'),
        );
        expect(
          app.validateGroup(
            const GroupRecord(
              id: _thirdId,
              name: 'Engineering',
              parentId: _otherRootId,
            ),
          ),
          isNull,
        );
        expect(
          app.validateGroup(
            const GroupRecord(
              id: _rootId,
              name: 'Engineering',
              parentId: _childId,
            ),
          ),
          contains('自身或其子分组'),
        );
        expect(
          app.validateGroup(
            const GroupRecord(
              id: _thirdId,
              name: 'Detached',
              parentId: _thirdId,
            ),
          ),
          contains('自身或其子分组'),
        );
        expect(
          app.validateGroup(
            const GroupRecord(
              id: _thirdId,
              name: 'Detached',
              parentId: '99999999-9999-4999-8999-999999999999',
            ),
          ),
          contains('已不存在'),
        );
        expect(
          app.canUseGroupAsParent(groupId: _rootId, parentId: _childId),
          isFalse,
        );
        expect(
          app.canUseGroupAsParent(groupId: _thirdId, parentId: _rootId),
          isTrue,
        );
        expect(await database.countPending(_vaultId), 0);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'rejects deleting Groups while Hosts or child Groups reference them',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      try {
        await app.saveGroup(const GroupRecord(id: _rootId, name: 'Root'));
        await app.saveGroup(
          const GroupRecord(id: _childId, name: 'Child', parentId: _rootId),
        );
        const host = HostRecord(
          id: _thirdId,
          name: 'Production host',
          address: 'prod.example.test',
          username: 'deploy',
          groupId: _childId,
        );
        await app.saveHost(host);
        final pendingBeforeReject = await database.countPending(_vaultId);

        await expectLater(
          app.deleteGroup(
            app.groups.singleWhere((group) => group.id == _rootId),
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          app.deleteGroup(
            app.groups.singleWhere((group) => group.id == _childId),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await database.countPending(_vaultId), pendingBeforeReject);
        expect(app.groups, hasLength(2));

        await app.saveHost(
          const HostRecord(
            id: _thirdId,
            name: 'Production host',
            address: 'prod.example.test',
            username: 'deploy',
          ),
        );
        await app.deleteGroup(
          app.groups.singleWhere((group) => group.id == _childId),
        );
        await app.deleteGroup(
          app.groups.singleWhere((group) => group.id == _rootId),
        );

        expect(app.groups, isEmpty);
        expect(await database.countPending(_vaultId), 3);
        final deletedRoot = await database.encryptedRecord(_vaultId, _rootId);
        expect(deletedRoot, isNotNull);
        final envelope =
            jsonDecode(deletedRoot!.envelopeJson) as Map<String, dynamic>;
        final plain = await fixture.$3.crypto.decryptRecord(
          vaultKey: key,
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plain['deleted'], isTrue);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Group deletion CAS rejects a concurrent child Group reference creation',
    () async {
      final childValidated = Completer<void>();
      final deleteValidated = Completer<void>();
      final releaseChild = Completer<void>();
      final releaseDelete = Completer<void>();
      var pauseChild = false;
      var pauseDelete = false;
      final fixture = await _fixture(
        sodium,
        beforeVaultReferenceWrite:
            ({required recordId, required operation}) async {
              if (recordId != _childId ||
                  operation != 'create' ||
                  !pauseChild) {
                return;
              }
              pauseChild = false;
              childValidated.complete();
              await releaseChild.future;
            },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeVaultReferenceWriteForTesting:
            ({required recordId, required operation}) async {
              if (recordId != _rootId ||
                  operation != 'delete' ||
                  !pauseDelete) {
                return;
              }
              pauseDelete = false;
              deleteValidated.complete();
              await releaseDelete.future;
            },
      )..activeVault = app.activeVault;
      const root = GroupRecord(id: _rootId, name: 'Parent race root');
      const child = GroupRecord(
        id: _childId,
        name: 'Concurrent child',
        parentId: _rootId,
      );
      try {
        await app.saveGroup(root);
        await _acknowledgeLocalCreate(database, root.id);
        await sibling.reloadRecords();

        pauseChild = true;
        pauseDelete = true;
        final saveChild = app.saveGroup(child);
        final deleteRoot = sibling.deleteGroup(root);
        await Future.wait([childValidated.future, deleteValidated.future]);

        releaseDelete.complete();
        await deleteRoot;
        releaseChild.complete();
        await expectLater(
          saveChild,
          throwsA(isA<LocalRecordHeadChangedException>()),
        );

        final rootRow = await database.encryptedRecord(_vaultId, root.id);
        expect(rootRow, isNotNull);
        expect(rootRow!.isDeleted, isTrue);
        expect(await database.encryptedRecord(_vaultId, child.id), isNull);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, root.id);
      } finally {
        if (!releaseChild.isCompleted) releaseChild.complete();
        if (!releaseDelete.isCompleted) releaseDelete.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('Group deletion rejects a stale cached target revision', () async {
    final fixture = await _fixture(sodium);
    final (app, database, _, identity, key) = fixture;
    final sibling = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
      repositoryForTesting: fixture.$3,
    )..activeVault = app.activeVault;
    const group = GroupRecord(id: _rootId, name: 'Stale delete target');
    try {
      await app.saveGroup(group);
      await _acknowledgeLocalCreate(database, group.id);
      await sibling.reloadRecords();

      await app.saveGroup(
        const GroupRecord(id: _rootId, name: 'Updated delete target'),
      );
      await expectLater(
        sibling.deleteGroup(sibling.groups.single),
        throwsA(isA<LocalRecordHeadChangedException>()),
      );

      final row = await database.encryptedRecord(_vaultId, group.id);
      expect(row, isNotNull);
      expect(row!.isDeleted, isFalse);
      final rows = await fixture.$3.loadRecords();
      expect(
        GroupRecord.fromJson(
          rows.singleWhere((row) => row['id'] == group.id),
        ).name,
        'Updated delete target',
      );
      final pending = await database.queuedOperations(_vaultId);
      expect(pending, hasLength(1));
      expect(pending.single.recordId, group.id);
    } finally {
      sibling.dispose();
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'read-only and deleting Vaults reject Group writes and tombstones',
    () async {
      final fixture = await _fixture(sodium, canWrite: false);
      final (app, database, _, identity, key) = fixture;
      try {
        const group = GroupRecord(id: _rootId, name: 'Read-only group');
        await expectLater(app.saveGroup(group), throwsA(isA<StateError>()));
        await expectLater(app.deleteGroup(group), throwsA(isA<StateError>()));
        expect(await database.countPending(_vaultId), 0);

        app.activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          status: 'deleting',
          canWrite: true,
        );
        await expectLater(app.saveGroup(group), throwsA(isA<StateError>()));
        await expectLater(app.deleteGroup(group), throwsA(isA<StateError>()));
        expect(await database.countPending(_vaultId), 0);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'a failed local save leaves the Group unchanged and can be retried',
    () async {
      final fixture = await _fixture(sodium, failFirstSave: true);
      final (app, database, _, identity, key) = fixture;
      try {
        const group = GroupRecord(id: _rootId, name: 'Retry group');
        await expectLater(app.saveGroup(group), throwsA(isA<StateError>()));
        expect(app.groups, isEmpty);
        expect(await database.countPending(_vaultId), 0);

        await app.saveGroup(group);
        expect(app.groups.single.name, 'Retry group');
        expect(await database.countPending(_vaultId), 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Group save and delete stay successful if status refresh fails',
    () async {
      final fixture = await _fixture(sodium, failRefresh: true);
      final (app, database, _, identity, key) = fixture;
      try {
        const group = GroupRecord(id: _rootId, name: 'Queued group');
        await app.saveGroup(group);
        expect(app.groups.single.name, 'Queued group');
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);

        (app as _RefreshFailingGroupApp).failNextRefresh = true;
        await app.deleteGroup(group);
        expect(app.groups, isEmpty);
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);
        final tombstone = await database.encryptedRecord(_vaultId, _rootId);
        expect(tombstone, isNotNull);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host save and delete stay successful if status refresh fails',
    () async {
      final fixture = await _fixture(sodium, failRefresh: true);
      final (app, database, _, identity, key) = fixture;
      const host = HostRecord(
        id: _thirdId,
        name: 'Queued host',
        address: 'queued.example.test',
        username: 'deploy',
      );
      try {
        await app.saveHost(host);
        expect(app.hosts.single.name, 'Queued host');
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);

        (app as _RefreshFailingGroupApp).failNextRefresh = true;
        await app.deleteHost(host);
        expect(app.hosts, isEmpty);
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);
        final tombstone = await database.encryptedRecord(_vaultId, _thirdId);
        expect(tombstone, isNotNull);
        final envelope =
            jsonDecode(tombstone!.envelopeJson) as Map<String, dynamic>;
        expect(
          (envelope['header'] as Map<String, dynamic>)['operation'],
          'delete',
        );
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Credential save and delete stay successful if status refresh fails',
    () async {
      final fixture = await _fixture(sodium, failRefresh: true);
      final (app, database, _, identity, key) = fixture;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Queued credential',
        username: 'deploy',
        secret: 'ephemeral-secret',
      );
      try {
        await app.saveCredential(credential);
        expect(app.credentials.single.name, 'Queued credential');
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);

        (app as _RefreshFailingGroupApp).failNextRefresh = true;
        await app.deleteCredential(credential);
        expect(app.credentials, isEmpty);
        expect(app.noticeMessage, contains('本地待同步队列'));
        expect(await database.countPending(_vaultId), 1);
        final tombstone = await database.encryptedRecord(
          _vaultId,
          _credentialOverrideId,
        );
        expect(tombstone, isNotNull);
        final envelope =
            jsonDecode(tombstone!.envelopeJson) as Map<String, dynamic>;
        expect(
          (envelope['header'] as Map<String, dynamic>)['operation'],
          'delete',
        );
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('Host save invalidates an earlier in-flight record snapshot', () async {
    final staleRows = Completer<List<Map<String, dynamic>>>();
    final loadStarted = Completer<void>();
    final fixture = await _fixture(
      sodium,
      loadRows: (_) {
        loadStarted.complete();
        return staleRows.future;
      },
    );
    final (app, database, _, identity, key) = fixture;
    const host = HostRecord(
      id: _thirdId,
      name: 'Fresh Host',
      address: 'fresh.example.test',
      username: 'deploy',
    );
    try {
      final staleReload = app.reloadRecords();
      await loadStarted.future;
      await app.saveHost(host);

      staleRows.complete(const []);
      await staleReload;

      expect(app.hosts, hasLength(1));
      expect(app.hosts.single.name, 'Fresh Host');
      expect(await database.countPending(_vaultId), 1);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'Host save rejects dangling Group ids and accepts unassigned Hosts',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      try {
        const dangling = HostRecord(
          id: _thirdId,
          name: 'Host',
          address: 'host.example.test',
          username: 'deploy',
          groupId: _rootId,
        );
        await expectLater(
          app.saveHost(dangling),
          throwsA(isA<FormatException>()),
        );
        expect(await database.countPending(_vaultId), 0);

        await app.saveHost(
          const HostRecord(
            id: _thirdId,
            name: 'Host',
            address: 'host.example.test',
            username: 'deploy',
          ),
        );
        expect(app.hosts.single.groupId, isNull);
        expect(await database.countPending(_vaultId), 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'full reload surfaces a remote dangling Host Group ref and explicit repair queues one update',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      const remoteHost = HostRecord(
        id: _thirdId,
        name: 'Remote orphan Host',
        address: 'orphan.example.test',
        username: 'deploy',
        groupId: _rootId,
      );
      try {
        // Seed a valid encrypted record as if it had already been committed by
        // another device. The AppController has not loaded it yet.
        await repository.saveRecord(
          recordId: remoteHost.id,
          plaintext: remoteHost.toJson(),
          operation: 'create',
        );
        await _acknowledgeLocalCreate(database, remoteHost.id);
        final storedBeforeReload = await database.encryptedRecord(
          _vaultId,
          remoteHost.id,
        );
        expect(storedBeforeReload, isNotNull);
        final ciphertextBeforeReload = storedBeforeReload!.envelopeJson;
        expect(await database.countPending(_vaultId), 0);
        expect(app.hostGroupReferenceIssueCount, 0);
        expect(app.hostsNeedingGroupRepair, isEmpty);

        await app.reloadRecords();

        expect(app.hosts, hasLength(1));
        expect(app.hostGroupReferenceIssueCount, 1);
        expect(
          app.hostGroupReferenceIssueForHost(remoteHost.id),
          contains(_rootId),
        );
        expect(app.hostsNeedingGroupRepair.single.id, remoteHost.id);
        expect(
          (await database.encryptedRecord(
            _vaultId,
            remoteHost.id,
          ))!.envelopeJson,
          ciphertextBeforeReload,
        );
        expect(await database.countPending(_vaultId), 0);

        final loadedHost = app.hosts.single;
        await app.saveHostFromEditor(
          original: loadedHost,
          edited: HostRecord.fromJson({
            ...loadedHost.toJson(),
            'group_id': null,
          }),
        );

        expect(app.hosts.single.groupId, isNull);
        expect(app.hostGroupReferenceIssueCount, 0);
        expect(app.hostGroupReferenceIssueForHost(remoteHost.id), isNull);
        final pending = await database.allPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, remoteHost.id);
        final updateEnvelope =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        final updateHeader = updateEnvelope['header'] as Map<String, dynamic>;
        expect(updateHeader['operation'], 'update');
        expect(updateHeader['base_revision_id'], storedBeforeReload.revisionId);
        final updatedCiphertext = (await database.encryptedRecord(
          _vaultId,
          remoteHost.id,
        ))!;
        expect(updatedCiphertext.envelopeJson, isNot(ciphertextBeforeReload));
        final updatedPlaintext = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope:
              jsonDecode(updatedCiphertext.envelopeJson)
                  as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(updatedPlaintext['group_id'], isNull);

        await app.reloadRecords();
        expect(app.hostGroupReferenceIssueCount, 0);
        expect(app.hostGroupReferenceIssueForHost(remoteHost.id), isNull);
        expect(await database.countPending(_vaultId), 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host Group diagnostics wait for a complete out-of-order record snapshot',
    () async {
      final pendingRows = Completer<List<Map<String, dynamic>>>();
      final loadStarted = Completer<void>();
      final fixture = await _fixture(
        sodium,
        loadRows: (_) {
          if (!loadStarted.isCompleted) loadStarted.complete();
          return pendingRows.future;
        },
      );
      final (app, database, repository, identity, key) = fixture;
      const remoteGroup = GroupRecord(id: _rootId, name: 'Remote group');
      const remoteHost = HostRecord(
        id: _thirdId,
        name: 'Remote Host',
        address: 'remote.example.test',
        username: 'deploy',
        groupId: _rootId,
      );
      try {
        await repository.saveRecord(
          recordId: remoteGroup.id,
          plaintext: remoteGroup.toJson(),
          operation: 'create',
        );
        await repository.saveRecord(
          recordId: remoteHost.id,
          plaintext: remoteHost.toJson(),
          operation: 'create',
        );
        final completeRows = await repository.loadRecords();
        completeRows.sort((left, right) {
          final leftRank = left['type'] == 'host' ? 0 : 1;
          final rightRank = right['type'] == 'host' ? 0 : 1;
          return leftRank.compareTo(rightRank);
        });
        final issueCountsOnNotify = <int>[];
        app.addListener(() {
          issueCountsOnNotify.add(app.hostGroupReferenceIssueCount);
        });

        final reload = app.reloadRecords();
        await loadStarted.future;
        expect(app.hosts, isEmpty);
        expect(app.groups, isEmpty);
        expect(app.hostGroupReferenceIssueCount, 0);
        expect(app.hostsNeedingGroupRepair, isEmpty);

        // The full cache snapshot intentionally puts the Host before its
        // Group, like a paginated feed where the related Group arrives later.
        // reloadRecords publishes only after it has projected all rows.
        pendingRows.complete(completeRows);
        await reload;

        expect(app.hosts, hasLength(1));
        expect(app.groups, hasLength(1));
        expect(app.hostGroupReferenceIssueCount, 0);
        expect(app.hostGroupReferenceIssueForHost(remoteHost.id), isNull);
        expect(issueCountsOnNotify, isNotEmpty);
        expect(issueCountsOnNotify, everyElement(0));
      } finally {
        if (!pendingRows.isCompleted) pendingRows.complete(const []);
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host Group diagnostics distinguish unreadable Group records from missing Groups',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      const hostWithUnreadableGroup = HostRecord(
        id: _thirdId,
        name: 'Unreadable Group Host',
        address: 'unreadable.example.test',
        username: 'deploy',
        groupId: _rootId,
      );
      const hostWithMissingGroup = HostRecord(
        id: _otherRootId,
        name: 'Missing Group Host',
        address: 'missing.example.test',
        username: 'deploy',
        groupId: _childId,
      );
      try {
        await repository.saveRecord(
          recordId: _rootId,
          plaintext: const {'id': _rootId, 'type': 'group', 'name': 12},
          operation: 'create',
        );
        await repository.saveRecord(
          recordId: hostWithUnreadableGroup.id,
          plaintext: hostWithUnreadableGroup.toJson(),
          operation: 'create',
        );
        await repository.saveRecord(
          recordId: hostWithMissingGroup.id,
          plaintext: hostWithMissingGroup.toJson(),
          operation: 'create',
        );

        await app.reloadRecords();

        expect(app.unavailableRecordCount, 1);
        expect(app.hosts, hasLength(2));
        expect(
          app.hostGroupReferenceIssueForHost(hostWithUnreadableGroup.id),
          isNull,
        );
        expect(
          app.hostGroupReferenceIssueForHost(hostWithMissingGroup.id),
          contains(_childId),
        );
        expect(app.hostGroupReferenceIssueCount, 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('Host Jump Host references permit bounded acyclic chains', () async {
    final fixture = await _fixture(sodium);
    final (app, database, repository, identity, key) = fixture;
    try {
      const bastion = HostRecord(
        id: _rootId,
        name: 'Bastion',
        address: 'bastion.example.test',
        username: 'relay',
      );
      await app.saveHost(bastion);

      const selfReference = HostRecord(
        id: _thirdId,
        name: 'Self reference',
        address: 'self.example.test',
        username: 'deploy',
        jumpHostId: _thirdId,
      );
      const missingReference = HostRecord(
        id: _thirdId,
        name: 'Missing jump',
        address: 'missing.example.test',
        username: 'deploy',
        jumpHostId: _credentialMissingId,
      );
      expect(app.validateHostReferences(selfReference), contains('自身'));
      expect(app.validateHostReferences(missingReference), contains('不存在'));
      await expectLater(
        app.saveHost(selfReference),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        app.saveHost(missingReference),
        throwsA(isA<FormatException>()),
      );

      const oneHop = HostRecord(
        id: _childId,
        name: 'First hop',
        address: 'first-hop.example.test',
        username: 'deploy',
        jumpHostId: _rootId,
      );
      await app.saveHost(oneHop);
      await app.saveHost(
        const HostRecord(
          id: _credentialOverrideId,
          name: 'Alternate bastion',
          address: 'alternate-bastion.example.test',
          username: 'relay',
        ),
      );
      final nestedBastionUpdate = bastion.copyWith(
        jumpHostId: _credentialOverrideId,
      );
      expect(app.validateHostReferences(nestedBastionUpdate), isNull);
      await app.saveHost(nestedBastionUpdate);
      const nestedReference = HostRecord(
        id: _otherRootId,
        name: 'Nested jump',
        address: 'nested.example.test',
        username: 'deploy',
        jumpHostId: _childId,
      );
      expect(app.validateHostReferences(nestedReference), isNull);
      await app.saveHost(nestedReference);
      const cycle = HostRecord(
        id: _credentialOverrideId,
        name: 'Alternate bastion',
        address: 'alternate-bastion.example.test',
        username: 'relay',
        jumpHostId: _otherRootId,
      );
      expect(app.validateHostReferences(cycle), contains('循环'));

      const target = HostRecord(
        id: _thirdId,
        name: 'Target',
        address: 'target.example.test',
        username: 'deploy',
        jumpHostId: _rootId,
      );
      await app.saveHost(target);
      final stored = await database.encryptedRecord(_vaultId, _thirdId);
      final envelope = jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
      final plaintext = await repository.crypto.decryptRecord(
        vaultKey: key,
        envelope: envelope,
        authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
      );
      expect(plaintext['jump_host_id'], _rootId);
      expect(await database.countPending(_vaultId), 5);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test('Host Jump Host chain depth is limited to eight', () async {
    final fixture = await _fixture(sodium);
    final (app, database, _, identity, key) = fixture;
    try {
      final routeHosts = <HostRecord>[
        for (var index = 0; index < maxJumpHostHops; index++)
          HostRecord(
            id: _routeId(index),
            name: 'Hop $index',
            address: 'hop-$index.example.test',
            jumpHostId: index == 0 ? null : _routeId(index - 1),
          ),
      ];
      app.hosts.addAll(routeHosts);
      final eightHops = HostRecord(
        id: _routeId(maxJumpHostHops),
        name: 'Eight hops',
        address: 'eight-hops.example.test',
        jumpHostId: _routeId(maxJumpHostHops - 1),
      );
      expect(app.validateHostReferences(eightHops), isNull);
      app.hosts.add(eightHops);
      final nineHops = HostRecord(
        id: _routeId(maxJumpHostHops + 1),
        name: 'Nine hops',
        address: 'nine-hops.example.test',
        jumpHostId: eightHops.id,
      );
      expect(app.validateHostReferences(nineHops), contains('最多支持 8 层'));
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'full Vault reload marks only malformed Jump Host branches and preserves ciphertext',
    () async {
      var connectorCalls = 0;
      final fixture = await _fixture(
        sodium,
        sshConnectorForTesting:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async {
              connectorCalls++;
              throw StateError('invalid route reached the SSH connector');
            },
      );
      final (app, database, repository, identity, key) = fixture;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Route credential',
        username: 'deploy',
        secret: 'ephemeral-test-secret',
      );
      final goodId = _routeId(100);
      final missingId = _routeId(101);
      final missingChildId = _routeId(102);
      final selfId = _routeId(103);
      final cycleAId = _routeId(104);
      final cycleBId = _routeId(105);
      final deepTargetId = _routeId(106);
      final depthHostIds = [
        for (var index = 0; index < maxJumpHostHops + 1; index++)
          _routeId(120 + index),
      ];
      HostRecord makeHost(String id, {String? jumpHostId}) => HostRecord(
        id: id,
        name: 'Route $id',
        address: '$id.example.test',
        username: 'deploy',
        credentialId: credential.id,
        jumpHostId: jumpHostId,
      );

      try {
        await app.saveCredential(credential);
        final remoteHosts = <HostRecord>[
          makeHost(goodId),
          makeHost(missingId, jumpHostId: _routeId(999)),
          makeHost(missingChildId, jumpHostId: missingId),
          makeHost(selfId, jumpHostId: selfId),
          makeHost(cycleAId, jumpHostId: cycleBId),
          makeHost(cycleBId, jumpHostId: cycleAId),
          makeHost(deepTargetId, jumpHostId: depthHostIds.first),
          for (var index = 0; index < depthHostIds.length; index++)
            makeHost(
              depthHostIds[index],
              jumpHostId: index + 1 < depthHostIds.length
                  ? depthHostIds[index + 1]
                  : null,
            ),
        ];
        for (final host in remoteHosts) {
          await repository.saveRecord(
            recordId: host.id,
            plaintext: host.toJson(),
          );
        }
        final ciphertextBeforeReload = (await database.encryptedRecord(
          _vaultId,
          missingId,
        ))!.envelopeJson;
        final pendingBeforeReload = await database.countPending(_vaultId);

        await app.reloadRecords();

        expect(app.hosts, hasLength(remoteHosts.length));
        expect(app.jumpHostRouteIssueForHost(goodId), isNull);
        expect(app.jumpHostRouteIssueForHost(depthHostIds.first), isNull);
        expect(app.jumpHostRouteIssueForHost(missingId), contains('不存在'));
        expect(app.jumpHostRouteIssueForHost(missingChildId), contains('不存在'));
        expect(app.jumpHostRouteIssueForHost(selfId), contains('自身'));
        expect(app.jumpHostRouteIssueForHost(cycleAId), contains('循环'));
        expect(app.jumpHostRouteIssueForHost(cycleBId), contains('循环'));
        expect(
          app.jumpHostRouteIssueForHost(deepTargetId),
          contains('最多支持 8 层'),
        );
        expect(app.jumpHostRouteIssueCount, 6);
        expect(
          app.validateHostReferences(
            app.hosts.singleWhere((host) => host.id == goodId),
          ),
          isNull,
        );
        expect(
          (await database.encryptedRecord(_vaultId, missingId))!.envelopeJson,
          ciphertextBeforeReload,
        );
        expect(await database.countPending(_vaultId), pendingBeforeReload);

        await expectLater(
          app.openTerminalTab(
            app.hosts.singleWhere((host) => host.id == missingId),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => '$error',
              'message',
              contains('不存在'),
            ),
          ),
        );
        expect(connectorCalls, 0);

        final repaired = app.hosts
            .singleWhere((host) => host.id == missingId)
            .copyWith(clearJumpHost: true);
        await app.saveHost(repaired);
        expect(app.jumpHostRouteIssueForHost(missingId), isNull);
        expect(app.jumpHostRouteIssueForHost(missingChildId), isNull);

        await app.reloadRecords();
        expect(app.jumpHostRouteIssueForHost(missingId), isNull);
        expect(app.jumpHostRouteIssueForHost(missingChildId), isNull);
        expect(app.jumpHostRouteIssueForHost(selfId), contains('自身'));
        expect(app.jumpHostRouteIssueCount, 4);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Snippet credential references are authenticated and block Credential deletion',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Snippet credential',
        username: 'deploy',
        secret: 'snippet-password',
      );
      const host = HostRecord(
        id: _thirdId,
        name: 'Credential host',
        address: 'credential.example.test',
        username: 'deploy',
        credentialId: _credentialOverrideId,
      );
      const group = GroupRecord(
        id: _rootId,
        name: 'Credential group',
        defaultCredentialId: _credentialOverrideId,
      );
      const snippet = SnippetRecord(
        id: 'eeee1111-1111-4111-8111-000000000001',
        title: 'Use credential secret',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'printf',
        arguments: [SnippetArgument.reference('secret')],
        parameters: [
          SnippetParameter.credential(
            name: 'secret',
            credentialId: _credentialOverrideId,
          ),
        ],
      );
      try {
        await app.saveCredential(credential);
        await app.saveHost(host);
        await app.saveGroup(group);
        await app.saveSnippet(snippet);

        await expectLater(
          app.deleteCredential(credential),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('1 个分组默认值'),
                contains('1 个主机覆盖'),
                contains('1 个片段密钥参数'),
              ),
            ),
          ),
        );
        final credentialRow = await database.encryptedRecord(
          _vaultId,
          credential.id,
        );
        expect(credentialRow, isNotNull);
        expect(credentialRow!.isDeleted, isFalse);
        expect(await database.countPending(_vaultId), 4);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Snippet Credential create and Credential delete race cannot leave a dangling reference',
    () async {
      final snippetValidated = Completer<void>();
      final deleteValidated = Completer<void>();
      final releaseSnippet = Completer<void>();
      final releaseDelete = Completer<void>();
      var pauseSnippet = true;
      var pauseDelete = true;
      final fixture = await _fixture(
        sodium,
        beforeVaultReferenceWrite:
            ({required recordId, required operation}) async {
              if (recordId != 'eeee1111-1111-4111-8111-000000000002' ||
                  operation != 'create' ||
                  !pauseSnippet) {
                return;
              }
              pauseSnippet = false;
              snippetValidated.complete();
              await releaseSnippet.future;
            },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeVaultReferenceWriteForTesting:
            ({required recordId, required operation}) async {
              if (recordId != _credentialOverrideId ||
                  operation != 'delete' ||
                  !pauseDelete) {
                return;
              }
              pauseDelete = false;
              deleteValidated.complete();
              await releaseDelete.future;
            },
      )..activeVault = app.activeVault;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Race credential',
        username: 'deploy',
        secret: 'race-password',
      );
      const snippet = SnippetRecord(
        id: 'eeee1111-1111-4111-8111-000000000002',
        title: 'Race reference',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'printf',
        arguments: [SnippetArgument.reference('secret')],
        parameters: [
          SnippetParameter.credential(
            name: 'secret',
            credentialId: _credentialOverrideId,
          ),
        ],
      );
      try {
        await app.saveCredential(credential);
        await _acknowledgeLocalCreate(database, credential.id);
        await sibling.reloadRecords();

        final saveSnippet = app.saveSnippet(snippet);
        final deleteCredential = sibling.deleteCredential(credential);
        await Future.wait([snippetValidated.future, deleteValidated.future]);

        releaseSnippet.complete();
        await saveSnippet;
        releaseDelete.complete();
        await expectLater(
          deleteCredential,
          throwsA(isA<LocalRecordHeadChangedException>()),
        );

        final credentialRow = await database.encryptedRecord(
          _vaultId,
          credential.id,
        );
        expect(credentialRow, isNotNull);
        expect(credentialRow!.isDeleted, isFalse);
        final rows = await repository.loadRecords();
        final savedSnippet = rows.singleWhere(
          (row) => row['_record_id'] == snippet.id,
        );
        expect(savedSnippet['parameters'], [
          {
            'name': 'secret',
            'type': 'credentialSecret',
            'credential_id': credential.id,
          },
        ]);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, snippet.id);
        expect(await database.countPending(_vaultId), 1);
      } finally {
        if (!releaseSnippet.isCompleted) releaseSnippet.complete();
        if (!releaseDelete.isCompleted) releaseDelete.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Group rejects a default Credential reference that is not active',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      const group = GroupRecord(
        id: _rootId,
        name: 'Missing credential reference',
        defaultCredentialId: _credentialMissingId,
      );
      try {
        await expectLater(
          app.saveGroup(group),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('默认 SSH 凭据已不存在'),
            ),
          ),
        );
        expect(await database.countPending(_vaultId), 0);
        expect(await database.encryptedRecord(_vaultId, group.id), isNull);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Group default Credential create and Credential delete race cannot leave a dangling reference',
    () async {
      final groupValidated = Completer<void>();
      final deleteValidated = Completer<void>();
      final releaseGroup = Completer<void>();
      final releaseDelete = Completer<void>();
      var pauseGroup = true;
      var pauseDelete = true;
      final fixture = await _fixture(
        sodium,
        beforeVaultReferenceWrite:
            ({required recordId, required operation}) async {
              if (recordId != _rootId || operation != 'create' || !pauseGroup) {
                return;
              }
              pauseGroup = false;
              groupValidated.complete();
              await releaseGroup.future;
            },
      );
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
        beforeVaultReferenceWriteForTesting:
            ({required recordId, required operation}) async {
              if (recordId != _credentialOverrideId ||
                  operation != 'delete' ||
                  !pauseDelete) {
                return;
              }
              pauseDelete = false;
              deleteValidated.complete();
              await releaseDelete.future;
            },
      )..activeVault = app.activeVault;
      const credential = CredentialRecord(
        id: _credentialOverrideId,
        name: 'Group race credential',
        username: 'deploy',
        secret: 'group-race-password',
      );
      const group = GroupRecord(
        id: _rootId,
        name: 'Credential default race',
        defaultCredentialId: _credentialOverrideId,
      );
      try {
        await app.saveCredential(credential);
        await _acknowledgeLocalCreate(database, credential.id);
        await sibling.reloadRecords();

        final saveGroup = app.saveGroup(group);
        final deleteCredential = sibling.deleteCredential(credential);
        await Future.wait([groupValidated.future, deleteValidated.future]);

        releaseGroup.complete();
        await saveGroup;
        releaseDelete.complete();
        await expectLater(
          deleteCredential,
          throwsA(isA<LocalRecordHeadChangedException>()),
        );

        final credentialRow = await database.encryptedRecord(
          _vaultId,
          credential.id,
        );
        expect(credentialRow, isNotNull);
        expect(credentialRow!.isDeleted, isFalse);
        final rows = await repository.loadRecords();
        final savedGroup = rows.singleWhere(
          (row) => row['_record_id'] == group.id,
        );
        expect(savedGroup['default_credential_id'], credential.id);
        final pending = await database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.recordId, group.id);
        expect(await database.countPending(_vaultId), 1);
      } finally {
        if (!releaseGroup.isCompleted) releaseGroup.complete();
        if (!releaseDelete.isCompleted) releaseDelete.complete();
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saveGroup rejects an edited Group whose cached head became stale',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      final sibling = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        repositoryForTesting: repository,
      )..activeVault = app.activeVault;
      const initial = GroupRecord(id: _rootId, name: 'Initial group');
      const editedBySibling = GroupRecord(id: _rootId, name: 'Newer group');
      const staleEdit = GroupRecord(id: _rootId, name: 'Stale group');
      try {
        await app.saveGroup(initial);
        await sibling.reloadRecords();
        await app.saveGroup(editedBySibling);

        await expectLater(
          sibling.saveGroup(staleEdit),
          throwsA(isA<LocalRecordHeadChangedException>()),
        );
        final rows = await repository.loadRecords();
        expect(rows.single['name'], 'Newer group');
        expect(await database.countPending(_vaultId), 1);
      } finally {
        sibling.dispose();
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saveSnippet rejects credential references that are not active records',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      const snippet = SnippetRecord(
        id: 'eeee1111-1111-4111-8111-000000000003',
        title: 'Missing credential reference',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'printf',
        arguments: [SnippetArgument.reference('secret')],
        parameters: [
          SnippetParameter.credential(
            name: 'secret',
            credentialId: _credentialOverrideId,
          ),
        ],
      );
      try {
        await expectLater(
          app.saveSnippet(snippet),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('不存在或不可用'),
            ),
          ),
        );
        expect(await database.countPending(_vaultId), 0);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'Host deletion protects Jump Host references until they are cleared',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, _, identity, key) = fixture;
      try {
        const bastion = HostRecord(
          id: _rootId,
          name: 'Bastion',
          address: 'bastion.example.test',
          username: 'relay',
        );
        const target = HostRecord(
          id: _childId,
          name: 'Target',
          address: 'target.example.test',
          username: 'deploy',
          jumpHostId: _rootId,
        );
        await app.saveHost(bastion);
        await app.saveHost(target);
        final pendingBeforeDelete = await database.countPending(_vaultId);

        await expectLater(
          app.deleteHost(bastion),
          throwsA(isA<FormatException>()),
        );
        expect(await database.countPending(_vaultId), pendingBeforeDelete);
        expect(app.hosts.map((host) => host.id), contains(_rootId));

        await app.saveHost(target.copyWith(clearJumpHost: true));
        await app.deleteHost(bastion);
        expect(app.hosts.map((host) => host.id), [_childId]);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('locked and read-only Vaults reject Host relation mutations', () async {
    final readOnlyFixture = await _fixture(sodium, canWrite: false);
    final (readOnly, database, _, identity, key) = readOnlyFixture;
    try {
      const host = HostRecord(
        id: _rootId,
        name: 'Viewer Host',
        address: 'viewer.example.test',
        username: 'reader',
      );
      readOnly.hosts.add(host);
      await expectLater(readOnly.saveHost(host), throwsA(isA<StateError>()));
      await expectLater(readOnly.deleteHost(host), throwsA(isA<StateError>()));
      expect(await database.countPending(_vaultId), 0);
    } finally {
      readOnly.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }

    final lockedDatabase = ClientDatabase.forTesting(NativeDatabase.memory());
    final locked = AppController(
      sodium: sodium,
      database: lockedDatabase,
      secureStore: ClientSecureStore(),
    );
    try {
      const host = HostRecord(
        id: _rootId,
        name: 'Locked Host',
        address: 'locked.example.test',
        username: 'reader',
      );
      await expectLater(locked.saveHost(host), throwsA(isA<StateError>()));
      await expectLater(locked.deleteHost(host), throwsA(isA<StateError>()));
    } finally {
      locked.dispose();
      await lockedDatabase.close();
    }
  });

  test(
    'reload quarantines malformed and unsupported rows and keeps valid rows',
    () async {
      final fixture = await _fixture(
        sodium,
        loadRows: (_) async => [
          {
            ...const GroupRecord(id: _rootId, name: 'Valid before').toJson(),
            '_record_id': _rootId,
            '_revision_id': _revisionId,
          },
          {
            ...const GroupRecord(id: _childId, name: 'Valid after').toJson(),
            '_record_id': _childId,
            '_revision_id': _revisionId,
            'name': 12,
          },
          {
            'id': _thirdId,
            'type': 'futureRecordKind',
            '_record_id': _thirdId,
            '_revision_id': _revisionId,
          },
          {
            ...const GroupRecord(
              id: _otherRootId,
              name: 'Still valid',
            ).toJson(),
            '_record_id': _otherRootId,
            '_revision_id': _revisionId,
          },
        ],
      );
      final (app, database, _, identity, key) = fixture;
      app.groups.add(const GroupRecord(id: _thirdId, name: 'Old catalog'));
      try {
        await app.reloadRecords();
        expect(app.groups.map((group) => group.name), [
          'Valid before',
          'Still valid',
        ]);
        expect(app.unavailableRecordCount, 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );
}

Future<void> _acknowledgeLocalCreate(
  ClientDatabase database,
  String recordId,
) async {
  final stored = await database.encryptedRecord(_vaultId, recordId);
  if (stored == null) throw StateError('Test Host was not stored.');
  final envelope = jsonDecode(stored.envelopeJson) as Map<String, dynamic>;
  final header = envelope['header'] as Map<String, dynamic>;
  await database.markCommitted(
    opId: header['op_id'] as String,
    commitSeq: '1',
    authenticatedEventEnvelope: envelope,
  );
}

Future<
  (AppController, ClientDatabase, SyncRepository, DeviceIdentity, Uint8List)
>
_fixture(
  SodiumSumo sodium, {
  bool canWrite = true,
  bool failFirstSave = false,
  bool failRefresh = false,
  bool blockRefresh = false,
  Future<List<Map<String, dynamic>>> Function(SyncRepository)? loadRows,
  Future<void> Function()? beforeHostEditorSave,
  Future<void> Function({required String recordId, required String operation})?
  beforeVaultReferenceWrite,
  SshConnectorForTesting? sshConnectorForTesting,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final key = sodium.randombytes.buf(32);
  final api = _GroupApi(identity);
  final repositoryBase = SyncRepository(
    api: api,
    database: database,
    crypto: VaultCrypto(sodium),
    identity: identity,
    serverSpaceId: _serverSpaceId,
    instanceId: _instanceId,
    vaultId: _vaultId,
    keyEpoch: '1',
    membershipVersion: '1',
    serverGeneration: '1',
    vaultKey: key,
    canWrite: canWrite,
  );
  final repository = failFirstSave
      ? _FailFirstSaveGroupRepository(
          api: api,
          database: database,
          crypto: repositoryBase.crypto,
          identity: identity,
          serverSpaceId: _serverSpaceId,
          instanceId: _instanceId,
          vaultId: _vaultId,
          keyEpoch: '1',
          membershipVersion: '1',
          serverGeneration: '1',
          vaultKey: key,
          canWrite: canWrite,
        )
      : repositoryBase;
  final app =
      (blockRefresh
            ? _RefreshBlockingGroupApp(
                sodium: sodium,
                database: database,
                secureStore: ClientSecureStore(),
                repositoryForTesting: repository,
                loadRecordsForTesting: loadRows,
                beforeHostEditorSaveForTesting: beforeHostEditorSave,
                beforeVaultReferenceWriteForTesting: beforeVaultReferenceWrite,
                sshConnectorForTesting: sshConnectorForTesting,
              )
            : failRefresh
            ? _RefreshFailingGroupApp(
                sodium: sodium,
                database: database,
                secureStore: ClientSecureStore(),
                repositoryForTesting: repository,
                loadRecordsForTesting: loadRows,
                beforeHostEditorSaveForTesting: beforeHostEditorSave,
                beforeVaultReferenceWriteForTesting: beforeVaultReferenceWrite,
                sshConnectorForTesting: sshConnectorForTesting,
              )
            : AppController(
                sodium: sodium,
                database: database,
                secureStore: ClientSecureStore(),
                repositoryForTesting: repository,
                loadRecordsForTesting: loadRows,
                beforeHostEditorSaveForTesting: beforeHostEditorSave,
                beforeVaultReferenceWriteForTesting: beforeVaultReferenceWrite,
                sshConnectorForTesting: sshConnectorForTesting,
              ))
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database, repository, identity, key);
}

class _RefreshFailingGroupApp extends AppController {
  _RefreshFailingGroupApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required super.repositoryForTesting,
    super.loadRecordsForTesting,
    super.beforeHostEditorSaveForTesting,
    super.beforeVaultReferenceWriteForTesting,
    super.sshConnectorForTesting,
  });

  bool failNextRefresh = true;

  @override
  Future<void> refreshSyncStatus({bool keepStatus = false}) {
    if (failNextRefresh) {
      failNextRefresh = false;
      throw StateError('synthetic status refresh failure');
    }
    return super.refreshSyncStatus(keepStatus: keepStatus);
  }
}

class _RefreshBlockingGroupApp extends AppController {
  _RefreshBlockingGroupApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required super.repositoryForTesting,
    super.loadRecordsForTesting,
    super.beforeHostEditorSaveForTesting,
    super.beforeVaultReferenceWriteForTesting,
    super.sshConnectorForTesting,
  });

  final refreshStarted = Completer<void>();
  final refreshGate = Completer<void>();
  bool blockNextRefresh = false;

  @override
  Future<void> refreshSyncStatus({bool keepStatus = false}) {
    if (blockNextRefresh) {
      blockNextRefresh = false;
      refreshStarted.complete();
      return refreshGate.future;
    }
    return super.refreshSyncStatus(keepStatus: keepStatus);
  }
}

class _GroupApi extends ApiClient {
  _GroupApi(this.identity) : super(baseUrl: 'https://group.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _userId,
    'signing_public_key': identity.signingPublicKey,
    'status': 'active',
  };

  @override
  Future<List<Map<String, dynamic>>> devices() async => [_device];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    _device,
  ];
}

class _FailFirstSaveGroupRepository extends SyncRepository {
  _FailFirstSaveGroupRepository({
    required super.api,
    required super.database,
    required super.crypto,
    required super.identity,
    required super.serverSpaceId,
    required super.instanceId,
    required super.vaultId,
    required super.keyEpoch,
    required super.membershipVersion,
    required super.serverGeneration,
    required super.vaultKey,
    required super.canWrite,
  });

  bool _fail = true;

  @override
  Future<Map<String, Object?>> saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) {
    if (_fail) {
      _fail = false;
      throw StateError('synthetic storage failure');
    }
    return super.saveRecord(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain,
      operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    );
  }
}
