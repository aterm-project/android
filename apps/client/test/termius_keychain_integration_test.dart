import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_keychain_bridge.dart';
import 'package:aterm_client/import/termius_openssh_bundle.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/ssh/openssh_certificate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory directory;
  late String key;
  late String certificate;
  const bridge = KeychainTermiusCertificateBridge();

  Future<void> keygen(List<String> args) async {
    final result = await Process.run('ssh-keygen', ['-q', ...args]);
    expect(result.exitCode, 0, reason: 'Synthetic certificate generation failed');
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('r7-transfer-cert-');
    final ca = '${directory.path}/ca';
    final user = '${directory.path}/user';
    await keygen(['-t', 'ed25519', '-N', '', '-f', ca]);
    await keygen(['-t', 'ed25519', '-N', 'synthetic-test-passphrase', '-f', user]);
    await keygen(['-s', ca, '-I', 'synthetic-transfer', '-n', 'testuser',
      '-V', '-5m:+1h', '$user.pub']);
    key = await File(user).readAsString();
    certificate = await File('$user-cert.pub').readAsString();
  });

  tearDownAll(() async => directory.delete(recursive: true));

  test('production bridge preserves credential fields and user certificate', () {
    final original = CredentialRecord(
      id: const Uuid().v4(), name: 'Fixture key', username: 'testuser',
      kind: AuthKind.privateKey, privateKey: key,
      passphrase: 'synthetic-test-passphrase', revisionId: 'fixture-revision',
      manifest: const {'fixture': true},
    );
    final stored = bridge.withCertificate(original, certificate);
    expect(stored.privateKey, original.privateKey);
    expect(stored.passphrase, original.passphrase);
    expect(stored.revisionId, original.revisionId);
    expect(stored.manifest, original.manifest);
    expect(stored.username, original.username);
    expect(bridge.certificateOf(stored), OpenSshCertificate.parse(certificate).canonicalLine);
    expect(validateUserCertificateForPrivateKey(
      certificateText: stored.certificate!, privateKey: stored.privateKey!,
      passphrase: stored.passphrase,
    ).keyFingerprint, stored.fingerprint);
  });

  test('real encrypted key and certificate retain association through bundle', () {
    final credential = bridge.withCertificate(CredentialRecord(
      id: const Uuid().v4(), name: 'Fixture key', username: 'testuser',
      kind: AuthKind.privateKey, privateKey: key,
      passphrase: 'synthetic-test-passphrase',
    ), certificate);
    final host = HostRecord(id: const Uuid().v4(), name: 'Fixture host',
      address: 'fixture.example.test', username: '', credentialId: credential.id);
    final result = TermiusOpenSshBundleExporter.export(
      TermiusCatalog(hosts: [host], groups: const [], credentials: [credential]),
      options: const TermiusExportOptions(includePrivateKeys: true),
      certificates: bridge,
    );
    final document = TermiusOpenSshBundleImporter.parseZip(result.binary!);
    expect(document.blocksWholeFile, isFalse);
    final plan = TermiusImportPlanner.plan(document,
      TermiusCatalog(hosts: const [], groups: const []), certificates: bridge);
    expect(plan.canApply, isTrue);
    expect(plan.hostsToCreate.single.credentialId, plan.newCredentials.single.id);
    final imported = plan.newCredentials.single;
    expect(imported.privateKey, key);
    expect(imported.certificate, credential.certificate);
    expect(imported.username, 'testuser');
    // Standard OpenSSH bundles preserve key encryption, never its passphrase.
    expect(imported.passphrase, isNull);
    expect(validateUserCertificateForPrivateKey(
      certificateText: imported.certificate!, privateKey: imported.privateKey!,
      passphrase: 'synthetic-test-passphrase',
    ).keyFingerprint, credential.fingerprint);
  });
}
