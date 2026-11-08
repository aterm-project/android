import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = 'https://sync.example.test';
const _account = 'account-a';
const _device = 'device-a';
const _otherServer = 'https://other.example.test';
const _otherAccount = 'account-b';
const _otherDevice = 'device-b';

void main() {
  test('fresh schema stores only ciphertext and namespace metadata', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await database.ensureReady();

    final schemaVersion = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(schemaVersion.read<int>('user_version'), 14);

    final table = await database
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name = 'terminal_history_entries'",
        )
        .getSingleOrNull();
    expect(table, isNotNull);

    final columns = await database
        .customSelect("PRAGMA table_info('terminal_history_entries')")
        .get();
    expect(columns.map((row) => row.read<String>('name')).toSet(), {
      'server_namespace',
      'account_id',
      'device_id',
      'entry_id',
      'ciphertext',
      'created_at',
      'updated_at',
    });
  });

  test('round-trips opaque bytes and isolates each namespace', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.ensureReady();

    final originalBytes = Uint8List.fromList([0, 1, 0xff, 0x80, 42]);
    final entryId = await database.insertTerminalHistoryCiphertext(
      serverNamespace: _server,
      accountId: _account,
      deviceId: _device,
      ciphertext: originalBytes,
      createdAt: 123456,
    );
    originalBytes.fillRange(0, originalBytes.length, 0);

    final otherServerId = await database.insertTerminalHistoryCiphertext(
      serverNamespace: _otherServer,
      accountId: _account,
      deviceId: _device,
      ciphertext: Uint8List.fromList([9]),
      createdAt: 123457,
    );
    final otherAccountId = await database.insertTerminalHistoryCiphertext(
      serverNamespace: _server,
      accountId: _otherAccount,
      deviceId: _device,
      ciphertext: Uint8List.fromList([10]),
      createdAt: 123458,
    );
    final otherDeviceId = await database.insertTerminalHistoryCiphertext(
      serverNamespace: _server,
      accountId: _account,
      deviceId: _otherDevice,
      ciphertext: Uint8List.fromList([11]),
      createdAt: 123459,
    );

    final entries = await database.terminalHistoryCiphertextEntries(
      serverNamespace: _server,
      accountId: _account,
      deviceId: _device,
    );
    expect(entries, hasLength(1));
    expect(entries.single.entryId, entryId);
    expect(entries.single.ciphertext, [0, 1, 0xff, 0x80, 42]);
    expect(entries.single.createdAt, 123456);
    expect(entries.single.updatedAt, 123456);
    expect(
      {
        otherServerId,
        otherAccountId,
        otherDeviceId,
      }.intersection(entries.map((entry) => entry.entryId).toSet()),
      isEmpty,
    );

    expect(
      (await database.terminalHistoryCiphertextEntries(
        serverNamespace: _otherServer,
        accountId: _account,
        deviceId: _device,
      )).single.entryId,
      otherServerId,
    );
    expect(
      (await database.terminalHistoryCiphertextEntries(
        serverNamespace: _server,
        accountId: _otherAccount,
        deviceId: _device,
      )).single.entryId,
      otherAccountId,
    );
    expect(
      (await database.terminalHistoryCiphertextEntries(
        serverNamespace: _server,
        accountId: _account,
        deviceId: _otherDevice,
      )).single.entryId,
      otherDeviceId,
    );
  });

  test(
    'deletes rows and prunes only beyond the scoped newest-entry cap',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.ensureReady();

      final ids = <String>[];
      for (final timestamp in [10, 20, 20, 30]) {
        ids.add(
          await database.insertTerminalHistoryCiphertext(
            serverNamespace: _server,
            accountId: _account,
            deviceId: _device,
            ciphertext: Uint8List.fromList([timestamp]),
            createdAt: timestamp,
          ),
        );
      }
      final otherNamespaceId = await database.insertTerminalHistoryCiphertext(
        serverNamespace: _server,
        accountId: _account,
        deviceId: _otherDevice,
        ciphertext: Uint8List.fromList([99]),
        createdAt: 1,
      );

      expect(
        await database.pruneTerminalHistoryCiphertext(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
          maxEntries: 2,
        ),
        2,
      );
      final retained = await database.terminalHistoryCiphertextEntries(
        serverNamespace: _server,
        accountId: _account,
        deviceId: _device,
      );
      expect(retained.map((entry) => entry.createdAt), [30, 20]);
      expect(
        retained.map((entry) => entry.entryId),
        isNot(contains(ids.first)),
      );

      final removedId = retained.last.entryId;
      expect(
        await database.deleteTerminalHistoryCiphertext(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
          entryId: removedId,
        ),
        isTrue,
      );
      expect(
        await database.deleteTerminalHistoryCiphertext(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
          entryId: removedId,
        ),
        isFalse,
      );

      expect(
        await database.clearTerminalHistoryCiphertext(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
        ),
        1,
      );
      expect(
        await database.terminalHistoryCiphertextEntries(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
        ),
        isEmpty,
      );
      expect(
        (await database.terminalHistoryCiphertextEntries(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _otherDevice,
        )).single.entryId,
        otherNamespaceId,
      );

      await database.insertTerminalHistoryCiphertext(
        serverNamespace: _server,
        accountId: _account,
        deviceId: _device,
        ciphertext: Uint8List.fromList([40]),
        createdAt: 40,
      );
      expect(
        await database.pruneTerminalHistoryCiphertext(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
          maxEntries: 0,
        ),
        1,
      );
      expect(
        await database.terminalHistoryCiphertextEntries(
          serverNamespace: _server,
          accountId: _account,
          deviceId: _device,
        ),
        isEmpty,
      );
    },
  );

  test(
    'authenticated push receipt pruning preserves the retention boundary',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.ensureReady();

      final now = DateTime.utc(2026, 10, 11, 12);
      final cutoff =
          now.millisecondsSinceEpoch -
          ClientDatabase.authenticatedPushReceiptRetention.inMilliseconds;
      Future<void> insertReceipt(
        String opId,
        int createdAt,
      ) => database.customStatement(
        'INSERT INTO authenticated_push_receipts '
        '(op_id, vault_id, record_id, revision_id, envelope_json, commit_seq, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          opId,
          'vault-1',
          'record-1',
          'revision-$opId',
          '{"opaque":"ciphertext"}',
          '1',
          createdAt,
        ],
      );

      await insertReceipt('expired', cutoff - 1);
      await insertReceipt('at-cutoff', cutoff);
      await insertReceipt('fresh', now.millisecondsSinceEpoch);

      expect(await database.pruneAuthenticatedPushReceipts(now: now), 1);
      final retained = await database
          .select(database.authenticatedPushReceipts)
          .get();
      expect(retained.map((proof) => proof.opId).toSet(), {
        'at-cutoff',
        'fresh',
      });
      expect(
        await database.pruneAuthenticatedPushReceipts(now: now),
        0,
        reason: 'repeated cleanup is idempotent',
      );
      final startupExpiredAt =
          DateTime.now().millisecondsSinceEpoch -
          ClientDatabase.authenticatedPushReceiptRetention.inMilliseconds -
          1;
      await insertReceipt('startup-expired', startupExpiredAt);
      await database.ensureReady();
      expect(
        await (database.select(database.authenticatedPushReceipts)
              ..where((proof) => proof.opId.equals('startup-expired')))
            .getSingleOrNull(),
        isNull,
        reason: 'database open preflight prunes expired proofs',
      );
    },
  );

  test('v9 receipt rows migrate with a fresh retention timestamp', () async {
    final directory = await Directory.systemTemp.createTemp(
      'atermius-push-receipt-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/client.sqlite');

    final beforeUpgrade = ClientDatabase.forTesting(NativeDatabase(file));
    await beforeUpgrade.ensureReady();
    await beforeUpgrade.customStatement(
      'DROP TABLE authenticated_push_receipts',
    );
    await beforeUpgrade.customStatement(
      'CREATE TABLE authenticated_push_receipts ('
      'op_id TEXT NOT NULL PRIMARY KEY, vault_id TEXT NOT NULL, '
      'record_id TEXT NOT NULL, revision_id TEXT NOT NULL, '
      'envelope_json TEXT NOT NULL, commit_seq TEXT NOT NULL)',
    );
    await beforeUpgrade.customStatement(
      'INSERT INTO authenticated_push_receipts '
      '(op_id, vault_id, record_id, revision_id, envelope_json, commit_seq) '
      "VALUES ('old-op', 'vault-1', 'record-1', 'revision-1', '{\"opaque\":\"ciphertext\"}', '1')",
    );
    await beforeUpgrade.customStatement('PRAGMA user_version = 9');
    await beforeUpgrade.close();

    final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.ensureReady();
    final schemaVersion = await upgraded
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(schemaVersion.read<int>('user_version'), 14);
    final proof = await upgraded
        .select(upgraded.authenticatedPushReceipts)
        .getSingle();
    expect(proof.opId, 'old-op');
    expect(proof.createdAt, greaterThan(0));
  });

  test(
    'v6 to current migration creates the table and tolerates an existing table',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atermius-terminal-history-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/client.sqlite');

      final beforeUpgrade = ClientDatabase.forTesting(NativeDatabase(file));
      await beforeUpgrade.ensureReady();
      await beforeUpgrade.customStatement(
        'DROP TABLE terminal_history_entries',
      );
      await beforeUpgrade.customStatement('PRAGMA user_version = 6');
      await beforeUpgrade.close();

      final upgraded = ClientDatabase.forTesting(NativeDatabase(file));
      await upgraded.ensureReady();
      expect(
        await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE type = 'table' AND name = 'terminal_history_entries'",
            )
            .getSingleOrNull(),
        isNotNull,
      );
      await upgraded.customStatement('PRAGMA user_version = 6');
      await upgraded.close();

      final retried = ClientDatabase.forTesting(NativeDatabase(file));
      addTearDown(retried.close);
      await retried.ensureReady();
      expect(
        await retried
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        14,
      );
    },
  );
}
