import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

// The fixture must be an explicitly provisioned, disposable low-privilege SSH
// account. Its private JSON is supplied out of band, never committed or logged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixturePath = Platform.environment['ATERMIUS_SSH_FIXTURE_FILE'];
  final resultPath = Platform.environment['ATERMIUS_SSH_RESULT_FILE'];
  test(
    'Windows LocalVault persists trust and credentials for real SSH and SFTP',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath!).readAsString(),
      ) as Map<String, dynamic>;
      final hostAddress = fixture['host'] as String;
      final port = fixture['port'] as int;
      final username = fixture['username'] as String;
      final secret = fixture['password'] as String;
      final fingerprint = fixture['host_fingerprint'] as String;
      final remoteHome = fixture['remote_home'] as String;
      final proofName = fixture['proof_name'] as String;
      final proofHash = fixture['proof_sha256'] as String;
      final root = await Directory.systemTemp.createTemp(
        'atermius-windows-ssh-',
      );
      const ids = Uuid();
      final masterPassword = 'synthetic-local-${ids.v4()}';
      final hostName = 'synthetic-host-${ids.v4()}';
      final credentialName = 'synthetic-credential-${ids.v4()}';
      final catalogFile = File('${root.path}/catalog.sqlite');
      final vaultFile = File('${root.path}/vault.sqlite');
      final result = <String, Object?>{
        'runtime': 'Windows FlutterTester',
        'productServicePath': true,
        'guiAcceptance': false,
        'hostFingerprint': fingerprint,
        'proofSha256': proofHash,
        'completedCycles': 0,
        'hostApprovals': 0,
      };
      LocalProfileCatalog? catalog;
      LocalVaultDatabase? database;
      UnlockedLocalProfile? profile;
      SshConnection? connection;
      LocalProfileSftpController? sftp;
      var passed = false;
      try {
        final crypto = VaultCrypto(await SodiumSumoInit.init());
        catalog = LocalProfileCatalog.forTesting(NativeDatabase(catalogFile));
        profile = await LocalProfileService(
          catalog: catalog,
          crypto: crypto,
        ).create(password: masterPassword);
        final profileId = profile.record.profileId;
        database = await _openVault(vaultFile, profile, create: true);
        var repository = LocalHostRepository(
          database: database,
          profile: profile,
          crypto: crypto,
        );
        final credential = await repository.createCredential(
          CredentialRecord(
            id: ids.v4(),
            name: credentialName,
            username: username,
            kind: AuthKind.password,
            secret: secret,
          ),
        );
        final host = await repository.createHost(
          HostRecord(
            id: ids.v4(),
            name: hostName,
            address: hostAddress,
            port: port,
            username: username,
            credentialId: credential.id,
          ),
        );
        var approvals = 0;
        for (var cycle = 0; cycle < 2; cycle++) {
          final storedHost = await repository.getHost(host.id);
          expect(storedHost, isNotNull);
          expect(storedHost!.name == hostName, isTrue);
          final storedCredential = await repository.resolveCredentialForHost(
            storedHost,
          );
          expect(storedCredential, isNotNull);
          // Compare a boolean so assertion failure cannot print the credential.
          expect(storedCredential!.secret == secret, isTrue);
          final controller = LocalProfileSshController(repository: repository);
          connection = await controller.connect(
            host: storedHost,
            credential: storedCredential,
            askApproval: (request) async {
              expect(
                cycle,
                0,
                reason: 'Reopened trust must need no new approval.',
              );
              expect(request.host, hostAddress);
              expect(request.port, port);
              expect(request.algorithm, 'ssh-ed25519');
              expect(request.fingerprint, fingerprint);
              approvals++;
              return true;
            },
          );
          expect(approvals, 1);
          result['hostApprovals'] = approvals;
          final trusted = await repository.listKnownHosts();
          expect(trusted, hasLength(1));
          expect(trusted.single.fingerprint, fingerprint);

          // Exercise the product's actual PTY shell stream and input method.
          // Split the printed marker so terminal command echo cannot satisfy it.
          final suffix = 'WINDOWS_SHELL_${ids.v4()}__';
          final marker = '__ATERMIUS_$suffix';
          final observed = Completer<void>();
          var output = '';
          final subscription = connection.output.listen(
            (chunk) {
              output += chunk;
              if (output.length > 32768) {
                if (!observed.isCompleted) {
                  observed.completeError(
                    StateError('Shell output exceeded bound.'),
                  );
                }
              } else if (output.contains(marker) && !observed.isCompleted) {
                observed.complete();
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!observed.isCompleted) observed.completeError(error, stack);
            },
          );
          try {
            connection.input("printf '%s%s\\n' '__ATERMIUS_' '$suffix'\n");
            await observed.future.timeout(const Duration(seconds: 10));
            result['shellMarkers'] = cycle + 1;
          } finally {
            await subscription.cancel();
          }

          sftp = LocalProfileSftpController(connection: connection);
          final entries = await sftp.listDirectory(remoteHome);
          expect(entries.any((entry) => entry.filename == proofName), isTrue);
          final bytes = await sftp.downloadFile(
            parent: remoteHome,
            name: proofName,
          );
          try {
            expect(sha256.convert(bytes).toString(), proofHash);
            result['proofBytes'] = bytes.length;
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
          await sftp.close();
          sftp = null;
          await connection.close();
          connection = null;
          result['completedCycles'] = cycle + 1;
          result['hostApprovals'] = approvals;

          await database!.close();
          database = null;
          await profile!.lock();
          profile = null;
          await catalog!.close();
          catalog = null;
          // Check the actual closed SQLite files, including any sidecar files.
          // This is a narrow at-rest check for our synthetic test strings.
          for (final entity in await root.list().toList()) {
            if (entity is! File) continue;
            final contents = latin1.decode(await entity.readAsBytes());
            for (final sensitive in [
              secret,
              masterPassword,
              hostName,
              credentialName,
            ]) {
              expect(
                contents.contains(sensitive),
                isFalse,
                reason: 'Synthetic private data appeared in persisted SQLite bytes.',
              );
            }
          }
          result['syntheticPlaintextAbsentAtRest'] = true;
          if (cycle == 0) {
            catalog = LocalProfileCatalog.forTesting(
              NativeDatabase(catalogFile),
            );
            profile = await LocalProfileService(
              catalog: catalog,
              crypto: crypto,
            ).unlock(profileId: profileId, password: masterPassword);
            database = await _openVault(vaultFile, profile, create: false);
            repository = LocalHostRepository(
              database: database,
              profile: profile,
              crypto: crypto,
            );
          }
        }
        result['reopenedCatalogAndVault'] = true;
        passed = true;
      } finally {
        await sftp?.close();
        await connection?.close();
        await database?.close();
        await profile?.lock();
        await catalog?.close();
        if (await root.exists()) await root.delete(recursive: true);
        result['temporaryDatabaseRemoved'] = !await root.exists();
        result['passed'] = passed;
        if (resultPath != null) {
          await File(resultPath).writeAsString(jsonEncode(result));
        }
      }
    },
    skip: !Platform.isWindows || fixturePath == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<LocalVaultDatabase> _openVault(
  File file,
  UnlockedLocalProfile profile, {
  required bool create,
}) => LocalVaultDatabase.openForTesting(
  executor: NativeDatabase(file),
  profileId: profile.record.profileId,
  localDataDomainId: profile.record.localDataDomainId,
  localVaultId: profile.record.localVaultId,
  mode: create ? LocalVaultOpenMode.createNew : LocalVaultOpenMode.openExisting,
);
