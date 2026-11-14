// Typed, strictly parsed wire models for Credential visibility v1
// (`/api/v1/credential-visibility` and the admin escrow routes). Every model
// requires its exact field set, so a changed or truncated server response
// fails closed instead of being half-trusted.
import 'credential_escrow_crypto.dart';

/// Per-account credential visibility mode. Wire values are stable.
enum CredentialVisibilityMode {
  /// `private`: zero-knowledge; admins cannot read saved Host credentials.
  private('private'),

  /// `admin_visible`: the client escrows Vault keys to the admin escrow key.
  adminVisible('admin_visible');

  const CredentialVisibilityMode(this.wire);
  final String wire;

  static CredentialVisibilityMode? tryParse(Object? value) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }

  static CredentialVisibilityMode parse(Object? value) =>
      tryParse(value) ??
      (throw const FormatException('Invalid credential visibility mode.'));
}

enum CredentialEscrowStatus {
  notRequired('not_required'),
  noKey('no_key'),
  pending('pending'),
  complete('complete');

  const CredentialEscrowStatus(this.wire);
  final String wire;

  static CredentialEscrowStatus? tryParse(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }

  static CredentialEscrowStatus parse(Object? value) =>
      tryParse(value) ??
      (throw const FormatException('Invalid credential escrow status.'));
}

final _timestamp = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
);

DateTime? _parseTimestamp(Object? value) {
  if (value is! String || !_timestamp.hasMatch(value)) return null;
  return DateTime.tryParse(value)?.toUtc();
}

DateTime _requireTimestamp(Object? value, String what) =>
    _parseTimestamp(value) ?? (throw FormatException('Invalid $what.'));

Map<String, dynamic> _exactObject(
  Object? value,
  Set<String> keys,
  String what,
) {
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.length != keys.length ||
      !keys.containsAll(value.keys.cast<String>())) {
    throw FormatException('Invalid $what response.');
  }
  return Map<String, dynamic>.from(value);
}

String _uuid(Object? value, String what) {
  if (value is! String || !isCanonicalEscrowUuid(value)) {
    throw FormatException('Invalid $what.');
  }
  return value;
}

String _nonEmpty(Object? value, String what, {int maxLength = 512}) {
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('Invalid $what.');
  }
  return value;
}

int _epoch(Object? value) {
  if (value is! int || value < 1) {
    throw const FormatException('Invalid key epoch.');
  }
  return value;
}

int _count(Object? value) {
  if (value is! int || value < 0) {
    throw const FormatException('Invalid credential visibility count.');
  }
  return value;
}

/// The mode summary in `/me` (`policy.credential_visibility`), or null when
/// the server does not support the feature (older server or PostgreSQL mode).
class CredentialVisibilityPolicy {
  const CredentialVisibilityPolicy({required this.mode, this.changedAt});

  final CredentialVisibilityMode mode;

  /// Raw `changed_at` wire value; compared verbatim for acknowledgements.
  final String? changedAt;

  static CredentialVisibilityPolicy? fromAccountPolicy(
    Map<String, dynamic> policy,
  ) {
    final raw = policy['credential_visibility'];
    if (raw == null) return null;
    final json = _exactObject(raw, const {
      'mode',
      'changed_at',
    }, 'credential visibility policy');
    final changedAt = json['changed_at'];
    if (changedAt != null && _parseTimestamp(changedAt) == null) {
      throw const FormatException('Invalid credential visibility change time.');
    }
    return CredentialVisibilityPolicy(
      mode: CredentialVisibilityMode.parse(json['mode']),
      changedAt: changedAt as String?,
    );
  }
}

/// Wire escrow key descriptor. Must be verified with
/// [verifyEscrowKeyDescriptor] before any use.
class CredentialEscrowKeyDescriptor {
  const CredentialEscrowKeyDescriptor({
    required this.keyId,
    required this.publicKey,
    required this.signedPayload,
    required this.signature,
    required this.createdAt,
  });

  final String keyId;
  final String publicKey;
  final String signedPayload;
  final String signature;
  final String createdAt;

  factory CredentialEscrowKeyDescriptor.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'key_id',
      'public_key',
      'signed_payload',
      'signature',
      'created_at',
    }, 'credential escrow key');
    _requireTimestamp(json['created_at'], 'escrow key creation time');
    return CredentialEscrowKeyDescriptor(
      keyId: _uuid(json['key_id'], 'escrow key id'),
      publicKey: _nonEmpty(json['public_key'], 'escrow public key'),
      signedPayload: _nonEmpty(
        json['signed_payload'],
        'escrow key payload',
        maxLength: 4096,
      ),
      signature: _nonEmpty(json['signature'], 'escrow key signature'),
      createdAt: json['created_at'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'key_id': keyId,
    'public_key': publicKey,
    'signed_payload': signedPayload,
    'signature': signature,
    'created_at': createdAt,
  };
}

class CredentialEscrowMissingItem {
  const CredentialEscrowMissingItem({
    required this.vaultId,
    required this.keyEpoch,
  });

  final String vaultId;
  final int keyEpoch;

  factory CredentialEscrowMissingItem.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'vault_id',
      'key_epoch',
    }, 'credential escrow missing item');
    return CredentialEscrowMissingItem(
      vaultId: _uuid(json['vault_id'], 'vault id'),
      keyEpoch: _epoch(json['key_epoch']),
    );
  }
}

class CredentialAdminView {
  const CredentialAdminView({
    required this.viewedAt,
    this.adminUsername,
    this.vaultId,
  });

  final DateTime viewedAt;

  /// Null when the viewing admin account was deleted.
  final String? adminUsername;
  final String? vaultId;

  factory CredentialAdminView.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'viewed_at',
      'admin_username',
      'vault_id',
    }, 'credential admin view');
    final username = json['admin_username'];
    final vaultId = json['vault_id'];
    return CredentialAdminView(
      viewedAt: _requireTimestamp(json['viewed_at'], 'view time'),
      adminUsername: username == null
          ? null
          : _nonEmpty(username, 'admin username'),
      vaultId: vaultId == null ? null : _uuid(vaultId, 'vault id'),
    );
  }
}

/// `GET /api/v1/credential-visibility`.
class CredentialVisibilityStatus {
  const CredentialVisibilityStatus({
    required this.mode,
    required this.changedAt,
    required this.escrowStatus,
    required this.escrowKey,
    required this.missing,
    required this.adminViews,
    this.adminVisibleVaults,
  });

  final CredentialVisibilityMode mode;
  final String? changedAt;
  final CredentialEscrowStatus escrowStatus;
  final CredentialEscrowKeyDescriptor? escrowKey;
  final List<CredentialEscrowMissingItem> missing;
  final List<CredentialAdminView> adminViews;

  /// How many of this account's Vaults (as `GET /vaults` lists them) are
  /// administrator visible. For a `private` account, a non-zero count means
  /// shared Vaults are readable through another member. Null when the server
  /// does not report it.
  final int? adminVisibleVaults;

  DateTime? get changedAtTime => _parseTimestamp(changedAt);

  factory CredentialVisibilityStatus.fromJson(Map<String, dynamic> json) {
    final body = _exactObject(json, {
      'mode',
      'changed_at',
      'escrow_status',
      'escrow_key',
      'missing',
      'admin_views',
      if (json.containsKey('admin_visible_vaults')) 'admin_visible_vaults',
    }, 'credential visibility');
    final adminVisibleVaults = body['admin_visible_vaults'];
    if (adminVisibleVaults != null &&
        (adminVisibleVaults is! int || adminVisibleVaults < 0)) {
      throw const FormatException('Invalid credential visibility Vault count.');
    }
    final changedAt = body['changed_at'];
    if (changedAt != null && _parseTimestamp(changedAt) == null) {
      throw const FormatException('Invalid credential visibility change time.');
    }
    final rawMissing = body['missing'];
    final rawViews = body['admin_views'];
    if (rawMissing is! List || rawViews is! List || rawViews.length > 200) {
      throw const FormatException('Invalid credential visibility response.');
    }
    final mode = CredentialVisibilityMode.parse(body['mode']);
    final status = CredentialEscrowStatus.parse(body['escrow_status']);
    if ((mode == CredentialVisibilityMode.private) !=
        (status == CredentialEscrowStatus.notRequired)) {
      throw const FormatException('Inconsistent credential escrow status.');
    }
    final escrowKey = body['escrow_key'] == null
        ? null
        : CredentialEscrowKeyDescriptor.fromJson(body['escrow_key']);
    if (status == CredentialEscrowStatus.noKey && escrowKey != null) {
      throw const FormatException('Inconsistent credential escrow status.');
    }
    final missing = [
      for (final item in rawMissing) CredentialEscrowMissingItem.fromJson(item),
    ];
    final seen = <String>{};
    for (final item in missing) {
      if (!seen.add('${item.vaultId}:${item.keyEpoch}')) {
        throw const FormatException('Duplicate credential escrow item.');
      }
    }
    return CredentialVisibilityStatus(
      mode: mode,
      changedAt: changedAt as String?,
      escrowStatus: status,
      escrowKey: escrowKey,
      missing: List.unmodifiable(missing),
      adminViews: List.unmodifiable([
        for (final item in rawViews) CredentialAdminView.fromJson(item),
      ]),
      adminVisibleVaults: adminVisibleVaults as int?,
    );
  }
}

/// `GET /credential-visibility/vaults/{vault}/recipients/{device}`: asked by a
/// Vault owner before sharing with the account behind a device.
class CredentialVisibilityShareRecipient {
  const CredentialVisibilityShareRecipient({
    required this.recipientAdminVisible,
    required this.vaultAdminVisible,
  });

  /// The recipient account is `admin_visible`: administrators can read the
  /// whole Vault once it joins (and its client deposits).
  final bool recipientAdminVisible;

  /// The Vault is administrator visible already (another member).
  final bool vaultAdminVisible;

  factory CredentialVisibilityShareRecipient.fromJson(
    Map<String, dynamic> json,
  ) {
    final body = _exactObject(json, const {
      'recipient_admin_visible',
      'vault_admin_visible',
    }, 'credential visibility share recipient');
    final recipient = body['recipient_admin_visible'];
    final vault = body['vault_admin_visible'];
    if (recipient is! bool || vault is! bool) {
      throw const FormatException(
        'Invalid credential visibility share recipient response.',
      );
    }
    return CredentialVisibilityShareRecipient(
      recipientAdminVisible: recipient,
      vaultAdminVisible: vault,
    );
  }
}

enum CredentialEscrowDepositResult { stored, alreadyPresent }

CredentialEscrowDepositResult parseCredentialEscrowDepositResult(
  Map<String, dynamic> json,
) {
  final body = _exactObject(json, const {
    'status',
  }, 'credential escrow deposit');
  return switch (body['status']) {
    'stored' => CredentialEscrowDepositResult.stored,
    'already_present' => CredentialEscrowDepositResult.alreadyPresent,
    _ => throw const FormatException(
      'Invalid credential escrow deposit status.',
    ),
  };
}

class CredentialVisibilityCounts {
  const CredentialVisibilityCounts({
    required this.adminVisible,
    required this.private,
    required this.pending,
  });

  final int adminVisible;
  final int private;
  final int pending;

  factory CredentialVisibilityCounts.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'admin_visible',
      'private',
      'pending',
    }, 'credential visibility counts');
    return CredentialVisibilityCounts(
      adminVisible: _count(json['admin_visible']),
      private: _count(json['private']),
      pending: _count(json['pending']),
    );
  }
}

/// `GET|PUT /api/v1/admin/credential-visibility`.
class AdminCredentialVisibilityOverview {
  const AdminCredentialVisibilityOverview({
    required this.defaultMode,
    required this.escrowKey,
    required this.callerWrap,
    required this.recoveryWrap,
    required this.counts,
  });

  final CredentialVisibilityMode defaultMode;
  final CredentialEscrowKeyDescriptor? escrowKey;
  final Map<String, dynamic>? callerWrap;
  final Map<String, dynamic>? recoveryWrap;
  final CredentialVisibilityCounts counts;

  factory AdminCredentialVisibilityOverview.fromJson(
    Map<String, dynamic> json,
  ) {
    final body = _exactObject(json, const {
      'default_mode',
      'escrow_key',
      'caller_wrap',
      'recovery_wrap',
      'counts',
    }, 'admin credential visibility');
    final escrowKey = body['escrow_key'] == null
        ? null
        : CredentialEscrowKeyDescriptor.fromJson(body['escrow_key']);
    Map<String, dynamic>? wrap(
      Object? value,
      void Function(Map<String, dynamic>) validate,
    ) {
      if (value == null) return null;
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid credential escrow wrap.');
      }
      final map = Map<String, dynamic>.from(value);
      validate(map);
      return map;
    }

    final callerWrap = wrap(body['caller_wrap'], validateEscrowAccountWrap);
    final recoveryWrap = wrap(
      body['recovery_wrap'],
      (value) => validateEscrowRecoveryWrap(value),
    );
    if (escrowKey == null && (callerWrap != null || recoveryWrap != null)) {
      throw const FormatException('Credential escrow wraps without a key.');
    }
    if (escrowKey != null && recoveryWrap == null) {
      throw const FormatException(
        'Credential escrow recovery wrap is missing.',
      );
    }
    return AdminCredentialVisibilityOverview(
      defaultMode: CredentialVisibilityMode.parse(body['default_mode']),
      escrowKey: escrowKey,
      callerWrap: callerWrap,
      recoveryWrap: recoveryWrap,
      counts: CredentialVisibilityCounts.fromJson(body['counts']),
    );
  }
}

/// `PUT /api/v1/admin/accounts/{user_id}/credential-visibility`.
class AdminCredentialVisibilityAccountReceipt {
  const AdminCredentialVisibilityAccountReceipt({
    required this.userId,
    required this.mode,
    required this.changedAt,
    required this.escrowStatus,
  });

  final String userId;
  final CredentialVisibilityMode mode;
  final String? changedAt;
  final CredentialEscrowStatus escrowStatus;

  factory AdminCredentialVisibilityAccountReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedUserId,
  }) {
    final body = _exactObject(json, const {
      'user_id',
      'mode',
      'changed_at',
      'escrow_status',
    }, 'admin credential visibility account');
    final changedAt = body['changed_at'];
    if (body['user_id'] != expectedUserId ||
        (changedAt != null && _parseTimestamp(changedAt) == null)) {
      throw const FormatException(
        'Invalid admin credential visibility account response.',
      );
    }
    return AdminCredentialVisibilityAccountReceipt(
      userId: expectedUserId,
      mode: CredentialVisibilityMode.parse(body['mode']),
      changedAt: changedAt as String?,
      escrowStatus: CredentialEscrowStatus.parse(body['escrow_status']),
    );
  }
}

class AdminEscrowEnvelope {
  const AdminEscrowEnvelope({
    required this.keyEpoch,
    required this.sealed,
    required this.signature,
    required this.depositorDeviceId,
    required this.depositorSigningPublicKey,
  });

  final int keyEpoch;
  final String sealed;
  final String signature;
  final String? depositorDeviceId;

  /// Null when the server has neither the device row nor the Vault device
  /// archive for the depositor. Such a deposit cannot be verified and is
  /// never trusted (the viewer reports its epoch as failed).
  final String? depositorSigningPublicKey;

  factory AdminEscrowEnvelope.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'key_epoch',
      'sealed',
      'signature',
      'depositor_device_id',
      'depositor_signing_public_key',
    }, 'credential escrow envelope');
    final deviceId = json['depositor_device_id'];
    final depositorKey = json['depositor_signing_public_key'];
    return AdminEscrowEnvelope(
      keyEpoch: _epoch(json['key_epoch']),
      sealed: _nonEmpty(json['sealed'], 'sealed escrow', maxLength: 2048),
      signature: _nonEmpty(json['signature'], 'escrow signature'),
      depositorDeviceId: deviceId == null
          ? null
          : _nonEmpty(deviceId, 'depositor device id', maxLength: 128),
      // The key must be present but may be null (see the field docs).
      depositorSigningPublicKey: depositorKey == null
          ? null
          : _nonEmpty(depositorKey, 'depositor signing key'),
    );
  }
}

class AdminEscrowVault {
  const AdminEscrowVault({
    required this.vaultId,
    required this.role,
    required this.ownerUserId,
    required this.nameEnvelope,
    required this.activeEpoch,
    required this.escrow,
  });

  final String vaultId;
  final String role;
  final String? ownerUserId;
  final Map<String, dynamic>? nameEnvelope;
  final int activeEpoch;
  final List<AdminEscrowEnvelope> escrow;

  factory AdminEscrowVault.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'vault_id',
      'role',
      'owner_user_id',
      'name_envelope',
      'active_epoch',
      'escrow',
    }, 'credential escrow vault');
    final rawEscrow = json['escrow'];
    final nameEnvelope = json['name_envelope'];
    final owner = json['owner_user_id'];
    if (rawEscrow is! List ||
        (nameEnvelope != null &&
            (nameEnvelope is! Map ||
                nameEnvelope.keys.any((key) => key is! String)))) {
      throw const FormatException('Invalid credential escrow vault response.');
    }
    final escrow = [
      for (final item in rawEscrow) AdminEscrowEnvelope.fromJson(item),
    ];
    if (escrow.map((item) => item.keyEpoch).toSet().length != escrow.length) {
      throw const FormatException('Duplicate credential escrow epoch.');
    }
    return AdminEscrowVault(
      vaultId: _uuid(json['vault_id'], 'vault id'),
      role: _nonEmpty(json['role'], 'vault role', maxLength: 32),
      ownerUserId: owner == null ? null : _uuid(owner, 'owner id'),
      nameEnvelope: nameEnvelope == null
          ? null
          : Map<String, dynamic>.from(nameEnvelope as Map),
      activeEpoch: _epoch(json['active_epoch']),
      escrow: List.unmodifiable(escrow),
    );
  }
}

/// `GET /api/v1/admin/credential-escrow/accounts/{user_id}/vaults`.
class AdminEscrowAccountVaults {
  const AdminEscrowAccountVaults({
    required this.userId,
    required this.username,
    required this.mode,
    required this.vaults,
  });

  final String userId;
  final String username;
  final CredentialVisibilityMode mode;
  final List<AdminEscrowVault> vaults;

  factory AdminEscrowAccountVaults.fromJson(
    Map<String, dynamic> json, {
    required String expectedUserId,
  }) {
    final body = _exactObject(json, const {
      'account',
      'vaults',
    }, 'credential escrow account vaults');
    final account = _exactObject(body['account'], const {
      'user_id',
      'username',
      'mode',
    }, 'credential escrow account');
    final rawVaults = body['vaults'];
    if (account['user_id'] != expectedUserId || rawVaults is! List) {
      throw const FormatException(
        'Invalid credential escrow account vaults response.',
      );
    }
    final vaults = [
      for (final item in rawVaults) AdminEscrowVault.fromJson(item),
    ];
    if (vaults.map((vault) => vault.vaultId).toSet().length != vaults.length) {
      throw const FormatException('Duplicate credential escrow vault.');
    }
    return AdminEscrowAccountVaults(
      userId: expectedUserId,
      username: _nonEmpty(account['username'], 'username'),
      mode: CredentialVisibilityMode.parse(account['mode']),
      vaults: List.unmodifiable(vaults),
    );
  }
}

class AdminEscrowRecord {
  const AdminEscrowRecord({
    required this.recordId,
    required this.revisionId,
    required this.envelope,
    required this.authorDeviceId,
    required this.authorSigningPublicKey,
  });

  final String recordId;
  final String revisionId;
  final Map<String, dynamic> envelope;
  final String? authorDeviceId;

  /// Null when the server has neither the device row nor the Vault device
  /// archive for the author. Such a record cannot be verified and is counted
  /// as undecryptable.
  final String? authorSigningPublicKey;

  factory AdminEscrowRecord.fromJson(Object? value) {
    final json = _exactObject(value, const {
      'record_id',
      'revision_id',
      'envelope',
      'author_device_id',
      'author_signing_public_key',
    }, 'credential escrow record');
    final envelope = json['envelope'];
    final author = json['author_device_id'];
    final authorKey = json['author_signing_public_key'];
    if (envelope is! Map || envelope.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid credential escrow record envelope.');
    }
    return AdminEscrowRecord(
      recordId: _nonEmpty(json['record_id'], 'record id', maxLength: 128),
      revisionId: _nonEmpty(json['revision_id'], 'revision id', maxLength: 128),
      envelope: Map<String, dynamic>.from(envelope),
      authorDeviceId: author == null
          ? null
          : _nonEmpty(author, 'author device id', maxLength: 128),
      // The key must be present but may be null (see the field docs).
      authorSigningPublicKey: authorKey == null
          ? null
          : _nonEmpty(authorKey, 'author signing key'),
    );
  }
}

/// `GET /api/v1/admin/credential-escrow/vaults/{vault_id}/records`.
class AdminEscrowRecordsPage {
  const AdminEscrowRecordsPage({required this.records, this.nextAfter});

  final List<AdminEscrowRecord> records;
  final String? nextAfter;

  factory AdminEscrowRecordsPage.fromJson(
    Map<String, dynamic> json, {
    required int limit,
  }) {
    final body = _exactObject(json, const {
      'records',
      'next_after',
    }, 'credential escrow records');
    final rawRecords = body['records'];
    final nextAfter = body['next_after'];
    if (rawRecords is! List ||
        rawRecords.length > limit ||
        (nextAfter != null && (nextAfter is! String || nextAfter.isEmpty))) {
      throw const FormatException(
        'Invalid credential escrow records response.',
      );
    }
    final records = [
      for (final item in rawRecords) AdminEscrowRecord.fromJson(item),
    ];
    for (var i = 1; i < records.length; i++) {
      if (records[i - 1].recordId.compareTo(records[i].recordId) >= 0) {
        throw const FormatException(
          'Credential escrow records are not ordered.',
        );
      }
    }
    return AdminEscrowRecordsPage(
      records: List.unmodifiable(records),
      nextAfter: nextAfter as String?,
    );
  }
}
