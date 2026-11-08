import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';

/// Upper bound for one pasted/imported OpenSSH certificate line. Real user
/// certificates are a few KiB (RSA-4096 + many principals); anything larger is
/// rejected before base64 decoding.
const int openSshCertificateMaxTextBytes = 32768;

/// Why an OpenSSH certificate cannot be used. Values are stable identifiers;
/// the UI maps them to localized text. No certificate material is carried.
enum OpenSshCertificateProblem {
  /// Not a single `<type> <base64> [comment]` OpenSSH public line.
  malformed,

  /// A certificate algorithm this client cannot sign for (DSA, FIDO `sk-*`).
  unsupportedAlgorithm,

  /// A host certificate (type 2) was supplied where a user certificate is
  /// required.
  notUserCertificate,

  /// The certified public key is not the public half of the private key.
  keyMismatch,

  /// The private key could not be decoded (wrong passphrase / format).
  privateKeyUnreadable,
}

class OpenSshCertificateException implements Exception {
  const OpenSshCertificateException(this.problem);
  final OpenSshCertificateProblem problem;

  @override
  String toString() => 'OpenSshCertificateException(${problem.name})';
}

/// Parsed, structurally validated OpenSSH certificate (PROTOCOL.certkeys).
///
/// Only public data is held. The CA signature is not verified locally: the
/// SSH server is the authority that trusts (or not) the CA. The client checks
/// structure, certificate type, key binding and validity window so the UI
/// never reports a certificate as usable when it is not.
final class OpenSshCertificate {
  const OpenSshCertificate._({
    required this.certificateType,
    required this.blob,
    required this.publicKeyBlob,
    required this.serial,
    required this.isUserCertificate,
    required this.keyId,
    required this.principals,
    required this.validAfter,
    required this.validBefore,
    required this.criticalOptions,
    required this.extensions,
    required this.caFingerprint,
    required this.caKeyType,
    required this.comment,
  });

  /// e.g. `ssh-ed25519-cert-v01@openssh.com`.
  final String certificateType;

  /// The full certificate wire blob (the "public key" sent during auth).
  final Uint8List blob;

  /// The plain certified public key blob (`ssh-ed25519 …`).
  final Uint8List publicKeyBlob;
  final BigInt serial;
  final bool isUserCertificate;
  final String keyId;

  /// Empty means "valid for any principal" per OpenSSH semantics.
  final List<String> principals;

  /// `null` means unbounded (0 / max uint64).
  final DateTime? validAfter;
  final DateTime? validBefore;
  final List<String> criticalOptions;
  final List<String> extensions;
  final String caFingerprint;
  final String caKeyType;
  final String comment;

  /// The plain key algorithm the certificate binds (`ssh-ed25519`, ...).
  String get keyType => certificateType.substring(
    0,
    certificateType.length - _certSuffix.length,
  );

  /// SHA256 fingerprint of the certified public key (matches
  /// `ssh-keygen -lf key.pub`).
  String get keyFingerprint => openSshFingerprint(publicKeyBlob);

  bool isExpiredAt(DateTime now) =>
      validBefore != null && !now.toUtc().isBefore(validBefore!);

  bool isNotYetValidAt(DateTime now) =>
      validAfter != null && now.toUtc().isBefore(validAfter!);

  bool isValidAt(DateTime now) =>
      !isExpiredAt(now) && !isNotYetValidAt(now);

  /// Canonical single-line form used for storage (comment preserved, all
  /// surrounding whitespace removed).
  String get canonicalLine =>
      '$certificateType ${base64.encode(blob)}${comment.isEmpty ? '' : ' $comment'}';

  static const _certSuffix = '-cert-v01@openssh.com';
  static const supportedTypes = {
    'ssh-ed25519-cert-v01@openssh.com',
    'ssh-rsa-cert-v01@openssh.com',
    'ecdsa-sha2-nistp256-cert-v01@openssh.com',
    'ecdsa-sha2-nistp384-cert-v01@openssh.com',
    'ecdsa-sha2-nistp521-cert-v01@openssh.com',
  };

  /// Heuristic used by the editor to tell a pasted certificate from a plain
  /// public key or a private key without decoding anything.
  static bool looksLikeCertificate(String text) {
    final first = text.trimLeft().split(RegExp(r'\s')).first;
    return first.endsWith(_certSuffix);
  }

  /// Parses one OpenSSH certificate line (`*-cert.pub` file contents).
  ///
  /// Throws [OpenSshCertificateException]; never echoes input in errors.
  static OpenSshCertificate parse(String text) {
    if (utf8.encode(text).length > openSshCertificateMaxTextBytes) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    if (lines.length != 1) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    final parts = lines.single.split(RegExp(r'[ \t]+'));
    if (parts.length < 2) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    final declaredType = parts[0];
    if (!declaredType.endsWith(_certSuffix)) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    final comment = parts.skip(2).join(' ');
    if (comment.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    final Uint8List blob;
    try {
      blob = base64.decode(parts[1]);
    } on FormatException {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
    return _decode(blob, declaredType, comment);
  }

  static OpenSshCertificate _decode(
    Uint8List blob,
    String declaredType,
    String comment,
  ) {
    try {
      final reader = _WireReader(blob);
      final type = reader.utf8String();
      if (type != declaredType) {
        throw const OpenSshCertificateException(
          OpenSshCertificateProblem.malformed,
        );
      }
      if (!supportedTypes.contains(type)) {
        throw const OpenSshCertificateException(
          OpenSshCertificateProblem.unsupportedAlgorithm,
        );
      }
      reader.bytes(); // nonce
      final keyType = type.substring(0, type.length - _certSuffix.length);
      final publicKey = _WireWriter()..string(utf8.encode(keyType));
      if (keyType == 'ssh-ed25519') {
        final pk = reader.bytes();
        if (pk.length != 32) {
          throw const OpenSshCertificateException(
            OpenSshCertificateProblem.malformed,
          );
        }
        publicKey.string(pk);
      } else if (keyType == 'ssh-rsa') {
        publicKey
          ..string(reader.bytes()) // e (mpint, raw)
          ..string(reader.bytes()); // n (mpint, raw)
      } else {
        final curve = reader.bytes();
        if (keyType != 'ecdsa-sha2-${ascii.decode(curve)}') {
          throw const OpenSshCertificateException(
            OpenSshCertificateProblem.malformed,
          );
        }
        publicKey
          ..string(curve)
          ..string(reader.bytes());
      }
      final serial = reader.uint64();
      final certType = reader.uint32();
      if (certType != 1 && certType != 2) {
        throw const OpenSshCertificateException(
          OpenSshCertificateProblem.malformed,
        );
      }
      final keyId = reader.utf8String();
      final principals = _WireReader(reader.bytes()).utf8List();
      final validAfter = _time(reader.uint64(), lower: true);
      final validBefore = _time(reader.uint64(), lower: false);
      final critical = _WireReader(reader.bytes()).optionNames();
      final extensions = _WireReader(reader.bytes()).optionNames();
      reader.bytes(); // reserved
      final signatureKey = reader.bytes();
      final caType = _WireReader(signatureKey).utf8String();
      reader.bytes(); // signature
      if (!reader.done) {
        throw const OpenSshCertificateException(
          OpenSshCertificateProblem.malformed,
        );
      }
      return OpenSshCertificate._(
        certificateType: type,
        blob: Uint8List.fromList(blob),
        publicKeyBlob: publicKey.bytes(),
        serial: serial,
        isUserCertificate: certType == 1,
        keyId: keyId,
        principals: List.unmodifiable(principals),
        validAfter: validAfter,
        validBefore: validBefore,
        criticalOptions: List.unmodifiable(critical),
        extensions: List.unmodifiable(extensions),
        caFingerprint: openSshFingerprint(signatureKey),
        caKeyType: caType,
        comment: comment,
      );
    } on OpenSshCertificateException {
      rethrow;
    } on Object {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.malformed,
      );
    }
  }

  static DateTime? _time(BigInt value, {required bool lower}) {
    if (lower && value == BigInt.zero) return null;
    // OpenSSH uses 0xffffffffffffffff for "forever". Anything past year 9999
    // is treated the same way to stay within DateTime's range.
    if (value > BigInt.from(253402300799)) return null;
    final seconds = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  /// Validates that this is a user certificate for [keyPair].
  void requireUserCertificateFor(SSHKeyPair keyPair) {
    if (!isUserCertificate) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.notUserCertificate,
      );
    }
    if (!_sameBytes(keyPair.toPublicKey().encode(), publicKeyBlob)) {
      throw const OpenSshCertificateException(
        OpenSshCertificateProblem.keyMismatch,
      );
    }
  }
}

/// Validates [certificateText] against the PEM [privateKey] and returns the
/// parsed certificate. Used by credential editors before saving so a mismatched
/// or host certificate can never be stored as a usable login.
OpenSshCertificate validateUserCertificateForPrivateKey({
  required String certificateText,
  required String privateKey,
  String? passphrase,
}) {
  final certificate = OpenSshCertificate.parse(certificateText);
  final pairs = _decodePairs(privateKey, passphrase);
  if (!certificate.isUserCertificate) {
    throw const OpenSshCertificateException(
      OpenSshCertificateProblem.notUserCertificate,
    );
  }
  if (!pairs.any((pair) => _matches(pair, certificate))) {
    throw const OpenSshCertificateException(
      OpenSshCertificateProblem.keyMismatch,
    );
  }
  return certificate;
}

List<SSHKeyPair> _decodePairs(String privateKey, String? passphrase) {
  try {
    return SSHKeyPair.fromPem(
      privateKey,
      passphrase?.isEmpty == true ? null : passphrase,
    );
  } on Object {
    throw const OpenSshCertificateException(
      OpenSshCertificateProblem.privateKeyUnreadable,
    );
  }
}

bool _matches(SSHKeyPair pair, OpenSshCertificate certificate) =>
    _sameBytes(pair.toPublicKey().encode(), certificate.publicKeyBlob);

/// Builds the publickey identities for a key credential. When a matching user
/// certificate is attached it is offered first (as OpenSSH does), followed by
/// the plain key so servers that only list the key in authorized_keys still
/// work. A mismatched certificate is never offered.
List<SSHIdentity> sshIdentitiesFor(
  List<SSHKeyPair> pairs, {
  String? certificateText,
}) {
  if (certificateText == null || certificateText.trim().isEmpty) {
    return List<SSHIdentity>.of(pairs);
  }
  final certificate = OpenSshCertificate.parse(certificateText);
  if (!certificate.isUserCertificate) {
    throw const OpenSshCertificateException(
      OpenSshCertificateProblem.notUserCertificate,
    );
  }
  final matching = pairs.where((pair) => _matches(pair, certificate));
  if (matching.isEmpty) {
    throw const OpenSshCertificateException(
      OpenSshCertificateProblem.keyMismatch,
    );
  }
  return <SSHIdentity>[
    OpenSshCertificateIdentity(matching.first, certificate),
    ...pairs,
  ];
}

/// A `publickey` identity that presents an OpenSSH certificate and signs
/// with the certified private key.
final class OpenSshCertificateIdentity implements SSHIdentity {
  OpenSshCertificateIdentity(this.keyPair, this.certificate);

  final SSHKeyPair keyPair;
  final OpenSshCertificate certificate;

  /// The auth algorithm: RSA certificates use the SHA-2 signature names
  /// (`rsa-sha2-256-cert-v01@openssh.com`, RFC 8332 / OpenSSH 7.8+);
  /// others reuse the certificate type.
  @override
  String get type => certificate.keyType == 'ssh-rsa'
      ? '${keyPair.type}-cert-v01@openssh.com'
      : certificate.certificateType;

  @override
  String? get comment => certificate.keyId;

  @override
  bool get shouldProbe => false;

  @override
  SSHHostKey toPublicKey() => _CertificateBlob(certificate.blob);

  @override
  FutureOr<SSHSignature> sign(Uint8List data) => keyPair.sign(data);
}

final class _CertificateBlob implements SSHHostKey {
  _CertificateBlob(this._blob);
  final Uint8List _blob;

  @override
  Uint8List encode() => Uint8List.fromList(_blob);
}

/// `SHA256:<base64 without padding>` like `ssh-keygen -l`.
String openSshFingerprint(Uint8List publicKeyBlob) {
  final digest = crypto.sha256.convert(publicKeyBlob).bytes;
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

/// Public facts about a private key used by the Keychain UI. Decodes the key
/// with [passphrase]; returns `null` when it cannot be read. The private key
/// itself is never returned or logged.
({String keyType, String fingerprint})? describePrivateKey(
  String privateKey, {
  String? passphrase,
}) {
  try {
    final pairs = _decodePairs(privateKey, passphrase);
    if (pairs.isEmpty) return null;
    final blob = pairs.first.toPublicKey().encode();
    return (keyType: pairs.first.name, fingerprint: openSshFingerprint(blob));
  } on Object {
    return null;
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

final class _WireReader {
  _WireReader(this._data);
  final Uint8List _data;
  int _offset = 0;

  bool get done => _offset == _data.length;

  int uint32() {
    if (_offset + 4 > _data.length) throw const FormatException('short');
    final value = ByteData.sublistView(_data, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    return value;
  }

  BigInt uint64() {
    final high = BigInt.from(uint32());
    final low = BigInt.from(uint32());
    return (high << 32) | low;
  }

  Uint8List bytes() {
    final length = uint32();
    if (length > _data.length - _offset) throw const FormatException('short');
    final value = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return value;
  }

  String utf8String() => utf8.decode(bytes());

  List<String> utf8List() {
    final values = <String>[];
    while (!done) {
      values.add(utf8String());
      if (values.length > 256) throw const FormatException('too many');
    }
    return values;
  }

  /// Critical options / extensions: (name, data) pairs; only names kept.
  List<String> optionNames() {
    final names = <String>[];
    while (!done) {
      names.add(utf8String());
      bytes();
      if (names.length > 64) throw const FormatException('too many');
    }
    return names;
  }
}

final class _WireWriter {
  final _builder = BytesBuilder(copy: false);

  void string(List<int> value) {
    final length = ByteData(4)..setUint32(0, value.length);
    _builder
      ..add(length.buffer.asUint8List())
      ..add(value);
  }

  Uint8List bytes() => _builder.toBytes();
}
