import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/local_profile_sftp_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/sftp/sftp_text_editor_service.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

const _enableLocalVaultJumpAcceptance =
    'ATERMIUS_RUN_LOCALVAULT_JUMP_SSHD_TEST';
const _targetMarker = '__LOCALVAULT_JUMP_TARGET_OK__';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final enabled =
      Platform.isLinux &&
      Platform.environment[_enableLocalVaultJumpAcceptance] == '1';

  test(
    'LocalVault opens a real two-hop OpenSSH route with per-hop trust and credentials',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atermius-local-jump-sshd-',
      );
      final servers = <_TemporarySshd>[];
      final processes = <Process>[];
      final serverPorts = <int>[];
      LocalProfileCatalog? catalog;
      LocalVaultDatabase? database;
      UnlockedLocalProfile? profile;
      SshConnection? connection;
      FilePicker? originalFilePicker;
      var filePickerOverridden = false;
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );

      try {
        final sshdPath = _findExecutable('sshd');
        final sshKeygenPath = _findExecutable('ssh-keygen');
        final sshUser = await _currentSshUser();
        const ids = Uuid();
        final crypto = VaultCrypto(await SodiumSumoInit.init());

        catalog = LocalProfileCatalog.forTesting(
          NativeDatabase(File('${root.path}/catalog.sqlite')),
        );
        final profileService = LocalProfileService(
          catalog: catalog,
          crypto: crypto,
        );
        profile = await profileService.create(
          password: 'loopback-only-${ids.v4()}',
        );
        database = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File('${root.path}/vault.sqlite')),
          profileId: profile.record.profileId,
          localDataDomainId: profile.record.localDataDomainId,
          localVaultId: profile.record.localVaultId,
        );
        final repository = LocalHostRepository(
          database: database,
          profile: profile,
          crypto: crypto,
        );

        final privateKeyPaths = <String>[];
        final fingerprints = <String>[];
        for (var index = 0; index < 3; index++) {
          final name = switch (index) {
            0 => 'first-bastion',
            1 => 'second-bastion',
            _ => 'target',
          };
          final privateKeyPath = '${root.path}/$name-user-key';
          final hostKeyPath = '${root.path}/$name-host-key';
          final authorizedKeysPath = '${root.path}/$name-authorized-keys';
          final configPath = '${root.path}/$name-sshd.conf';
          final logPath = '${root.path}/$name-sshd.log';
          privateKeyPaths.add(privateKeyPath);

          await _run(sshKeygenPath, [
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-f',
            privateKeyPath,
          ]);
          await _run(sshKeygenPath, [
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-f',
            hostKeyPath,
          ]);
          final publicKey = await _run(sshKeygenPath, [
            '-y',
            '-f',
            privateKeyPath,
          ]);
          await File(authorizedKeysPath).writeAsString('${publicKey.stdout}\n');
          final fingerprint = await _run(sshKeygenPath, [
            '-lf',
            '$hostKeyPath.pub',
            '-E',
            'sha256',
          ]);
          fingerprints.add(fingerprint.stdout.trim().split(RegExp(r'\s+'))[1]);

          final port = await _allocateLoopbackPort();
          serverPorts.add(port);
          await File(configPath).writeAsString('''
AddressFamily inet
ListenAddress 127.0.0.1
Port $port
HostKey $hostKeyPath
PidFile ${root.path}/$name-sshd.pid
AuthorizedKeysFile $authorizedKeysPath
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $sshUser
PermitRootLogin yes
StrictModes no
UsePAM no
UseDNS no
AllowTcpForwarding yes
GatewayPorts no
PermitTTY yes
Subsystem sftp internal-sftp
AllowAgentForwarding no
X11Forwarding no
PrintMotd no
LogLevel VERBOSE
''');
          await _run(sshdPath, ['-t', '-f', configPath]);
          final process = await Process.start(sshdPath, [
            '-D',
            '-e',
            '-f',
            configPath,
            '-E',
            logPath,
          ]);
          processes.add(process);
          unawaited(process.stdout.drain<void>());
          unawaited(process.stderr.drain<void>());
          final server = _TemporarySshd(
            process: process,
            port: port,
            logPath: logPath,
          );
          servers.add(server);
          await _waitForSshd(server);
        }

        final credentials = <CredentialRecord>[];
        for (var index = 0; index < privateKeyPaths.length; index++) {
          final credential = CredentialRecord(
            id: ids.v4(),
            name: 'synthetic route key $index',
            username: sshUser,
            kind: AuthKind.privateKey,
            privateKey: await File(privateKeyPaths[index]).readAsString(),
          );
          credentials.add(await repository.createCredential(credential));
        }

        final bastion = await repository.createHost(
          HostRecord(
            id: ids.v4(),
            name: 'First isolated bastion',
            address: '127.0.0.1',
            port: serverPorts[0],
            username: sshUser,
            credentialId: credentials[0].id,
          ),
        );
        final middle = await repository.createHost(
          HostRecord(
            id: ids.v4(),
            name: 'Second isolated bastion',
            address: '127.0.0.1',
            port: serverPorts[1],
            username: sshUser,
            credentialId: credentials[1].id,
            jumpHostId: bastion.id,
          ),
        );
        final target = await repository.createHost(
          HostRecord(
            id: ids.v4(),
            name: 'Isolated final target',
            address: '127.0.0.1',
            port: serverPorts[2],
            username: sshUser,
            credentialId: credentials[2].id,
            jumpHostId: middle.id,
          ),
        );

        final directEndpoints = <(String, int)>[];
        var relayCalls = 0;
        final service = SshService(
          api: null,
          deviceId: repository.localDeviceId,
          useRelay: false,
          knownHostDecisionLock: repository.knownHostDecisionLock,
          directSocketConnector: (host, port) async {
            directEndpoints.add((host, port));
            return SSHSocket.connect(
              host,
              port,
              timeout: const Duration(seconds: 3),
            );
          },
          relaySocketConnector: (_, _) async {
            relayCalls++;
            throw StateError('LocalVault SSH must not create a Relay socket.');
          },
        );
        expect(service.api, isNull);
        final controller = LocalProfileSshController(
          repository: repository,
          serviceForTesting: service,
        );
        final approvals = <LocalKnownHostApprovalRequest>[];
        connection = await controller.connect(
          host: target,
          credential: credentials[2],
          askApproval: (request) async {
            approvals.add(request);
            final index = approvals.length - 1;
            expect(index, lessThan(3));
            expect(request.host, '127.0.0.1');
            expect(request.port, serverPorts[index]);
            expect(request.algorithm, 'ssh-ed25519');
            expect(request.fingerprint, fingerprints[index]);
            return true;
          },
        );

        // Run the real target command through the final authenticated client.
        final targetCommand = await connection.client.runWithResult(
          "printf '$_targetMarker'",
        );
        expect(targetCommand.exitCode, 0);
        expect(utf8.decode(targetCommand.stdout), _targetMarker);
        expect(approvals.map((item) => item.port), serverPorts);
        expect(directEndpoints, List.filled(4, ('127.0.0.1', serverPorts[0])));
        expect(relayCalls, 0);
        expect(await repository.listKnownHosts(), hasLength(3));

        final sftp = LocalProfileSftpController(connection: connection);
        final sftpFolderName = 'atermius-local-${ids.v4()}';
        final sftpFolder = '/tmp/$sftpFolderName';
        final uploaded = Uint8List.fromList(
          utf8.encode('private local SFTP\n'),
        );
        final streamingTarget = File('${root.path}/streamed-download.txt');
        final appSupport = Directory('${root.path}/app-support')
          ..createSync(recursive: true);
        Uint8List? downloaded;
        try {
          try {
            originalFilePicker = FilePicker.platform;
          } on Object {
            // The native plugin is not registered in a standalone test.
          }
          FilePicker.platform = _SavePicker(streamingTarget.path);
          filePickerOverridden = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                pathProviderChannel,
                (call) async => appSupport.path,
              );

          await sftp.createDirectory('/tmp', sftpFolderName);
          await sftp.uploadFile(
            parent: sftpFolder,
            name: 'note.txt',
            bytes: uploaded,
          );
          final listed = await sftp.listDirectory(sftpFolder);
          expect(listed.map((entry) => entry.filename), ['note.txt']);
          await expectLater(
            sftp.uploadFile(
              parent: sftpFolder,
              name: 'note.txt',
              bytes: Uint8List.fromList(utf8.encode('must not overwrite')),
            ),
            throwsA(isA<StateError>()),
          );
          downloaded = await sftp.downloadFile(
            parent: sftpFolder,
            name: 'note.txt',
          );
          expect(downloaded, uploaded);
          final streamingWriter = await openAttachmentStreamingSave(
            fileName: 'streamed-download.txt',
            mediaType: 'text/plain',
          );
          expect(streamingWriter, isNotNull);
          final streamedBytes = await sftp.downloadFileTo(
            parent: sftpFolder,
            name: 'note.txt',
            destination: streamingWriter!,
          );
          expect(streamedBytes, uploaded.length);
          expect(await streamingTarget.readAsBytes(), uploaded);
          expect(
            appSupport
                .listSync(recursive: true)
                .where((entity) => entity.path.endsWith('.partial')),
            isEmpty,
          );

          final document = await sftp.openTextFile(
            parent: sftpFolder,
            name: 'note.txt',
          );
          expect(document.text, 'private local SFTP\n');
          final save = await sftp.saveTextFile(document, 'edited locally\n');
          expect(save, isA<SftpTextSaveSuccess>());
          (save as SftpTextSaveSuccess).document.dispose();
          document.dispose();
          downloaded.fillRange(0, downloaded.length, 0);
          downloaded = await sftp.downloadFile(
            parent: sftpFolder,
            name: 'note.txt',
          );
          expect(utf8.decode(downloaded), 'edited locally\n');

          final file = (await sftp.listDirectory(sftpFolder)).single;
          await sftp.deleteEntry(parent: sftpFolder, item: file);
          final folder = (await sftp.listDirectory(
            '/tmp',
          )).singleWhere((entry) => entry.filename == sftpFolderName);
          await sftp.deleteEntry(parent: '/tmp', item: folder);
          expect(
            (await sftp.listDirectory(
              '/tmp',
            )).any((entry) => entry.filename == sftpFolderName),
            isFalse,
          );
        } finally {
          uploaded.fillRange(0, uploaded.length, 0);
          if (downloaded != null) {
            downloaded.fillRange(0, downloaded.length, 0);
          }
          await sftp.close();
          // The SFTP assertions should remove the fixture directory; this
          // direct cleanup covers a failing assertion without masking it.
          final remaining = Directory(sftpFolder);
          if (await remaining.exists()) await remaining.delete(recursive: true);
        }

        final acceptedCounts = <int>[];
        for (final server in servers) {
          final log = await File(server.logPath).readAsString();
          acceptedCounts.add(
            RegExp(r'Accepted publickey for ').allMatches(log).length,
          );
        }
        // Each deeper unknown key aborts the current route after the preceding
        // hop authenticates. Approval always retries from the first bastion.
        expect(acceptedCounts, [3, 2, 1]);
      } finally {
        if (filePickerOverridden) {
          if (originalFilePicker != null) {
            FilePicker.platform = originalFilePicker;
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pathProviderChannel, null);
        }
        await connection?.close();
        for (final process in processes.reversed) {
          await _stopProcess(process);
        }
        if (database != null) await database.close();
        await profile?.lock();
        await catalog?.close();
        if (await root.exists()) await root.delete(recursive: true);
      }

      expect(await root.exists(), isFalse);
      for (final server in servers) {
        expect(await _canConnect(server.port), isFalse);
      }
    },
    skip: enabled
        ? null
        : 'Set $_enableLocalVaultJumpAcceptance=1 on Linux with OpenSSH installed.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _SavePicker extends FilePicker {
  _SavePicker(this.path);

  final String path;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('$executable failed with exit ${result.exitCode}');
  }
  return result;
}

String _findExecutable(String name) {
  final path = Platform.environment['PATH'];
  if (path == null) throw StateError('PATH is unavailable');
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    final candidate = File('$directory/$name');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  throw StateError('Required executable is not installed: $name');
}

Future<String> _currentSshUser() async {
  final fromEnvironment = Platform.environment['USER'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final result = await Process.run('id', ['-un']);
  if (result.exitCode != 0) throw StateError('Could not determine SSH user.');
  return (result.stdout as String).trim();
}

Future<int> _allocateLoopbackPort() async {
  final lease = await ServerSocket.bind('127.0.0.1', 0);
  final port = lease.port;
  await lease.close();
  return port;
}

Future<void> _waitForSshd(_TemporarySshd server) async {
  var exited = false;
  var exitCode = -1;
  unawaited(
    server.process.exitCode.then((code) {
      exited = true;
      exitCode = code;
    }),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (exited) throw StateError('Temporary sshd exited with code $exitCode.');
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        server.port,
        timeout: const Duration(milliseconds: 250),
      );
      socket.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  throw StateError('Temporary sshd did not listen on loopback.');
}

Future<void> _stopProcess(Process process) async {
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 3));
  }
}

Future<bool> _canConnect(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 250),
    );
    return true;
  } on SocketException {
    return false;
  } finally {
    socket?.destroy();
  }
}

final class _TemporarySshd {
  const _TemporarySshd({
    required this.process,
    required this.port,
    required this.logPath,
  });

  final Process process;
  final int port;
  final String logPath;
}
