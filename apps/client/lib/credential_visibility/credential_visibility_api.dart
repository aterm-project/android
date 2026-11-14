// HTTP bindings for Credential visibility v1. Reuses the authenticated
// ApiClient (Bearer session, error envelope, no redirects) and returns the
// strictly parsed models from credential_visibility_models.dart.
import '../api/api_client.dart';
import 'credential_escrow_crypto.dart';
import 'credential_visibility_models.dart';

/// Server capability advertised by `GET /api/v1/instance` (SQLite mode only).
const credentialVisibilityCapability = 'credential_visibility';

class CredentialVisibilityApi {
  CredentialVisibilityApi(this._api);

  final ApiClient _api;

  static void _requireUuid(String value, String field) {
    if (!isCanonicalEscrowUuid(value)) {
      throw ArgumentError.value(value, field, 'Must be a canonical UUID.');
    }
  }

  // User ---------------------------------------------------------------------

  Future<CredentialVisibilityStatus> status() async =>
      CredentialVisibilityStatus.fromJson(
        await _api.get('/api/v1/credential-visibility'),
      );

  Future<CredentialEscrowDepositResult> deposit({
    required String vaultId,
    required int keyEpoch,
    required Map<String, Object?> body,
  }) async {
    _requireUuid(vaultId, 'vaultId');
    if (keyEpoch < 1) {
      throw ArgumentError.value(keyEpoch, 'keyEpoch', 'Must be positive.');
    }
    return parseCredentialEscrowDepositResult(
      await _api.put(
        '/api/v1/credential-visibility/escrow/$vaultId/$keyEpoch',
        body,
      ),
    );
  }

  /// Asked by the owner of [vaultId] before inviting (or delivering a key to)
  /// the account behind [deviceId].
  Future<CredentialVisibilityShareRecipient> shareRecipient({
    required String vaultId,
    required String deviceId,
  }) async {
    _requireUuid(vaultId, 'vaultId');
    _requireUuid(deviceId, 'deviceId');
    return CredentialVisibilityShareRecipient.fromJson(
      await _api.get(
        '/api/v1/credential-visibility/vaults/$vaultId/recipients/$deviceId',
      ),
    );
  }

  // Admin --------------------------------------------------------------------

  Future<AdminCredentialVisibilityOverview> adminOverview() async =>
      AdminCredentialVisibilityOverview.fromJson(
        await _api.get('/api/v1/admin/credential-visibility'),
      );

  Future<AdminCredentialVisibilityOverview> setDefaultMode(
    CredentialVisibilityMode mode,
  ) async => AdminCredentialVisibilityOverview.fromJson(
    await _api.put('/api/v1/admin/credential-visibility', {
      'default_mode': mode.wire,
    }),
  );

  Future<AdminCredentialVisibilityAccountReceipt> setAccountMode({
    required String userId,
    required CredentialVisibilityMode mode,
  }) async {
    _requireUuid(userId, 'userId');
    return AdminCredentialVisibilityAccountReceipt.fromJson(
      await _api.put('/api/v1/admin/accounts/$userId/credential-visibility', {
        'mode': mode.wire,
      }),
      expectedUserId: userId,
    );
  }

  /// `POST /api/v1/admin/account-invitations` with an explicit mode. The
  /// receipt parser is the existing strict one.
  Future<AdminAccountInvitationIssueReceipt> createAccountInvitation({
    required String username,
    required int expiresInSeconds,
    required CredentialVisibilityMode mode,
  }) async {
    final normalized = username.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw ArgumentError.value(username, 'username', 'Must not be empty.');
    }
    if (expiresInSeconds < 60 || expiresInSeconds > 2592000) {
      throw ArgumentError.value(
        expiresInSeconds,
        'expiresInSeconds',
        'Must be between 60 and 2592000.',
      );
    }
    return AdminAccountInvitationIssueReceipt.fromJson(
      await _api.post('/api/v1/admin/account-invitations', {
        'username': normalized,
        'expires_in_seconds': expiresInSeconds,
        'credential_visibility': mode.wire,
      }),
    );
  }

  Future<CredentialEscrowKeyDescriptor> createEscrowKey({
    required String keyId,
    required String publicKey,
    required String creatorSignature,
    required Map<String, Object?> accountWrap,
    required Map<String, Object?> recoveryWrap,
  }) async {
    _requireUuid(keyId, 'keyId');
    final response = await _api.post('/api/v1/admin/credential-escrow/key', {
      'key_id': keyId,
      'public_key': publicKey,
      'creator_signature': creatorSignature,
      'account_wrap': accountWrap,
      'recovery_wrap': recoveryWrap,
    });
    if (response.length != 1 || !response.containsKey('escrow_key')) {
      throw const FormatException('Invalid credential escrow key response.');
    }
    return CredentialEscrowKeyDescriptor.fromJson(response['escrow_key']);
  }

  Future<void> storeOwnWrap({
    required String keyId,
    required Map<String, Object?> accountWrap,
  }) async {
    _requireUuid(keyId, 'keyId');
    final response = await _api.put(
      '/api/v1/admin/credential-escrow/key/wrap',
      {'key_id': keyId, 'account_wrap': accountWrap},
    );
    if (response.length != 1 || response['status'] != 'stored') {
      throw const FormatException('Invalid credential escrow wrap response.');
    }
  }

  Future<void> resetEscrowKey({required String keyId}) async {
    _requireUuid(keyId, 'keyId');
    final response = await _api.delete(
      '/api/v1/admin/credential-escrow/key',
      body: {'key_id': keyId, 'confirm': 'reset'},
    );
    if (response.length != 1 || response['status'] != 'reset') {
      throw const FormatException('Invalid credential escrow reset response.');
    }
  }

  Future<AdminEscrowAccountVaults> escrowAccountVaults(String userId) async {
    _requireUuid(userId, 'userId');
    return AdminEscrowAccountVaults.fromJson(
      await _api.get('/api/v1/admin/credential-escrow/accounts/$userId/vaults'),
      expectedUserId: userId,
    );
  }

  Future<AdminEscrowRecordsPage> escrowRecords({
    required String vaultId,
    required String userId,
    String? after,
    int limit = 200,
  }) async {
    _requireUuid(vaultId, 'vaultId');
    _requireUuid(userId, 'userId');
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 500.');
    }
    return AdminEscrowRecordsPage.fromJson(
      await _api.get(
        '/api/v1/admin/credential-escrow/vaults/$vaultId/records',
        query: {'user_id': userId, 'after': ?after, 'limit': '$limit'},
      ),
      limit: limit,
    );
  }
}
