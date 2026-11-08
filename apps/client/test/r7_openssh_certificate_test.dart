import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/openssh_certificate.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real OpenSSH fixtures: keys/certificates are generated with ssh-keygen in a
/// private temp directory and a loopback sshd trusts only the test CA
/// (`AuthorizedKeysFile none`), so a successful login proves certificate auth.
void main() {
  final tools =
      !Platform.isWindows &&
      _which('ssh-keygen') != null &&
      _which('sshd') != null;
  late Directory root;
  late String caKey;

  setUpAll(() async {
    if (!tools) return;
    root = await Directory.systemTemp.createTemp('atermius-r7-cert-');
    caKey = '${root.path}/ca';
    await _keygen(['-t', 'ed25519', '-N', '', '-f', caKey, '-C', 'test-ca']);
  });

  tearDownAll(() async {
    if (tools && await root.exists()) await root.delete(recursive: true);
  });

  Future<({String key, String cert, String pub})> userCert(
    String name,
    List<String> keyArgs, {
    String principals = 'root',
    String validity = '-5m:+1h',
    bool host = false,
    String passphrase = '',
  }) async {
    final path = '${root.path}/$name';
    await _keygen([...keyArgs, '-N', passphrase, '-f', path, '-C', name]);
    await _keygen([
      '-s',
      caKey,
      '-I',
      'id-$name',
      '-n',
      principals,
      '-V',
      validity,
      '-z',
      '42',
      if (host) '-h',
      '$path.pub',
    ]);
    return (
      key: await File(path).readAsString(),
      cert: await File('$path-cert.pub').readAsString(),
      pub: await File('$path.pub').readAsString(),
    );
  }

  group('OpenSshCertificate.parse', () {
    test('decodes a real ed25519 user certificate', () async {
      final fixture = await userCert('ed', ['-t', 'ed25519']);
      final cert = OpenSshCertificate.parse(fixture.cert);
      expect(cert.certificateType, 'ssh-ed25519-cert-v01@openssh.com');
      expect(cert.keyType, 'ssh-ed25519');
      expect(cert.isUserCertificate, isTrue);
      expect(cert.keyId, 'id-ed');
      expect(cert.serial, BigInt.from(42));
      expect(cert.principals, ['root']);
      expect(cert.isValidAt(DateTime.now()), isTrue);
      expect(cert.extensions, contains('permit-pty'));
      final fingerprint = await _keygen(['-lf', '${root.path}/ed.pub']);
      expect(fingerprint.split(' ')[1], cert.keyFingerprint);
      final caFingerprint = await _keygen(['-lf', '$caKey.pub']);
      expect(caFingerprint.split(' ')[1], cert.caFingerprint);
      expect(
        validateUserCertificateForPrivateKey(
          certificateText: fixture.cert,
          privateKey: fixture.key,
        ).keyId,
        'id-ed',
      );
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

    test('rejects host certs, plain keys, garbage and mismatches', () async {
      final hostCert = await userCert('hc', ['-t', 'ed25519'], host: true);
      final other = await userCert('other', ['-t', 'ed25519']);
      final mine = await userCert('mine', ['-t', 'ed25519']);
      expect(OpenSshCertificate.parse(hostCert.cert).isUserCertificate, false);
      expect(
        () => validateUserCertificateForPrivateKey(
          certificateText: hostCert.cert,
          privateKey: hostCert.key,
        ),
        _problem(OpenSshCertificateProblem.notUserCertificate),
      );
      expect(
        () => validateUserCertificateForPrivateKey(
          certificateText: other.cert,
          privateKey: mine.key,
        ),
        _problem(OpenSshCertificateProblem.keyMismatch),
      );
      expect(
        () => OpenSshCertificate.parse(mine.pub),
        _problem(OpenSshCertificateProblem.malformed),
      );
      expect(
        () => OpenSshCertificate.parse(mine.key),
        _problem(OpenSshCertificateProblem.malformed),
      );
      final parts = mine.cert.split(' ');
      final truncated = '${parts[0]} ${parts[1].substring(0, 60)}';
      expect(
        () => OpenSshCertificate.parse(truncated),
        _problem(OpenSshCertificateProblem.malformed),
      );
      expect(
        () => OpenSshCertificate.parse('${mine.cert}\n${mine.cert}'),
        _problem(OpenSshCertificateProblem.malformed),
      );
      expect(
        () => OpenSshCertificate.parse(
          'ssh-ed25519-cert-v01@openssh.com ${'A' * 40000}',
        ),
        _problem(OpenSshCertificateProblem.malformed),
      );
      expect(
        () => validateUserCertificateForPrivateKey(
          certificateText: mine.cert,
          privateKey: 'not a key',
        ),
        _problem(OpenSshCertificateProblem.privateKeyUnreadable),
      );
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

    test('reports expiry and not-yet-valid windows', () async {
      final expired = await userCert(
        'old',
        ['-t', 'ed25519'],
        validity: '20200101:20200102',
      );
      final future = await userCert(
        'future',
        ['-t', 'ed25519'],
        validity: '+1d:+2d',
      );
      final forever = await userCert(
        'forever',
        ['-t', 'ed25519'],
        validity: 'always:forever',
      );
      final now = DateTime.now();
      expect(OpenSshCertificate.parse(expired.cert).isExpiredAt(now), isTrue);
      expect(
        OpenSshCertificate.parse(future.cert).isNotYetValidAt(now),
        isTrue,
      );
      final unbounded = OpenSshCertificate.parse(forever.cert);
      expect(unbounded.validAfter, isNull);
      expect(unbounded.validBefore, isNull);
      expect(unbounded.isValidAt(now), isTrue);
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');
  });

  test('no certificate: plain key login against authorized_keys unchanged', () async {
    final fixture = await userCert('plain', ['-t', 'ed25519']);
    final keys = '${root.path}/plain_authorized_keys';
    await File(keys).writeAsString(fixture.pub);
    final server = await _Sshd.start(
      root,
      '$caKey.pub',
      authorizedKeys: keys,
      name: 'plain-sshd',
    );
    try {
      final connection = await SshService(
        api: null,
        deviceId: 'r7-plain',
        useRelay: false,
      ).connect(
        host: HostRecord(
          id: 'p',
          name: 'plain',
          address: '127.0.0.1',
          port: server.port,
          username: 'root',
        ),
        credential: CredentialRecord(
          id: 'p',
          name: 'p',
          username: 'root',
          kind: AuthKind.privateKey,
          privateKey: fixture.key,
          passphrase: '',
        ),
        verifyHostKey: (_, fp) async => fp == server.hostFingerprint,
      );
      final out = utf8.decode(await connection.client.run('echo plain-ok'));
      await connection.close();
      expect(out.trim(), 'plain-ok');
      final log = await server.log();
      expect(log, contains('Accepted publickey for root'));
      expect(log, isNot(contains('-CERT')));
    } finally {
      await server.stop();
    }
  }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

  group('real sshd TrustedUserCAKeys login', () {
    late _Sshd sshd;

    setUpAll(() async {
      if (!tools) return;
      sshd = await _Sshd.start(root, '$caKey.pub');
    });

    tearDownAll(() async {
      if (tools) await sshd.stop();
    });

    Future<String> run(CredentialRecord credential) async {
      final service = SshService(
        api: null,
        deviceId: 'r7-cert-test',
        useRelay: false,
      );
      final connection = await service.connect(
        host: HostRecord(
          id: 'h',
          name: 'cert host',
          address: '127.0.0.1',
          port: sshd.port,
          username: 'root',
        ),
        credential: credential,
        verifyHostKey: (_, fingerprint) async =>
            fingerprint == sshd.hostFingerprint,
      );
      try {
        final result = await connection.client.run('echo cert-login-ok');
        return utf8.decode(result).trim();
      } finally {
        await connection.close();
      }
    }

    for (final spec in [
      ('ed25519', ['-t', 'ed25519'], 'ED25519-CERT'),
      ('rsa', ['-t', 'rsa', '-b', '2048'], 'RSA-CERT'),
      ('ecdsa', ['-t', 'ecdsa', '-b', '256'], 'ECDSA-CERT'),
    ]) {
      test('${spec.$1} certificate authenticates; key alone is refused', () async {
        final fixture = await userCert('login-${spec.$1}', spec.$2);
        final withCert = CredentialRecord(
          id: 'c-${spec.$1}',
          name: spec.$1,
          username: 'root',
          kind: AuthKind.privateKey,
          privateKey: fixture.key,
          passphrase: '',
          certificate: fixture.cert,
        );
        expect(await run(withCert), 'cert-login-ok');
        expect(
          await sshd.log(),
          contains('Accepted publickey for root'),
        );
        expect(await sshd.log(), contains(spec.$3));
        final keyOnly = CredentialRecord(
          id: 'k-${spec.$1}',
          name: spec.$1,
          username: 'root',
          kind: AuthKind.privateKey,
          privateKey: fixture.key,
        );
        await expectLater(run(keyOnly), throwsA(anything));
      }, skip: tools ? null : 'ssh-keygen/sshd unavailable');
    }

    test('passphrase-protected key with certificate authenticates', () async {
      final fixture = await userCert(
        'locked',
        ['-t', 'ed25519'],
        passphrase: 'correct horse',
      );
      final credential = CredentialRecord(
        id: 'locked',
        name: 'locked',
        username: 'root',
        kind: AuthKind.privateKey,
        privateKey: fixture.key,
        passphrase: 'correct horse',
        certificate: fixture.cert,
      );
      expect(await run(credential), 'cert-login-ok');
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

    test('real CA-only sshd refuses a certificate from an untrusted CA', () async {
      final otherCa = '${root.path}/other-ca';
      await _keygen(['-t', 'ed25519', '-N', '', '-f', otherCa]);
      final path = '${root.path}/rogue';
      await _keygen(['-t', 'ed25519', '-N', '', '-f', path]);
      await _keygen([
        '-s', otherCa, '-I', 'rogue', '-n', 'root', '-V', '-5m:+1h',
        '$path.pub',
      ]);
      // Structurally valid and bound to the key: the client offers it, the
      // server must reject it because it does not trust that CA.
      final cert = await File('$path-cert.pub').readAsString();
      final key = await File(path).readAsString();
      expect(
        validateUserCertificateForPrivateKey(
          certificateText: cert,
          privateKey: key,
        ).isUserCertificate,
        isTrue,
      );
      await expectLater(
        run(
          CredentialRecord(
            id: 'rogue',
            name: 'rogue',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: key,
            certificate: cert,
          ),
        ),
        throwsA(anything),
      );
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

    test('real sshd refuses an expired certificate; host cert never sent', () async {
      final expired = await userCert(
        'expired',
        ['-t', 'ed25519'],
        validity: '20200101:20200102',
      );
      await expectLater(
        run(
          CredentialRecord(
            id: 'e',
            name: 'e',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: expired.key,
            certificate: expired.cert,
          ),
        ),
        throwsA(anything),
      );
      final hostCert = await userCert('hostc', ['-t', 'ed25519'], host: true);
      await expectLater(
        run(
          CredentialRecord(
            id: 'hc',
            name: 'hc',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: hostCert.key,
            certificate: hostCert.cert,
          ),
        ),
        throwsA(isA<SshCredentialException>()),
      );
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');

    test('wrong principal and mismatched certificate fail closed', () async {
      final wrongPrincipal = await userCert(
        'nobody',
        ['-t', 'ed25519'],
        principals: 'someone-else',
      );
      await expectLater(
        run(
          CredentialRecord(
            id: 'p',
            name: 'p',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: wrongPrincipal.key,
            certificate: wrongPrincipal.cert,
          ),
        ),
        throwsA(anything),
      );
      final a = await userCert('mis-a', ['-t', 'ed25519']);
      final b = await userCert('mis-b', ['-t', 'ed25519']);
      await expectLater(
        run(
          CredentialRecord(
            id: 'm',
            name: 'm',
            username: 'root',
            kind: AuthKind.privateKey,
            privateKey: a.key,
            certificate: b.cert,
          ),
        ),
        throwsA(isA<SshCredentialException>()),
      );
    }, skip: tools ? null : 'ssh-keygen/sshd unavailable');
  });
}

Matcher _problem(OpenSshCertificateProblem problem) => throwsA(
  isA<OpenSshCertificateException>().having((e) => e.problem, 'problem', problem),
);

String? _which(String name) {
  for (final directory in [
    ...?Platform.environment['PATH']?.split(':'),
    '/usr/sbin',
  ]) {
    final candidate = File('$directory/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

Future<String> _keygen(List<String> args) async {
  final result = await Process.run(_which('ssh-keygen')!, ['-q', ...args]);
  if (result.exitCode != 0) {
    throw StateError('ssh-keygen failed (${result.exitCode})');
  }
  return '${result.stdout}';
}

final class _Sshd {
  _Sshd(this.process, this.port, this.hostFingerprint, this.logPath);
  final Process process;
  final int port;
  final String hostFingerprint;
  final String logPath;

  Future<String> log() => File(logPath).readAsString();

  static Future<_Sshd> start(
    Directory root,
    String caPub, {
    String? authorizedKeys,
    String name = 'sshd',
  }) async {
    final hostKey = '${root.path}/$name-host';
    await _keygen(['-t', 'ed25519', '-N', '', '-f', hostKey]);
    final hostFingerprint = (await _keygen(['-lf', '$hostKey.pub'])).split(
      ' ',
    )[1];
    final lease = await ServerSocket.bind('127.0.0.1', 0);
    final port = lease.port;
    await lease.close();
    final config = '${root.path}/$name-config';
    final logPath = '${root.path}/$name.log';
    await File(config).writeAsString('''
AddressFamily inet
ListenAddress 127.0.0.1
Port $port
HostKey $hostKey
PidFile ${root.path}/$name.pid
AuthorizedKeysFile ${authorizedKeys ?? 'none'}
${authorizedKeys == null ? 'TrustedUserCAKeys $caPub' : ''}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin yes
AllowUsers root
StrictModes no
UsePAM no
UseDNS no
PrintMotd no
LogLevel INFO
''');
    final process = await Process.start(_which('sshd')!, [
      '-D',
      '-E',
      logPath,
      '-f',
      config,
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        (await Socket.connect('127.0.0.1', port)).destroy();
        break;
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return _Sshd(process, port, hostFingerprint, logPath);
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
