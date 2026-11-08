import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

const _header = 'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password';

/// Fails the create of one chosen Host, optionally after letting a
/// "concurrent" edit change an already imported Host.
class _FailingRepository extends LocalHostRepository {
  _FailingRepository({
    required super.database,
    required super.profile,
    required super.crypto,
  });

  String? failHostName;
  Future<void> Function()? beforeFailure;

  @override
  Future<HostRecord> createHost(HostRecord draft, {String? recordId}) async {
    if (draft.name == failHostName) {
      await beforeFailure?.call();
      throw StateError('synthetic local storage failure');
    }
    return super.createHost(draft, recordId: recordId);
  }
}

void main() {
  useAppLocaleFixture('en');
  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService service;
  late VaultCrypto crypto;
  final profiles = <UnlockedLocalProfile>[];
  final databases = <LocalVaultDatabase>[];

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-termius-local-');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    service = LocalProfileService(catalog: catalog, crypto: crypto);
    profiles.clear();
    databases.clear();
  });

  tearDown(() async {
    for (final database in databases.reversed) {
      await database.close();
    }
    for (final profile in profiles) {
      await profile.lock();
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<_FailingRepository> repository() async {
    final profile = await service.create(password: 'synthetic passphrase 42');
    profiles.add(profile);
    final record = profile.record;
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
    databases.add(database);
    return _FailingRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
  }

  Future<TermiusImportPlan> plan(
    TermiusTransferTarget target,
    List<String> rows,
  ) async => TermiusImportPlanner.plan(
    TermiusCsvImporter.parse([_header, ...rows].join('\n')),
    await target.loadCatalog(),
  );

  test('local apply writes encrypted groups and hosts with their login', () async {
    final repo = await repository();
    var refreshed = 0;
    final target = LocalTermiusTransferTarget(
      repo,
      onChanged: () async => refreshed++,
    );
    final report = await target.apply(
      await plan(target, ['Team/Ops,ops,x,o.example,ssh,22,root," pw "']),
    );
    expect(report.createdHosts, 1);
    expect(report.createdGroups, 2);
    expect(refreshed, 1);
    final host = (await repo.listHosts()).single;
    expect(host.login?.password, ' pw ');
    final groups = {for (final g in await repo.listGroups()) g.id: g.group};
    expect(groups[host.groupId]!.name, 'Ops');
    expect(groups[groups[host.groupId]!.parentId]!.name, 'Team');
  });

  test('local failure rolls back, but keeps a concurrently edited host', () async {
    for (final concurrent in [false, true]) {
      final repo = await repository();
      final target = LocalTermiusTransferTarget(repo);
      final importPlan = await plan(target, [
        'G,first,,f.example,ssh,22,u,',
        'G,second,,s.example,ssh,22,u,',
      ]);
      final first = importPlan.hostsToCreate.singleWhere(
        (h) => h.name == 'first',
      );
      repo
        ..failHostName = 'second'
        ..beforeFailure = concurrent
            ? () async {
                final current = (await repo.getHost(first.id))!;
                await repo.updateHost(
                  host: current.copyWith(name: 'edited elsewhere'),
                  baseRevisionId: current.revisionId!,
                );
              }
            : null;
      final error = await target.apply(importPlan).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      final failure = error! as TermiusApplyException;
      expect(failure.writtenHosts, 1);
      expect(failure.writtenGroups, 1);
      final hosts = await repo.listHosts();
      if (concurrent) {
        expect(failure.rolledBack, isFalse);
        expect(failure.mutatedTarget, isTrue);
        expect(hosts.single.name, 'edited elsewhere');
        // Its Group stays because the kept Host still references it.
        expect(await repo.listGroups(), hasLength(1));
      } else {
        expect(failure.rolledBack, isTrue);
        expect(hosts, isEmpty);
        expect(await repo.listGroups(), isEmpty);
      }
      await databases.removeLast().close();
      await profiles.removeLast().lock();
      await File('${directory.path}/vault.sqlite').delete();
    }
  });
}
