import 'dart:convert';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/terminal/local_shell_history.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  test('local completed commands are opt-in, encrypted, scoped, restored and cleared', () async {
    final crypto = VaultCrypto(await SodiumSumoInit.init());
    final catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    final service = LocalProfileService(catalog: catalog, crypto: crypto);
    final profile = await service.create(
      password: 'local history fixture password',
    );
    final record = profile.record;
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase.memory(),
      profileId: record.profileId,
      localDataDomainId: record.localDataDomainId,
      localVaultId: record.localVaultId,
    );
    final repo = LocalHostRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
    final history = LocalShellHistory(
      repository: repo,
      hostId: 'fixture-host',
      terminalId: 'fixture-terminal',
    );
    final reopened = LocalShellHistory(
      repository: repo,
      hostId: 'fixture-host',
      terminalId: 'another-terminal',
    );
    final otherHost = LocalShellHistory(
      repository: repo,
      hostId: 'other-host',
      terminalId: 'other-terminal',
    );
    try {
      final encoded = base64Url
          .encode(utf8.encode('echo history-secret-sentinel'))
          .replaceAll('=', '');
      List<String> event(String nonce, String kind, String payload) => [
        'atermius',
        'v1',
        nonce,
        'fixture-terminal',
        '1',
        kind,
        payload,
      ];
      history.accept('777', event('AAAAAAAAAAAAAAAAAAAAAA', 'start', encoded));
      history.accept('777', event('AAAAAAAAAAAAAAAAAAAAAA', 'end', '0'));
      expect(history.items, isEmpty);
      final bootstrap = history.enable();
      final nonce = RegExp("__atermius_nonce='([^']+)'")
          .firstMatch(bootstrap)!
          .group(1)!;
      history.accept('777', event(nonce, 'start', encoded));
      history.accept('777', event(nonce, 'end', '0'));
      expect(history.items.single.command, 'echo history-secret-sentinel');
      await history.flush();
      expect(history.storageFailed, false);
      final raw = await database
          .customSelect('SELECT envelope_json FROM local_vault_records')
          .get();
      expect(raw, isNotEmpty);
      expect(
        raw.map((r) => r.data).toString(),
        isNot(contains('history-secret-sentinel')),
      );
      await reopened.load();
      await otherHost.load();
      expect(reopened.items.single.command, history.items.single.command);
      expect(otherHost.items, isEmpty);
      await reopened.clear();
      await history.load();
      expect(history.items, isEmpty);
      // Clearing also propagates to other open terminals for this host.
      final cleared = LocalShellHistory(
        repository: repo,
        hostId: 'fixture-host',
        terminalId: 'third',
      );
      await cleared.load();
      expect(cleared.items, isEmpty);
      cleared.dispose();
      final snapshot = await repo.prepareMigrationSnapshot(
        migrationId: '10000000-0000-4000-8000-000000000001',
        targetInstanceId: '20000000-0000-4000-8000-000000000002',
        targetVaultId: '30000000-0000-4000-8000-000000000003');
      expect(snapshot.items, isEmpty);
      expect(await repo.getPreference(scope: 'terminal-history', key: 'host-fixture-host', platformFamily: 'all'), isNotNull);
      history.disable();
      expect(history.enabled, false);
    } finally {
      history.dispose();
      reopened.dispose();
      otherHost.dispose();
      await database.close();
      await profile.lock();
      await catalog.close();
    }
  });
}
