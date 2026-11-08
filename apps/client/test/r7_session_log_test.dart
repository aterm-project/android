import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/terminal/session_log_scope.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _host = HostRecord(
  id: 'host-1',
  name: 'prod web',
  address: '10.0.0.5',
  port: 2222,
  username: 'deploy',
);

class _SecretError implements Exception {
  @override
  String toString() => 'password=hunter2 -----BEGIN OPENSSH PRIVATE KEY-----';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionLogBook (memory)', () {
    test('lifecycle: connecting → connected → closed by remote', () async {
      final book = SessionLogBook.memory();
      final log = book.begin(host: _host);
      expect(book.entries.single.status, SessionLogStatus.connecting);
      expect(book.entries.single.endpoint, 'deploy@10.0.0.5:2222');
      expect(book.isLive(log.id), isTrue);
      log.markConnected();
      expect(book.entries.single.status, SessionLogStatus.connected);
      log.markClosed(SessionLogEndReason.remote);
      log.markClosed(SessionLogEndReason.user); // idempotent
      await book.flush();
      final entry = book.entries.single;
      expect(entry.status, SessionLogStatus.closed);
      expect(entry.endReason, SessionLogEndReason.remote);
      expect(entry.duration, isNotNull);
      expect(book.isLive(log.id), isFalse);
    });

    test('failures are categorized; exception text is never stored', () async {
      final storage = MemorySessionLogStorage();
      final book = SessionLogBook(storage: storage);
      book.begin(host: _host).markFailed(_SecretError());
      book
          .begin(host: _host)
          .markFailed(
            const SshHostKeyVerificationException(SshHostKeyFailure.changed),
          );
      book.begin(host: _host).markFailed(const SshCredentialException());
      book.begin(host: _host).markFailed(TimeoutException('x'));
      await book.flush();
      final failures = book.entries.map((e) => e.failure).toSet();
      expect(failures, {
        SessionLogFailure.other,
        SessionLogFailure.hostKeyChanged,
        SessionLogFailure.credential,
        SessionLogFailure.timeout,
      });
      final stored = jsonEncode(await storage.read('index'));
      expect(stored, isNot(contains('hunter2')));
      expect(stored, isNot(contains('PRIVATE KEY')));
    });

    test('transcripts only when enabled before the session started', () async {
      final book = SessionLogBook.memory();
      final before = book.begin(host: _host)..markConnected();
      await book.setRecordTranscripts(true);
      before.output('should-not-be-recorded\n');
      final after = book.begin(host: _host)..markConnected();
      after.output('\x1B[1;32mgreen\x1B[0m line\r\n\x1B]0;title\x07next');
      before.markClosed(SessionLogEndReason.user);
      after.markClosed(SessionLogEndReason.user);
      await book.flush();
      expect(await book.transcript(before.id), isNull);
      expect(await book.transcript(after.id), 'green line\nnext');
      expect(
        book.entries.firstWhere((e) => e.id == after.id).hasTranscript,
        isTrue,
      );
    });

    test('retention is bounded (rows, transcript slots, bytes)', () async {
      final book = SessionLogBook(
        storage: MemorySessionLogStorage(),
        maxEntries: 5,
        maxTranscripts: 2,
        maxTranscriptBytes: 64,
      );
      await book.setRecordTranscripts(true);
      final ids = <String>[];
      for (var i = 0; i < 8; i++) {
        final log = book.begin(host: _host)..markConnected();
        log.output('${'x' * 100}tail-$i');
        log.markClosed(SessionLogEndReason.user);
        ids.add(log.id);
        await book.flush();
      }
      expect(book.entries, hasLength(5));
      final withTranscript = book.entries.where((e) => e.hasTranscript);
      expect(withTranscript, hasLength(2));
      final newest = await book.transcript(ids.last);
      expect(newest, endsWith('tail-7'));
      expect(utf8.encode(newest!).length, lessThanOrEqualTo(64));
      expect(book.entries.first.transcriptTruncated, isTrue);
      // Reused slot no longer serves the old row.
      expect(await book.transcript(ids[5]), isNull);
    });

    test('delete and clear keep live sessions', () async {
      final book = SessionLogBook.memory();
      final live = book.begin(host: _host)..markConnected();
      final done = book.begin(host: _host)..markFailed(_SecretError());
      await book.flush();
      await book.delete(live.id); // ignored while live
      expect(book.entries, hasLength(2));
      await book.clear();
      expect(book.entries.single.id, live.id);
      expect(done.finished, isTrue);
    });
  });

  group('ScopedSessionLogBook (cloud account/Vault scope)', () {
    test('scope switch, retire and late old finish never leak', () async {
      Object? scope = ('srv', 'account-a', 'device', 'vault-1');
      final holder = ScopedSessionLogBook(() => scope);
      final first = holder.current;
      expect(identical(holder.current, first), isTrue); // stable in scope
      await first.setRecordTranscripts(true);
      final old = first.begin(host: _host)..markConnected();
      old.output('vault-1 secret output');

      scope = ('srv', 'account-a', 'device', 'vault-2'); // selectVault
      final second = holder.current;
      expect(identical(second, first), isFalse);
      expect(second.entries, isEmpty);
      expect(second.recordTranscripts, isFalse);
      old.markClosed(SessionLogEndReason.remote); // delayed old finish
      await second.flush();
      expect(second.entries, isEmpty);
      expect(await second.transcript(old.id), isNull);

      final row = second.begin(host: _host)..markFailed(_SecretError());
      expect(second.entries.single.id, row.id);
      holder.retire(); // lock / logout / credential cleanup
      final third = holder.current; // same scope key after re-login
      expect(identical(third, second), isFalse);
      expect(third.entries, isEmpty);

      scope = ('srv', 'account-b', 'device', 'vault-1'); // other account
      expect(holder.current.entries, isEmpty);
      holder.dispose();
      expect(holder.current.entries, isEmpty);
    });
  });

  group('LocalPreferenceSessionLogStorage (encrypted Local Profile)', () {
    late Directory root;
    late LocalProfileCatalog catalog;
    late LocalVaultDatabase database;
    late UnlockedLocalProfile profile;
    late LocalHostRepository repository;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('atermius-r7-logs-');
      final crypto = VaultCrypto(await SodiumSumoInit.init());
      catalog = LocalProfileCatalog.forTesting(
        NativeDatabase(File('${root.path}/catalog.sqlite')),
      );
      profile = await LocalProfileService(
        catalog: catalog,
        crypto: crypto,
      ).create(password: 'r7-session-log-test-password');
      database = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(File('${root.path}/vault.sqlite')),
        profileId: profile.record.profileId,
        localDataDomainId: profile.record.localDataDomainId,
        localVaultId: profile.record.localVaultId,
      );
      repository = LocalHostRepository(
        database: database,
        profile: profile,
        crypto: crypto,
      );
    });

    tearDown(() async {
      await database.close();
      await profile.lock();
      await catalog.close();
      await root.delete(recursive: true);
    });

    test('Keychain certificate round-trips; invalid shapes rejected', () async {
      if (Process.runSync('which', ['ssh-keygen']).exitCode != 0) {
        markTestSkipped('ssh-keygen unavailable');
        return;
      }
      Future<void> keygen(List<String> a) async {
        final r = await Process.run('ssh-keygen', ['-q', ...a]);
        if (r.exitCode != 0) throw StateError('ssh-keygen ${r.exitCode}');
      }

      final p = root.path;
      await keygen(['-t', 'ed25519', '-N', '', '-f', '$p/ca']);
      await keygen(['-t', 'ed25519', '-N', '', '-f', '$p/u']);
      await keygen(['-s', '$p/ca', '-I', 'kid', '-n', 'root', '$p/u.pub']);
      await keygen(['-t', 'ed25519', '-N', '', '-f', '$p/h']);
      await keygen(['-s', '$p/ca', '-I', 'hid', '-h', '$p/h.pub']);
      final key = await File('$p/u').readAsString();
      final cert = await File('$p/u-cert.pub').readAsString();
      final hostCert = await File('$p/h-cert.pub').readAsString();
      final saved = await repository.createCredential(
        CredentialRecord(
          id: '6f1f2b9e-5a49-4c55-9a3e-3f0e1b2c4d5e',
          name: 'cert login',
          username: 'root',
          kind: AuthKind.privateKey,
          privateKey: key,
          certificate: '$cert\n',  // file contents incl. newline
          fingerprint: 'SHA256:x',
        ),
      );
      final read = await repository.getCredential(saved.id);
      expect(read!.certificate, cert.trim());
      final summaries = await repository.listCredentials();
      expect(summaries.single.certificate, cert.trim());
      expect(summaries.single.fingerprint, 'SHA256:x');
      await expectLater(
        repository.createCredential(
          CredentialRecord(
            id: '7f1f2b9e-5a49-4c55-9a3e-3f0e1b2c4d5e',
            name: 'host cert',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: key,
            certificate: hostCert,
          ),
        ),
        throwsA(anything),
      );
      await expectLater(
        repository.createCredential(
          CredentialRecord(
            id: '8f1f2b9e-5a49-4c55-9a3e-3f0e1b2c4d5e',
            name: 'pw cert',
            username: 'root',
            secret: 'pw',
            certificate: cert,
          ),
        ),
        throwsA(anything),
      );
      expect(await repository.listCredentials(), hasLength(1));
    });

    test('survives restart, encrypted at rest, crashed rows closed', () async {
      final first = SessionLogBook(
        storage: LocalPreferenceSessionLogStorage(repository),
      );
      await first.load();
      await first.setRecordTranscripts(true);
      final done = first.begin(host: _host)..markConnected();
      done.output('transcript-sentinel-7f3a\n');
      done.markClosed(SessionLogEndReason.remote);
      // Simulates an app kill while a session was open.
      final orphan = first.begin(host: _host)..markConnected();
      await first.flush();
      first.dispose();

      final raw = await File('${root.path}/vault.sqlite').readAsBytes();
      final text = latin1.decode(raw);
      expect(text, isNot(contains('transcript-sentinel-7f3a')));
      expect(text, isNot(contains('prod web')));

      // Owner heartbeat is fresh: another window may still own it → kept.
      final peer = SessionLogBook(
        storage: LocalPreferenceSessionLogStorage(repository),
      );
      await peer.load();
      expect(
        peer.entries.firstWhere((e) => e.id == orphan.id).status,
        SessionLogStatus.connected,
      );
      expect(peer.isActive(orphan.id), isTrue);
      peer.dispose();

      // After the owner's heartbeat goes stale the row is closed as lost.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = SessionLogBook(
        storage: LocalPreferenceSessionLogStorage(repository),
        ownerStaleAfter: const Duration(milliseconds: 10),
      );
      await second.load();
      expect(second.recordTranscripts, isTrue);
      expect(second.entries, hasLength(2));
      final restored = second.entries.firstWhere((e) => e.id == done.id);
      expect(restored.status, SessionLogStatus.closed);
      expect(restored.endReason, SessionLogEndReason.remote);
      expect(
        await second.transcript(done.id),
        'transcript-sentinel-7f3a\n',
      );
      final recovered = second.entries.firstWhere((e) => e.id == orphan.id);
      expect(recovered.status, SessionLogStatus.closed);
      expect(recovered.endReason, SessionLogEndReason.error);

      await second.clear();
      second.dispose();
      final third = SessionLogBook(
        storage: LocalPreferenceSessionLogStorage(repository),
      );
      await third.load();
      expect(third.entries, isEmpty);
      // Fixed keys are updated in place: index + settings + one slot.
      final prefs = (await repository.listPreferences())
          .where((p) => p.scope == localSessionLogPreferenceScope)
          .map((p) => p.key)
          .toSet();
      expect(prefs, {'index', 'settings', 'transcript-slot-0'});
      third.dispose();
    });
  });

  group('two books (windows) sharing one Profile journal', () {
    Future<void> session(SessionLogBook book, String text) async {
      final log = book.begin(host: _host)..markConnected();
      log.output(text);
      log.markClosed(SessionLogEndReason.user);
      await book.flush();
    }

    for (final kind in ['memory', 'encrypted']) {
      group(kind, () {
        late SessionLogStorage storage;
        late Future<void> Function() cleanup;

        setUp(() async {
          if (kind == 'memory') {
            storage = MemorySessionLogStorage();
            cleanup = () async {};
            return;
          }
          final root = await Directory.systemTemp.createTemp('r7-2book-');
          final crypto = VaultCrypto(await SodiumSumoInit.init());
          final catalog = LocalProfileCatalog.forTesting(
            NativeDatabase(File('${root.path}/c.sqlite')),
          );
          final profile = await LocalProfileService(
            catalog: catalog,
            crypto: crypto,
          ).create(password: 'r7-two-book-password');
          final database = await LocalVaultDatabase.openForTesting(
            executor: NativeDatabase(File('${root.path}/v.sqlite')),
            profileId: profile.record.profileId,
            localDataDomainId: profile.record.localDataDomainId,
            localVaultId: profile.record.localVaultId,
          );
          storage = LocalPreferenceSessionLogStorage(
            LocalHostRepository(
              database: database,
              profile: profile,
              crypto: crypto,
            ),
          );
          cleanup = () async {
            await database.close();
            await profile.lock();
            await catalog.close();
            await root.delete(recursive: true);
          };
        });
        tearDown(() => cleanup());

        SessionLogBook book() => SessionLogBook(storage: storage);

        test('interleaved writers keep both rows and own transcripts', () async {
          final a = book(), b = book();
          await a.load();
          await b.load(); // both start from the same (empty) view
          await a.setRecordTranscripts(true);
          await b.setRecordTranscripts(true);
          await session(a, 'from-window-A');
          await session(b, 'from-window-B'); // b never reloaded
          await session(a, 'second-from-A');
          final c = book();
          await c.load();
          expect(c.entries, hasLength(3));
          final texts = <String?>[
            for (final e in c.entries) await c.transcript(e.id),
          ];
          expect(
            texts.toSet(),
            {'from-window-A', 'from-window-B', 'second-from-A'},
          );
          expect(
            c.entries.map((e) => e.transcriptSlot).toSet(),
            hasLength(3),
          );
          for (final x in [a, b, c]) {
            x.dispose();
          }
        });

        test('delete and clear are not resurrected by a stale writer', () async {
          final a = book(), b = book();
          await a.load();
          await session(a, 'x');
          await session(a, 'y');
          await b.load(); // b sees x and y
          final doomed = a.entries.last.id;
          await a.delete(doomed);
          await session(b, 'z'); // stale b writes after the delete
          final c = book();
          await c.load();
          expect(c.entries.map((e) => e.id), isNot(contains(doomed)));
          expect(c.entries, hasLength(2));

          await a.load();
          await a.clear();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await session(b, 'after-clear'); // b's view still has old rows
          final d = book();
          await d.load();
          expect(d.entries, hasLength(1));
          for (final x in [a, b, c, d]) {
            x.dispose();
          }
        });

        test('another window does not close an externally live session', () async {
          final a = book(), b = book();
          await a.load();
          final live = a.begin(host: _host)..markConnected();
          await a.flush();
          await b.load();
          final seen = b.entries.single;
          expect(seen.status, SessionLogStatus.connected);
          expect(b.isActive(live.id), isTrue);
          expect(b.isLive(live.id), isFalse);
          await b.delete(live.id);
          await b.clear();
          await session(b, 'other');
          await a.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          live.markClosed(SessionLogEndReason.remote);
          await a.flush();
          await b.load();
          final closed = b.entries.firstWhere((e) => e.id == live.id);
          expect(closed.status, SessionLogStatus.closed);
          expect(closed.endReason, SessionLogEndReason.remote);
          expect(b.entries, hasLength(2));
          a.dispose();
          b.dispose();
        });
      });
    }
  });

  group('real sshd session lifecycle', () {
    final tools =
        !Platform.isWindows &&
        File('/usr/sbin/sshd').existsSync() &&
        Process.runSync('which', ['ssh-keygen']).exitCode == 0;

    test('records connect, transcript of real output and remote close', () async {
      final root = await Directory.systemTemp.createTemp('atermius-r7-logssh-');
      Process? sshd;
      try {
        Future<void> keygen(List<String> a) async {
          final r = await Process.run('ssh-keygen', ['-q', ...a]);
          if (r.exitCode != 0) throw StateError('ssh-keygen ${r.exitCode}');
        }

        await keygen(['-t', 'ed25519', '-N', '', '-f', '${root.path}/user']);
        await keygen(['-t', 'ed25519', '-N', '', '-f', '${root.path}/host']);
        await File('${root.path}/authorized_keys').writeAsString(
          await File('${root.path}/user.pub').readAsString(),
        );
        final lease = await ServerSocket.bind('127.0.0.1', 0);
        final port = lease.port;
        await lease.close();
        await File('${root.path}/sshd_config').writeAsString('''
ListenAddress 127.0.0.1
Port $port
HostKey ${root.path}/host
PidFile ${root.path}/sshd.pid
AuthorizedKeysFile ${root.path}/authorized_keys
AuthenticationMethods publickey
PermitRootLogin yes
AllowUsers root
StrictModes no
UsePAM no
UseDNS no
PermitTTY yes
PrintMotd no
LogLevel ERROR
''');
        sshd = await Process.start('/usr/sbin/sshd', [
          '-D',
          '-e',
          '-f',
          '${root.path}/sshd_config',
        ]);
        unawaited(sshd.stdout.drain<void>());
        unawaited(sshd.stderr.drain<void>());
        for (var i = 0; ; i++) {
          try {
            (await Socket.connect('127.0.0.1', port)).destroy();
            break;
          } on SocketException {
            if (i > 200) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        final host = HostRecord(
          id: 'real',
          name: 'real sshd',
          address: '127.0.0.1',
          port: port,
          username: 'root',
        );
        final book = SessionLogBook.memory();
        await book.setRecordTranscripts(true);
        final log = book.begin(host: host);
        final connection = await SshService(
          api: null,
          deviceId: 'r7-log-test',
          useRelay: false,
        ).connect(
          host: host,
          credential: CredentialRecord(
            id: 'c',
            name: 'k',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: await File('${root.path}/user').readAsString(),
          ),
          verifyHostKey: (_, _) async => true,
        );
        log.markConnected();
        final seen = Completer<void>();
        final done = Completer<void>();
        final buffer = StringBuffer();
        connection.output.listen(
          (text) {
            log.output(text);
            buffer.write(text);
            if (buffer.toString().contains('r7-marker-42') &&
                !seen.isCompleted) {
              seen.complete();
            }
          },
          onDone: () {
            log.markClosed(SessionLogEndReason.remote);
            if (!done.isCompleted) done.complete();
          },
        );
        connection.input('echo r7-marker-\$((40+2)); exit\n');
        await seen.future.timeout(const Duration(seconds: 10));
        await done.future.timeout(const Duration(seconds: 10));
        await connection.close();
        await book.flush();
        final entry = book.entries.single;
        expect(entry.status, SessionLogStatus.closed);
        expect(entry.endReason, SessionLogEndReason.remote);
        expect(entry.endpoint, 'root@127.0.0.1:$port');
        expect(await book.transcript(log.id), contains('r7-marker-42'));
        expect(await book.transcript(log.id), isNot(contains('\x1B[')));
      } finally {
        sshd?.kill();
        await sshd?.exitCode;
        await root.delete(recursive: true);
      }
    }, skip: tools ? null : 'OpenSSH unavailable');
  });
}
