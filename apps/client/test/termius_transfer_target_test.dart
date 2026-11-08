import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultA = '33333333-3333-4333-8333-333333333333';
const _vaultB = '33333333-3333-4333-8333-3333333333bb';
const _userId = '44444444-4444-4444-8444-444444444444';
const _blockerGroupId = '55555555-5555-4555-8555-555555555555';
const _header = 'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password';

const _key =
    '-----BEGIN OPENSSH PRIVATE KEY-----\nc3ludGhldGlj\n-----END OPENSSH PRIVATE KEY-----\n';
const _cert =
    'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t synthetic';

class _PassThroughCertificates implements TermiusCertificateBridge {
  @override
  String? certificateOf(CredentialRecord credential) => null;

  @override
  CredentialRecord withCertificate(
    CredentialRecord credential,
    String certificate,
  ) => credential;
}

int _ids = 0;
String _id() =>
    '60000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

typedef _SaveHook =
    Future<void> Function(
      SyncRepository repository,
      String recordId,
      String operation,
    );

class _HookedRepository extends SyncRepository {
  _HookedRepository({
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

  _SaveHook? beforeSave;
  _SaveHook? afterCommit;
  final writes = <String>[];

  /// Writes that bypass [beforeSave] (used to simulate another tab).
  Future<Map<String, Object?>> rawSave({
    required String recordId,
    required Map<String, Object?> plaintext,
    required String baseRevisionId,
  }) => super.saveRecord(
    recordId: recordId,
    plaintext: plaintext,
    baseRevisionId: baseRevisionId,
    expectedCachedHeadRevisionId: baseRevisionId,
    operation: 'update',
  );

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
  }) async {
    await beforeSave?.call(this, recordId, operation);
    writes.add('$operation:$recordId');
    final envelope = await super.saveRecord(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain,
      operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    );
    await afterCommit?.call(this, recordId, operation);
    return envelope;
  }
}

class _Api extends ApiClient {
  _Api(this.identity) : super(baseUrl: 'https://termius-target.test');

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

class _Fixture {
  _Fixture(
    this.app,
    this.database,
    this.repositoryA,
    this.repositoryB,
    this.identity,
    this.keys,
    this.hookGate,
  );

  final AppController app;
  final ClientDatabase database;
  final _HookedRepository repositoryA;
  final _HookedRepository repositoryB;
  final DeviceIdentity identity;
  final List<Uint8List> keys;
  Completer<void>? Function() hookGate;

  Future<void> dispose() async {
    app.dispose();
    identity.dispose();
    for (final key in keys) {
      key.fillRange(0, key.length, 0);
    }
    await database.close();
  }
}

VaultDescriptor _vault(String id) => VaultDescriptor(
  id: id,
  role: 'owner',
  activeKeyEpoch: '1',
  membershipVersion: '1',
);

Future<_Fixture> _fixture(
  SodiumSumo sodium, {
  Completer<void>? referenceGate,
  Completer<void>? referenceEntered,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final api = _Api(identity);
  final keyA = sodium.randombytes.buf(32);
  final keyB = sodium.randombytes.buf(32);
  _HookedRepository repository(String vaultId, Uint8List key) =>
      _HookedRepository(
        api: api,
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        serverSpaceId: _serverSpaceId,
        instanceId: _instanceId,
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: '1',
        vaultKey: key,
        canWrite: true,
      );
  final repositoryA = repository(_vaultA, keyA);
  final repositoryB = repository(_vaultB, keyB);
  final app = AppController(
    sodium: sodium,
    database: database,
    secureStore: ClientSecureStore(),
    repositoryForTesting: repositoryA,
    beforeVaultReferenceWriteForTesting:
        ({required String recordId, required String operation}) async {
          if (recordId != _blockerGroupId) return;
          referenceEntered?.complete();
          await referenceGate?.future;
        },
  )..activeVault = _vault(_vaultA);
  return _Fixture(
    app,
    database,
    repositoryA,
    repositoryB,
    identity,
    [keyA, keyB],
    () => referenceGate,
  );
}

Future<TermiusImportPlan> _plan(
  TermiusTransferTarget target,
  List<String> rows,
) async => TermiusImportPlanner.plan(
  TermiusCsvImporter.parse([_header, ...rows].join('\n')),
  await target.loadCatalog(),
  newId: _id,
);

void main() {
  useAppLocaleFixture('en');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('cloud apply creates groups, hosts and attached credentials', () async {
    final fixture = await _fixture(sodium);
    try {
      final target = CloudTermiusTransferTarget(fixture.app);
      final plan = await _plan(target, [
        'Project/Dev,web,a,w.example,ssh,22,alice,"  spaced  "',
        ',db,,d.example,ssh,2200,bob,',
      ]);
      final report = await target.apply(plan);
      expect(report.createdHosts, 2);
      expect(report.createdGroups, 2);
      final web = fixture.app.hosts.singleWhere((host) => host.name == 'web');
      expect(web.login?.password, '  spaced  ');
      final dev = fixture.app.groups.singleWhere((g) => g.id == web.groupId);
      expect(dev.name, 'Dev');
      expect(
        fixture.app.groups.singleWhere((g) => g.id == dev.parentId).name,
        'Project',
      );
      final stored = await fixture.repositoryA.loadRecord(web.id);
      expect(stored?['login'], isA<Map<dynamic, dynamic>>());
      // A second apply of the same (now stale) plan writes nothing.
      final writes = fixture.repositoryA.writes.length;
      await expectLater(
        target.apply(plan),
        throwsA(
          isA<TermiusApplyException>().having(
            (e) => e.failure,
            'failure',
            TermiusApplyFailure.stalePlan,
          ),
        ),
      );
      expect(fixture.repositoryA.writes, hasLength(writes));
    } finally {
      await fixture.dispose();
    }
  });

  for (final withGroup in [false, true]) {
    test(
      'P2: queued ${withGroup ? 'group' : 'host'} write never lands in a '
      'newly selected Vault',
      () async {
        final gate = Completer<void>();
        final entered = Completer<void>();
        final fixture = await _fixture(
          sodium,
          referenceGate: gate,
          referenceEntered: entered,
        );
        try {
          final target = CloudTermiusTransferTarget(fixture.app);
          final plan = await _plan(target, [
            '${withGroup ? 'Imported' : ''},queued,,q.example,ssh,22,u,pw',
          ]);
          // Block the controller mutation queue with an unrelated Group save.
          final blocker = fixture.app.saveGroup(
            const GroupRecord(id: _blockerGroupId, name: 'Blocker'),
          );
          await entered.future;
          final apply = target.apply(plan);
          // Let apply pass its pre-checks and enqueue its first write.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          fixture.app.replaceRecordScopeForTesting(
            repository: fixture.repositoryB,
            vault: _vault(_vaultB),
          );
          gate.complete();
          await expectLater(blocker, throwsA(anything));
          final error = await apply.then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          expect(error, isA<TermiusApplyException>());
          expect(
            (error! as TermiusApplyException).failure,
            TermiusApplyFailure.contextChanged,
          );
          // ZERO writes reached the new scope, and none reached the old one.
          expect(fixture.repositoryB.writes, isEmpty);
          expect(
            fixture.repositoryA.writes.where((w) => !w.endsWith(_blockerGroupId)),
            isEmpty,
          );
          expect(await fixture.database.countPending(_vaultB), 0);
          for (final group in plan.newGroups) {
            expect(await fixture.database.encryptedRecord(_vaultB, group.id), isNull);
            expect(await fixture.database.encryptedRecord(_vaultA, group.id), isNull);
          }
          for (final host in plan.hostsToCreate) {
            expect(await fixture.database.encryptedRecord(_vaultB, host.id), isNull);
            expect(await fixture.database.encryptedRecord(_vaultA, host.id), isNull);
          }
        } finally {
          if (!gate.isCompleted) gate.complete();
          await fixture.dispose();
        }
      },
    );
  }

  test('rollback removes created records when nothing else changed them', () async {
    final fixture = await _fixture(sodium);
    try {
      final target = CloudTermiusTransferTarget(fixture.app);
      final plan = await _plan(target, [
        'G,first,,f.example,ssh,22,u,',
        'G,second,,s.example,ssh,22,u,',
      ]);
      final second = plan.hostsToCreate.singleWhere((h) => h.name == 'second');
      fixture.repositoryA.beforeSave = (repository, recordId, operation) async {
        if (recordId == second.id && operation == 'create') {
          throw StateError('synthetic storage failure');
        }
      };
      final error = await target.apply(plan).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(error, isA<TermiusApplyException>());
      final failure = error! as TermiusApplyException;
      expect(failure.failure, TermiusApplyFailure.writeFailed);
      expect(failure.rolledBack, isTrue);
      expect(failure.writtenHosts, 1);
      expect(failure.writtenGroups, 1);
      final first = plan.hostsToCreate.singleWhere((h) => h.name == 'first');
      expect(await fixture.repositoryA.loadRecord(first.id), isNull);
      expect(
        await fixture.repositoryA.loadRecord(plan.newGroups.single.id),
        isNull,
      );
      expect(fixture.app.hosts.where((h) => h.id == first.id), isEmpty);
      expect(fixture.app.groups, isEmpty);
    } finally {
      await fixture.dispose();
    }
  });

  test('P2: rollback never deletes a concurrently edited imported record', () async {
    final fixture = await _fixture(sodium);
    try {
      final target = CloudTermiusTransferTarget(fixture.app);
      final plan = await _plan(target, [
        ',first,,f.example,ssh,22,u,',
        ',second,,s.example,ssh,22,u,',
      ]);
      final first = plan.hostsToCreate.singleWhere((h) => h.name == 'first');
      final second = plan.hostsToCreate.singleWhere((h) => h.name == 'second');
      fixture.repositoryA.beforeSave = (repository, recordId, operation) async {
        if (recordId != second.id || operation != 'create') return;
        // Another tab edits the freshly created Host before the later
        // failure; compensation must leave that edit alone.
        final current = await repository.loadRecord(first.id);
        await (repository as _HookedRepository).rawSave(
          recordId: first.id,
          plaintext: {
            ...first.toJson(),
            'name': 'edited elsewhere',
          },
          baseRevisionId: current!['_revision_id'] as String,
        );
        throw StateError('synthetic storage failure');
      };
      final error = await target.apply(plan).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(error, isA<TermiusApplyException>());
      final failure = error! as TermiusApplyException;
      expect(failure.rolledBack, isFalse);
      expect(failure.mutatedTarget, isTrue);
      final kept = await fixture.repositoryA.loadRecord(first.id);
      expect(kept, isNotNull);
      expect(kept!['name'], 'edited elsewhere');
      expect(await fixture.repositoryA.loadRecord(second.id), isNull);
      expect(
        fixture.repositoryA.writes.where((w) => w == 'delete:${first.id}'),
        isEmpty,
      );
    } finally {
      await fixture.dispose();
    }
  });

  TermiusImportPlan certificatePlan(TermiusCatalog catalog) {
    final document = TermiusImportDocument(
      format: TermiusSourceFormat.openSsh,
      headers: const [],
      fileIssues: const [],
      rows: [
        TermiusImportRow(
          row: 1,
          line: 1,
          label: 'certified',
          address: 'c.example',
          protocol: HostProtocol.ssh,
          port: 22,
          username: 'u',
          groupPath: const [],
          tags: const [],
          privateKey: _key,
          certificate: _cert,
        ),
      ],
    );
    return TermiusImportPlanner.plan(
      document,
      catalog,
      newId: _id,
      certificates: _PassThroughCertificates(),
    );
  }

  for (final concurrentEdit in [false, true]) {
    test(
      'credential-only creation then host failure '
      '${concurrentEdit ? 'keeps a concurrently edited credential' : 'is rolled back'}',
      () async {
        final fixture = await _fixture(sodium);
        try {
          final target = CloudTermiusTransferTarget(fixture.app);
          final plan = certificatePlan(await target.loadCatalog());
          expect(plan.newCredentials, hasLength(1));
          expect(plan.newGroups, isEmpty);
          final credential = plan.newCredentials.single;
          final host = plan.hostsToCreate.single;
          expect(host.credentialId, credential.id);
          fixture.repositoryA.beforeSave = (repository, recordId, operation) async {
            if (recordId != host.id || operation != 'create') return;
            if (concurrentEdit) {
              final current = await repository.loadRecord(credential.id);
              await (repository as _HookedRepository).rawSave(
                recordId: credential.id,
                plaintext: {...credential.toJson(), 'name': 'renamed elsewhere'},
                baseRevisionId: current!['_revision_id'] as String,
              );
            }
            throw StateError('synthetic storage failure');
          };
          final error = await target.apply(plan).then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          final failure = error! as TermiusApplyException;
          expect(failure.failure, TermiusApplyFailure.writeFailed);
          expect(failure.writtenHosts, 0);
          expect(failure.writtenGroups, 0);
          expect(failure.writtenCredentials, 1);
          final stored = await fixture.repositoryA.loadRecord(credential.id);
          if (concurrentEdit) {
            expect(failure.rolledBack, isFalse);
            expect(failure.mutatedTarget, isTrue);
            expect(stored?['name'], 'renamed elsewhere');
          } else {
            expect(failure.rolledBack, isTrue);
            expect(failure.mutatedTarget, isFalse);
            expect(stored, isNull);
            expect(
              fixture.app.credentials.where((c) => c.id == credential.id),
              isEmpty,
            );
          }
          expect(await fixture.repositoryA.loadRecord(host.id), isNull);
        } finally {
          await fixture.dispose();
        }
      },
    );
  }

  test('same-scope commit-then-throw is reported as kept, never clean', () async {
    final fixture = await _fixture(sodium);
    try {
      final target = CloudTermiusTransferTarget(fixture.app);
      final plan = await _plan(target, [
        ',first,,f.example,ssh,22,u,',
        ',second,,s.example,ssh,22,u,',
      ]);
      final first = plan.hostsToCreate.singleWhere((h) => h.name == 'first');
      final second = plan.hostsToCreate.singleWhere((h) => h.name == 'second');
      fixture.repositoryA.afterCommit = (repository, recordId, operation) async {
        if (recordId == second.id && operation == 'create') {
          throw StateError('synthetic failure after commit');
        }
      };
      final error = await target.apply(plan).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      final failure = error! as TermiusApplyException;
      expect(failure.failure, TermiusApplyFailure.writeFailed);
      expect(failure.rolledBack, isFalse);
      expect(failure.mutatedTarget, isTrue);
      expect(failure.writtenHosts, 2);
      // The committed in-flight record is kept (revision unproven) ...
      expect(await fixture.repositoryA.loadRecord(second.id), isNotNull);
      expect(
        fixture.repositoryA.writes.where((w) => w == 'delete:${second.id}'),
        isEmpty,
      );
      // ... while the confirmed, unchanged earlier record is compensated.
      expect(await fixture.repositoryA.loadRecord(first.id), isNull);
    } finally {
      await fixture.dispose();
    }
  });

  test('read-only Vault refuses apply without writes', () async {
    final fixture = await _fixture(sodium);
    try {
      final target = CloudTermiusTransferTarget(fixture.app);
      final plan = await _plan(target, [',a,,a.example,ssh,22,u,']);
      fixture.app.activeVault = const VaultDescriptor(
        id: _vaultA,
        role: 'viewer',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        canWrite: false,
      );
      await expectLater(
        target.apply(plan),
        throwsA(
          isA<TermiusApplyException>().having(
            (e) => e.failure,
            'failure',
            TermiusApplyFailure.readOnly,
          ),
        ),
      );
      expect(fixture.repositoryA.writes, isEmpty);
    } finally {
      await fixture.dispose();
    }
  });
}
