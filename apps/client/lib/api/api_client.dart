import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../attachments/attachment_file_saver.dart'
    show supportsStreamingAttachmentSave;
import 'browser_offline_signal.dart' as browser;
import '../domain/conflict_feed.dart';
import '../l10n/l10n.dart';

const _clientCapabilityMarkerHeader = 'X-Atermius-Capability-Marker';
const _clientRedactionMarkerHeader = 'X-Atermius-Redaction-Marker';

String get _clientCapabilityMarker =>
    supportsStreamingAttachmentSave ? 'v2' : 'v1';

class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
    this.details = const {},
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;
  final Map<String, dynamic> details;

  bool get isRetryable =>
      statusCode >= 500 || statusCode == 408 || statusCode == 429;

  @override
  String toString() => '$code: $message';
}

/// A safe, repeatable GET failed before an HTTP response was received.
/// Mutations are intentionally never represented by this exception because a
/// lost response cannot tell the client whether the server committed them.
class ApiTransportException implements Exception {
  const ApiTransportException({required this.method, required this.path});

  final String method;
  final String path;

  @override
  String toString() => 'The server could not be reached for this request.';
}

/// A read-only Vault sync request failed before the HTTP client received any
/// response headers. This is intentionally distinct from HTTP errors,
/// response-body failures and timeouts, all of which remain fail-closed for
/// KnownHost decisions.
class SyncReadTransportUnavailableException implements Exception {
  const SyncReadTransportUnavailableException({required this.path});

  final String path;

  @override
  String toString() => 'Vault sync read received no HTTP response.';
}

class InstanceInfo {
  const InstanceInfo({
    required this.instanceId,
    required this.serverSpaceId,
    required this.generation,
    required this.protocolVersion,
    required this.setupRequired,
    required this.capabilities,
    this.restoreRetentionDays,
    this.limits = const {},
    this.signingPublicKey = '',
    this.signingKeyTransitions = const [],
  });

  final String instanceId;
  final String serverSpaceId;
  final String generation;
  final int protocolVersion;
  final bool setupRequired;
  final List<String> capabilities;

  /// Advertised upper bound for explicit record restores, when supported by
  /// the connected server. Absence keeps older server versions readable.
  final int? restoreRetentionDays;
  final Map<String, dynamic> limits;
  final String signingPublicKey;
  final List<Map<String, dynamic>> signingKeyTransitions;

  factory InstanceInfo.fromJson(Map<String, dynamic> json) {
    final rawTransitions = json['signing_key_transitions'] ?? const <dynamic>[];
    if (rawTransitions is! List) {
      throw const FormatException('Instance key transition chain is invalid.');
    }
    final rawLimits = json['limits'];
    final limits = rawLimits is Map
        ? Map<String, dynamic>.from(rawLimits)
        : const <String, dynamic>{};
    final rawRestoreRetentionDays =
        json['restore_retention_days'] ?? limits['restore_retention_days'];
    if (rawRestoreRetentionDays != null &&
        (rawRestoreRetentionDays is! int ||
            rawRestoreRetentionDays < 1 ||
            rawRestoreRetentionDays > 36500)) {
      throw const FormatException('Instance restore retention is invalid.');
    }
    return InstanceInfo(
      instanceId: json['instance_id'] as String,
      serverSpaceId: json['server_space_id'] as String,
      generation: json['generation'].toString(),
      protocolVersion: (json['protocol_version'] as num).toInt(),
      setupRequired: json['setup_required'] as bool? ?? false,
      capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
          .cast<String>(),
      restoreRetentionDays: rawRestoreRetentionDays as int?,
      limits: limits,
      signingPublicKey: json['signing_public_key'] as String? ?? '',
      signingKeyTransitions: rawTransitions
          .map((transition) => Map<String, dynamic>.from(transition as Map))
          .toList(growable: false),
    );
  }
}

class NotificationTicket {
  const NotificationTicket({
    required this.ticket,
    required this.expiresAt,
    required this.expiresInSeconds,
  });

  final String ticket;
  final DateTime expiresAt;
  final int expiresInSeconds;

  factory NotificationTicket.fromJson(Map<String, dynamic> json) {
    final ticket = json['ticket'];
    final expiresAtValue = json['expires_at'];
    final expiresInSeconds = json['expires_in_seconds'];
    if (ticket is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(ticket) ||
        expiresAtValue is! String ||
        expiresInSeconds is! int ||
        expiresInSeconds < 1) {
      throw const FormatException('Invalid notification ticket response.');
    }
    List<int>? ticketBytes;
    try {
      ticketBytes = base64Url.decode(base64Url.normalize(ticket));
      final canonicalTicket = base64Url.encode(ticketBytes).replaceAll('=', '');
      if (ticketBytes.length != 32 || canonicalTicket != ticket) {
        throw const FormatException('Invalid notification ticket encoding.');
      }
    } on FormatException {
      throw const FormatException('Invalid notification ticket encoding.');
    } finally {
      ticketBytes?.fillRange(0, ticketBytes.length, 0);
    }
    final expiresAt = DateTime.tryParse(expiresAtValue);
    if (expiresAt == null) {
      throw const FormatException('Invalid notification ticket expiry.');
    }
    return NotificationTicket(
      ticket: ticket,
      expiresAt: expiresAt.toUtc(),
      expiresInSeconds: expiresInSeconds,
    );
  }
}

class MobilePushEndpointResult {
  const MobilePushEndpointResult({
    required this.status,
    required this.deviceId,
    required this.provider,
  });

  final String status;
  final String deviceId;
  final String provider;

  factory MobilePushEndpointResult.fromJson(
    Map<String, dynamic> json, {
    required String expectedStatus,
    required String expectedDeviceId,
    required String expectedProvider,
  }) {
    if (json.length != 3 ||
        json['status'] != expectedStatus ||
        json['device_id'] != expectedDeviceId ||
        json['provider'] != expectedProvider) {
      throw const FormatException('Invalid mobile push endpoint response.');
    }
    return MobilePushEndpointResult(
      status: expectedStatus,
      deviceId: expectedDeviceId,
      provider: expectedProvider,
    );
  }
}

class RelayTicket {
  const RelayTicket({required this.value, required this.expiresAt});

  final String value;
  final DateTime expiresAt;

  factory RelayTicket.fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final value = json['ticket'];
    final expiresAtText = json['expires_at'];
    final connectPath = json['connect_path'];
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value) ||
        expiresAtText is! String ||
        connectPath != '/relay/v1/connect') {
      throw const FormatException('Invalid SSH relay ticket response.');
    }

    Uint8List? decoded;
    try {
      decoded = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(value)),
      );
      if (decoded.length != 32 ||
          base64Url.encode(decoded).replaceAll('=', '') != value) {
        throw const FormatException('Invalid SSH relay ticket encoding.');
      }
    } on FormatException {
      throw const FormatException('Invalid SSH relay ticket encoding.');
    } finally {
      decoded?.fillRange(0, decoded.length, 0);
    }

    final rfc3339 = RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
    );
    final parsedExpiry = DateTime.tryParse(expiresAtText);
    final currentTime = (now ?? DateTime.now()).toUtc();
    final expiresAt = parsedExpiry?.toUtc();
    if (expiresAt == null ||
        !rfc3339.hasMatch(expiresAtText) ||
        !expiresAt.isAfter(currentTime) ||
        expiresAt.isAfter(currentTime.add(const Duration(seconds: 35)))) {
      throw const FormatException(
        'SSH relay ticket is expired or not short-lived.',
      );
    }
    return RelayTicket(value: value, expiresAt: expiresAt);
  }
}

class AuditEvent {
  const AuditEvent({
    required this.eventId,
    required this.scope,
    required this.vaultId,
    required this.actorUserId,
    required this.actorDeviceId,
    required this.action,
    required this.resourceType,
    required this.resourceId,
    required this.result,
    required this.occurredAt,
    required this.source,
  });

  final String eventId;
  final String scope;
  final String? vaultId;
  final String? actorUserId;
  final String? actorDeviceId;
  final String action;
  final String resourceType;
  final String? resourceId;
  final String result;
  final DateTime occurredAt;
  final String source;

  factory AuditEvent.fromJson(Map<String, dynamic> json) {
    String requiredString(String name) {
      if (!json.containsKey(name)) {
        throw FormatException('Audit event is missing $name.');
      }
      final value = json[name];
      if (value is! String || value.isEmpty) {
        throw FormatException('Audit event is missing $name.');
      }
      return value;
    }

    String? nullableString(String name) {
      if (!json.containsKey(name)) {
        throw FormatException('Audit event is missing $name.');
      }
      final value = json[name];
      if (value != null && value is! String) {
        throw FormatException('Audit event $name must be a string or null.');
      }
      return value as String?;
    }

    final eventId = requiredString('event_id');
    final scope = requiredString('scope');
    final vaultId = nullableString('vault_id');
    final actorUserId = nullableString('actor_user_id');
    final actorDeviceId = nullableString('actor_device_id');
    final action = requiredString('action');
    final resourceType = requiredString('resource_type');
    final resourceId = nullableString('resource_id');
    final result = requiredString('result');
    final source = requiredString('source');
    final occurredAtText = requiredString('occurred_at');
    final occurredAt = DateTime.tryParse(occurredAtText);
    const canonicalUuid =
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    final rfc3339DateTime = RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
    );
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(eventId) ||
        !const {'account', 'vault'}.contains(scope) ||
        (scope == 'account' && vaultId != null) ||
        (scope == 'vault' && vaultId == null) ||
        (vaultId != null &&
            !RegExp(canonicalUuid, caseSensitive: false).hasMatch(vaultId)) ||
        (actorUserId != null &&
            !RegExp(
              canonicalUuid,
              caseSensitive: false,
            ).hasMatch(actorUserId)) ||
        (actorDeviceId != null &&
            !RegExp(
              canonicalUuid,
              caseSensitive: false,
            ).hasMatch(actorDeviceId)) ||
        !const {'success', 'failure'}.contains(result) ||
        !const {'api', 'maintenance'}.contains(source) ||
        occurredAt == null ||
        !rfc3339DateTime.hasMatch(occurredAtText)) {
      throw const FormatException('Audit event contains invalid fields.');
    }
    return AuditEvent(
      eventId: eventId,
      scope: scope,
      vaultId: vaultId,
      actorUserId: actorUserId,
      actorDeviceId: actorDeviceId,
      action: action,
      resourceType: resourceType,
      resourceId: resourceId,
      result: result,
      occurredAt: occurredAt.toUtc(),
      source: source,
    );
  }
}

class VaultPresenceDevice {
  const VaultPresenceDevice({
    required this.userId,
    required this.deviceId,
    required this.lastSeenAt,
  });

  final String userId;
  final String deviceId;
  final DateTime lastSeenAt;

  factory VaultPresenceDevice.fromJson(Map<String, dynamic> json) {
    const requiredKeys = {'user_id', 'device_id', 'last_seen_at'};
    if (json.keys.toSet().difference(requiredKeys).isNotEmpty ||
        !json.keys.toSet().containsAll(requiredKeys)) {
      throw const FormatException('Invalid Vault presence response fields.');
    }
    final userId = json['user_id'];
    final deviceId = json['device_id'];
    final timestamp = json['last_seen_at'];
    final lastSeenAt = timestamp is String
        ? DateTime.tryParse(timestamp)
        : null;
    if (userId is! String ||
        !_isCanonicalLowercaseUuid(userId) ||
        deviceId is! String ||
        !_isCanonicalLowercaseUuid(deviceId) ||
        lastSeenAt == null ||
        lastSeenAt.isUtc == false) {
      throw const FormatException('Invalid Vault presence response.');
    }
    return VaultPresenceDevice(
      userId: userId,
      deviceId: deviceId,
      lastSeenAt: lastSeenAt,
    );
  }
}

class VaultPresenceSnapshot {
  const VaultPresenceSnapshot({
    required this.devices,
    required this.ttlSeconds,
  });

  final List<VaultPresenceDevice> devices;
  final int ttlSeconds;

  factory VaultPresenceSnapshot.fromJson(Map<String, dynamic> json) {
    final rawDevices = json['devices'];
    final ttlSeconds = json['ttl_seconds'];
    if (json.keys.toSet().difference(const {
          'devices',
          'ttl_seconds',
        }).isNotEmpty ||
        json.length != 2 ||
        rawDevices is! List ||
        ttlSeconds != 90) {
      throw const FormatException('Invalid Vault presence snapshot.');
    }
    final devices = <VaultPresenceDevice>[];
    for (final item in rawDevices) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid Vault presence snapshot.');
      }
      devices.add(
        VaultPresenceDevice.fromJson(Map<String, dynamic>.from(item)),
      );
    }
    return VaultPresenceSnapshot(
      devices: List.unmodifiable(devices),
      ttlSeconds: ttlSeconds as int,
    );
  }
}

class AuditPage {
  const AuditPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AuditEvent> events;
  final String? nextCursor;
  final bool hasMore;

  factory AuditPage.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    final rawNextCursor = json['next_cursor'];
    final hasMore = json['has_more'];
    if (!json.containsKey('events') ||
        !json.containsKey('next_cursor') ||
        !json.containsKey('has_more') ||
        rawEvents is! List ||
        (rawNextCursor != null && rawNextCursor is! String) ||
        (rawNextCursor is String && rawNextCursor.isEmpty) ||
        hasMore is! bool ||
        (hasMore && (rawNextCursor as String?)?.isNotEmpty != true)) {
      throw const FormatException('Invalid audit page response.');
    }
    final events = <AuditEvent>[];
    for (final item in rawEvents) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid audit event response.');
      }
      events.add(AuditEvent.fromJson(Map<String, dynamic>.from(item)));
    }
    return AuditPage(
      events: List.unmodifiable(events),
      nextCursor: rawNextCursor as String?,
      hasMore: hasMore,
    );
  }
}

class VaultDescriptor {
  const VaultDescriptor({
    required this.id,
    required this.role,
    required this.activeKeyEpoch,
    required this.membershipVersion,
    this.encryptedDisplayNameEnvelope,
    this.keyEnvelopes = const [],
    this.status = 'active',
    this.requestedAt,
    this.purgeAfter,
    this.canCancel = false,
    this.canWrite = true,
  });

  final String id;
  final String role;
  final String activeKeyEpoch;
  final String membershipVersion;
  final Map<String, dynamic>? encryptedDisplayNameEnvelope;
  final List<Map<String, dynamic>> keyEnvelopes;
  final String status;
  final String? requestedAt;
  final String? purgeAfter;
  final bool canCancel;
  final bool canWrite;

  factory VaultDescriptor.fromJson(
    Map<String, dynamic> json,
  ) => VaultDescriptor(
    id: json['vault_id'] as String? ?? json['id'] as String,
    role: json['role'] as String? ?? 'member',
    activeKeyEpoch: json['active_key_epoch']?.toString() ?? '1',
    membershipVersion: json['membership_version']?.toString() ?? '1',
    encryptedDisplayNameEnvelope:
        (json['name_envelope'] ?? json['encrypted_display_name_envelope']) ==
            null
        ? null
        : Map<String, dynamic>.from(
            (json['name_envelope'] ?? json['encrypted_display_name_envelope'])
                as Map,
          ),
    keyEnvelopes: (json['key_envelopes'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false),
    status: json['status'] as String? ?? 'active',
    requestedAt: json['requested_at'] as String?,
    purgeAfter: json['purge_after'] as String?,
    canCancel: json['can_cancel'] as bool? ?? false,
    canWrite:
        json['can_write'] as bool? ??
        (json['status'] == null || json['status'] == 'active'),
  );

  VaultDescriptor withLifecycleFrom(VaultDescriptor remote) => VaultDescriptor(
    id: id,
    role: remote.role,
    activeKeyEpoch: activeKeyEpoch,
    membershipVersion: membershipVersion,
    encryptedDisplayNameEnvelope: encryptedDisplayNameEnvelope,
    keyEnvelopes: keyEnvelopes,
    status: remote.status,
    requestedAt: remote.requestedAt,
    purgeAfter: remote.purgeAfter,
    canCancel: remote.canCancel,
    canWrite: remote.canWrite,
  );

  VaultDescriptor withLifecycleResponse(Map<String, dynamic> json) {
    final responseId = json['vault_id'];
    if (responseId != id) {
      throw const FormatException(
        'Vault lifecycle response has a different vault_id.',
      );
    }
    final remoteStatus = json['status'];
    final remoteCanCancel = json['can_cancel'];
    final remoteCanWrite = json['can_write'];
    if (remoteStatus is! String ||
        remoteCanCancel is! bool ||
        remoteCanWrite is! bool) {
      throw const FormatException(
        'Vault lifecycle response is missing required state fields.',
      );
    }
    return VaultDescriptor(
      id: id,
      role: role,
      activeKeyEpoch: activeKeyEpoch,
      membershipVersion: membershipVersion,
      encryptedDisplayNameEnvelope: encryptedDisplayNameEnvelope,
      keyEnvelopes: keyEnvelopes,
      status: remoteStatus,
      requestedAt: json['requested_at'] as String?,
      purgeAfter: json['purge_after'] as String?,
      canCancel: remoteCanCancel,
      canWrite: remoteCanWrite,
    );
  }
}

class AuthSession {
  const AuthSession({
    required this.accountId,
    required this.accessToken,
    required this.expiresIn,
    required this.refreshToken,
    required this.deviceId,
    required this.vaults,
  });

  final String accountId;
  final String accessToken;
  final int expiresIn;
  final String refreshToken;
  final String deviceId;
  final List<VaultDescriptor> vaults;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    accountId: json['account_id'] as String,
    accessToken: json['access_token'] as String,
    expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
    refreshToken: json['refresh_token'] as String,
    deviceId: json['device_id'] as String,
    vaults: (json['vaults'] as List<dynamic>? ?? const [])
        .map(
          (e) => VaultDescriptor.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(growable: false),
  );
}

sealed class AuthLoginResult {
  const AuthLoginResult();

  factory AuthLoginResult.fromJson(Map<String, dynamic> json) {
    if (json['mfa_required'] == true) {
      return MfaLoginChallenge.fromJson(json);
    }
    if (json.containsKey('mfa_required')) {
      throw const FormatException('Invalid MFA login challenge response.');
    }
    return AuthenticatedLogin(AuthSession.fromJson(json));
  }
}

class AuthenticatedLogin extends AuthLoginResult {
  const AuthenticatedLogin(this.session);

  final AuthSession session;
}

class MfaLoginChallenge extends AuthLoginResult {
  const MfaLoginChallenge({
    required this.challengeId,
    required this.expiresAt,
    required this.methods,
  });

  final String challengeId;
  final DateTime expiresAt;
  final Set<String> methods;

  factory MfaLoginChallenge.fromJson(Map<String, dynamic> json) {
    final challengeId = json['challenge_id'];
    final expiresAt = json['expires_at'];
    final methodsValue = json['methods'];
    if (challengeId is! String ||
        challengeId.isEmpty ||
        expiresAt is! String ||
        methodsValue is! List) {
      throw const FormatException('Invalid MFA login challenge response.');
    }
    final parsedExpiry = DateTime.tryParse(expiresAt);
    final methods = <String>{};
    for (final method in methodsValue) {
      if (method is! String ||
          !const {'totp', 'recovery_code'}.contains(method) ||
          !methods.add(method)) {
        throw const FormatException('Invalid MFA challenge methods.');
      }
    }
    if (parsedExpiry == null ||
        methods.length != 2 ||
        !methods.contains('totp') ||
        !methods.contains('recovery_code')) {
      throw const FormatException('Invalid MFA login challenge response.');
    }
    return MfaLoginChallenge(
      challengeId: challengeId,
      expiresAt: parsedExpiry,
      methods: Set.unmodifiable(methods),
    );
  }
}

class AccountMfaStatus {
  const AccountMfaStatus({
    required this.enabled,
    required this.recoveryCodesRemaining,
  });

  final bool enabled;
  final int recoveryCodesRemaining;

  factory AccountMfaStatus.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final remaining = json['recovery_codes_remaining'];
    if (enabled is! bool ||
        remaining is! num ||
        remaining < 0 ||
        remaining != remaining.round()) {
      throw const FormatException('Invalid account MFA status response.');
    }
    return AccountMfaStatus(
      enabled: enabled,
      recoveryCodesRemaining: remaining.toInt(),
    );
  }
}

/// MFA enrollment material is intentionally mutable so callers can drop the
/// only retained references immediately after the transient setup dialog ends.
class MfaTotpSetup {
  MfaTotpSetup({
    required String secret,
    required String provisioningUri,
    required this.expiresAt,
  }) : _secret = secret,
       _provisioningUri = provisioningUri;

  String? _secret;
  String? _provisioningUri;
  final DateTime expiresAt;

  String? get secret => _secret;
  String? get provisioningUri => _provisioningUri;

  void clear() {
    _secret = null;
    _provisioningUri = null;
  }

  factory MfaTotpSetup.fromJson(Map<String, dynamic> json) {
    final secret = json['secret'];
    final provisioningUri = json['provisioning_uri'];
    final expiresAt = json['expires_at'];
    if (secret is! String ||
        !RegExp(r'^[A-Z2-7]{32}$').hasMatch(secret) ||
        provisioningUri is! String ||
        expiresAt is! String) {
      throw const FormatException('Invalid TOTP enrollment response.');
    }
    final uri = Uri.tryParse(provisioningUri);
    final parsedExpiry = DateTime.tryParse(expiresAt);
    if (uri == null ||
        uri.scheme != 'otpauth' ||
        uri.host != 'totp' ||
        uri.queryParameters['secret'] != secret ||
        parsedExpiry == null) {
      throw const FormatException('Invalid TOTP provisioning response.');
    }
    return MfaTotpSetup(
      secret: secret,
      provisioningUri: provisioningUri,
      expiresAt: parsedExpiry,
    );
  }
}

/// One-time plaintext MFA recovery codes. The caller must show them once,
/// require save confirmation, and then call [clear].
class MfaRecoveryCodes {
  MfaRecoveryCodes(List<String> codes) : codes = List.of(codes);

  final List<String> codes;

  void clear() {
    for (var index = 0; index < codes.length; index++) {
      codes[index] = '';
    }
    codes.clear();
  }

  factory MfaRecoveryCodes.fromJson(Map<String, dynamic> json) {
    final value = json['recovery_codes'];
    if (value is! List || value.length != 10) {
      throw const FormatException('Invalid one-time MFA recovery codes.');
    }
    final codes = <String>[];
    for (final item in value) {
      if (item is! String ||
          !RegExp(r'^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$').hasMatch(item) ||
          codes.contains(item)) {
        throw const FormatException('Invalid one-time MFA recovery codes.');
      }
      codes.add(item);
    }
    return MfaRecoveryCodes(codes);
  }
}

class AccountDeletionState {
  const AccountDeletionState({
    required this.status,
    required this.requestedAt,
    required this.purgeAfter,
    required this.canCancel,
  });

  final String status;
  final String? requestedAt;
  final String? purgeAfter;
  final bool canCancel;

  factory AccountDeletionState.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final requestedAt = json['requested_at'];
    final purgeAfter = json['purge_after'];
    final canCancel = json['can_cancel'];
    if (status is! String ||
        (requestedAt != null && requestedAt is! String) ||
        (purgeAfter != null && purgeAfter is! String) ||
        canCancel is! bool) {
      throw const FormatException('Invalid account deletion lifecycle DTO.');
    }
    return AccountDeletionState(
      status: status,
      requestedAt: requestedAt as String?,
      purgeAfter: purgeAfter as String?,
      canCancel: canCancel,
    );
  }
}

class AccountProfile {
  const AccountProfile({
    required this.accountId,
    required this.deviceId,
    required this.accountKeyEnvelopeVersion,
    required this.accountKeyEnvelope,
    this.recoveryStatus = 'disabled',
    this.policy = const {},
  });

  final String accountId;
  final String deviceId;
  final int accountKeyEnvelopeVersion;
  final Map<String, dynamic> accountKeyEnvelope;
  final String recoveryStatus;
  final Map<String, dynamic> policy;

  factory AccountProfile.fromJson(Map<String, dynamic> json) => AccountProfile(
    accountId: json['account_id'] as String,
    deviceId: json['device_id'] as String,
    accountKeyEnvelopeVersion: (json['account_key_envelope_version'] as num)
        .toInt(),
    accountKeyEnvelope: Map<String, dynamic>.from(
      json['account_key_envelope'] as Map,
    ),
    recoveryStatus: json['recovery_status'] as String? ?? 'disabled',
    policy: Map<String, dynamic>.from(json['policy'] as Map? ?? const {}),
  );
}

class AccountRecoveryContext {
  const AccountRecoveryContext({
    required this.vaultId,
    required this.keyEpoch,
    this.membershipVersion,
  });

  final String vaultId;
  final int keyEpoch;
  final int? membershipVersion;

  factory AccountRecoveryContext.fromJson(Map<String, dynamic> json) {
    final vaultId = json['vault_id'];
    final keyEpoch = json['key_epoch'];
    final membershipVersion = json['membership_version'];
    if (vaultId is! String ||
        vaultId.isEmpty ||
        keyEpoch is! num ||
        keyEpoch < 1 ||
        (membershipVersion != null &&
            (membershipVersion is! num || membershipVersion < 1))) {
      throw const FormatException('Invalid account recovery context.');
    }
    return AccountRecoveryContext(
      vaultId: vaultId,
      keyEpoch: keyEpoch.toInt(),
      membershipVersion: (membershipVersion as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'vault_id': vaultId,
    'key_epoch': keyEpoch,
    if (membershipVersion != null) 'membership_version': membershipVersion,
  };

  String get logicalKey => '$vaultId:$keyEpoch';
}

class AccountRecoveryContexts {
  const AccountRecoveryContexts({
    required this.generation,
    required this.required,
    required this.present,
    required this.status,
    this.identityEnvelope,
    this.recoveryPublicSigningKey,
    this.recoveryPublicEncryptionKey,
    this.descriptorHash,
    this.keyEnvelopes = const [],
  });

  final int generation;
  final List<AccountRecoveryContext> required;
  final List<AccountRecoveryContext> present;
  final String status;
  final Map<String, dynamic>? identityEnvelope;
  final String? recoveryPublicSigningKey;
  final String? recoveryPublicEncryptionKey;
  final String? descriptorHash;
  final List<Map<String, dynamic>> keyEnvelopes;

  factory AccountRecoveryContexts.fromJson(Map<String, dynamic> json) {
    final generation = json['recovery_generation'];
    final status = json['recovery_status'] ?? json['status'];
    final required = json['required_contexts'];
    final present = json['present_contexts'];
    final identityEnvelope = json['recovery_identity_envelope'];
    final signingKey = json['recovery_public_signing_key'];
    final encryptionKey = json['recovery_public_encryption_key'];
    final descriptorHash =
        json['recovery_descriptor_hash'] ?? json['descriptor_hash'];
    final rawBoxes =
        json['key_envelopes'] ?? json['recovery_key_envelopes'] ?? const [];
    if (generation is! num ||
        generation < 0 ||
        status is! String ||
        !const {
          'disabled',
          'current',
          'stale',
          'incomplete',
        }.contains(status) ||
        required is! List ||
        present is! List ||
        (identityEnvelope != null && identityEnvelope is! Map) ||
        (signingKey != null && signingKey is! String) ||
        (encryptionKey != null && encryptionKey is! String) ||
        (descriptorHash != null && descriptorHash is! String) ||
        rawBoxes is! List) {
      throw const FormatException(
        'Invalid account recovery contexts response.',
      );
    }
    return AccountRecoveryContexts(
      generation: generation.toInt(),
      required: required
          .map(
            (item) => AccountRecoveryContext.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
      present: present
          .map(
            (item) => AccountRecoveryContext.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
      status: status,
      identityEnvelope: identityEnvelope == null
          ? null
          : Map<String, dynamic>.from(identityEnvelope as Map),
      recoveryPublicSigningKey: signingKey as String?,
      recoveryPublicEncryptionKey: encryptionKey as String?,
      descriptorHash: descriptorHash as String?,
      keyEnvelopes: rawBoxes
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false),
    );
  }
}

/// Read-only instance-wide status exposed to accounts on the admin allowlist.
/// The endpoint is still protected by the server; this DTO only describes the
/// data returned when that authorization succeeds.
class InstanceAdminOverview {
  const InstanceAdminOverview({
    required this.instanceId,
    required this.serverSpaceId,
    required this.generation,
    required this.protocolVersion,
    required this.accountsTotal,
    required this.accountsActive,
    required this.accountsDisabled,
    required this.accountsDeleting,
    required this.devicesActive,
    required this.vaultsActive,
    required this.vaultsDeleting,
    required this.storedBytes,
    required this.reservedUploadBytes,
    required this.vaultQuotaBytes,
    required this.relayEnabled,
    required this.relayAllowCidrs,
    required this.relayAllowPorts,
    required this.relayMaxConnectionsPerUser,
    required this.generatedAt,
  });

  final String instanceId;
  final String serverSpaceId;
  final String generation;
  final int protocolVersion;
  final int accountsTotal;
  final int accountsActive;
  final int accountsDisabled;
  final int accountsDeleting;
  final int devicesActive;
  final int vaultsActive;
  final int vaultsDeleting;
  final int storedBytes;
  final int reservedUploadBytes;
  final int vaultQuotaBytes;
  final bool relayEnabled;
  final List<String> relayAllowCidrs;
  final List<int> relayAllowPorts;
  final int relayMaxConnectionsPerUser;
  final DateTime generatedAt;

  factory InstanceAdminOverview.fromJson(Map<String, dynamic> json) {
    final instance = json['instance'];
    final counts = json['counts'];
    final relay = json['relay'];
    final generatedAtValue = json['generated_at'];
    if (instance is! Map || counts is! Map || relay is! Map) {
      throw const FormatException('Invalid instance admin overview response.');
    }
    final instanceJson = Map<String, dynamic>.from(instance);
    final countsJson = Map<String, dynamic>.from(counts);
    final relayJson = Map<String, dynamic>.from(relay);
    String stringField(Map<String, dynamic> value, String key) {
      final field = value[key];
      if (field is! String || field.isEmpty) {
        throw FormatException('Instance admin overview is missing $key.');
      }
      return field;
    }

    int integerField(Map<String, dynamic> value, String key) {
      final field = value[key];
      if (field is! int || field < 0) {
        throw FormatException('Instance admin overview has invalid $key.');
      }
      return field;
    }

    final protocolVersion = integerField(instanceJson, 'protocol_version');
    final relayEnabled = relayJson['enabled'];
    final rawCidrs = relayJson['allow_cidrs'];
    final rawPorts = relayJson['allow_ports'];
    final generatedAt = generatedAtValue is String
        ? DateTime.tryParse(generatedAtValue)
        : null;
    if (protocolVersion < 1 ||
        relayEnabled is! bool ||
        rawCidrs is! List ||
        rawCidrs.any((value) => value is! String) ||
        rawPorts is! List ||
        rawPorts.any((value) => value is! int || value < 1 || value > 65535) ||
        generatedAt == null) {
      throw const FormatException('Invalid instance admin overview response.');
    }
    return InstanceAdminOverview(
      instanceId: stringField(instanceJson, 'instance_id'),
      serverSpaceId: stringField(instanceJson, 'server_space_id'),
      generation: stringField(instanceJson, 'generation'),
      protocolVersion: protocolVersion,
      accountsTotal: integerField(countsJson, 'accounts_total'),
      accountsActive: integerField(countsJson, 'accounts_active'),
      accountsDisabled: integerField(countsJson, 'accounts_disabled'),
      accountsDeleting: integerField(countsJson, 'accounts_deleting'),
      devicesActive: integerField(countsJson, 'devices_active'),
      vaultsActive: integerField(countsJson, 'vaults_active'),
      vaultsDeleting: integerField(countsJson, 'vaults_deleting'),
      storedBytes: integerField(countsJson, 'stored_bytes'),
      reservedUploadBytes: integerField(countsJson, 'reserved_upload_bytes'),
      vaultQuotaBytes: integerField(countsJson, 'vault_quota_bytes'),
      relayEnabled: relayEnabled,
      relayAllowCidrs: List<String>.from(rawCidrs),
      relayAllowPorts: List<int>.from(rawPorts),
      relayMaxConnectionsPerUser: integerField(
        relayJson,
        'max_connections_per_user',
      ),
      generatedAt: generatedAt.toUtc(),
    );
  }
}

/// Aggregate, read-only health snapshot for the configured push providers.
///
/// The server intentionally returns provider totals only. This type has no
/// user or endpoint identity fields, and its closed JSON shape rejects any
/// accidental expansion to per-device data.
class InstanceAdminPushHealth {
  const InstanceAdminPushHealth({
    required this.generatedAt,
    required this.deliveryStartDateUtc,
    required this.deliveryEndDateUtc,
    required this.deliveryWindowAvailable,
    required this.providers,
  });

  final DateTime generatedAt;
  final String deliveryStartDateUtc;
  final String deliveryEndDateUtc;
  final bool deliveryWindowAvailable;
  final List<InstanceAdminPushProviderHealth> providers;

  factory InstanceAdminPushHealth.fromJson(Map<String, dynamic> json) {
    final currentShape = json.length == 3 &&
        json.keys.toSet().containsAll(const {
          'generated_at',
          'delivery_window',
          'providers',
        });
    final legacyShape = json.length == 2 &&
        json.keys.toSet().containsAll(const {'generated_at', 'providers'});
    if (!currentShape && !legacyShape) {
      throw const FormatException('Invalid admin push health response.');
    }
    final generatedAtValue = json['generated_at'];
    final rawWindow = json['delivery_window'];
    final rawProviders = json['providers'];
    final generatedAt =
        generatedAtValue is String &&
            RegExp(
              r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
            ).hasMatch(generatedAtValue)
        ? DateTime.tryParse(generatedAtValue)
        : null;
    if (generatedAt == null ||
        (currentShape &&
            (rawWindow is! Map || rawWindow.keys.any((key) => key is! String))) ||
        rawProviders is! List) {
      throw const FormatException('Invalid admin push health response.');
    }
    var startDateUtc = '';
    var endDateUtc = '';
    if (currentShape) {
      final window = Map<String, dynamic>.from(rawWindow as Map);
      if (window.length != 3 ||
          !window.keys.toSet().containsAll(const {
            'days',
            'start_date_utc',
            'end_date_utc',
          }) ||
          window['days'] != 7) {
        throw const FormatException('Invalid admin push delivery window.');
      }
      String date(String key) {
        final value = window[key];
        final parsed =
            value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
            ? DateTime.tryParse('${value}T00:00:00Z')
            : null;
        if (parsed == null ||
            parsed.toIso8601String().substring(0, 10) != value) {
          throw const FormatException('Invalid admin push delivery window.');
        }
        return value as String;
      }

      startDateUtc = date('start_date_utc');
      endDateUtc = date('end_date_utc');
      if (DateTime.parse('${endDateUtc}T00:00:00Z')
              .difference(DateTime.parse('${startDateUtc}T00:00:00Z'))
              .inDays !=
          6) {
        throw const FormatException('Invalid admin push delivery window.');
      }
    }
    final providers = rawProviders
        .map((value) {
          if (value is! Map || value.keys.any((key) => key is! String)) {
            throw const FormatException('Invalid admin push provider status.');
          }
          return InstanceAdminPushProviderHealth.fromJson(
            Map<String, dynamic>.from(value),
          );
        })
        .toList(growable: false);
    if (providers.length != 2 ||
        providers[0].provider != 'apns' ||
        providers[1].provider != 'fcm_v1') {
      throw const FormatException('Invalid admin push provider order.');
    }
    return InstanceAdminPushHealth(
      generatedAt: generatedAt.toUtc(),
      deliveryStartDateUtc: startDateUtc,
      deliveryEndDateUtc: endDateUtc,
      deliveryWindowAvailable: currentShape,
      providers: List.unmodifiable(providers),
    );
  }
}

class InstanceAdminPushProviderHealth {
  const InstanceAdminPushProviderHealth({
    required this.provider,
    required this.configured,
    required this.registeredEndpoints,
    required this.due,
    required this.retryWaiting,
    required this.leased,
    required this.deadLettered,
    required this.deliveryResults,
    required this.deliveryResultsAvailable,
  });

  final String provider;
  final bool configured;
  final int registeredEndpoints;
  final int due;
  final int retryWaiting;
  final int leased;
  final int deadLettered;
  final InstanceAdminPushDeliveryResults deliveryResults;
  final bool deliveryResultsAvailable;

  factory InstanceAdminPushProviderHealth.fromJson(Map<String, dynamic> json) {
    const keys = {
      'provider',
      'configured',
      'registered_endpoints',
      'due',
      'retry_waiting',
      'leased',
      'dead_lettered',
    };
    final currentShape = json.length == keys.length + 1 &&
        json.keys.toSet().containsAll({...keys, 'delivery_results'});
    final legacyShape = json.length == keys.length &&
        json.keys.toSet().containsAll(keys);
    if (!currentShape && !legacyShape) {
      throw const FormatException('Invalid admin push provider status.');
    }
    final provider = json['provider'];
    final configured = json['configured'];
    int count(String key) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw const FormatException('Invalid admin push provider count.');
      }
      return value;
    }

    if ((provider != 'apns' && provider != 'fcm_v1') || configured is! bool) {
      throw const FormatException('Invalid admin push provider status.');
    }
    final rawDeliveryResults = json['delivery_results'];
    if (currentShape &&
        (rawDeliveryResults is! Map ||
            rawDeliveryResults.keys.any((key) => key is! String))) {
      throw const FormatException('Invalid admin push delivery results.');
    }
    return InstanceAdminPushProviderHealth(
      provider: provider,
      configured: configured,
      registeredEndpoints: count('registered_endpoints'),
      due: count('due'),
      retryWaiting: count('retry_waiting'),
      leased: count('leased'),
      deadLettered: count('dead_lettered'),
      deliveryResults: currentShape
          ? InstanceAdminPushDeliveryResults.fromJson(
              Map<String, dynamic>.from(rawDeliveryResults as Map),
            )
          : const InstanceAdminPushDeliveryResults.zero(),
      deliveryResultsAvailable: currentShape,
    );
  }
}

class InstanceAdminPushDeliveryResults {
  const InstanceAdminPushDeliveryResults({
    required this.accepted,
    required this.invalidToken,
    required this.retryableFailure,
  });

  const InstanceAdminPushDeliveryResults.zero()
    : accepted = 0,
      invalidToken = 0,
      retryableFailure = 0;

  final int accepted;
  final int invalidToken;
  final int retryableFailure;

  factory InstanceAdminPushDeliveryResults.fromJson(Map<String, dynamic> json) {
    const keys = {'accepted', 'invalid_token', 'retryable_failure'};
    if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid admin push delivery results.');
    }
    int count(String key) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw const FormatException(
          'Invalid admin push delivery result count.',
        );
      }
      return value;
    }

    return InstanceAdminPushDeliveryResults(
      accepted: count('accepted'),
      invalidToken: count('invalid_token'),
      retryableFailure: count('retryable_failure'),
    );
  }
}

/// Metadata for the optional Prometheus scrape credential. The credential
/// value is deliberately never part of this reloadable status DTO.
class InstanceAdminMetricsCredentialStatus {
  const InstanceAdminMetricsCredentialStatus({
    required this.active,
    required this.updatedAt,
  });

  final bool active;
  final DateTime? updatedAt;

  factory InstanceAdminMetricsCredentialStatus.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 2 ||
        !json.keys.toSet().containsAll(const {'active', 'updated_at'})) {
      throw const FormatException(
        'Invalid instance admin metrics credential status.',
      );
    }
    final active = json['active'];
    final updatedAtValue = json['updated_at'];
    final updatedAt = updatedAtValue is String
        ? DateTime.tryParse(updatedAtValue)
        : null;
    if (active is! bool ||
        (updatedAtValue != null && updatedAt == null) ||
        (active && updatedAt == null)) {
      throw const FormatException(
        'Invalid instance admin metrics credential status.',
      );
    }
    return InstanceAdminMetricsCredentialStatus(
      active: active,
      updatedAt: updatedAt?.toUtc(),
    );
  }
}

/// A newly created scrape credential. Its plaintext is returned by the
/// rotation endpoint once and is never included in status reads.
class InstanceAdminMetricsCredentialRotation {
  const InstanceAdminMetricsCredentialRotation({
    required this.credential,
    required this.createdAt,
  });

  final String credential;
  final DateTime createdAt;

  factory InstanceAdminMetricsCredentialRotation.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 2 ||
        !json.keys.toSet().containsAll(const {'credential', 'created_at'})) {
      throw const FormatException(
        'Invalid instance admin metrics credential rotation.',
      );
    }
    final credential = json['credential'];
    final createdAtValue = json['created_at'];
    final createdAt = createdAtValue is String
        ? DateTime.tryParse(createdAtValue)
        : null;
    if (credential is! String ||
        !RegExp(r'^atm_[A-Za-z0-9_-]{43}$').hasMatch(credential) ||
        createdAt == null) {
      throw const FormatException(
        'Invalid instance admin metrics credential rotation.',
      );
    }
    return InstanceAdminMetricsCredentialRotation(
      credential: credential,
      createdAt: createdAt.toUtc(),
    );
  }
}

class InstanceAdminMetricsCredentialRevocation {
  const InstanceAdminMetricsCredentialRevocation({required this.revoked});

  final bool revoked;

  factory InstanceAdminMetricsCredentialRevocation.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 1 || json['revoked'] is! bool) {
      throw const FormatException(
        'Invalid instance admin metrics credential revocation.',
      );
    }
    return InstanceAdminMetricsCredentialRevocation(
      revoked: json['revoked'] as bool,
    );
  }
}

/// The mutable relay settings. The deployment limits are returned separately
/// and remain an immutable ceiling for every value in this policy.
class AdminRelayPolicyValue {
  const AdminRelayPolicyValue({
    required this.enabled,
    required this.allowCidrs,
    required this.allowPorts,
  });

  final bool enabled;
  final List<String> allowCidrs;
  final List<int> allowPorts;
}

/// Per-account Relay policy selection returned by the instance-admin API.
/// `revision` remains monotonic after an override is cleared, even though the
/// account then inherits the instance policy again.
class InstanceAdminRelayUserPolicy {
  const InstanceAdminRelayUserPolicy({
    required this.userId,
    required this.inherited,
    required this.policy,
    required this.effectivePolicy,
    required this.instancePolicyRevision,
    required this.revision,
    required this.updatedAt,
  });

  final String userId;
  final bool inherited;
  final AdminRelayPolicyValue policy;
  final AdminRelayPolicyValue effectivePolicy;
  final int instancePolicyRevision;
  final int revision;
  final DateTime? updatedAt;

  factory InstanceAdminRelayUserPolicy.fromJson(Map<String, dynamic> json) {
    if (json.length != 7 ||
        !json.keys.toSet().containsAll(const {
          'user_id',
          'inherited',
          'policy',
          'effective_policy',
          'instance_policy_revision',
          'revision',
          'updated_at',
        })) {
      throw const FormatException('Invalid admin relay user policy response.');
    }

    final userId = json['user_id'];
    final inherited = json['inherited'];
    final rawPolicy = json['policy'];
    final rawEffectivePolicy = json['effective_policy'];
    final instancePolicyRevision = json['instance_policy_revision'];
    final revision = json['revision'];
    final rawUpdatedAt = json['updated_at'];
    if (userId is! String ||
        !_isCanonicalLowercaseUuid(userId) ||
        inherited is! bool ||
        rawPolicy is! Map ||
        rawPolicy.keys.any((key) => key is! String) ||
        rawEffectivePolicy is! Map ||
        rawEffectivePolicy.keys.any((key) => key is! String) ||
        instancePolicyRevision is! int ||
        instancePolicyRevision < 0 ||
        revision is! int ||
        revision < 0 ||
        (rawUpdatedAt != null && rawUpdatedAt is! String)) {
      throw const FormatException('Invalid admin relay user policy response.');
    }

    DateTime? updatedAt;
    if (rawUpdatedAt != null) {
      final text = rawUpdatedAt as String;
      final parsed = DateTime.tryParse(text);
      if (!_isValidRelayTimestamp(text) || parsed == null) {
        throw const FormatException(
          'Invalid admin relay user policy timestamp.',
        );
      }
      updatedAt = parsed.toUtc();
    }

    return InstanceAdminRelayUserPolicy(
      userId: userId,
      inherited: inherited,
      policy: _parseAdminRelayUserPolicyValue(rawPolicy),
      effectivePolicy: _parseAdminRelayUserPolicyValue(rawEffectivePolicy),
      instancePolicyRevision: instancePolicyRevision,
      revision: revision,
      updatedAt: updatedAt,
    );
  }
}

/// An instance administrator managed server access group. These groups are
/// authorization metadata and are separate from encrypted Workspace groups.
class AdminRelayGroupSummary {
  const AdminRelayGroupSummary({
    required this.groupId,
    required this.name,
    required this.revision,
    required this.membershipRevision,
    required this.policyRevision,
    required this.memberCount,
    required this.policyInherited,
    required this.updatedAt,
  });

  final String groupId;
  final String name;
  final int revision;
  final int membershipRevision;
  final int policyRevision;
  final int memberCount;
  final bool policyInherited;
  final DateTime? updatedAt;

  factory AdminRelayGroupSummary.fromJson(Map<String, dynamic> json) {
    if (json.length != 8 ||
        !json.keys.toSet().containsAll(const {
          'group_id',
          'name',
          'revision',
          'membership_revision',
          'policy_revision',
          'member_count',
          'policy_inherited',
          'updated_at',
        })) {
      throw const FormatException('Invalid admin relay group response.');
    }
    final groupId = json['group_id'];
    final name = json['name'];
    final revision = json['revision'];
    final membershipRevision = json['membership_revision'];
    final policyRevision = json['policy_revision'];
    final memberCount = json['member_count'];
    final policyInherited = json['policy_inherited'];
    final updatedAt = _parseAdminRelayGroupTimestamp(json['updated_at']);
    if (groupId is! String ||
        !_isCanonicalLowercaseUuid(groupId) ||
        !_isValidAdminRelayGroupName(name) ||
        revision is! int ||
        revision < 0 ||
        membershipRevision is! int ||
        membershipRevision < 0 ||
        policyRevision is! int ||
        policyRevision < 0 ||
        memberCount is! int ||
        memberCount < 0 ||
        policyInherited is! bool ||
        (json['updated_at'] != null && updatedAt == null)) {
      throw const FormatException('Invalid admin relay group response.');
    }
    return AdminRelayGroupSummary(
      groupId: groupId,
      name: name as String,
      revision: revision,
      membershipRevision: membershipRevision,
      policyRevision: policyRevision,
      memberCount: memberCount,
      policyInherited: policyInherited,
      updatedAt: updatedAt,
    );
  }
}

class AdminRelayGroupMember {
  const AdminRelayGroupMember({required this.userId, required this.username});

  final String userId;
  final String username;

  factory AdminRelayGroupMember.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        !json.keys.toSet().containsAll(const {'user_id', 'username'})) {
      throw const FormatException('Invalid admin relay group member.');
    }
    final userId = json['user_id'];
    final username = json['username'];
    if (userId is! String ||
        !_isCanonicalLowercaseUuid(userId) ||
        username is! String ||
        username.isEmpty ||
        username.length > 320 ||
        username.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('Invalid admin relay group member.');
    }
    return AdminRelayGroupMember(userId: userId, username: username);
  }
}

class AdminRelayGroupPolicy {
  const AdminRelayGroupPolicy({
    required this.inherited,
    required this.revision,
    required this.updatedAt,
    required this.instancePolicyRevision,
    required this.policy,
    required this.effectivePolicy,
  });

  final bool inherited;
  final int revision;
  final DateTime? updatedAt;
  final int instancePolicyRevision;
  final AdminRelayPolicyValue policy;
  final AdminRelayPolicyValue effectivePolicy;

  factory AdminRelayGroupPolicy.fromJson(Map<String, dynamic> json) {
    if (json.length != 6 ||
        !json.keys.toSet().containsAll(const {
          'inherited',
          'revision',
          'updated_at',
          'instance_policy_revision',
          'policy',
          'effective_policy',
        })) {
      throw const FormatException('Invalid admin relay group policy.');
    }
    final inherited = json['inherited'];
    final revision = json['revision'];
    final rawUpdatedAt = json['updated_at'];
    final updatedAt = _parseAdminRelayGroupTimestamp(rawUpdatedAt);
    final instancePolicyRevision = json['instance_policy_revision'];
    final rawPolicy = json['policy'];
    final rawEffectivePolicy = json['effective_policy'];
    if (inherited is! bool ||
        revision is! int ||
        revision < 0 ||
        (rawUpdatedAt != null && updatedAt == null) ||
        instancePolicyRevision is! int ||
        instancePolicyRevision < 0 ||
        rawPolicy is! Map ||
        rawEffectivePolicy is! Map ||
        rawPolicy.keys.any((key) => key is! String) ||
        rawEffectivePolicy.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid admin relay group policy.');
    }
    return AdminRelayGroupPolicy(
      inherited: inherited,
      revision: revision,
      updatedAt: updatedAt,
      instancePolicyRevision: instancePolicyRevision,
      policy: _parseAdminRelayUserPolicyValue(rawPolicy),
      effectivePolicy: _parseAdminRelayUserPolicyValue(rawEffectivePolicy),
    );
  }
}

class AdminRelayGroupDetail {
  const AdminRelayGroupDetail({
    required this.groupId,
    required this.name,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    required this.membershipRevision,
    required this.members,
    required this.policy,
  });

  final String groupId;
  final String name;
  final int revision;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int membershipRevision;
  final List<AdminRelayGroupMember> members;
  final AdminRelayGroupPolicy policy;

  factory AdminRelayGroupDetail.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        !json.keys.toSet().containsAll(const {'group', 'members', 'policy'})) {
      throw const FormatException('Invalid admin relay group detail.');
    }
    final rawGroup = json['group'];
    final rawMembers = json['members'];
    final rawPolicy = json['policy'];
    if (rawGroup is! Map ||
        rawMembers is! Map ||
        rawPolicy is! Map ||
        rawGroup.keys.any((key) => key is! String) ||
        rawMembers.keys.any((key) => key is! String) ||
        rawPolicy.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid admin relay group detail.');
    }
    final group = Map<String, dynamic>.from(rawGroup);
    final members = Map<String, dynamic>.from(rawMembers);
    if (group.length != 5 ||
        !group.keys.toSet().containsAll(const {
          'group_id',
          'name',
          'revision',
          'created_at',
          'updated_at',
        }) ||
        members.length != 2 ||
        !members.keys.toSet().containsAll(const {'revision', 'items'})) {
      throw const FormatException('Invalid admin relay group detail.');
    }
    final groupId = group['group_id'];
    final name = group['name'];
    final revision = group['revision'];
    final createdAt = _parseAdminRelayGroupTimestamp(group['created_at']);
    final updatedAt = _parseAdminRelayGroupTimestamp(group['updated_at']);
    final membershipRevision = members['revision'];
    final rawItems = members['items'];
    if (groupId is! String ||
        !_isCanonicalLowercaseUuid(groupId) ||
        !_isValidAdminRelayGroupName(name) ||
        revision is! int ||
        revision < 0 ||
        (group['created_at'] != null && createdAt == null) ||
        (group['updated_at'] != null && updatedAt == null) ||
        membershipRevision is! int ||
        membershipRevision < 0 ||
        rawItems is! List) {
      throw const FormatException('Invalid admin relay group detail.');
    }
    final parsedMembers = rawItems
        .map((value) {
          if (value is! Map || value.keys.any((key) => key is! String)) {
            throw const FormatException('Invalid admin relay group member.');
          }
          return AdminRelayGroupMember.fromJson(
            Map<String, dynamic>.from(value),
          );
        })
        .toList(growable: false);
    if (parsedMembers.map((member) => member.userId).toSet().length !=
        parsedMembers.length) {
      throw const FormatException('Duplicate admin relay group member.');
    }
    return AdminRelayGroupDetail(
      groupId: groupId,
      name: name as String,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt,
      membershipRevision: membershipRevision,
      members: List.unmodifiable(parsedMembers),
      policy: AdminRelayGroupPolicy.fromJson(
        Map<String, dynamic>.from(rawPolicy),
      ),
    );
  }
}

bool _isValidAdminRelayGroupName(Object? value) =>
    value is String &&
    value == value.trim() &&
    value.runes.length >= 1 &&
    value.runes.length <= 80 &&
    utf8.encode(value).length <= 320 &&
    !value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f));

DateTime? _parseAdminRelayGroupTimestamp(Object? value) {
  if (value == null) return null;
  if (value is! String || !_isValidRelayTimestamp(value)) return null;
  return DateTime.tryParse(value)?.toUtc();
}

AdminRelayPolicyValue _parseAdminRelayUserPolicyValue(Object? raw) {
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid admin relay user policy selection.');
  }
  final json = Map<String, dynamic>.from(raw);
  if (json.length != 3 ||
      !json.keys.toSet().containsAll(const {
        'enabled',
        'allow_cidrs',
        'allow_ports',
      })) {
    throw const FormatException('Invalid admin relay user policy selection.');
  }
  final enabled = json['enabled'];
  if (enabled is! bool) {
    throw const FormatException('Invalid admin relay user policy selection.');
  }
  final cidrs = _relayPolicyCidrs(json['allow_cidrs']);
  final ports = _relayPolicyPorts(json['allow_ports']);
  if (!_relayListIsSorted(cidrs) || !_relayListIsSorted(ports)) {
    throw const FormatException('Invalid admin relay user policy selection.');
  }
  return AdminRelayPolicyValue(
    enabled: enabled,
    allowCidrs: cidrs,
    allowPorts: ports,
  );
}

bool _relayListIsSorted<T extends Comparable<T>>(List<T> values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index - 1].compareTo(values[index]) > 0) return false;
  }
  return true;
}

const _maxAdminRelayPolicyCidrs = 256;
const _maxAdminRelayPolicyPorts = 4096;
const _maxAdminRelayPolicyCidrLength = 64;

class AdminRelayPolicyLimits {
  const AdminRelayPolicyLimits({
    required this.relayAvailable,
    required this.allowCidrs,
    required this.allowPorts,
  });

  final bool relayAvailable;
  final List<String> allowCidrs;
  final List<int> allowPorts;
}

class AdminRelayPolicyDraft {
  const AdminRelayPolicyDraft({
    required this.enabled,
    required this.allowCidrs,
    required this.allowPorts,
  });

  final bool enabled;
  final List<String> allowCidrs;
  final List<int> allowPorts;

  /// Parses the settings form and makes sure it cannot widen deployment
  /// allowlists. Error messages intentionally never repeat submitted values.
  factory AdminRelayPolicyDraft.parseAndValidate({
    required bool enabled,
    required String allowCidrsText,
    required String allowPortsText,
    required AdminRelayPolicyLimits deploymentLimits,
  }) {
    if (enabled && !deploymentLimits.relayAvailable) {
      throw const FormatException(
        'SSH relay is disabled by the server deployment setting.',
      );
    }

    final cidrs = <String>[];
    final parsedCidrs = <_RelayNetwork>[];
    for (final raw in allowCidrsText.split('\n')) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      final network = _RelayNetwork.tryParse(value);
      if (network == null ||
          !network.isNetworkAddress ||
          value != network.canonicalCidr) {
        throw const FormatException(
          'Enter one canonical network CIDR per line using its network address.',
        );
      }
      if (parsedCidrs.any(network.sameNetwork)) {
        throw const FormatException('Remove duplicate CIDR entries.');
      }
      if (parsedCidrs.length >= _maxAdminRelayPolicyCidrs) {
        throw const FormatException(
          'Keep the CIDR list at 256 entries or fewer.',
        );
      }
      parsedCidrs.add(network);
      cidrs.add(value);
    }
    final ceilingCidrs = deploymentLimits.allowCidrs
        .map(_RelayNetwork.parseResponse)
        .toList(growable: false);
    for (final network in parsedCidrs) {
      if (!ceilingCidrs.any((ceiling) => ceiling.contains(network))) {
        throw const FormatException(
          'Every CIDR must fit within a server deployment limit.',
        );
      }
    }

    final ports = <int>[];
    for (final raw in allowPortsText.split(RegExp(r'[,\n]'))) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      final port = int.tryParse(value);
      if (port == null || port < 1 || port > 65535) {
        throw const FormatException(
          'Enter comma or line separated ports from 1 to 65535.',
        );
      }
      if (ports.contains(port)) {
        throw const FormatException('Remove duplicate port entries.');
      }
      if (ports.length >= _maxAdminRelayPolicyPorts) {
        throw const FormatException(
          'Keep the port list at 4096 entries or fewer.',
        );
      }
      ports.add(port);
    }
    if (ports.any((port) => !deploymentLimits.allowPorts.contains(port))) {
      throw const FormatException(
        'Every port must be included in the server deployment limits.',
      );
    }
    return AdminRelayPolicyDraft(
      enabled: enabled,
      allowCidrs: List.unmodifiable(cidrs),
      allowPorts: List.unmodifiable(ports),
    );
  }
}

/// Persisted relay policy plus the immutable limits used to validate edits.
class InstanceAdminRelayPolicy {
  const InstanceAdminRelayPolicy({
    required this.policy,
    required this.deploymentLimits,
    required this.maxConnectionsPerUser,
    required this.revision,
    required this.updatedAt,
  });

  final AdminRelayPolicyValue policy;
  final AdminRelayPolicyLimits deploymentLimits;
  final int maxConnectionsPerUser;
  final int revision;
  final DateTime? updatedAt;

  /// Whether all selected entries still fit inside the current immutable
  /// deployment ceilings. This can be false after a deployment is tightened.
  bool get policyWithinDeploymentLimits =>
      _relayPolicyIsWithin(policy, deploymentLimits);

  /// The effective instance ceiling for per-account policy edits. It mirrors
  /// the server's deployment ∩ instance policy intersection. Account editors
  /// should also compare a user policy's `instancePolicyRevision` with this
  /// object's [revision] before saving.
  AdminRelayPolicyLimits get effectiveUserRelayPolicyLimits =>
      AdminRelayPolicyLimits(
        relayAvailable: deploymentLimits.relayAvailable && policy.enabled,
        allowCidrs: _intersectRelayPolicyCidrs(
          policy.allowCidrs,
          deploymentLimits.allowCidrs,
        ),
        allowPorts: _intersectRelayPolicyPorts(
          policy.allowPorts,
          deploymentLimits.allowPorts,
        ),
      );

  factory InstanceAdminRelayPolicy.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !json.keys.toSet().containsAll(const {
          'policy',
          'deployment_limits',
          'max_connections_per_user',
          'revision',
          'updated_at',
        })) {
      throw const FormatException('Invalid admin relay policy response.');
    }
    final rawPolicy = json['policy'];
    final rawLimits = json['deployment_limits'];
    final rawMaxConnections = json['max_connections_per_user'];
    final revision = json['revision'];
    final rawUpdatedAt = json['updated_at'];
    if (rawPolicy is! Map ||
        rawLimits is! Map ||
        rawMaxConnections is! int ||
        rawMaxConnections < 1 ||
        revision is! int ||
        revision < 0 ||
        (rawUpdatedAt != null && rawUpdatedAt is! String)) {
      throw const FormatException('Invalid admin relay policy response.');
    }
    final policyJson = Map<String, dynamic>.from(rawPolicy);
    final limitsJson = Map<String, dynamic>.from(rawLimits);
    if (policyJson.length != 3 ||
        !policyJson.keys.toSet().containsAll(const {
          'enabled',
          'allow_cidrs',
          'allow_ports',
        }) ||
        limitsJson.length != 3 ||
        !limitsJson.keys.toSet().containsAll(const {
          'relay_available',
          'allow_cidrs',
          'allow_ports',
        })) {
      throw const FormatException('Invalid admin relay policy response.');
    }
    final enabled = policyJson['enabled'];
    final relayAvailable = limitsJson['relay_available'];
    if (enabled is! bool || relayAvailable is! bool) {
      throw const FormatException('Invalid admin relay policy response.');
    }
    final policyCidrs = _relayPolicyCidrs(policyJson['allow_cidrs']);
    final policyPorts = _relayPolicyPorts(policyJson['allow_ports']);
    final ceilingCidrs = _relayPolicyCidrs(limitsJson['allow_cidrs']);
    final ceilingPorts = _relayPolicyPorts(limitsJson['allow_ports']);
    final limits = AdminRelayPolicyLimits(
      relayAvailable: relayAvailable,
      allowCidrs: ceilingCidrs,
      allowPorts: ceilingPorts,
    );
    final value = AdminRelayPolicyValue(
      enabled: enabled,
      allowCidrs: policyCidrs,
      allowPorts: policyPorts,
    );
    // A deployment gate can be changed independently of the durable policy.
    // Preserve an enabled selection in that case; the service is ineffective
    // until the deployment becomes available again.
    DateTime? updatedAt;
    if (rawUpdatedAt != null) {
      final text = rawUpdatedAt as String;
      final parsed = DateTime.tryParse(text);
      if (!_isValidRelayTimestamp(text) || parsed == null) {
        throw const FormatException('Invalid admin relay policy timestamp.');
      }
      updatedAt = parsed.toUtc();
    }
    return InstanceAdminRelayPolicy(
      policy: value,
      deploymentLimits: limits,
      maxConnectionsPerUser: rawMaxConnections,
      revision: revision,
      updatedAt: updatedAt,
    );
  }
}

final _relayRfc3339 = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
);

bool _isValidRelayTimestamp(String value) {
  if (!_relayRfc3339.hasMatch(value)) return false;
  final components = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(value);
  if (components == null) return false;
  final year = int.parse(components.group(1)!);
  final month = int.parse(components.group(2)!);
  final day = int.parse(components.group(3)!);
  final hour = int.parse(components.group(4)!);
  final minute = int.parse(components.group(5)!);
  final second = int.parse(components.group(6)!);
  if (year < 1 || month < 1 || month > 12) return false;
  final localTime = DateTime.utc(year, month, day, hour, minute, second);
  if (localTime.year != year ||
      localTime.month != month ||
      localTime.day != day ||
      localTime.hour != hour ||
      localTime.minute != minute ||
      localTime.second != second) {
    return false;
  }
  final offset = RegExp(r'[+-](\d{2}):(\d{2})$').firstMatch(value);
  if (offset != null &&
      (int.parse(offset.group(1)!) > 23 || int.parse(offset.group(2)!) > 59)) {
    return false;
  }
  return DateTime.tryParse(value) != null;
}

List<String> _relayPolicyCidrs(Object? raw) {
  if (raw is! List ||
      raw.length > _maxAdminRelayPolicyCidrs ||
      raw.any((value) => value is! String)) {
    throw const FormatException('Invalid admin relay CIDR list.');
  }
  final values = List<String>.from(raw);
  final networks = <_RelayNetwork>[];
  for (final value in values) {
    final network = _RelayNetwork.tryParse(value);
    if (network == null ||
        value.length > _maxAdminRelayPolicyCidrLength ||
        !network.isNetworkAddress ||
        value != network.canonicalCidr ||
        networks.any(network.sameNetwork)) {
      throw const FormatException('Invalid admin relay CIDR list.');
    }
    networks.add(network);
  }
  return List.unmodifiable(values);
}

List<int> _relayPolicyPorts(Object? raw) {
  if (raw is! List ||
      raw.length > _maxAdminRelayPolicyPorts ||
      raw.any((value) => value is! int || value < 1 || value > 65535)) {
    throw const FormatException('Invalid admin relay port list.');
  }
  final values = List<int>.from(raw);
  if (values.toSet().length != values.length) {
    throw const FormatException('Invalid admin relay port list.');
  }
  return List.unmodifiable(values);
}

bool _relayPolicyIsWithin(
  AdminRelayPolicyValue policy,
  AdminRelayPolicyLimits limits,
) {
  final ceilings = limits.allowCidrs
      .map(_RelayNetwork.parseResponse)
      .toList(growable: false);
  return policy.allowCidrs.every((value) {
        final network = _RelayNetwork.parseResponse(value);
        return ceilings.any((ceiling) => ceiling.contains(network));
      }) &&
      policy.allowPorts.every(limits.allowPorts.contains);
}

class _RelayNetwork {
  const _RelayNetwork(this.family, this.bytes, this.prefix);

  final int family;
  final List<int> bytes;
  final int prefix;

  int get width => bytes.length * 8;
  String get canonicalCidr =>
      '${family == 4 ? bytes.join('.') : _formatCanonicalRelayIpv6(bytes)}/$prefix';

  bool get isNetworkAddress {
    for (var bit = prefix; bit < width; bit++) {
      if ((bytes[bit ~/ 8] & (1 << (7 - bit % 8))) != 0) return false;
    }
    return true;
  }

  bool contains(_RelayNetwork child) {
    if (family != child.family || prefix > child.prefix) return false;
    for (var bit = 0; bit < prefix; bit++) {
      final mask = 1 << (7 - bit % 8);
      if ((bytes[bit ~/ 8] & mask) != (child.bytes[bit ~/ 8] & mask)) {
        return false;
      }
    }
    return true;
  }

  bool sameNetwork(_RelayNetwork other) =>
      family == other.family &&
      prefix == other.prefix &&
      listEquals(bytes, other.bytes);

  static _RelayNetwork parseResponse(String value) {
    final result = tryParse(value);
    if (result == null || !result.isNetworkAddress) {
      throw const FormatException('Invalid admin relay CIDR list.');
    }
    return result;
  }

  static _RelayNetwork? tryParse(String value) {
    final parts = value.split('/');
    if (parts.length != 2 ||
        parts[0].isEmpty ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(parts[1])) {
      return null;
    }
    final address = _parseRelayAddress(parts[0]);
    if (address == null) return null;
    final prefix = int.tryParse(parts[1]);
    final width = address.bytes.length * 8;
    if (prefix == null || prefix < 0 || prefix > width) return null;
    return _RelayNetwork(address.family, address.bytes, prefix);
  }
}

_RelayNetwork? _intersectRelayNetwork(
  _RelayNetwork selected,
  _RelayNetwork deployment,
) {
  if (selected.contains(deployment)) return deployment;
  if (deployment.contains(selected)) return selected;
  return null;
}

List<String> _intersectRelayPolicyCidrs(
  List<String> selectedCidrs,
  List<String> deploymentCidrs,
) {
  final intersections = <_RelayNetwork>[];
  for (final selectedValue in selectedCidrs) {
    final selected = _RelayNetwork.parseResponse(selectedValue);
    for (final deploymentValue in deploymentCidrs) {
      final deployment = _RelayNetwork.parseResponse(deploymentValue);
      final intersection = _intersectRelayNetwork(selected, deployment);
      if (intersection != null) intersections.add(intersection);
    }
  }

  intersections.sort(
    (left, right) => left.canonicalCidr.compareTo(right.canonicalCidr),
  );
  final normalized = <_RelayNetwork>[];
  for (final candidate in intersections) {
    if (normalized.any((existing) => existing.contains(candidate))) continue;
    normalized.removeWhere((existing) => candidate.contains(existing));
    normalized.add(candidate);
  }
  normalized.sort(
    (left, right) => left.canonicalCidr.compareTo(right.canonicalCidr),
  );
  return List.unmodifiable(normalized.map((network) => network.canonicalCidr));
}

List<int> _intersectRelayPolicyPorts(
  List<int> selectedPorts,
  List<int> deploymentPorts,
) {
  final deployment = deploymentPorts.toSet();
  final ports = selectedPorts.where(deployment.contains).toSet().toList()
    ..sort();
  return List.unmodifiable(ports);
}

({int family, List<int> bytes})? _parseRelayAddress(String value) {
  if (value.contains(':')) {
    if (value.contains('%')) return null;
    final halves = value.toLowerCase().split('::');
    if (halves.length > 2) return null;
    List<int>? parseSide(String side, {required bool allowIpv4}) {
      if (side.isEmpty) return <int>[];
      final rawGroups = side.split(':');
      final groups = <int>[];
      for (var i = 0; i < rawGroups.length; i++) {
        final group = rawGroups[i];
        if (group.contains('.')) {
          if (!allowIpv4 || i != rawGroups.length - 1) {
            return null;
          }
          final ipv4 = _parseRelayIpv4(group);
          if (ipv4 == null) return null;
          groups
            ..add((ipv4[0] << 8) | ipv4[1])
            ..add((ipv4[2] << 8) | ipv4[3]);
        } else {
          if (!RegExp(r'^[0-9a-f]{1,4}$').hasMatch(group)) return null;
          groups.add(int.parse(group, radix: 16));
        }
      }
      return groups;
    }

    final hasCompression = halves.length == 2;
    final left = parseSide(halves.first, allowIpv4: !hasCompression);
    final right = halves.length == 2
        ? parseSide(halves.last, allowIpv4: true)
        : <int>[];
    if (left == null || right == null) return null;
    final missing = 8 - left.length - right.length;
    if ((hasCompression && missing < 1) || (!hasCompression && missing != 0)) {
      return null;
    }
    final groups = <int>[...left, ...List<int>.filled(missing, 0), ...right];
    if (groups.length != 8) return null;
    final bytes = <int>[];
    for (final group in groups) {
      bytes
        ..add((group >> 8) & 0xff)
        ..add(group & 0xff);
    }
    return (family: 6, bytes: bytes);
  }
  final ipv4 = _parseRelayIpv4(value);
  return ipv4 == null ? null : (family: 4, bytes: ipv4);
}

List<int>? _parseRelayIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return null;
    final byte = int.parse(part);
    if (byte > 255) return null;
    bytes.add(byte);
  }
  return bytes;
}

String _formatCanonicalRelayIpv6(List<int> bytes) {
  if (bytes.length != 16) {
    throw const FormatException('Invalid IPv6 network address.');
  }
  // Rust's IPv6 Display spelling uses dotted decimal for IPv4-mapped values.
  if (bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    return '::ffff:${bytes.sublist(12).join('.')}';
  }
  final groups = List<int>.generate(
    8,
    (index) => (bytes[index * 2] << 8) | bytes[index * 2 + 1],
  );
  var bestStart = -1;
  var bestLength = 0;
  for (var index = 0; index < groups.length;) {
    if (groups[index] != 0) {
      index++;
      continue;
    }
    var end = index;
    while (end < groups.length && groups[end] == 0) {
      end++;
    }
    final length = end - index;
    if (length >= 2 && length > bestLength) {
      bestStart = index;
      bestLength = length;
    }
    index = end;
  }
  final formatted = groups.map((group) => group.toRadixString(16)).toList();
  if (bestStart < 0) return formatted.join(':');
  final left = formatted.take(bestStart).join(':');
  final right = formatted.skip(bestStart + bestLength).join(':');
  if (left.isEmpty) return right.isEmpty ? '::' : '::$right';
  if (right.isEmpty) return '$left::';
  return '$left::$right';
}

/// The latest local `backup` CLI attempt exposed to allowlisted admins.
/// This reports the command result only; it does not establish that the
/// archive still exists or that an isolated restore would succeed.
class InstanceAdminBackupAttempt {
  const InstanceAdminBackupAttempt({
    required this.attemptedAt,
    required this.result,
    required this.migrationVersion,
    required this.archiveBytes,
    required this.failureCategory,
  });

  final DateTime attemptedAt;
  final String result;
  final int? migrationVersion;
  final int? archiveBytes;
  final String? failureCategory;

  factory InstanceAdminBackupAttempt.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !json.keys.toSet().containsAll(const {
          'attempted_at',
          'result',
          'migration_version',
          'archive_bytes',
          'failure_category',
        })) {
      throw const FormatException('Invalid instance admin backup status.');
    }
    final attemptedAtValue = json['attempted_at'];
    final attemptedAt = attemptedAtValue is String
        ? DateTime.tryParse(attemptedAtValue)
        : null;
    final result = json['result'];
    final migrationVersion = json['migration_version'];
    final archiveBytes = json['archive_bytes'];
    final failureCategory = json['failure_category'];
    if (attemptedAt == null ||
        (result != 'succeeded' && result != 'failed') ||
        (migrationVersion != null &&
            (migrationVersion is! int || migrationVersion < 0)) ||
        (archiveBytes != null && (archiveBytes is! int || archiveBytes <= 0)) ||
        (failureCategory != null && failureCategory != 'backup_failed')) {
      throw const FormatException('Invalid instance admin backup status.');
    }
    if (result == 'succeeded' &&
        (migrationVersion == null || failureCategory != null)) {
      throw const FormatException('Invalid successful backup status.');
    }
    if (result == 'failed' &&
        (migrationVersion != null ||
            archiveBytes != null ||
            failureCategory != 'backup_failed')) {
      throw const FormatException('Invalid failed backup status.');
    }
    return InstanceAdminBackupAttempt(
      attemptedAt: attemptedAt.toUtc(),
      result: result as String,
      migrationVersion: migrationVersion as int?,
      archiveBytes: archiveBytes as int?,
      failureCategory: failureCategory as String?,
    );
  }
}

class InstanceAdminBackupStatus {
  const InstanceAdminBackupStatus({required this.lastAttempt});

  final InstanceAdminBackupAttempt? lastAttempt;

  factory InstanceAdminBackupStatus.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        !json.keys.toSet().containsAll(const {'operation', 'last_attempt'}) ||
        json['operation'] != 'backup') {
      throw const FormatException('Invalid instance admin backup operation.');
    }
    final rawAttempt = json['last_attempt'];
    if (rawAttempt == null) {
      return const InstanceAdminBackupStatus(lastAttempt: null);
    }
    if (rawAttempt is! Map) {
      throw const FormatException('Invalid instance admin backup attempt.');
    }
    return InstanceAdminBackupStatus(
      lastAttempt: InstanceAdminBackupAttempt.fromJson(
        Map<String, dynamic>.from(rawAttempt),
      ),
    );
  }
}

/// Durable state for server-side encrypted backup replication. This response
/// intentionally contains no destination, object key, path, credential, or
/// provider error details.
class InstanceAdminBackupReplicationStatus {
  const InstanceAdminBackupReplicationStatus({
    required this.configured,
    required this.pendingCount,
    required this.latestAttempt,
  });

  final bool configured;
  final int pendingCount;
  final InstanceAdminBackupReplicationAttempt? latestAttempt;

  factory InstanceAdminBackupReplicationStatus.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 4 ||
        !json.keys.toSet().containsAll(const {
          'operation',
          'configured',
          'pending_count',
          'latest_attempt',
        }) ||
        json['operation'] != 'backup_replication') {
      throw const FormatException(
        'Invalid instance admin backup replication status.',
      );
    }
    final configured = json['configured'];
    final pendingCount = json['pending_count'];
    final rawAttempt = json['latest_attempt'];
    if (configured is! bool ||
        pendingCount is! int ||
        pendingCount < 0 ||
        (rawAttempt != null && rawAttempt is! Map)) {
      throw const FormatException(
        'Invalid instance admin backup replication status.',
      );
    }
    return InstanceAdminBackupReplicationStatus(
      configured: configured,
      pendingCount: pendingCount,
      latestAttempt: rawAttempt == null
          ? null
          : InstanceAdminBackupReplicationAttempt.fromJson(
              Map<String, dynamic>.from(rawAttempt as Map),
            ),
    );
  }
}

/// The fixed result of a server-configured S3 bucket access check. This is a
/// HeadBucket check only; the response never includes provider diagnostics.
class InstanceAdminBackupBucketAccessCheck {
  const InstanceAdminBackupBucketAccessCheck();

  factory InstanceAdminBackupBucketAccessCheck.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 2 ||
        json['check'] != 'bucket_access' ||
        json['result'] != 'passed') {
      throw const FormatException(
        'Invalid instance admin backup bucket-access check response.',
      );
    }
    return const InstanceAdminBackupBucketAccessCheck();
  }
}

class InstanceAdminBackupReplicationAttempt {
  const InstanceAdminBackupReplicationAttempt({
    required this.archiveId,
    required this.state,
    required this.attemptedAt,
    required this.completedAt,
    required this.archiveBytes,
    required this.failureCategory,
  });

  final String archiveId;
  final String state;
  final DateTime attemptedAt;
  final DateTime? completedAt;
  final int? archiveBytes;
  final String? failureCategory;

  factory InstanceAdminBackupReplicationAttempt.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.length != 6 ||
        !json.keys.toSet().containsAll(const {
          'archive_id',
          'state',
          'attempted_at',
          'completed_at',
          'archive_bytes',
          'failure_category',
        })) {
      throw const FormatException(
        'Invalid instance admin backup replication attempt.',
      );
    }
    final archiveId = json['archive_id'];
    final state = json['state'];
    final attemptedAt = _backupScheduleDate(json['attempted_at']);
    final rawCompletedAt = json['completed_at'];
    final completedAt = rawCompletedAt == null
        ? null
        : _backupScheduleDate(rawCompletedAt);
    final archiveBytes = json['archive_bytes'];
    final failureCategory = json['failure_category'];
    if (archiveId is! String ||
        !_isCanonicalLowercaseUuid(archiveId) ||
        !const {
          'pending_archive',
          'pending',
          'running',
          'retry_wait',
          'succeeded',
          'interrupted',
          'failed',
        }.contains(state) ||
        attemptedAt == null ||
        (rawCompletedAt != null && completedAt == null) ||
        (archiveBytes != null && (archiveBytes is! int || archiveBytes <= 0)) ||
        (failureCategory != null &&
            !const {
              'archive_unavailable',
              'credentials_invalid',
              'remote_unavailable',
              'remote_integrity_mismatch',
              'replication_failed',
            }.contains(failureCategory))) {
      throw const FormatException(
        'Invalid instance admin backup replication attempt.',
      );
    }
    final terminal = state == 'succeeded' || state == 'failed';
    if (terminal != (completedAt != null) ||
        (state == 'succeeded' &&
            (archiveBytes == null || failureCategory != null)) ||
        (state == 'failed' && failureCategory == null) ||
        (!terminal && failureCategory != null)) {
      throw const FormatException(
        'Inconsistent instance admin backup replication outcome.',
      );
    }
    return InstanceAdminBackupReplicationAttempt(
      archiveId: archiveId,
      state: state as String,
      attemptedAt: attemptedAt.toUtc(),
      completedAt: completedAt?.toUtc(),
      archiveBytes: archiveBytes as int?,
      failureCategory: failureCategory as String?,
    );
  }
}

/// The instance-wide encrypted backup schedule and the latest durable run.
/// `backupConfigured` only reports whether the server's private archive and
/// encryption-key configuration currently validates. It never contains either
/// path or any key material. A non-null interval means the schedule is enabled.
class InstanceAdminBackupSchedule {
  const InstanceAdminBackupSchedule({
    required this.backupConfigured,
    required this.intervalHours,
    required this.nextRunAt,
    required this.lastRun,
  });

  final bool backupConfigured;
  final int? intervalHours;
  final DateTime? nextRunAt;
  final InstanceAdminBackupScheduleRun? lastRun;

  bool get enabled => intervalHours != null;

  factory InstanceAdminBackupSchedule.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !json.keys.toSet().containsAll(const {
          'operation',
          'backup_configured',
          'interval_hours',
          'next_run_at',
          'last_run',
        }) ||
        json['operation'] != 'backup_schedule') {
      throw const FormatException('Invalid instance admin backup schedule.');
    }
    final backupConfigured = json['backup_configured'];
    final rawInterval = json['interval_hours'];
    final rawNextRun = json['next_run_at'];
    final rawLastRun = json['last_run'];
    if (backupConfigured is! bool ||
        (rawInterval != null &&
            (rawInterval is! int || rawInterval < 1 || rawInterval > 720)) ||
        (rawNextRun != null && rawNextRun is! String) ||
        (rawLastRun != null && rawLastRun is! Map)) {
      throw const FormatException('Invalid instance admin backup schedule.');
    }
    final nextRunAt = rawNextRun == null
        ? null
        : DateTime.tryParse(rawNextRun as String);
    if ((rawNextRun != null && nextRunAt == null) ||
        ((rawInterval == null) != (nextRunAt == null))) {
      throw const FormatException('Invalid next backup run time.');
    }
    return InstanceAdminBackupSchedule(
      backupConfigured: backupConfigured,
      intervalHours: rawInterval as int?,
      nextRunAt: nextRunAt?.toUtc(),
      lastRun: rawLastRun == null
          ? null
          : InstanceAdminBackupScheduleRun.fromJson(
              Map<String, dynamic>.from(rawLastRun as Map),
            ),
    );
  }
}

class InstanceAdminBackupScheduleRun {
  const InstanceAdminBackupScheduleRun({
    required this.runId,
    required this.scheduledFor,
    required this.startedAt,
    required this.finishedAt,
    required this.status,
    required this.resultCode,
    required this.archiveBytes,
    required this.migrationVersion,
  });

  final String runId;
  final DateTime scheduledFor;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String status;
  final String? resultCode;
  final int? archiveBytes;
  final int? migrationVersion;

  factory InstanceAdminBackupScheduleRun.fromJson(Map<String, dynamic> json) {
    if (json.length != 8 ||
        !json.keys.toSet().containsAll(const {
          'run_id',
          'scheduled_for',
          'started_at',
          'finished_at',
          'status',
          'result_code',
          'archive_bytes',
          'migration_version',
        })) {
      throw const FormatException('Invalid scheduled backup run.');
    }
    final runId = json['run_id'];
    final scheduledFor = _backupScheduleDate(json['scheduled_for']);
    final startedAt = _backupScheduleDate(json['started_at']);
    final rawFinishedAt = json['finished_at'];
    final finishedAt = rawFinishedAt == null
        ? null
        : _backupScheduleDate(rawFinishedAt);
    final status = json['status'];
    final resultCode = json['result_code'];
    final archiveBytes = json['archive_bytes'];
    final migrationVersion = json['migration_version'];
    if (runId is! String ||
        !_isCanonicalLowercaseUuid(runId) ||
        scheduledFor == null ||
        startedAt == null ||
        (rawFinishedAt != null && finishedAt == null) ||
        !const {
          'running',
          'succeeded',
          'failed',
          'interrupted',
        }.contains(status) ||
        (resultCode != null &&
            (resultCode is! String ||
                !const {
                  'completed',
                  'backup_failed',
                  'interrupted',
                }.contains(resultCode))) ||
        (archiveBytes != null && (archiveBytes is! int || archiveBytes <= 0)) ||
        (migrationVersion != null &&
            (migrationVersion is! int || migrationVersion < 0))) {
      throw const FormatException('Invalid scheduled backup run.');
    }
    final validOutcome = switch (status) {
      'running' =>
        finishedAt == null &&
            resultCode == null &&
            archiveBytes == null &&
            migrationVersion == null,
      'succeeded' =>
        finishedAt != null &&
            resultCode == 'completed' &&
            archiveBytes is int &&
            migrationVersion is int,
      'failed' =>
        finishedAt != null &&
            resultCode == 'backup_failed' &&
            archiveBytes == null &&
            migrationVersion == null,
      'interrupted' =>
        finishedAt != null &&
            resultCode == 'interrupted' &&
            archiveBytes == null &&
            migrationVersion == null,
      _ => false,
    };
    if (!validOutcome) {
      throw const FormatException('Inconsistent scheduled backup outcome.');
    }
    return InstanceAdminBackupScheduleRun(
      runId: runId,
      scheduledFor: scheduledFor.toUtc(),
      startedAt: startedAt.toUtc(),
      finishedAt: finishedAt?.toUtc(),
      status: status as String,
      resultCode: resultCode as String?,
      archiveBytes: archiveBytes as int?,
      migrationVersion: migrationVersion as int?,
    );
  }
}

/// A server-generated encrypted archive that is safe to offer for an
/// administrator's isolated restore preparation. The source identifier is a
/// UUID only; paths, basenames, key locations, and key bytes are never part of
/// this DTO.
class InstanceAdminRestoreSource {
  const InstanceAdminRestoreSource({
    required this.archiveId,
    required this.createdAt,
    required this.archiveBytes,
    required this.origin,
    required this.source,
  });

  final String archiveId;
  final DateTime createdAt;
  final int archiveBytes;
  final String origin;
  final String source;

  factory InstanceAdminRestoreSource.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !json.keys.toSet().containsAll(const {
          'archive_id',
          'created_at',
          'archive_bytes',
          'origin',
          'source',
        })) {
      throw const FormatException('Invalid instance admin restore source.');
    }
    final archiveId = json['archive_id'];
    final createdAt = _adminTimestamp(json['created_at']);
    final archiveBytes = json['archive_bytes'];
    final origin = json['origin'];
    final source = json['source'];
    if (archiveId is! String ||
        !_isCanonicalLowercaseUuid(archiveId) ||
        createdAt == null ||
        archiveBytes is! int ||
        archiveBytes <= 0 ||
        !const {'manual', 'scheduled'}.contains(origin) ||
        !const {'local', 'replica'}.contains(source)) {
      throw const FormatException('Invalid instance admin restore source.');
    }
    return InstanceAdminRestoreSource(
      archiveId: archiveId,
      createdAt: createdAt,
      archiveBytes: archiveBytes,
      origin: origin as String,
      source: source as String,
    );
  }
}

class InstanceAdminRestoreSourcesPage {
  const InstanceAdminRestoreSourcesPage({
    required this.sources,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<InstanceAdminRestoreSource> sources;
  final int total;
  final int limit;
  final int offset;

  bool get hasNext => offset + sources.length < total;
  bool get hasPrevious => offset > 0;

  factory InstanceAdminRestoreSourcesPage.fromJson(
    Map<String, dynamic> json, {
    required int limit,
    required int offset,
  }) {
    final rawSources = json['sources'];
    final total = json['total'];
    if (json.length != 2 ||
        !json.keys.toSet().containsAll(const {'sources', 'total'}) ||
        rawSources is! List ||
        total is! int ||
        total < 0 ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 1000000 ||
        rawSources.length > limit ||
        rawSources.length > total) {
      throw const FormatException('Invalid instance admin restore sources.');
    }
    final sources = <InstanceAdminRestoreSource>[];
    final identities = <String>{};
    for (final value in rawSources) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid instance admin restore source.');
      }
      final source = InstanceAdminRestoreSource.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (!identities.add('${source.source}:${source.archiveId}')) {
        throw const FormatException('Duplicate instance admin restore source.');
      }
      sources.add(source);
    }
    return InstanceAdminRestoreSourcesPage(
      sources: List.unmodifiable(sources),
      total: total,
      limit: limit,
      offset: offset,
    );
  }
}

DateTime? _backupScheduleDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

// This fits within JavaScript's exact integer range. Keep it as a literal:
// shifting by 40 compiles to a 32-bit JavaScript bitwise operation in Web.
const maxAdminVaultQuotaBytes = 1099511627776;

class AdminVaultMetadata {
  const AdminVaultMetadata({
    required this.vaultId,
    required this.ownerUserId,
    required this.ownerUsername,
    required this.state,
    required this.storedBytes,
    required this.reservedUploadBytes,
    required this.quotaBytes,
    required this.createdAt,
  });

  final String vaultId;
  final String ownerUserId;
  final String ownerUsername;
  final String state;
  final int storedBytes;
  final int reservedUploadBytes;
  final int quotaBytes;
  final DateTime createdAt;

  factory AdminVaultMetadata.fromJson(Map<String, dynamic> json) {
    final vaultId = json['vault_id'];
    final ownerUserId = json['owner_user_id'];
    final ownerUsername = json['owner_username'];
    final state = json['state'];
    final createdAtValue = json['created_at'];
    final createdAt = createdAtValue is String
        ? DateTime.tryParse(createdAtValue)
        : null;
    final storedBytes = json['stored_bytes'];
    final reservedUploadBytes = json['reserved_upload_bytes'];
    final quotaBytes = json['quota_bytes'];
    if (vaultId is! String ||
        !_isCanonicalLowercaseUuid(vaultId) ||
        ownerUserId is! String ||
        !_isCanonicalLowercaseUuid(ownerUserId) ||
        ownerUsername is! String ||
        ownerUsername.isEmpty ||
        state is! String ||
        state.isEmpty ||
        storedBytes is! int ||
        storedBytes < 0 ||
        reservedUploadBytes is! int ||
        reservedUploadBytes < 0 ||
        quotaBytes is! int ||
        quotaBytes < 1 ||
        quotaBytes > maxAdminVaultQuotaBytes ||
        createdAt == null) {
      throw const FormatException('Invalid admin Vault metadata response.');
    }
    return AdminVaultMetadata(
      vaultId: vaultId,
      ownerUserId: ownerUserId,
      ownerUsername: ownerUsername,
      state: state,
      storedBytes: storedBytes,
      reservedUploadBytes: reservedUploadBytes,
      quotaBytes: quotaBytes,
      createdAt: createdAt.toUtc(),
    );
  }
}

class AdminVaultPage {
  const AdminVaultPage({
    required this.vaults,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<AdminVaultMetadata> vaults;
  final int total;
  final int limit;
  final int offset;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + vaults.length < total;

  factory AdminVaultPage.fromJson(Map<String, dynamic> json) {
    final rawVaults = json['vaults'];
    final total = json['total'];
    final limit = json['limit'];
    final offset = json['offset'];
    if (rawVaults is! List ||
        total is! int ||
        total < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        offset is! int ||
        offset < 0 ||
        offset > 1000000 ||
        rawVaults.length > limit) {
      throw const FormatException('Invalid admin Vault page response.');
    }
    return AdminVaultPage(
      vaults: rawVaults
          .map(
            (value) => AdminVaultMetadata.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(growable: false),
      total: total,
      limit: limit,
      offset: offset,
    );
  }
}

class AdminVaultQuotaReceipt {
  const AdminVaultQuotaReceipt({
    required this.vaultId,
    required this.quotaBytes,
    required this.storedBytes,
    required this.reservedUploadBytes,
    required this.updatedAt,
  });

  final String vaultId;
  final int quotaBytes;
  final int storedBytes;
  final int reservedUploadBytes;
  final DateTime updatedAt;

  factory AdminVaultQuotaReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedVaultId,
  }) {
    final vaultId = json['vault_id'];
    final quotaBytes = json['quota_bytes'];
    final storedBytes = json['stored_bytes'];
    final reservedUploadBytes = json['reserved_upload_bytes'];
    final updatedAtValue = json['updated_at'];
    final updatedAt = updatedAtValue is String
        ? DateTime.tryParse(updatedAtValue)
        : null;
    if (vaultId != expectedVaultId ||
        quotaBytes is! int ||
        quotaBytes < 1 ||
        quotaBytes > maxAdminVaultQuotaBytes ||
        storedBytes is! int ||
        storedBytes < 0 ||
        reservedUploadBytes is! int ||
        reservedUploadBytes < 0 ||
        updatedAt == null) {
      throw const FormatException('Invalid admin Vault quota receipt.');
    }
    return AdminVaultQuotaReceipt(
      vaultId: vaultId as String,
      quotaBytes: quotaBytes,
      storedBytes: storedBytes,
      reservedUploadBytes: reservedUploadBytes,
      updatedAt: updatedAt.toUtc(),
    );
  }
}

class AdminAccountMetadata {
  const AdminAccountMetadata({
    required this.userId,
    required this.username,
    required this.status,
    required this.createdAt,
    required this.activeDeviceCount,
    required this.activeSessionCount,
  });

  final String userId;
  final String username;
  final String status;
  final DateTime createdAt;
  final int activeDeviceCount;
  final int activeSessionCount;

  factory AdminAccountMetadata.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final username = json['username'];
    final status = json['status'];
    final createdAtText = json['created_at'];
    final createdAt = createdAtText is String
        ? DateTime.tryParse(createdAtText)
        : null;
    final activeDeviceCount = json['active_device_count'];
    final activeSessionCount = json['active_session_count'];
    if (userId is! String ||
        !_isCanonicalLowercaseUuid(userId) ||
        username is! String ||
        username.isEmpty ||
        !const {'active', 'disabled', 'deleting'}.contains(status) ||
        activeDeviceCount is! int ||
        activeDeviceCount < 0 ||
        activeSessionCount is! int ||
        activeSessionCount < 0 ||
        createdAt == null ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(createdAtText as String)) {
      throw const FormatException('Invalid admin account metadata response.');
    }
    return AdminAccountMetadata(
      userId: userId,
      username: username,
      status: status as String,
      createdAt: createdAt.toUtc(),
      activeDeviceCount: activeDeviceCount,
      activeSessionCount: activeSessionCount,
    );
  }
}

class AdminAccountPage {
  const AdminAccountPage({
    required this.accounts,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<AdminAccountMetadata> accounts;
  final int total;
  final int limit;
  final int offset;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + accounts.length < total;

  factory AdminAccountPage.fromJson(Map<String, dynamic> json) {
    final rawAccounts = json['accounts'];
    final total = json['total'];
    final limit = json['limit'];
    final offset = json['offset'];
    if (rawAccounts is! List ||
        total is! int ||
        total < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        offset is! int ||
        offset < 0 ||
        offset > 1000000 ||
        rawAccounts.length > limit) {
      throw const FormatException('Invalid admin account page response.');
    }
    final accounts = <AdminAccountMetadata>[];
    for (final value in rawAccounts) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid admin account response.');
      }
      accounts.add(
        AdminAccountMetadata.fromJson(Map<String, dynamic>.from(value)),
      );
    }
    return AdminAccountPage(
      accounts: List.unmodifiable(accounts),
      total: total,
      limit: limit,
      offset: offset,
    );
  }
}

class AdminAccountInvitationMetadata {
  const AdminAccountInvitationMetadata({
    required this.invitationId,
    required this.username,
    required this.createdAt,
    required this.expiresAt,
    required this.status,
  });

  final String invitationId;
  final String username;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String status;

  factory AdminAccountInvitationMetadata.fromJson(Map<String, dynamic> json) {
    const expectedKeys = {
      'invitation_id',
      'username',
      'created_at',
      'expires_at',
      'status',
    };
    final invitationId = json['invitation_id'];
    final username = json['username'];
    final createdAt = _adminTimestamp(json['created_at']);
    final expiresAt = _adminTimestamp(json['expires_at']);
    final status = json['status'];
    if (json.keys.toSet().difference(expectedKeys).isNotEmpty ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        invitationId is! String ||
        !_isCanonicalLowercaseUuid(invitationId) ||
        username is! String ||
        username.isEmpty ||
        createdAt == null ||
        expiresAt == null ||
        !const {'pending', 'expired', 'consumed', 'revoked'}.contains(status)) {
      throw const FormatException('Invalid admin account invitation response.');
    }
    return AdminAccountInvitationMetadata(
      invitationId: invitationId,
      username: username,
      createdAt: createdAt,
      expiresAt: expiresAt,
      status: status as String,
    );
  }
}

class AdminAccountInvitationsPage {
  const AdminAccountInvitationsPage({
    required this.invitations,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<AdminAccountInvitationMetadata> invitations;
  final int total;
  final int limit;
  final int offset;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + invitations.length < total;

  factory AdminAccountInvitationsPage.fromJson(
    Map<String, dynamic> json, {
    required int limit,
    required int offset,
  }) {
    const expectedKeys = {'invitations', 'total', 'limit', 'offset'};
    final rawInvitations = json['invitations'];
    final total = json['total'];
    final responseLimit = json['limit'];
    final responseOffset = json['offset'];
    if (json.keys.toSet().difference(expectedKeys).isNotEmpty ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        rawInvitations is! List ||
        total is! int ||
        total < 0 ||
        responseLimit != limit ||
        responseOffset != offset ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 1000000 ||
        rawInvitations.length > limit) {
      throw const FormatException(
        'Invalid admin account invitations page response.',
      );
    }
    final invitations = <AdminAccountInvitationMetadata>[];
    final ids = <String>{};
    for (final value in rawInvitations) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Invalid admin account invitation response.',
        );
      }
      final invitation = AdminAccountInvitationMetadata.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (!ids.add(invitation.invitationId)) {
        throw const FormatException(
          'Duplicate admin account invitation response.',
        );
      }
      invitations.add(invitation);
    }
    return AdminAccountInvitationsPage(
      invitations: List.unmodifiable(invitations),
      total: total,
      limit: limit,
      offset: offset,
    );
  }
}

class AdminAccountInvitationIssueReceipt {
  const AdminAccountInvitationIssueReceipt({
    required this.invitationId,
    required this.username,
    required this.createdAt,
    required this.expiresAt,
    required this.token,
  });

  final String invitationId;
  final String username;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String token;

  factory AdminAccountInvitationIssueReceipt.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json.keys.toSet().difference(const {'invitation'}).isNotEmpty ||
        !json.keys.toSet().containsAll(const {'invitation'}) ||
        json['invitation'] is! Map ||
        (json['invitation'] as Map).keys.any((key) => key is! String)) {
      throw const FormatException(
        'Invalid admin account invitation issue response.',
      );
    }
    final invitation = Map<String, dynamic>.from(json['invitation'] as Map);
    const expectedKeys = {
      'invitation_id',
      'username',
      'created_at',
      'expires_at',
      'token',
    };
    final invitationId = invitation['invitation_id'];
    final username = invitation['username'];
    final createdAt = _adminTimestamp(invitation['created_at']);
    final expiresAt = _adminTimestamp(invitation['expires_at']);
    final token = invitation['token'];
    if (invitation.keys.toSet().difference(expectedKeys).isNotEmpty ||
        !invitation.keys.toSet().containsAll(expectedKeys) ||
        invitationId is! String ||
        !_isCanonicalLowercaseUuid(invitationId) ||
        username is! String ||
        username.isEmpty ||
        createdAt == null ||
        expiresAt == null ||
        token is! String ||
        !_isCanonicalBase64Url32(token)) {
      throw const FormatException(
        'Invalid admin account invitation issue receipt.',
      );
    }
    return AdminAccountInvitationIssueReceipt(
      invitationId: invitationId,
      username: username,
      createdAt: createdAt,
      expiresAt: expiresAt,
      token: token,
    );
  }
}

class AdminAccountInvitationRevokeReceipt {
  const AdminAccountInvitationRevokeReceipt({
    required this.invitationId,
    required this.status,
    required this.revokedAt,
  });

  final String invitationId;
  final String status;
  final DateTime revokedAt;

  factory AdminAccountInvitationRevokeReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedInvitationId,
  }) {
    const expectedKeys = {'invitation_id', 'status', 'revoked_at'};
    final invitationId = json['invitation_id'];
    final status = json['status'];
    final revokedAt = _adminTimestamp(json['revoked_at']);
    if (json.keys.toSet().difference(expectedKeys).isNotEmpty ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        invitationId != expectedInvitationId ||
        status != 'revoked' ||
        revokedAt == null) {
      throw const FormatException(
        'Invalid admin account invitation revoke receipt.',
      );
    }
    return AdminAccountInvitationRevokeReceipt(
      invitationId: invitationId as String,
      status: status as String,
      revokedAt: revokedAt,
    );
  }
}

class AdminAccountStatusReceipt {
  const AdminAccountStatusReceipt({
    required this.accountId,
    required this.status,
    required this.revokedSessions,
    required this.updatedAt,
  });

  final String accountId;
  final String status;
  final int revokedSessions;
  final DateTime updatedAt;

  factory AdminAccountStatusReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedAccountId,
    required String expectedStatus,
  }) {
    final accountId = json['account_id'];
    final status = json['status'];
    final revokedSessions = json['revoked_sessions'];
    final updatedAtText = json['updated_at'];
    final updatedAt = updatedAtText is String
        ? DateTime.tryParse(updatedAtText)
        : null;
    if (accountId != expectedAccountId ||
        status != expectedStatus ||
        !const {'active', 'disabled'}.contains(status) ||
        revokedSessions is! int ||
        revokedSessions < 0 ||
        updatedAt == null) {
      throw const FormatException('Invalid admin account status receipt.');
    }
    return AdminAccountStatusReceipt(
      accountId: accountId as String,
      status: status as String,
      revokedSessions: revokedSessions,
      updatedAt: updatedAt.toUtc(),
    );
  }
}

class AdminAccountSessionsReceipt {
  const AdminAccountSessionsReceipt({
    required this.accountId,
    required this.revokedSessions,
    required this.updatedAt,
  });

  final String accountId;
  final int revokedSessions;
  final DateTime updatedAt;

  factory AdminAccountSessionsReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedAccountId,
  }) {
    final accountId = json['account_id'];
    final revokedSessions = json['revoked_sessions'];
    final updatedAtText = json['updated_at'];
    final updatedAt = updatedAtText is String
        ? DateTime.tryParse(updatedAtText)
        : null;
    if (accountId != expectedAccountId ||
        revokedSessions is! int ||
        revokedSessions < 0 ||
        updatedAt == null) {
      throw const FormatException('Invalid admin account session receipt.');
    }
    return AdminAccountSessionsReceipt(
      accountId: accountId as String,
      revokedSessions: revokedSessions,
      updatedAt: updatedAt.toUtc(),
    );
  }
}

class AdminAccountSessionMetadata {
  const AdminAccountSessionMetadata({
    required this.sessionId,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.active,
    required this.revokedAt,
  });

  final String sessionId;
  final String deviceId;
  final String deviceName;
  final DateTime createdAt;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final bool active;
  final DateTime? revokedAt;

  factory AdminAccountSessionMetadata.fromJson(Map<String, dynamic> json) {
    final sessionId = json['session_id'];
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final createdAtText = json['created_at'];
    final accessExpiresAtText = json['access_expires_at'];
    final refreshExpiresAtText = json['refresh_expires_at'];
    final active = json['active'];
    final revokedAtText = json['revoked_at'];
    final createdAt = _adminTimestamp(createdAtText);
    final accessExpiresAt = _adminTimestamp(accessExpiresAtText);
    final refreshExpiresAt = _adminTimestamp(refreshExpiresAtText);
    final revokedAt = revokedAtText == null
        ? null
        : _adminTimestamp(revokedAtText);
    if (sessionId is! String ||
        !_isCanonicalLowercaseUuid(sessionId) ||
        deviceId is! String ||
        !_isCanonicalLowercaseUuid(deviceId) ||
        deviceName is! String ||
        deviceName.isEmpty ||
        createdAt == null ||
        accessExpiresAt == null ||
        refreshExpiresAt == null ||
        active is! bool ||
        (revokedAtText != null && revokedAt == null)) {
      throw const FormatException('Invalid admin account session response.');
    }
    return AdminAccountSessionMetadata(
      sessionId: sessionId,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: createdAt,
      accessExpiresAt: accessExpiresAt,
      refreshExpiresAt: refreshExpiresAt,
      active: active,
      revokedAt: revokedAt,
    );
  }
}

class AdminAccountSessionsPage {
  const AdminAccountSessionsPage({
    required this.sessions,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<AdminAccountSessionMetadata> sessions;
  final int total;
  final int limit;
  final int offset;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + sessions.length < total;

  factory AdminAccountSessionsPage.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessions'];
    final total = json['total'];
    final limit = json['limit'];
    final offset = json['offset'];
    if (rawSessions is! List ||
        total is! int ||
        total < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        offset is! int ||
        offset < 0 ||
        offset > 1000000 ||
        rawSessions.length > limit) {
      throw const FormatException('Invalid admin account sessions page.');
    }
    final sessions = <AdminAccountSessionMetadata>[];
    for (final value in rawSessions) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid admin account session response.');
      }
      sessions.add(
        AdminAccountSessionMetadata.fromJson(Map<String, dynamic>.from(value)),
      );
    }
    return AdminAccountSessionsPage(
      sessions: List.unmodifiable(sessions),
      total: total,
      limit: limit,
      offset: offset,
    );
  }
}

class AdminAccountSessionRevokeReceipt {
  const AdminAccountSessionRevokeReceipt({
    required this.accountId,
    required this.sessionId,
    required this.revoked,
    required this.updatedAt,
  });

  final String accountId;
  final String sessionId;
  final bool revoked;
  final DateTime updatedAt;

  factory AdminAccountSessionRevokeReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedAccountId,
    required String expectedSessionId,
  }) {
    final accountId = json['account_id'];
    final sessionId = json['session_id'];
    final revoked = json['revoked'];
    final updatedAt = _adminTimestamp(json['updated_at']);
    if (accountId != expectedAccountId ||
        sessionId != expectedSessionId ||
        revoked is! bool ||
        updatedAt == null) {
      throw const FormatException(
        'Invalid admin account session revoke receipt.',
      );
    }
    return AdminAccountSessionRevokeReceipt(
      accountId: accountId as String,
      sessionId: sessionId as String,
      revoked: revoked,
      updatedAt: updatedAt,
    );
  }
}

DateTime? _adminTimestamp(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(value)) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

class InstanceAdminAuditEvent {
  const InstanceAdminAuditEvent({
    required this.eventId,
    required this.scope,
    required this.actorUserId,
    required this.actorDeviceId,
    required this.action,
    required this.resourceType,
    required this.resourceIdHmac,
    required this.result,
    required this.occurredAt,
    required this.source,
  });

  final String eventId;
  final String scope;
  final String? actorUserId;
  final String? actorDeviceId;
  final String action;
  final String resourceType;
  final String? resourceIdHmac;
  final String result;
  final DateTime occurredAt;
  final String source;

  factory InstanceAdminAuditEvent.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Instance admin audit event is missing $key.');
      }
      return value;
    }

    String? nullableString(String key) {
      if (!json.containsKey(key)) {
        throw FormatException('Instance admin audit event is missing $key.');
      }
      final value = json[key];
      if (value != null && (value is! String || value.isEmpty)) {
        throw FormatException('Invalid instance admin audit $key.');
      }
      return value as String?;
    }

    final eventId = requiredString('event_id');
    final scope = requiredString('scope');
    final actorUserId = nullableString('actor_user_id');
    final actorDeviceId = nullableString('actor_device_id');
    final action = requiredString('action');
    final resourceType = requiredString('resource_type');
    final resourceIdHmac = nullableString('resource_id');
    final result = requiredString('result');
    final occurredAtText = requiredString('occurred_at');
    final occurredAt = DateTime.tryParse(occurredAtText);
    const rfc3339DateTime =
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$';
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(eventId) ||
        scope != 'instance' ||
        !const {'success', 'failure'}.contains(result) ||
        !const {'api', 'maintenance'}.contains(requiredString('source')) ||
        (resourceIdHmac != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(resourceIdHmac)) ||
        occurredAt == null ||
        !RegExp(rfc3339DateTime).hasMatch(occurredAtText)) {
      throw const FormatException('Invalid instance admin audit event.');
    }
    return InstanceAdminAuditEvent(
      eventId: eventId,
      scope: scope,
      actorUserId: actorUserId,
      actorDeviceId: actorDeviceId,
      action: action,
      resourceType: resourceType,
      resourceIdHmac: resourceIdHmac,
      result: result,
      occurredAt: occurredAt.toUtc(),
      source: json['source'] as String,
    );
  }
}

class InstanceAdminAuditPage {
  const InstanceAdminAuditPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<InstanceAdminAuditEvent> events;
  final String? nextCursor;
  final bool hasMore;

  factory InstanceAdminAuditPage.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    final nextCursor = json['next_cursor'];
    final hasMore = json['has_more'];
    if (rawEvents is! List ||
        (nextCursor != null && (nextCursor is! String || nextCursor.isEmpty)) ||
        hasMore is! bool ||
        (hasMore && nextCursor == null)) {
      throw const FormatException('Invalid instance admin audit page.');
    }
    final events = <InstanceAdminAuditEvent>[];
    for (final value in rawEvents) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid instance admin audit event.');
      }
      events.add(
        InstanceAdminAuditEvent.fromJson(Map<String, dynamic>.from(value)),
      );
    }
    return InstanceAdminAuditPage(
      events: List.unmodifiable(events),
      nextCursor: nextCursor as String?,
      hasMore: hasMore,
    );
  }
}

class AdminMaintenanceJob {
  const AdminMaintenanceJob({
    required this.jobId,
    required this.requestId,
    required this.action,
    required this.status,
    required this.requestedAt,
    required this.startedAt,
    required this.finishedAt,
    required this.resultCode,
    required this.archiveId,
    required this.archiveSource,
    required this.restoreStageStatus,
  });

  final String jobId;
  final String requestId;
  final String action;
  final String status;
  final DateTime requestedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? resultCode;
  final String? archiveId;
  final String? archiveSource;
  final String? restoreStageStatus;

  bool get isBackup => action == 'backup';
  bool get isRestore => action == 'restore';
  bool get isActive => status == 'queued' || status == 'running';

  AdminMaintenanceJob withRestoreStageStatus(String? value) =>
      AdminMaintenanceJob(
        jobId: jobId,
        requestId: requestId,
        action: action,
        status: status,
        requestedAt: requestedAt,
        startedAt: startedAt,
        finishedAt: finishedAt,
        resultCode: resultCode,
        archiveId: archiveId,
        archiveSource: archiveSource,
        restoreStageStatus: value,
      );

  factory AdminMaintenanceJob.fromJson(Map<String, dynamic> json) {
    if (json.length != 11 ||
        !json.keys.toSet().containsAll(const {
          'job_id',
          'request_id',
          'action',
          'status',
          'requested_at',
          'started_at',
          'finished_at',
          'result_code',
          'archive_id',
          'archive_source',
          'restore_stage_status',
        })) {
      throw const FormatException('Invalid admin maintenance job fields.');
    }
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Admin maintenance job is missing $key.');
      }
      return value;
    }

    DateTime parseTimestamp(String value, String field) {
      const rfc3339 =
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$';
      final parsed = DateTime.tryParse(value);
      if (parsed == null || !RegExp(rfc3339).hasMatch(value)) {
        throw FormatException('Invalid admin maintenance job $field.');
      }
      return parsed.toUtc();
    }

    DateTime? optionalTimestamp(String key) {
      if (!json.containsKey(key)) {
        throw FormatException('Admin maintenance job is missing $key.');
      }
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Invalid admin maintenance job $key.');
      }
      return parseTimestamp(value, key);
    }

    String? optionalResultCode() {
      if (!json.containsKey('result_code')) {
        throw const FormatException(
          'Admin maintenance job is missing result_code.',
        );
      }
      final value = json['result_code'];
      if (value != null &&
          (value is! String ||
              !const {
                'completed',
                'maintenance_failed',
                'backup_failed',
                'restore_failed',
                'interrupted',
              }.contains(value))) {
        throw const FormatException('Invalid admin maintenance result code.');
      }
      return value as String?;
    }

    final jobId = requiredString('job_id');
    final requestId = requiredString('request_id');
    final action = requiredString('action');
    final status = requiredString('status');
    final requestedAtText = requiredString('requested_at');
    final startedAt = optionalTimestamp('started_at');
    final finishedAt = optionalTimestamp('finished_at');
    final resultCode = optionalResultCode();
    if (!json.containsKey('archive_id')) {
      throw const FormatException(
        'Admin maintenance job is missing archive_id.',
      );
    }
    final rawArchiveId = json['archive_id'];
    if (rawArchiveId != null &&
        (rawArchiveId is! String || !_isCanonicalLowercaseUuid(rawArchiveId))) {
      throw const FormatException('Invalid admin maintenance archive ID.');
    }
    final archiveId = rawArchiveId as String?;
    if (!json.containsKey('archive_source')) {
      throw const FormatException(
        'Admin maintenance job is missing archive_source.',
      );
    }
    final rawArchiveSource = json['archive_source'];
    if (rawArchiveSource != null &&
        !const {'local', 'replica'}.contains(rawArchiveSource)) {
      throw const FormatException('Invalid admin maintenance archive source.');
    }
    final archiveSource = rawArchiveSource as String?;
    if (!json.containsKey('restore_stage_status')) {
      throw const FormatException(
        'Admin maintenance job is missing restore_stage_status.',
      );
    }
    final rawRestoreStageStatus = json['restore_stage_status'];
    if (rawRestoreStageStatus != null &&
        !const {
          'ready',
          'failed',
          'interrupted',
          'discarding',
          'discarded',
          'unverified',
        }.contains(rawRestoreStageStatus)) {
      throw const FormatException('Invalid admin restore stage status.');
    }
    final restoreStageStatus = rawRestoreStageStatus as String?;
    const uuidPattern =
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if (!RegExp(uuidPattern).hasMatch(jobId) ||
        !RegExp(uuidPattern).hasMatch(requestId) ||
        !const {'maintenance', 'backup', 'restore'}.contains(action) ||
        (action == 'restore' && (archiveId == null || archiveSource == null)) ||
        (action == 'backup' && archiveSource != null) ||
        (action == 'maintenance' &&
            (archiveId != null || archiveSource != null)) ||
        (action != 'restore' && restoreStageStatus != null) ||
        (action == 'restore' &&
            ((status == 'succeeded' &&
                    const {
                      'failed',
                      'interrupted',
                    }.contains(restoreStageStatus)) ||
                (status == 'failed' &&
                    restoreStageStatus != null &&
                    restoreStageStatus != 'failed') ||
                (status == 'interrupted' &&
                    restoreStageStatus != null &&
                    !const {
                      'interrupted',
                      'ready',
                      'discarding',
                      'discarded',
                    }.contains(restoreStageStatus)) ||
                const {'queued', 'running'}.contains(status) &&
                    restoreStageStatus != null)) ||
        !const {
          'queued',
          'running',
          'succeeded',
          'failed',
          'interrupted',
        }.contains(status)) {
      throw const FormatException('Invalid admin maintenance job.');
    }
    switch (status) {
      case 'queued':
        if (startedAt != null || finishedAt != null || resultCode != null) {
          throw const FormatException('Invalid queued maintenance job state.');
        }
      case 'running':
        if (startedAt == null || finishedAt != null || resultCode != null) {
          throw const FormatException('Invalid running maintenance job state.');
        }
      case 'succeeded':
        if (startedAt == null ||
            finishedAt == null ||
            resultCode != 'completed') {
          throw const FormatException(
            'Invalid succeeded maintenance job state.',
          );
        }
      case 'failed':
        if (startedAt == null ||
            finishedAt == null ||
            resultCode !=
                switch (action) {
                  'backup' => 'backup_failed',
                  'restore' => 'restore_failed',
                  _ => 'maintenance_failed',
                }) {
          throw const FormatException('Invalid failed maintenance job state.');
        }
      case 'interrupted':
        if (finishedAt == null || resultCode != 'interrupted') {
          throw const FormatException(
            'Invalid interrupted maintenance job state.',
          );
        }
    }
    return AdminMaintenanceJob(
      jobId: jobId,
      requestId: requestId,
      action: action,
      status: status,
      requestedAt: parseTimestamp(requestedAtText, 'requested_at'),
      startedAt: startedAt,
      finishedAt: finishedAt,
      resultCode: resultCode,
      archiveId: archiveId,
      archiveSource: archiveSource,
      restoreStageStatus: restoreStageStatus,
    );
  }
}

class InstanceAdminRestoreStageDiscard {
  const InstanceAdminRestoreStageDiscard({
    required this.restoreJobId,
    required this.discardedAt,
  });

  final String restoreJobId;
  final DateTime discardedAt;

  factory InstanceAdminRestoreStageDiscard.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        !json.keys.toSet().containsAll(const {
          'restore_job_id',
          'status',
          'discarded_at',
        }) ||
        json['status'] != 'discarded') {
      throw const FormatException('Invalid restore stage discard response.');
    }
    final restoreJobId = json['restore_job_id'];
    final discardedAtText = json['discarded_at'];
    const rfc3339 =
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$';
    final discardedAt = discardedAtText is String
        ? DateTime.tryParse(discardedAtText)
        : null;
    if (restoreJobId is! String ||
        !_isCanonicalLowercaseUuid(restoreJobId) ||
        discardedAt == null ||
        !RegExp(rfc3339).hasMatch(discardedAtText as String)) {
      throw const FormatException('Invalid restore stage discard response.');
    }
    return InstanceAdminRestoreStageDiscard(
      restoreJobId: restoreJobId,
      discardedAt: discardedAt.toUtc(),
    );
  }
}

class AdminMaintenanceJobsPage {
  const AdminMaintenanceJobsPage({
    required this.jobs,
    required this.total,
    required this.limit,
    required this.offset,
    this.supportedActions = const <String>[],
  });

  final List<AdminMaintenanceJob> jobs;
  final int total;
  final int limit;
  final int offset;
  final List<String> supportedActions;

  bool get hasNext => offset + jobs.length < total;
  bool get hasPrevious => offset > 0;

  factory AdminMaintenanceJobsPage.fromJson(
    Map<String, dynamic> json, {
    required int limit,
    required int offset,
  }) {
    final rawJobs = json['jobs'];
    final total = json['total'];
    final rawSupportedActions = json['supported_actions'];
    if (rawJobs is! List ||
        total is! int ||
        total < 0 ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        rawJobs.length > limit) {
      throw const FormatException('Invalid admin maintenance jobs page.');
    }
    final supportedActions = rawSupportedActions == null
        ? const <String>[]
        : rawSupportedActions is List &&
              rawSupportedActions.every(
                (action) =>
                    action is String &&
                    const {
                      'maintenance',
                      'backup',
                      'restore',
                      'backup_status',
                      'backup_replication',
                      'backup_schedule',
                      'restore_replica',
                      'restore_stage_discard',
                    }.contains(action),
              ) &&
              rawSupportedActions.toSet().length ==
                  rawSupportedActions.length &&
              rawSupportedActions.contains('maintenance')
        ? rawSupportedActions.cast<String>()
        : throw const FormatException(
            'Invalid admin maintenance job capabilities.',
          );
    final jobs = <AdminMaintenanceJob>[];
    final ids = <String>{};
    for (final value in rawJobs) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid admin maintenance job row.');
      }
      final job = AdminMaintenanceJob.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (!ids.add(job.jobId)) {
        throw const FormatException('Duplicate admin maintenance job.');
      }
      jobs.add(job);
    }
    return AdminMaintenanceJobsPage(
      jobs: List.unmodifiable(jobs),
      total: total,
      limit: limit,
      offset: offset,
      supportedActions: List.unmodifiable(supportedActions),
    );
  }
}

bool _isCanonicalLowercaseUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);

bool _isCanonicalBase64Url32(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) return false;
  Uint8List? decoded;
  try {
    decoded = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
    return decoded.length == 32 &&
        base64Url.encode(decoded).replaceAll('=', '') == value;
  } on FormatException {
    return false;
  } finally {
    decoded?.fillRange(0, decoded.length, 0);
  }
}

class PasswordChangeReceipt {
  const PasswordChangeReceipt({
    required this.operationId,
    required this.credentialVersion,
    required this.alreadyApplied,
  });

  final String operationId;
  final int credentialVersion;
  final bool alreadyApplied;

  factory PasswordChangeReceipt.fromJson(
    Map<String, dynamic> json, {
    required String expectedOperationId,
  }) {
    final operationId = json['operation_id'];
    final credentialVersion = json['credential_version'];
    final alreadyApplied = json['already_applied'];
    if (json['status'] != 'changed' ||
        operationId is! String ||
        operationId != expectedOperationId ||
        credentialVersion is! int ||
        credentialVersion < 1 ||
        json['session_preserved'] != true ||
        json['other_sessions_revoked'] != true ||
        alreadyApplied is! bool) {
      throw const FormatException('Invalid password change response.');
    }
    return PasswordChangeReceipt(
      operationId: operationId,
      credentialVersion: credentialVersion,
      alreadyApplied: alreadyApplied,
    );
  }
}

class SyncPage {
  const SyncPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
    required this.serverGeneration,
  });

  final List<Map<String, dynamic>> events;
  final String? nextCursor;
  final bool hasMore;
  final String serverGeneration;

  factory SyncPage.fromJson(Map<String, dynamic> json) => SyncPage(
    events: (json['events'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false),
    nextCursor: json['next_cursor'] as String?,
    hasMore: json['has_more'] as bool? ?? false,
    serverGeneration: json['server_generation'] as String,
  );
}

class VaultRevisionEntry {
  const VaultRevisionEntry({
    required this.recordId,
    required this.revisionId,
    required this.baseRevisionId,
    required this.commitSeq,
    required this.operation,
    required this.deleted,
    required this.createdAt,
    required this.envelope,
    this.restoreUntil,
    this.redaction,
    this.autoPurgeEnabled = false,
    this.autoPurgeRevision = '0',
  });

  final String recordId;
  final String revisionId;
  final String? baseRevisionId;
  final String commitSeq;
  final String operation;
  final bool deleted;
  final String createdAt;
  final Map<String, dynamic>? envelope;

  /// Absolute server deadline for restoring this delete revision. Older
  /// servers omit it; callers must treat that as unknown, never derive a
  /// purge deadline from the instance's current retention setting.
  final DateTime? restoreUntil;
  final Map<String, dynamic>? redaction;

  /// Per-tombstone Owner consent for bounded Maintenance automatic purge.
  /// Older servers omit both fields; that is treated as disabled at revision 0.
  final bool autoPurgeEnabled;
  final String autoPurgeRevision;

  factory VaultRevisionEntry.fromJson(Map<String, dynamic> json) {
    final redacted = json['operation'] == 'redacted';
    final hasRestoreUntil = json.containsKey('restore_until');
    final hasAutoPurgeEnabled = json.containsKey('auto_purge_enabled');
    final hasAutoPurgeRevision = json.containsKey('auto_purge_revision');
    if (hasAutoPurgeEnabled != hasAutoPurgeRevision) {
      throw const FormatException(
        'Delete revision automatic purge fields must be provided together.',
      );
    }
    final expected = redacted
        ? const {
            'record_id',
            'revision_id',
            'base_revision_id',
            'commit_seq',
            'operation',
            'deleted',
            'created_at',
            'envelope',
            'redaction',
          }
        : const {
            'record_id',
            'revision_id',
            'base_revision_id',
            'commit_seq',
            'operation',
            'deleted',
            'created_at',
            'envelope',
          };
    final allowed = <String>{...expected};
    if (hasRestoreUntil) allowed.add('restore_until');
    if (json['operation'] == 'delete') {
      if (hasAutoPurgeEnabled) allowed.add('auto_purge_enabled');
      if (hasAutoPurgeRevision) allowed.add('auto_purge_revision');
    }
    final recordId = json['record_id'];
    final revisionId = json['revision_id'];
    final commitSeq = json['commit_seq'];
    final operation = json['operation'];
    final deleted = json['deleted'];
    final createdAt = json['created_at'];
    final autoPurgeEnabled = hasAutoPurgeEnabled
        ? json['auto_purge_enabled']
        : false;
    final autoPurgeRevision = hasAutoPurgeRevision
        ? json['auto_purge_revision']
        : '0';
    DateTime? restoreUntil;
    if (hasRestoreUntil) {
      final rawRestoreUntil = json['restore_until'];
      if (operation == 'delete') {
        if (deleted != true ||
            rawRestoreUntil is! String ||
            (restoreUntil = _parseUtcRfc3339(rawRestoreUntil)) == null) {
          throw const FormatException(
            'Delete revision restore_until must be a UTC RFC3339 timestamp.',
          );
        }
      } else if (rawRestoreUntil != null) {
        throw const FormatException(
          'Non-delete revision restore_until must be null.',
        );
      }
    }
    if (recordId is! String ||
        revisionId is! String ||
        commitSeq is! String ||
        !_isDecimal(commitSeq) ||
        operation is! String ||
        deleted is! bool ||
        autoPurgeEnabled is! bool ||
        autoPurgeRevision is! String ||
        !_isDecimal(autoPurgeRevision) ||
        createdAt is! String ||
        (redacted
            ? json['envelope'] != null || json['redaction'] is! Map
            : json['envelope'] is! Map || json.containsKey('redaction')) ||
        json.keys.toSet().length != allowed.length ||
        !json.keys.toSet().containsAll(allowed)) {
      throw const FormatException('Revision history entry is malformed.');
    }
    return VaultRevisionEntry(
      recordId: recordId,
      revisionId: revisionId,
      baseRevisionId: json['base_revision_id'] as String?,
      commitSeq: commitSeq,
      operation: operation,
      deleted: deleted,
      createdAt: createdAt,
      envelope: redacted
          ? null
          : Map<String, dynamic>.from(json['envelope'] as Map),
      restoreUntil: restoreUntil,
      redaction: redacted
          ? Map<String, dynamic>.from(json['redaction'] as Map)
          : null,
      autoPurgeEnabled: autoPurgeEnabled,
      autoPurgeRevision: autoPurgeRevision,
    );
  }

  Map<String, Object?> toJson() => {
    'record_id': recordId,
    'revision_id': revisionId,
    'base_revision_id': baseRevisionId,
    'commit_seq': commitSeq,
    'operation': operation,
    'deleted': deleted,
    'created_at': createdAt,
    'envelope': envelope,
    if (restoreUntil != null)
      'restore_until': restoreUntil!.toUtc().toIso8601String(),
    if (operation == 'delete') ...{
      'auto_purge_enabled': autoPurgeEnabled,
      'auto_purge_revision': autoPurgeRevision,
    },
    if (redaction != null) 'redaction': redaction,
  };
}

final _utcRfc3339Timestamp = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|\+00:00)$',
);

DateTime? _parseUtcRfc3339(Object? value) {
  if (value is! String) return null;
  final match = _utcRfc3339Timestamp.firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  if (year < 1 || month < 1 || month > 12) return null;
  final calendar = DateTime.utc(year, month, day, hour, minute, second);
  if (calendar.year != year ||
      calendar.month != month ||
      calendar.day != day ||
      calendar.hour != hour ||
      calendar.minute != minute ||
      calendar.second != second) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

class VaultConflictEntry {
  const VaultConflictEntry({
    required this.conflictId,
    required this.conflictSeq,
    required this.recordId,
    required this.baseRevisionId,
    required this.resolvedRevisionId,
    required this.resolutionSeq,
    required this.createdAt,
    required this.envelope,
    this.redaction,
  });

  final String conflictId;
  final String conflictSeq;
  final String recordId;
  final String? baseRevisionId;
  final String? resolvedRevisionId;
  final String? resolutionSeq;
  final String createdAt;
  final Map<String, dynamic>? envelope;
  final Map<String, dynamic>? redaction;

  factory VaultConflictEntry.fromJson(Map<String, dynamic> json) {
    final redacted = json['envelope'] == null;
    final expected = redacted
        ? const {
            'conflict_id',
            'conflict_seq',
            'record_id',
            'base_revision_id',
            'resolved_revision_id',
            'resolution_seq',
            'created_at',
            'envelope',
            'redaction',
          }
        : const {
            'conflict_id',
            'conflict_seq',
            'record_id',
            'base_revision_id',
            'resolved_revision_id',
            'resolution_seq',
            'created_at',
            'envelope',
          };
    final conflictId = json['conflict_id'];
    final conflictSeq = json['conflict_seq'];
    final recordId = json['record_id'];
    final createdAt = json['created_at'];
    final resolutionSeq = json['resolution_seq'];
    if (conflictId is! String ||
        recordId is! String ||
        createdAt is! String ||
        conflictSeq is! String ||
        !_isDecimal(conflictSeq) ||
        (resolutionSeq != null &&
            (resolutionSeq is! String || !_isDecimal(resolutionSeq))) ||
        (redacted
            ? json['resolved_revision_id'] != null ||
                  json['envelope'] != null ||
                  json['redaction'] is! Map
            : json['envelope'] is! Map || json.containsKey('redaction')) ||
        json.keys.toSet().length != expected.length ||
        !json.keys.toSet().containsAll(expected)) {
      throw const FormatException('Conflict history entry is malformed.');
    }
    return VaultConflictEntry(
      conflictId: conflictId,
      conflictSeq: conflictSeq,
      recordId: recordId,
      baseRevisionId: json['base_revision_id'] as String?,
      resolvedRevisionId: json['resolved_revision_id'] as String?,
      resolutionSeq: resolutionSeq as String?,
      createdAt: createdAt,
      envelope: redacted
          ? null
          : Map<String, dynamic>.from(json['envelope'] as Map),
      redaction: redacted
          ? Map<String, dynamic>.from(json['redaction'] as Map)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'conflict_id': conflictId,
    'conflict_seq': conflictSeq,
    'record_id': recordId,
    'base_revision_id': baseRevisionId,
    'resolved_revision_id': resolvedRevisionId,
    'resolution_seq': resolutionSeq,
    'created_at': createdAt,
    'envelope': envelope,
    if (redaction != null) 'redaction': redaction,
  };
}

class VaultHistoryPage<T> {
  const VaultHistoryPage({
    required this.snapshotId,
    required this.vaultId,
    required this.highWatermark,
    required this.conflictHighWatermark,
    required this.entries,
    required this.nextCursor,
    required this.hasMore,
    required this.serverGeneration,
  });

  final String snapshotId;
  final String vaultId;
  final String highWatermark;
  final String conflictHighWatermark;
  final List<T> entries;
  final String? nextCursor;
  final bool hasMore;
  final String serverGeneration;

  factory VaultHistoryPage.fromJson(
    Map<String, dynamic> json, {
    required String listKey,
    required T Function(Map<String, dynamic>) parseEntry,
  }) {
    final snapshotId = json['snapshot_id'];
    final vaultId = json['vault_id'];
    final highWatermark = json['high_watermark'];
    final conflictHighWatermark = json['conflict_high_watermark'];
    final rawEntries = json[listKey];
    final nextCursor = json['next_cursor'];
    final hasMore = json['has_more'];
    final generation = json['server_generation'];
    if (snapshotId is! String ||
        vaultId is! String ||
        highWatermark is! String ||
        !_isDecimal(highWatermark) ||
        conflictHighWatermark is! String ||
        !_isDecimal(conflictHighWatermark) ||
        rawEntries is! List ||
        (nextCursor != null && nextCursor is! String) ||
        hasMore is! bool ||
        generation is! String) {
      throw const FormatException('Vault history page is malformed.');
    }
    return VaultHistoryPage<T>(
      snapshotId: snapshotId,
      vaultId: vaultId,
      highWatermark: highWatermark,
      conflictHighWatermark: conflictHighWatermark,
      entries: rawEntries
          .map((item) => parseEntry(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false),
      nextCursor: nextCursor as String?,
      hasMore: hasMore,
      serverGeneration: generation,
    );
  }
}

class DownloadedVaultObject {
  const DownloadedVaultObject({required this.bytes, required this.sha256});

  final Uint8List bytes;
  final String sha256;
}

bool _isDecimal(String value) => RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value);

class ApiClient {
  ApiClient({
    http.Client? client,
    required String baseUrl,
    @visibleForTesting
    this.controlPlaneResponseBodyTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       baseUrl = _normalize(baseUrl);

  final http.Client _client;
  final String baseUrl;
  @visibleForTesting
  final Duration controlPlaneResponseBodyTimeout;
  String? accessToken;

  static String _normalize(String value) {
    final uri = Uri.parse(value.trim());
    if (!uri.hasScheme || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException(
        'Server URL must use https:// or a loopback http:// address.',
      );
    }
    if (uri.scheme == 'http' && !_isLoopback(uri.host)) {
      throw const FormatException(
        'Remote server URLs must use HTTPS. HTTP is allowed only for localhost development.',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException(
        'Server URL cannot contain credentials, query or fragment',
      );
    }
    return uri
        .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
        .toString();
  }

  static bool _isLoopback(String host) =>
      host.toLowerCase() == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = Uri.parse(baseUrl);
    final joined = '${root.path}${path.startsWith('/') ? path : '/$path'}';
    return root.replace(path: joined, queryParameters: query);
  }

  /// The WebSocket endpoint is the same API origin and preserves any reverse
  /// proxy path prefix. Authentication is by a one-time first frame, never a
  /// query parameter or WebSocket subprotocol.
  Uri notificationsWebSocketUri() {
    final endpoint = _uri('/api/v1/notifications');
    return endpoint.replace(
      scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
      query: null,
      fragment: null,
    );
  }

  /// Native clients set this as the exact Origin header expected by the
  /// notification service. Browsers set their page origin automatically.
  String get notificationsOrigin => Uri.parse(baseUrl).origin;

  /// Creates an ephemeral, host-owned collaboration room. The request contains
  /// only signed opaque observer keyboxes; the server never receives the
  /// session secret or terminal plaintext.
  Future<Map<String, dynamic>> createTerminalCollaborationSession(
    String vaultId,
    Map<String, Object?> body,
  ) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    return post('/api/v1/vaults/$vaultId/terminal-sessions', body);
  }

  /// Mints a one-use observer WebSocket ticket and returns its host-signed
  /// session keybox. Neither value is persisted by this API client.
  Future<Map<String, dynamic>> terminalCollaborationTicket({
    required String vaultId,
    required String sessionId,
  }) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(sessionId, 'sessionId');
    return postEmpty(
      '/api/v1/vaults/$vaultId/terminal-sessions/$sessionId/ticket',
    );
  }

  /// Creates/repeats one host-approved controller lease. The signed keybox is
  /// encrypted for the named registered device; the server cannot open it.
  Future<Map<String, dynamic>> createTerminalControllerLease({
    required String vaultId,
    required String sessionId,
    required Map<String, Object?> body,
  }) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(sessionId, 'sessionId');
    return post(
      '/api/v1/vaults/$vaultId/terminal-sessions/$sessionId/controller-lease',
      body,
    );
  }

  /// Mints a one-use WebSocket ticket for the currently granted controller.
  /// The returned keybox and ticket are transient and must not be persisted.
  Future<Map<String, dynamic>> terminalControllerTicket({
    required String vaultId,
    required String sessionId,
  }) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(sessionId, 'sessionId');
    return postEmpty(
      '/api/v1/vaults/$vaultId/terminal-sessions/$sessionId/controller-lease/ticket',
    );
  }

  /// Revokes the active controller lease without stopping the host room.
  Future<void> revokeTerminalControllerLease({
    required String vaultId,
    required String sessionId,
  }) async {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(sessionId, 'sessionId');
    await delete(
      '/api/v1/vaults/$vaultId/terminal-sessions/$sessionId/controller-lease',
    );
  }

  /// Ends the ephemeral collaboration room. The caller must also close its
  /// local WebSocket and clear the in-memory session key.
  Future<void> stopTerminalCollaborationSession({
    required String vaultId,
    required String sessionId,
  }) async {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(sessionId, 'sessionId');
    await delete('/api/v1/vaults/$vaultId/terminal-sessions/$sessionId');
  }

  /// Builds a collaboration WebSocket URI from a server-provided path while
  /// preserving this ApiClient's reverse-proxy path prefix. Tickets are sent
  /// in the first text frame, never in the URL.
  Uri terminalCollaborationWebSocketUri(String connectPath) {
    final endpoint = Uri.parse(connectPath);
    final pathSegments = endpoint.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (!endpoint.hasScheme &&
        endpoint.userInfo.isEmpty &&
        endpoint.host.isEmpty &&
        !endpoint.hasQuery &&
        !endpoint.hasFragment &&
        pathSegments.length == 3 &&
        pathSegments.join('/') == 'collaboration/v1/connect') {
      final root = Uri.parse(baseUrl);
      final websocketScheme = switch (root.scheme) {
        'https' => 'wss',
        'http' when _isLoopback(root.host) => 'ws',
        'http' => throw const FormatException(
          'Terminal collaboration requires HTTPS outside localhost development.',
        ),
        _ => throw const FormatException('Unsupported server URL scheme.'),
      };
      final prefix = root.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      return root.replace(
        scheme: websocketScheme,
        pathSegments: [...prefix, ...pathSegments],
        query: null,
        fragment: null,
      );
    }
    throw const FormatException(
      'Invalid terminal collaboration WebSocket path.',
    );
  }

  static void _requireCanonicalUuid(String value, String field) {
    if (!_isCanonicalLowercaseUuid(value)) {
      throw ArgumentError.value(value, field, 'Must be a canonical UUID.');
    }
  }

  Map<String, String> _headers({bool authenticated = true}) => {
    'Accept': 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
    if (authenticated && accessToken != null) ...{
      'Authorization': 'Bearer $accessToken',
      _clientCapabilityMarkerHeader: _clientCapabilityMarker,
      _clientRedactionMarkerHeader: 'v1',
    },
  };

  Map<String, String> _withoutRedactionMarker(Map<String, String>? headers) => {
    for (final entry in (headers ?? const <String, String>{}).entries)
      if (entry.key.toLowerCase() != _clientRedactionMarkerHeader.toLowerCase())
        entry.key: entry.value,
  };

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) => _request('GET', path, query: query, authenticated: authenticated);

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, Object?> body = const {},
  ]) => _request('POST', path, body: body);

  Future<Map<String, dynamic>> postEmpty(String path) => _request('POST', path);

  Future<Map<String, dynamic>> postPublic(
    String path, [
    Map<String, Object?> body = const {},
  ]) => _request('POST', path, body: body, authenticated: false);

  Future<Map<String, dynamic>> put(String path, Map<String, Object?> body) =>
      _request('PUT', path, body: body);

  Future<Map<String, dynamic>> delete(
    String path, {
    Map<String, Object?>? body,
  }) => _request('DELETE', path, body: body);

  Future<Map<String, dynamic>> putBytes(
    String path,
    List<int> bytes, {
    Map<String, String>? headers,
  }) async {
    final request = http.Request('PUT', _uri(path))
      // Auth headers and bytes must not be forwarded to a redirect target,
      // especially if an HTTPS endpoint redirects to plain HTTP.
      ..followRedirects = false
      ..headers.addAll({
        if (accessToken != null) ...{'Authorization': 'Bearer $accessToken'},
        'Content-Type': 'application/octet-stream',
        ..._withoutRedactionMarker(headers),
        if (accessToken != null)
          _clientCapabilityMarkerHeader: _clientCapabilityMarker,
        if (accessToken != null) _clientRedactionMarkerHeader: 'v1',
      })
      ..bodyBytes = bytes;
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 45));
    final response = await http.Response.fromStream(streamed);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool authenticated = true,
    Map<String, String>? extraHeaders,
  }) async {
    final request = http.Request(method, _uri(path, query))
      // Login material, bearer tokens, and other request bodies are scoped to
      // the configured HTTPS/loopback origin and never follow redirects.
      ..followRedirects = false
      ..headers.addAll({
        ..._headers(authenticated: authenticated),
        ..._withoutRedactionMarker(extraHeaders),
        if (authenticated && accessToken != null)
          _clientCapabilityMarkerHeader: _clientCapabilityMarker,
        if (authenticated && accessToken != null)
          _clientRedactionMarkerHeader: 'v1',
      });
    if (body != null) request.body = jsonEncode(body);
    late final http.StreamedResponse streamed;
    try {
      streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on http.ClientException {
      // Only the read-only synchronization control/data-plane GETs can be
      // classified as transport unavailable. A write may have committed even
      // when its response is lost, so POST/PUT/DELETE errors are never wrapped.
      if (method == 'GET' &&
          _isVaultSyncReadPath(path) &&
          (!kIsWeb || browser.browserReportsOffline)) {
        throw SyncReadTransportUnavailableException(path: Uri.parse(path).path);
      }
      if (method == 'GET' && _isAccountControlPlaneReadPath(path)) {
        throw ApiTransportException(method: method, path: Uri.parse(path).path);
      }
      rethrow;
    } on TimeoutException {
      if (method == 'GET' && _isAccountControlPlaneReadPath(path)) {
        throw ApiTransportException(method: method, path: Uri.parse(path).path);
      }
      rethrow;
    }
    final isControlPlaneRead =
        method == 'GET' && _isAccountControlPlaneReadPath(path);
    late final http.Response response;
    try {
      response = isControlPlaneRead
          ? await _readControlPlaneResponse(streamed)
          : await http.Response.fromStream(streamed);
    } catch (_) {
      // A complete read is required before decoding or trusting membership.
      // Transport errors in its body are retryable for this idempotent GET;
      // _decode stays outside this block so malformed complete responses still
      // fail closed in the controller.
      if (isControlPlaneRead) {
        throw ApiTransportException(method: method, path: Uri.parse(path).path);
      }
      rethrow;
    }
    return _decode(response);
  }

  Future<http.Response> _readControlPlaneResponse(
    http.StreamedResponse streamed,
  ) async {
    final iterator = StreamIterator<List<int>>(streamed.stream);
    final body = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();
    try {
      while (true) {
        final remaining = controlPlaneResponseBodyTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Control-plane response body timed out.');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        body.add(iterator.current);
      }
    } catch (_) {
      unawaited(iterator.cancel());
      rethrow;
    }
    return http.Response.bytes(
      body.takeBytes(),
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  bool _isVaultSyncReadPath(String path) {
    final parsed = Uri.tryParse(path);
    if (parsed == null) return false;
    if (parsed.path == '/api/v1/devices') return true;
    final segments = parsed.pathSegments;
    return segments.length == 5 &&
        segments[0] == 'api' &&
        segments[1] == 'v1' &&
        segments[2] == 'vaults' &&
        segments[3].isNotEmpty &&
        const {'devices', 'changes', 'conflict-changes'}.contains(segments[4]);
  }

  bool _isAccountControlPlaneReadPath(String path) {
    final parsed = Uri.tryParse(path);
    if (parsed == null) return false;
    if (parsed.path == '/api/v1/devices' || parsed.path == '/api/v1/vaults') {
      return true;
    }
    final segments = parsed.pathSegments;
    return segments.length == 5 &&
        segments[0] == 'api' &&
        segments[1] == 'v1' &&
        segments[2] == 'vaults' &&
        segments[3].isNotEmpty &&
        const {'devices', 'members', 'membership'}.contains(segments[4]);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> value = const {};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) value = decoded;
      } on FormatException {
        if (response.statusCode >= 400) {
          throw ApiException(
            statusCode: response.statusCode,
            code: 'INVALID_RESPONSE',
            message: currentL10n.theServerReturnedAnInvalidResponse,
          );
        }
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = value['error'] is Map
          ? Map<String, dynamic>.from(value['error'] as Map)
          : <String, dynamic>{};
      throw ApiException(
        statusCode: response.statusCode,
        code: error['code'] as String? ?? 'HTTP_${response.statusCode}',
        message: error['message'] as String? ?? currentL10n.requestFailed,
        requestId: error['request_id'] as String?,
        details: Map<String, dynamic>.from(
          error['details'] as Map? ?? const {},
        ),
      );
    }
    return value;
  }

  Future<InstanceInfo> fetchInstance() async => InstanceInfo.fromJson(
    await get('/api/v1/instance', authenticated: false),
  );

  Future<NotificationTicket> createNotificationTicket() async =>
      NotificationTicket.fromJson(await post('/api/v1/notifications/tickets'));

  /// Registers this device's FCM token. Tokens are validated locally and are
  /// never included in response DTOs or error messages.
  Future<MobilePushEndpointResult> registerMobilePushEndpoint({
    required String deviceId,
    required String provider,
    required String token,
  }) async {
    if (!_isCanonicalLowercaseUuid(deviceId)) {
      throw ArgumentError('Device ID must be a canonical lowercase UUID.');
    }
    if (provider != 'fcm_v1' && provider != 'apns') {
      throw ArgumentError('Invalid mobile push provider.');
    }
    final validToken = provider == 'fcm_v1'
        ? token.length >= 16 &&
              token.length <= 4096 &&
              token.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e)
        : RegExp(r'^(?:[0-9A-Fa-f]{2}){16,256}$').hasMatch(token);
    if (!validToken) throw ArgumentError('Invalid mobile push token.');
    final response = await put(
      '/api/v1/notifications/push-endpoints/${Uri.encodeComponent(deviceId)}',
      {'provider': provider, 'token': token},
    );
    return MobilePushEndpointResult.fromJson(
      response,
      expectedStatus: 'registered',
      expectedDeviceId: deviceId,
      expectedProvider: provider,
    );
  }

  Future<MobilePushEndpointResult> removeMobilePushEndpoint({
    required String deviceId,
    required String provider,
  }) async {
    if (!_isCanonicalLowercaseUuid(deviceId)) {
      throw ArgumentError('Device ID must be a canonical lowercase UUID.');
    }
    if (provider != 'fcm_v1' && provider != 'apns') {
      throw ArgumentError('Invalid mobile push provider.');
    }
    final response = await delete(
      '/api/v1/notifications/push-endpoints/${Uri.encodeComponent(deviceId)}/$provider',
    );
    return MobilePushEndpointResult.fromJson(
      response,
      expectedStatus: 'removed',
      expectedDeviceId: deviceId,
      expectedProvider: provider,
    );
  }

  Future<Map<String, dynamic>> prelogin(String username) =>
      postPublic('/api/v1/auth/prelogin', {'username': username});

  Future<AuthSession> register({
    required String accountId,
    required String username,
    String? bootstrapToken,
    String? instanceInvitationToken,
    required Map<String, Object?> kdf,
    required String loginVerifier,
    required Map<String, Object?> accountKeyEnvelope,
    required Map<String, Object?> device,
    required Map<String, Object?> initialVault,
  }) async {
    if ((bootstrapToken == null) == (instanceInvitationToken == null)) {
      throw ArgumentError(
        'Provide exactly one registration token: bootstrap or instance invitation.',
      );
    }
    final json = await postPublic('/api/v1/auth/register', {
      'account_id': accountId,
      'username': username,
      if (bootstrapToken != null) 'bootstrap_token': bootstrapToken,
      if (instanceInvitationToken != null)
        'instance_invitation_token': instanceInvitationToken,
      'kdf': kdf,
      'login_verifier': loginVerifier,
      'account_key_envelope': accountKeyEnvelope,
      'device': device,
      'initial_vault': initialVault,
    });
    final session = AuthSession.fromJson(json);
    accessToken = session.accessToken;
    return session;
  }

  Future<AuthLoginResult> login({
    required String username,
    required String loginVerifier,
    required String deviceId,
  }) async {
    final result = AuthLoginResult.fromJson(
      await postPublic('/api/v1/auth/login', {
        'username': username,
        'login_verifier': loginVerifier,
        'device_id': deviceId,
      }),
    );
    if (result case AuthenticatedLogin(:final session)) {
      accessToken = session.accessToken;
    } else if (result is MfaLoginChallenge) {
      // A challenge is not an authenticated session, including when this
      // client previously held a now-stale access token.
      accessToken = null;
    }
    return result;
  }

  Future<AuthSession> completeMfaLogin({
    required String challengeId,
    String? totpCode,
    String? recoveryCode,
  }) async {
    if (challengeId.isEmpty || (totpCode == null) == (recoveryCode == null)) {
      throw ArgumentError(
        'Provide a challenge and exactly one MFA response method.',
      );
    }
    final json = await postPublic('/api/v1/auth/login/mfa', {
      'challenge_id': challengeId,
      if (totpCode != null) 'totp_code': totpCode,
      if (recoveryCode != null) 'recovery_code': recoveryCode,
    });
    final session = AuthSession.fromJson(json);
    accessToken = session.accessToken;
    return session;
  }

  Future<AuthSession> refresh(String refreshToken) async {
    final json = await postPublic('/api/v1/auth/refresh', {
      'refresh_token': refreshToken,
    });
    final session = AuthSession.fromJson(json);
    accessToken = session.accessToken;
    return session;
  }

  Future<void> logout() async {
    final tokenBeingLoggedOut = accessToken;
    try {
      await post('/api/v1/auth/logout');
    } finally {
      // A new login can reuse this ApiClient while the old logout request is
      // still in flight. Clear only the credential used by this request so a
      // late response cannot erase the newer session's token.
      if (accessToken == tokenBeingLoggedOut) accessToken = null;
    }
  }

  Future<AccountProfile> accountProfile() async =>
      AccountProfile.fromJson(await get('/api/v1/me'));

  Future<AccountMfaStatus> accountMfaStatus() async =>
      AccountMfaStatus.fromJson(await get('/api/v1/auth/mfa'));

  Future<MfaTotpSetup> setupMfaTotp(String currentLoginVerifier) async =>
      MfaTotpSetup.fromJson(
        await post('/api/v1/auth/mfa/totp/setup', {
          'current_login_verifier': currentLoginVerifier,
        }),
      );

  Future<MfaRecoveryCodes> confirmMfaTotp({
    required String currentLoginVerifier,
    required String totpCode,
  }) async => MfaRecoveryCodes.fromJson(
    await post('/api/v1/auth/mfa/totp/confirm', {
      'current_login_verifier': currentLoginVerifier,
      'totp_code': totpCode,
    }),
  );

  Future<MfaRecoveryCodes> rotateMfaRecoveryCodes({
    required String currentLoginVerifier,
    required String totpCode,
  }) async => MfaRecoveryCodes.fromJson(
    await post('/api/v1/auth/mfa/recovery-codes', {
      'current_login_verifier': currentLoginVerifier,
      'totp_code': totpCode,
    }),
  );

  Future<AccountMfaStatus> disableMfaTotp({
    required String currentLoginVerifier,
    required String totpCode,
  }) async => AccountMfaStatus.fromJson(
    await delete(
      '/api/v1/auth/mfa/totp',
      body: {
        'current_login_verifier': currentLoginVerifier,
        'totp_code': totpCode,
      },
    ),
  );

  Future<InstanceAdminOverview> instanceAdminOverview() async =>
      InstanceAdminOverview.fromJson(await get('/api/v1/admin/overview'));

  Future<InstanceAdminPushHealth> instanceAdminPushHealth() async =>
      InstanceAdminPushHealth.fromJson(await get('/api/v1/admin/push-health'));

  Future<InstanceAdminMetricsCredentialStatus>
  instanceAdminMetricsCredentialStatus() async =>
      InstanceAdminMetricsCredentialStatus.fromJson(
        await get('/api/v1/admin/metrics-credential'),
      );

  Future<InstanceAdminMetricsCredentialRotation>
  rotateInstanceAdminMetricsCredential() async =>
      InstanceAdminMetricsCredentialRotation.fromJson(
        await postEmpty('/api/v1/admin/metrics-credential'),
      );

  Future<InstanceAdminMetricsCredentialRevocation>
  revokeInstanceAdminMetricsCredential() async =>
      InstanceAdminMetricsCredentialRevocation.fromJson(
        await delete('/api/v1/admin/metrics-credential'),
      );

  Future<InstanceAdminRelayPolicy> instanceAdminRelayPolicy() async =>
      InstanceAdminRelayPolicy.fromJson(
        await get('/api/v1/admin/relay-policy'),
      );

  Future<InstanceAdminRelayPolicy> updateInstanceAdminRelayPolicy({
    required int expectedRevision,
    required AdminRelayPolicyDraft draft,
    required AdminRelayPolicyLimits deploymentLimits,
  }) async {
    if (expectedRevision < 0) {
      throw ArgumentError.value(
        expectedRevision,
        'expectedRevision',
        'Must be non-negative.',
      );
    }
    final validated = AdminRelayPolicyDraft.parseAndValidate(
      enabled: draft.enabled,
      allowCidrsText: draft.allowCidrs.join('\n'),
      allowPortsText: draft.allowPorts.join(','),
      deploymentLimits: deploymentLimits,
    );
    return InstanceAdminRelayPolicy.fromJson(
      await put('/api/v1/admin/relay-policy', {
        'expected_revision': expectedRevision,
        'enabled': validated.enabled,
        'allow_cidrs': validated.allowCidrs,
        'allow_ports': validated.allowPorts,
      }),
    );
  }

  Future<InstanceAdminRelayUserPolicy> instanceAdminRelayUserPolicy(
    String userId,
  ) async {
    _requireCanonicalUuid(userId, 'userId');
    return _parseRelayUserPolicyForUser(
      userId,
      await get('/api/v1/admin/relay-policy/users/$userId'),
    );
  }

  Future<InstanceAdminRelayUserPolicy> updateInstanceAdminRelayUserPolicy({
    required String userId,
    required int expectedRevision,
    required int expectedInstancePolicyRevision,
    required bool enabled,
    required List<String> allowCidrs,
    required List<int> allowPorts,
  }) async {
    _requireCanonicalUuid(userId, 'userId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    _requireNonnegativeRelayPolicyRevision(expectedInstancePolicyRevision);
    final selection = _normalizeRelayUserPolicySelection(
      allowCidrs,
      allowPorts,
    );
    return _parseRelayUserPolicyForUser(
      userId,
      await put('/api/v1/admin/relay-policy/users/$userId', {
        'expected_revision': expectedRevision,
        'expected_instance_policy_revision': expectedInstancePolicyRevision,
        'enabled': enabled,
        'allow_cidrs': selection.cidrs,
        'allow_ports': selection.ports,
      }),
    );
  }

  Future<InstanceAdminRelayUserPolicy> resetInstanceAdminRelayUserPolicy({
    required String userId,
    required int expectedRevision,
  }) async {
    _requireCanonicalUuid(userId, 'userId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    return _parseRelayUserPolicyForUser(
      userId,
      await delete(
        '/api/v1/admin/relay-policy/users/$userId',
        body: {'expected_revision': expectedRevision},
      ),
    );
  }

  Future<List<AdminRelayGroupSummary>> adminRelayGroups() async {
    final response = await get('/api/v1/admin/relay-groups');
    if (response.length != 1 || response['groups'] is! List) {
      throw const FormatException('Invalid admin relay groups response.');
    }
    final groups = (response['groups'] as List)
        .map((value) {
          if (value is! Map || value.keys.any((key) => key is! String)) {
            throw const FormatException('Invalid admin relay group response.');
          }
          return AdminRelayGroupSummary.fromJson(
            Map<String, dynamic>.from(value),
          );
        })
        .toList(growable: false);
    if (groups.map((group) => group.groupId).toSet().length != groups.length) {
      throw const FormatException('Duplicate admin relay group ID.');
    }
    return List.unmodifiable(groups);
  }

  Future<AdminRelayGroupDetail> adminRelayGroup(String groupId) async {
    _requireCanonicalUuid(groupId, 'groupId');
    return _parseAdminRelayGroupDetail(
      groupId,
      await get('/api/v1/admin/relay-groups/$groupId'),
    );
  }

  Future<AdminRelayGroupDetail> createAdminRelayGroup({
    required String name,
  }) async {
    final validatedName = _validateAdminRelayGroupName(name);
    return _parseAdminRelayGroupDetail(
      null,
      await post('/api/v1/admin/relay-groups', {'name': validatedName}),
    );
  }

  Future<AdminRelayGroupDetail> updateAdminRelayGroup({
    required String groupId,
    required int expectedRevision,
    required String name,
  }) async {
    _requireCanonicalUuid(groupId, 'groupId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    return _parseAdminRelayGroupDetail(
      groupId,
      await put('/api/v1/admin/relay-groups/$groupId', {
        'expected_revision': expectedRevision,
        'name': _validateAdminRelayGroupName(name),
      }),
    );
  }

  Future<void> deleteAdminRelayGroup({
    required String groupId,
    required int expectedRevision,
    required int expectedMembershipRevision,
    required int expectedPolicyRevision,
  }) async {
    _requireCanonicalUuid(groupId, 'groupId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    _requireNonnegativeRelayPolicyRevision(expectedMembershipRevision);
    _requireNonnegativeRelayPolicyRevision(expectedPolicyRevision);
    await delete(
      '/api/v1/admin/relay-groups/$groupId',
      body: {
        'expected_revision': expectedRevision,
        'expected_membership_revision': expectedMembershipRevision,
        'expected_policy_revision': expectedPolicyRevision,
      },
    );
  }

  Future<AdminRelayGroupDetail> updateAdminRelayGroupMembers({
    required String groupId,
    required int expectedRevision,
    required List<String> userIds,
  }) async {
    _requireCanonicalUuid(groupId, 'groupId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    for (final userId in userIds) {
      _requireCanonicalUuid(userId, 'userId');
    }
    if (userIds.toSet().length != userIds.length) {
      throw ArgumentError.value(
        userIds,
        'userIds',
        'Must not contain duplicates.',
      );
    }
    final sortedIds = [...userIds]..sort();
    return _parseAdminRelayGroupDetail(
      groupId,
      await put('/api/v1/admin/relay-groups/$groupId/members', {
        'expected_revision': expectedRevision,
        'user_ids': sortedIds,
      }),
    );
  }

  Future<AdminRelayGroupDetail> updateAdminRelayGroupPolicy({
    required String groupId,
    required int expectedRevision,
    required int expectedInstancePolicyRevision,
    required bool enabled,
    required List<String> allowCidrs,
    required List<int> allowPorts,
  }) async {
    _requireCanonicalUuid(groupId, 'groupId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    _requireNonnegativeRelayPolicyRevision(expectedInstancePolicyRevision);
    final selection = _normalizeRelayUserPolicySelection(
      allowCidrs,
      allowPorts,
    );
    return _parseAdminRelayGroupDetail(
      groupId,
      await put('/api/v1/admin/relay-groups/$groupId/relay-policy', {
        'expected_revision': expectedRevision,
        'expected_instance_policy_revision': expectedInstancePolicyRevision,
        'enabled': enabled,
        'allow_cidrs': selection.cidrs,
        'allow_ports': selection.ports,
      }),
    );
  }

  Future<AdminRelayGroupDetail> resetAdminRelayGroupPolicy({
    required String groupId,
    required int expectedRevision,
  }) async {
    _requireCanonicalUuid(groupId, 'groupId');
    _requireNonnegativeRelayPolicyRevision(expectedRevision);
    return _parseAdminRelayGroupDetail(
      groupId,
      await delete(
        '/api/v1/admin/relay-groups/$groupId/relay-policy',
        body: {'expected_revision': expectedRevision},
      ),
    );
  }

  AdminRelayGroupDetail _parseAdminRelayGroupDetail(
    String? expectedGroupId,
    Map<String, dynamic> response,
  ) {
    final detail = AdminRelayGroupDetail.fromJson(response);
    if (expectedGroupId != null && detail.groupId != expectedGroupId) {
      throw const FormatException(
        'Admin relay group response has a different group ID.',
      );
    }
    return detail;
  }

  String _validateAdminRelayGroupName(String name) {
    final normalized = name.trim();
    if (!_isValidAdminRelayGroupName(normalized)) {
      throw ArgumentError.value(
        name,
        'name',
        'Invalid admin relay group name.',
      );
    }
    return normalized;
  }

  InstanceAdminRelayUserPolicy _parseRelayUserPolicyForUser(
    String userId,
    Map<String, dynamic> response,
  ) {
    final policy = InstanceAdminRelayUserPolicy.fromJson(response);
    if (policy.userId != userId) {
      throw const FormatException(
        'Admin relay user policy response has a different user ID.',
      );
    }
    return policy;
  }

  static void _requireNonnegativeRelayPolicyRevision(int revision) {
    if (revision < 0) {
      throw ArgumentError.value(
        revision,
        'expectedRevision',
        'Must be non-negative.',
      );
    }
  }

  static ({List<String> cidrs, List<int> ports})
  _normalizeRelayUserPolicySelection(
    List<String> allowCidrs,
    List<int> allowPorts,
  ) {
    final cidrs = _relayPolicyCidrs(allowCidrs).toList()..sort();
    final ports = _relayPolicyPorts(allowPorts).toList()..sort();
    return (
      cidrs: List<String>.unmodifiable(cidrs),
      ports: List<int>.unmodifiable(ports),
    );
  }

  Future<InstanceAdminBackupStatus> instanceAdminBackupStatus() async =>
      InstanceAdminBackupStatus.fromJson(
        await get('/api/v1/admin/backup-status'),
      );

  Future<InstanceAdminBackupReplicationStatus>
  instanceAdminBackupReplicationStatus() async =>
      InstanceAdminBackupReplicationStatus.fromJson(
        await get('/api/v1/admin/backup-replication'),
      );

  Future<InstanceAdminBackupBucketAccessCheck>
  instanceAdminBackupBucketAccessCheck() async =>
      InstanceAdminBackupBucketAccessCheck.fromJson(
        await post(
          '/api/v1/admin/backup-replication/preflight',
          const <String, Object?>{},
        ),
      );

  Future<InstanceAdminBackupSchedule> instanceAdminBackupSchedule() async =>
      InstanceAdminBackupSchedule.fromJson(
        await get('/api/v1/admin/backup-schedule'),
      );

  Future<InstanceAdminBackupSchedule> updateInstanceAdminBackupSchedule(
    int? intervalHours,
  ) async {
    if (intervalHours != null && (intervalHours < 1 || intervalHours > 720)) {
      throw ArgumentError.value(
        intervalHours,
        'intervalHours',
        'Must be null or between 1 and 720.',
      );
    }
    return InstanceAdminBackupSchedule.fromJson(
      await put('/api/v1/admin/backup-schedule', {
        'interval_hours': intervalHours,
      }),
    );
  }

  Future<InstanceAdminRestoreSourcesPage> instanceAdminRestoreSources({
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return InstanceAdminRestoreSourcesPage.fromJson(
      await get(
        '/api/v1/admin/restore-sources',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
      limit: limit,
      offset: offset,
    );
  }

  Future<AdminVaultPage> adminVaults({int limit = 50, int offset = 0}) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return AdminVaultPage.fromJson(
      await get(
        '/api/v1/admin/vaults',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
    );
  }

  Future<AdminVaultQuotaReceipt> updateAdminVaultQuota({
    required String vaultId,
    required int quotaBytes,
  }) async {
    if (!_isCanonicalLowercaseUuid(vaultId)) {
      throw ArgumentError.value(
        vaultId,
        'vaultId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (quotaBytes < 1 || quotaBytes > maxAdminVaultQuotaBytes) {
      throw ArgumentError.value(
        quotaBytes,
        'quotaBytes',
        'Must be between 1 byte and 1 TiB.',
      );
    }
    return AdminVaultQuotaReceipt.fromJson(
      await put('/api/v1/admin/vaults/$vaultId/quota', {
        'quota_bytes': quotaBytes,
      }),
      expectedVaultId: vaultId,
    );
  }

  Future<AdminAccountPage> adminAccounts({
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return AdminAccountPage.fromJson(
      await get(
        '/api/v1/admin/accounts',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
    );
  }

  Future<AdminAccountInvitationsPage> adminAccountInvitations({
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return AdminAccountInvitationsPage.fromJson(
      await get(
        '/api/v1/admin/account-invitations',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
      limit: limit,
      offset: offset,
    );
  }

  Future<AdminAccountInvitationIssueReceipt> createAdminAccountInvitation({
    required String username,
    int? expiresInSeconds,
  }) async {
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty) {
      throw ArgumentError.value(username, 'username', 'Must not be empty.');
    }
    if (expiresInSeconds != null &&
        (expiresInSeconds < 60 || expiresInSeconds > 2592000)) {
      throw ArgumentError.value(
        expiresInSeconds,
        'expiresInSeconds',
        'Must be between 60 and 2592000.',
      );
    }
    return AdminAccountInvitationIssueReceipt.fromJson(
      await post('/api/v1/admin/account-invitations', {
        'username': normalizedUsername,
        if (expiresInSeconds != null) 'expires_in_seconds': expiresInSeconds,
      }),
    );
  }

  Future<AdminAccountInvitationRevokeReceipt> revokeAdminAccountInvitation({
    required String invitationId,
  }) async {
    if (!_isCanonicalLowercaseUuid(invitationId)) {
      throw ArgumentError.value(
        invitationId,
        'invitationId',
        'Must be a canonical lowercase UUID.',
      );
    }
    return AdminAccountInvitationRevokeReceipt.fromJson(
      await postEmpty('/api/v1/admin/account-invitations/$invitationId/revoke'),
      expectedInvitationId: invitationId,
    );
  }

  Future<AdminAccountStatusReceipt> setAdminAccountStatus({
    required String userId,
    required String status,
  }) async {
    if (!_isCanonicalLowercaseUuid(userId)) {
      throw ArgumentError.value(
        userId,
        'userId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (!const {'active', 'disabled'}.contains(status)) {
      throw ArgumentError.value(
        status,
        'status',
        'Must be active or disabled.',
      );
    }
    return AdminAccountStatusReceipt.fromJson(
      await put('/api/v1/admin/accounts/$userId/status', {'status': status}),
      expectedAccountId: userId,
      expectedStatus: status,
    );
  }

  Future<AdminAccountSessionsReceipt> revokeAdminAccountSessions({
    required String userId,
  }) async {
    if (!_isCanonicalLowercaseUuid(userId)) {
      throw ArgumentError.value(
        userId,
        'userId',
        'Must be a canonical lowercase UUID.',
      );
    }
    return AdminAccountSessionsReceipt.fromJson(
      await post('/api/v1/admin/accounts/$userId/sessions/revoke'),
      expectedAccountId: userId,
    );
  }

  Future<AdminAccountSessionsPage> adminAccountSessions({
    required String userId,
    int limit = 50,
    int offset = 0,
  }) async {
    if (!_isCanonicalLowercaseUuid(userId)) {
      throw ArgumentError.value(
        userId,
        'userId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return AdminAccountSessionsPage.fromJson(
      await get(
        '/api/v1/admin/accounts/$userId/sessions',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
    );
  }

  Future<AdminAccountSessionRevokeReceipt> revokeAdminAccountSession({
    required String userId,
    required String sessionId,
  }) async {
    if (!_isCanonicalLowercaseUuid(userId)) {
      throw ArgumentError.value(
        userId,
        'userId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (!_isCanonicalLowercaseUuid(sessionId)) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Must be a canonical lowercase UUID.',
      );
    }
    return AdminAccountSessionRevokeReceipt.fromJson(
      await post('/api/v1/admin/accounts/$userId/sessions/$sessionId/revoke'),
      expectedAccountId: userId,
      expectedSessionId: sessionId,
    );
  }

  Future<InstanceAdminAuditPage> adminAudit({
    String? cursor,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 200.');
    }
    if (cursor != null && cursor.isEmpty) {
      throw ArgumentError.value(cursor, 'cursor', 'Must not be empty.');
    }
    return InstanceAdminAuditPage.fromJson(
      await get(
        '/api/v1/admin/audit',
        query: {'limit': '$limit', if (cursor != null) 'cursor': cursor},
      ),
    );
  }

  Future<AdminMaintenanceJobsPage> adminMaintenanceJobs({
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Must be between 0 and 1000000.',
      );
    }
    return AdminMaintenanceJobsPage.fromJson(
      await get(
        '/api/v1/admin/jobs',
        query: {'limit': '$limit', 'offset': '$offset'},
      ),
      limit: limit,
      offset: offset,
    );
  }

  Future<AdminMaintenanceJob> startAdminMaintenanceJob({
    required String requestId,
  }) => _startAdminJob(requestId: requestId, action: 'maintenance');

  Future<AdminMaintenanceJob> startAdminBackupJob({
    required String requestId,
  }) => _startAdminJob(requestId: requestId, action: 'backup');

  Future<AdminMaintenanceJob> startAdminRestoreJob({
    required String requestId,
    required String archiveId,
    required String archiveSource,
  }) => _startAdminJob(
    requestId: requestId,
    action: 'restore',
    archiveId: archiveId,
    archiveSource: archiveSource,
  );

  Future<InstanceAdminRestoreStageDiscard> discardAdminRestoreStage({
    required String restoreJobId,
    required String requestId,
  }) async {
    if (!_isCanonicalLowercaseUuid(restoreJobId)) {
      throw ArgumentError.value(
        restoreJobId,
        'restoreJobId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (!_isCanonicalLowercaseUuid(requestId)) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'Must be a canonical lowercase UUID.',
      );
    }
    final json = await post(
      '/api/v1/admin/restore-stages/${Uri.encodeComponent(restoreJobId)}/discard',
      {'request_id': requestId},
    );
    if (json.length != 1 || !json.containsKey('restore_stage')) {
      throw const FormatException('Invalid restore stage discard response.');
    }
    final rawStage = json['restore_stage'];
    if (rawStage is! Map || rawStage.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid restore stage discard response.');
    }
    final stage = InstanceAdminRestoreStageDiscard.fromJson(
      Map<String, dynamic>.from(rawStage),
    );
    if (stage.restoreJobId != restoreJobId) {
      throw const FormatException(
        'Restore stage response does not match request.',
      );
    }
    return stage;
  }

  Future<AdminMaintenanceJob> _startAdminJob({
    required String requestId,
    required String action,
    String? archiveId,
    String? archiveSource,
  }) async {
    if (!_isCanonicalLowercaseUuid(requestId)) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'Must be a canonical lowercase UUID.',
      );
    }
    if (action == 'restore') {
      if (archiveId == null || !_isCanonicalLowercaseUuid(archiveId)) {
        throw ArgumentError.value(
          archiveId,
          'archiveId',
          'Must be a canonical lowercase UUID.',
        );
      }
      if (!const {'local', 'replica'}.contains(archiveSource)) {
        throw ArgumentError.value(
          archiveSource,
          'archiveSource',
          'Must be local or replica.',
        );
      }
    } else if (archiveId != null || archiveSource != null) {
      throw ArgumentError.value(
        archiveSource ?? archiveId,
        'archiveSource',
        'Only restore jobs accept an archive source and ID.',
      );
    }
    final json = await post('/api/v1/admin/jobs', {
      'request_id': requestId,
      'action': action,
      if (archiveId != null) 'archive_id': archiveId,
      if (archiveSource != null) 'archive_source': archiveSource,
    });
    final rawJob = json['job'];
    if (rawJob is! Map || rawJob.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid admin maintenance job response.');
    }
    final job = AdminMaintenanceJob.fromJson(Map<String, dynamic>.from(rawJob));
    if (job.requestId != requestId ||
        job.action != action ||
        job.archiveId != archiveId ||
        job.archiveSource != archiveSource) {
      throw const FormatException('Admin job response does not match request.');
    }
    return job;
  }

  Future<AuditPage> audit({String? cursor, int limit = 100}) async {
    if (limit < 1 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 200.');
    }
    return AuditPage.fromJson(
      await get(
        '/api/v1/audit',
        query: {
          if (cursor != null) 'cursor': cursor,
          if (limit != 100) 'limit': '$limit',
        },
      ),
    );
  }

  Future<Map<String, dynamic>> deleteAccount(Map<String, Object?> body) =>
      post('/api/v1/account/delete', body);

  Future<Map<String, dynamic>> cancelAccountDeletion({
    required String username,
    required Map<String, Object?> body,
  }) => postPublic('/api/v1/account/delete/cancel', {
    'username': username,
    ...body,
  });

  Future<List<Map<String, dynamic>>> devices() async =>
      _list(await get('/api/v1/devices'), 'devices');

  Future<Map<String, dynamic>> updateDeviceCapabilities(
    Map<String, Object?> report,
  ) => put('/api/v1/devices/capabilities', report);

  Future<Map<String, dynamic>> updateDeviceRedactionCapabilities(
    Map<String, Object?> report,
  ) => put('/api/v1/devices/redaction-capabilities', report);

  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      _list(
        await get('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/devices'),
        'devices',
      );

  Future<List<Map<String, dynamic>>> vaultMembers(String vaultId) async =>
      _list(
        await get('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/members'),
        'members',
      );

  Future<VaultPresenceSnapshot> vaultPresence(String vaultId) async {
    if (!_isCanonicalLowercaseUuid(vaultId)) {
      throw ArgumentError.value(
        vaultId,
        'vaultId',
        'Must be a canonical UUID.',
      );
    }
    return VaultPresenceSnapshot.fromJson(
      await get('/api/v1/vaults/$vaultId/presence'),
    );
  }

  Future<void> heartbeatVaultPresence(String vaultId) async {
    if (!_isCanonicalLowercaseUuid(vaultId)) {
      throw ArgumentError.value(
        vaultId,
        'vaultId',
        'Must be a canonical UUID.',
      );
    }
    final response = await postEmpty('/api/v1/vaults/$vaultId/presence');
    if (response['ttl_seconds'] != 90 ||
        response.keys.toSet().difference(const {
          'expires_at',
          'ttl_seconds',
        }).isNotEmpty ||
        response.length != 2 ||
        response['expires_at'] is! String ||
        DateTime.tryParse(response['expires_at'] as String)?.isUtc != true) {
      throw const FormatException('Invalid Vault presence heartbeat response.');
    }
  }

  Future<Map<String, dynamic>> registerDevice(Map<String, Object?> device) =>
      post('/api/v1/devices', device);

  Future<void> revokeDevice(String deviceId) async =>
      post('/api/v1/devices/${Uri.encodeComponent(deviceId)}/revoke');

  Future<List<VaultDescriptor>> vaults() async => _list(
    await get('/api/v1/vaults'),
    'vaults',
  ).map(VaultDescriptor.fromJson).toList(growable: false);

  Future<Map<String, dynamic>> createVault(Map<String, Object?> body) =>
      post('/api/v1/vaults', body);

  Future<Map<String, dynamic>> membership(String vaultId, {int from = 0}) =>
      get(
        '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/membership',
        query: {'from': '$from'},
      );

  Future<Map<String, dynamic>> invite(
    String vaultId,
    Map<String, Object?> body,
  ) => post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/invitations', body);

  Future<Map<String, dynamic>> acceptInvitation(
    String token,
    Map<String, Object?> body,
  ) => post('/api/v1/invitations/accept', {...body, 'token': token});

  Future<Map<String, dynamic>> rotateVaultKey(
    String vaultId,
    Map<String, Object?> body,
  ) => post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/keys/rotate', body);

  Future<Map<String, dynamic>> transferVaultOwnership(
    String vaultId,
    Map<String, Object?> body,
  ) => post(
    '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/ownership/transfer',
    body,
  );

  Future<Map<String, dynamic>> deleteVault(
    String vaultId,
    Map<String, Object?> body,
  ) => delete('/api/v1/vaults/${Uri.encodeComponent(vaultId)}', body: body);

  Future<Map<String, dynamic>> cancelVaultDeletion(
    String vaultId,
    Map<String, Object?> body,
  ) => post(
    '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/deletion/cancel',
    body,
  );

  Future<PasswordChangeReceipt> changePassword(
    Map<String, Object?> body,
  ) async {
    final operationId = body['operation_id'];
    if (operationId is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(operationId)) {
      throw const FormatException('Password change operation ID is invalid.');
    }
    return PasswordChangeReceipt.fromJson(
      await post('/api/v1/auth/password-change', body),
      expectedOperationId: operationId,
    );
  }

  Future<Map<String, dynamic>> configureAccountRecovery(
    Map<String, Object?> body,
  ) => put('/api/v1/auth/recovery', body);

  Future<AccountRecoveryContexts> accountRecoveryContexts() async =>
      AccountRecoveryContexts.fromJson(
        await get('/api/v1/auth/recovery/contexts'),
      );

  Future<Map<String, dynamic>> uploadAccountRecoveryKeyEnvelopes(
    Map<String, Object?> body,
  ) => put('/api/v1/auth/recovery/key-envelopes', body);

  Future<Map<String, dynamic>> disableAccountRecovery(
    Map<String, Object?> body,
  ) => delete('/api/v1/auth/recovery', body: body);

  Future<Map<String, dynamic>> startAccountRecovery(String username) =>
      postPublic('/api/v1/auth/recovery/start', {'username': username});

  Future<Map<String, dynamic>> inspectAccountRecovery(
    Map<String, Object?> body,
  ) => postPublic('/api/v1/auth/recovery/inspect', body);

  Future<Map<String, dynamic>> completeAccountRecovery(
    Map<String, Object?> body,
  ) => postPublic('/api/v1/auth/recovery/complete', body);

  @Deprecated('Use configureAccountRecovery.')
  Future<Map<String, dynamic>> createPasswordRecovery(
    Map<String, Object?> body,
  ) => configureAccountRecovery(body);

  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) => post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/sync/push', batch);

  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async => SyncPage.fromJson(
    await get(
      '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/changes',
      query: {if (cursor != null) 'cursor': cursor, 'limit': '$limit'},
    ),
  );

  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async {
    if ((afterSeq != null &&
            (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(afterSeq) ||
                serverGeneration == null ||
                serverGeneration.isEmpty)) ||
        (afterSeq == null && serverGeneration != null) ||
        limit < 1 ||
        limit > 100) {
      throw ArgumentError('Invalid conflict feed cursor or page limit.');
    }
    final expectedAfter = afterSeq ?? '0';
    return ConflictChangesPage.fromJson(
      await get(
        '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/conflict-changes',
        query: {
          if (afterSeq != null) 'after_seq': afterSeq,
          'limit': '$limit',
          if (serverGeneration != null) 'server_generation': serverGeneration,
        },
      ),
      expectedVaultId: vaultId,
      expectedAfterSeq: expectedAfter,
      limit: limit,
    );
  }

  Future<Map<String, dynamic>> createSnapshot(String vaultId) =>
      post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/snapshots');

  Future<Map<String, dynamic>> snapshot(
    String snapshotId, {
    int? limit,
    String? pageCursor,
  }) {
    if (limit != null && (limit < 1 || limit > 100)) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (pageCursor != null &&
        (pageCursor.isEmpty || pageCursor.length > 2048)) {
      throw ArgumentError.value(
        pageCursor,
        'pageCursor',
        'Must be a non-empty opaque cursor of at most 2048 characters.',
      );
    }
    return get(
      '/api/v1/snapshots/${Uri.encodeComponent(snapshotId)}',
      query: {
        if (limit != null) 'limit': '$limit',
        if (pageCursor != null) 'page_cursor': pageCursor,
      },
    );
  }

  Future<VaultHistoryPage<VaultRevisionEntry>> revisions(
    String vaultId, {
    required String snapshotId,
    String? cursor,
    int limit = 500,
  }) async => VaultHistoryPage<VaultRevisionEntry>.fromJson(
    await get(
      '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/revisions',
      query: {
        'snapshot_id': snapshotId,
        if (cursor != null) 'cursor': cursor,
        'limit': '$limit',
      },
    ),
    listKey: 'revisions',
    parseEntry: VaultRevisionEntry.fromJson,
  );

  /// Permanently removes the currently deleted head only when it still
  /// matches the revision and commit sequence shown in the recycle bin. The
  /// returned proof is not trusted here; the sync repository verifies it
  /// against the pinned instance signing key before erasing local state.
  Future<Map<String, dynamic>> purgeRecord({
    required String vaultId,
    required String recordId,
    required String expectedDeletedRevisionId,
    required String expectedDeletedSeq,
  }) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(recordId, 'recordId');
    _requireCanonicalUuid(
      expectedDeletedRevisionId,
      'expectedDeletedRevisionId',
    );
    if (!_isDecimal(expectedDeletedSeq) || expectedDeletedSeq == '0') {
      throw ArgumentError.value(
        expectedDeletedSeq,
        'expectedDeletedSeq',
        'Must be a positive canonical decimal sequence.',
      );
    }
    return post('/api/v1/vaults/$vaultId/records/$recordId/purge', {
      'expected_deleted_revision_id': expectedDeletedRevisionId,
      'expected_deleted_seq': expectedDeletedSeq,
    });
  }

  /// Records or withdraws the Owner's consent for a future automatic purge of
  /// this exact deleted head. This endpoint never performs a purge itself.
  Future<Map<String, dynamic>> setRecordAutomaticPurge({
    required String vaultId,
    required String recordId,
    required String expectedDeletedRevisionId,
    required String expectedDeletedSeq,
    required String expectedPolicyRevision,
    required bool enabled,
  }) {
    _requireCanonicalUuid(vaultId, 'vaultId');
    _requireCanonicalUuid(recordId, 'recordId');
    _requireCanonicalUuid(
      expectedDeletedRevisionId,
      'expectedDeletedRevisionId',
    );
    if (!_isDecimal(expectedDeletedSeq) || expectedDeletedSeq == '0') {
      throw ArgumentError.value(
        expectedDeletedSeq,
        'expectedDeletedSeq',
        'Must be a positive canonical decimal sequence.',
      );
    }
    if (!_isDecimal(expectedPolicyRevision)) {
      throw ArgumentError.value(
        expectedPolicyRevision,
        'expectedPolicyRevision',
        'Must be a canonical decimal policy revision.',
      );
    }
    return put('/api/v1/vaults/$vaultId/records/$recordId/automatic-purge', {
      'expected_deleted_revision_id': expectedDeletedRevisionId,
      'expected_deleted_seq': expectedDeletedSeq,
      'expected_policy_revision': expectedPolicyRevision,
      'enabled': enabled,
    });
  }

  /// Reads one immutable signed revision by ID. This endpoint is used for
  /// conflict review baselines; callers must still verify the envelope and
  /// bind its header to the requested Vault, record, and revision.
  Future<Map<String, dynamic>> revision(
    String vaultId,
    String revisionId,
  ) => get(
    '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/revisions/${Uri.encodeComponent(revisionId)}',
  );

  Future<VaultHistoryPage<VaultConflictEntry>> conflicts(
    String vaultId, {
    required String snapshotId,
    String? cursor,
    int limit = 500,
  }) async => VaultHistoryPage<VaultConflictEntry>.fromJson(
    await get(
      '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/conflicts',
      query: {
        'snapshot_id': snapshotId,
        if (cursor != null) 'cursor': cursor,
        'limit': '$limit',
      },
    ),
    listKey: 'conflicts',
    parseEntry: VaultConflictEntry.fromJson,
  );

  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) => post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/conflicts', body);

  Future<Map<String, dynamic>> resolveConflict(
    String vaultId,
    String conflictId,
    Map<String, Object?> body,
  ) => post(
    '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/conflicts/${Uri.encodeComponent(conflictId)}/resolve',
    body,
  );

  Future<Map<String, dynamic>> initUpload(
    String vaultId,
    Map<String, Object?> body,
  ) =>
      post('/api/v1/vaults/${Uri.encodeComponent(vaultId)}/uploads/init', body);

  Future<Map<String, dynamic>> completeUpload(
    String uploadId,
    Map<String, Object?> body,
  ) => post('/api/v1/uploads/${Uri.encodeComponent(uploadId)}/complete', body);

  Future<Map<String, dynamic>> uploadChunk({
    required String uploadId,
    required int index,
    required List<int> bytes,
    required String sha256,
  }) => putBytes(
    '/api/v1/uploads/${Uri.encodeComponent(uploadId)}/chunks/$index',
    bytes,
    headers: {'X-Content-SHA256': sha256},
  );

  Future<List<int>> downloadObject(String vaultId, String objectId) async {
    return (await downloadObjectWithDigest(vaultId, objectId)).bytes;
  }

  Future<DownloadedVaultObject> downloadObjectWithDigest(
    String vaultId,
    String objectId,
  ) async {
    final response = await _client
        .get(
          _uri(
            '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/objects/${Uri.encodeComponent(objectId)}',
          ),
          headers: {
            if (accessToken != null) ...{
              'Authorization': 'Bearer $accessToken',
              _clientCapabilityMarkerHeader: _clientCapabilityMarker,
              _clientRedactionMarkerHeader: 'v1',
            },
            'Accept': 'application/octet-stream',
          },
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
      throw ApiException(
        statusCode: response.statusCode,
        code: 'HTTP_${response.statusCode}',
        message: currentL10n.objectDownloadFailed,
      );
    }
    final etag = response.headers['etag'];
    final match = etag == null
        ? null
        : RegExp(r'^"sha256-([0-9a-f]{64})"$').firstMatch(etag);
    if (match == null) {
      throw const FormatException(
        'Object download is missing its canonical SHA-256 ETag.',
      );
    }
    return DownloadedVaultObject(
      bytes: response.bodyBytes,
      sha256: match.group(1)!,
    );
  }

  /// Reads one bounded ciphertext range from an immutable Vault object.
  /// `expectedSize` and `expectedSha256` come from the authenticated encrypted
  /// Host attachment manifest; each response is checked against both metadata
  /// values before callers persist the ciphertext part locally.
  Future<Uint8List> downloadObjectRange({
    required String vaultId,
    required String objectId,
    required int start,
    required int end,
    required int expectedSize,
    required String expectedSha256,
  }) async {
    if (start < 0 || end < start || end >= expectedSize) {
      throw ArgumentError('Object byte range is outside the expected size.');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) {
      throw ArgumentError.value(expectedSha256, 'expectedSha256');
    }
    final response = await _client
        .get(
          _uri(
            '/api/v1/vaults/${Uri.encodeComponent(vaultId)}/objects/${Uri.encodeComponent(objectId)}',
          ),
          headers: {
            if (accessToken != null) ...{
              'Authorization': 'Bearer $accessToken',
              _clientCapabilityMarkerHeader: _clientCapabilityMarker,
              _clientRedactionMarkerHeader: 'v1',
            },
            'Accept': 'application/octet-stream',
            'Accept-Encoding': 'identity',
            'Range': 'bytes=$start-$end',
            'If-Range': '"sha256-$expectedSha256"',
          },
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
      throw ApiException(
        statusCode: response.statusCode,
        code: 'HTTP_${response.statusCode}',
        message: currentL10n.objectRangeDownloadFailed,
      );
    }
    final expectedLength = end - start + 1;
    final expectedContentRange = 'bytes $start-$end/$expectedSize';
    final etag = response.headers['etag'];
    final contentRange = response.headers['content-range'];
    final contentLength = int.tryParse(
      response.headers['content-length'] ?? '',
    );
    if (response.statusCode != 206 ||
        contentRange != expectedContentRange ||
        contentLength != expectedLength ||
        response.bodyBytes.length != expectedLength ||
        etag != '"sha256-$expectedSha256"') {
      throw const FormatException(
        'Object range response did not match the requested encrypted range.',
      );
    }
    return response.bodyBytes;
  }

  Future<RelayTicket> createRelayTicket({
    required String deviceId,
    required String targetHost,
    required int targetPort,
  }) async {
    if (targetHost.trim().isEmpty || targetHost != targetHost.trim()) {
      throw ArgumentError.value(targetHost, 'targetHost');
    }
    if (targetPort < 1 || targetPort > 65535) {
      throw ArgumentError.value(targetPort, 'targetPort');
    }
    return RelayTicket.fromJson(
      await post('/api/v1/relay/tickets', {
        'device_id': deviceId,
        'target_host': targetHost,
        'target_port': targetPort,
      }),
    );
  }

  Uri relayUri() {
    final base = Uri.parse(baseUrl);
    final websocketScheme = switch (base.scheme) {
      'https' => 'wss',
      'http' when _isLoopback(base.host) => 'ws',
      'http' => throw const FormatException(
        'SSH relay requires HTTPS outside localhost development.',
      ),
      _ => throw const FormatException('Unsupported SSH relay URL scheme.'),
    };
    final pathSegments = base.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    pathSegments.addAll(const ['relay', 'v1', 'connect']);
    return base.replace(scheme: websocketScheme, pathSegments: pathSegments);
  }

  static List<Map<String, dynamic>> _list(
    Map<String, dynamic> value,
    String key,
  ) => (value[key] as List<dynamic>? ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList(growable: false);

  void close() => _client.close();
}
