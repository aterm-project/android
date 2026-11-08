import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:sodium/sodium.dart' as sodium_api;
import 'package:sodium/sodium_sumo.dart';

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart'
    show DeviceIdentity, decodeBase64Url, encodeBase64Url;

const _keyboxFormat = 'atermius-terminal-keybox-v1';
const _frameFormat = 'atermius-terminal-frame-v1';
const _controlKeyboxFormat = 'atermius-terminal-control-keybox-v2';
const _inputFrameFormat = 'atermius-terminal-input-frame-v2';
const _frameKeyPurpose = 'terminal-collaboration-frame';
const _inputKeyPurpose = 'terminal-collaboration-input';
const _protocolVersion = 1;
const _inputProtocolVersion = 2;
const _epoch = 1;
const _maxSafeInteger = 9007199254740991;
const _maxOutputBytes = 16 * 1024;
const _maxInputBytes = 8 * 1024;
const _maxColumns = 500;
const _maxRows = 300;

const _keyboxFields = <String>{
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
};

const _frameFields = <String>{
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
};

const _controlKeyboxFields = <String>{
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
};

const _inputFrameFields = <String>{
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
};

/// Context shared by the host and one explicitly approved observer device.
/// Values are public identifiers; [sessionSecret] remains transient and must
/// be cleared by the owning host/observer handle when it closes.
class TerminalCollaborationContext {
  const TerminalCollaborationContext({
    required this.sessionId,
    required this.vaultId,
    required this.membershipVersion,
    required this.hostUserId,
    required this.hostDeviceId,
    required this.observerUserId,
    required this.observerDeviceId,
  });

  final String sessionId;
  final String vaultId;
  final int membershipVersion;
  final String hostUserId;
  final String hostDeviceId;
  final String observerUserId;
  final String observerDeviceId;

  void validate() {
    for (final entry in <String, String>{
      'session_id': sessionId,
      'vault_id': vaultId,
      'host_user_id': hostUserId,
      'host_device_id': hostDeviceId,
      'observer_user_id': observerUserId,
      'observer_device_id': observerDeviceId,
    }.entries) {
      TerminalCollaborationCrypto._requireUuid(entry.value, entry.key);
    }
    if (membershipVersion < 1 || membershipVersion > _maxSafeInteger) {
      throw const FormatException('Terminal collaboration context is invalid.');
    }
  }

  Map<String, Object?> keyboxUnsigned({
    required String expiresAt,
    required String sealedSecret,
  }) => {
    'format': _keyboxFormat,
    'session_id': sessionId,
    'vault_id': vaultId,
    'membership_version': membershipVersion,
    'host_user_id': hostUserId,
    'host_device_id': hostDeviceId,
    'observer_user_id': observerUserId,
    'observer_device_id': observerDeviceId,
    'role': 'observer',
    'epoch': _epoch,
    'expires_at': expiresAt,
    'sealed_secret': sealedSecret,
  };

  Map<String, Object?> frameMetadata({
    required int sequence,
    required String kind,
    required String nonce,
  }) => {
    'format': _frameFormat,
    'session_id': sessionId,
    'vault_id': vaultId,
    'membership_version': membershipVersion,
    'host_user_id': hostUserId,
    'host_device_id': hostDeviceId,
    'recipient_user_id': observerUserId,
    'recipient_device_id': observerDeviceId,
    'role': 'observer',
    'epoch': _epoch,
    'sequence': sequence,
    'kind': kind,
    'nonce': nonce,
  };
}

/// Context for one host-approved controller lease. The v2 control secret is
/// deliberately separate from every observer output secret.
class TerminalControlContext {
  const TerminalControlContext({
    required this.sessionId,
    required this.vaultId,
    required this.membershipVersion,
    required this.hostUserId,
    required this.hostDeviceId,
    required this.controllerUserId,
    required this.controllerDeviceId,
    required this.leaseId,
    required this.controlEpoch,
  });

  final String sessionId;
  final String vaultId;
  final int membershipVersion;
  final String hostUserId;
  final String hostDeviceId;
  final String controllerUserId;
  final String controllerDeviceId;
  final String leaseId;
  final int controlEpoch;

  void validate() {
    for (final entry in <String, String>{
      'session_id': sessionId,
      'vault_id': vaultId,
      'host_user_id': hostUserId,
      'host_device_id': hostDeviceId,
      'controller_user_id': controllerUserId,
      'controller_device_id': controllerDeviceId,
      'lease_id': leaseId,
    }.entries) {
      TerminalCollaborationCrypto._requireUuid(entry.value, entry.key);
    }
    if (membershipVersion < 1 ||
        membershipVersion > _maxSafeInteger ||
        controlEpoch < 1 ||
        controlEpoch > _maxSafeInteger) {
      throw const FormatException('Terminal control context is invalid.');
    }
  }

  Map<String, Object?> keyboxUnsigned({
    required String expiresAt,
    required String sealedSecret,
  }) => {
    'format': _controlKeyboxFormat,
    'session_id': sessionId,
    'vault_id': vaultId,
    'membership_version': membershipVersion,
    'host_user_id': hostUserId,
    'host_device_id': hostDeviceId,
    'controller_user_id': controllerUserId,
    'controller_device_id': controllerDeviceId,
    'lease_id': leaseId,
    'control_epoch': controlEpoch,
    'purpose': 'input',
    'expires_at': expiresAt,
    'sealed_secret': sealedSecret,
  };

  Map<String, Object?> inputMetadata({
    required int sequence,
    required String nonce,
  }) => {
    'format': _inputFrameFormat,
    'session_id': sessionId,
    'vault_id': vaultId,
    'membership_version': membershipVersion,
    'host_user_id': hostUserId,
    'host_device_id': hostDeviceId,
    'controller_user_id': controllerUserId,
    'controller_device_id': controllerDeviceId,
    'lease_id': leaseId,
    'control_epoch': controlEpoch,
    'sequence': sequence,
    'nonce': nonce,
  };
}

class TerminalCollaborationCrypto {
  TerminalCollaborationCrypto(this.sodium)
    : _hkdf = crypto.Hkdf(hmac: crypto.Hmac.sha256(), outputLength: 32);

  final SodiumSumo sodium;
  final crypto.Hkdf _hkdf;

  Uint8List createSessionSecret() => sodium.randombytes.buf(32);

  /// Generates fresh lease-only key material for one v2 controller.
  Uint8List createControlSecret() => sodium.randombytes.buf(32);

  /// Creates a host-signed grant. Its only secret content is a sealed box for
  /// one registered observer device; the caller must not persist this object.
  Map<String, Object?> createKeybox({
    required Uint8List sessionSecret,
    required DeviceIdentity hostIdentity,
    required Uint8List observerEncryptionPublicKey,
    required TerminalCollaborationContext context,
    required DateTime expiresAt,
  }) {
    context.validate();
    if (sessionSecret.length != 32 ||
        observerEncryptionPublicKey.length != 32) {
      throw const FormatException(
        'Terminal collaboration key material is invalid.',
      );
    }
    final canonicalExpiry = _canonicalUtcTimestamp(expiresAt);
    final sealed = sodium.crypto.box.seal(
      message: sessionSecret,
      publicKey: observerEncryptionPublicKey,
    );
    final unsigned = context.keyboxUnsigned(
      expiresAt: canonicalExpiry,
      sealedSecret: encodeBase64Url(sealed),
    );
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      secretKey: hostIdentity.signing.secretKey,
    );
    sealed.fillRange(0, sealed.length, 0);
    return {...unsigned, 'signature': encodeBase64Url(signature)};
  }

  /// Verifies the host signature and exact recipient/session context before
  /// opening the sealed session secret to this device.
  Uint8List openKeybox({
    required Map<String, dynamic> keybox,
    required DeviceIdentity observerIdentity,
    required Uint8List hostSigningPublicKey,
    required TerminalCollaborationContext expectedContext,
    required DateTime now,
  }) {
    expectedContext.validate();
    if (keybox.keys.toSet().length != _keyboxFields.length ||
        !keybox.keys.toSet().containsAll(_keyboxFields) ||
        keybox['format'] != _keyboxFormat ||
        keybox['session_id'] != expectedContext.sessionId ||
        keybox['vault_id'] != expectedContext.vaultId ||
        keybox['membership_version'] != expectedContext.membershipVersion ||
        keybox['host_user_id'] != expectedContext.hostUserId ||
        keybox['host_device_id'] != expectedContext.hostDeviceId ||
        keybox['observer_user_id'] != expectedContext.observerUserId ||
        keybox['observer_device_id'] != expectedContext.observerDeviceId ||
        expectedContext.observerDeviceId != observerIdentity.deviceId ||
        keybox['role'] != 'observer' ||
        keybox['epoch'] != _epoch ||
        keybox['expires_at'] is! String ||
        keybox['sealed_secret'] is! String ||
        keybox['signature'] is! String ||
        hostSigningPublicKey.length != 32) {
      throw const FormatException('Terminal collaboration keybox is invalid.');
    }
    final expiresAtText = keybox['expires_at'] as String;
    final expiresAt = DateTime.tryParse(expiresAtText);
    if (expiresAt == null ||
        !expiresAt.isUtc ||
        _canonicalUtcTimestamp(expiresAt) != expiresAtText ||
        !expiresAt.isAfter(now.toUtc())) {
      throw const FormatException('Terminal collaboration keybox is expired.');
    }
    final signatureText = keybox['signature'] as String;
    final signature = _decodeCanonicalBase64(
      signatureText,
      expectedBytes: 64,
      field: 'signature',
    );
    final sealedText = keybox['sealed_secret'] as String;
    final sealed = _decodeCanonicalBase64(
      sealedText,
      // crypto_box_seal adds crypto_box_SEALBYTES (48) to the 32-byte key.
      expectedBytes: 80,
      field: 'sealed_secret',
    );
    final unsigned = <String, Object?>{
      for (final field in _keyboxFields.where((field) => field != 'signature'))
        field: keybox[field],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: hostSigningPublicKey,
    )) {
      throw const FormatException(
        'Terminal collaboration keybox signature is invalid.',
      );
    }
    Uint8List? opened;
    try {
      opened = sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: observerIdentity.encryption.publicKey,
        secretKey: observerIdentity.encryption.secretKey,
      );
      if (opened.length != 32) {
        throw const FormatException(
          'Terminal collaboration keybox is invalid.',
        );
      }
      return Uint8List.fromList(opened);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Terminal collaboration keybox is invalid.');
    } finally {
      sealed.fillRange(0, sealed.length, 0);
      opened?.fillRange(0, opened.length, 0);
    }
  }

  /// Creates the host-signed, recipient-sealed keybox for one controller
  /// lease. The returned JSON contains only the sealed secret.
  Map<String, Object?> createControlKeybox({
    required Uint8List controlSecret,
    required DeviceIdentity hostIdentity,
    required Uint8List controllerEncryptionPublicKey,
    required TerminalControlContext context,
    required DateTime expiresAt,
  }) {
    context.validate();
    if (hostIdentity.deviceId != context.hostDeviceId ||
        controlSecret.length != 32 ||
        controllerEncryptionPublicKey.length != 32) {
      throw const FormatException('Terminal control key material is invalid.');
    }
    final canonicalExpiry = _canonicalUtcTimestamp(expiresAt);
    final sealed = sodium.crypto.box.seal(
      message: controlSecret,
      publicKey: controllerEncryptionPublicKey,
    );
    try {
      final unsigned = context.keyboxUnsigned(
        expiresAt: canonicalExpiry,
        sealedSecret: encodeBase64Url(sealed),
      );
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: hostIdentity.signing.secretKey,
      );
      return {...unsigned, 'signature': encodeBase64Url(signature)};
    } finally {
      sealed.fillRange(0, sealed.length, 0);
    }
  }

  /// Validates the exact lease context and host signature before opening the
  /// controller secret. Expired or excessively long leases are rejected.
  Uint8List openControlKeybox({
    required Map<String, dynamic> keybox,
    required DeviceIdentity controllerIdentity,
    required Uint8List hostSigningPublicKey,
    required TerminalControlContext expectedContext,
    required DateTime now,
  }) {
    expectedContext.validate();
    if (keybox.keys.toSet().length != _controlKeyboxFields.length ||
        !keybox.keys.toSet().containsAll(_controlKeyboxFields) ||
        keybox['format'] != _controlKeyboxFormat ||
        keybox['session_id'] != expectedContext.sessionId ||
        keybox['vault_id'] != expectedContext.vaultId ||
        keybox['membership_version'] is! int ||
        keybox['membership_version'] != expectedContext.membershipVersion ||
        keybox['host_user_id'] != expectedContext.hostUserId ||
        keybox['host_device_id'] != expectedContext.hostDeviceId ||
        keybox['controller_user_id'] != expectedContext.controllerUserId ||
        keybox['controller_device_id'] != expectedContext.controllerDeviceId ||
        expectedContext.controllerDeviceId != controllerIdentity.deviceId ||
        keybox['lease_id'] != expectedContext.leaseId ||
        keybox['control_epoch'] is! int ||
        keybox['control_epoch'] != expectedContext.controlEpoch ||
        keybox['purpose'] != 'input' ||
        keybox['expires_at'] is! String ||
        keybox['sealed_secret'] is! String ||
        keybox['signature'] is! String ||
        hostSigningPublicKey.length != 32) {
      throw const FormatException('Terminal control keybox is invalid.');
    }
    final expiresAtText = keybox['expires_at'] as String;
    final expiresAt = DateTime.tryParse(expiresAtText);
    final currentTime = now.toUtc();
    if (expiresAt == null ||
        !expiresAt.isUtc ||
        _canonicalUtcTimestamp(expiresAt) != expiresAtText ||
        !expiresAt.isAfter(currentTime) ||
        expiresAt.isAfter(currentTime.add(const Duration(minutes: 5)))) {
      throw const FormatException('Terminal control lease is expired.');
    }
    final signature = _decodeCanonicalBase64(
      keybox['signature'] as String,
      expectedBytes: 64,
      field: 'signature',
    );
    final sealed = _decodeCanonicalBase64(
      keybox['sealed_secret'] as String,
      expectedBytes: 80,
      field: 'sealed_secret',
    );
    final unsigned = <String, Object?>{
      for (final field in _controlKeyboxFields.where(
        (field) => field != 'signature',
      ))
        field: keybox[field],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: hostSigningPublicKey,
    )) {
      sealed.fillRange(0, sealed.length, 0);
      throw const FormatException(
        'Terminal control keybox signature is invalid.',
      );
    }
    Uint8List? opened;
    try {
      opened = sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: controllerIdentity.encryption.publicKey,
        secretKey: controllerIdentity.encryption.secretKey,
      );
      if (opened.length != 32) {
        throw const FormatException('Terminal control keybox is invalid.');
      }
      return Uint8List.fromList(opened);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Terminal control keybox is invalid.');
    } finally {
      sealed.fillRange(0, sealed.length, 0);
      opened?.fillRange(0, opened.length, 0);
    }
  }

  /// Encrypts raw terminal input and signs the complete v2 frame with the
  /// controller device's registered signing key.
  Future<Map<String, Object?>> encryptInputFrame({
    required Uint8List controlSecret,
    required DeviceIdentity controllerIdentity,
    required TerminalControlContext context,
    required int sequence,
    required Uint8List plaintext,
  }) async {
    context.validate();
    if (controllerIdentity.deviceId != context.controllerDeviceId) {
      throw const FormatException('Terminal controller identity is invalid.');
    }
    _validateInput(
      controlSecret: controlSecret,
      sequence: sequence,
      plaintext: plaintext,
    );
    final nonce = sodium.randombytes.buf(24);
    final metadata = context.inputMetadata(
      sequence: sequence,
      nonce: encodeBase64Url(nonce),
    );
    final keyBytes = await _deriveInputKey(controlSecret, context);
    sodium_api.SecureKey? key;
    Uint8List? ciphertext;
    try {
      key = sodium.secureCopy(keyBytes);
      ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson(metadata)),
        ),
      );
      final unsigned = <String, Object?>{
        ...metadata,
        'ciphertext': encodeBase64Url(ciphertext),
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: controllerIdentity.signing.secretKey,
      );
      return {...unsigned, 'signature': encodeBase64Url(signature)};
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      keyBytes.fillRange(0, keyBytes.length, 0);
      ciphertext?.fillRange(0, ciphertext.length, 0);
      key?.dispose();
    }
  }

  /// Validates sender signature, lease context, sequence and AEAD tag before
  /// returning the raw bytes to the host's SSH input sink.
  Future<Uint8List> decryptInputFrame({
    required Uint8List controlSecret,
    required Uint8List controllerSigningPublicKey,
    required TerminalControlContext expectedContext,
    required Map<String, dynamic> frame,
    required int expectedSequence,
  }) async {
    expectedContext.validate();
    if (frame.keys.toSet().length != _inputFrameFields.length ||
        !frame.keys.toSet().containsAll(_inputFrameFields) ||
        frame['format'] != _inputFrameFormat ||
        frame['session_id'] != expectedContext.sessionId ||
        frame['vault_id'] != expectedContext.vaultId ||
        frame['membership_version'] is! int ||
        frame['membership_version'] != expectedContext.membershipVersion ||
        frame['host_user_id'] != expectedContext.hostUserId ||
        frame['host_device_id'] != expectedContext.hostDeviceId ||
        frame['controller_user_id'] != expectedContext.controllerUserId ||
        frame['controller_device_id'] != expectedContext.controllerDeviceId ||
        frame['lease_id'] != expectedContext.leaseId ||
        frame['control_epoch'] is! int ||
        frame['control_epoch'] != expectedContext.controlEpoch ||
        frame['sequence'] is! int ||
        frame['sequence'] != expectedSequence ||
        expectedSequence < 1 ||
        expectedSequence > _maxSafeInteger ||
        controlSecret.length != 32 ||
        controllerSigningPublicKey.length != 32) {
      throw const FormatException('Terminal input frame context is invalid.');
    }
    final nonceText = frame['nonce'];
    final ciphertextText = frame['ciphertext'];
    final signatureText = frame['signature'];
    if (nonceText is! String ||
        ciphertextText is! String ||
        signatureText is! String) {
      throw const FormatException('Terminal input frame is invalid.');
    }
    final nonce = _decodeCanonicalBase64(
      nonceText,
      expectedBytes: 24,
      field: 'nonce',
    );
    final ciphertext = _decodeCanonicalBase64(
      ciphertextText,
      minimumBytes: 17,
      maximumBytes: _maxInputBytes + 16,
      field: 'ciphertext',
    );
    final signature = _decodeCanonicalBase64(
      signatureText,
      expectedBytes: 64,
      field: 'signature',
    );
    final unsigned = <String, Object?>{
      for (final field in _inputFrameFields.where(
        (field) => field != 'signature',
      ))
        field: frame[field],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: controllerSigningPublicKey,
    )) {
      nonce.fillRange(0, nonce.length, 0);
      ciphertext.fillRange(0, ciphertext.length, 0);
      throw const FormatException('Terminal input frame signature is invalid.');
    }
    final metadata = <String, Object?>{
      for (final field in _inputFrameFields.where(
        (field) => field != 'signature' && field != 'ciphertext',
      ))
        field: frame[field],
    };
    final keyBytes = await _deriveInputKey(controlSecret, expectedContext);
    sodium_api.SecureKey? key;
    Uint8List? cleartext;
    try {
      key = sodium.secureCopy(keyBytes);
      cleartext = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson(metadata)),
        ),
      );
      if (cleartext.isEmpty || cleartext.length > _maxInputBytes) {
        throw const FormatException('Terminal input frame is too large.');
      }
      return Uint8List.fromList(cleartext);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Terminal input frame is invalid.');
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      ciphertext.fillRange(0, ciphertext.length, 0);
      keyBytes.fillRange(0, keyBytes.length, 0);
      cleartext?.fillRange(0, cleartext.length, 0);
      key?.dispose();
    }
  }

  Future<Map<String, Object?>> encryptFrame({
    required Uint8List sessionSecret,
    required DeviceIdentity hostIdentity,
    required TerminalCollaborationContext context,
    required int sequence,
    required String kind,
    required Uint8List plaintext,
  }) async {
    context.validate();
    _validateFrameFields(
      sessionSecret: sessionSecret,
      sequence: sequence,
      kind: kind,
      plaintext: plaintext,
    );
    final nonce = sodium.randombytes.buf(24);
    final metadata = context.frameMetadata(
      sequence: sequence,
      kind: kind,
      nonce: encodeBase64Url(nonce),
    );
    final keyBytes = await _deriveFrameKey(sessionSecret, context, kind);
    sodium_api.SecureKey? key;
    Uint8List? ciphertext;
    try {
      key = sodium.secureCopy(keyBytes);
      ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson(metadata)),
        ),
      );
      final unsigned = <String, Object?>{
        ...metadata,
        'ciphertext': encodeBase64Url(ciphertext),
      };
      final signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: hostIdentity.signing.secretKey,
      );
      return {...unsigned, 'signature': encodeBase64Url(signature)};
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      keyBytes.fillRange(0, keyBytes.length, 0);
      ciphertext?.fillRange(0, ciphertext.length, 0);
      key?.dispose();
    }
  }

  Future<Uint8List> decryptFrame({
    required Uint8List sessionSecret,
    required Uint8List hostSigningPublicKey,
    required TerminalCollaborationContext expectedContext,
    required Map<String, dynamic> frame,
    required int expectedSequence,
    required String expectedKind,
  }) async {
    expectedContext.validate();
    if (frame.keys.toSet().length != _frameFields.length ||
        !frame.keys.toSet().containsAll(_frameFields) ||
        frame['format'] != _frameFormat ||
        frame['session_id'] != expectedContext.sessionId ||
        frame['vault_id'] != expectedContext.vaultId ||
        frame['membership_version'] != expectedContext.membershipVersion ||
        frame['host_user_id'] != expectedContext.hostUserId ||
        frame['host_device_id'] != expectedContext.hostDeviceId ||
        frame['recipient_user_id'] != expectedContext.observerUserId ||
        frame['recipient_device_id'] != expectedContext.observerDeviceId ||
        frame['role'] != 'observer' ||
        frame['epoch'] != _epoch ||
        frame['sequence'] != expectedSequence ||
        frame['kind'] != expectedKind ||
        (expectedKind != 'output' && expectedKind != 'resize') ||
        sessionSecret.length != 32 ||
        hostSigningPublicKey.length != 32) {
      throw const FormatException(
        'Terminal collaboration frame context is invalid.',
      );
    }
    final nonceText = frame['nonce'];
    final ciphertextText = frame['ciphertext'];
    final signatureText = frame['signature'];
    if (nonceText is! String ||
        ciphertextText is! String ||
        signatureText is! String) {
      throw const FormatException('Terminal collaboration frame is invalid.');
    }
    final nonce = _decodeCanonicalBase64(
      nonceText,
      expectedBytes: 24,
      field: 'nonce',
    );
    final ciphertext = _decodeCanonicalBase64(
      ciphertextText,
      minimumBytes: 16,
      maximumBytes: _maxOutputBytes + 16,
      field: 'ciphertext',
    );
    final signature = _decodeCanonicalBase64(
      signatureText,
      expectedBytes: 64,
      field: 'signature',
    );
    final unsigned = <String, Object?>{
      for (final field in _frameFields.where((field) => field != 'signature'))
        field: frame[field],
    };
    if (!sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      signature: signature,
      publicKey: hostSigningPublicKey,
    )) {
      throw const FormatException(
        'Terminal collaboration frame signature is invalid.',
      );
    }
    final metadata = <String, Object?>{
      for (final field in _frameFields.where(
        (field) => field != 'signature' && field != 'ciphertext',
      ))
        field: frame[field],
    };
    final keyBytes = await _deriveFrameKey(
      sessionSecret,
      expectedContext,
      expectedKind,
    );
    sodium_api.SecureKey? key;
    Uint8List? cleartext;
    try {
      key = sodium.secureCopy(keyBytes);
      cleartext = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: Uint8List.fromList(
          utf8.encode(canonicalJson(metadata)),
        ),
      );
      if (expectedKind == 'output') {
        if (cleartext.length > _maxOutputBytes) {
          throw const FormatException('Terminal output frame is too large.');
        }
        // Reject invalid UTF-8 before the caller renders any bytes.
        utf8.decode(cleartext, allowMalformed: false);
      } else {
        _validateResizePlaintext(cleartext);
      }
      return Uint8List.fromList(cleartext);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Terminal collaboration frame is invalid.');
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      ciphertext.fillRange(0, ciphertext.length, 0);
      keyBytes.fillRange(0, keyBytes.length, 0);
      cleartext?.fillRange(0, cleartext.length, 0);
      key?.dispose();
    }
  }

  Future<Uint8List> _deriveFrameKey(
    Uint8List sessionSecret,
    TerminalCollaborationContext context,
    String kind,
  ) async {
    final info = <Object?>[
      'atermius',
      _frameKeyPurpose,
      _protocolVersion,
      context.vaultId,
      context.membershipVersion,
      context.sessionId,
      context.hostUserId,
      context.hostDeviceId,
      context.observerUserId,
      context.observerDeviceId,
      'observer',
      _epoch,
      kind,
    ];
    final derived = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(sessionSecret),
      nonce: utf8.encode(context.sessionId),
      info: utf8.encode(canonicalJson(info)),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  Future<Uint8List> _deriveInputKey(
    Uint8List controlSecret,
    TerminalControlContext context,
  ) async {
    final info = <Object?>[
      'atermius',
      _inputKeyPurpose,
      _inputProtocolVersion,
      context.vaultId,
      context.membershipVersion,
      context.sessionId,
      context.hostUserId,
      context.hostDeviceId,
      context.controllerUserId,
      context.controllerDeviceId,
      context.leaseId,
      context.controlEpoch,
    ];
    final derived = await _hkdf.deriveKey(
      secretKey: crypto.SecretKey(controlSecret),
      nonce: utf8.encode(context.sessionId),
      info: utf8.encode(canonicalJson(info)),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  static Uint8List resizePlaintext({required int cols, required int rows}) {
    if (cols < 1 || cols > _maxColumns || rows < 1 || rows > _maxRows) {
      throw ArgumentError('Terminal collaboration resize is out of bounds.');
    }
    return Uint8List.fromList(
      utf8.encode(canonicalJson({'cols': cols, 'rows': rows})),
    );
  }

  static Map<String, int> decodeResize(Uint8List plaintext) =>
      _validateResizePlaintext(plaintext);

  static void _validateFrameFields({
    required Uint8List sessionSecret,
    required int sequence,
    required String kind,
    required Uint8List plaintext,
  }) {
    if (sessionSecret.length != 32 ||
        sequence < 1 ||
        sequence > _maxSafeInteger ||
        (kind != 'output' && kind != 'resize') ||
        plaintext.length > _maxOutputBytes ||
        (kind == 'resize' && _validateResizePlaintext(plaintext).isEmpty)) {
      throw const FormatException('Terminal collaboration frame is invalid.');
    }
  }

  static void _validateInput({
    required Uint8List controlSecret,
    required int sequence,
    required Uint8List plaintext,
  }) {
    if (controlSecret.length != 32 ||
        sequence < 1 ||
        sequence > _maxSafeInteger ||
        plaintext.isEmpty ||
        plaintext.length > _maxInputBytes) {
      throw const FormatException('Terminal input frame is invalid.');
    }
  }

  static Map<String, int> _validateResizePlaintext(Uint8List plaintext) {
    if (plaintext.length > 64) {
      throw const FormatException('Terminal resize frame is invalid.');
    }
    final text = utf8.decode(plaintext, allowMalformed: false);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().length != 2 ||
        !decoded.keys.toSet().containsAll(const {'cols', 'rows'}) ||
        decoded['cols'] is! int ||
        decoded['rows'] is! int ||
        (decoded['cols'] as int) < 1 ||
        (decoded['cols'] as int) > _maxColumns ||
        (decoded['rows'] as int) < 1 ||
        (decoded['rows'] as int) > _maxRows ||
        canonicalJson(decoded) != text) {
      throw const FormatException('Terminal resize frame is invalid.');
    }
    return {'cols': decoded['cols'] as int, 'rows': decoded['rows'] as int};
  }

  static Uint8List _decodeCanonicalBase64(
    String value, {
    int? expectedBytes,
    int? minimumBytes,
    int? maximumBytes,
    required String field,
  }) {
    try {
      final decoded = decodeBase64Url(value);
      if (encodeBase64Url(decoded) != value ||
          (expectedBytes != null && decoded.length != expectedBytes) ||
          (minimumBytes != null && decoded.length < minimumBytes) ||
          (maximumBytes != null && decoded.length > maximumBytes)) {
        throw FormatException('Invalid collaboration $field encoding.');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } on Object {
      throw FormatException('Invalid collaboration $field encoding.');
    }
  }

  static String _canonicalUtcTimestamp(DateTime value) {
    if (!value.isUtc) {
      throw const FormatException(
        'Terminal collaboration timestamp must be UTC.',
      );
    }
    return value.toIso8601String();
  }

  static void _requireUuid(String value, String field) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      throw FormatException('Invalid terminal collaboration $field.');
    }
  }
}
