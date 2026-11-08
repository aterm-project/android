import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:sodium/sodium.dart' as sodium_api;
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'jcs.dart';
import '../l10n/l10n.dart';

const _uuid = Uuid();
const _localUmkEnvelopeFormat = 'atermius-local-umk-envelope';
const _localUmkEnvelopeVersion = 1;
const _localUmkKeyVersion = 1;
const _localUmkPurpose = 'local-umk-wrap';
const _localUmkKdfMemoryKib = 65536;
const _localUmkKdfIterations = 3;
const _localUmkKdfParallelism = 1;
const _localUmkKdfVersion = 1;

const _localVaultKeyEnvelopeFormat = 'atermius-local-vault-key-envelope';
const _localVaultKeyEnvelopeVersion = 1;
const _localVaultKeyVersion = 1;
const _localVaultKeyPurpose = 'local-vault-key-wrap';

const _localDeviceIdentityEnvelopeFormat =
    'atermius-local-device-identity-envelope';
const _localDeviceIdentityEnvelopeVersion = 1;
const _localDeviceIdentityPurpose = 'local-device-identity-wrap';
const _localDeviceSigningAlgorithm = 'ed25519';
const _localDeviceEncryptionAlgorithm = 'curve25519-xsalsa20-poly1305';
const _localKeyEnvelopeSuite = 'xchacha20-poly1305-ietf';

const _localRecordFormat = 'atermius-local-record-v1';
const _localRecordSchemaVersion = 1;
const _vaultRecordEnvelopeFields = {
  'header',
  'nonce',
  'ciphertext',
  'signature',
};
const _vaultRecordHeaderFields = {
  'wire_version',
  'server_space_id',
  'vault_id',
  'record_id',
  'revision_id',
  'base_revision_id',
  'op_id',
  'device_id',
  'device_seq',
  'key_epoch',
  'membership_version',
  'record_schema',
  'operation',
  'crypto_suite',
  'kdf_salt',
};
const _localRecordCryptoSuite = 'xchacha20-poly1305-ietf+hkdf-sha256+ed25519';
const _localRecordMaxCiphertextBytes = 4 * 1024 * 1024;
const _localRecordEnvelopeFields = {
  'format',
  'header',
  'nonce',
  'ciphertext',
  'signature',
};
const _localRecordHeaderFields = {
  'format',
  'schema_version',
  'profile_id',
  'local_data_domain_id',
  'local_vault_id',
  'record_id',
  'revision_id',
  'base_revision_id',
  'operation',
  'crypto_suite',
  'kdf_salt',
};

const _localVaultKeyEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'local_vault_id',
  'key_epoch',
  'suite',
  'nonce',
  'ciphertext',
};
const _localDeviceIdentityEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'local_device_id',
  'signing_algorithm',
  'signing_public',
  'encryption_algorithm',
  'encryption_public',
  'suite',
  'nonce',
  'ciphertext',
};

const _localUmkEnvelopeFields = {
  'format',
  'envelope_version',
  'key_version',
  'purpose',
  'profile_id',
  'local_data_domain_id',
  'kdf',
  'nonce',
  'ciphertext',
};
const _kdfParameterFields = {
  'id',
  'salt',
  'mem_kib',
  'iterations',
  'parallelism',
  'version',
};

class KdfParameters {
  const KdfParameters({
    required this.salt,
    this.memoryKib = 65536,
    this.iterations = 3,
    this.parallelism = 1,
    this.version = 1,
  });

  final Uint8List salt;
  final int memoryKib;
  final int iterations;
  final int parallelism;
  final int version;

  factory KdfParameters.defaults(SodiumSumo sodium) => KdfParameters(
    salt: sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes),
  );

  factory KdfParameters.fromJson(Map<String, dynamic> json) {
    final saltText = json['salt'];
    if (saltText is! String) throw const FormatException('Missing KDF salt');
    final value = KdfParameters(
      salt: decodeBase64Url(saltText),
      memoryKib: (json['mem_kib'] as num?)?.toInt() ?? 65536,
      iterations: (json['iterations'] as num?)?.toInt() ?? 3,
      parallelism: (json['parallelism'] as num?)?.toInt() ?? 1,
      version: (json['version'] as num?)?.toInt() ?? 1,
    );
    value.validate();
    return value;
  }

  Map<String, Object?> toJson() => {
    'id': 'argon2id13',
    'salt': encodeBase64Url(salt),
    'mem_kib': memoryKib,
    'iterations': iterations,
    'parallelism': parallelism,
    'version': version,
  };

  void validate() {
    if (salt.length != 16) {
      throw const FormatException('KDF salt must be 16 bytes');
    }
    if (memoryKib < 65536 || memoryKib > 1048576) {
      throw const FormatException(
        'KDF memory must be between 64 MiB and 1 GiB',
      );
    }
    if (iterations < 3 || iterations > 10) {
      throw const FormatException('KDF iterations must be between 3 and 10');
    }
    if (parallelism != 1 || version != 1) {
      throw const FormatException('Unsupported KDF parameters');
    }
  }
}

class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.signing,
    required this.encryption,
  });

  final String deviceId;
  final sodium_api.KeyPair signing;
  final sodium_api.KeyPair encryption;

  String get signingPublicKey => encodeBase64Url(signing.publicKey);
  String get encryptionPublicKey => encodeBase64Url(encryption.publicKey);

  Map<String, Object?> registrationProof(
    SodiumSumo sodium, {
    required String accountId,
    String name = 'Atermius client',
  }) {
    final signedPayload = <String, Object?>{
      'account_id': accountId,
      'device_id': deviceId,
      'signing_public_key': signingPublicKey,
      'encryption_public_key': encryptionPublicKey,
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(signedPayload))),
      secretKey: signing.secretKey,
    );
    return {
      ...signedPayload,
      'name': name,
      'signature': encodeBase64Url(signature),
    };
  }

  /// Legacy server-profile serialization used by ClientSecureStore.
  ///
  /// This contains private-key bytes in base64 and is not an encrypted
  /// persistence format. Never write it to Drift, an archive, or a local-only
  /// profile; local profiles must persist [VaultCrypto.wrapLocalDeviceIdentity]
  /// output instead. Browser secure storage is not a same-origin XSS boundary.
  Map<String, String> toStorageJson() => {
    'device_id': deviceId,
    'signing_public': signingPublicKey,
    'signing_secret': encodeBase64Url(signing.secretKey.extractBytes()),
    'encryption_public': encryptionPublicKey,
    'encryption_secret': encodeBase64Url(encryption.secretKey.extractBytes()),
  };

  static DeviceIdentity create(SodiumSumo sodium) => DeviceIdentity(
    deviceId: _uuid.v4(),
    signing: sodium.crypto.sign.keyPair(),
    encryption: sodium.crypto.box.keyPair(),
  );

  static DeviceIdentity fromStorage(
    SodiumSumo sodium,
    Map<String, dynamic> json,
  ) => DeviceIdentity(
    deviceId: json['device_id'] as String,
    signing: sodium_api.KeyPair(
      publicKey: decodeBase64Url(json['signing_public'] as String),
      secretKey: sodium.secureCopy(
        decodeBase64Url(json['signing_secret'] as String),
      ),
    ),
    encryption: sodium_api.KeyPair(
      publicKey: decodeBase64Url(json['encryption_public'] as String),
      secretKey: sodium.secureCopy(
        decodeBase64Url(json['encryption_secret'] as String),
      ),
    ),
  );

  void dispose() {
    signing.dispose();
    encryption.dispose();
  }
}

class PublicDeviceCard {
  const PublicDeviceCard({
    required this.accountId,
    required this.instanceId,
    required this.deviceId,
    required this.name,
    required this.signingPublicKey,
    required this.encryptionPublicKey,
    required this.device,
  });

  final String accountId;
  final String instanceId;
  final String deviceId;
  final String name;
  final Uint8List signingPublicKey;
  final Uint8List encryptionPublicKey;
  final Map<String, Object?> device;
}

class VerifiedDeviceCapabilities {
  const VerifiedDeviceCapabilities({
    required this.revision,
    required this.maxRecordSchema,
    required this.hostAttachmentManifestVersions,
    required this.maxAttachmentBytes,
  });

  final int revision;
  final int maxRecordSchema;
  final List<int> hostAttachmentManifestVersions;
  final int maxAttachmentBytes;
}

class InitialVaultMaterial {
  const InitialVaultMaterial({
    required this.vaultId,
    required this.vaultKey,
    required this.payload,
  });

  final String vaultId;
  final Uint8List vaultKey;
  final Map<String, Object?> payload;
}

class VerifiedMembership {
  const VerifiedMembership({
    required this.version,
    required this.digest,
    required this.signerDeviceId,
    required this.manifest,
  });

  final int version;
  final String digest;
  final String signerDeviceId;
  final Map<String, dynamic> manifest;
}

class DeviceVaultEnvelope {
  const DeviceVaultEnvelope({
    required this.vaultId,
    required this.recipientDeviceId,
    required this.keyEpoch,
    required this.membershipVersion,
    required this.envelope,
  });

  final String vaultId;
  final String recipientDeviceId;
  final int keyEpoch;
  final int membershipVersion;
  final Map<String, Object?> envelope;

  Map<String, Object?> toJson() => {
    'vault_id': vaultId,
    'recipient_device_id': recipientDeviceId,
    'key_epoch': keyEpoch,
    'membership_version': membershipVersion,
    'envelope': envelope,
  };
}

class VaultCrypto {
  VaultCrypto(this.sodium);

  final SodiumSumo sodium;
  final crypto.Hkdf _hkdf = crypto.Hkdf(
    hmac: crypto.Hmac.sha256(),
    outputLength: 32,
  );

  VerifiedDeviceCapabilities verifyDeviceCapabilityReport({
    required Map<String, dynamic> report,
    required String expectedAccountId,
    required String expectedDeviceId,
    required Uint8List signingPublicKey,
  }) {
    const fields = {
      'account_id',
      'device_id',
      'revision',
      'max_record_schema',
      'host_attachment_manifest_versions',
      'max_attachment_bytes',
      'signature',
    };
    if (report.keys.toSet().length != fields.length ||
        !report.keys.toSet().containsAll(fields) ||
        report['account_id'] != expectedAccountId ||
        report['device_id'] != expectedDeviceId ||
        report['revision'] is! int ||
        (report['revision'] as int) < 1 ||
        report['max_record_schema'] is! int ||
        !const {1, 2}.contains(report['max_record_schema']) ||
        report['max_attachment_bytes'] is! int ||
        (report['max_attachment_bytes'] as int) < 0 ||
        (report['max_attachment_bytes'] as int) > 1024 * 1024 * 1024 ||
        report['host_attachment_manifest_versions'] is! List ||
        report['signature'] is! String ||
        signingPublicKey.length != 32) {
      throw const FormatException('Device capability report is invalid.');
    }
    final versions = (report['host_attachment_manifest_versions'] as List)
        .cast<Object?>();
    var previous = 0;
    final parsedVersions = <int>[];
    for (final version in versions) {
      if (version is! int ||
          !const {1, 2}.contains(version) ||
          version <= previous) {
        throw const FormatException('Device capability versions are invalid.');
      }
      parsedVersions.add(version);
      previous = version;
    }
    if (parsedVersions.isEmpty) {
      throw const FormatException('Device capability versions are empty.');
    }
    final signatureText = report['signature'] as String;
    final signature = decodeBase64Url(signatureText);
    if (signature.length != 64 || encodeBase64Url(signature) != signatureText) {
      throw const FormatException('Device capability signature is invalid.');
    }
    final unsigned = <String, Object?>{
      for (final field in fields.where((field) => field != 'signature'))
        field: report[field],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: signingPublicKey,
    )) {
      throw const FormatException('Device capability signature is invalid.');
    }
    return VerifiedDeviceCapabilities(
      revision: report['revision'] as int,
      maxRecordSchema: report['max_record_schema'] as int,
      hostAttachmentManifestVersions: List.unmodifiable(parsedVersions),
      maxAttachmentBytes: report['max_attachment_bytes'] as int,
    );
  }

  Uint8List randomBytes(int count) => sodium.randombytes.buf(count);

  String createVaultShareRequest({
    required String accountId,
    required String instanceId,
    required DeviceIdentity identity,
    required String name,
  }) => const JsonEncoder.withIndent('  ').convert({
    'format': 'atermius-vault-share-request-v1',
    'account_id': accountId,
    'instance_id': instanceId,
    'device': identity.registrationProof(
      sodium,
      accountId: accountId,
      name: name,
    ),
  });

  /// Verifies a TOFU-pinned instance key rotation chain. Each transition is
  /// signed by the previous Ed25519 key and binds the public keys to the
  /// persistent instance ID. A current-key match needs no transition data.
  bool verifyInstanceKeyTransitions({
    required String instanceId,
    required String pinnedPublicKey,
    required String currentPublicKey,
    required List<Map<String, dynamic>> transitions,
  }) {
    try {
      final pinned = decodeBase64Url(pinnedPublicKey);
      final current = decodeBase64Url(currentPublicKey);
      if (pinned.length != 32 ||
          current.length != 32 ||
          encodeBase64Url(pinned) != pinnedPublicKey ||
          encodeBase64Url(current) != currentPublicKey) {
        return false;
      }
      if (pinnedPublicKey == currentPublicKey) return true;

      final start = transitions.indexWhere(
        (transition) => transition['from_public_key'] == pinnedPublicKey,
      );
      if (start < 0) return false;
      const expectedFields = {
        'format',
        'instance_id',
        'from_public_key',
        'to_public_key',
        'issued_at',
        'signature',
      };
      var expectedKey = pinnedPublicKey;
      for (final transition in transitions.skip(start)) {
        if (transition.keys.toSet().difference(expectedFields).isNotEmpty ||
            !transition.keys.toSet().containsAll(expectedFields) ||
            transition['format'] != 'atermius-instance-key-transition-v1' ||
            transition['instance_id'] != instanceId ||
            transition['from_public_key'] != expectedKey) {
          return false;
        }
        final toKeyText = transition['to_public_key'];
        final issuedAt = transition['issued_at'];
        final signatureText = transition['signature'];
        if (toKeyText is! String ||
            issuedAt is! String ||
            DateTime.tryParse(issuedAt) == null ||
            signatureText is! String) {
          return false;
        }
        final toKey = decodeBase64Url(toKeyText);
        final signature = decodeBase64Url(signatureText);
        if (toKey.length != 32 ||
            signature.length != 64 ||
            encodeBase64Url(toKey) != toKeyText ||
            encodeBase64Url(signature) != signatureText) {
          return false;
        }
        final payload = <String, Object?>{
          'format': 'atermius-instance-key-transition-v1',
          'instance_id': instanceId,
          'from_public_key': expectedKey,
          'to_public_key': toKeyText,
          'issued_at': issuedAt,
        };
        if (!sodium.crypto.sign.verifyDetached(
          message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
          signature: signature,
          publicKey: decodeBase64Url(expectedKey),
        )) {
          return false;
        }
        expectedKey = toKeyText;
      }
      return expectedKey == currentPublicKey;
    } on Object {
      return false;
    }
  }

  /// Validates a public Device Card before it is used as an invitation target.
  /// The exported card contains only public keys and a self-proof signature.
  PublicDeviceCard verifyVaultShareRequest(
    String json, {
    required String expectedInstanceId,
  }) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'atermius-vault-share-request-v1' ||
        decoded['instance_id'] != expectedInstanceId ||
        decoded['device'] is! Map) {
      throw FormatException(currentL10n.theShareRequestIsMalformedOr);
    }
    final accountId = decoded['account_id'];
    if (accountId is! String) {
      throw FormatException(currentL10n.invalidShareRequestAccountIdentifier);
    }
    return verifyDeviceProof(
      accountId: accountId,
      instanceId: expectedInstanceId,
      device: Map<String, dynamic>.from(decoded['device'] as Map),
    );
  }

  /// Verifies the device self-proof shared by enrollment and invite cards.
  PublicDeviceCard verifyDeviceProof({
    required String accountId,
    required String instanceId,
    required Map<String, dynamic> device,
  }) {
    if (!_isCanonicalUuid(accountId)) {
      throw FormatException(currentL10n.invalidDeviceSelfProofAccountIdentifier);
    }
    final rawDevice = device;
    final deviceId = rawDevice['device_id'];
    final signingText = rawDevice['signing_public_key'];
    final encryptionText = rawDevice['encryption_public_key'];
    final signatureText = rawDevice['signature'];
    if (deviceId is! String ||
        !_isCanonicalUuid(deviceId) ||
        signingText is! String ||
        encryptionText is! String ||
        signatureText is! String) {
      throw FormatException(currentL10n.invalidDeviceSelfProofFields);
    }
    final signingKey = decodeBase64Url(signingText);
    final encryptionKey = decodeBase64Url(encryptionText);
    final signature = decodeBase64Url(signatureText);
    if (signingKey.length != 32 ||
        encryptionKey.length != 32 ||
        signature.length != 64) {
      throw FormatException(currentL10n.invalidDeviceSelfProofPublicKey);
    }
    final signedPayload = <String, Object?>{
      'account_id': accountId,
      'device_id': deviceId,
      'signing_public_key': signingText,
      'encryption_public_key': encryptionText,
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(signedPayload))),
      signature: signature,
      publicKey: signingKey,
    )) {
      throw FormatException(currentL10n.invalidDeviceSelfProofSignature);
    }
    final name = rawDevice['name'];
    final displayName = name is String && name.trim().isNotEmpty
        ? name.trim()
        : 'Unnamed device';
    return PublicDeviceCard(
      accountId: accountId,
      instanceId: instanceId,
      deviceId: deviceId,
      name: displayName,
      signingPublicKey: signingKey,
      encryptionPublicKey: encryptionKey,
      // Rebuild a strict, public-only object. Extra input fields never reach API.
      device: {
        'device_id': deviceId,
        'name': name is String ? name : displayName,
        'signing_public_key': signingText,
        'encryption_public_key': encryptionText,
        'signature': signatureText,
      },
    );
  }

  Map<String, Object?> createMembershipGrant({
    required String vaultId,
    required int membershipVersion,
    required String? previousDigest,
    required Map<String, Object?> manifest,
    required DeviceIdentity signer,
  }) {
    final signedPayload = <String, Object?>{
      'vault_id': vaultId,
      'membership_version': membershipVersion,
      'previous_digest': previousDigest,
      'manifest': manifest,
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(signedPayload))),
      secretKey: signer.signing.secretKey,
    );
    return {
      'membership_version': membershipVersion,
      'previous_digest': previousDigest,
      'manifest': manifest,
      'signature': encodeBase64Url(signature),
    };
  }

  bool verifyDeviceApprovalCertificate({
    required String accountId,
    required String approverDeviceId,
    required Map<String, dynamic> device,
    required String signature,
    required Uint8List approverSigningPublicKey,
  }) {
    final signatureBytes = decodeBase64Url(signature);
    if (signatureBytes.length != 64 || approverSigningPublicKey.length != 32) {
      return false;
    }
    final payload = <String, Object?>{
      'account_id': accountId,
      'approver_device_id': approverDeviceId,
      'device': device,
    };
    return sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
      signature: signatureBytes,
      publicKey: approverSigningPublicKey,
    );
  }

  bool _isCanonicalUuid(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(value);

  bool _isCanonicalLocalUuid(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value);

  void _validateLocalProfileContext({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
  }) {
    if (!_isCanonicalLocalUuid(profileId) ||
        !_isCanonicalLocalUuid(localDataDomainId) ||
        !_isCanonicalLocalUuid(localVaultId)) {
      throw const FormatException('Local record context IDs are invalid');
    }
  }

  void _validateLocalRecordContext({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required String recordId,
    required String? baseRevisionId,
    required String operation,
  }) {
    _validateLocalProfileContext(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
    );
    if (!_isCanonicalLocalUuid(recordId)) {
      throw const FormatException('Local record ID is invalid');
    }
    if (operation != 'create' &&
        operation != 'update' &&
        operation != 'delete') {
      throw const FormatException('Local record operation is invalid');
    }
    if (operation == 'create') {
      if (baseRevisionId != null) {
        throw const FormatException('Create must not have a base revision');
      }
    } else if (baseRevisionId == null ||
        !_isCanonicalLocalUuid(baseRevisionId)) {
      throw const FormatException('Update or delete requires a base revision');
    }
  }

  SecureKey derivePasswordKey(String password, KdfParameters parameters) {
    parameters.validate();
    final passwordBytes = Int8List.fromList(utf8.encode(password));
    try {
      return sodium.crypto.pwhash.callRaw(
        outLen: 32,
        password: passwordBytes,
        salt: parameters.salt,
        opsLimit: parameters.iterations,
        memLimit: parameters.memoryKib * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
    } finally {
      passwordBytes.fillRange(0, passwordBytes.length, 0);
    }
  }

  /// Verifies the complete signed membership history returned by the server.
  /// The server's `manifest` field is currently the persisted signed wrapper;
  /// accepting a direct manifest body as well keeps this parser compatible with
  /// shape-equivalent responses while still reconstructing the exact JCS bytes.
  Future<List<VerifiedMembership>> verifyMembershipChain({
    required String vaultId,
    required List<Map<String, dynamic>> entries,
    required Map<String, Uint8List> signerPublicKeys,
    required int expectedLatestVersion,
  }) async {
    if (expectedLatestVersion < 1 || entries.length != expectedLatestVersion) {
      throw const FormatException('Membership history is incomplete');
    }
    final sorted = [...entries]
      ..sort(
        (left, right) => _integer(
          left['membership_version'],
        ).compareTo(_integer(right['membership_version'])),
      );
    final verified = <VerifiedMembership>[];
    String? previousDigest;
    int? previousKeyEpoch;
    for (var index = 0; index < sorted.length; index++) {
      final row = sorted[index];
      final version = _integer(row['membership_version']);
      if (version != index + 1) {
        throw const FormatException('Membership versions are not contiguous');
      }
      final rowPrevious = row['previous_digest'] as String?;
      if (rowPrevious != previousDigest) {
        throw const FormatException(
          'Membership previous digest does not match',
        );
      }

      final stored = Map<String, dynamic>.from(row['manifest'] as Map);
      final nestedWrapper =
          stored['vault_id'] != null &&
          stored['membership_version'] != null &&
          stored['manifest'] is Map;
      final wrapper = nestedWrapper ? stored : null;
      final body = Map<String, dynamic>.from(
        (wrapper?['manifest'] ?? stored) as Map,
      );
      final wrapperVersion = wrapper == null
          ? version
          : _integer(wrapper['membership_version']);
      final wrapperPrevious = wrapper == null
          ? rowPrevious
          : wrapper['previous_digest'] as String?;
      if (wrapper != null &&
          (wrapper['vault_id'] != vaultId ||
              wrapperVersion != version ||
              wrapperPrevious != rowPrevious)) {
        throw const FormatException(
          'Membership signed context is inconsistent',
        );
      }
      final signedPayload = <String, Object?>{
        'vault_id': vaultId,
        'membership_version': version,
        'previous_digest': rowPrevious,
        'manifest': body,
      };
      final signerId =
          row['signer_device_id'] as String? ??
          body['signer_device_id'] as String?;
      final bodySignerId = body['signer_device_id'] as String?;
      if (signerId == null || signerId != bodySignerId) {
        throw const FormatException(
          'Membership signer context is inconsistent',
        );
      }
      final signerKey = signerPublicKeys[signerId];
      if (signerKey == null) {
        throw FormatException('Unknown membership signer device: $signerId');
      }
      final signature =
          row['signature'] as String? ?? wrapper?['signature'] as String?;
      if (signature == null ||
          (row['signature'] != null &&
              wrapper?['signature'] != null &&
              row['signature'] != wrapper?['signature'])) {
        throw const FormatException(
          'Membership signature is missing or inconsistent',
        );
      }
      final signedBytes = Uint8List.fromList(
        utf8.encode(canonicalJson(signedPayload)),
      );
      if (!sodium.crypto.sign.verifyDetached(
        message: signedBytes,
        signature: decodeBase64Url(signature),
        publicKey: signerKey,
      )) {
        throw const FormatException('Membership signature is invalid');
      }
      final digestBytes = await crypto.Sha256().hash(signedBytes);
      final digest = _hexDigest(digestBytes.bytes);
      final serverDigest = row['digest'] as String?;
      if (serverDigest != null && serverDigest != digest) {
        throw const FormatException('Membership digest is invalid');
      }
      final keyEpoch = body['key_epoch'];
      if (keyEpoch is! int || keyEpoch < 1) {
        throw const FormatException('Membership key epoch is invalid');
      }
      if (previousKeyEpoch != null &&
          (keyEpoch < previousKeyEpoch ||
              (keyEpoch != previousKeyEpoch &&
                  keyEpoch != previousKeyEpoch + 1))) {
        throw const FormatException(
          'Membership key epochs must stay the same or advance by one',
        );
      }
      previousKeyEpoch = keyEpoch;
      final members = body['members'];
      if (members is! List || members.isEmpty) {
        throw const FormatException('Membership members are missing');
      }
      verified.add(
        VerifiedMembership(
          version: version,
          digest: digest,
          signerDeviceId: signerId,
          manifest: body,
        ),
      );
      previousDigest = digest;
    }
    return verified;
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw const FormatException('Membership version must be an integer');
  }

  String _hexDigest(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  List<String> _objectRefs(Object? value, {required String source}) {
    if (value is! List) {
      throw FormatException('$source object_refs must be a list');
    }
    if (value.length > 1024) {
      throw FormatException('$source object_refs exceeds the 1024 item limit');
    }
    final refs = <String>[];
    String? previous;
    for (final item in value) {
      if (item is! String || !_isCanonicalUuid(item)) {
        throw FormatException(
          '$source object_refs must contain lowercase canonical UUIDs',
        );
      }
      if (previous != null && previous.compareTo(item) >= 0) {
        throw FormatException(
          '$source object_refs must be strictly ascending and unique',
        );
      }
      refs.add(item);
      previous = item;
    }
    return refs;
  }

  List<String> _plaintextObjectRefs(Map<String, dynamic> plaintext) {
    if (!plaintext.containsKey('_manifest')) return const [];
    final rawManifest = plaintext['_manifest'];
    if (rawManifest is! Map) {
      throw const FormatException('Record _manifest must be a JSON object');
    }
    if (!rawManifest.containsKey('object_refs')) return const [];
    return _objectRefs(rawManifest['object_refs'], source: 'Plaintext');
  }

  Future<Uint8List> derivePurposeKey({
    required SecureKey inputKey,
    required String purpose,
    Uint8List? salt,
    Map<String, Object?> context = const {},
  }) async {
    final info = Uint8List.fromList(
      utf8.encode(canonicalJson(['atermius', purpose, 1, context])),
    );
    final inputBytes = inputKey.extractBytes();
    try {
      final derived = await _hkdf.deriveKey(
        secretKey: crypto.SecretKey(inputBytes),
        nonce: salt ?? Uint8List(32),
        info: info,
      );
      final extracted = await derived.extract();
      try {
        // cryptography exposes extracted key bytes through an intentionally
        // immutable SensitiveBytes list. Copy into a mutable buffer so callers
        // can erase their working key after use, then release the provider's
        // extracted key object.
        return Uint8List.fromList(extracted.bytes);
      } finally {
        extracted.destroy();
      }
    } finally {
      inputBytes.fillRange(0, inputBytes.length, 0);
      info.fillRange(0, info.length, 0);
    }
  }

  /// Wraps a random 32-byte local user master key (UMK) using a password-derived
  /// key. This format is intentionally separate from the account-key envelope:
  /// its HKDF purpose and authenticated context bind it to one local profile
  /// and local data domain.
  Future<Map<String, Object?>> wrapLocalUmk({
    required String password,
    required KdfParameters params,
    required Uint8List umk,
    required String profileId,
    required String localDataDomainId,
  }) async {
    _validateLocalUmkContext(profileId, localDataDomainId);
    _validateLocalUmkKdf(params);
    if (umk.length != 32) {
      throw const FormatException('Local UMK must be exactly 32 bytes');
    }

    final aadFields = _localUmkAadFields(
      params: params,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
    );
    final aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
    final k0 = derivePasswordKey(password, params);
    SecureKey? wrappingKey;
    try {
      final keyBytes = await derivePurposeKey(
        inputKey: k0,
        purpose: _localUmkPurpose,
        salt: params.salt,
        context: {
          'envelope_version': _localUmkEnvelopeVersion,
          'key_version': _localUmkKeyVersion,
        },
      );
      try {
        wrappingKey = sodium.secureCopy(keyBytes);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }

      final nonce = randomBytes(24);
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: umk,
        nonce: nonce,
        key: wrappingKey,
        additionalData: aadBytes,
      );
      return {
        ...aadFields,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
    } finally {
      aadBytes.fillRange(0, aadBytes.length, 0);
      k0.dispose();
      wrappingKey?.dispose();
    }
  }

  /// Opens a local UMK envelope only when its version and both local UUID
  /// contexts match the caller's expected profile and data domain.
  Future<Uint8List> unwrapLocalUmk({
    required String password,
    required Map<String, dynamic> envelope,
    required String profileId,
    required String localDataDomainId,
  }) async {
    _validateLocalUmkContext(profileId, localDataDomainId);
    if (envelope.keys.toSet().difference(_localUmkEnvelopeFields).isNotEmpty ||
        !envelope.keys.toSet().containsAll(_localUmkEnvelopeFields) ||
        envelope['format'] != _localUmkEnvelopeFormat ||
        envelope['envelope_version'] is! int ||
        envelope['envelope_version'] != _localUmkEnvelopeVersion ||
        envelope['key_version'] is! int ||
        envelope['key_version'] != _localUmkKeyVersion ||
        envelope['purpose'] != _localUmkPurpose ||
        envelope['profile_id'] != profileId ||
        envelope['local_data_domain_id'] != localDataDomainId) {
      throw const FormatException('Local UMK envelope context is invalid');
    }

    final rawKdf = envelope['kdf'];
    if (rawKdf is! Map || rawKdf.keys.any((key) => key is! String)) {
      throw const FormatException('Local UMK envelope KDF is invalid');
    }
    final kdfJson = Map<String, dynamic>.from(rawKdf);
    if (kdfJson.keys.toSet().difference(_kdfParameterFields).isNotEmpty ||
        !kdfJson.keys.toSet().containsAll(_kdfParameterFields) ||
        kdfJson['id'] != 'argon2id13' ||
        kdfJson['salt'] is! String ||
        kdfJson['mem_kib'] is! int ||
        kdfJson['iterations'] is! int ||
        kdfJson['parallelism'] is! int ||
        kdfJson['version'] is! int) {
      throw const FormatException('Local UMK envelope KDF is invalid');
    }
    final params = KdfParameters.fromJson(kdfJson);
    _validateLocalUmkKdf(params);
    if (params.toJson()['salt'] != kdfJson['salt']) {
      throw const FormatException('Local UMK KDF salt is not canonical');
    }
    final nonceText = envelope['nonce'];
    final ciphertextText = envelope['ciphertext'];
    if (nonceText is! String || ciphertextText is! String) {
      throw const FormatException('Local UMK envelope bytes are invalid');
    }

    final nonce = _decodeCanonicalBase64Url(nonceText, 'nonce');
    final ciphertext = _decodeCanonicalBase64Url(ciphertextText, 'ciphertext');
    if (nonce.length != 24 || ciphertext.length != 32 + 16) {
      throw const FormatException('Local UMK envelope lengths are invalid');
    }

    final aadFields = _localUmkAadFields(
      params: params,
      profileId: profileId,
      localDataDomainId: localDataDomainId,
    );
    final aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
    final k0 = derivePasswordKey(password, params);
    SecureKey? wrappingKey;
    try {
      final keyBytes = await derivePurposeKey(
        inputKey: k0,
        purpose: _localUmkPurpose,
        salt: params.salt,
        context: {
          'envelope_version': _localUmkEnvelopeVersion,
          'key_version': _localUmkKeyVersion,
        },
      );
      try {
        wrappingKey = sodium.secureCopy(keyBytes);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }

      late Uint8List umk;
      try {
        umk = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ciphertext,
          nonce: nonce,
          key: wrappingKey,
          additionalData: aadBytes,
        );
      } on Object {
        throw const FormatException('Local UMK envelope authentication failed');
      }
      if (umk.length != 32) {
        umk.fillRange(0, umk.length, 0);
        throw const FormatException('Local UMK must be exactly 32 bytes');
      }
      return umk;
    } finally {
      aadBytes.fillRange(0, aadBytes.length, 0);
      k0.dispose();
      wrappingKey?.dispose();
    }
  }

  /// Creates the ciphertext-only persisted envelope for one local Vault key.
  /// The returned map contains no UMK or Vault-key bytes and is deliberately
  /// bound to one local profile, data domain, Vault, and key epoch.
  Future<Map<String, Object?>> wrapLocalVaultKey({
    required Uint8List umk,
    required Uint8List vaultKey,
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required int keyEpoch,
  }) async {
    _validateLocalKeyContext(profileId, localDataDomainId);
    if (!_isCanonicalLocalUuid(localVaultId) || keyEpoch < 1) {
      throw const FormatException('Local Vault key context is invalid');
    }
    if (umk.length != 32 || vaultKey.length != 32) {
      throw const FormatException(
        'Local key material must be exactly 32 bytes',
      );
    }

    final aadFields = _localVaultKeyAadFields(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      keyEpoch: keyEpoch,
    );
    final aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
    final wrappingKey = await _deriveLocalEnvelopeKey(
      umk: umk,
      purpose: _localVaultKeyPurpose,
      context: {
        'profile_id': profileId,
        'local_data_domain_id': localDataDomainId,
        'local_vault_id': localVaultId,
        'key_epoch': keyEpoch,
        'key_version': _localVaultKeyVersion,
      },
    );
    try {
      final nonce = randomBytes(24);
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: vaultKey,
        nonce: nonce,
        key: wrappingKey,
        additionalData: aadBytes,
      );
      return {
        ...aadFields,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
    } finally {
      aadBytes.fillRange(0, aadBytes.length, 0);
      wrappingKey.dispose();
    }
  }

  /// Opens a local Vault-key envelope only for its exact profile/domain/Vault
  /// and epoch. The caller owns and must clear the returned key bytes.
  Future<Uint8List> unwrapLocalVaultKey({
    required Uint8List umk,
    required Map<String, dynamic> envelope,
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required int keyEpoch,
  }) async {
    _validateLocalKeyContext(profileId, localDataDomainId);
    if (!_isCanonicalLocalUuid(localVaultId) ||
        keyEpoch < 1 ||
        umk.length != 32) {
      throw const FormatException('Local Vault key context is invalid');
    }
    _validateExactEnvelopeFields(envelope, _localVaultKeyEnvelopeFields);
    if (envelope['envelope_version'] is! int ||
        envelope['key_version'] is! int ||
        envelope['key_epoch'] is! int ||
        envelope['format'] != _localVaultKeyEnvelopeFormat ||
        envelope['envelope_version'] != _localVaultKeyEnvelopeVersion ||
        envelope['key_version'] != _localVaultKeyVersion ||
        envelope['purpose'] != _localVaultKeyPurpose ||
        envelope['profile_id'] != profileId ||
        envelope['local_data_domain_id'] != localDataDomainId ||
        envelope['local_vault_id'] != localVaultId ||
        envelope['key_epoch'] != keyEpoch ||
        envelope['suite'] != _localKeyEnvelopeSuite) {
      throw const FormatException(
        'Local Vault key envelope context is invalid',
      );
    }
    final nonceText = envelope['nonce'];
    final ciphertextText = envelope['ciphertext'];
    if (nonceText is! String || ciphertextText is! String) {
      throw const FormatException('Local Vault key envelope bytes are invalid');
    }
    final nonce = _decodeCanonicalLocalBytes(nonceText, 'nonce');
    final ciphertext = _decodeCanonicalLocalBytes(ciphertextText, 'ciphertext');
    if (nonce.length != 24 || ciphertext.length != 32 + 16) {
      throw const FormatException(
        'Local Vault key envelope lengths are invalid',
      );
    }

    final aadFields = _localVaultKeyAadFields(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      keyEpoch: keyEpoch,
    );
    final aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
    final wrappingKey = await _deriveLocalEnvelopeKey(
      umk: umk,
      purpose: _localVaultKeyPurpose,
      context: {
        'profile_id': profileId,
        'local_data_domain_id': localDataDomainId,
        'local_vault_id': localVaultId,
        'key_epoch': keyEpoch,
        'key_version': _localVaultKeyVersion,
      },
    );
    try {
      late Uint8List vaultKey;
      try {
        vaultKey = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ciphertext,
          nonce: nonce,
          key: wrappingKey,
          additionalData: aadBytes,
        );
      } on Object {
        throw const FormatException('Local Vault key authentication failed');
      }
      if (vaultKey.length != 32) {
        vaultKey.fillRange(0, vaultKey.length, 0);
        throw const FormatException('Local Vault key must be exactly 32 bytes');
      }
      return vaultKey;
    } finally {
      aadBytes.fillRange(0, aadBytes.length, 0);
      wrappingKey.dispose();
    }
  }

  /// Seals the DeviceIdentity private keys into a ciphertext-only storage map.
  /// Public keys remain visible so callers can identify/register the device;
  /// all public metadata is authenticated as part of the ciphertext.
  Future<Map<String, Object?>> wrapLocalDeviceIdentity({
    required Uint8List umk,
    required DeviceIdentity identity,
    required String profileId,
    required String localDataDomainId,
    required String localDeviceId,
    required int keyVersion,
  }) async {
    _validateLocalKeyContext(profileId, localDataDomainId);
    if (!_isCanonicalLocalUuid(localDeviceId) ||
        identity.deviceId != localDeviceId ||
        keyVersion < 1 ||
        umk.length != 32) {
      throw const FormatException('Local device identity context is invalid');
    }
    final signingPublic = identity.signing.publicKey;
    final encryptionPublic = identity.encryption.publicKey;
    if (signingPublic.length != 32 ||
        encryptionPublic.length != 32 ||
        !_identityKeyPairMatches(
          signingPublic: signingPublic,
          encryptionPublic: encryptionPublic,
          signingSecret: identity.signing.secretKey,
          encryptionSecret: identity.encryption.secretKey,
        )) {
      throw const FormatException('Local device identity key pair is invalid');
    }
    Uint8List? signingSecretBytes;
    Uint8List? encryptionSecretBytes;
    Uint8List? privateBundle;
    Uint8List? aadBytes;
    sodium_api.SecureKey? wrappingKey;
    try {
      signingSecretBytes = identity.signing.secretKey.extractBytes();
      encryptionSecretBytes = identity.encryption.secretKey.extractBytes();
      if (signingSecretBytes.length != sodium.crypto.sign.secretKeyBytes ||
          encryptionSecretBytes.length != sodium.crypto.box.secretKeyBytes) {
        throw const FormatException(
          'Local device identity private key lengths are invalid',
        );
      }
      privateBundle = Uint8List(
        signingSecretBytes.length + encryptionSecretBytes.length,
      );
      privateBundle.setRange(0, signingSecretBytes.length, signingSecretBytes);
      privateBundle.setRange(
        signingSecretBytes.length,
        privateBundle.length,
        encryptionSecretBytes,
      );

      final aadFields = _localDeviceIdentityAadFields(
        profileId: profileId,
        localDataDomainId: localDataDomainId,
        localDeviceId: localDeviceId,
        keyVersion: keyVersion,
        signingPublic: encodeBase64Url(signingPublic),
        encryptionPublic: encodeBase64Url(encryptionPublic),
      );
      aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
      wrappingKey = await _deriveLocalEnvelopeKey(
        umk: umk,
        purpose: _localDeviceIdentityPurpose,
        context: {
          'profile_id': profileId,
          'local_data_domain_id': localDataDomainId,
          'local_device_id': localDeviceId,
          'key_version': keyVersion,
        },
      );
      final nonce = randomBytes(24);
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: privateBundle,
        nonce: nonce,
        key: wrappingKey,
        additionalData: aadBytes,
      );
      return {
        ...aadFields,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
    } finally {
      signingSecretBytes?.fillRange(0, signingSecretBytes.length, 0);
      encryptionSecretBytes?.fillRange(0, encryptionSecretBytes.length, 0);
      privateBundle?.fillRange(0, privateBundle.length, 0);
      aadBytes?.fillRange(0, aadBytes.length, 0);
      wrappingKey?.dispose();
    }
  }

  /// Opens the local DeviceIdentity package after exact context, envelope and
  /// key-pair validation. The returned identity owns its SecureKeys and must be
  /// disposed by its caller when the local profile is locked.
  Future<DeviceIdentity> unwrapLocalDeviceIdentity({
    required Uint8List umk,
    required Map<String, dynamic> envelope,
    required String profileId,
    required String localDataDomainId,
    required String localDeviceId,
    required int keyVersion,
  }) async {
    _validateLocalKeyContext(profileId, localDataDomainId);
    if (!_isCanonicalLocalUuid(localDeviceId) ||
        keyVersion < 1 ||
        umk.length != 32) {
      throw const FormatException('Local device identity context is invalid');
    }
    _validateExactEnvelopeFields(envelope, _localDeviceIdentityEnvelopeFields);
    final stringFields = [
      'format',
      'purpose',
      'profile_id',
      'local_data_domain_id',
      'local_device_id',
      'signing_algorithm',
      'signing_public',
      'encryption_algorithm',
      'encryption_public',
      'suite',
      'nonce',
      'ciphertext',
    ];
    if (stringFields.any((field) => envelope[field] is! String) ||
        envelope['envelope_version'] is! int ||
        envelope['key_version'] is! int ||
        envelope['format'] != _localDeviceIdentityEnvelopeFormat ||
        envelope['envelope_version'] != _localDeviceIdentityEnvelopeVersion ||
        envelope['key_version'] != keyVersion ||
        envelope['purpose'] != _localDeviceIdentityPurpose ||
        envelope['profile_id'] != profileId ||
        envelope['local_data_domain_id'] != localDataDomainId ||
        envelope['local_device_id'] != localDeviceId ||
        envelope['signing_algorithm'] != _localDeviceSigningAlgorithm ||
        envelope['encryption_algorithm'] != _localDeviceEncryptionAlgorithm ||
        envelope['suite'] != _localKeyEnvelopeSuite) {
      throw const FormatException(
        'Local device identity envelope context is invalid',
      );
    }
    final signingPublicText = envelope['signing_public']! as String;
    final encryptionPublicText = envelope['encryption_public']! as String;
    final signingPublic = _decodeCanonicalLocalBytes(
      signingPublicText,
      'signing_public',
    );
    final encryptionPublic = _decodeCanonicalLocalBytes(
      encryptionPublicText,
      'encryption_public',
    );
    if (signingPublic.length != 32 || encryptionPublic.length != 32) {
      throw const FormatException(
        'Local device identity public keys are invalid',
      );
    }
    final nonce = _decodeCanonicalLocalBytes(
      envelope['nonce']! as String,
      'nonce',
    );
    final ciphertext = _decodeCanonicalLocalBytes(
      envelope['ciphertext']! as String,
      'ciphertext',
    );
    final privateBundleLength =
        sodium.crypto.sign.secretKeyBytes + sodium.crypto.box.secretKeyBytes;
    if (nonce.length != 24 || ciphertext.length != privateBundleLength + 16) {
      throw const FormatException(
        'Local device identity envelope lengths are invalid',
      );
    }

    final aadFields = _localDeviceIdentityAadFields(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localDeviceId: localDeviceId,
      keyVersion: keyVersion,
      signingPublic: signingPublicText,
      encryptionPublic: encryptionPublicText,
    );
    final aadBytes = Uint8List.fromList(utf8.encode(canonicalJson(aadFields)));
    final wrappingKey = await _deriveLocalEnvelopeKey(
      umk: umk,
      purpose: _localDeviceIdentityPurpose,
      context: {
        'profile_id': profileId,
        'local_data_domain_id': localDataDomainId,
        'local_device_id': localDeviceId,
        'key_version': keyVersion,
      },
    );
    Uint8List? privateBundle;
    sodium_api.SecureKey? signingSecret;
    sodium_api.SecureKey? encryptionSecret;
    var transferred = false;
    try {
      try {
        privateBundle = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ciphertext,
          nonce: nonce,
          key: wrappingKey,
          additionalData: aadBytes,
        );
      } on Object {
        throw const FormatException(
          'Local device identity authentication failed',
        );
      }
      if (privateBundle.length != privateBundleLength) {
        throw const FormatException(
          'Local device identity private bundle is invalid',
        );
      }
      final signingSecretBytes = Uint8List.fromList(
        privateBundle.sublist(0, sodium.crypto.sign.secretKeyBytes),
      );
      final encryptionSecretBytes = Uint8List.fromList(
        privateBundle.sublist(sodium.crypto.sign.secretKeyBytes),
      );
      try {
        signingSecret = sodium.secureCopy(signingSecretBytes);
        encryptionSecret = sodium.secureCopy(encryptionSecretBytes);
      } finally {
        signingSecretBytes.fillRange(0, signingSecretBytes.length, 0);
        encryptionSecretBytes.fillRange(0, encryptionSecretBytes.length, 0);
      }
      if (!_identityKeyPairMatches(
        signingPublic: signingPublic,
        encryptionPublic: encryptionPublic,
        signingSecret: signingSecret,
        encryptionSecret: encryptionSecret,
      )) {
        throw const FormatException(
          'Local device identity key pair is invalid',
        );
      }
      final result = DeviceIdentity(
        deviceId: localDeviceId,
        signing: sodium_api.KeyPair(
          publicKey: signingPublic,
          secretKey: signingSecret,
        ),
        encryption: sodium_api.KeyPair(
          publicKey: encryptionPublic,
          secretKey: encryptionSecret,
        ),
      );
      transferred = true;
      return result;
    } finally {
      privateBundle?.fillRange(0, privateBundle.length, 0);
      aadBytes.fillRange(0, aadBytes.length, 0);
      wrappingKey.dispose();
      if (!transferred) {
        signingSecret?.dispose();
        encryptionSecret?.dispose();
      }
    }
  }

  Future<sodium_api.SecureKey> _deriveLocalEnvelopeKey({
    required Uint8List umk,
    required String purpose,
    required Map<String, Object?> context,
  }) async {
    if (umk.length != 32) {
      throw const FormatException('Local UMK must be exactly 32 bytes');
    }
    final inputKey = sodium.secureCopy(umk);
    try {
      final derivedBytes = await derivePurposeKey(
        inputKey: inputKey,
        purpose: purpose,
        context: context,
      );
      try {
        return sodium.secureCopy(derivedBytes);
      } finally {
        derivedBytes.fillRange(0, derivedBytes.length, 0);
      }
    } finally {
      inputKey.dispose();
    }
  }

  bool _identityKeyPairMatches({
    required Uint8List signingPublic,
    required Uint8List encryptionPublic,
    required sodium_api.SecureKey signingSecret,
    required sodium_api.SecureKey encryptionSecret,
  }) {
    try {
      final derivedSigningPublic = sodium.crypto.sign.skToPk(signingSecret);
      if (!_sameBytes(derivedSigningPublic, signingPublic)) return false;

      // Box does not expose a secret-key-to-public-key helper. A sealed
      // challenge exercises the pair in both directions without persisting or
      // exporting another private-key representation.
      final challenge = randomBytes(32);
      Uint8List? sealed;
      Uint8List? opened;
      try {
        sealed = sodium.crypto.box.seal(
          message: challenge,
          publicKey: encryptionPublic,
        );
        opened = sodium.crypto.box.sealOpen(
          cipherText: sealed,
          publicKey: encryptionPublic,
          secretKey: encryptionSecret,
        );
        return _sameBytes(challenge, opened);
      } finally {
        challenge.fillRange(0, challenge.length, 0);
        sealed?.fillRange(0, sealed.length, 0);
        opened?.fillRange(0, opened.length, 0);
      }
    } on Object {
      return false;
    }
  }

  bool _sameBytes(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Map<String, Object?> _localVaultKeyAadFields({
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required int keyEpoch,
  }) => {
    'format': _localVaultKeyEnvelopeFormat,
    'envelope_version': _localVaultKeyEnvelopeVersion,
    'key_version': _localVaultKeyVersion,
    'purpose': _localVaultKeyPurpose,
    'profile_id': profileId,
    'local_data_domain_id': localDataDomainId,
    'local_vault_id': localVaultId,
    'key_epoch': keyEpoch,
    'suite': _localKeyEnvelopeSuite,
  };

  Map<String, Object?> _localDeviceIdentityAadFields({
    required String profileId,
    required String localDataDomainId,
    required String localDeviceId,
    required int keyVersion,
    required String signingPublic,
    required String encryptionPublic,
  }) => {
    'format': _localDeviceIdentityEnvelopeFormat,
    'envelope_version': _localDeviceIdentityEnvelopeVersion,
    'key_version': keyVersion,
    'purpose': _localDeviceIdentityPurpose,
    'profile_id': profileId,
    'local_data_domain_id': localDataDomainId,
    'local_device_id': localDeviceId,
    'signing_algorithm': _localDeviceSigningAlgorithm,
    'signing_public': signingPublic,
    'encryption_algorithm': _localDeviceEncryptionAlgorithm,
    'encryption_public': encryptionPublic,
    'suite': _localKeyEnvelopeSuite,
  };

  void _validateLocalKeyContext(String profileId, String localDataDomainId) {
    if (!_isCanonicalLocalUuid(profileId) ||
        !_isCanonicalLocalUuid(localDataDomainId)) {
      throw const FormatException(
        'Local profile and data-domain IDs are invalid',
      );
    }
  }

  void _validateExactEnvelopeFields(
    Map<String, dynamic> envelope,
    Set<String> expectedFields,
  ) {
    final actual = envelope.keys.toSet();
    if (actual.difference(expectedFields).isNotEmpty ||
        !actual.containsAll(expectedFields)) {
      throw const FormatException('Local key envelope fields are invalid');
    }
  }

  Uint8List _decodeCanonicalLocalBytes(String value, String field) {
    try {
      final decoded = decodeBase64Url(value);
      if (encodeBase64Url(decoded) != value) {
        throw FormatException('Local key envelope $field is not canonical');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } on Object {
      throw FormatException('Local key envelope $field is invalid');
    }
  }

  void _validateLocalUmkContext(String profileId, String localDataDomainId) {
    if (!_isCanonicalLocalUuid(profileId) ||
        !_isCanonicalLocalUuid(localDataDomainId)) {
      throw const FormatException(
        'Local UMK profile and data domain IDs must be canonical UUIDs',
      );
    }
  }

  void _validateLocalUmkKdf(KdfParameters params) {
    params.validate();
    if (params.memoryKib != _localUmkKdfMemoryKib ||
        params.iterations != _localUmkKdfIterations ||
        params.parallelism != _localUmkKdfParallelism ||
        params.version != _localUmkKdfVersion) {
      throw const FormatException(
        'Local UMK v1 requires its fixed Argon2id parameter profile',
      );
    }
  }

  Map<String, Object?> _localUmkAadFields({
    required KdfParameters params,
    required String profileId,
    required String localDataDomainId,
  }) => {
    'format': _localUmkEnvelopeFormat,
    'envelope_version': _localUmkEnvelopeVersion,
    'key_version': _localUmkKeyVersion,
    'purpose': _localUmkPurpose,
    'profile_id': profileId,
    'local_data_domain_id': localDataDomainId,
    'kdf': params.toJson(),
  };

  Uint8List _decodeCanonicalBase64Url(String value, String field) {
    try {
      final decoded = decodeBase64Url(value);
      if (encodeBase64Url(decoded) != value) {
        throw FormatException('Local UMK $field is not canonical base64url');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } on Object {
      throw FormatException('Local UMK $field is invalid');
    }
  }

  Future<Uint8List> deriveLoginVerifier(
    String password,
    KdfParameters params,
  ) async {
    final k0 = derivePasswordKey(password, params);
    try {
      return await derivePurposeKey(
        inputKey: k0,
        purpose: 'login-verifier',
        context: {'kdf_version': params.version},
      );
    } finally {
      k0.dispose();
    }
  }

  Future<Map<String, Object?>> wrapAccountKey({
    required String password,
    required KdfParameters params,
    required Uint8List accountKey,
  }) async {
    final k0 = derivePasswordKey(password, params);
    SecureKey? wrappingKey;
    try {
      final keyBytes = await derivePurposeKey(
        inputKey: k0,
        purpose: 'account-key-wrap',
        salt: params.salt,
        context: {'version': 1},
      );
      wrappingKey = sodium.secureCopy(keyBytes);
      keyBytes.fillRange(0, keyBytes.length, 0);
      final nonce = randomBytes(24);
      final aad = utf8.encode(
        canonicalJson({'version': 1, 'context': 'account-key'}),
      );
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: accountKey,
        nonce: nonce,
        key: wrappingKey,
        additionalData: Uint8List.fromList(aad),
      );
      return {
        'version': 1,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
    } finally {
      k0.dispose();
      wrappingKey?.dispose();
    }
  }

  Future<InitialVaultMaterial> createInitialVault({
    required String accountId,
    required String name,
    required DeviceIdentity identity,
  }) async {
    final vaultId = _uuid.v4();
    final vaultKey = randomBytes(32);
    final keyEnvelopeBody = <String, Object?>{
      'vault_id': vaultId,
      'recipient_device_id': identity.deviceId,
      'key_epoch': 1,
      'membership_version': 1,
      'vault_key': encodeBase64Url(vaultKey),
    };
    final sealed = sodium.crypto.box.seal(
      message: Uint8List.fromList(utf8.encode(canonicalJson(keyEnvelopeBody))),
      publicKey: identity.encryption.publicKey,
    );
    final keyEnvelopeUnsigned = <String, Object?>{
      'recipient_device_id': identity.deviceId,
      'key_epoch': 1,
      'membership_version': 1,
      'envelope': {
        'version': 1,
        'suite': 'crypto_box_seal',
        'ciphertext': encodeBase64Url(sealed),
      },
    };
    final keyEnvelopeSignaturePayload = <String, Object?>{
      'vault_id': vaultId,
      ...keyEnvelopeUnsigned,
    };
    final keyEnvelopeSignature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(
        utf8.encode(canonicalJson(keyEnvelopeSignaturePayload)),
      ),
      secretKey: identity.signing.secretKey,
    );
    final publicKeyDigest = await crypto.Sha256().hash(
      identity.encryption.publicKey,
    );
    final nameEnvelope = await encryptVaultName(
      vaultId: vaultId,
      vaultKey: vaultKey,
      name: name,
    );
    final manifestBody = <String, Object?>{
      'key_epoch': 1,
      'display_name_envelope': nameEnvelope,
      'members': [
        {
          'user_id': accountId,
          'role': 'owner',
          'state': 'active',
          'encryption_key_fingerprint': encodeBase64Url(publicKeyDigest.bytes),
        },
      ],
      'signer_device_id': identity.deviceId,
    };
    final membershipUnsigned = <String, Object?>{
      'vault_id': vaultId,
      'membership_version': 1,
      'previous_digest': null,
      'manifest': manifestBody,
    };
    final manifestSignature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(
        utf8.encode(canonicalJson(membershipUnsigned)),
      ),
      secretKey: identity.signing.secretKey,
    );
    return InitialVaultMaterial(
      vaultId: vaultId,
      vaultKey: vaultKey,
      payload: {
        'vault_id': vaultId,
        'name_envelope': nameEnvelope,
        'key_epoch': 1,
        'membership_version': 1,
        'key_envelope': {
          ...keyEnvelopeUnsigned,
          'signature': encodeBase64Url(keyEnvelopeSignature),
        },
        'membership': {
          'membership_version': 1,
          'previous_digest': null,
          'manifest': manifestBody,
          'signature': encodeBase64Url(manifestSignature),
        },
      },
    );
  }

  Map<String, Object?> createDeviceKeyEnvelope({
    required String vaultId,
    required Uint8List vaultKey,
    required int keyEpoch,
    required int membershipVersion,
    required String recipientDeviceId,
    required Uint8List recipientEncryptionPublicKey,
    required DeviceIdentity signer,
  }) {
    final context = <String, Object?>{
      'vault_id': vaultId,
      'recipient_device_id': recipientDeviceId,
      'key_epoch': keyEpoch,
      'membership_version': membershipVersion,
    };
    final clear = <String, Object?>{
      ...context,
      'vault_key': encodeBase64Url(vaultKey),
    };
    final sealed = sodium.crypto.box.seal(
      message: Uint8List.fromList(utf8.encode(canonicalJson(clear))),
      publicKey: recipientEncryptionPublicKey,
    );
    final envelope = <String, Object?>{
      'version': 1,
      'suite': 'crypto_box_seal',
      'ciphertext': encodeBase64Url(sealed),
    };
    final unsigned = <String, Object?>{...context, 'envelope': envelope};
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      secretKey: signer.signing.secretKey,
    );
    return {...unsigned, 'signature': encodeBase64Url(signature)};
  }

  Future<Uint8List> openVaultKeyEnvelope({
    required String vaultId,
    required String deviceId,
    required DeviceIdentity identity,
    required Map<String, dynamic> keyEnvelope,
    required Uint8List signerPublicKey,
  }) async {
    final envelopeBody = <String, dynamic>{
      'vault_id': vaultId,
      'recipient_device_id': keyEnvelope['recipient_device_id'],
      'key_epoch': keyEnvelope['key_epoch'],
      'membership_version': keyEnvelope['membership_version'],
      'envelope': keyEnvelope['envelope'],
    };
    final valid = sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(envelopeBody))),
      signature: decodeBase64Url(keyEnvelope['signature'] as String),
      publicKey: signerPublicKey,
    );
    if (!valid) {
      throw const FormatException('Vault key envelope signature is invalid');
    }
    if (keyEnvelope['recipient_device_id'] != deviceId) {
      throw const FormatException(
        'Vault key envelope is addressed to another device',
      );
    }
    final sealedEnvelope = Map<String, dynamic>.from(
      keyEnvelope['envelope'] as Map,
    );
    if (sealedEnvelope['version'] != 1 ||
        sealedEnvelope['suite'] != 'crypto_box_seal') {
      throw const FormatException('Unsupported vault key envelope');
    }
    final opened = sodium.crypto.box.sealOpen(
      cipherText: decodeBase64Url(sealedEnvelope['ciphertext'] as String),
      publicKey: identity.encryption.publicKey,
      secretKey: identity.encryption.secretKey,
    );
    final decoded = jsonDecode(utf8.decode(opened));
    if (decoded is! Map<String, dynamic> ||
        decoded['vault_id'] != vaultId ||
        decoded['recipient_device_id'] != deviceId ||
        decoded['key_epoch'] != keyEnvelope['key_epoch'] ||
        decoded['membership_version'] != keyEnvelope['membership_version']) {
      throw const FormatException('Vault key envelope context does not match');
    }
    final key = decodeBase64Url(decoded['vault_key'] as String);
    if (key.length != 32) {
      throw const FormatException('Invalid vault key length');
    }
    return key;
  }

  Future<Map<String, Object?>> encryptVaultName({
    required String vaultId,
    required Uint8List vaultKey,
    required String name,
  }) async {
    final derived = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(vaultKey),
      nonce: Uint8List(32),
      info: utf8.encode(canonicalJson(['atermius', 'vault-name', 1, vaultId])),
    );
    final key = sodium.secureCopy(
      Uint8List.fromList(await derived.extractBytes()),
    );
    try {
      final nonce = randomBytes(24);
      final cipherText = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: Uint8List.fromList(utf8.encode(name)),
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(
            canonicalJson({
              'vault_id': vaultId,
              'version': 1,
              'purpose': 'display_name',
            }),
          ),
        ),
      );
      return {
        'version': 1,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(cipherText),
      };
    } finally {
      key.dispose();
    }
  }

  Future<String> decryptVaultName({
    required String vaultId,
    required Uint8List vaultKey,
    required Map<String, dynamic> envelope,
  }) async {
    if (envelope['version'] != 1) {
      throw const FormatException('Unsupported vault name envelope');
    }
    final derived = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(vaultKey),
      nonce: Uint8List(32),
      info: utf8.encode(canonicalJson(['atermius', 'vault-name', 1, vaultId])),
    );
    final key = sodium.secureCopy(
      Uint8List.fromList(await derived.extractBytes()),
    );
    try {
      final clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: decodeBase64Url(envelope['ciphertext'] as String),
        nonce: decodeBase64Url(envelope['nonce'] as String),
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(
            canonicalJson({
              'vault_id': vaultId,
              'version': 1,
              'purpose': 'display_name',
            }),
          ),
        ),
      );
      return utf8.decode(clear);
    } finally {
      key.dispose();
    }
  }

  Future<Uint8List> unwrapAccountKey({
    required String password,
    required KdfParameters params,
    required Map<String, dynamic> envelope,
  }) async {
    final k0 = derivePasswordKey(password, params);
    SecureKey? wrappingKey;
    try {
      final keyBytes = await derivePurposeKey(
        inputKey: k0,
        purpose: 'account-key-wrap',
        salt: params.salt,
        context: {'version': 1},
      );
      wrappingKey = sodium.secureCopy(keyBytes);
      keyBytes.fillRange(0, keyBytes.length, 0);
      return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: decodeBase64Url(envelope['ciphertext'] as String),
        nonce: decodeBase64Url(envelope['nonce'] as String),
        key: wrappingKey,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson({'version': 1, 'context': 'account-key'})),
        ),
      );
    } finally {
      k0.dispose();
      wrappingKey?.dispose();
    }
  }

  /// Encrypts one local-only record revision.
  ///
  /// This envelope deliberately has no server sequence, operation ID,
  /// membership, or server-space fields. Local records must be re-encrypted
  /// into the server wire format before they can participate in sync.
  Future<Map<String, Object?>> encryptLocalRecord({
    required Uint8List vaultKey,
    required String profileId,
    required String localDataDomainId,
    required String localVaultId,
    required String recordId,
    required String? baseRevisionId,
    required String operation,
    required Map<String, Object?> plaintext,
    required DeviceIdentity identity,
  }) async {
    _validateLocalRecordContext(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: operation,
    );
    if (vaultKey.length != 32) {
      throw const FormatException('Local Vault key must be 32 bytes');
    }
    if (!_isCanonicalLocalUuid(identity.deviceId) ||
        identity.signing.publicKey.length != 32 ||
        identity.signing.secretKey.length != 64) {
      throw const FormatException('Local record signing identity is invalid');
    }

    final plaintextBytes = Uint8List.fromList(
      utf8.encode(canonicalJson(plaintext)),
    );
    SecureKey? key;
    Uint8List? keyBytes;
    try {
      if (plaintextBytes.length > _localRecordMaxCiphertextBytes - 16) {
        throw const FormatException('Local record plaintext is too large');
      }
      final revisionId = _uuid.v4();
      final kdfSalt = randomBytes(32);
      final nonce = randomBytes(24);
      final header = <String, Object?>{
        'format': _localRecordFormat,
        'schema_version': _localRecordSchemaVersion,
        'profile_id': profileId,
        'local_data_domain_id': localDataDomainId,
        'local_vault_id': localVaultId,
        'record_id': recordId,
        'revision_id': revisionId,
        'base_revision_id': baseRevisionId,
        'operation': operation,
        'crypto_suite': _localRecordCryptoSuite,
        'kdf_salt': encodeBase64Url(kdfSalt),
      };
      final info = utf8.encode(
        canonicalJson([
          'atermius',
          'local-record',
          _localRecordSchemaVersion,
          profileId,
          localDataDomainId,
          localVaultId,
          recordId,
          revisionId,
        ]),
      );
      final keyData = await _hkdf.deriveKey(
        secretKey: crypto.SecretKey(vaultKey),
        nonce: kdfSalt,
        info: info,
      );
      keyBytes = Uint8List.fromList(await keyData.extractBytes());
      key = sodium.secureCopy(keyBytes);
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plaintextBytes,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(utf8.encode(canonicalJson(header))),
      );
      final unsigned = <String, Object?>{
        'format': _localRecordFormat,
        'header': header,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: identity.signing.secretKey,
      );
      return {...unsigned, 'signature': encodeBase64Url(signature)};
    } finally {
      plaintextBytes.fillRange(0, plaintextBytes.length, 0);
      keyBytes?.fillRange(0, keyBytes.length, 0);
      key?.dispose();
    }
  }

  /// Opens a local record only after strict envelope, context, signature, and
  /// AEAD validation. The caller supplies the already trusted local author key.
  Future<Map<String, dynamic>> decryptLocalRecord({
    required Uint8List vaultKey,
    required Map<String, dynamic> envelope,
    required String expectedProfileId,
    required String expectedLocalDataDomainId,
    required String expectedLocalVaultId,
    required Uint8List authorPublicKey,
  }) async {
    _validateLocalProfileContext(
      profileId: expectedProfileId,
      localDataDomainId: expectedLocalDataDomainId,
      localVaultId: expectedLocalVaultId,
    );
    if (vaultKey.length != 32 || authorPublicKey.length != 32) {
      throw const FormatException('Local record key or author key is invalid');
    }
    _requireExactFields(envelope, _localRecordEnvelopeFields, 'Local record');
    if (envelope['format'] != _localRecordFormat) {
      throw const FormatException('Unsupported local record format');
    }
    final rawHeader = envelope['header'];
    if (rawHeader is! Map || rawHeader.keys.any((key) => key is! String)) {
      throw const FormatException('Local record header is invalid');
    }
    final header = Map<String, dynamic>.from(rawHeader);
    _requireExactFields(
      header,
      _localRecordHeaderFields,
      'Local record header',
    );
    if (header['format'] != _localRecordFormat ||
        header['schema_version'] is! int ||
        header['schema_version'] != _localRecordSchemaVersion ||
        header['crypto_suite'] != _localRecordCryptoSuite) {
      throw const FormatException('Unsupported local record header');
    }

    final profileId = _localRecordString(header, 'profile_id');
    final localDataDomainId = _localRecordString(
      header,
      'local_data_domain_id',
    );
    final localVaultId = _localRecordString(header, 'local_vault_id');
    final recordId = _localRecordString(header, 'record_id');
    final revisionId = _localRecordString(header, 'revision_id');
    final operation = _localRecordString(header, 'operation');
    final baseRevisionValue = header['base_revision_id'];
    if (baseRevisionValue != null && baseRevisionValue is! String) {
      throw const FormatException('Local record base revision is invalid');
    }
    final baseRevisionId = baseRevisionValue as String?;
    _validateLocalRecordContext(
      profileId: profileId,
      localDataDomainId: localDataDomainId,
      localVaultId: localVaultId,
      recordId: recordId,
      baseRevisionId: baseRevisionId,
      operation: operation,
    );
    if (!_isCanonicalLocalUuid(revisionId)) {
      throw const FormatException('Local record revision ID is invalid');
    }
    if (profileId != expectedProfileId ||
        localDataDomainId != expectedLocalDataDomainId ||
        localVaultId != expectedLocalVaultId) {
      throw const FormatException('Local record context does not match');
    }

    final kdfSalt = _decodeLocalRecordBase64(
      header['kdf_salt'],
      field: 'KDF salt',
      expectedBytes: 32,
    );
    final nonce = _decodeLocalRecordBase64(
      envelope['nonce'],
      field: 'nonce',
      expectedBytes: 24,
    );
    final ciphertext = _decodeLocalRecordBase64(
      envelope['ciphertext'],
      field: 'ciphertext',
      maximumBytes: _localRecordMaxCiphertextBytes,
      minimumBytes: 16,
    );
    final signature = _decodeLocalRecordBase64(
      envelope['signature'],
      field: 'signature',
      expectedBytes: 64,
    );
    final unsigned = <String, Object?>{
      'format': _localRecordFormat,
      'header': header,
      'nonce': envelope['nonce'],
      'ciphertext': envelope['ciphertext'],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: authorPublicKey,
    )) {
      throw const FormatException('Local record signature is invalid');
    }

    final info = utf8.encode(
      canonicalJson([
        'atermius',
        'local-record',
        _localRecordSchemaVersion,
        profileId,
        localDataDomainId,
        localVaultId,
        recordId,
        revisionId,
      ]),
    );
    SecureKey? key;
    Uint8List? keyBytes;
    Uint8List? clear;
    try {
      final keyData = await _hkdf.deriveKey(
        secretKey: crypto.SecretKey(vaultKey),
        nonce: kdfSalt,
        info: info,
      );
      keyBytes = Uint8List.fromList(await keyData.extractBytes());
      key = sodium.secureCopy(keyBytes);
      clear = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(utf8.encode(canonicalJson(header))),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Local record plaintext must be an object');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Local record authentication failed');
    } finally {
      if (clear != null) clear.fillRange(0, clear.length, 0);
      keyBytes?.fillRange(0, keyBytes.length, 0);
      key?.dispose();
    }
  }

  Future<Map<String, Object?>> encryptRecord({
    required Uint8List vaultKey,
    required String serverSpaceId,
    required String vaultId,
    required String recordId,
    required String? baseRevisionId,
    required String deviceId,
    required String deviceSequence,
    required String keyEpoch,
    required String membershipVersion,
    required String operation,
    required Map<String, Object?> plaintext,
    required DeviceIdentity identity,
  }) async {
    if (plaintext['id'] != recordId) {
      throw const FormatException(
        'Record plaintext id does not match its signed header.',
      );
    }
    final objectRefs = _plaintextObjectRefs(plaintext);
    final recordSchema = _recordSchemaForPlaintext(plaintext);
    final revisionId = _uuid.v4();
    final opId = _uuid.v4();
    final kdfSalt = randomBytes(32);
    final nonce = randomBytes(24);
    final header = <String, Object?>{
      'wire_version': 1,
      'server_space_id': serverSpaceId,
      'vault_id': vaultId,
      'record_id': recordId,
      'revision_id': revisionId,
      'base_revision_id': baseRevisionId,
      'op_id': opId,
      'device_id': deviceId,
      'device_seq': deviceSequence,
      'key_epoch': keyEpoch,
      'membership_version': membershipVersion,
      'record_schema': recordSchema,
      'operation': operation,
      'crypto_suite': 'atermius-vault-v1',
      'kdf_salt': encodeBase64Url(kdfSalt),
      if (objectRefs.isNotEmpty) 'object_refs': objectRefs,
    };
    final info = utf8.encode(
      canonicalJson(['atermius', 'record', 1, vaultId, recordId, revisionId]),
    );
    final recordKeyBytes = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(vaultKey),
      nonce: kdfSalt,
      info: info,
    );
    final recordKey = sodium.secureCopy(
      Uint8List.fromList(await recordKeyBytes.extractBytes()),
    );
    Uint8List? cleartext;
    try {
      cleartext = Uint8List.fromList(utf8.encode(canonicalJson(plaintext)));
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: cleartext,
        nonce: nonce,
        key: recordKey,
        additionalData: Uint8List.fromList(utf8.encode(canonicalJson(header))),
      );
      final unsigned = <String, Object?>{
        'header': header,
        'nonce': encodeBase64Url(nonce),
        'ciphertext': encodeBase64Url(ciphertext),
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: identity.signing.secretKey,
      );
      return {...unsigned, 'signature': encodeBase64Url(signature)};
    } finally {
      if (cleartext != null) cleartext.fillRange(0, cleartext.length, 0);
      recordKey.dispose();
    }
  }

  /// Checks the public shape and canonical encodings of a server record
  /// envelope without trusting its signer or decrypting its contents.
  ///
  /// Sync uses this before deciding that a signer directory entry is missing:
  /// malformed records must never cause a control-plane refresh retry.
  Map<String, dynamic> validateRecordEnvelope(Map<String, dynamic> envelope) {
    _requireExactFields(
      envelope,
      _vaultRecordEnvelopeFields,
      'Record envelope',
    );
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw const FormatException('Record envelope header is invalid');
    }
    _requireExactFields(
      rawHeader,
      rawHeader.containsKey('object_refs')
          ? {..._vaultRecordHeaderFields, 'object_refs'}
          : _vaultRecordHeaderFields,
      'Record envelope header',
    );
    final header = Map<String, dynamic>.from(rawHeader);
    if (utf8.encode(canonicalJson(header)).length > 64 * 1024) {
      throw const FormatException('Record envelope header is too large');
    }
    for (final name in const [
      'server_space_id',
      'vault_id',
      'record_id',
      'revision_id',
      'op_id',
      'device_id',
    ]) {
      final value = header[name];
      if (value is! String || !_isCanonicalUuid(value)) {
        throw FormatException('Record envelope $name is invalid');
      }
    }
    final baseRevisionId = header['base_revision_id'];
    if (baseRevisionId != null &&
        (baseRevisionId is! String || !_isCanonicalUuid(baseRevisionId))) {
      throw const FormatException(
        'Record envelope base_revision_id is invalid',
      );
    }
    if (header['wire_version'] is! int ||
        header['wire_version'] != 1 ||
        header['record_schema'] is! int ||
        !const {1, 2}.contains(header['record_schema']) ||
        header['crypto_suite'] != 'atermius-vault-v1' ||
        !const {
          'create',
          'update',
          'delete',
          'restore',
        }.contains(header['operation'])) {
      throw const FormatException('Record envelope protocol is invalid');
    }
    _validateRecordCounter(header['device_seq'], 'device_seq', maxDigits: 20);
    _validateRecordCounter(
      header['key_epoch'],
      'key_epoch',
      maxDigits: 19,
      allowZero: false,
    );
    _validateRecordCounter(
      header['membership_version'],
      'membership_version',
      maxDigits: 19,
      allowZero: false,
    );
    if (header.containsKey('object_refs')) {
      _objectRefs(header['object_refs'], source: 'Record header');
    }

    final saltText = header['kdf_salt'];
    final nonceText = envelope['nonce'];
    final ciphertextText = envelope['ciphertext'];
    final signatureText = envelope['signature'];
    if (saltText is! String ||
        saltText.length != 43 ||
        nonceText is! String ||
        nonceText.length != 32 ||
        ciphertextText is! String ||
        ciphertextText.length < 22 ||
        ciphertextText.length > 1_398_102 ||
        signatureText is! String ||
        signatureText.length != 86) {
      throw const FormatException('Record envelope encoding is invalid');
    }
    final salt = decodeBase64Url(saltText);
    final nonce = decodeBase64Url(nonceText);
    final ciphertext = decodeBase64Url(ciphertextText);
    final signature = decodeBase64Url(signatureText);
    if (salt.length != 32 ||
        nonce.length != 24 ||
        ciphertext.length < 16 ||
        ciphertext.length > 1024 * 1024 ||
        signature.length != 64 ||
        encodeBase64Url(salt) != saltText ||
        encodeBase64Url(nonce) != nonceText ||
        encodeBase64Url(ciphertext) != ciphertextText ||
        encodeBase64Url(signature) != signatureText) {
      throw const FormatException('Record envelope encoding is invalid');
    }
    return header;
  }

  /// Verifies a record's detached signature after structural validation.
  /// Keeping this shared with [decryptRecord] ensures sync cannot classify an
  /// invalid known-signer record as a retryable missing-key condition.
  void verifyRecordSignature({
    required Map<String, dynamic> envelope,
    required Uint8List authorPublicKey,
  }) {
    final header = validateRecordEnvelope(envelope);
    _verifyRecordSignature(
      envelope: envelope,
      header: header,
      authorPublicKey: authorPublicKey,
    );
  }

  void _verifyRecordSignature({
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> header,
    required Uint8List authorPublicKey,
  }) {
    if (authorPublicKey.length != 32) {
      throw const FormatException('Record signer key is invalid');
    }
    final signatureMessage = <String, Object?>{
      'header': header,
      'nonce': envelope['nonce'],
      'ciphertext': envelope['ciphertext'],
    };
    final verified = sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(signatureMessage))),
      signature: decodeBase64Url(envelope['signature'] as String),
      publicKey: authorPublicKey,
    );
    if (!verified) throw const FormatException('Record signature is invalid');
  }

  void _validateRecordCounter(
    Object? value,
    String field, {
    required int maxDigits,
    bool allowZero = true,
  }) {
    if (value is! String ||
        value.length > maxDigits ||
        !RegExp(
          allowZero ? r'^(0|[1-9][0-9]*)$' : r'^[1-9][0-9]*$',
        ).hasMatch(value)) {
      throw FormatException('Record envelope $field is invalid');
    }
    final counter = BigInt.parse(value);
    final maximum = BigInt.parse(
      maxDigits == 20 ? '18446744073709551615' : '9223372036854775807',
    );
    if (counter > maximum) {
      throw FormatException(
        'Record envelope $field is outside protocol bounds',
      );
    }
  }

  Future<Map<String, dynamic>> decryptRecord({
    required Uint8List vaultKey,
    required Map<String, dynamic> envelope,
    required Uint8List authorPublicKey,
  }) async {
    final header = validateRecordEnvelope(envelope);
    _verifyRecordSignature(
      envelope: envelope,
      header: header,
      authorPublicKey: authorPublicKey,
    );
    final recordId = header['record_id'] as String;
    final vaultId = header['vault_id'] as String;
    final revisionId = header['revision_id'] as String;
    final kdfSalt = decodeBase64Url(header['kdf_salt'] as String);
    if (kdfSalt.length != 32) {
      throw const FormatException('Invalid record KDF salt');
    }
    final info = utf8.encode(
      canonicalJson(['atermius', 'record', 1, vaultId, recordId, revisionId]),
    );
    final keyData = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(vaultKey),
      nonce: kdfSalt,
      info: info,
    );
    final key = sodium.secureCopy(
      Uint8List.fromList(await keyData.extractBytes()),
    );
    Uint8List? cleartext;
    try {
      cleartext = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: decodeBase64Url(envelope['ciphertext'] as String),
        nonce: decodeBase64Url(envelope['nonce'] as String),
        key: key,
        additionalData: Uint8List.fromList(utf8.encode(canonicalJson(header))),
      );
      final decoded = jsonDecode(utf8.decode(cleartext));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Record plaintext must be a JSON object');
      }
      if (decoded['id'] != recordId) {
        throw const FormatException(
          'Record plaintext id does not match its signed header.',
        );
      }
      final headerObjectRefs = header.containsKey('object_refs')
          ? _objectRefs(header['object_refs'], source: 'Header')
          : const <String>[];
      final plaintextObjectRefs = _plaintextObjectRefs(decoded);
      if (canonicalJson(headerObjectRefs) !=
          canonicalJson(plaintextObjectRefs)) {
        throw const FormatException(
          'Record header object_refs do not match plaintext _manifest.object_refs',
        );
      }
      return decoded;
    } finally {
      if (cleartext != null) cleartext.fillRange(0, cleartext.length, 0);
      key.dispose();
    }
  }
}

/// Record schema 2 is reserved for payloads containing attachment-manifest v2.
/// It is selected automatically when an encrypted Host is rewritten so stale
/// outbox recovery and conflict adoption cannot accidentally downgrade it.
int _recordSchemaForPlaintext(Map<String, Object?> plaintext) {
  final manifest = plaintext['_manifest'];
  if (manifest is! Map) return 1;
  final attachments = manifest['attachments'];
  if (attachments is! List) return 1;
  for (final attachment in attachments) {
    if (attachment is Map &&
        attachment['format'] == 'atermius-host-attachment-v2') {
      return 2;
    }
  }
  return 1;
}

void _requireExactFields(
  Map<dynamic, dynamic> value,
  Set<String> expected,
  String description,
) {
  if (value.keys.any((key) => key is! String) ||
      value.keys.toSet().length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw FormatException('$description fields are invalid');
  }
}

String _localRecordString(Map<String, dynamic> value, String field) {
  final raw = value[field];
  if (raw is! String) {
    throw FormatException('Local record $field is invalid');
  }
  return raw;
}

Uint8List _decodeLocalRecordBase64(
  Object? value, {
  required String field,
  int? expectedBytes,
  int? minimumBytes,
  int? maximumBytes,
}) {
  if (value is! String ||
      value.isEmpty ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value) ||
      value.length % 4 == 1) {
    throw FormatException('Local record $field encoding is invalid');
  }
  if (expectedBytes != null) {
    final expectedEncodedLength = (expectedBytes * 8 + 5) ~/ 6;
    if (value.length != expectedEncodedLength) {
      throw FormatException('Local record $field size is invalid');
    }
  }
  if (maximumBytes != null && value.length > (maximumBytes * 8 + 5) ~/ 6) {
    throw FormatException('Local record $field is too large');
  }
  try {
    final decoded = decodeBase64Url(value);
    if ((expectedBytes != null && decoded.length != expectedBytes) ||
        (minimumBytes != null && decoded.length < minimumBytes) ||
        (maximumBytes != null && decoded.length > maximumBytes) ||
        encodeBase64Url(decoded) != value) {
      throw FormatException('Local record $field size is invalid');
    }
    return decoded;
  } on FormatException {
    rethrow;
  } on Object {
    throw FormatException('Local record $field encoding is invalid');
  }
}

String encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List decodeBase64Url(String input) {
  final normalized = input.replaceAll('-', '+').replaceAll('_', '/');
  return Uint8List.fromList(
    base64.decode(normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=')),
  );
}
