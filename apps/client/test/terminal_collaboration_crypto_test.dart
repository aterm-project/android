import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/terminal/terminal_collaboration_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;
  late TerminalCollaborationCrypto collaboration;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    collaboration = TerminalCollaborationCrypto(sodium);
  });

  test('signed keybox seals the session secret to one observer device', () {
    final host = DeviceIdentity.create(sodium);
    final observer = DeviceIdentity.create(sodium);
    final secret = collaboration.createSessionSecret();
    final now = DateTime.now().toUtc();
    final context = _context(
      sessionId: '11111111-1111-4111-8111-111111111111',
      observerDeviceId: observer.deviceId,
    );
    Uint8List? opened;
    try {
      final keybox = collaboration.createKeybox(
        sessionSecret: secret,
        hostIdentity: host,
        observerEncryptionPublicKey: observer.encryption.publicKey,
        context: context,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      expect(keybox.keys.toSet(), {
        'format',
        'session_id',
        'vault_id',
        'membership_version',
        'host_user_id',
        'host_device_id',
        'observer_user_id',
        'observer_device_id',
        'role',
        'epoch',
        'expires_at',
        'sealed_secret',
        'signature',
      });
      expect(
        decodeBase64Url(keybox['sealed_secret']! as String),
        hasLength(80),
      );
      opened = collaboration.openKeybox(
        keybox: Map<String, dynamic>.from(keybox),
        observerIdentity: observer,
        hostSigningPublicKey: host.signing.publicKey,
        expectedContext: context,
        now: now,
      );
      expect(opened, secret);

      final wrongObserver = _context(
        sessionId: context.sessionId,
        observerDeviceId: '22222222-2222-4222-8222-222222222222',
      );
      expect(
        () => collaboration.openKeybox(
          keybox: Map<String, dynamic>.from(keybox),
          observerIdentity: observer,
          hostSigningPublicKey: host.signing.publicKey,
          expectedContext: wrongObserver,
          now: now,
        ),
        throwsFormatException,
      );

      final tampered = Map<String, dynamic>.from(keybox)
        ..['vault_id'] = '33333333-3333-4333-8333-333333333333';
      expect(
        () => collaboration.openKeybox(
          keybox: tampered,
          observerIdentity: observer,
          hostSigningPublicKey: host.signing.publicKey,
          expectedContext: context,
          now: now,
        ),
        throwsFormatException,
      );
      expect(
        () => collaboration.openKeybox(
          keybox: Map<String, dynamic>.from(keybox),
          observerIdentity: observer,
          hostSigningPublicKey: DeviceIdentity.create(sodium).signing.publicKey,
          expectedContext: context,
          now: now,
        ),
        throwsFormatException,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
      opened?.fillRange(0, opened.length, 0);
      host.dispose();
      observer.dispose();
    }
  });

  test('recipient and kind bound frames verify before decrypting', () async {
    final host = DeviceIdentity.create(sodium);
    final observer = DeviceIdentity.create(sodium);
    final secret = collaboration.createSessionSecret();
    final context = _context(
      sessionId: '44444444-4444-4444-8444-444444444444',
      observerDeviceId: observer.deviceId,
    );
    final output = Uint8List.fromList(utf8.encode('hello observer\r\n'));
    Uint8List? opened;
    try {
      final frame = await collaboration.encryptFrame(
        sessionSecret: secret,
        hostIdentity: host,
        context: context,
        sequence: 7,
        kind: 'output',
        plaintext: output,
      );
      expect(frame.keys.toSet(), {
        'format',
        'session_id',
        'vault_id',
        'membership_version',
        'host_user_id',
        'host_device_id',
        'recipient_user_id',
        'recipient_device_id',
        'role',
        'epoch',
        'sequence',
        'kind',
        'nonce',
        'ciphertext',
        'signature',
      });
      expect(decodeBase64Url(frame['nonce']! as String), hasLength(24));
      expect(
        utf8.decode(
          await collaboration.decryptFrame(
            sessionSecret: secret,
            hostSigningPublicKey: host.signing.publicKey,
            expectedContext: context,
            frame: Map<String, dynamic>.from(frame),
            expectedSequence: 7,
            expectedKind: 'output',
          ),
        ),
        'hello observer\r\n',
      );

      final changedRecipient = Map<String, dynamic>.from(frame)
        ..['recipient_device_id'] = '55555555-5555-4555-8555-555555555555';
      await expectLater(
        collaboration.decryptFrame(
          sessionSecret: secret,
          hostSigningPublicKey: host.signing.publicKey,
          expectedContext: context,
          frame: changedRecipient,
          expectedSequence: 7,
          expectedKind: 'output',
        ),
        throwsFormatException,
      );

      final alteredCiphertext = Map<String, dynamic>.from(frame)
        ..['ciphertext'] = encodeBase64Url(Uint8List(32));
      await expectLater(
        collaboration.decryptFrame(
          sessionSecret: secret,
          hostSigningPublicKey: host.signing.publicKey,
          expectedContext: context,
          frame: alteredCiphertext,
          expectedSequence: 7,
          expectedKind: 'output',
        ),
        throwsFormatException,
      );

      final resizeBytes = TerminalCollaborationCrypto.resizePlaintext(
        cols: 160,
        rows: 48,
      );
      final resizeFrame = await collaboration.encryptFrame(
        sessionSecret: secret,
        hostIdentity: host,
        context: context,
        sequence: 1,
        kind: 'resize',
        plaintext: resizeBytes,
      );
      opened = await collaboration.decryptFrame(
        sessionSecret: secret,
        hostSigningPublicKey: host.signing.publicKey,
        expectedContext: context,
        frame: Map<String, dynamic>.from(resizeFrame),
        expectedSequence: 1,
        expectedKind: 'resize',
      );
      expect(TerminalCollaborationCrypto.decodeResize(opened), {
        'cols': 160,
        'rows': 48,
      });
      expect(
        () => TerminalCollaborationCrypto.resizePlaintext(cols: 501, rows: 1),
        throwsArgumentError,
      );
      expect(
        () => TerminalCollaborationCrypto.resizePlaintext(cols: 1, rows: 301),
        throwsArgumentError,
      );
      resizeBytes.fillRange(0, resizeBytes.length, 0);
    } finally {
      secret.fillRange(0, secret.length, 0);
      output.fillRange(0, output.length, 0);
      opened?.fillRange(0, opened.length, 0);
      host.dispose();
      observer.dispose();
    }
  });

  test(
    'v2 lease keybox and input frames are independently bound and signed',
    () async {
      final hostBase = DeviceIdentity.create(sodium);
      final controller = DeviceIdentity.create(sodium);
      final host = DeviceIdentity(
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        signing: hostBase.signing,
        encryption: hostBase.encryption,
      );
      final observerSecret = collaboration.createSessionSecret();
      final controlSecret = collaboration.createControlSecret();
      final context = TerminalControlContext(
        sessionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        vaultId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        membershipVersion: 9,
        hostUserId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        hostDeviceId: host.deviceId,
        controllerUserId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        controllerDeviceId: controller.deviceId,
        leaseId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        controlEpoch: 3,
      );
      final now = DateTime.now().toUtc();
      final expiresAt = now.add(const Duration(minutes: 3));
      Uint8List? opened;
      Uint8List? cleartext;
      final input = Uint8List.fromList([0x03, 0x7f, 0x0d, 0x0a, 0xc3, 0xa9]);
      try {
        expect(controlSecret, isNot(observerSecret));
        final keybox = collaboration.createControlKeybox(
          controlSecret: controlSecret,
          hostIdentity: host,
          controllerEncryptionPublicKey: controller.encryption.publicKey,
          context: context,
          expiresAt: expiresAt,
        );
        expect(keybox.keys.toSet(), {
          'format',
          'session_id',
          'vault_id',
          'membership_version',
          'host_user_id',
          'host_device_id',
          'controller_user_id',
          'controller_device_id',
          'lease_id',
          'control_epoch',
          'purpose',
          'expires_at',
          'sealed_secret',
          'signature',
        });
        expect(keybox['format'], 'atermius-terminal-control-keybox-v2');
        opened = collaboration.openControlKeybox(
          keybox: Map<String, dynamic>.from(keybox),
          controllerIdentity: controller,
          hostSigningPublicKey: host.signing.publicKey,
          expectedContext: context,
          now: now,
        );
        expect(opened, controlSecret);

        final wrongLease = TerminalControlContext(
          sessionId: context.sessionId,
          vaultId: context.vaultId,
          membershipVersion: context.membershipVersion,
          hostUserId: context.hostUserId,
          hostDeviceId: context.hostDeviceId,
          controllerUserId: context.controllerUserId,
          controllerDeviceId: context.controllerDeviceId,
          leaseId: '12121212-1212-4212-8212-121212121212',
          controlEpoch: context.controlEpoch,
        );
        expect(
          () => collaboration.openControlKeybox(
            keybox: Map<String, dynamic>.from(keybox),
            controllerIdentity: controller,
            hostSigningPublicKey: host.signing.publicKey,
            expectedContext: wrongLease,
            now: now,
          ),
          throwsFormatException,
        );
        final changedEpoch = Map<String, dynamic>.from(keybox)
          ..['control_epoch'] = 4;
        expect(
          () => collaboration.openControlKeybox(
            keybox: changedEpoch,
            controllerIdentity: controller,
            hostSigningPublicKey: host.signing.publicKey,
            expectedContext: context,
            now: now,
          ),
          throwsFormatException,
        );

        final frame = await collaboration.encryptInputFrame(
          controlSecret: controlSecret,
          controllerIdentity: controller,
          context: context,
          sequence: 1,
          plaintext: input,
        );
        expect(frame.keys.toSet(), {
          'format',
          'session_id',
          'vault_id',
          'membership_version',
          'host_user_id',
          'host_device_id',
          'controller_user_id',
          'controller_device_id',
          'lease_id',
          'control_epoch',
          'sequence',
          'nonce',
          'ciphertext',
          'signature',
        });
        expect(frame['format'], 'atermius-terminal-input-frame-v2');
        expect(decodeBase64Url(frame['nonce']! as String), hasLength(24));
        cleartext = await collaboration.decryptInputFrame(
          controlSecret: controlSecret,
          controllerSigningPublicKey: controller.signing.publicKey,
          expectedContext: context,
          frame: Map<String, dynamic>.from(frame),
          expectedSequence: 1,
        );
        expect(cleartext, input);

        final alteredLease = Map<String, dynamic>.from(frame)
          ..['lease_id'] = wrongLease.leaseId;
        await expectLater(
          collaboration.decryptInputFrame(
            controlSecret: controlSecret,
            controllerSigningPublicKey: controller.signing.publicKey,
            expectedContext: context,
            frame: alteredLease,
            expectedSequence: 1,
          ),
          throwsFormatException,
        );
        final alteredCiphertext = Map<String, dynamic>.from(frame)
          ..['ciphertext'] = encodeBase64Url(Uint8List(32));
        await expectLater(
          collaboration.decryptInputFrame(
            controlSecret: controlSecret,
            controllerSigningPublicKey: controller.signing.publicKey,
            expectedContext: context,
            frame: alteredCiphertext,
            expectedSequence: 1,
          ),
          throwsFormatException,
        );
        await expectLater(
          collaboration.encryptInputFrame(
            controlSecret: controlSecret,
            controllerIdentity: controller,
            context: context,
            sequence: 1,
            plaintext: Uint8List(8193),
          ),
          throwsFormatException,
        );
        await expectLater(
          collaboration.encryptInputFrame(
            controlSecret: controlSecret,
            controllerIdentity: controller,
            context: context,
            sequence: 1,
            plaintext: Uint8List(0),
          ),
          throwsFormatException,
        );
      } finally {
        observerSecret.fillRange(0, observerSecret.length, 0);
        controlSecret.fillRange(0, controlSecret.length, 0);
        input.fillRange(0, input.length, 0);
        opened?.fillRange(0, opened.length, 0);
        cleartext?.fillRange(0, cleartext.length, 0);
        hostBase.dispose();
        controller.dispose();
      }
    },
  );
}

TerminalCollaborationContext _context({
  required String sessionId,
  required String observerDeviceId,
}) => TerminalCollaborationContext(
  sessionId: sessionId,
  vaultId: '66666666-6666-4666-8666-666666666666',
  membershipVersion: 3,
  hostUserId: '77777777-7777-4777-8777-777777777777',
  hostDeviceId: '88888888-8888-4888-8888-888888888888',
  observerUserId: '99999999-9999-4999-8999-999999999999',
  observerDeviceId: observerDeviceId,
);
