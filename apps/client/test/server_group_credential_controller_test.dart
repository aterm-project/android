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
import 'package:sodium/sodium_sumo.dart';

const _rootGroupId = '11111111-1111-4111-8111-111111111111';
const _childGroupId = '22222222-2222-4222-8222-222222222222';
const _leafGroupId = '33333333-3333-4333-8333-333333333333';
const _orphanGroupId = '44444444-4444-4444-8444-444444444444';
const _cycleGroupId = '55555555-5555-4555-8555-555555555555';
const _hostId = '66666666-6666-4666-8666-666666666666';
const _rootCredentialId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _childCredentialId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _overrideCredentialId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _missingCredentialId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _serverSpaceId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _instanceId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const _vaultId = '99999999-9999-4999-8999-999999999999';
const _userId = '88888888-8888-4888-8888-888888888888';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'Host override wins and inheritance uses the nearest Group default',
    () async {
      final (app, database) = await _makeController(sodium);
      app
        ..credentials.addAll(const [
          CredentialRecord(
            id: _rootCredentialId,
            name: 'Root credential',
            username: 'root-user',
            secret: 'root-secret',
          ),
          CredentialRecord(
            id: _childCredentialId,
            name: 'Child credential',
            username: 'child-user',
            secret: 'child-secret',
          ),
          CredentialRecord(
            id: _overrideCredentialId,
            name: 'Host override',
            username: 'host-user',
            secret: 'override-secret',
          ),
        ])
        ..groups.addAll(const [
          GroupRecord(
            id: _rootGroupId,
            name: 'Root',
            defaultCredentialId: _rootCredentialId,
          ),
          GroupRecord(
            id: _childGroupId,
            name: 'Child',
            parentId: _rootGroupId,
            defaultCredentialId: _childCredentialId,
          ),
          GroupRecord(id: _leafGroupId, name: 'Leaf', parentId: _childGroupId),
        ]);

      try {
        final child = app.resolveHostCredential(
          groupId: _childGroupId,
          hostCredentialId: null,
        );
        expect(child.credential?.id, _childCredentialId);
        expect(child.source, HostCredentialSource.groupDefault);
        expect(child.sourceGroupId, _childGroupId);

        final leaf = app.resolveHostCredential(
          groupId: _leafGroupId,
          hostCredentialId: null,
        );
        expect(leaf.credential?.id, _childCredentialId);
        expect(leaf.sourceGroupName, 'Child');

        final override = app.resolveHostCredential(
          groupId: _childGroupId,
          hostCredentialId: _overrideCredentialId,
        );
        expect(override.credential?.id, _overrideCredentialId);
        expect(override.source, HostCredentialSource.hostOverride);
        expect(override.displayText, contains('Host override'));
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'stale references and broken inheritance chains do not fall through',
    () async {
      final (app, database) = await _makeController(sodium);
      app
        ..credentials.add(
          const CredentialRecord(
            id: _rootCredentialId,
            name: 'Root credential',
            username: 'root-user',
            secret: 'root-secret',
          ),
        )
        ..groups.addAll(const [
          GroupRecord(
            id: _rootGroupId,
            name: 'Root',
            defaultCredentialId: _rootCredentialId,
          ),
          GroupRecord(
            id: _childGroupId,
            name: 'Stale child',
            parentId: _rootGroupId,
            defaultCredentialId: _missingCredentialId,
          ),
          GroupRecord(
            id: _orphanGroupId,
            name: 'Orphan',
            parentId: _cycleGroupId,
          ),
          GroupRecord(
            id: _cycleGroupId,
            name: 'Cycle',
            parentId: _orphanGroupId,
          ),
        ]);

      try {
        final staleOverride = app.resolveHostCredential(
          groupId: _childGroupId,
          hostCredentialId: _missingCredentialId,
        );
        expect(staleOverride.source, HostCredentialSource.hostOverride);
        expect(staleOverride.hasStaleReference, isTrue);
        expect(staleOverride.credentialId, _missingCredentialId);
        expect(
          staleOverride.displayText,
          contains('Host override is unavailable'),
        );

        final staleDefault = app.resolveHostCredential(
          groupId: _childGroupId,
          hostCredentialId: null,
        );
        expect(staleDefault.source, HostCredentialSource.groupDefault);
        expect(staleDefault.credentialId, _missingCredentialId);
        expect(staleDefault.hasStaleReference, isTrue);

        final missingParent = app.resolveHostCredential(
          groupId: _hostId,
          hostCredentialId: null,
        );
        expect(missingParent.hasStaleReference, isTrue);
        expect(missingParent.missingGroupId, _hostId);

        final cycle = app.resolveHostCredential(
          groupId: _cycleGroupId,
          hostCredentialId: null,
        );
        expect(cycle.hasStaleReference, isTrue);

        await expectLater(
          app.openTerminalTab(
            const HostRecord(
              id: _hostId,
              name: 'Host',
              address: 'host.example.test',
              username: 'deploy',
              groupId: _childGroupId,
              credentialId: _missingCredentialId,
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('effective SSH credential is unavailable'),
            ),
          ),
        );
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  test(
    'Group and Host references must exist and protect Credential deletion',
    () async {
      final (app, database, identity, key) =
          await _makeControllerWithRepository(sodium);
      const credential = CredentialRecord(
        id: _rootCredentialId,
        name: 'Default credential',
        username: 'deploy',
        secret: 'ephemeral-secret',
      );
      try {
        await app.saveCredential(credential);
        expect(
          app.validateGroup(
            const GroupRecord(
              id: _rootGroupId,
              name: 'Root',
              defaultCredentialId: _missingCredentialId,
            ),
          ),
          contains('no longer exists'),
        );

        await expectLater(
          app.saveGroup(
            const GroupRecord(
              id: _rootGroupId,
              name: 'Root',
              defaultCredentialId: _missingCredentialId,
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          app.saveHost(
            const HostRecord(
              id: _hostId,
              name: 'Host',
              address: 'host.example.test',
              username: 'deploy',
              credentialId: _missingCredentialId,
            ),
          ),
          throwsA(isA<FormatException>()),
        );

        await app.saveGroup(
          const GroupRecord(
            id: _rootGroupId,
            name: 'Root',
            defaultCredentialId: _rootCredentialId,
          ),
        );
        await expectLater(
          app.deleteCredential(credential),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(contains('group default'), contains('host override')),
            ),
          ),
        );
        expect(app.credentials.single.id, _rootCredentialId);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('read-only Vault blocks Group default changes', () async {
    final (app, database) = await _makeController(sodium, canWrite: false);
    try {
      await expectLater(
        app.saveGroup(
          const GroupRecord(
            id: _rootGroupId,
            name: 'Root',
            defaultCredentialId: _rootCredentialId,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      app.dispose();
      await database.close();
    }
  });
}

Future<(AppController, ClientDatabase)> _makeController(
  SodiumSumo sodium, {
  bool canWrite = true,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..activeVault = VaultDescriptor(
          id: '77777777-7777-4777-8777-777777777777',
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database);
}

Future<(AppController, ClientDatabase, DeviceIdentity, Uint8List)>
_makeControllerWithRepository(SodiumSumo sodium) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final key = sodium.randombytes.buf(32);
  final api = _ControllerApi(identity);
  final repository = SyncRepository(
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
    canWrite: true,
  );
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          repositoryForTesting: repository,
        )
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: true,
        );
  return (app, database, identity, key);
}

class _ControllerApi extends ApiClient {
  _ControllerApi(this.identity)
    : super(baseUrl: 'https://group-credential.test');

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
