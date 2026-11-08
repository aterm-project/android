import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:aterm_client/attachments/attachment_file_saver_model.dart';
import 'package:aterm_client/ssh/scp_transfer_service.dart';

void main() {
  final url = Platform.environment['ATERMIUS_TRANSFER_FIXTURE_URL'];
  final ca = Platform.environment['ATERMIUS_TRANSFER_FIXTURE_CA'];
  test(
    'real SFTP and SCP streaming roundtrip, no-overwrite, cancellation cleanup',
    () async {
      SSHClient? client;
      Directory? local;
      String? remote;
      Map<String, dynamic>? login;
      String? password;
      try {
        final fixture = await HttpOverrides.runWithHttpOverrides(() async {
          final http = HttpClient(
            context: SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificates(ca!),
          );
          try {
            final response = await (await http.getUrl(Uri.parse(url!))).close();
            if (response.statusCode != 200) throw StateError('fixture');
            return jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
          } finally {
            http.close(force: true);
          }
        }, _Network());
        login = fixture;
        password = fixture.remove('password') as String;
        client = SSHClient(
          await SSHSocket.connect(
            fixture['host'] as String,
            fixture['port'] as int,
          ),
          username: fixture['username'] as String,
          onPasswordRequest: () => password!,
          onVerifyHostKey: (type, key) =>
              type == 'ssh-ed25519' &&
              utf8.decode(key) == fixture['fingerprint'],
        );
        await client.authenticated.timeout(const Duration(seconds: 30));
        remote = '/tmp/atermius-transfer-${const Uuid().v4()}';
        await File('/tmp/atermius-transfer-20261105/owned-remote.json').writeAsString(jsonEncode({'path': remote}));
        local = await Directory.systemTemp.createTemp('atermius-transfer-');
        await _exec(
          client,
          'umask 077; mkdir -- ${quoteSshTransferPath(remote)}',
        );
        final service = SshFileTransferService(client);
        final data = Uint8List.fromList(
          List.generate(1024 * 1024 + 17, (n) => (n * 17 + 31) % 251),
        );
        Stream<Uint8List> source() async* {
          for (var n = 0; n < data.length; n += 16384) {
            yield Uint8List.sublistView(
              data,
              n,
              n + 16384 > data.length ? data.length : n + 16384,
            );
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }

        for (final protocol in SshTransferProtocol.values) {
          final path = "$remote/-space '中文' \$semi; ${protocol.name}.bin";
          var last = 0;
          await service.upload(
            protocol: protocol,
            remotePath: path,
            source: source(),
            size: data.length,
            cancellation: SshTransferCancellation(),
            onProgress: (p) {
              expect(p.transferred, greaterThanOrEqualTo(last));
              last = p.transferred;
            },
          );
          expect(last, data.length);
          final destination = _DiskWriter(
            File('${local.path}/${protocol.name}.bin'),
          );
          final downloaded = await service.download(
            protocol: protocol,
            remotePath: path,
            destination: destination,
            cancellation: SshTransferCancellation(),
          );
          expect(downloaded, data.length);
          expect(
            sha256.convert(await destination.target.readAsBytes()),
            sha256.convert(data),
          );
          expect(await destination.partial.exists(), false);
          await expectLater(
            service.upload(
              protocol: protocol,
              remotePath: path,
              source: Stream.value(Uint8List.fromList([99])),
              size: 1,
              cancellation: SshTransferCancellation(),
            ),
            throwsA(anything),
          );
          final verify = _DiskWriter(
            File('${local.path}/${protocol.name}-unchanged.bin'),
          );
          await service.download(
            protocol: protocol,
            remotePath: path,
            destination: verify,
            cancellation: SshTransferCancellation(),
          );
          expect(
            sha256.convert(await verify.target.readAsBytes()),
            sha256.convert(data),
          );
          final cancelUpload = SshTransferCancellation();
          final partialPath = '$remote/cancel-${protocol.name}.bin';
          await expectLater(
            service.upload(
              protocol: protocol,
              remotePath: partialPath,
              source: source(),
              size: data.length,
              cancellation: cancelUpload,
              onProgress: (p) {
                if (p.transferred >= 16384) cancelUpload.cancel();
              },
            ),
            throwsA(isA<SshTransferCancelled>()),
          );
          final check = await client.sftp();
          try {
            expect(
              (await check.listdir(remote)).where(
                (n) =>
                    n.filename == 'cancel-${protocol.name}.bin' ||
                    n.filename.startsWith('.atermius-transfer-'),
              ),
              isEmpty,
            );
          } finally {
            await check.close();
          }
          final cancelDownload = SshTransferCancellation();
          final aborted = _DiskWriter(
            File('${local.path}/${protocol.name}-cancel.bin'),
          );
          await expectLater(
            service.download(
              protocol: protocol,
              remotePath: path,
              destination: aborted,
              cancellation: cancelDownload,
              onProgress: (p) {
                if (p.transferred > 0) cancelDownload.cancel();
              },
            ),
            throwsA(isA<SshTransferCancelled>()),
          );
          expect(aborted.aborted, true);
          expect(await aborted.target.exists(), false);
          expect(await aborted.partial.exists(), false);
          debugPrint(
            'TRANSFER_SSH_PASS protocol=${protocol.name} bytes=${data.length} sha256=${sha256.convert(data)} roundtrip/no-overwrite/unicode/cancel-cleanup',
          );
        }
      } catch (error) {
        fail('Transfer acceptance failed (${error.runtimeType})');
      } finally {
        try {
          if (client != null && remote != null) {
            try { await _exec(client, 'rm -rf -- ${quoteSshTransferPath(remote)}'); }
            catch (_) {
              final cleanup = SSHClient(await SSHSocket.connect(login!['host'] as String, login['port'] as int), username: login['username'] as String, onPasswordRequest: () => password!, onVerifyHostKey: (type, key) => type == 'ssh-ed25519' && utf8.decode(key) == login!['fingerprint']);
              try { await cleanup.authenticated.timeout(const Duration(seconds:30)); await _exec(cleanup, 'rm -rf -- ${quoteSshTransferPath(remote)}'); }
              finally {cleanup.close(); await cleanup.done;}
            }
          }
        } finally {
          client?.close(); await client?.done;
          if (local != null) await local.delete(recursive: true);
          password = null;
        }
      }
    },
    skip: url == null || ca == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _exec(SSHClient client, String command) async {
  final session = await client.execute(command);
  var bytes = 0;
  final drain = Future.wait([
    session.stdout.forEach((p) {
      bytes += p.length;
      if (bytes > 4096) session.channel.destroy();
    }),
    session.stderr.forEach((p) {
      bytes += p.length;
      if (bytes > 4096) session.channel.destroy();
    }),
  ]);
  await drain.timeout(const Duration(seconds: 20));
  await session.done.timeout(const Duration(seconds: 20));
  if (session.exitCode != 0) throw StateError('Remote setup/cleanup failed');
}

class _Network extends HttpOverrides {}

class _DiskWriter implements AttachmentStreamingSaveWriter {
  _DiskWriter(this.target) : partial = File('${target.path}.partial');
  final File target;
  final File partial;
  bool aborted = false;
  @override
  Future<void> write(Uint8List bytes) async {
    await partial.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  @override
  Future<void> commit() async {
    if (!await partial.exists()) await partial.create();
    await partial.rename(target.path);
  }

  @override
  Future<void> abort() async {
    aborted = true;
    if (await partial.exists()) await partial.delete();
  }
}
