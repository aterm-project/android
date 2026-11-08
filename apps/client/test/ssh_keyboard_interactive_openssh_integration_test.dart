import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _enableKbdintAcceptance = 'ATERMIUS_RUN_SSHD_KBDINT_TEST';
const _pamServiceDirectory = '/etc/pam.d';
const _pamModuleHeaders = '/usr/include/security/pam_modules.h';
const _pamApplicationHeaders = '/usr/include/security/pam_appl.h';

void main() {
  final skipReason = _prerequisiteSkipReason();

  test(
    'OpenSSH PAM keyboard-interactive accepts two rounds and cancellation aborts',
    () async {
      final fixture = await _OpenSshKbdintFixture.create();
      try {
        final pamService = File(fixture.pamServicePath);
        final originalPamService = await pamService.readAsString();
        expect((await pamService.stat()).mode & 0x1ff, 0x180);
        await expectLater(
          _writeExclusivePamService(
            fixture.serviceWriterPath,
            fixture.pamServicePath,
            'auth required pam_deny.so\n',
          ),
          throwsA(isA<StateError>()),
        );
        expect(await pamService.readAsString(), originalPamService);
        try {
          await _assertTwoPromptRounds(fixture);
          await _assertCancellationAbortsWithoutPasswordFallback(fixture);
        } catch (error, stackTrace) {
          Error.throwWithStackTrace(
            StateError('$error\nTemporary sshd logs:\n${fixture.logs}'),
            stackTrace,
          );
        }
      } finally {
        await fixture.close();
      }
      expect(File(fixture.pamServicePath).existsSync(), isFalse);
      expect(fixture.root.existsSync(), isFalse);
      expect(fixture.sshdExitCodes, hasLength(2));
      expect(fixture.sshdExitCodes, everyElement(isNotNull));
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String? _prerequisiteSkipReason() {
  if (!Platform.isLinux) return 'Requires Linux.';
  if (Platform.environment[_enableKbdintAcceptance] != '1') {
    return 'Set $_enableKbdintAcceptance=1 to run the optional OpenSSH/PAM acceptance.';
  }

  final uid = Process.runSync('id', ['-u']);
  if (uid.exitCode != 0 || uid.stdout.toString().trim() != '0') {
    return 'Requires root to start isolated sshd and create a temporary PAM service.';
  }

  if (_findExecutablePath('sshd') == null) {
    return 'Requires OpenSSH sshd.';
  }
  if (_findExecutablePath('cc') == null)
    return 'Requires a C compiler named cc.';
  for (final header in [_pamModuleHeaders, _pamApplicationHeaders]) {
    if (!File(header).existsSync()) {
      return 'Requires Linux-PAM development headers ($header).';
    }
  }
  if (!Directory(_pamServiceDirectory).existsSync()) {
    return 'Requires the Linux PAM service directory $_pamServiceDirectory.';
  }
  if (_findExecutablePath('ssh-keygen') == null) return 'Requires ssh-keygen.';
  return null;
}

Future<void> _assertTwoPromptRounds(_OpenSshKbdintFixture fixture) async {
  final requests = <SSHUserInfoRequest>[];
  final clientEvents = <String>[];
  var keyboardInteractiveStarted = false;
  var authenticatedCallback = false;
  var passwordRequestsBeforeKbdint = 0;
  var passwordRequestsAfterKbdint = 0;
  final client = await fixture.connect(
    onUserInfoRequest: (request) {
      keyboardInteractiveStarted = true;
      requests.add(request);
      if (requests.length == 1) return ['atermius-kbdint-code'];
      if (requests.length == 2) return ['620914'];
      // OpenSSH sends a final empty PAM conversation before USERAUTH_SUCCESS.
      if (requests.length == 3 && request.prompts.isEmpty) return const [];
      throw StateError(
        'OpenSSH sent an unexpected keyboard-interactive request.',
      );
    },
    onPasswordRequest: () {
      // dartssh2 probes configured password auth before keyboard-interactive.
      // Returning null exhausts that initial probe; count later calls separately.
      if (keyboardInteractiveStarted) {
        passwordRequestsAfterKbdint++;
      } else {
        passwordRequestsBeforeKbdint++;
      }
      return null;
    },
    onAuthenticated: () => authenticatedCallback = true,
    printDebug: (message) {
      if (message?.startsWith('SSHClient._') ?? false) {
        clientEvents.add(message!);
      }
    },
  );

  try {
    try {
      await client.authenticated.timeout(const Duration(seconds: 15));
    } catch (error) {
      throw StateError(
        '$error; received ${requests.length} user-info requests; '
        'authenticated callback=$authenticatedCallback; '
        'client events=$clientEvents',
      );
    }
    expect(requests, hasLength(3));
    expect(requests[0].name, isEmpty);
    expect(requests[0].instruction, isEmpty);
    expect(requests[0].prompts, hasLength(1));
    expect(requests[0].prompts.single.promptText, 'Account code:');
    expect(requests[0].prompts.single.echo, isTrue);
    expect(requests[1].name, isEmpty);
    expect(requests[1].instruction, isEmpty);
    expect(requests[1].prompts, hasLength(1));
    expect(requests[1].prompts.single.promptText, 'One-time code:');
    expect(requests[1].prompts.single.echo, isFalse);
    expect(requests[2].prompts, isEmpty);
    expect(passwordRequestsBeforeKbdint, 1);
    expect(passwordRequestsAfterKbdint, 0);
    expect(client.isClosed, isFalse);
  } finally {
    client.close();
  }
}

Future<void> _assertCancellationAbortsWithoutPasswordFallback(
  _OpenSshKbdintFixture fixture,
) async {
  final challenge = Completer<SSHUserInfoRequest>();
  final cancel = Completer<void>();
  var keyboardInteractiveStarted = false;
  var userInfoCalls = 0;
  var passwordRequestsBeforeKbdint = 0;
  var passwordRequestsAfterKbdint = 0;
  final client = await fixture.connect(
    port: fixture.kbdThenPasswordPort,
    onUserInfoRequest: (request) async {
      keyboardInteractiveStarted = true;
      userInfoCalls++;
      if (!challenge.isCompleted) challenge.complete(request);
      await cancel.future;
      throw const SshKeyboardInteractiveCancelled();
    },
    onPasswordRequest: () {
      // Ignore dartssh2's pre-KBI password probe. A post-challenge call would
      // mean cancellation fell through to the configured next factor.
      if (keyboardInteractiveStarted) {
        passwordRequestsAfterKbdint++;
      } else {
        passwordRequestsBeforeKbdint++;
      }
      return null;
    },
  );

  try {
    final authentication = client.authenticated;
    final request = await challenge.future.timeout(const Duration(seconds: 10));
    expect(request.prompts, hasLength(1));
    expect(request.prompts.single.promptText, 'Account code:');
    expect(request.prompts.single.echo, isTrue);
    cancel.complete();

    Object? authenticationError;
    try {
      await authentication.timeout(const Duration(seconds: 10));
      fail(
        'Cancelled keyboard-interactive authentication unexpectedly succeeded.',
      );
    } catch (error) {
      authenticationError = error;
    }

    expect(authenticationError, isA<SSHAuthAbortError>());
    expect(_containsCancellation(authenticationError), isTrue);
    expect(userInfoCalls, 1);
    expect(passwordRequestsBeforeKbdint, 1);
    expect(passwordRequestsAfterKbdint, 0);
    expect(client.isClosed, isTrue);
  } finally {
    if (!cancel.isCompleted) cancel.complete();
    client.close();
  }
}

bool _containsCancellation(Object? error) => switch (error) {
  SshKeyboardInteractiveCancelled() => true,
  SSHInternalError(:final error) => _containsCancellation(error),
  SSHAuthAbortError(:final reason) => _containsCancellation(reason),
  _ => false,
};

class _OpenSshKbdintFixture {
  _OpenSshKbdintFixture._({
    required this.root,
    required this.kbdOnlySshd,
    required this.kbdOnlyPort,
    required this.kbdThenPasswordSshd,
    required this.kbdThenPasswordPort,
    required this.expectedFingerprint,
    required this.pamServicePath,
    required this.serviceWriterPath,
    required this.kbdOnlyLogs,
    required this.kbdThenPasswordLogs,
  });

  final Directory root;
  final Process kbdOnlySshd;
  final int kbdOnlyPort;
  final Process kbdThenPasswordSshd;
  final int kbdThenPasswordPort;
  final String expectedFingerprint;
  final String pamServicePath;
  final String serviceWriterPath;
  final StringBuffer kbdOnlyLogs;
  final StringBuffer kbdThenPasswordLogs;

  String get logs =>
      'KBI-only:\n$kbdOnlyLogs\nKBI-then-password:\n$kbdThenPasswordLogs';

  final List<int?> sshdExitCodes = [];
  bool _closed = false;

  static Future<_OpenSshKbdintFixture> create() async {
    final root = await Directory.systemTemp.createTemp('atermius-ssh-kbdint-');
    Process? kbdOnlySshd;
    Process? kbdThenPasswordSshd;
    String? pamServicePath;
    var ownsPamService = false;
    final kbdOnlyLogs = StringBuffer();
    final kbdThenPasswordLogs = StringBuffer();
    try {
      final hostKeyPath = '${root.path}/host-key';
      final configPath = '${root.path}/sshd_kbdint_only_config';
      final kbdThenPasswordConfigPath =
          '${root.path}/sshd_kbdint_then_password_config';
      final pamModulePath = '${root.path}/libatermius_pam_kbdint.so';
      final serviceName = _uniquePamServiceName();
      pamServicePath = '$_pamServiceDirectory/$serviceName';

      final serviceWriterPath = await _compilePamFixture(pamModulePath);
      await _run(_findExecutablePath('ssh-keygen')!, [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        hostKeyPath,
      ]);
      final fingerprintResult = await _run('ssh-keygen', [
        '-lf',
        '$hostKeyPath.pub',
        '-E',
        'sha256',
      ]);
      final expectedFingerprint = fingerprintResult.stdout.trim().split(
        RegExp(r'\s+'),
      )[1];

      final portLease = await ServerSocket.bind('127.0.0.1', 0);
      final secondPortLease = await ServerSocket.bind('127.0.0.1', 0);
      final kbdOnlyPort = portLease.port;
      final kbdThenPasswordPort = secondPortLease.port;
      await portLease.close();
      await secondPortLease.close();

      await _writeExclusivePamService(
        serviceWriterPath,
        pamServicePath,
        'auth requisite $pamModulePath\n'
        'account required pam_permit.so\n'
        'session required pam_permit.so\n',
      );
      ownsPamService = true;
      await File(configPath).writeAsString(
        _sshdConfig(
          root: root,
          hostKeyPath: hostKeyPath,
          port: kbdOnlyPort,
          serviceName: serviceName,
          authenticationMethods: 'keyboard-interactive',
          passwordAuthentication: 'no',
          pidFileName: 'sshd-kbdint-only.pid',
        ),
      );
      await File(kbdThenPasswordConfigPath).writeAsString(
        _sshdConfig(
          root: root,
          hostKeyPath: hostKeyPath,
          port: kbdThenPasswordPort,
          serviceName: serviceName,
          authenticationMethods: 'keyboard-interactive,password',
          passwordAuthentication: 'yes',
          pidFileName: 'sshd-kbdint-password.pid',
        ),
      );
      final sshdPath = _findExecutablePath('sshd')!;
      await _run(sshdPath, ['-t', '-f', configPath]);
      await _run(sshdPath, ['-t', '-f', kbdThenPasswordConfigPath]);

      kbdOnlySshd = await _startSshd(configPath, kbdOnlyLogs);
      await _connectWhenReady(kbdOnlyPort, kbdOnlySshd, kbdOnlyLogs);
      kbdThenPasswordSshd = await _startSshd(
        kbdThenPasswordConfigPath,
        kbdThenPasswordLogs,
      );
      await _connectWhenReady(
        kbdThenPasswordPort,
        kbdThenPasswordSshd,
        kbdThenPasswordLogs,
      );

      return _OpenSshKbdintFixture._(
        root: root,
        kbdOnlySshd: kbdOnlySshd,
        kbdOnlyPort: kbdOnlyPort,
        kbdThenPasswordSshd: kbdThenPasswordSshd,
        kbdThenPasswordPort: kbdThenPasswordPort,
        expectedFingerprint: expectedFingerprint,
        pamServicePath: pamServicePath,
        serviceWriterPath: serviceWriterPath,
        kbdOnlyLogs: kbdOnlyLogs,
        kbdThenPasswordLogs: kbdThenPasswordLogs,
      );
    } catch (_) {
      await _stopSshd(kbdThenPasswordSshd);
      await _stopSshd(kbdOnlySshd);
      if (ownsPamService && pamServicePath != null) {
        await _deleteOwnedPamService(pamServicePath);
      }
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<SSHClient> connect({
    required SSHUserInfoRequestHandler onUserInfoRequest,
    required SSHPasswordRequestHandler onPasswordRequest,
    int? port,
    SSHAuthenticatedHandler? onAuthenticated,
    void Function(String? message)? printDebug,
  }) async {
    final socket = await SSHSocket.connect(
      '127.0.0.1',
      port ?? kbdOnlyPort,
      timeout: const Duration(seconds: 5),
    );
    return SSHClient(
      socket,
      username: 'root',
      onUserInfoRequest: onUserInfoRequest,
      onPasswordRequest: onPasswordRequest,
      onAuthenticated: onAuthenticated,
      printDebug: printDebug,
      authTimeout: const Duration(seconds: 20),
      onVerifyHostKey: (type, fingerprint) =>
          type == 'ssh-ed25519' &&
          utf8.decode(fingerprint) == expectedFingerprint,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      sshdExitCodes.add(await _stopSshd(kbdThenPasswordSshd));
      sshdExitCodes.add(await _stopSshd(kbdOnlySshd));
    } finally {
      try {
        await _deleteOwnedPamService(pamServicePath);
      } finally {
        await root.delete(recursive: true);
      }
    }
  }
}

String _sshdConfig({
  required Directory root,
  required String hostKeyPath,
  required int port,
  required String serviceName,
  required String authenticationMethods,
  required String passwordAuthentication,
  required String pidFileName,
}) =>
    '''
AddressFamily inet
ListenAddress 127.0.0.1
Port $port
HostKey $hostKeyPath
PidFile ${root.path}/$pidFileName
AuthorizedKeysFile none
PubkeyAuthentication no
PasswordAuthentication $passwordAuthentication
KbdInteractiveAuthentication yes
AuthenticationMethods $authenticationMethods
PermitRootLogin yes
AllowUsers root
StrictModes no
UsePAM yes
PAMServiceName $serviceName
UseDNS no
PermitTTY no
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PrintMotd no
LogLevel DEBUG2
''';

Future<String> _compilePamFixture(String outputPath) async {
  final source = _findPamFixtureSource();
  final compiler = _findExecutablePath('cc');
  if (source == null || compiler == null) {
    throw StateError('PAM fixture source or cc compiler was not found.');
  }
  await _run(compiler, [
    '-std=c11',
    '-shared',
    '-fPIC',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-Wno-unused-parameter',
    '-o',
    outputPath,
    source.path,
    '-lpam',
  ]);
  final serviceWriterPath = '$outputPath.service-writer';
  await _run(compiler, [
    '-std=c11',
    '-DPAM_SERVICE_WRITER',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-o',
    serviceWriterPath,
    source.path,
  ]);
  return serviceWriterPath;
}

File? _findPamFixtureSource() {
  final candidates = [
    File('test/fixtures/pam_keyboard_interactive_fixture.c'),
    File('apps/client/test/fixtures/pam_keyboard_interactive_fixture.c'),
  ];
  for (final candidate in candidates) {
    if (candidate.existsSync()) return candidate.absolute;
  }
  return null;
}

Future<void> _writeExclusivePamService(
  String writerPath,
  String path,
  String content,
) async {
  final file = File(path);
  final result = await Process.run(writerPath, [path, content]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not create unique PAM service file: ${result.stderr.toString().trim()}',
    );
  }
  final mode = (await file.stat()).mode & 0x1ff;
  if (mode != 0x180) {
    await file.delete();
    throw StateError('Temporary PAM service file mode is not 0600.');
  }
}

Future<void> _deleteOwnedPamService(String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  await file.delete();
}

String _uniquePamServiceName() {
  final random = Random.secure();
  final suffix = List.generate(
    20,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  return 'atermius-kbdint-${pid.toRadixString(16)}-$suffix';
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError(
      '$executable exited ${result.exitCode}: ${result.stderr.toString().trim()}',
    );
  }
  return result;
}

String? _findExecutablePath(String name) {
  final path = Platform.environment['PATH'];
  if (path == null) return null;
  for (final directory in path.split(':')) {
    final candidate = File('$directory/$name');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  return null;
}

Future<Process> _startSshd(String configPath, StringBuffer logs) async {
  final sshdPath = _findExecutablePath('sshd');
  if (sshdPath == null) throw StateError('OpenSSH sshd disappeared from PATH.');
  final process = await Process.start(sshdPath, ['-D', '-e', '-f', configPath]);
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.transform(utf8.decoder).forEach(logs.write));
  return process;
}

Future<void> _connectWhenReady(
  int port,
  Process process,
  StringBuffer logs,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final socketResult = SSHSocket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 250),
    );
    final result = await Future.any<Object?>([
      socketResult.then<Object?>((socket) {
        unawaited(socket.close());
        return socket;
      }, onError: (_) => null),
      process.exitCode.then<Object?>((code) => code),
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    if (result is SSHSocket) return;
    if (result is int) {
      throw StateError(
        'Temporary sshd exited with code $result before listening: $logs',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Temporary sshd did not listen on loopback.');
}

Future<int?> _stopSshd(Process? process) async {
  if (process == null) return null;
  final killed = process.kill(ProcessSignal.sigterm);
  if (!killed) {
    try {
      return await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return null;
    }
  }
  try {
    return await process.exitCode.timeout(const Duration(seconds: 4));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    try {
      return await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return null;
    }
  }
}
