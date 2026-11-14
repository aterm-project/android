import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/credential_visibility/credential_escrow_crypto.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/credential_visibility_fixtures.dart';

void main() {
  late SodiumSumo sodium;
  late VaultCrypto crypto;
  late EscrowTestInstance instance;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
    instance = EscrowTestInstance(sodium);
  });

  group('escrow key descriptor', () {
    test('verifies against the pinned instance key', () {
      final escrow = sodium.crypto.box.keyPair();
      final descriptor = instance.descriptor(
        keyId: escrowKeyId,
        publicKey: escrow.publicKey,
      );
      final verified = verifyEscrowKeyDescriptor(
        sodium,
        descriptor: descriptor,
        instanceId: escrowInstanceId,
        pinnedInstanceSigningKey: instance.signingPublicKey,
      );
      expect(verified.keyId, escrowKeyId);
      expect(verified.publicKey, escrow.publicKey);
      expect(verified.createdAt, '2026-11-13T10:00:00Z');
      escrow.dispose();
    });

    test('rejects another instance key, format, instance or binding', () {
      final escrow = sodium.crypto.box.keyPair();
      final good = instance.descriptor(
        keyId: escrowKeyId,
        publicKey: escrow.publicKey,
      );
      void rejects(
        Map<String, dynamic> descriptor, {
        String? pinned,
        String instanceId = escrowInstanceId,
      }) {
        expect(
          () => verifyEscrowKeyDescriptor(
            sodium,
            descriptor: descriptor,
            instanceId: instanceId,
            pinnedInstanceSigningKey: pinned ?? instance.signingPublicKey,
          ),
          throwsFormatException,
        );
      }

      // Signed by a different (unpinned) instance key.
      final other = EscrowTestInstance(sodium);
      rejects(
        other.descriptor(keyId: escrowKeyId, publicKey: escrow.publicKey),
      );
      rejects(good, pinned: other.signingPublicKey);
      // Same signature, other instance.
      rejects(good, instanceId: '99999999-9999-4999-8999-999999999999');
      // Wrong format string (validly signed).
      rejects(
        instance.descriptor(
          keyId: escrowKeyId,
          publicKey: escrow.publicKey,
          format: 'atermius-share-gateway-key-v1',
        ),
      );
      // Wire key_id / public_key not bound by the signed payload.
      rejects({...good, 'key_id': '88888888-8888-4888-8888-888888888888'});
      final swapped = sodium.crypto.box.keyPair();
      rejects({...good, 'public_key': encodeBase64Url(swapped.publicKey)});
      // Tampered payload bytes.
      rejects({
        ...good,
        'signed_payload': (good['signed_payload'] as String).replaceFirst(
          '2026',
          '2027',
        ),
      });
      // A validly signed 31-byte key.
      rejects(
        instance.descriptor(
          keyId: escrowKeyId,
          publicKey: Uint8List.fromList(escrow.publicKey.sublist(0, 31)),
        ),
      );
      // No pinned key at all.
      rejects(good, pinned: '');
      escrow.dispose();
      swapped.dispose();
    });
  });

  group('deposits', () {
    late KeyPair escrow;
    late VerifiedEscrowKey key;
    late DeviceIdentity depositor;
    final vaultKey = Uint8List.fromList(List.generate(32, (i) => i + 7));

    setUp(() {
      escrow = sodium.crypto.box.keyPair();
      key = verifyEscrowKeyDescriptor(
        sodium,
        descriptor: instance.descriptor(
          keyId: escrowKeyId,
          publicKey: escrow.publicKey,
        ),
        instanceId: escrowInstanceId,
        pinnedInstanceSigningKey: instance.signingPublicKey,
      );
      depositor = DeviceIdentity.create(sodium);
    });

    tearDown(() {
      escrow.dispose();
      depositor.dispose();
    });

    Map<String, Object?> deposit({int epoch = 3}) => buildEscrowDeposit(
      sodium,
      key: key,
      identity: depositor,
      instanceId: escrowInstanceId,
      vaultId: escrowVaultId,
      keyEpoch: epoch,
      vaultKey: vaultKey,
    );

    Uint8List open(
      Map<String, Object?> body, {
      String vaultId = escrowVaultId,
      int epoch = 3,
      String instanceId = escrowInstanceId,
      String? depositorKey,
      SecureKey? secret,
    }) => openEscrowDeposit(
      sodium,
      key: key,
      secretKey: secret ?? escrow.secretKey,
      instanceId: instanceId,
      vaultId: vaultId,
      keyEpoch: epoch,
      sealed: body['sealed']! as String,
      signature: body['signature']! as String,
      depositorSigningPublicKey: depositorKey ?? depositor.signingPublicKey,
    );

    test('round trip opens the exact vault key', () {
      final body = deposit();
      expect(body.keys.toSet(), {'key_id', 'sealed', 'signature'});
      expect(body['key_id'], escrowKeyId);
      expect(decodeBase64Url(body['sealed']! as String).length, lessThan(1024));
      expect(open(body), vaultKey);
      // The server-side signature check: device key over the JCS payload.
      final sealed = decodeBase64Url(body['sealed']! as String);
      final payload = canonicalJson({
        'format': 'atermius-credential-escrow-deposit-v1',
        'instance_id': escrowInstanceId,
        'key_id': escrowKeyId,
        'vault_id': escrowVaultId,
        'key_epoch': 3,
        'sealed_sha256': encodeBase64Url(sha256Bytes(sealed)),
      });
      expect(
        sodium.crypto.sign.verifyDetached(
          message: Uint8List.fromList(utf8.encode(payload)),
          signature: decodeBase64Url(body['signature']! as String),
          publicKey: depositor.signing.publicKey,
        ),
        isTrue,
      );
    });

    test('tampered sealed, signature, depositor or context is rejected', () {
      final body = deposit();
      final sealed = decodeBase64Url(body['sealed']! as String);
      sealed[sealed.length - 1] ^= 1;
      expect(
        () => open({...body, 'sealed': encodeBase64Url(sealed)}),
        throwsFormatException,
      );
      final signature = decodeBase64Url(body['signature']! as String);
      signature[0] ^= 1;
      expect(
        () => open({...body, 'signature': encodeBase64Url(signature)}),
        throwsFormatException,
      );
      final stranger = DeviceIdentity.create(sodium);
      expect(
        () => open(body, depositorKey: stranger.signingPublicKey),
        throwsFormatException,
      );
      stranger.dispose();
      // Signed context mismatches (another vault, epoch or instance).
      expect(
        () => open(body, vaultId: '77777777-7777-4777-8777-777777777777'),
        throwsFormatException,
      );
      expect(() => open(body, epoch: 4), throwsFormatException);
      expect(
        () => open(body, instanceId: '66666666-6666-4666-8666-666666666666'),
        throwsFormatException,
      );
    });

    test('a deposit re-signed for another context fails the inner check', () {
      // An attacker with a device key re-signs the same seal for vault B; the
      // signed payload verifies but the sealed plaintext names vault A.
      final body = deposit();
      final sealed = decodeBase64Url(body['sealed']! as String);
      const otherVault = '77777777-7777-4777-8777-777777777777';
      final payload = canonicalJson({
        'format': 'atermius-credential-escrow-deposit-v1',
        'instance_id': escrowInstanceId,
        'key_id': escrowKeyId,
        'vault_id': otherVault,
        'key_epoch': 3,
        'sealed_sha256': encodeBase64Url(sha256Bytes(sealed)),
      });
      final resigned = encodeBase64Url(
        sodium.crypto.sign.detached(
          message: Uint8List.fromList(utf8.encode(payload)),
          secretKey: depositor.signing.secretKey,
        ),
      );
      expect(
        () => open({...body, 'signature': resigned}, vaultId: otherVault),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('context'),
          ),
        ),
      );
    });

    test('another escrow secret key cannot open the seal', () {
      final body = deposit();
      final wrong = sodium.crypto.box.keyPair();
      expect(() => open(body, secret: wrong.secretKey), throwsFormatException);
      wrong.dispose();
    });

    test('rejects a short vault key and a zero epoch', () {
      expect(
        () => buildEscrowDeposit(
          sodium,
          key: key,
          identity: depositor,
          instanceId: escrowInstanceId,
          vaultId: escrowVaultId,
          keyEpoch: 1,
          vaultKey: Uint8List(31),
        ),
        throwsFormatException,
      );
      expect(() => deposit(epoch: 0), throwsFormatException);
    });
  });

  group('account wrap', () {
    test('round trip and binding to account, key and account key', () async {
      final escrow = GeneratedEscrowKey.generate(sodium);
      final accountKey = sodium.randombytes.buf(32);
      final wrap = await wrapEscrowSecretKeyForAccount(
        crypto,
        accountKey: accountKey,
        secretKey: escrow.keyPair.secretKey,
        instanceId: escrowInstanceId,
        keyId: escrow.keyId,
        accountId: escrowAdminId,
      );
      expect(wrap.keys.toSet(), {'version', 'nonce', 'ciphertext'});
      expect(wrap['version'], 1);
      expect(decodeBase64Url(wrap['nonce']! as String).length, 24);
      expect(decodeBase64Url(wrap['ciphertext']! as String).length, 48);
      final json = Map<String, dynamic>.from(wrap);
      final opened = await unwrapEscrowSecretKeyForAccount(
        crypto,
        accountKey: accountKey,
        wrap: json,
        instanceId: escrowInstanceId,
        keyId: escrow.keyId,
        accountId: escrowAdminId,
      );
      expect(opened.extractBytes(), escrow.keyPair.secretKey.extractBytes());
      final verified = VerifiedEscrowKey(
        keyId: escrow.keyId,
        publicKey: escrow.keyPair.publicKey,
        createdAt: '2026-11-13T10:00:00Z',
      );
      expect(
        escrowSecretKeyMatches(sodium, key: verified, secretKey: opened),
        isTrue,
      );
      opened.dispose();

      Future<void> rejects({
        Uint8List? key,
        String accountId = escrowAdminId,
        String? keyId,
        String instanceId = escrowInstanceId,
      }) => expectLater(
        unwrapEscrowSecretKeyForAccount(
          crypto,
          accountKey: key ?? accountKey,
          wrap: json,
          instanceId: instanceId,
          keyId: keyId ?? escrow.keyId,
          accountId: accountId,
        ),
        throwsFormatException,
      );
      await rejects(accountId: escrowUserId); // wrong account
      await rejects(key: sodium.randombytes.buf(32)); // wrong account key
      await rejects(keyId: '88888888-8888-4888-8888-888888888888');
      await rejects(instanceId: '66666666-6666-4666-8666-666666666666');
      expect(
        () => validateEscrowAccountWrap({...json, 'extra': 1}),
        throwsFormatException,
      );
      expect(
        () => validateEscrowAccountWrap({...json, 'version': 2}),
        throwsFormatException,
      );
      final other = sodium.crypto.box.keyPair();
      final otherOpened = sodium.secureCopy(other.secretKey.extractBytes());
      expect(
        escrowSecretKeyMatches(sodium, key: verified, secretKey: otherOpened),
        isFalse,
      );
      otherOpened.dispose();
      other.dispose();
      escrow.dispose();
    });
  });

  group('recovery code', () {
    test('generates 32 Base32 characters shown as 8 groups of 4', () {
      final code = EscrowRecoveryCode.generate(sodium);
      expect(code.normalized, matches(RegExp(r'^[A-Z2-7]{32}$')));
      expect(code.display, matches(RegExp(r'^([A-Z2-7]{4}-){7}[A-Z2-7]{4}$')));
      expect(
        EscrowRecoveryCode.parse(code.display).normalized,
        code.normalized,
      );
      expect(
        EscrowRecoveryCode.generate(sodium).normalized,
        isNot(code.normalized),
      );
    });

    test('normalizes case, dashes and whitespace and rejects junk', () {
      const display = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567';
      final parsed = EscrowRecoveryCode.parse(
        ' abcd efgh-ijkl\tmnop-QRST uvwx-yz23-4567\n',
      );
      expect(parsed.normalized, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567');
      expect(parsed.display, display);
      for (final bad in [
        '',
        'ABCD-EFGH',
        'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-456', // 31
        'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-45678', // 33
        'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4561', // '1' not Base32
        'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-456=',
      ]) {
        expect(() => EscrowRecoveryCode.parse(bad), throwsFormatException);
      }
    });

    test('recovery wrap round trip with exact KDF bounds', () {
      final escrow = GeneratedEscrowKey.generate(sodium);
      final code = EscrowRecoveryCode.generate(sodium);
      final wrap = Map<String, dynamic>.from(
        wrapEscrowSecretKeyForRecovery(
          crypto,
          code: code,
          secretKey: escrow.keyPair.secretKey,
          instanceId: escrowInstanceId,
          keyId: escrow.keyId,
        ),
      );
      expect(wrap['kdf'], {
        'id': 'argon2id13',
        'salt': isA<String>(),
        'mem_kib': 65536,
        'iterations': 3,
        'parallelism': 1,
      });
      // Typed with dashes/lower case by the admin.
      final opened = unwrapEscrowSecretKeyWithRecoveryCode(
        crypto,
        code: EscrowRecoveryCode.parse(code.display.toLowerCase()),
        wrap: wrap,
        instanceId: escrowInstanceId,
        keyId: escrow.keyId,
      );
      expect(opened.extractBytes(), escrow.keyPair.secretKey.extractBytes());
      opened.dispose();

      final wrongCode = EscrowRecoveryCode.generate(sodium);
      expect(
        () => unwrapEscrowSecretKeyWithRecoveryCode(
          crypto,
          code: wrongCode,
          wrap: wrap,
          instanceId: escrowInstanceId,
          keyId: escrow.keyId,
        ),
        throwsFormatException,
      );
      expect(
        () => unwrapEscrowSecretKeyWithRecoveryCode(
          crypto,
          code: code,
          wrap: wrap,
          instanceId: '66666666-6666-4666-8666-666666666666',
          keyId: escrow.keyId,
        ),
        throwsFormatException,
      );
      for (final kdf in [
        {...(wrap['kdf'] as Map), 'mem_kib': 1024},
        {...(wrap['kdf'] as Map), 'iterations': 2},
        {...(wrap['kdf'] as Map), 'parallelism': 2},
        {...(wrap['kdf'] as Map), 'id': 'argon2i13'},
      ]) {
        expect(
          () => unwrapEscrowSecretKeyWithRecoveryCode(
            crypto,
            code: code,
            wrap: {...wrap, 'kdf': kdf},
            instanceId: escrowInstanceId,
            keyId: escrow.keyId,
          ),
          throwsFormatException,
        );
      }
      escrow.dispose();
    });
  });

  test('creator signature verifies with the admin device key', () {
    final identity = DeviceIdentity.create(sodium);
    final escrow = GeneratedEscrowKey.generate(sodium);
    final signature = signEscrowKeyCreation(
      sodium,
      identity: identity,
      instanceId: escrowInstanceId,
      accountId: escrowAdminId,
      keyId: escrow.keyId,
      publicKey: escrow.publicKeyText,
    );
    final payload = canonicalJson({
      'format': 'atermius-credential-escrow-key-creation-v1',
      'instance_id': escrowInstanceId,
      'key_id': escrow.keyId,
      'public_key': escrow.publicKeyText,
      'account_id': escrowAdminId,
      'device_id': identity.deviceId,
    });
    expect(
      sodium.crypto.sign.verifyDetached(
        message: Uint8List.fromList(utf8.encode(payload)),
        signature: decodeBase64Url(signature),
        publicKey: identity.signing.publicKey,
      ),
      isTrue,
    );
    expect(isCanonicalEscrowUuid(escrow.keyId), isTrue);
    identity.dispose();
    escrow.dispose();
  });
}
