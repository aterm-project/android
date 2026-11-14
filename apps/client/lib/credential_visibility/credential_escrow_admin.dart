// Instance-admin side of Credential visibility v1: default mode, per-account
// modes, escrow key setup / recovery-code unlock / reset and the read-only
// credential viewer.
//
// The escrow private key exists only in admin clients. Every operation that
// needs it re-derives the admin's account key from the master password the
// admin re-enters, unwraps the key, uses it and disposes it. Nothing here
// writes Vault records.
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../api/api_client.dart';
import '../app_controller.dart';
import '../crypto/vault_crypto.dart';
import '../domain/models.dart';
import 'credential_escrow_crypto.dart';
import 'credential_visibility_api.dart';
import 'credential_visibility_models.dart';

/// Admin-actionable failure; [code] is stable for localization.
class CredentialEscrowAdminException implements Exception {
  const CredentialEscrowAdminException(this.code);

  /// `signed_out`, `not_admin`, `wrong_password`, `wrong_recovery_code`,
  /// `no_key`, `key_exists`, `key_invalid`, `wrap_missing`,
  /// `wrap_invalid`, `scope_changed`, `not_available`.
  final String code;

  @override
  String toString() => 'CredentialEscrowAdminException($code)';
}

/// The signed-in admin session an operation was started for. Every network
/// result is checked against it so a sign-out or server switch never mixes
/// scopes.
class _AdminScope {
  _AdminScope(this.app)
    : client = app.api,
      accountId = app.account?.accountId,
      identity = app.identity,
      instance = app.instance;

  final AppController app;
  final ApiClient? client;
  final String? accountId;
  final DeviceIdentity? identity;
  final InstanceInfo? instance;

  void verify() {
    if (client == null ||
        accountId == null ||
        identity == null ||
        instance == null ||
        !identical(app.api, client) ||
        app.account?.accountId != accountId ||
        !identical(app.identity, identity) ||
        app.instance?.instanceId != instance!.instanceId ||
        app.instance?.signingPublicKey != instance!.signingPublicKey ||
        !app.isInstanceAdmin) {
      throw const CredentialEscrowAdminException('scope_changed');
    }
  }
}

/// Key material generated for a new escrow key, held only until the admin
/// confirmed storing the recovery code and the upload finished. The escrow
/// secret key itself is already disposed: only wraps remain.
class PreparedEscrowKey {
  PreparedEscrowKey._(
    this._scope,
    this._recoveryCode, {
    required this.keyId,
    required this.publicKey,
    required this.creatorSignature,
    required this.accountWrap,
    required this.recoveryWrap,
  });

  final String keyId;
  final String publicKey;
  final String creatorSignature;
  final Map<String, Object?> accountWrap;
  final Map<String, Object?> recoveryWrap;
  final _AdminScope _scope;
  String? _recoveryCode;

  /// Display form `XXXX-XXXX-…`. Null once [discardRecoveryCode] ran.
  String? get recoveryCode => _recoveryCode;

  /// Drops the only reference to the recovery code. (Dart strings cannot be
  /// overwritten; releasing the reference is the strongest option.)
  void discardRecoveryCode() => _recoveryCode = null;
}

/// Opens the escrow key for the admin and offers the account directory
/// operations.
class CredentialEscrowAdmin {
  CredentialEscrowAdmin(this.app);

  final AppController app;

  bool get available =>
      app.isInstanceAdmin &&
      (app.instance?.capabilities.contains(credentialVisibilityCapability) ??
          false);

  _AdminScope _scope() {
    final scope = _AdminScope(app);
    if (scope.client == null ||
        scope.accountId == null ||
        scope.identity == null ||
        scope.instance == null) {
      throw const CredentialEscrowAdminException('signed_out');
    }
    if (!app.isInstanceAdmin) {
      throw const CredentialEscrowAdminException('not_admin');
    }
    return scope;
  }

  CredentialVisibilityApi _api(_AdminScope scope) =>
      CredentialVisibilityApi(scope.client!);

  Future<AdminCredentialVisibilityOverview> loadOverview() async {
    final scope = _scope();
    final overview = await _api(scope).adminOverview();
    scope.verify();
    return overview;
  }

  /// `database_encryption` of the instance overview (`enabled` or
  /// `disabled`), or null when the server does not report it. Escrow keys are
  /// best kept on an encrypted database: a plaintext file holds each
  /// administrator's KDF salt and verifier next to that administrator's wrap.
  Future<String?> loadDatabaseEncryption() async {
    final scope = _scope();
    final overview = await scope.client!.instanceAdminOverview();
    scope.verify();
    return overview.databaseEncryption;
  }

  /// Verifies [descriptor] against the pinned instance signing key.
  VerifiedEscrowKey verifyKey(CredentialEscrowKeyDescriptor descriptor) {
    final instance = app.instance;
    if (instance == null) {
      throw const CredentialEscrowAdminException('signed_out');
    }
    try {
      return verifyEscrowKeyDescriptor(
        app.sodium,
        descriptor: descriptor.toJson(),
        instanceId: instance.instanceId,
        pinnedInstanceSigningKey: instance.signingPublicKey,
      );
    } on FormatException {
      throw const CredentialEscrowAdminException('key_invalid');
    }
  }

  Future<AdminCredentialVisibilityOverview> setDefaultMode(
    CredentialVisibilityMode mode,
  ) async {
    final scope = _scope();
    final overview = await _api(scope).setDefaultMode(mode);
    scope.verify();
    return overview;
  }

  Future<AdminCredentialVisibilityAccountReceipt> setAccountMode({
    required String userId,
    required CredentialVisibilityMode mode,
  }) async {
    final scope = _scope();
    final receipt = await _api(scope)
        .setAccountMode(userId: userId, mode: mode);
    scope.verify();
    return receipt;
  }

  /// Derives this admin's account key from the re-entered master password.
  /// The caller zeroes the returned buffer.
  Future<Uint8List> _deriveAccountKey(
    _AdminScope scope,
    String password,
  ) async {
    final username = app.authenticatedUsername;
    final account = app.account;
    if (username == null || account == null) {
      throw const CredentialEscrowAdminException('signed_out');
    }
    final prelogin = await scope.client!.prelogin(username);
    scope.verify();
    if (prelogin['account_id'] != scope.accountId || prelogin['kdf'] is! Map) {
      throw const CredentialEscrowAdminException('wrong_password');
    }
    final params = KdfParameters.fromJson(
      Map<String, dynamic>.from(prelogin['kdf'] as Map),
    );
    try {
      final key = await app.crypto.unwrapAccountKey(
        password: password,
        params: params,
        envelope: account.accountKeyEnvelope,
      );
      if (key.length != 32) {
        key.fillRange(0, key.length, 0);
        throw const CredentialEscrowAdminException('wrong_password');
      }
      return key;
    } on CredentialEscrowAdminException {
      rethrow;
    } on Object {
      throw const CredentialEscrowAdminException('wrong_password');
    } finally {
      params.salt.fillRange(0, params.salt.length, 0);
    }
  }

  /// Step 1 of key setup: generates the X25519 escrow key pair, a recovery
  /// code, both wraps and the creator signature. Nothing is uploaded yet.
  Future<PreparedEscrowKey> prepareEscrowKey(String password) async {
    final scope = _scope();
    final instanceId = scope.instance!.instanceId;
    final accountKey = await _deriveAccountKey(scope, password);
    final generated = GeneratedEscrowKey.generate(app.sodium);
    try {
      final code = EscrowRecoveryCode.generate(app.sodium);
      final accountWrap = await wrapEscrowSecretKeyForAccount(
        app.crypto,
        accountKey: accountKey,
        secretKey: generated.keyPair.secretKey,
        instanceId: instanceId,
        keyId: generated.keyId,
        accountId: scope.accountId!,
      );
      final recoveryWrap = wrapEscrowSecretKeyForRecovery(
        app.crypto,
        code: code,
        secretKey: generated.keyPair.secretKey,
        instanceId: instanceId,
        keyId: generated.keyId,
      );
      final creatorSignature = signEscrowKeyCreation(
        app.sodium,
        identity: scope.identity!,
        instanceId: instanceId,
        accountId: scope.accountId!,
        keyId: generated.keyId,
        publicKey: generated.publicKeyText,
      );
      scope.verify();
      return PreparedEscrowKey._(
        scope,
        code.display,
        keyId: generated.keyId,
        publicKey: generated.publicKeyText,
        creatorSignature: creatorSignature,
        accountWrap: accountWrap,
        recoveryWrap: recoveryWrap,
      );
    } finally {
      generated.dispose();
      accountKey.fillRange(0, accountKey.length, 0);
    }
  }

  /// Step 2, after the admin confirmed storing the recovery code.
  Future<VerifiedEscrowKey> uploadEscrowKey(PreparedEscrowKey prepared) async {
    final scope = prepared._scope;
    scope.verify();
    prepared.discardRecoveryCode();
    final CredentialEscrowKeyDescriptor descriptor;
    try {
      descriptor = await _api(scope).createEscrowKey(
        keyId: prepared.keyId,
        publicKey: prepared.publicKey,
        creatorSignature: prepared.creatorSignature,
        accountWrap: prepared.accountWrap,
        recoveryWrap: prepared.recoveryWrap,
      );
    } on ApiException catch (error) {
      if (error.code == 'CREDENTIAL_ESCROW_KEY_EXISTS') {
        throw const CredentialEscrowAdminException('key_exists');
      }
      rethrow;
    }
    scope.verify();
    final verified = verifyKey(descriptor);
    if (verified.keyId != prepared.keyId ||
        verified.publicKeyText != prepared.publicKey) {
      throw const CredentialEscrowAdminException('key_invalid');
    }
    return verified;
  }

  /// Opens the escrow key with the recovery code and stores this admin's own
  /// account wrap (for a second admin, or after an account key change).
  Future<void> unlockWithRecoveryCode({
    required String recoveryCode,
    required String password,
  }) async {
    final scope = _scope();
    final EscrowRecoveryCode code;
    try {
      code = EscrowRecoveryCode.parse(recoveryCode);
    } on FormatException {
      throw const CredentialEscrowAdminException('wrong_recovery_code');
    }
    final overview = await _api(scope).adminOverview();
    scope.verify();
    final descriptor = overview.escrowKey;
    final recoveryWrap = overview.recoveryWrap;
    if (descriptor == null || recoveryWrap == null) {
      throw const CredentialEscrowAdminException('no_key');
    }
    final key = verifyKey(descriptor);
    final instanceId = scope.instance!.instanceId;
    SecureKey? secret;
    Uint8List? accountKey;
    try {
      try {
        secret = unwrapEscrowSecretKeyWithRecoveryCode(
          app.crypto,
          code: code,
          wrap: recoveryWrap,
          instanceId: instanceId,
          keyId: key.keyId,
        );
      } on FormatException {
        throw const CredentialEscrowAdminException('wrong_recovery_code');
      }
      if (!escrowSecretKeyMatches(app.sodium, key: key, secretKey: secret)) {
        throw const CredentialEscrowAdminException('wrap_invalid');
      }
      accountKey = await _deriveAccountKey(scope, password);
      final wrap = await wrapEscrowSecretKeyForAccount(
        app.crypto,
        accountKey: accountKey,
        secretKey: secret,
        instanceId: instanceId,
        keyId: key.keyId,
        accountId: scope.accountId!,
      );
      scope.verify();
      try {
        await _api(scope).storeOwnWrap(keyId: key.keyId, accountWrap: wrap);
      } on ApiException catch (error) {
        if (error.code == 'CREDENTIAL_ESCROW_KEY_MISMATCH') {
          throw const CredentialEscrowAdminException('no_key');
        }
        rethrow;
      }
      scope.verify();
    } finally {
      secret?.dispose();
      accountKey?.fillRange(0, accountKey.length, 0);
    }
  }

  /// Deletes the escrow key, every admin wrap and every escrowed envelope.
  Future<void> resetEscrowKey(String keyId) async {
    final scope = _scope();
    await _api(scope).resetEscrowKey(keyId: keyId);
    scope.verify();
  }

  /// Unwraps the escrow secret key with the admin's master password and
  /// returns a viewer for [targetUserId]. The caller must [dispose] it.
  Future<CredentialEscrowViewerSession> openViewer({
    required String password,
    required String targetUserId,
  }) async {
    final scope = _scope();
    final overview = await _api(scope).adminOverview();
    scope.verify();
    final descriptor = overview.escrowKey;
    if (descriptor == null) {
      throw const CredentialEscrowAdminException('no_key');
    }
    final wrap = overview.callerWrap;
    if (wrap == null) {
      throw const CredentialEscrowAdminException('wrap_missing');
    }
    final key = verifyKey(descriptor);
    final accountKey = await _deriveAccountKey(scope, password);
    SecureKey? secret;
    try {
      try {
        secret = await unwrapEscrowSecretKeyForAccount(
          app.crypto,
          accountKey: accountKey,
          wrap: wrap,
          instanceId: scope.instance!.instanceId,
          keyId: key.keyId,
          accountId: scope.accountId!,
        );
      } on FormatException {
        // The password was right (the account key opened), so the wrap was
        // made for another account key (e.g. after a full account recovery).
        throw const CredentialEscrowAdminException('wrap_invalid');
      }
      if (!escrowSecretKeyMatches(app.sodium, key: key, secretKey: secret)) {
        throw const CredentialEscrowAdminException('wrap_invalid');
      }
      scope.verify();
      final session = CredentialEscrowViewerSession._(
        scope,
        secret,
        app: app,
        key: key,
        targetUserId: targetUserId,
      );
      secret = null;
      return session;
    } finally {
      secret?.dispose();
      accountKey.fillRange(0, accountKey.length, 0);
    }
  }
}

/// One decrypted Vault in the viewer.
class EscrowViewerVault {
  const EscrowViewerVault({
    required this.vaultId,
    required this.name,
    required this.role,
    required this.openedEpochs,
    required this.failedEpochs,
  });

  final String vaultId;

  /// Decrypted display name, or null when it could not be decrypted.
  final String? name;
  final String role;
  final List<int> openedEpochs;

  /// Escrowed epochs whose deposit failed verification (never trusted).
  final List<int> failedEpochs;

  bool get readable => openedEpochs.isNotEmpty;
}

/// Hosts and keychain items of one Vault, decrypted read-only.
class EscrowViewerItems {
  const EscrowViewerItems({
    required this.hosts,
    required this.credentials,
    required this.undecryptable,
  });

  final List<HostRecord> hosts;
  final List<CredentialRecord> credentials;

  /// Records whose key epoch was not escrowed or that failed verification.
  final int undecryptable;
}

/// Holds the unwrapped escrow secret key while the viewer is open. Read-only:
/// it never writes records. [dispose] releases every key.
class CredentialEscrowViewerSession {
  CredentialEscrowViewerSession._(
    this._scope,
    this._secretKey, {
    required this.app,
    required this.key,
    required this.targetUserId,
  });

  final AppController app;
  final _AdminScope _scope;
  final VerifiedEscrowKey key;
  final String targetUserId;
  SecureKey? _secretKey;
  final Map<String, Map<int, Uint8List>> _vaultKeys = {};
  String? username;

  static const recordPageLimit = 200;

  /// Upper bound on record pages per Vault (200 × 50 = 10 000 records).
  static const maxRecordPages = 50;

  bool get disposed => _secretKey == null;

  CredentialVisibilityApi get _api => CredentialVisibilityApi(_scope.client!);

  SecureKey _requireSecret() {
    final secret = _secretKey;
    if (secret == null) {
      throw const CredentialEscrowAdminException('scope_changed');
    }
    _scope.verify();
    return secret;
  }

  /// Lists the target's Vaults (decrypting names) and opens every escrowed
  /// key under the current escrow key. Does not count as a view.
  Future<List<EscrowViewerVault>> loadVaults() async {
    _requireSecret();
    final response = await _api.escrowAccountVaults(targetUserId);
    final secret = _requireSecret();
    username = response.username;
    final instanceId = _scope.instance!.instanceId;
    final result = <EscrowViewerVault>[];
    for (final vault in response.vaults) {
      final keys = <int, Uint8List>{};
      final failed = <int>[];
      for (final envelope in vault.escrow) {
        final depositorKey = envelope.depositorSigningPublicKey;
        if (depositorKey == null) {
          // Unverifiable deposit: never trusted.
          failed.add(envelope.keyEpoch);
          continue;
        }
        try {
          keys[envelope.keyEpoch] = openEscrowDeposit(
            app.sodium,
            key: key,
            secretKey: secret,
            instanceId: instanceId,
            vaultId: vault.vaultId,
            keyEpoch: envelope.keyEpoch,
            sealed: envelope.sealed,
            signature: envelope.signature,
            depositorSigningPublicKey: depositorKey,
          );
        } on FormatException {
          failed.add(envelope.keyEpoch);
        }
      }
      final previous = _vaultKeys.remove(vault.vaultId);
      _wipeKeys(previous);
      _vaultKeys[vault.vaultId] = keys;
      String? name;
      final envelope = vault.nameEnvelope;
      if (envelope != null) {
        final candidates = [
          ?keys[vault.activeEpoch],
          for (final entry in keys.entries)
            if (entry.key != vault.activeEpoch) entry.value,
        ];
        for (final candidate in candidates) {
          try {
            name = await app.crypto.decryptVaultName(
              vaultId: vault.vaultId,
              vaultKey: candidate,
              envelope: envelope,
            );
            break;
          } on Object {
            // Try the next escrowed epoch.
          }
        }
      }
      result.add(
        EscrowViewerVault(
          vaultId: vault.vaultId,
          name: name,
          role: vault.role,
          openedEpochs: List.unmodifiable(keys.keys.toList()..sort()),
          failedEpochs: List.unmodifiable(failed..sort()),
        ),
      );
    }
    return result;
  }

  /// Reads the Vault's current Hosts and keychain items. The server records
  /// this as an admin view and notifies the user.
  Future<EscrowViewerItems> loadItems(String vaultId) async {
    _requireSecret();
    final keys = _vaultKeys[vaultId];
    if (keys == null || keys.isEmpty) {
      throw const CredentialEscrowAdminException('not_available');
    }
    final hosts = <HostRecord>[];
    final credentials = <CredentialRecord>[];
    var undecryptable = 0;
    String? after;
    for (var page = 0; page < maxRecordPages; page++) {
      final AdminEscrowRecordsPage response;
      try {
        response = await _api.escrowRecords(
          vaultId: vaultId,
          userId: targetUserId,
          after: after,
          limit: recordPageLimit,
        );
      } on ApiException catch (error) {
        if (error.code == 'CREDENTIAL_ESCROW_NOT_AVAILABLE') {
          throw const CredentialEscrowAdminException('not_available');
        }
        rethrow;
      }
      _requireSecret();
      for (final record in response.records) {
        final plaintext = await _decrypt(vaultId, keys, record);
        if (plaintext == null) {
          undecryptable++;
          continue;
        }
        try {
          switch (plaintext['type']) {
            case 'host':
              hosts.add(HostRecord.fromJson(plaintext));
            case 'credential':
              credentials.add(CredentialRecord.fromJson(plaintext));
          }
        } on Object {
          undecryptable++;
        }
      }
      after = response.nextAfter;
      if (after == null) break;
    }
    hosts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    credentials.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return EscrowViewerItems(
      hosts: List.unmodifiable(hosts),
      credentials: List.unmodifiable(credentials),
      undecryptable: undecryptable,
    );
  }

  Future<Map<String, dynamic>?> _decrypt(
    String vaultId,
    Map<int, Uint8List> keys,
    AdminEscrowRecord record,
  ) async {
    final header = record.envelope['header'];
    if (header is! Map ||
        header['vault_id'] != vaultId ||
        header['record_id'] != record.recordId ||
        header['revision_id'] != record.revisionId) {
      return null;
    }
    final epoch = int.tryParse('${header['key_epoch']}');
    final vaultKey = epoch == null ? null : keys[epoch];
    final authorKey = record.authorSigningPublicKey;
    // No author key: the record's signature cannot be verified.
    if (vaultKey == null || authorKey == null) return null;
    try {
      return await app.crypto.decryptRecord(
        vaultKey: vaultKey,
        envelope: record.envelope,
        authorPublicKey: decodeEscrowBase64(
          authorKey,
          field: 'author key',
          exactBytes: 32,
        ),
      );
    } on Object {
      return null;
    }
  }

  static void _wipeKeys(Map<int, Uint8List>? keys) {
    if (keys == null) return;
    for (final key in keys.values) {
      key.fillRange(0, key.length, 0);
    }
  }

  void dispose() {
    _secretKey?.dispose();
    _secretKey = null;
    for (final keys in _vaultKeys.values) {
      _wipeKeys(keys);
    }
    _vaultKeys.clear();
  }
}
