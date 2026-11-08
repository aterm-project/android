import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _refA = '40000000-0000-4000-8000-000000000001';
const _refB = '50000000-0000-4000-8000-000000000002';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late VaultCrypto vaultCrypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    vaultCrypto = VaultCrypto(sodium);
  });

  test('binds encrypted plaintext id to the signed record header', () async {
    final identity = DeviceIdentity.create(sodium);
    final vaultKey = vaultCrypto.randomBytes(32);
    const validPlaintext = <String, Object?>{
      'id': _recordId,
      'type': 'host',
      'name': 'Bound record',
    };
    try {
      final original = await _encryptRecord(
        vaultCrypto: vaultCrypto,
        identity: identity,
        vaultKey: vaultKey,
        plaintext: validPlaintext,
      );
      final mismatchedPlaintext = <String, Object?>{
        ...validPlaintext,
        'id': '44444444-4444-4444-8444-444444444444',
      };
      final signedMismatch = await _rewriteEnvelope(
        sodium: sodium,
        identity: identity,
        vaultKey: vaultKey,
        original: original,
        plaintext: mismatchedPlaintext,
        headerObjectRefs: const <String>[],
      );
      await expectLater(
        vaultCrypto.decryptRecord(
          vaultKey: vaultKey,
          envelope: Map<String, dynamic>.from(signedMismatch),
          authorPublicKey: identity.signing.publicKey,
        ),
        throwsFormatException,
      );
      await expectLater(
        _encryptRecord(
          vaultCrypto: vaultCrypto,
          identity: identity,
          vaultKey: vaultKey,
          plaintext: mismatchedPlaintext,
        ),
        throwsFormatException,
      );
    } finally {
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    }
  });

  test('legacy records without object references remain readable', () async {
    final identity = DeviceIdentity.create(sodium);
    final vaultKey = vaultCrypto.randomBytes(32);
    const plaintext = <String, Object?>{
      'id': _recordId,
      'type': 'host',
      'name': 'Legacy record',
    };

    final envelope = await _encryptRecord(
      vaultCrypto: vaultCrypto,
      identity: identity,
      vaultKey: vaultKey,
      plaintext: plaintext,
    );
    expect((envelope['header'] as Map).containsKey('object_refs'), isFalse);
    expect(
      await vaultCrypto.decryptRecord(
        vaultKey: vaultKey,
        envelope: Map<String, dynamic>.from(envelope),
        authorPublicKey: identity.signing.publicKey,
      ),
      plaintext,
    );

    final emptyManifestPlaintext = <String, Object?>{
      ...plaintext,
      '_manifest': const {'object_refs': []},
    };
    final emptyManifestEnvelope = await _encryptRecord(
      vaultCrypto: vaultCrypto,
      identity: identity,
      vaultKey: vaultKey,
      plaintext: emptyManifestPlaintext,
    );
    expect(
      (emptyManifestEnvelope['header'] as Map).containsKey('object_refs'),
      isFalse,
    );
    expect(
      await vaultCrypto.decryptRecord(
        vaultKey: vaultKey,
        envelope: Map<String, dynamic>.from(emptyManifestEnvelope),
        authorPublicKey: identity.signing.publicKey,
      ),
      emptyManifestPlaintext,
    );

    final explicitEmptyHeader = await _rewriteEnvelope(
      sodium: sodium,
      identity: identity,
      vaultKey: vaultKey,
      original: envelope,
      plaintext: plaintext,
      headerObjectRefs: const [],
    );
    expect(
      await vaultCrypto.decryptRecord(
        vaultKey: vaultKey,
        envelope: Map<String, dynamic>.from(explicitEmptyHeader),
        authorPublicKey: identity.signing.publicKey,
      ),
      plaintext,
    );
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  });

  test(
    'canonical object refs are signed in the header and round-trip',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = vaultCrypto.randomBytes(32);
      const refs = [_refA, _refB];
      const plaintext = <String, Object?>{
        'id': _recordId,
        'type': 'host',
        'name': 'Record with objects',
        '_manifest': {'object_refs': refs, 'extension_version': 1},
      };

      final envelope = await _encryptRecord(
        vaultCrypto: vaultCrypto,
        identity: identity,
        vaultKey: vaultKey,
        plaintext: plaintext,
      );
      expect((envelope['header'] as Map)['object_refs'], refs);
      expect(
        await vaultCrypto.decryptRecord(
          vaultKey: vaultKey,
          envelope: Map<String, dynamic>.from(envelope),
          authorPublicKey: identity.signing.publicKey,
        ),
        plaintext,
      );
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test('accepts exactly 1024 canonical object references', () async {
    final identity = DeviceIdentity.create(sodium);
    final vaultKey = vaultCrypto.randomBytes(32);
    final refs = List<String>.generate(
      1024,
      (index) => '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
    );
    final envelope = await _encryptRecord(
      vaultCrypto: vaultCrypto,
      identity: identity,
      vaultKey: vaultKey,
      plaintext: {
        'id': _recordId,
        'type': 'host',
        '_manifest': {'object_refs': refs},
      },
    );
    expect((envelope['header'] as Map)['object_refs'], hasLength(1024));
    final clear = await vaultCrypto.decryptRecord(
      vaultKey: vaultKey,
      envelope: Map<String, dynamic>.from(envelope),
      authorPublicKey: identity.signing.publicKey,
    );
    expect(
      (clear['_manifest'] as Map<String, dynamic>)['object_refs'],
      hasLength(1024),
    );
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  });

  test(
    'rejects unsorted, duplicate, invalid and oversized reference lists',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = vaultCrypto.randomBytes(32);
      final emptyPlaintext = <String, Object?>{'id': _recordId, 'type': 'host'};
      final legacyEnvelope = await _encryptRecord(
        vaultCrypto: vaultCrypto,
        identity: identity,
        vaultKey: vaultKey,
        plaintext: emptyPlaintext,
      );
      final tooManyRefs = List<String>.generate(
        1025,
        (index) =>
            '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
      );
      final invalidLists = <String, List<String>>{
        'unsorted': const [_refB, _refA],
        'duplicate': const [_refA, _refA],
        'uppercase UUID': const ['A0000000-0000-4000-8000-000000000001'],
        'malformed UUID': const ['object-1'],
        'more than 1024 items': tooManyRefs,
      };

      for (final entry in invalidLists.entries) {
        final plaintext = <String, Object?>{
          ...emptyPlaintext,
          '_manifest': {'object_refs': entry.value},
        };
        await expectLater(
          _encryptRecord(
            vaultCrypto: vaultCrypto,
            identity: identity,
            vaultKey: vaultKey,
            plaintext: plaintext,
          ),
          throwsA(isA<FormatException>()),
          reason: 'Encrypt must reject ${entry.key} references',
        );

        final malformedHeader = await _rewriteEnvelope(
          sodium: sodium,
          identity: identity,
          vaultKey: vaultKey,
          original: legacyEnvelope,
          plaintext: emptyPlaintext,
          headerObjectRefs: entry.value,
        );
        await expectLater(
          vaultCrypto.decryptRecord(
            vaultKey: vaultKey,
            envelope: Map<String, dynamic>.from(malformedHeader),
            authorPublicKey: identity.signing.publicKey,
          ),
          throwsA(isA<FormatException>()),
          reason: 'Decrypt must reject ${entry.key} header references',
        );
      }
      for (final malformedManifest in <Object?>[
        null,
        'not-an-object',
        const {'object_refs': null},
        const {'object_refs': 'not-a-list'},
      ]) {
        await expectLater(
          _encryptRecord(
            vaultCrypto: vaultCrypto,
            identity: identity,
            vaultKey: vaultKey,
            plaintext: {...emptyPlaintext, '_manifest': malformedManifest},
          ),
          throwsA(isA<FormatException>()),
        );
      }

      for (final malformedHeaderRefs in <Object?>[
        null,
        'not-a-list',
        const {'ref': _refA},
      ]) {
        final malformedHeader = await _rewriteEnvelope(
          sodium: sodium,
          identity: identity,
          vaultKey: vaultKey,
          original: legacyEnvelope,
          plaintext: emptyPlaintext,
          headerObjectRefs: malformedHeaderRefs,
        );
        await expectLater(
          vaultCrypto.decryptRecord(
            vaultKey: vaultKey,
            envelope: Map<String, dynamic>.from(malformedHeader),
            authorPublicKey: identity.signing.publicKey,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );

  test(
    'rejects signed header/plaintext mismatch and one-sided omission',
    () async {
      final identity = DeviceIdentity.create(sodium);
      final vaultKey = vaultCrypto.randomBytes(32);
      const referencedPlaintext = <String, Object?>{
        'id': _recordId,
        'type': 'host',
        '_manifest': {
          'object_refs': [_refA, _refB],
        },
      };
      final original = await _encryptRecord(
        vaultCrypto: vaultCrypto,
        identity: identity,
        vaultKey: vaultKey,
        plaintext: referencedPlaintext,
      );
      final mismatches = <Map<String, Object?>>[
        await _rewriteEnvelope(
          sodium: sodium,
          identity: identity,
          vaultKey: vaultKey,
          original: original,
          plaintext: referencedPlaintext,
          headerObjectRefs: null,
          omitHeaderObjectRefs: true,
        ),
        await _rewriteEnvelope(
          sodium: sodium,
          identity: identity,
          vaultKey: vaultKey,
          original: original,
          plaintext: const {'id': _recordId, 'type': 'host'},
          headerObjectRefs: const [_refA, _refB],
        ),
        await _rewriteEnvelope(
          sodium: sodium,
          identity: identity,
          vaultKey: vaultKey,
          original: original,
          plaintext: const {
            'id': _recordId,
            'type': 'host',
            '_manifest': {
              'object_refs': [_refB],
            },
          },
          headerObjectRefs: const [_refA, _refB],
        ),
      ];

      for (final mismatch in mismatches) {
        await expectLater(
          vaultCrypto.decryptRecord(
            vaultKey: vaultKey,
            envelope: Map<String, dynamic>.from(mismatch),
            authorPublicKey: identity.signing.publicKey,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      identity.dispose();
      vaultKey.fillRange(0, vaultKey.length, 0);
    },
  );
}

Future<Map<String, Object?>> _encryptRecord({
  required VaultCrypto vaultCrypto,
  required DeviceIdentity identity,
  required Uint8List vaultKey,
  required Map<String, Object?> plaintext,
}) => vaultCrypto.encryptRecord(
  vaultKey: vaultKey,
  serverSpaceId: _serverSpaceId,
  vaultId: _vaultId,
  recordId: _recordId,
  baseRevisionId: null,
  deviceId: identity.deviceId,
  deviceSequence: '1',
  keyEpoch: '1',
  membershipVersion: '1',
  operation: 'create',
  plaintext: plaintext,
  identity: identity,
);

Future<Map<String, Object?>> _rewriteEnvelope({
  required SodiumSumo sodium,
  required DeviceIdentity identity,
  required Uint8List vaultKey,
  required Map<String, Object?> original,
  required Map<String, Object?> plaintext,
  required Object? headerObjectRefs,
  bool omitHeaderObjectRefs = false,
}) async {
  final header = Map<String, Object?>.from(original['header']! as Map);
  header.remove('object_refs');
  if (!omitHeaderObjectRefs) header['object_refs'] = headerObjectRefs;
  final salt = decodeBase64Url(header['kdf_salt']! as String);
  final info = utf8.encode(
    canonicalJson([
      'atermius',
      'record',
      1,
      header['vault_id'],
      header['record_id'],
      header['revision_id'],
    ]),
  );
  final derivedKey =
      await cryptography.Hkdf(
        hmac: cryptography.Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(
        secretKey: cryptography.SecretKey(vaultKey),
        nonce: salt,
        info: info,
      );
  final keyBytes = Uint8List.fromList(await derivedKey.extractBytes());
  final recordKey = sodium.secureCopy(keyBytes);
  final nonce = sodium.randombytes.buf(24);
  try {
    final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: Uint8List.fromList(utf8.encode(canonicalJson(plaintext))),
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
    recordKey.dispose();
    keyBytes.fillRange(0, keyBytes.length, 0);
    nonce.fillRange(0, nonce.length, 0);
  }
}
