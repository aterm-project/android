import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_openssh.dart';
import 'package:aterm_client/import/termius_openssh_bundle.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

// Synthetic, non-functional key material only.
const _keyA =
    '-----BEGIN OPENSSH PRIVATE KEY-----\nc3ludGhldGljLWtleS1h\n-----END OPENSSH PRIVATE KEY-----\n';
const _keyShared =
    '-----BEGIN OPENSSH PRIVATE KEY-----\nc3ludGhldGljLXNoYXJlZA==\n-----END OPENSSH PRIVATE KEY-----\n';
const _cert =
    'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t synthetic-cert';

int _ids = 0;
String _id() =>
    '30000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

class _FakeCertificates implements TermiusCertificateBridge {
  final byCredential = <String, String>{};

  @override
  String? certificateOf(CredentialRecord credential) =>
      byCredential[credential.id];

  @override
  CredentialRecord withCertificate(
    CredentialRecord credential,
    String certificate,
  ) {
    byCredential[credential.id] = certificate;
    return credential;
  }
}

List<TermiusIssueCode> _codes(Iterable<TermiusIssue> issues) =>
    issues.map((issue) => issue.code).toList();

/// Builds a ZIP with arbitrary (possibly hostile) central-directory fields.
Uint8List _rawZip(
  List<
    ({
      String name,
      List<int> data,
      int method,
      int declaredSize,
      int flags,
      int external,
    })
  >
  entries,
) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final offset = out.length;
    final crc = archive.getCrc32(entry.data);
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, entry.flags | 0x0800, Endian.little)
      ..setUint16(8, entry.method, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, entry.data.length, Endian.little)
      ..setUint32(22, entry.declaredSize, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(entry.data);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 0x0314, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, entry.flags | 0x0800, Endian.little)
      ..setUint16(10, entry.method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, entry.data.length, Endian.little)
      ..setUint32(24, entry.declaredSize, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(38, entry.external, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name);
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add(
    (ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(8, entries.length, Endian.little)
          ..setUint16(10, entries.length, Endian.little)
          ..setUint32(12, centralBytes.length, Endian.little)
          ..setUint32(16, centralOffset, Endian.little))
        .buffer
        .asUint8List(),
  );
  return out.takeBytes();
}

({String name, List<int> data, int method, int declaredSize, int flags, int external})
_stored(String name, String text, {int flags = 0, int mode = 0x81A4}) {
  final data = utf8.encode(text);
  return (
    name: name,
    data: data,
    method: 0,
    declaredSize: data.length,
    flags: flags,
    external: mode << 16,
  );
}

void main() {
  useAppLocaleFixture('en');

  final project = GroupRecord(id: _id(), name: 'Project');
  final shared = CredentialRecord(
    id: _id(),
    name: 'team key',
    username: 'svc',
    kind: AuthKind.privateKey,
    privateKey: _keyShared,
    passphrase: 'synthetic-passphrase',
  );
  final dev = GroupRecord(
    id: _id(),
    name: 'Dev',
    parentId: project.id,
    defaultCredentialId: shared.id,
  );
  final passwordCredential = CredentialRecord(
    id: _id(),
    name: 'pw',
    username: '',
    secret: 'synthetic-pw',
  );
  TermiusCatalog catalog() => TermiusCatalog(
    hosts: [
      HostRecord(
        id: _hostA,
        name: 'alpha',
        address: 'alpha.example',
        username: 'alice',
        groupId: project.id,
        tags: const ['web', 'prod'],
        login: const HostLogin(kind: AuthKind.privateKey, privateKey: _keyA),
      ),
      HostRecord(
        id: _hostB,
        name: 'beta',
        address: 'beta.example',
        port: 2200,
        username: 'ignored-by-credential',
        groupId: dev.id,
      ),
      HostRecord(
        id: _hostC,
        name: 'gamma',
        address: 'gamma.example',
        username: 'carol',
        groupId: dev.id,
        jumpHostId: _hostA,
      ),
      HostRecord(
        id: _hostD,
        name: 'delta',
        address: 'delta.example',
        username: 'dave',
        credentialId: passwordCredential.id,
      ),
    ],
    groups: [project, dev],
    credentials: [shared, passwordCredential],
  );

  group('effective login', () {
    test('host login, inherited group default, credential username', () {
      final c = catalog();
      final alpha = resolveTermiusEffectiveLogin(c.hosts[0], c)!;
      expect(alpha.source, TermiusLoginSource.hostLogin);
      expect(alpha.privateKey, _keyA);
      expect(alpha.username, 'alice');
      final beta = resolveTermiusEffectiveLogin(c.hosts[1], c)!;
      expect(beta.source, TermiusLoginSource.groupDefault);
      expect(beta.privateKey, _keyShared);
      expect(beta.passphrase, 'synthetic-passphrase');
      // A non-empty Credential username wins, like the SSH connection code.
      expect(beta.username, 'svc');
      final delta = resolveTermiusEffectiveLogin(c.hosts[3], c)!;
      expect(delta.source, TermiusLoginSource.hostCredential);
      expect(delta.password, 'synthetic-pw');
      // Empty Credential username falls back to the Host username.
      expect(delta.username, 'dave');
      expect(alpha.toString(), isNot(contains('synthetic')));
    });

    test('broken references resolve to no login', () {
      final host = HostRecord(
        id: _id(),
        name: 'x',
        address: 'x',
        username: 'u',
        credentialId: _id(),
      );
      expect(
        resolveTermiusEffectiveLogin(
          host,
          TermiusCatalog(hosts: [host], groups: const []),
        ),
        isNull,
      );
    });

    test('CSV uses the effective username and inherited password', () {
      final result = TermiusExporter.csv(
        catalog(),
        options: const TermiusExportOptions(includePasswords: true),
      );
      expect(result.text, contains('beta.example,ssh,2200,svc,'));
      expect(result.text, contains('delta.example,ssh,22,dave,synthetic-pw'));
      expect(result.text, isNot(contains('PRIVATE KEY')));
      expect(
        _codes(result.issues),
        contains(TermiusIssueCode.exportKeysNotRepresented),
      );
    });
  });

  group('OpenSSH bundle export', () {
    test('without key opt-in: config + README only, keys reported', () {
      final result = TermiusOpenSshBundleExporter.export(catalog());
      expect(result.containsSecrets, isFalse);
      expect(result.keyFiles, 0);
      final zip = TermiusZip.decode(result.binary!);
      expect(zip.files.keys.toSet(), {
        'atermius-ssh/config',
        'atermius-ssh/README.txt',
      });
      final config = utf8.decode(zip.files['atermius-ssh/config']!);
      expect(config, isNot(contains('IdentityFile')));
      expect(config, isNot(contains('synthetic')));
      expect(
        _codes(result.issues),
        containsAll([
          TermiusIssueCode.exportKeysOmitted,
          TermiusIssueCode.exportPasswordsNotRepresented,
        ]),
      );
    });

    test('with key opt-in: private files, shared key once, 0600 mode', () {
      final certificates = _FakeCertificates()..byCredential[shared.id] = _cert;
      final result = TermiusOpenSshBundleExporter.export(
        catalog(),
        options: const TermiusExportOptions(includePrivateKeys: true),
        certificates: certificates,
      );
      expect(result.containsSecrets, isTrue);
      expect(result.keyFiles, 2);
      final zip = TermiusZip.decode(result.binary!);
      final keyPaths = zip.files.keys
          .where((path) => path.startsWith('atermius-ssh/keys/'))
          .toList()
        ..sort();
      expect(keyPaths, [
        'atermius-ssh/keys/id_alpha',
        'atermius-ssh/keys/id_team_key',
        'atermius-ssh/keys/id_team_key-cert.pub',
      ]);
      expect(utf8.decode(zip.files['atermius-ssh/keys/id_alpha']!), _keyA);
      final config = utf8.decode(zip.files['atermius-ssh/config']!);
      expect(
        config,
        contains('IdentityFile ~/.ssh/atermius-ssh/keys/id_team_key\n'),
      );
      expect(
        config,
        contains('CertificateFile ~/.ssh/atermius-ssh/keys/id_team_key-cert.pub'),
      );
      expect(config, contains('ProxyJump alpha'));
      expect(config, contains('# atermius:group Project/Dev'));
      expect(config, isNot(contains('synthetic-passphrase')));
      expect(
        _codes(result.issues),
        contains(TermiusIssueCode.exportPassphraseNotExported),
      );
      // Unix modes in the central directory: keys 0600, others 0644.
      final decoded = archive.ZipDecoder().decodeBytes(result.binary!);
      for (final file in decoded.files) {
        final private = file.name.contains('/keys/id_') &&
            !file.name.endsWith('.pub');
        expect(file.mode & 0x1FF, private ? 0x180 : 0x1A4, reason: file.name);
      }
    });

    test('bundle config fixture is stable (root OpenSSH oracle input)', () {
      final certificates = _FakeCertificates()..byCredential[shared.id] = _cert;
      final result = TermiusOpenSshBundleExporter.export(
        catalog(),
        options: const TermiusExportOptions(includePrivateKeys: true),
        certificates: certificates,
        now: DateTime.utc(2026, 11, 8),
      );
      final file = File('test/fixtures/termius/writer_bundle_config_synthetic.conf');
      final bytes = utf8.encode(result.text);
      if (Platform.environment['TERMIUS_WRITE_FIXTURES'] == '1') {
        file.writeAsBytesSync(bytes);
      }
      expect(bytes, file.readAsBytesSync());
    });

    test('round trip keeps key association, groups, tags, username, jump', () {
      final certificates = _FakeCertificates()..byCredential[shared.id] = _cert;
      final exported = TermiusOpenSshBundleExporter.export(
        catalog(),
        options: const TermiusExportOptions(includePrivateKeys: true),
        certificates: certificates,
      );
      final document = TermiusOpenSshBundleImporter.parseZip(exported.binary!);
      expect(document.blocksWholeFile, isFalse, reason: '${document.fileIssues}');
      final importBridge = _FakeCertificates();
      final plan = TermiusImportPlanner.plan(
        document,
        TermiusCatalog(hosts: const [], groups: const []),
        newId: _id,
        certificates: importBridge,
      );
      expect(plan.createCount, 4);
      final byName = {for (final host in plan.hostsToCreate) host.name: host};
      expect(byName['alpha']!.login?.privateKey, _keyA);
      expect(byName['alpha']!.tags, ['web', 'prod']);
      expect(byName['alpha']!.username, 'alice');
      // Inherited key + certificate become one new private-key Credential.
      final beta = byName['beta']!;
      expect(beta.username, 'svc');
      expect(beta.port, 2200);
      expect(beta.login, isNull);
      final betaCredential = plan.newCredentials.singleWhere(
        (credential) => credential.id == beta.credentialId,
      );
      expect(betaCredential.privateKey, _keyShared);
      expect(importBridge.byCredential[betaCredential.id], _cert);
      expect(byName['gamma']!.jumpHostId, byName['alpha']!.id);
      // Groups come back nested from the Atermius metadata comments.
      final groupNames = {
        for (final group in plan.newGroups) group.id: group,
      };
      final betaGroup = groupNames[beta.groupId]!;
      expect(betaGroup.name, 'Dev');
      expect(groupNames[betaGroup.parentId]!.name, 'Project');
      // Password logins cannot travel in OpenSSH files.
      expect(byName['delta']!.login, isNull);
    });

    test('without a certificate bridge the certificate is reported', () {
      final certificates = _FakeCertificates()..byCredential[shared.id] = _cert;
      final exported = TermiusOpenSshBundleExporter.export(
        catalog(),
        options: const TermiusExportOptions(includePrivateKeys: true),
        certificates: certificates,
      );
      final document = TermiusOpenSshBundleImporter.parseZip(exported.binary!);
      final plan = TermiusImportPlanner.plan(
        document,
        TermiusCatalog(hosts: const [], groups: const []),
        newId: _id,
      );
      final beta = plan.rows.firstWhere((row) => row.source.label == 'beta');
      expect(beta.host!.login?.privateKey, _keyShared);
      expect(_codes(beta.issues), contains(TermiusIssueCode.certificateNotStored));
      expect(plan.newCredentials, isEmpty);
    });
  });

  group('bundle export bounds and names', () {
    test('key and certificate names never collide across hosts', () {
      final certificates = _FakeCertificates();
      final credential = CredentialRecord(
        id: _id(),
        name: 'foo',
        username: 'u',
        kind: AuthKind.privateKey,
        privateKey: _keyShared,
      );
      certificates.byCredential[credential.id] = _cert;
      final hosts = [
        HostRecord(
          id: _id(),
          name: 'aaa',
          address: 'a.example',
          username: 'u',
          credentialId: credential.id,
        ),
        HostRecord(
          id: _id(),
          name: 'foo-cert.pub',
          address: 'b.example',
          username: 'u',
          login: const HostLogin(kind: AuthKind.privateKey, privateKey: _keyA),
        ),
      ];
      final result = TermiusOpenSshBundleExporter.export(
        TermiusCatalog(hosts: hosts, groups: const [], credentials: [credential]),
        options: const TermiusExportOptions(includePrivateKeys: true),
        certificates: certificates,
      );
      final zip = TermiusZip.decode(result.binary!);
      final keyFiles = zip.files.keys.where((p) => p.contains('/keys/')).toList();
      expect(keyFiles.toSet(), hasLength(keyFiles.length));
      expect(keyFiles, hasLength(3));
      expect(utf8.decode(zip.files['atermius-ssh/keys/id_foo']!), _keyShared);
      expect(
        zip.files['atermius-ssh/keys/id_foo-cert.pub'],
        isNotNull,
      );
      // The host key whose sanitized name equals the cert path got a suffix.
      final hostKey = keyFiles.singleWhere(
        (p) => p.startsWith('atermius-ssh/keys/id_foo-cert.pub-'),
      );
      expect(utf8.decode(zip.files[hostKey]!), _keyA);
      final config = utf8.decode(zip.files['atermius-ssh/config']!);
      expect(config, contains('IdentityFile ~/.ssh/$hostKey'));
    });

    test('exports beyond importer limits are blocked, never truncated', () {
      final many = [
        for (var i = 0; i < maxOpenSshExportHosts + 1; i++)
          HostRecord(id: _id(), name: 'h$i', address: 'h$i.example', username: 'u'),
      ];
      final catalog = TermiusCatalog(hosts: many, groups: const []);
      final config = TermiusExporter.openSsh(catalog);
      expect(config.blocked, isTrue);
      expect(config.text, isEmpty);
      final bundle = TermiusOpenSshBundleExporter.export(catalog);
      expect(bundle.blocked, isTrue);
      expect(bundle.binary, isNull);
      expect(
        bundle.issues.where((issue) => issue.code == TermiusIssueCode.exportTooLarge),
        hasLength(1),
      );
      final rows = [
        for (var i = 0; i < maxTermiusImportRows + 1; i++)
          HostRecord(id: _id(), name: 'r$i', address: 'r$i.example', username: 'u'),
      ];
      final csv = TermiusExporter.csv(TermiusCatalog(hosts: rows, groups: const []));
      expect(csv.blocked, isTrue);
      expect(csv.text, isEmpty);
      // At the limit, export succeeds and re-imports completely.
      final atLimit = TermiusExporter.openSsh(
        TermiusCatalog(hosts: many.take(maxOpenSshExportHosts).toList(), groups: const []),
      );
      expect(atLimit.blocked, isFalse);
      expect(
        TermiusImportPlanner.plan(
          TermiusOpenSshImporter.parse(atLimit.text),
          TermiusCatalog(hosts: const [], groups: const []),
          newId: _id,
        ).createCount,
        maxOpenSshExportHosts,
      );
    });
  });

  group('bundle import safety', () {
    test('only files inside the bundle resolve; paths outside never read', () {
      final zip = _rawZip([
        _stored(
          'config',
          'Host a\n  HostName a.example\n  User u\n  IdentityFile /etc/ssh/key\n'
              'Host b\n  HostName b.example\n  User u\n  IdentityFile ../outside\n'
              'Host c\n  HostName c.example\n  User u\n  IdentityFile keys/c\n'
              'Host d\n  HostName d.example\n  User u\n  IdentityFile keys/notakey\n',
        ),
        _stored('keys/c', _keyA),
        _stored('keys/notakey', 'hello'),
      ]);
      final document = TermiusOpenSshBundleImporter.parseZip(zip);
      expect(document.blocksWholeFile, isFalse);
      final rows = {for (final row in document.rows) row.label: row};
      expect(_codes(rows['a']!.issues), contains(TermiusIssueCode.bundleKeyMissing));
      expect(_codes(rows['b']!.issues), contains(TermiusIssueCode.bundleKeyMissing));
      expect(rows['c']!.privateKey, _keyA);
      expect(_codes(rows['d']!.issues), contains(TermiusIssueCode.bundleKeyInvalid));
    });

    test('traversal, absolute, symlink and encrypted entries are refused', () {
      final zip = _rawZip([
        _stored('config', 'Host a\n  HostName a.example\n  User u\n'),
        _stored('../evil', 'x'),
        _stored('/abs', 'x'),
        _stored('link', 'keys/c', mode: 0xA1FF),
        _stored('enc', 'x', flags: 1),
      ]);
      final archiveResult = TermiusZip.decode(zip);
      expect(archiveResult.files.keys, ['config']);
      expect(archiveResult.rejectedPaths, hasLength(4));
      final document = TermiusOpenSshBundleImporter.parseZip(zip);
      expect(
        _codes(document.fileIssues).where(
          (code) => code == TermiusIssueCode.bundleEntryRejected,
        ),
        hasLength(4),
      );
      expect(document.rows.single.blocked, isFalse);
    });

    test('decompression bomb and oversize are rejected before use', () {
      final zeros = Uint8List(2 * 1024 * 1024);
      final deflated = archive.Deflate(zeros).getBytes();
      final bomb = _rawZip([
        (
          name: 'config',
          data: deflated,
          method: 8,
          declaredSize: 64,
          flags: 0,
          external: 0x81A4 << 16,
        ),
      ]);
      final document = TermiusOpenSshBundleImporter.parseZip(bomb);
      expect(_codes(document.fileIssues), [TermiusIssueCode.bundleTooLarge]);
      final tooBig = TermiusOpenSshBundleImporter.parseZip(
        Uint8List(maxTermiusBundleBytes + 1),
      );
      expect(_codes(tooBig.fileIssues), [TermiusIssueCode.bundleTooLarge]);
      final garbage = TermiusOpenSshBundleImporter.parseZip([1, 2, 3]);
      expect(_codes(garbage.fileIssues), [TermiusIssueCode.bundleInvalid]);
    });

    test('standard deflated ZIPs from other tools are readable', () {
      final source = archive.Archive()
        ..add(archive.ArchiveFile.string('ssh/config', 'Host a\n  HostName a.example\n  User u\n  IdentityFile ~/.ssh/ssh/k\n'))
        ..add(archive.ArchiveFile.string('ssh/k', _keyA));
      final bytes = archive.ZipEncoder().encodeBytes(source);
      final document = TermiusOpenSshBundleImporter.parseZip(bytes);
      expect(document.blocksWholeFile, isFalse);
      expect(document.rows.single.privateKey, _keyA);
    });

    test('independent Python zipfile bundle with UTF-8 paths resolves keys', () {
      final bytes = File(
        'test/fixtures/termius/python_utf8_bundle.zip',
      ).readAsBytesSync();
      final document = TermiusOpenSshBundleImporter.parseZip(bytes);
      expect(document.blocksWholeFile, isFalse, reason: '${document.fileIssues}');
      final row = document.rows.single;
      expect(row.label, 'plain');
      expect(row.privateKey, contains('c3ludGhldGljLXV0Zjg='));
      expect(row.issues.where((issue) => issue.blocking), isEmpty);
    });

    test('missing or ambiguous config is a whole-file failure', () {
      expect(
        _codes(
          TermiusOpenSshBundleImporter.parseZip(_rawZip([_stored('k', _keyA)]))
              .fileIssues,
        ),
        [TermiusIssueCode.bundleConfigMissing],
      );
      expect(
        _codes(
          TermiusOpenSshBundleImporter.parseZip(
            _rawZip([
              _stored('a/config', 'Host a\n'),
              _stored('b/config', 'Host b\n'),
            ]),
          ).fileIssues,
        ),
        [TermiusIssueCode.bundleConfigAmbiguous],
      );
    });
  });
}

const _hostA = '40000000-0000-4000-8000-000000000001';
const _hostB = '40000000-0000-4000-8000-000000000002';
const _hostC = '40000000-0000-4000-8000-000000000003';
const _hostD = '40000000-0000-4000-8000-000000000004';
