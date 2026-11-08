import '../domain/models.dart';
import '../ssh/openssh_certificate.dart';
import 'termius_transfer.dart';

/// Connects the transfer codec to the shared, encrypted Keychain model.
/// Encrypted keys keep their encryption; their passphrase can be entered in
/// Keychain after import. The normal SSH path verifies private-key binding.
class KeychainTermiusCertificateBridge implements TermiusCertificateBridge {
  const KeychainTermiusCertificateBridge();

  @override
  String? certificateOf(CredentialRecord credential) => credential.certificate;

  @override
  CredentialRecord withCertificate(
    CredentialRecord credential,
    String certificate,
  ) {
    final parsed = OpenSshCertificate.parse(certificate);
    if (credential.kind != AuthKind.privateKey || !parsed.isUserCertificate) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.notUserCertificate,
      );
    }
    return CredentialRecord(
      id: credential.id,
      name: credential.name,
      username: credential.username,
      kind: credential.kind,
      secret: credential.secret,
      privateKey: credential.privateKey,
      passphrase: credential.passphrase,
      fingerprint: credential.fingerprint ?? parsed.keyFingerprint,
      certificate: parsed.canonicalLine,
      revisionId: credential.revisionId,
      manifest: credential.manifest,
    );
  }
}
