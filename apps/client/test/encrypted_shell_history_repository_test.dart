import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/terminal/encrypted_shell_history_repository.dart';
import 'package:aterm_client/terminal/shell_integration_protocol.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  late ClientDatabase database;
  late DeviceIdentity identity;
  late EncryptedShellHistoryRepository repository;

  setUp(() async {
    sodium = await SodiumSumoInit.init();
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    identity = DeviceIdentity.create(sodium);
    repository = EncryptedShellHistoryRepository(
      database: database,
      crypto: VaultCrypto(sodium),
      identity: identity,
      baseUrl: 'https://sync.example.test/tenant/',
      accountId: 'account-a',
    );
  });

  tearDown(() async {
    repository.close();
    identity.dispose();
    await database.close();
  });

  test(
    'persists only authenticated ciphertext and restores after restart',
    () async {
      const command = 'sudo systemctl restart api.service';
      final completed = _command(1, command, DateTime.utc(2026, 10, 8, 12));
      await repository.record(hostId: 'host-a', command: completed);

      final rows = await database.terminalHistoryCiphertextEntries(
        serverNamespace: repository.serverNamespace,
        accountId: 'account-a',
        deviceId: identity.deviceId,
      );
      expect(rows, hasLength(1));
      expect(rows.single.ciphertext, isNotEmpty);
      expect(
        utf8.decode(rows.single.ciphertext, allowMalformed: true),
        isNot(contains(command)),
      );

      final restarted = EncryptedShellHistoryRepository(
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        baseUrl: 'https://sync.example.test/tenant',
        accountId: 'account-a',
      );
      addTearDown(restarted.close);
      final restored = await restarted.load(hostId: 'host-a');
      expect(restored, hasLength(1));
      expect(restored.single.command, command);
      expect(restored.single.exitStatus, 0);
      expect(restored.single.completedAt, completed.completedAt);
      expect(await restarted.load(hostId: 'other-host'), isEmpty);
    },
  );

  test(
    'authenticated data cannot be moved to a different server scope',
    () async {
      await repository.record(
        hostId: 'host-a',
        command: _command(1, 'uname -a', DateTime.utc(2026, 10, 8, 12)),
      );
      final sourceRows = await database.terminalHistoryCiphertextEntries(
        serverNamespace: repository.serverNamespace,
        accountId: 'account-a',
        deviceId: identity.deviceId,
      );
      await database.insertTerminalHistoryCiphertext(
        serverNamespace: 'https://other.example.test',
        accountId: 'account-a',
        deviceId: identity.deviceId,
        ciphertext: Uint8List.fromList(sourceRows.single.ciphertext),
      );

      final otherServer = EncryptedShellHistoryRepository(
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        baseUrl: 'https://other.example.test',
        accountId: 'account-a',
      );
      addTearDown(otherServer.close);
      expect(await otherServer.load(), isEmpty);
    },
  );

  test(
    'retention cap preserves newest commands and clear is host scoped',
    () async {
      final bounded = EncryptedShellHistoryRepository(
        database: database,
        crypto: VaultCrypto(sodium),
        identity: identity,
        baseUrl: 'https://sync.example.test/tenant',
        accountId: 'account-a',
        maxEntries: 2,
      );
      addTearDown(bounded.close);
      for (var index = 1; index <= 3; index++) {
        await bounded.record(
          hostId: index == 2 ? 'host-b' : 'host-a',
          command: _command(
            index,
            'command-$index',
            DateTime.utc(2026, 10, 8, 12, 0, index),
          ),
        );
      }

      final all = await bounded.load();
      expect(all.map((entry) => entry.command), ['command-2', 'command-3']);
      expect(await bounded.clear(hostId: 'host-a'), 1);
      expect((await bounded.load()).single.hostId, 'host-b');
    },
  );

  test('skips an unauthenticated row without exposing its contents', () async {
    await repository.record(
      hostId: 'host-a',
      command: _command(1, 'safe command', DateTime.utc(2026, 10, 8, 12)),
    );
    final rows = await database.terminalHistoryCiphertextEntries(
      serverNamespace: repository.serverNamespace,
      accountId: 'account-a',
      deviceId: identity.deviceId,
    );
    final corrupt = Uint8List.fromList(rows.single.ciphertext)..[0] ^= 0x40;
    await database.insertTerminalHistoryCiphertext(
      serverNamespace: repository.serverNamespace,
      accountId: 'account-a',
      deviceId: identity.deviceId,
      ciphertext: corrupt,
    );

    expect((await repository.load()).map((entry) => entry.command), [
      'safe command',
    ]);
  });
}

ShellIntegrationCompletedCommand _command(
  int id,
  String text,
  DateTime startedAt,
) => ShellIntegrationCompletedCommand(
  commandId: id,
  command: text,
  exitStatus: 0,
  startedAt: startedAt,
  completedAt: startedAt.add(const Duration(seconds: 1)),
);
