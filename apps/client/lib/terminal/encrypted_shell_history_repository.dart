import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart' as sodium_api;

import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../storage/client_database.dart';
import '../storage/secure_store.dart';
import 'shell_integration_protocol.dart';

const int encryptedShellHistoryMaxEntries = 500;
const int _maxHistoryCommandBytes = 4096;
const int _historyNonceBytes = 24;
const int _historyKeyBytes = 32;
const String _historyFormat = 'atermius-device-shell-history-v1';

/// One decrypted device-local history row. Host identifiers and command text
/// are present only after authenticated decryption and never appear in the DB
/// index columns.
final class DecryptedShellHistoryEntry {
  const DecryptedShellHistoryEntry({
    required this.entryId,
    required this.hostId,
    required this.command,
    required this.exitStatus,
    required this.startedAt,
    required this.completedAt,
  });

  final String entryId;
  final String hostId;
  final String command;
  final int exitStatus;
  final DateTime startedAt;
  final DateTime completedAt;

  ShellIntegrationCompletedCommand get commandEvent =>
      ShellIntegrationCompletedCommand(
        commandId: 0,
        command: command,
        exitStatus: exitStatus,
        startedAt: startedAt,
        completedAt: completedAt,
      );
}

/// Encrypts shell history into the ClientDatabase's ciphertext-only table.
///
/// The table is separate from encrypted Vault records and the sync outbox.
/// This repository has no sync API. It derives a stable per-server,
/// account-and-device key from that device's signing secret using a distinct
/// HKDF purpose, so changing a Vault epoch does not affect local history.
/// Browser secure storage remains accessible to same-origin scripts; this
/// protects database rows at rest and against accidental plaintext indexing,
/// not against XSS on the trusted application origin.
final class EncryptedShellHistoryRepository {
  EncryptedShellHistoryRepository({
    required ClientDatabase database,
    required VaultCrypto crypto,
    required DeviceIdentity identity,
    required String baseUrl,
    required String accountId,
    this.maxEntries = encryptedShellHistoryMaxEntries,
  }) : _database = database,
       _crypto = crypto,
       _identity = identity,
       _serverNamespace = secureStorageNamespace(baseUrl),
       _accountId = accountId,
       _deviceId = identity.deviceId {
    if (_serverNamespace.isEmpty ||
        _accountId.trim().isEmpty ||
        _deviceId.trim().isEmpty ||
        maxEntries < 1 ||
        maxEntries > encryptedShellHistoryMaxEntries) {
      throw ArgumentError('Invalid terminal history scope or retention limit.');
    }
  }

  final ClientDatabase _database;
  final VaultCrypto _crypto;
  final DeviceIdentity _identity;
  final String _serverNamespace;
  final String _accountId;
  final String _deviceId;
  final int maxEntries;
  Uint8List? _derivedKey;
  Future<Uint8List>? _derivedKeyFuture;
  bool _closed = false;

  String get accountId => _accountId;
  String get deviceId => _deviceId;
  String get serverNamespace => _serverNamespace;

  Future<String> record({
    required String hostId,
    required ShellIntegrationCompletedCommand command,
  }) async {
    _ensureOpen();
    _validateCommand(hostId, command);
    final entryId = await _database.insertTerminalHistoryCiphertext(
      serverNamespace: _serverNamespace,
      accountId: _accountId,
      deviceId: _deviceId,
      ciphertext: await _encrypt(hostId: hostId, command: command),
      createdAt: command.completedAt.toUtc().millisecondsSinceEpoch,
    );
    await _database.pruneTerminalHistoryCiphertext(
      serverNamespace: _serverNamespace,
      accountId: _accountId,
      deviceId: _deviceId,
      maxEntries: maxEntries,
    );
    return entryId;
  }

  Future<List<DecryptedShellHistoryEntry>> load({String? hostId}) async {
    _ensureOpen();
    final rows = await _database.terminalHistoryCiphertextEntries(
      serverNamespace: _serverNamespace,
      accountId: _accountId,
      deviceId: _deviceId,
    );
    final result = <DecryptedShellHistoryEntry>[];
    for (final row in rows) {
      try {
        final entry = await _decrypt(row.entryId, row.ciphertext);
        if (hostId == null || entry.hostId == hostId) result.add(entry);
      } on Object {
        // A malformed, moved, or unauthenticated row is omitted. Never expose
        // untrusted plaintext or ciphertext through diagnostic output.
      }
    }
    result.sort((left, right) {
      final time = left.completedAt.compareTo(right.completedAt);
      return time == 0 ? left.entryId.compareTo(right.entryId) : time;
    });
    return List.unmodifiable(result);
  }

  Future<int> clear({String? hostId}) async {
    _ensureOpen();
    if (hostId == null) {
      return _database.clearTerminalHistoryCiphertext(
        serverNamespace: _serverNamespace,
        accountId: _accountId,
        deviceId: _deviceId,
      );
    }
    var removed = 0;
    final rows = await _database.terminalHistoryCiphertextEntries(
      serverNamespace: _serverNamespace,
      accountId: _accountId,
      deviceId: _deviceId,
    );
    for (final row in rows) {
      try {
        final entry = await _decrypt(row.entryId, row.ciphertext);
        if (entry.hostId != hostId) continue;
        if (await _database.deleteTerminalHistoryCiphertext(
          serverNamespace: _serverNamespace,
          accountId: _accountId,
          deviceId: _deviceId,
          entryId: row.entryId,
        )) {
          removed++;
        }
      } on Object {
        // Keep rows that cannot be authenticated; their scope is unknown.
      }
    }
    return removed;
  }

  /// Releases the transient derived key held by this repository instance.
  void close() {
    _closed = true;
    _derivedKey?.fillRange(0, _derivedKey!.length, 0);
    _derivedKey = null;
  }

  Future<Uint8List> _encrypt({
    required String hostId,
    required ShellIntegrationCompletedCommand command,
  }) async {
    final keyBytes = Uint8List.fromList(await _keyBytes());
    sodium_api.SecureKey? key;
    Uint8List? nonce;
    final aad = _aad();
    final cleartext = Uint8List.fromList(
      utf8.encode(
        canonicalJson({
          'format': _historyFormat,
          'host_id': hostId,
          'command_id': command.commandId,
          'command': command.command,
          'exit_status': command.exitStatus,
          'started_at_ms': command.startedAt.toUtc().millisecondsSinceEpoch,
          'completed_at_ms': command.completedAt.toUtc().millisecondsSinceEpoch,
        }),
      ),
    );
    try {
      key = _crypto.sodium.secureCopy(keyBytes);
      nonce = _crypto.randomBytes(_historyNonceBytes);
      final ciphertext = _crypto.sodium.crypto.aeadXChaCha20Poly1305IETF
          .encrypt(
            message: cleartext,
            nonce: nonce,
            key: key,
            additionalData: aad,
          );
      return Uint8List.fromList([...nonce, ...ciphertext]);
    } finally {
      key?.dispose();
      keyBytes.fillRange(0, keyBytes.length, 0);
      nonce?.fillRange(0, nonce.length, 0);
      aad.fillRange(0, aad.length, 0);
      cleartext.fillRange(0, cleartext.length, 0);
    }
  }

  Future<DecryptedShellHistoryEntry> _decrypt(
    String entryId,
    Uint8List envelope,
  ) async {
    if (envelope.length < _historyNonceBytes + 16) {
      throw const FormatException('Terminal history ciphertext is truncated.');
    }
    final keyBytes = Uint8List.fromList(await _keyBytes());
    sodium_api.SecureKey? key;
    final aad = _aad();
    final nonce = Uint8List.fromList(envelope.sublist(0, _historyNonceBytes));
    final ciphertext = Uint8List.fromList(envelope.sublist(_historyNonceBytes));
    Uint8List? cleartext;
    try {
      key = _crypto.sodium.secureCopy(keyBytes);
      final plaintext = _crypto.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
      cleartext = plaintext;
      final cleartextJson = utf8.decode(plaintext);
      final decoded = jsonDecode(cleartextJson);
      if (decoded is! Map<String, dynamic> ||
          canonicalJson(decoded) != cleartextJson ||
          decoded.keys.toSet().difference(const {
            'format',
            'host_id',
            'command_id',
            'command',
            'exit_status',
            'started_at_ms',
            'completed_at_ms',
          }).isNotEmpty ||
          decoded['format'] != _historyFormat ||
          decoded['host_id'] is! String ||
          decoded['command_id'] is! int ||
          decoded['command'] is! String ||
          decoded['exit_status'] is! int ||
          decoded['started_at_ms'] is! int ||
          decoded['completed_at_ms'] is! int) {
        throw const FormatException('Terminal history payload is invalid.');
      }
      final hostId = decoded['host_id'] as String;
      final command = decoded['command'] as String;
      final exitStatus = decoded['exit_status'] as int;
      final startedAtMs = decoded['started_at_ms'] as int;
      final completedAtMs = decoded['completed_at_ms'] as int;
      if (hostId.isEmpty ||
          utf8.encode(command).length > _maxHistoryCommandBytes ||
          exitStatus < 0 ||
          exitStatus > 255 ||
          startedAtMs < 0 ||
          completedAtMs < startedAtMs) {
        throw const FormatException('Terminal history values are invalid.');
      }
      return DecryptedShellHistoryEntry(
        entryId: entryId,
        hostId: hostId,
        command: command,
        exitStatus: exitStatus,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          startedAtMs,
          isUtc: true,
        ),
        completedAt: DateTime.fromMillisecondsSinceEpoch(
          completedAtMs,
          isUtc: true,
        ),
      );
    } finally {
      key?.dispose();
      keyBytes.fillRange(0, keyBytes.length, 0);
      nonce.fillRange(0, nonce.length, 0);
      ciphertext.fillRange(0, ciphertext.length, 0);
      cleartext?.fillRange(0, cleartext.length, 0);
      aad.fillRange(0, aad.length, 0);
    }
  }

  Future<Uint8List> _keyBytes() async {
    _ensureOpen();
    final existing = _derivedKey;
    if (existing != null) return existing;
    final pending = _derivedKeyFuture ??= _deriveKey();
    final derived = await pending;
    if (_closed) {
      derived.fillRange(0, derived.length, 0);
      throw StateError('Terminal history repository is closed.');
    }
    return _derivedKey ??= derived;
  }

  Future<Uint8List> _deriveKey() => _crypto.derivePurposeKey(
    inputKey: _identity.signing.secretKey,
    purpose: 'terminal-history-device-local',
    context: {
      'key_version': 1,
      'server_namespace': _serverNamespace,
      'account_id': _accountId,
      'device_id': _deviceId,
    },
  );

  Uint8List _aad() => Uint8List.fromList(
    utf8.encode(
      canonicalJson({
        'format': _historyFormat,
        'server_namespace': _serverNamespace,
        'account_id': _accountId,
        'device_id': _deviceId,
      }),
    ),
  );

  void _validateCommand(
    String hostId,
    ShellIntegrationCompletedCommand command,
  ) {
    final bytes = utf8.encode(command.command);
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(hostId) ||
        bytes.isEmpty ||
        bytes.length > _maxHistoryCommandBytes ||
        command.exitStatus < 0 ||
        command.exitStatus > 255 ||
        command.completedAt.isBefore(command.startedAt) ||
        command.startedAt.toUtc().millisecondsSinceEpoch < 0 ||
        command.completedAt.toUtc().millisecondsSinceEpoch < 0) {
      throw const FormatException('Terminal history command is invalid.');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Terminal history repository is closed.');
  }
}
