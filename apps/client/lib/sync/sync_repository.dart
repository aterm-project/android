import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:sodium/sodium.dart' show SodiumException;
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../domain/credential_conflict_merge.dart';
import '../domain/conflict_feed.dart';
import '../domain/host_security_conflict_merge.dart';
import '../domain/known_host.dart';
import '../domain/merge.dart';
import '../domain/models.dart';
import '../domain/record_redaction.dart';
import '../domain/vault_preference.dart';
import '../domain/workspace_layout.dart';
import '../storage/client_database.dart';
import 'known_host_decision_lock.dart';
import 'sync_repository_e2e_hook.dart';
import '../l10n/l10n.dart';

const _uuid = Uuid();
final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _canonicalDecimal = RegExp(r'^(0|[1-9][0-9]*)$');
final _canonicalPositiveDecimal = RegExp(r'^[1-9][0-9]*$');
const _maxI64Decimal = '9223372036854775807';
const _snapshotPageLimit = 100;
const _maxSnapshotManifestHeads = 100000;
const _maxRecycleBinHistoryRevisions = 100000;

bool _isI64Decimal(String value) =>
    _canonicalDecimal.hasMatch(value) &&
    (value.length < _maxI64Decimal.length ||
        (value.length == _maxI64Decimal.length &&
            value.compareTo(_maxI64Decimal) <= 0));

int _compareDecimalSeq(String left, String right) {
  if (!_canonicalDecimal.hasMatch(left) || !_canonicalDecimal.hasMatch(right)) {
    throw const FormatException('Sequence must be a canonical decimal string.');
  }
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}

bool _hasExactKeys(Map<String, dynamic> actual, Set<String> expected) =>
    actual.length == expected.length &&
    actual.keys.toSet().containsAll(expected);

enum _AutoMergeAttempt { notEligible, retry, merged }

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _isBoundedUnsignedDecimal(
  String value, {
  required int maxDigits,
  bool allowZero = true,
}) =>
    value.length <= maxDigits &&
    (allowZero ? _canonicalDecimal : _canonicalPositiveDecimal).hasMatch(value);

/// Identifies the authenticated directory context for one encrypted Vault.
/// Signing keys are public, but keeping this scope explicit prevents cached
/// signer identities from crossing configured servers, accounts, or Vaults.
class SignerDirectoryCacheScope {
  const SignerDirectoryCacheScope({
    required this.serverBaseUrl,
    required this.serverSpaceId,
    required this.instanceId,
    required this.accountId,
    required this.vaultId,
  });

  final String serverBaseUrl;
  final String serverSpaceId;
  final String instanceId;
  final String accountId;
  final String vaultId;

  String get _key => jsonEncode([
    serverBaseUrl,
    serverSpaceId,
    instanceId,
    accountId,
    vaultId,
  ]);
}

/// Controller-owned cache of structurally validated signer directories.
/// Repository instances capture [generation] when they are created; an API or
/// authentication-context change invalidates that generation so a late
/// response from a retired repository cannot repopulate the new context.
class VerifiedSignerDirectoryCache {
  int _generation = 0;
  int _nextRefreshTicket = 0;
  final Map<String, Map<String, Uint8List>> _directories = {};
  final Map<String, int> _committedRefreshTickets = {};

  int get generation => _generation;

  Map<String, Uint8List>? read(
    SignerDirectoryCacheScope scope, {
    required int generation,
  }) {
    if (generation != _generation) return null;
    final directory = _directories[scope._key];
    if (directory == null) return null;
    return {
      for (final entry in directory.entries)
        entry.key: Uint8List.fromList(entry.value),
    };
  }

  int? beginRefresh(
    SignerDirectoryCacheScope scope, {
    required int generation,
  }) {
    if (generation != _generation) return null;
    return ++_nextRefreshTicket;
  }

  void publishRefresh(
    SignerDirectoryCacheScope scope, {
    required int generation,
    required int? ticket,
    required Map<String, List<int>> signers,
  }) {
    if (generation != _generation ||
        ticket == null ||
        ticket <= (_committedRefreshTickets[scope._key] ?? 0)) {
      return;
    }
    _committedRefreshTickets[scope._key] = ticket;
    _directories[scope._key] = _copyDirectory(signers);
  }

  /// Seeds the directory from a full Vault hydration using the ticket reserved
  /// before its network reads began. A later refresh then wins even when the
  /// older hydration finishes afterwards.
  void publishHydrated(
    SignerDirectoryCacheScope scope, {
    required int generation,
    required int? ticket,
    required Map<String, List<int>> signers,
  }) {
    if (generation != _generation ||
        ticket == null ||
        ticket <= (_committedRefreshTickets[scope._key] ?? 0)) {
      return;
    }
    _committedRefreshTickets[scope._key] = ticket;
    _directories[scope._key] = _copyDirectory(signers);
  }

  /// Invalidates every entry and every in-flight writer at an auth/API fence.
  void invalidate() {
    _generation++;
    _directories.clear();
    _committedRefreshTickets.clear();
  }

  Map<String, Uint8List> _copyDirectory(Map<String, List<int>> source) => {
    for (final entry in source.entries)
      entry.key: Uint8List.fromList(entry.value),
  };
}

/// Validates the complete device roster before it can seed a shared cache.
/// Returns signing keys only when identifiers, encodings, lengths, and key
/// ownership are all unambiguous.
Map<String, Uint8List> validatedSignerDirectory({
  required DeviceIdentity identity,
  required Iterable<Map<String, dynamic>> devices,
}) {
  final signers = <String, Uint8List>{
    identity.deviceId: Uint8List.fromList(identity.signing.publicKey),
  };
  final keyOwners = <String, String>{
    encodeBase64Url(identity.signing.publicKey): identity.deviceId,
  };

  for (final item in devices) {
    final id = item['device_id'];
    final encodedKey = item['signing_public_key'];
    if (id is! String ||
        !_canonicalUuid.hasMatch(id) ||
        encodedKey is! String ||
        encodedKey.isEmpty) {
      throw const FormatException(
        'Vault signing directory entry is malformed.',
      );
    }
    final key = decodeBase64Url(encodedKey);
    if (key.length != 32 || encodeBase64Url(key) != encodedKey) {
      throw const FormatException('Vault signing directory key is malformed.');
    }
    final existing = signers[id];
    if (existing != null && !_sameBytes(existing, key)) {
      throw const FormatException(
        'Vault signing directory contains conflicting keys for one device ID.',
      );
    }
    final owner = keyOwners[encodedKey];
    if (owner != null && owner != id) {
      throw const FormatException(
        'Vault signing directory reuses one signing key across device IDs.',
      );
    }
    signers[id] = Uint8List.fromList(key);
    keyOwners[encodedKey] = id;
  }
  return signers;
}

class _VerifiedFeedConflictBranch {
  const _VerifiedFeedConflictBranch({
    required this.header,
    required this.plaintext,
  });

  final Map<String, dynamic> header;
  final Map<String, dynamic> plaintext;
}

class _VerifiedPasswordCredentialConflict {
  const _VerifiedPasswordCredentialConflict({
    required this.preview,
    required this.localPlaintext,
    required this.remotePlaintext,
  });

  final CredentialConflictMergePreview preview;
  final Map<String, dynamic> localPlaintext;
  final Map<String, dynamic> remotePlaintext;
}

class _VerifiedHostSecurityConflict {
  const _VerifiedHostSecurityConflict({
    required this.preview,
    required this.basePlaintext,
    required this.conflictPlaintext,
    required this.currentPlaintext,
  });

  final HostSecurityConflictMergePreview preview;
  final Map<String, dynamic> basePlaintext;
  final Map<String, dynamic> conflictPlaintext;
  final Map<String, dynamic> currentPlaintext;
}

class SyncResult {
  const SyncResult({
    required this.pendingCount,
    required this.receivedCount,
    required this.conflictCount,
    required this.status,
    this.serverGeneration,
  });

  final int pendingCount;
  final int receivedCount;
  final int conflictCount;
  final String status;
  final String? serverGeneration;
}

/// A display-safe entry in the server-backed recycle bin. No decrypted record
/// payload or ciphertext is retained in this view model; restore re-fetches and
/// verifies the selected revision immediately before staging a new operation.
class RecycleBinRecord {
  const RecycleBinRecord({
    required this.recordId,
    required this.tombstoneRevisionId,
    required this.previousRevisionId,
    required this.deletedSeq,
    required this.recordType,
    required this.displayName,
    required this.deletedAt,
    required this.canRestore,
    required this.restorePending,
    this.restoreUntil,
    this.unavailableReason,
    this.autoPurgeEnabled = false,
    this.autoPurgeRevision = '0',
  });

  final String recordId;
  final String tombstoneRevisionId;
  final String? previousRevisionId;
  final String deletedSeq;
  final String recordType;
  final String displayName;
  final DateTime deletedAt;
  final DateTime? restoreUntil;
  final bool canRestore;
  final bool restorePending;
  final String? unavailableReason;
  final bool autoPurgeEnabled;
  final String autoPurgeRevision;
}

class RecycleBinHistoryLimitException implements Exception {
  const RecycleBinHistoryLimitException();

  @override
  String toString() =>
      'Recycle bin history exceeds this client’s 100,000 revision scan limit. No partial list was shown.';
}

typedef _MatchedRecycleBinRevision = ({
  DateTime deletedAt,
  String? baseRevisionId,
  DateTime? restoreUntil,
  bool autoPurgeEnabled,
  String autoPurgeRevision,
});

class _RecycleBinSnapshot {
  const _RecycleBinSnapshot({
    required this.snapshotId,
    required this.highWatermark,
    required this.conflictHighWatermark,
    required this.checkpointCursor,
    required this.expiresAt,
    required this.expectedItemCount,
    required this.tombstones,
  });

  final String snapshotId;
  final String highWatermark;
  final String conflictHighWatermark;
  final String checkpointCursor;
  final String expiresAt;
  final int expectedItemCount;
  final Map<String, SnapshotHead> tombstones;
}

class _VerifiedRecycleBinRevision {
  const _VerifiedRecycleBinRevision({
    required this.header,
    required this.plaintext,
  });

  final Map<String, dynamic> header;
  final Map<String, dynamic> plaintext;
}

/// Signals that a structurally valid server change is not processable with the
/// current control-plane snapshot. A canonical but unknown signer may request
/// one roster refresh because its signature cannot be checked until its device
/// key arrives. A known signer must authenticate the envelope before a missing
/// Vault key can request the same bounded refresh and uncheckpointed-page
/// replay. Malformed envelopes and bad signatures fail closed without retry.
enum SyncControlPlaneRefreshReason { missingEventSigner, missingVaultKey }

class SyncControlPlaneRefreshRequiredException implements Exception {
  const SyncControlPlaneRefreshRequiredException(this.reason);

  final SyncControlPlaneRefreshReason reason;

  @override
  String toString() => 'Vault control-plane refresh is required.';
}

/// A locally encrypted preference-repair tombstone which has not yet been
/// read back through this Vault's changes cursor.
class PendingDefaultPreferenceRepair {
  const PendingDefaultPreferenceRepair({
    required this.deletedRecordId,
    required this.retainedRecordId,
    this.scope = VaultPreferenceRecord.workspaceScope,
    this.key = VaultPreferenceRecord.defaultSectionKey,
    this.platformFamily = VaultPreferenceRecord.allPlatforms,
  });

  final String deletedRecordId;
  final String retainedRecordId;
  final String scope;
  final String key;
  final String platformFamily;

  bool get isDefaultWorkspaceSection =>
      scope == VaultPreferenceRecord.workspaceScope &&
      key == VaultPreferenceRecord.defaultSectionKey &&
      platformFamily == VaultPreferenceRecord.allPlatforms;

  bool get isTerminalFontSize =>
      scope == VaultPreferenceRecord.workspaceScope &&
      key == VaultPreferenceRecord.terminalFontSizeKey &&
      platformFamily == VaultPreferenceRecord.allPlatforms;

  bool get isTerminalTheme =>
      scope == VaultPreferenceRecord.workspaceScope &&
      key == VaultPreferenceRecord.terminalThemeKey &&
      platformFamily == VaultPreferenceRecord.allPlatforms;

  bool get isTerminalShortcuts =>
      scope == VaultPreferenceRecord.workspaceScope &&
      key == VaultPreferenceRecord.terminalShortcutsKey &&
      platformFamily == VaultPreferenceRecord.allPlatforms;
}

class _ConflictPublishResult {
  const _ConflictPublishResult({required this.allUploaded, required this.ids});

  final bool allUploaded;
  final Map<String, String> ids;
}

/// Result of comparing one SSH host key against this repository's Vault only.
enum KnownHostTrustStatus { trusted, unknown, changed, revoked, conflict }

/// A cached KnownHost read made only after a typed, no-response sync GET
/// failure. `hasEndpointHistory` prevents offline queueing for any endpoint
/// whose local trust or revocation history is already known.
final class CachedKnownHostTrustSnapshot {
  const CachedKnownHostTrustSnapshot({
    required this.status,
    required this.hasEndpointHistory,
  });

  final KnownHostTrustStatus status;
  final bool hasEndpointHistory;
}

/// Client-side encrypted record persistence and the offline-first sync worker.
class SyncRepository {
  SyncRepository({
    required this.api,
    required this.database,
    required this.crypto,
    required this.identity,
    required this.serverSpaceId,
    required this.instanceId,
    this.accountId,
    required this.vaultId,
    required this.keyEpoch,
    required this.membershipVersion,
    required this.serverGeneration,
    required this.vaultKey,
    this.trustedInstanceSigningPublicKey,
    KnownHostDecisionLock? knownHostDecisionLock,
    this.vaultKeysByVersion = const {},
    this.canWrite = true,
    this.deletionPending = false,
    this.publishDeviceCapabilities,
    this.beforePushMarkAttemptedForTesting,
    this.beforeStorePulledEventForTesting,
    this.beforeReplaceMergedOperationForTesting,
    VerifiedSignerDirectoryCache? signerDirectoryCache,
    SignerDirectoryCacheScope? signerDirectoryScope,
  }) : knownHostDecisionLock =
           knownHostDecisionLock ?? createKnownHostDecisionLock(),
       _signerDirectoryCache = signerDirectoryCache,
       _signerDirectoryScope = signerDirectoryScope,
       _signerDirectoryCacheGeneration = signerDirectoryCache?.generation {
    if (signerDirectoryCache != null && signerDirectoryScope != null) {
      _signers.addAll(
        signerDirectoryCache.read(
              signerDirectoryScope,
              generation: _signerDirectoryCacheGeneration!,
            ) ??
            const <String, Uint8List>{},
      );
    }
  }

  final ApiClient api;
  final ClientDatabase database;
  final VaultCrypto crypto;
  final DeviceIdentity identity;
  final String serverSpaceId;
  final String instanceId;

  /// Current instance key already checked against the server identity pin by
  /// AppController. Redaction proofs never introduce their own trust anchor.
  final String? trustedInstanceSigningPublicKey;

  /// Required for durable recovery staging. Older non-recovery test/service
  /// construction may omit it; recovery then fails closed before creating a
  /// stage rather than mixing account data in the shared client database.
  final String? accountId;
  final String vaultId;
  final KnownHostDecisionLock knownHostDecisionLock;
  final String keyEpoch;
  final String membershipVersion;
  String serverGeneration;
  final List<int> vaultKey;
  final Map<String, List<int>> vaultKeysByVersion;
  bool canWrite;
  bool deletionPending;
  final Future<void> Function()? publishDeviceCapabilities;

  /// Pauses a push after its batch snapshot but before the atomic outbox
  /// attempt transition. Used to exercise cancellation races in tests.
  final Future<void> Function()? beforePushMarkAttemptedForTesting;

  /// Pauses a pull after its initial outbox read but before the conditional
  /// remote-head write, so tests can exercise a concurrent local edit.
  final Future<void> Function()? beforeStorePulledEventForTesting;

  /// Pauses after a signed merge candidate is prepared but before its atomic
  /// outbox replacement, so tests can exercise a sibling-tab edit race.
  final Future<void> Function()? beforeReplaceMergedOperationForTesting;
  final VerifiedSignerDirectoryCache? _signerDirectoryCache;
  final SignerDirectoryCacheScope? _signerDirectoryScope;
  final int? _signerDirectoryCacheGeneration;

  KnownHostDecisionScope get knownHostDecisionScope =>
      KnownHostDecisionScope(serverSpaceId: serverSpaceId, vaultId: vaultId);
  bool lastRecoveryCommitted = false;
  int verifiedServerViewRevision = 0;
  bool _staleOutboxRewrapAuthorized = false;
  final Map<String, List<int>> _signers = {};
  int _nextSignerRefreshTicket = 0;
  int _committedSignerRefreshTicket = 0;
  final List<String> unavailableRecordIds = [];
  Future<void> _serialTail = Future<void>.value();
  static final Map<String, Future<void>> _knownHostLocks = {};
  int _recoveryRequests = 0;
  int _activeLocalWriters = 0;
  Completer<void>? _localWritersDrained;
  bool _localWritesFrozen = false;
  bool _keyOperationsRetired = false;
  int _activeKeyOperations = 0;
  Completer<void>? _keyOperationsDrained;

  Future<T> _withKeyOperation<T>(Future<T> Function() operation) {
    if (_keyOperationsRetired) {
      return Future<T>.error(
        StateError('This Vault repository has been replaced.'),
      );
    }
    _activeKeyOperations++;
    late final Future<T> result;
    try {
      result = operation();
    } catch (error, stackTrace) {
      _endKeyOperation();
      return Future<T>.error(error, stackTrace);
    }
    return result.whenComplete(_endKeyOperation);
  }

  /// Prevents new work from entering this repository and waits until every
  /// operation that could read its key buffers has finished. The controller
  /// calls this after publishing its replacement repository and before wiping
  /// the retired buffers.
  Future<void> retireAndWaitForKeyOperations() {
    _keyOperationsRetired = true;
    if (_activeKeyOperations == 0) return Future<void>.value();
    _keyOperationsDrained ??= Completer<void>();
    return _keyOperationsDrained!.future;
  }

  void _endKeyOperation() {
    _activeKeyOperations--;
    if (_activeKeyOperations == 0) {
      final drained = _keyOperationsDrained;
      _keyOperationsDrained = null;
      if (drained != null && !drained.isCompleted) drained.complete();
    }
  }

  Future<void> refreshSignerDirectory() async {
    final localRefreshTicket = ++_nextSignerRefreshTicket;
    final cache = _signerDirectoryCache;
    final scope = _signerDirectoryScope;
    final cacheGeneration = _signerDirectoryCacheGeneration;
    final refreshTicket =
        cache == null || scope == null || cacheGeneration == null
        ? null
        : cache.beginRefresh(scope, generation: cacheGeneration);
    final devices = await api.devices();
    final vaultDevices = await api.vaultDevices(vaultId);
    final nextSigners = validatedSignerDirectory(
      identity: identity,
      devices: [...devices, ...vaultDevices],
    );
    if (cache != null && scope != null && cacheGeneration != null) {
      cache.publishRefresh(
        scope,
        generation: cacheGeneration,
        ticket: refreshTicket,
        signers: nextSigners,
      );
    }
    if (localRefreshTicket > _committedSignerRefreshTicket) {
      _committedSignerRefreshTicket = localRefreshTicket;
      _signers
        ..clear()
        ..addAll(nextSigners);
    }
  }

  /// Loads only authenticated, decrypted KnownHost records from this Vault.
  /// Any unreadable record blocks trust decisions rather than being ignored.
  Future<List<KnownHostRecord>> loadKnownHosts() =>
      _withKeyOperation(_loadKnownHosts);

  Future<List<KnownHostRecord>> _loadKnownHosts({
    bool refreshSigners = true,
  }) async {
    if (refreshSigners) {
      await refreshSignerDirectory();
    } else if (_signers.isEmpty) {
      throw StateError(
        'No previously verified Vault signer directory is available offline.',
      );
    }

    final rows = await _loadRecords();

    if (unavailableRecordIds.isNotEmpty) {
      throw const FormatException(
        'KnownHost trust is unavailable because this Vault contains records that could not be authenticated.',
      );
    }
    final records = <KnownHostRecord>[];
    for (final row in rows) {
      if (row['type'] != 'knownHost') continue;
      records.add(KnownHostRecord.fromJson(row));
    }
    return records;
  }

  Future<KnownHostTrustStatus> knownHostTrustStatus({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) => _withKeyOperation(() async {
    final canonicalHost = canonicalizeKnownHost(host);
    // endpointKey performs the same strict port validation used when writing.
    final endpoint = endpointKey(host: canonicalHost, port: port);
    return _withKnownHostLock(() async {
      final records = await _loadKnownHosts();
      return _knownHostStatusWithoutPending(
        records: records,
        endpoint: endpoint,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
    });
  });

  /// Reads trust only from records authenticated with this repository's
  /// previously verified signer directory. It never refreshes that directory
  /// or starts network traffic. Callers may use it after a typed sync read
  /// transport failure to consider only a first-seen endpoint for offline
  /// queueing, or to revalidate a route proof against the current local Vault
  /// projection while an SSH handshake is in progress.
  Future<CachedKnownHostTrustSnapshot> cachedKnownHostTrustSnapshot({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) => _withKeyOperation(() async {
    final canonicalHost = canonicalizeKnownHost(host);
    final endpoint = endpointKey(host: canonicalHost, port: port);
    return _withKnownHostLock(() async {
      final records = await _loadKnownHosts(refreshSigners: false);
      return CachedKnownHostTrustSnapshot(
        status: await _knownHostStatusWithoutPending(
          records: records,
          endpoint: endpoint,
          algorithm: algorithm,
          fingerprint: fingerprint,
        ),
        hasEndpointHistory: records.any(
          (record) => record.endpoint == endpoint,
        ),
      );
    });
  });

  /// Persists an explicit SSH key approval as a signed, encrypted create.
  /// A different active key must first be revoked; this never overwrites one.
  Future<KnownHostRecord> approveKnownHost({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
    KnownHostApprovalSource approvalSource =
        KnownHostApprovalSource.interactiveConfirmation,
    bool allowOfflineFirstApproval = false,
    DateTime? approvedAt,
  }) => _withKeyOperation(
    () => knownHostDecisionLock.run(
      knownHostDecisionScope,
      () => _withKnownHostLock(() async {
        _requireKnownHostWriteAccess();
        if (allowOfflineFirstApproval &&
            approvalSource != KnownHostApprovalSource.interactiveConfirmation) {
          throw StateError(
            'Offline KnownHost queueing requires an interactive confirmation.',
          );
        }
        final canonicalHost = canonicalizeKnownHost(host);
        final endpoint = endpointKey(host: canonicalHost, port: port);
        final records = await _loadKnownHosts(
          refreshSigners: !allowOfflineFirstApproval,
        );
        if (allowOfflineFirstApproval &&
            records.any((record) => record.endpoint == endpoint)) {
          throw StateError(
            'Offline KnownHost approval is limited to an endpoint with no local trust or revocation history.',
          );
        }
        final status = _knownHostStatus(
          records,
          endpoint: endpoint,
          algorithm: algorithm,
          fingerprint: fingerprint,
        );
        if (status == KnownHostTrustStatus.trusted) {
          return records.singleWhere(
            (record) =>
                record.endpoint == endpoint &&
                record.state == KnownHostState.trusted,
          );
        }
        if (status == KnownHostTrustStatus.changed ||
            status == KnownHostTrustStatus.conflict) {
          throw StateError(
            'A different or conflicting trusted SSH key already exists for this endpoint; revoke its trust before approving another key.',
          );
        }

        final matchingTrusted = records.where(
          (record) =>
              record.endpoint == endpoint &&
              record.state == KnownHostState.trusted &&
              record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
        );
        if (status == KnownHostTrustStatus.revoked &&
            matchingTrusted.isNotEmpty) {
          throw StateError(
            'A stale active SSH key approval does not acknowledge the current revocation. Revoke that approval, then review and approve the key again.',
          );
        }

        final observedRevocations = <KnownHostRevocationReference>[];
        for (final revoked in records.where(
          (record) =>
              record.endpoint == endpoint &&
              record.state == KnownHostState.revoked &&
              record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
        )) {
          final revisionId = revoked.revisionId;
          if (revisionId == null) {
            throw StateError(
              'A revoked SSH key record has no verified revision; approval is blocked until Vault sync completes.',
            );
          }
          observedRevocations.add(
            KnownHostRevocationReference(
              recordId: revoked.id,
              revisionId: revisionId,
            ),
          );
        }

        final record = KnownHostRecord.approve(
          host: canonicalHost,
          port: port,
          algorithm: algorithm,
          fingerprint: fingerprint,
          approvalSource: approvalSource,
          approvedByDeviceId: identity.deviceId,
          approvedAt: (approvedAt ?? DateTime.now().toUtc()).toUtc(),
          observedRevocations: observedRevocations,
        );
        final envelope = await _saveRecord(
          recordId: record.id,
          plaintext: record.toJson(),
          operation: 'create',
        );
        return KnownHostRecord.fromJson({
          ...record.toJson(),
          '_record_id': record.id,
          '_revision_id':
              (envelope['header'] as Map<String, dynamic>)['revision_id'],
        });
      }),
    ),
  );

  /// Revocation is a signed encrypted update of the original record ID.
  Future<KnownHostRecord> revokeKnownHost({
    required String recordId,
    DateTime? revokedAt,
  }) => _withKeyOperation(
    () => knownHostDecisionLock.run(
      knownHostDecisionScope,
      () => _withKnownHostLock(() async {
        _requireKnownHostWriteAccess();
        final records = await _loadKnownHosts();
        final current = records
            .where((item) => item.id == recordId)
            .firstOrNull;
        if (current == null)
          throw StateError('KnownHost record was not found in this Vault.');
        if (current.state == KnownHostState.revoked) return current;
        final revoked = current.revoke(
          revokedByDeviceId: identity.deviceId,
          revokedAt: (revokedAt ?? DateTime.now().toUtc()).toUtc(),
        );
        final envelope = await _saveRecord(
          recordId: revoked.id,
          plaintext: revoked.toJson(),
          baseRevisionId: current.revisionId,
          operation: 'update',
        );
        return KnownHostRecord.fromJson({
          ...revoked.toJson(),
          '_record_id': revoked.id,
          '_revision_id':
              (envelope['header'] as Map<String, dynamic>)['revision_id'],
        });
      }),
    ),
  );

  void _requireKnownHostWriteAccess() {
    if (!canWrite || deletionPending) {
      throw StateError(
        'This Vault is read-only; SSH host-key trust cannot be changed.',
      );
    }
  }

  KnownHostTrustStatus _knownHostStatus(
    List<KnownHostRecord> records, {
    required String endpoint,
    required String algorithm,
    required String fingerprint,
  }) {
    final atEndpoint = records.where((record) => record.endpoint == endpoint);
    final trusted = atEndpoint
        .where((record) => record.state == KnownHostState.trusted)
        .toList(growable: false);
    if (trusted.length > 1) return KnownHostTrustStatus.conflict;
    if (trusted.length == 1) {
      final approval = trusted.single;
      if (!approval.matchesKey(
        algorithm: algorithm,
        fingerprint: fingerprint,
      )) {
        return KnownHostTrustStatus.changed;
      }
      final matchingRevocations = atEndpoint.where(
        (record) =>
            record.state == KnownHostState.revoked &&
            record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
      );
      final acknowledgesAllRevocations = matchingRevocations.every(
        (revoked) =>
            revoked.revisionId != null &&
            approval.observedRevocations.any(
              (reference) =>
                  reference.recordId == revoked.id &&
                  reference.revisionId == revoked.revisionId,
            ),
      );
      return acknowledgesAllRevocations
          ? KnownHostTrustStatus.trusted
          : KnownHostTrustStatus.revoked;
    }
    if (atEndpoint.any(
      (record) =>
          record.state == KnownHostState.revoked &&
          record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
    )) {
      return KnownHostTrustStatus.revoked;
    }
    return KnownHostTrustStatus.unknown;
  }

  Future<KnownHostTrustStatus> _knownHostStatusWithoutPending({
    required List<KnownHostRecord> records,
    required String endpoint,
    required String algorithm,
    required String fingerprint,
  }) async {
    final status = _knownHostStatus(
      records,
      endpoint: endpoint,
      algorithm: algorithm,
      fingerprint: fingerprint,
    );
    if (status != KnownHostTrustStatus.trusted) return status;

    // A newly approved record is projected locally before it is uploaded. It
    // must not authorize SSH until the exact row has a server commit sequence
    // and its outbox operation is gone, including during a route retry.
    final matchingApproval = records.singleWhere(
      (record) =>
          record.endpoint == endpoint &&
          record.state == KnownHostState.trusted &&
          record.matchesKey(algorithm: algorithm, fingerprint: fingerprint),
    );
    final cachedEnvelope = await database.cachedEnvelope(
      vaultId,
      matchingApproval.id,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final pending = await database.allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (cachedEnvelope?.commitSeq == null ||
        pending.any((operation) => operation.recordId == matchingApproval.id)) {
      return KnownHostTrustStatus.unknown;
    }
    return status;
  }

  Future<T> _withKnownHostLock<T>(Future<T> Function() action) async {
    final key = '${identity.deviceId}:$vaultId';
    final previous = _knownHostLocks[key] ?? Future<void>.value();
    final release = Completer<void>();
    _knownHostLocks[key] = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_knownHostLocks[key], release.future)) {
        _knownHostLocks.remove(key);
      }
    }
  }

  Future<void> updateVaultAccess({
    required bool canWrite,
    required bool deletionPending,
  }) async {
    this.canWrite = canWrite;
    this.deletionPending = deletionPending;
    final status = deletionPending
        ? 'deletion_pending'
        : canWrite
        ? (await database.countPending(
                    vaultId,
                    instanceId: instanceId,
                    serverSpaceId: serverSpaceId,
                  ) >
                  0
              ? 'pending'
              : 'idle')
        : 'read_only';
    await _setStatus(status);
  }

  Future<Map<String, Object?>> encryptOperation({
    required String recordId,
    required Map<String, Object?> plaintext,
    required String? baseRevisionId,
    String operation = 'update',
  }) => _withKeyOperation(
    () => _encryptOperation(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      operation: operation,
    ),
  );

  Future<Map<String, Object?>> _encryptOperation({
    required String recordId,
    required Map<String, Object?> plaintext,
    required String? baseRevisionId,
    String operation = 'update',
  }) async {
    final key = Uint8List.fromList(vaultKey);
    try {
      final sequence = await database.nextDeviceSequence(identity.deviceId);
      return await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: recordId,
        baseRevisionId: baseRevisionId,
        deviceId: identity.deviceId,
        deviceSequence: sequence,
        keyEpoch: keyEpoch,
        membershipVersion: membershipVersion,
        operation: operation,
        plaintext: plaintext,
        identity: identity,
      );
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Future<Map<String, Object?>> saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) => _withKeyOperation(
    () => _saveRecord(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain,
      operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    ),
  );

  Future<Map<String, Object?>> _saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) async {
    _beginLocalWrite();
    try {
      final envelope = await _encryptOperation(
        recordId: recordId,
        plaintext: plaintext,
        baseRevisionId: baseRevisionId,
        operation: operation,
      );
      await database.putLocalOperation(
        vaultId: vaultId,
        recordId: recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        baseRevisionId: baseRevisionId,
        envelope: envelope,
        deleted: operation == 'delete',
        expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
        expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
        preserveOutboxChain: preserveOutboxChain,
        cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
      );
      return envelope;
    } finally {
      _endLocalWrite();
    }
  }

  Future<List<Map<String, dynamic>>> loadRecords({
    bool includeDeleted = false,
  }) => _withKeyOperation(
    () async => (await _loadRecordsWithHeadRevisionSnapshot(
      includeDeleted: includeDeleted,
    )).records,
  );

  /// Loads the authenticated record catalog and the exact local head set used
  /// to produce it. Callers can pass [headRevisionIds] to a later conditional
  /// write so the database can reject a stale catalog atomically.
  Future<
    ({List<Map<String, dynamic>> records, Map<String, String> headRevisionIds})
  >
  loadRecordsWithHeadRevisionSnapshot({bool includeDeleted = false}) =>
      _withKeyOperation(
        () => _loadRecordsWithHeadRevisionSnapshot(
          includeDeleted: includeDeleted,
        ),
      );

  Future<List<Map<String, dynamic>>> _loadRecords({
    bool includeDeleted = false,
  }) async => (await _loadRecordsWithHeadRevisionSnapshot(
    includeDeleted: includeDeleted,
  )).records;

  /// Loads one authenticated local cache head without decrypting the rest of
  /// the Vault. Missing or deleted records return null; unreadable encrypted
  /// rows are recorded in [unavailableRecordIds] and also return null.
  Future<Map<String, dynamic>?> loadRecord(String recordId) =>
      _withKeyOperation(() => _loadRecord(recordId));

  Future<Map<String, dynamic>?> _loadRecord(String recordId) async {
    if (_signers.isEmpty) await refreshSignerDirectory();
    final row = await database.cachedEnvelope(
      vaultId,
      recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    unavailableRecordIds.remove(recordId);
    if (row == null || row.isDeleted) return null;
    try {
      final envelope = jsonDecode(row.envelopeJson) as Map<String, dynamic>;
      final header = envelope['header'] as Map<String, dynamic>;
      if (header['record_id'] != recordId ||
          header['revision_id'] != row.revisionId) {
        unavailableRecordIds.add(recordId);
        return null;
      }
      final deviceId = header['device_id'];
      if (deviceId is! String) {
        unavailableRecordIds.add(recordId);
        return null;
      }
      final signer = _signers[deviceId];
      if (signer == null) {
        unavailableRecordIds.add(recordId);
        return null;
      }
      final keyVersion =
          '${header['key_epoch']}:${header['membership_version']}';
      final versionedRecordKey = vaultKeysByVersion[keyVersion];
      final plain = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(versionedRecordKey ?? vaultKey),
        envelope: envelope,
        authorPublicKey: Uint8List.fromList(signer),
      );
      final recordType = plain['type'];
      if (plain['deleted'] == true ||
          recordType is! String ||
          !RecordKind.values.any((kind) => kind.name == recordType)) {
        unavailableRecordIds.add(recordId);
        return null;
      }
      return {
        ...plain,
        '_record_id': row.recordId,
        '_revision_id': row.revisionId,
      };
    } on FormatException {
      unavailableRecordIds.add(recordId);
      return null;
    } on SodiumException {
      rethrow;
    } on Object {
      rethrow;
    }
  }

  /// Reads the current deleted heads from one immutable server snapshot, then
  /// joins them to that snapshot's revision-history stream. Only display-safe
  /// labels leave this repository; restore decrypts and checks both revisions
  /// again immediately before creating an outbox operation.
  Future<List<RecycleBinRecord>> loadRecycleBin() =>
      _withKeyOperation(() => _runSerialized(_loadRecycleBinLocked));

  Future<List<RecycleBinRecord>> _loadRecycleBinLocked() async {
    final snapshot = await _createVerifiedRecycleBinSnapshot();
    if (snapshot.tombstones.isEmpty) return const [];

    final remaining = <String, SnapshotHead>{
      for (final head in snapshot.tombstones.values) head.revisionId: head,
    };
    final matched = <String, _MatchedRecycleBinRevision>{};
    final seenCursors = <String>{};
    String? cursor;
    var scanned = 0;
    String? previousCommitSeq;

    while (true) {
      final page = await api.revisions(
        vaultId,
        snapshotId: snapshot.snapshotId,
        cursor: cursor,
        limit: 500,
      );
      if (page.snapshotId != snapshot.snapshotId ||
          page.vaultId != vaultId ||
          page.highWatermark != snapshot.highWatermark ||
          page.conflictHighWatermark != snapshot.conflictHighWatermark ||
          page.serverGeneration != serverGeneration ||
          page.entries.isEmpty && page.hasMore ||
          page.hasMore != (page.nextCursor != null)) {
        throw const FormatException(
          'Revision history no longer matches its snapshot.',
        );
      }
      for (final entry in page.entries) {
        scanned++;
        if (scanned > _maxRecycleBinHistoryRevisions) {
          throw const RecycleBinHistoryLimitException();
        }
        if (previousCommitSeq != null &&
            _compareDecimalSeq(entry.commitSeq, previousCommitSeq) <= 0) {
          throw const FormatException(
            'Revision history is not in strict commit order.',
          );
        }
        previousCommitSeq = entry.commitSeq;
        if (_compareDecimalSeq(entry.commitSeq, snapshot.highWatermark) > 0) {
          throw const FormatException(
            'Revision history exceeds the snapshot high-watermark.',
          );
        }
        if (entry.operation == 'redacted') {
          final rawProof = entry.redaction;
          if (rawProof == null) {
            throw const FormatException(
              'Redacted revision history entry has no proof.',
            );
          }
          final proof = _verifyRecordRedactionProof(
            rawProof,
            recordId: entry.recordId,
          );
          if (_compareDecimalSeq(proof.deletedSeq, snapshot.highWatermark) >
                  0 ||
              _compareDecimalSeq(proof.redactionSeq, snapshot.highWatermark) >
                  0 ||
              (entry.deleted &&
                  (entry.revisionId != proof.deletedRevisionId ||
                      entry.commitSeq != proof.deletedSeq)) ||
              (!entry.deleted && entry.revisionId == proof.deletedRevisionId)) {
            throw const FormatException(
              'Redacted revision history does not match its signed proof.',
            );
          }
          await database.applyRecordRedaction(
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
            vaultId: vaultId,
            serverGeneration: serverGeneration,
            proof: proof.toJson(),
          );
          continue;
        }
        final head = remaining[entry.revisionId];
        if (head == null) continue;
        final entryEnvelope = entry.envelope;
        if (entryEnvelope == null) {
          throw const FormatException(
            'A non-redacted history entry has no revision envelope.',
          );
        }
        if (entry.recordId != head.recordId ||
            entry.commitSeq != head.commitSeq ||
            entry.operation != 'delete' ||
            !entry.deleted ||
            canonicalJson(entryEnvelope) != canonicalJson(head.envelope)) {
          throw const FormatException(
            'Deleted head does not match its snapshot-bound revision.',
          );
        }
        final verified = await _verifyRecycleBinRevision(
          envelope: entryEnvelope,
          expectedRecordId: head.recordId,
          expectedRevisionId: head.revisionId,
          expectedOperation: 'delete',
          expectedDeleted: true,
        );
        final baseRevisionId = verified.header['base_revision_id'];
        if (baseRevisionId != null &&
            (baseRevisionId is! String ||
                !_canonicalUuid.hasMatch(baseRevisionId))) {
          throw const FormatException('Tombstone base revision is malformed.');
        }
        final deletedAt = DateTime.tryParse(entry.createdAt);
        if (deletedAt == null) {
          throw const FormatException('Tombstone creation time is malformed.');
        }
        matched[head.recordId] = (
          deletedAt: deletedAt.toUtc(),
          baseRevisionId: baseRevisionId as String?,
          restoreUntil: entry.restoreUntil,
          autoPurgeEnabled: entry.autoPurgeEnabled,
          autoPurgeRevision: entry.autoPurgeRevision,
        );
        remaining.remove(entry.revisionId);
      }
      if (remaining.isEmpty || !page.hasMore) break;
      final next = page.nextCursor!;
      if (!seenCursors.add(next) || next == cursor) {
        throw const FormatException('Revision history cursor repeated.');
      }
      cursor = next;
    }
    if (remaining.isNotEmpty) {
      throw const FormatException(
        'A deleted snapshot head is missing from retained revision history.',
      );
    }

    final pending = await database.allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final result = <RecycleBinRecord>[];
    for (final head in snapshot.tombstones.values) {
      final metadata = matched[head.recordId]!;
      final baseRevisionId = metadata.baseRevisionId;
      String displayName = 'Unavailable historical record';
      String recordType = 'unknown';
      var unavailableReason = baseRevisionId == null
          ? 'No live revision is available before this tombstone.'
          : null;
      if (baseRevisionId != null) {
        try {
          final detail = await api.revision(vaultId, baseRevisionId);
          final rawEnvelope = detail['envelope'];
          if (detail['record_id'] != head.recordId || rawEnvelope is! Map) {
            throw const FormatException(
              'Historical revision response does not match the tombstone.',
            );
          }
          final verified = await _verifyRecycleBinRevision(
            envelope: Map<String, dynamic>.from(rawEnvelope),
            expectedRecordId: head.recordId,
            expectedRevisionId: baseRevisionId,
            expectedDeleted: false,
          );
          recordType = verified.plaintext['type'] as String;
          displayName = _recycleBinDisplayName(recordType, verified.plaintext);
        } on ApiException catch (error) {
          if (error.statusCode == 410 && error.code == 'RECORD_REDACTED') {
            await _applyRecordRedactionFromApiError(
              error,
              expectedRecordId: head.recordId,
            );
          }
          if (error.statusCode != 404 && error.statusCode != 410) rethrow;
          unavailableReason =
              'The previous encrypted revision is no longer available.';
        }
      }

      final local = await database.encryptedRecord(
        vaultId,
        head.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final recordPending = pending
          .where((operation) => operation.recordId == head.recordId)
          .toList(growable: false);
      final restorePending =
          local != null &&
          local.revisionId != head.revisionId &&
          recordPending.any((operation) {
            try {
              final envelope = jsonDecode(operation.envelopeJson);
              if (envelope is! Map || envelope['header'] is! Map) {
                return false;
              }
              final header = Map<String, dynamic>.from(envelope['header']);
              return header['operation'] == 'restore' &&
                  header['base_revision_id'] == head.revisionId;
            } on Object {
              return false;
            }
          });
      final locallyCurrent =
          local != null &&
          local.revisionId == head.revisionId &&
          local.isDeleted &&
          local.commitSeq != null &&
          local.commitSeq == head.commitSeq;
      final canRestore =
          locallyCurrent &&
          recordPending.isEmpty &&
          unavailableReason == null &&
          canWrite &&
          !deletionPending;
      result.add(
        RecycleBinRecord(
          recordId: head.recordId,
          tombstoneRevisionId: head.revisionId,
          previousRevisionId: baseRevisionId,
          deletedSeq: head.commitSeq!,
          recordType: recordType,
          displayName: displayName,
          deletedAt: metadata.deletedAt,
          restoreUntil: metadata.restoreUntil,
          canRestore: canRestore,
          restorePending: restorePending,
          autoPurgeEnabled: metadata.autoPurgeEnabled,
          autoPurgeRevision: metadata.autoPurgeRevision,
          unavailableReason:
              unavailableReason ??
              (restorePending
                  ? 'Restore is waiting to sync.'
                  : !locallyCurrent
                  ? 'Synchronize this Vault before restoring.'
                  : recordPending.isNotEmpty
                  ? 'This record has a pending local operation.'
                  : !canWrite || deletionPending
                  ? 'This Vault is currently read-only.'
                  : null),
        ),
      );
    }
    result.sort((left, right) => right.deletedAt.compareTo(left.deletedAt));
    return List.unmodifiable(result);
  }

  /// Records consent for a future worker on one exact tombstone. The fresh
  /// snapshot/history join prevents a stale recycle-bin row from authorizing
  /// a different head; the server also checks both the tombstone and policy
  /// revisions atomically. No record payload is changed or purged here.
  Future<void> setRecycleBinRecordAutomaticPurge(
    RecycleBinRecord entry, {
    required bool enabled,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      if (!_canonicalUuid.hasMatch(entry.recordId) ||
          !_canonicalUuid.hasMatch(entry.tombstoneRevisionId) ||
          !_canonicalPositiveDecimal.hasMatch(entry.deletedSeq) ||
          !_canonicalDecimal.hasMatch(entry.autoPurgeRevision)) {
        throw const FormatException('Automatic purge selection is invalid.');
      }

      final currentEntries = await _loadRecycleBinLocked();
      final current = currentEntries
          .where((item) => item.recordId == entry.recordId)
          .firstOrNull;
      if (current == null ||
          current.tombstoneRevisionId != entry.tombstoneRevisionId ||
          current.deletedSeq != entry.deletedSeq) {
        throw const LocalRecordHeadChangedException('server tombstone');
      }
      if (current.autoPurgeRevision != entry.autoPurgeRevision ||
          current.autoPurgeEnabled != entry.autoPurgeEnabled) {
        throw const LocalRecordHeadChangedException('automatic purge policy');
      }

      final response = await api.setRecordAutomaticPurge(
        vaultId: vaultId,
        recordId: entry.recordId,
        expectedDeletedRevisionId: entry.tombstoneRevisionId,
        expectedDeletedSeq: entry.deletedSeq,
        expectedPolicyRevision: entry.autoPurgeRevision,
        enabled: enabled,
      );
      const expectedKeys = {
        'vault_id',
        'record_id',
        'deleted_revision_id',
        'deleted_seq',
        'enabled',
        'policy_revision',
      };
      final policyRevision = response['policy_revision'];
      if (!_hasExactKeys(response, expectedKeys) ||
          response['vault_id'] != vaultId ||
          response['record_id'] != entry.recordId ||
          response['deleted_revision_id'] != entry.tombstoneRevisionId ||
          response['deleted_seq'] != entry.deletedSeq ||
          response['enabled'] != enabled ||
          policyRevision is! String ||
          !_canonicalDecimal.hasMatch(policyRevision)) {
        throw const FormatException(
          'Automatic purge response does not match the requested tombstone and policy.',
        );
      }
    }),
  );

  /// Permanently removes the exact tombstone selected in the recycle bin.
  /// A fresh snapshot/history read supplies the authoritative retention
  /// deadline and current sequence; after the API response, the pinned
  /// instance key verifies its proof before the database transaction erases
  /// this instance's cache/outbox and persists the graveyard reservation.
  /// Callers must finish a successful pull before allowing any queued push.
  Future<RecordRedactionProof> purgeRecycleBinRecord(
    RecycleBinRecord entry,
  ) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      if (!_canonicalUuid.hasMatch(entry.recordId) ||
          !_canonicalUuid.hasMatch(entry.tombstoneRevisionId) ||
          !_canonicalPositiveDecimal.hasMatch(entry.deletedSeq)) {
        throw const FormatException('Recycle bin purge selection is invalid.');
      }

      final currentEntries = await _loadRecycleBinLocked();
      final current = currentEntries
          .where((item) => item.recordId == entry.recordId)
          .firstOrNull;
      if (current != null) {
        if (current.tombstoneRevisionId != entry.tombstoneRevisionId ||
            current.deletedSeq != entry.deletedSeq) {
          throw const LocalRecordHeadChangedException('server tombstone');
        }
        final restoreUntil = current.restoreUntil;
        if (restoreUntil == null) {
          throw StateError(
            'The server did not provide a verified restore deadline; purge is blocked.',
          );
        }
        if (DateTime.now().toUtc().isBefore(restoreUntil.toUtc())) {
          throw ApiException(
            statusCode: 409,
            code: 'RECORD_PURGE_NOT_DUE',
            message: currentL10n.theServerRestorePeriodHasNot,
            details: {'restore_until': restoreUntil.toUtc().toIso8601String()},
          );
        }
      }

      final response = await api.purgeRecord(
        vaultId: vaultId,
        recordId: entry.recordId,
        expectedDeletedRevisionId: entry.tombstoneRevisionId,
        expectedDeletedSeq: entry.deletedSeq,
      );
      final redaction = response['redaction'];
      if (response.length != 3 ||
          response['status'] != 'purged' ||
          response['already_purged'] is! bool ||
          redaction is! Map ||
          redaction.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Record purge response does not match the signed protocol.',
        );
      }
      final proof = _verifyRecordRedactionProof(
        Map<String, dynamic>.from(redaction),
        recordId: entry.recordId,
      );
      if (proof.deletedRevisionId != entry.tombstoneRevisionId ||
          proof.deletedSeq != entry.deletedSeq) {
        throw const FormatException(
          'Record purge proof does not match the selected tombstone.',
        );
      }
      await database.applyRecordRedaction(
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        serverGeneration: serverGeneration,
        proof: proof.toJson(),
      );
      return proof;
    }),
  );

  /// Creates a fresh current-device-signed restore operation. It is strictly
  /// online-first: a fresh server snapshot must still contain the exact
  /// tombstone, and the local cache must contain that same committed head with
  /// no pending operation for the record. The server performs the matching
  /// tombstone CAS again when the queued envelope is pushed.
  Future<String> restoreRecycleBinRecord({
    required String recordId,
    required String expectedTombstoneRevisionId,
    required String expectedPreviousRevisionId,
    String? Function(
      Map<String, Object?> candidate,
      List<Map<String, dynamic>> currentRecords,
    )?
    validateReferences,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      if (!_canonicalUuid.hasMatch(recordId) ||
          !_canonicalUuid.hasMatch(expectedTombstoneRevisionId) ||
          !_canonicalUuid.hasMatch(expectedPreviousRevisionId)) {
        throw const FormatException(
          'Recycle bin restore selection is invalid.',
        );
      }
      _beginLocalWrite();
      try {
        final snapshot = await _createVerifiedRecycleBinSnapshot();
        final remoteTombstone = snapshot.tombstones[recordId];
        if (remoteTombstone == null ||
            remoteTombstone.revisionId != expectedTombstoneRevisionId) {
          throw const LocalRecordHeadChangedException('server tombstone');
        }
        final verifiedTombstone = await _verifyRecycleBinRevision(
          envelope: remoteTombstone.envelope,
          expectedRecordId: recordId,
          expectedRevisionId: expectedTombstoneRevisionId,
          expectedOperation: 'delete',
          expectedDeleted: true,
        );
        if (verifiedTombstone.header['base_revision_id'] !=
            expectedPreviousRevisionId) {
          throw const LocalRecordHeadChangedException('previous revision');
        }

        late final Map<String, dynamic> detail;
        try {
          detail = await api.revision(vaultId, expectedPreviousRevisionId);
        } on ApiException catch (error) {
          if (error.statusCode == 410 && error.code == 'RECORD_REDACTED') {
            await _applyRecordRedactionFromApiError(
              error,
              expectedRecordId: recordId,
            );
          }
          rethrow;
        }
        final rawPreviousEnvelope = detail['envelope'];
        if (detail['record_id'] != recordId || rawPreviousEnvelope is! Map) {
          throw const FormatException(
            'Previous revision response does not match the selected record.',
          );
        }
        final previous = await _verifyRecycleBinRevision(
          envelope: Map<String, dynamic>.from(rawPreviousEnvelope),
          expectedRecordId: recordId,
          expectedRevisionId: expectedPreviousRevisionId,
          expectedDeleted: false,
        );

        final localSnapshot = await _loadRecordsWithHeadRevisionSnapshot(
          includeDeleted: true,
        );
        if (unavailableRecordIds.isNotEmpty) {
          throw const FormatException(
            'Some local records could not be authenticated; synchronize or repair the Vault before restoring.',
          );
        }
        final local = await database.encryptedRecord(
          vaultId,
          recordId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        if (local == null ||
            local.revisionId != expectedTombstoneRevisionId ||
            !local.isDeleted ||
            local.commitSeq == null ||
            local.commitSeq != remoteTombstone.commitSeq) {
          throw LocalRecordHeadChangedException(recordId);
        }
        if ((await database.allPendingOperations(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        )).any((operation) => operation.recordId == recordId)) {
          throw StateError(
            'Synchronize or resolve the pending operation for this record before restoring it.',
          );
        }
        final localTombstone = await _verifyRecycleBinRevision(
          envelope: jsonDecode(local.envelopeJson) as Map<String, dynamic>,
          expectedRecordId: recordId,
          expectedRevisionId: expectedTombstoneRevisionId,
          expectedOperation: 'delete',
          expectedDeleted: true,
        );
        if (localTombstone.header['base_revision_id'] !=
            expectedPreviousRevisionId) {
          throw LocalRecordHeadChangedException(recordId);
        }
        if (previous.plaintext['type'] != localTombstone.plaintext['type']) {
          throw const FormatException(
            'Previous record type does not match the signed tombstone.',
          );
        }
        final referenceIssue = validateReferences?.call(
          Map<String, Object?>.from(previous.plaintext),
          localSnapshot.records,
        );
        if (referenceIssue != null) throw StateError(referenceIssue);

        final envelope = await _encryptOperation(
          recordId: recordId,
          plaintext: Map<String, Object?>.from(previous.plaintext),
          baseRevisionId: expectedTombstoneRevisionId,
          operation: 'restore',
        );
        await database.putLocalOperation(
          vaultId: vaultId,
          recordId: recordId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          baseRevisionId: expectedTombstoneRevisionId,
          envelope: envelope,
          deleted: false,
          expectedCachedHeadRevisionId: expectedTombstoneRevisionId,
          expectedVaultHeadRevisionIds: localSnapshot.headRevisionIds,
        );
        return (envelope['header'] as Map<String, dynamic>)['revision_id']
            as String;
      } finally {
        _endLocalWrite();
      }
    }),
  );

  Future<_RecycleBinSnapshot> _createVerifiedRecycleBinSnapshot() async {
    await refreshSignerDirectory();
    final instance = await api.fetchInstance();
    _checkInstance(instance);
    if (instance.generation != serverGeneration) {
      throw ApiException(
        statusCode: 410,
        code: 'SERVER_GENERATION_CHANGED',
        message: currentL10n.theServerGenerationChangedSynchronizeBefore,
      );
    }
    final created = await api.createSnapshot(vaultId);
    final snapshotId = created['snapshot_id'];
    final highWatermark = created['high_watermark'];
    final conflictHighWatermark = created['conflict_high_watermark'];
    final checkpointCursor = created['next_cursor'];
    final expiresAt = created['expires_at'];
    final itemCount = created['item_count'];
    final parsedExpiration = expiresAt is String
        ? DateTime.tryParse(expiresAt)
        : null;
    if (snapshotId is! String ||
        !_canonicalUuid.hasMatch(snapshotId) ||
        highWatermark is! String ||
        !_canonicalDecimal.hasMatch(highWatermark) ||
        conflictHighWatermark is! String ||
        !_canonicalDecimal.hasMatch(conflictHighWatermark) ||
        checkpointCursor is! String ||
        checkpointCursor.isEmpty ||
        checkpointCursor.length > 2048 ||
        expiresAt is! String ||
        parsedExpiration == null ||
        itemCount is! int ||
        itemCount < 0 ||
        itemCount > _maxSnapshotManifestHeads) {
      throw const FormatException('Recycle bin snapshot response is invalid.');
    }
    if (!parsedExpiration.toUtc().isAfter(DateTime.now().toUtc())) {
      throw ApiException(
        statusCode: 410,
        code: 'SNAPSHOT_EXPIRED',
        message: currentL10n.recycleBinSnapshotExpiredBeforeIt,
      );
    }

    final tombstones = <String, SnapshotHead>{};
    final graveyards = <SnapshotHead>[];
    final seenRecordIds = <String>{};
    final seenCursors = <String>{};
    var cursor = null as String?;
    String? previousRecordId;
    var count = 0;
    var serializedBytes = 0;
    while (true) {
      final page = await api.snapshot(
        snapshotId,
        limit: _snapshotPageLimit,
        pageCursor: cursor,
      );
      final manifest = page['manifest'];
      final hasMore = page['has_more'];
      final nextCursor = page['next_page_cursor'];
      if (page['snapshot_id'] != snapshotId ||
          page['high_watermark'] != highWatermark ||
          page['conflict_high_watermark'] != conflictHighWatermark ||
          page['next_cursor'] != checkpointCursor ||
          page['expires_at'] != expiresAt ||
          page['server_generation'] != serverGeneration ||
          page['item_count'] != itemCount ||
          manifest is! List ||
          hasMore is! bool ||
          (nextCursor != null && nextCursor is! String) ||
          hasMore != (nextCursor != null) ||
          (cursor != null && manifest.isEmpty && hasMore)) {
        throw const FormatException(
          'Recycle bin snapshot page metadata is inconsistent.',
        );
      }
      for (final raw in manifest) {
        serializedBytes += utf8.encode(jsonEncode(raw)).length;
      }
      if (serializedBytes > 64 * 1024 * 1024 ||
          count + manifest.length > _maxSnapshotManifestHeads) {
        throw const SnapshotBootstrapLimitException();
      }
      final verifiedHeads = await _verifySnapshotHeads(
        manifest,
        highWatermark: highWatermark,
      );
      for (final head in verifiedHeads) {
        if (!seenRecordIds.add(head.recordId) ||
            (previousRecordId != null &&
                head.recordId.compareTo(previousRecordId) <= 0)) {
          throw const FormatException(
            'Recycle bin snapshot record order is invalid.',
          );
        }
        previousRecordId = head.recordId;
        count++;
        if (head.isGraveyard) {
          graveyards.add(head);
          continue;
        }
        if (!head.deleted) continue;
        if (head.commitSeq == null ||
            !_canonicalPositiveDecimal.hasMatch(head.commitSeq!) ||
            _compareDecimalSeq(head.commitSeq!, highWatermark) > 0) {
          throw const FormatException(
            'Tombstone snapshot head has no valid committed sequence.',
          );
        }
        final verified = await _verifyRecycleBinRevision(
          envelope: head.envelope,
          expectedRecordId: head.recordId,
          expectedRevisionId: head.revisionId,
          expectedOperation: 'delete',
          expectedDeleted: true,
        );
        if (verified.plaintext['type'] is! String) {
          throw const FormatException('Tombstone record type is missing.');
        }
        tombstones[head.recordId] = head;
      }
      if (!hasMore) break;
      final next = nextCursor as String;
      if (next.isEmpty || next.length > 2048 || !seenCursors.add(next)) {
        throw const FormatException('Recycle bin snapshot cursor repeated.');
      }
      cursor = next;
    }
    if (count != itemCount) {
      throw const FormatException(
        'Recycle bin snapshot item count does not match its pages.',
      );
    }
    if (graveyards.isNotEmpty) {
      await database.applyRecordRedactions(
        serverGeneration: serverGeneration,
        proofs: graveyards
            .map((head) => head.redactionProof!)
            .toList(growable: false),
      );
    }
    return _RecycleBinSnapshot(
      snapshotId: snapshotId,
      highWatermark: highWatermark,
      conflictHighWatermark: conflictHighWatermark,
      checkpointCursor: checkpointCursor,
      expiresAt: expiresAt,
      expectedItemCount: itemCount,
      tombstones: Map.unmodifiable(tombstones),
    );
  }

  Future<_VerifiedRecycleBinRevision> _verifyRecycleBinRevision({
    required Map<String, dynamic> envelope,
    required String expectedRecordId,
    required String expectedRevisionId,
    String? expectedOperation,
    required bool expectedDeleted,
  }) async {
    final header = crypto.validateRecordEnvelope(envelope);
    if (header['server_space_id'] != serverSpaceId ||
        header['vault_id'] != vaultId ||
        header['record_id'] != expectedRecordId ||
        header['revision_id'] != expectedRevisionId ||
        (expectedOperation != null &&
            header['operation'] != expectedOperation)) {
      throw const FormatException(
        'Encrypted revision does not match its Vault history context.',
      );
    }
    final deviceId = header['device_id'];
    final signer = deviceId is String ? _signers[deviceId] : null;
    if (signer == null) {
      throw const FormatException('Historical revision signer is unknown.');
    }
    final keyVersion = '${header['key_epoch']}:${header['membership_version']}';
    final key =
        vaultKeysByVersion[keyVersion] ??
        (header['key_epoch'] == keyEpoch &&
                header['membership_version'] == membershipVersion
            ? vaultKey
            : null);
    if (key == null) {
      throw FormatException(
        'Historical revision needs unavailable Vault key version $keyVersion.',
      );
    }
    final plaintext = await crypto.decryptRecord(
      vaultKey: Uint8List.fromList(key),
      envelope: envelope,
      authorPublicKey: Uint8List.fromList(signer),
    );
    final type = plaintext['type'];
    final deleted = plaintext['deleted'];
    if (plaintext['id'] != expectedRecordId ||
        type is! String ||
        !RecordKind.values.any((kind) => kind.name == type) ||
        (deleted != null && deleted is! bool) ||
        (deleted == true) != expectedDeleted ||
        (header['operation'] == 'delete') != expectedDeleted) {
      throw const FormatException(
        'Decrypted revision does not match its signed record metadata.',
      );
    }
    return _VerifiedRecycleBinRevision(header: header, plaintext: plaintext);
  }

  String _recycleBinDisplayName(
    String recordType,
    Map<String, dynamic> record,
  ) {
    final value = switch (recordType) {
      'host' => record['name'],
      'credential' || 'group' || 'snippet' => record['name'],
      'workspace' => record['name'] ?? record['title'],
      'preference' => record['key'],
      'knownHost' => record['host'],
      'shellHistory' => 'Terminal command history',
      _ => null,
    };
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return switch (recordType) {
      'host' => 'Unnamed host',
      'credential' => 'Unnamed credential',
      'group' => 'Unnamed group',
      'snippet' => 'Unnamed snippet',
      'workspace' => 'Saved workspace',
      'preference' => 'Vault preference',
      'knownHost' => 'Known host',
      'shellHistory' => 'Terminal command history',
      _ => 'Encrypted record',
    };
  }

  Future<
    ({List<Map<String, dynamic>> records, Map<String, String> headRevisionIds})
  >
  _loadRecordsWithHeadRevisionSnapshot({bool includeDeleted = false}) async {
    if (_signers.isEmpty) await refreshSignerDirectory();

    final rows = await database.cachedEnvelopes(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final headRevisionIds = Map<String, String>.unmodifiable({
      for (final row in rows) row.recordId: row.revisionId,
    });

    final result = <Map<String, dynamic>>[];
    unavailableRecordIds.clear();
    for (final row in rows) {
      if (row.isDeleted && !includeDeleted) {
        continue;
      }
      final envelope = jsonDecode(row.envelopeJson) as Map<String, dynamic>;
      final header = envelope['header'] as Map<String, dynamic>;
      if (header['record_id'] != row.recordId ||
          header['revision_id'] != row.revisionId) {
        unavailableRecordIds.add(row.recordId);
        continue;
      }
      final signer = _signers[header['device_id'] as String];
      if (signer == null) {
        unavailableRecordIds.add(row.recordId);
        continue;
      }
      final keyVersion =
          '${header['key_epoch']}:${header['membership_version']}';
      final versionedRecordKey = vaultKeysByVersion[keyVersion];

      final recordKey = versionedRecordKey ?? vaultKey;
      try {
        final plain = await crypto.decryptRecord(
          vaultKey: Uint8List.fromList(recordKey),
          envelope: envelope,
          authorPublicKey: Uint8List.fromList(signer),
        );

        if (plain['deleted'] == true) continue;
        final recordType = plain['type'];
        if (recordType is! String ||
            !RecordKind.values.any((kind) => kind.name == recordType)) {
          // Keep future or unsupported records encrypted in the cache, but
          // make the limitation visible instead of silently dropping them.
          unavailableRecordIds.add(row.recordId);
          continue;
        }
        result.add({
          ...plain,
          '_record_id': row.recordId,
          '_revision_id': row.revisionId,
        });
      } on FormatException {
        // A malformed or unknown record remains encrypted in the local store.
        // The UI reports the count without discarding either ciphertext branch.
        unavailableRecordIds.add(row.recordId);
      } on SodiumException {
        rethrow;
      } on Object {
        rethrow;
      }
    }

    return (records: result, headRevisionIds: headRevisionIds);
  }

  /// Finds preference conflict-repair tombstones that are still pending or
  /// have not been observed in a complete changes pull. The versioned repair
  /// marker is part of the encrypted tombstone payload, so a restart can keep
  /// the corresponding preference tuple fail-closed without storing
  /// plaintext preferences or adding local schema.
  Future<List<PendingDefaultPreferenceRepair>>
  unconfirmedPreferenceRepairs() => _withKeyOperation(() async {
    if (_signers.isEmpty) await refreshSignerDirectory();
    final checkpoint = await database.checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final pending = await database.allPendingOperations(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final pendingRepairs = <String, PendingDefaultPreferenceRepair>{};

    for (final operation in pending) {
      final marker = await _decodePreferenceRepairMarker(
        envelopeJson: operation.envelopeJson,
        recordId: operation.recordId,
      );
      if (marker != null) {
        pendingRepairs['${marker.deletedRecordId}:${marker.retainedRecordId}:${marker.scope}:${marker.key}:${marker.platformFamily}'] =
            marker;
      }
    }

    final cachedRows = await database.cachedEnvelopes(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final row in cachedRows.where(
      (row) => row.isDeleted && !_checkpointCovers(checkpoint, row.commitSeq),
    )) {
      final marker = await _decodePreferenceRepairMarker(
        envelopeJson: row.envelopeJson,
        recordId: row.recordId,
      );
      if (marker == null) continue;
      final key =
          '${marker.deletedRecordId}:${marker.retainedRecordId}:${marker.scope}:${marker.key}:${marker.platformFamily}';
      if (pendingRepairs.containsKey(key)) continue;
      pendingRepairs[key] = marker;
    }

    return List.unmodifiable(pendingRepairs.values);
  });

  /// Backwards-compatible query for the original default-section conflict
  /// repair marker. New tuple-aware code should call
  /// [unconfirmedPreferenceRepairs].
  Future<List<PendingDefaultPreferenceRepair>>
  unconfirmedDefaultPreferenceRepairs() async => List.unmodifiable(
    (await unconfirmedPreferenceRepairs()).where(
      (marker) => marker.isDefaultWorkspaceSection,
    ),
  );

  Future<PendingDefaultPreferenceRepair?> _decodePreferenceRepairMarker({
    required String envelopeJson,
    required String recordId,
  }) async {
    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map) {
      throw const FormatException(
        'Encrypted preference repair tombstone is malformed.',
      );
    }
    final envelope = Map<String, dynamic>.from(decoded);
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw const FormatException(
        'Encrypted preference repair tombstone has no header.',
      );
    }
    final header = Map<String, dynamic>.from(rawHeader);
    if (header['operation'] != 'delete') return null;
    if (header['vault_id'] != vaultId || header['record_id'] != recordId) {
      throw const FormatException(
        'Encrypted preference repair tombstone has a mismatched context.',
      );
    }
    final deviceId = header['device_id'];
    final signer = deviceId is String ? _signers[deviceId] : null;
    if (signer == null) {
      throw const FormatException(
        'Encrypted preference repair tombstone signer is unavailable.',
      );
    }
    final epoch = header['key_epoch']?.toString();
    final membershipVersion = header['membership_version']?.toString();
    final recordKey =
        vaultKeysByVersion['$epoch:$membershipVersion'] ?? vaultKey;
    final plaintext = await crypto.decryptRecord(
      vaultKey: Uint8List.fromList(recordKey),
      envelope: envelope,
      authorPublicKey: Uint8List.fromList(signer),
    );
    final hasLegacyMarker = plaintext.containsKey(
      'default_section_conflict_repair',
    );
    final hasVersionedMarker = plaintext.containsKey(
      'preference_conflict_repair',
    );
    if (!hasLegacyMarker && !hasVersionedMarker) {
      return null;
    }
    if (plaintext['id'] != recordId ||
        plaintext['type'] != 'preference' ||
        plaintext['deleted'] != true ||
        hasLegacyMarker == hasVersionedMarker) {
      throw const FormatException(
        'Encrypted preference repair tombstone payload is invalid.',
      );
    }
    final rawRepair =
        plaintext[hasLegacyMarker
            ? 'default_section_conflict_repair'
            : 'preference_conflict_repair'];
    if (rawRepair is! Map) {
      throw const FormatException(
        'Encrypted preference repair marker is invalid.',
      );
    }
    final repair = Map<String, dynamic>.from(rawRepair);
    final String scope;
    final String key;
    final String platformFamily;
    if (hasLegacyMarker) {
      // Existing v1 default-section markers remain recognizable and are not
      // rewritten during readback.
      if (repair.length != 2 || repair['version'] != 1) {
        throw const FormatException(
          'Legacy preference repair marker is invalid.',
        );
      }
      scope = VaultPreferenceRecord.workspaceScope;
      key = VaultPreferenceRecord.defaultSectionKey;
      platformFamily = VaultPreferenceRecord.allPlatforms;
    } else {
      const expectedKeys = {
        'version',
        'kind',
        'scope',
        'key',
        'platform_family',
        'retained_record_id',
      };
      if (repair.keys.toSet().length != expectedKeys.length ||
          !repair.keys.toSet().containsAll(expectedKeys) ||
          repair['version'] != 1 ||
          repair['kind'] != 'duplicate_preference_tuple') {
        throw const FormatException(
          'Versioned preference repair marker is invalid.',
        );
      }
      final rawScope = repair['scope'];
      final rawKey = repair['key'];
      final rawPlatform = repair['platform_family'];
      if (rawScope is! String || rawKey is! String || rawPlatform is! String) {
        throw const FormatException(
          'Versioned preference repair tuple is invalid.',
        );
      }
      scope = rawScope;
      key = rawKey;
      platformFamily = rawPlatform;
      if (!((scope == VaultPreferenceRecord.workspaceScope &&
                  key == VaultPreferenceRecord.defaultSectionKey ||
              scope == VaultPreferenceRecord.workspaceScope &&
                  key == VaultPreferenceRecord.terminalFontSizeKey ||
              scope == VaultPreferenceRecord.workspaceScope &&
                  key == VaultPreferenceRecord.terminalThemeKey ||
              scope == VaultPreferenceRecord.workspaceScope &&
                  key == VaultPreferenceRecord.terminalShortcutsKey) &&
          platformFamily == VaultPreferenceRecord.allPlatforms)) {
        throw const FormatException(
          'Versioned preference repair tuple is unsupported.',
        );
      }
    }
    final retainedRecordId = repair['retained_record_id'];
    if (retainedRecordId is! String ||
        !_canonicalUuid.hasMatch(retainedRecordId) ||
        retainedRecordId == recordId) {
      throw const FormatException(
        'Encrypted preference repair marker is invalid.',
      );
    }
    return PendingDefaultPreferenceRepair(
      deletedRecordId: recordId,
      retainedRecordId: retainedRecordId,
      scope: scope,
      key: key,
      platformFamily: platformFamily,
    );
  }

  bool _checkpointCovers(SyncCheckpoint? checkpoint, String? commitSeq) {
    final cursorSequence = _checkpointCursorSequence(checkpoint);
    if (cursorSequence == null ||
        commitSeq == null ||
        !_isI64Decimal(commitSeq)) {
      return false;
    }
    if (cursorSequence.length != commitSeq.length) {
      return cursorSequence.length > commitSeq.length;
    }
    return cursorSequence.compareTo(commitSeq) >= 0;
  }

  String? _checkpointCursorSequence(SyncCheckpoint? checkpoint) {
    final cursor = checkpoint?.cursor;
    final generation = checkpoint?.serverGeneration;
    if (cursor == null ||
        generation == null ||
        generation != serverGeneration ||
        !_canonicalUuid.hasMatch(generation) ||
        !_canonicalUuid.hasMatch(vaultId) ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(cursor)) {
      return null;
    }
    try {
      final decoded = base64Url.decode(base64Url.normalize(cursor));
      // Server change cursors are base64url(JCS payload || 32-byte HMAC).
      // The API server validates the token before serving changes, and this
      // checkpoint advances only after each page has been validated and
      // durably stored. We only extract sequence metadata for local ordering;
      // this does not verify the HMAC and is never used for authorization or
      // record-integrity decisions.
      if (decoded.length <= 32 ||
          base64Url.encode(decoded).replaceAll('=', '') != cursor) {
        return null;
      }
      final payloadBytes = decoded.sublist(0, decoded.length - 32);
      final payloadText = utf8.decode(payloadBytes);
      final payload = jsonDecode(payloadText);
      if (payload is! Map<String, dynamic> ||
          !_hasExactKeys(payload, const {
            'v',
            'vault_id',
            'seq',
            'generation',
          }) ||
          payload['v'] != 1 ||
          payload['vault_id'] != vaultId ||
          payload['generation'] != generation) {
        return null;
      }
      final sequenceMatch = RegExp(
        r'^\{"generation":"[0-9a-f-]{36}","seq":(0|[1-9][0-9]*),"v":1,"vault_id":"[0-9a-f-]{36}"\}$',
      ).firstMatch(payloadText);
      if (sequenceMatch == null || payload['seq'] is! num) return null;
      final value = sequenceMatch.group(1)!;
      if (!_isI64Decimal(value)) return null;
      final canonicalPayload =
          '{"generation":${jsonEncode(generation)},"seq":$value,"v":1,'
          '"vault_id":${jsonEncode(vaultId)}}';
      return payloadText == canonicalPayload ? value : null;
    } on FormatException {
      // A malformed or foreign checkpoint must keep the repair fail-closed.
      return null;
    }
  }

  /// Reads the active feed as safe display metadata. The event ciphertext and
  /// decrypted fields are kept inside the repository and never returned to UI.
  Future<List<ConflictFeedReviewItem>>
  loadConflictFeedReviewItems() => _withKeyOperation(() async {
    final generation = await database.activeConflictFeedGeneration(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final partitionId = await database.activeConflictFeedPartitionId(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (generation == null || partitionId == null) return const [];
    final events = await database.activeConflictFeedInbox(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    final resolvedIds = events
        .where((event) => event.type == 'resolved')
        .map((event) => event.conflictId)
        .toSet();
    final targets = {
      for (final target in await database.listFeedConflictResolutions(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      ))
        target.conflictId: target,
    };
    List<Map<String, dynamic>> signerRows;
    String? directoryError;
    try {
      // Always use the current Vault-scoped directory. `_signers` is a cache
      // used by the normal change path and is not a trust source for this feed.
      signerRows = await api.vaultDevices(vaultId);
    } on Object {
      signerRows = const [];
      directoryError = 'Vault signer directory is unavailable.';
    }

    final items = <ConflictFeedReviewItem>[];
    for (final event in events.where((event) => event.type == 'created')) {
      final target = targets[event.conflictId];
      final head = await database.encryptedRecord(
        vaultId,
        event.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      _VerifiedFeedConflictBranch? branch;
      String? verificationError = directoryError;
      if (verificationError == null) {
        try {
          branch = await _verifyFeedConflictEvent(event, signerRows);
        } on Object {
          verificationError = 'Conflict branch cannot be verified.';
        }
      }
      final headerPreview = _safeFeedHeaderPreview(event);
      items.add(
        ConflictFeedReviewItem(
          conflictId: event.conflictId,
          recordId: event.recordId,
          seq: event.seq,
          createdAt: event.createdAt,
          serverGeneration: generation,
          partitionId: partitionId,
          baseRevisionId: event.baseRevisionId,
          branchRevisionId:
              branch?.header['revision_id'] as String? ??
              headerPreview?['revision_id'] as String?,
          branchDeviceId: branch?.header['device_id'] as String?,
          branchOperation:
              branch?.header['operation'] as String? ??
              headerPreview?['operation'] as String?,
          keyEpoch:
              branch?.header['key_epoch'] as String? ??
              headerPreview?['key_epoch'] as String?,
          membershipVersion:
              branch?.header['membership_version'] as String? ??
              headerPreview?['membership_version'] as String?,
          currentHeadRevisionId: head?.revisionId,
          currentHeadExists: head != null,
          currentHeadDeleted: head?.isDeleted ?? false,
          currentHeadCommitted: head?.commitSeq != null,
          isVerified: branch != null,
          verificationError: verificationError,
          isResolved:
              resolvedIds.contains(event.conflictId) ||
              target?.state == 'resolved',
          resolutionState: switch (target?.state) {
            'awaiting_commit' || 'cas_refresh' => 'pending',
            'committed' => 'committed',
            'needs_review' => 'reselect_required',
            'resolved' => 'resolved',
            _ => null,
          },
        ),
      );
    }
    return List.unmodifiable(items);
  });

  /// Reports field-merge eligibility without returning decrypted Credential
  /// values to the caller. The eligible Credential contents are decrypted and
  /// discarded inside the repository.
  Future<bool> isPasswordCredentialMergeEligible({
    required String conflictId,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      try {
        final signers = await api.vaultDevices(vaultId);
        return await _verifiedPasswordCredentialConflict(
              conflictId: conflictId,
              signerRows: signers,
            ) !=
            null;
      } on FormatException {
        return false;
      } on SodiumException {
        return false;
      }
    }),
  );

  /// Loads a verified, transient preview for one password Credential conflict.
  /// `local` is the losing conflict branch; `remote` is the current committed
  /// head. Unsupported or stale conflicts return null.
  Future<CredentialConflictMergePreview?> loadCredentialConflictMergePreview({
    required String conflictId,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      final signers = await api.vaultDevices(vaultId);
      try {
        return (await _verifiedPasswordCredentialConflict(
          conflictId: conflictId,
          signerRows: signers,
        ))?.preview;
      } on FormatException {
        return null;
      } on SodiumException {
        return null;
      }
    }),
  );

  /// Stages a new signed update against the exact committed head shown in the
  /// preview. Only name, username, and secret can be selected from the two
  /// verified branches. A changed head returns `reviewRequired` without
  /// staging an outbox operation.
  Future<CredentialConflictMergeOutcome> mergePasswordCredentialConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required Map<CredentialConflictMergeField, CredentialConflictMergeBranch>
    choices,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      _beginLocalWrite();
      try {
        final signers = await api.vaultDevices(vaultId);
        await _requireCurrentDeviceActive(signers);
        final verified = await _verifiedPasswordCredentialConflict(
          conflictId: conflictId,
          signerRows: signers,
        );
        if (verified == null ||
            verified.preview.currentHeadRevisionId != expectedHeadRevisionId) {
          return const CredentialConflictMergeOutcome.reviewRequired();
        }

        final preview = verified.preview;
        final requiredChoices = <CredentialConflictMergeField>{
          CredentialConflictMergeField.secret,
          if (!preview.name.sameOnBothBranches)
            CredentialConflictMergeField.name,
          if (!preview.username.sameOnBothBranches)
            CredentialConflictMergeField.username,
        };
        if (!choices.keys.toSet().containsAll(requiredChoices)) {
          throw ArgumentError(
            'Select a branch for the password secret and every differing name or username.',
          );
        }

        String choose(
          CredentialConflictMergeField field,
          CredentialConflictMergeFieldPreview values,
        ) {
          final branch = choices[field];
          if (branch == null) return values.remoteValue;
          return branch == CredentialConflictMergeBranch.local
              ? values.localValue
              : values.remoteValue;
        }

        final merged = Map<String, Object?>.from(verified.remotePlaintext);
        merged['name'] = choose(
          CredentialConflictMergeField.name,
          preview.name,
        );
        merged['username'] = choose(
          CredentialConflictMergeField.username,
          preview.username,
        );
        final selectedSecret = choose(
          CredentialConflictMergeField.secret,
          preview.secret,
        );
        merged['secret'] = selectedSecret;

        final envelope = await _encryptOperation(
          recordId: preview.recordId,
          plaintext: merged,
          baseRevisionId: expectedHeadRevisionId,
          operation: 'update',
        );
        final generation = await database.activeConflictFeedGeneration(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        final partition = await database.activeConflictFeedPartitionId(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        if (generation == null || partition == null) {
          return const CredentialConflictMergeOutcome.reviewRequired();
        }
        try {
          await database.stageFeedConflictAdoption(
            vaultId: vaultId,
            conflictId: conflictId,
            serverGeneration: generation,
            partitionId: partition,
            recordId: preview.recordId,
            expectedHeadRevisionId: expectedHeadRevisionId,
            envelope: envelope,
            deleted: false,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
        } on StateError {
          // The transaction is the authoritative local CAS. Distinguish a
          // changed head or resolved conflict from unrelated staging failures.
          final current = await database.encryptedRecord(
            vaultId,
            preview.recordId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          final stillEligible = await _verifiedPasswordCredentialConflict(
            conflictId: conflictId,
            signerRows: signers,
          );
          if (current?.revisionId != expectedHeadRevisionId ||
              current?.commitSeq == null ||
              stillEligible == null) {
            return const CredentialConflictMergeOutcome.reviewRequired();
          }
          rethrow;
        }
        final header = envelope['header'] as Map<String, dynamic>;
        return CredentialConflictMergeOutcome.staged(
          revisionId: header['revision_id'] as String,
        );
      } finally {
        _endLocalWrite();
      }
    }),
  );

  Future<_VerifiedPasswordCredentialConflict?>
  _verifiedPasswordCredentialConflict({
    required String conflictId,
    required List<Map<String, dynamic>> signerRows,
  }) async {
    if (!_canonicalUuid.hasMatch(conflictId)) return null;
    final target = await database.feedConflictResolution(
      conflictId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (target != null && target.state != 'needs_review') return null;
    final events = await database.activeConflictFeedInbox(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (events.any(
      (event) => event.conflictId == conflictId && event.type == 'resolved',
    )) {
      return null;
    }
    final event = await database.activeCreatedConflictEvent(
      vaultId: vaultId,
      conflictId: conflictId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (event == null) return null;
    final branch = await _verifyFeedConflictEvent(event, signerRows);
    if (branch.header['operation'] != 'update' ||
        branch.header['base_revision_id'] == null ||
        branch.plaintext['type'] != RecordKind.credential.name ||
        branch.plaintext['kind'] != AuthKind.password.name ||
        branch.plaintext['id'] != event.recordId ||
        branch.plaintext['deleted'] == true) {
      return null;
    }

    final current = await database.encryptedRecord(
      vaultId,
      event.recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (current == null || current.isDeleted || current.commitSeq == null) {
      return null;
    }
    final decodedCurrent = jsonDecode(current.envelopeJson);
    if (decodedCurrent is! Map ||
        decodedCurrent.keys.any((key) => key is! String)) {
      return null;
    }
    final currentEnvelope = Map<String, dynamic>.from(decodedCurrent);
    final rawHeader = currentEnvelope['header'];
    if (rawHeader is! Map || rawHeader.keys.any((key) => key is! String)) {
      return null;
    }
    final currentHeader = Map<String, dynamic>.from(rawHeader);
    if (currentHeader['revision_id'] != current.revisionId ||
        currentHeader['record_id'] != event.recordId) {
      return null;
    }
    final rawBaseRevisionId = currentHeader['base_revision_id'];
    if (rawBaseRevisionId != null && rawBaseRevisionId is! String) {
      return null;
    }
    final verifiedCurrent = await _verifyFeedConflictEvent(
      ConflictChangeEvent(
        seq: event.seq,
        type: 'created',
        conflictId: event.conflictId,
        recordId: event.recordId,
        baseRevisionId: rawBaseRevisionId as String?,
        resolvedRevisionId: null,
        createdAt: event.createdAt,
        envelope: currentEnvelope,
      ),
      signerRows,
    );
    if (!const {
          'create',
          'update',
          'restore',
        }.contains(currentHeader['operation']) ||
        currentHeader['revision_id'] == branch.header['revision_id'] ||
        verifiedCurrent.plaintext['type'] != RecordKind.credential.name ||
        verifiedCurrent.plaintext['kind'] != AuthKind.password.name ||
        verifiedCurrent.plaintext['id'] != event.recordId ||
        verifiedCurrent.plaintext['deleted'] == true) {
      return null;
    }
    bool supportsCredentialFields(Map<String, dynamic> plaintext) {
      const allowedKeys = {
        'id',
        'type',
        'name',
        'username',
        'kind',
        'secret',
        'deleted',
        '_manifest',
      };
      if (plaintext.keys.any((key) => !allowedKeys.contains(key))) return false;
      final manifest = plaintext['_manifest'];
      if (manifest != null && manifest is! Map) return false;
      final localManifest = branch.plaintext['_manifest'];
      final remoteManifest = verifiedCurrent.plaintext['_manifest'];
      return canonicalJson(localManifest) == canonicalJson(remoteManifest);
    }

    CredentialConflictMergeFieldPreview? field(String name) {
      final local = branch.plaintext[name];
      final remote = verifiedCurrent.plaintext[name];
      if (local is! String || remote is! String) {
        return null;
      }
      return CredentialConflictMergeFieldPreview(
        localValue: local,
        remoteValue: remote,
      );
    }

    final name = field('name');
    final username = field('username');
    final secret = field('secret');
    if (name == null ||
        username == null ||
        secret == null ||
        username.remoteValue.isEmpty ||
        username.localValue.isEmpty ||
        name.remoteValue.isEmpty ||
        name.localValue.isEmpty ||
        secret.localValue.isEmpty ||
        secret.remoteValue.isEmpty ||
        !supportsCredentialFields(branch.plaintext) ||
        !supportsCredentialFields(verifiedCurrent.plaintext)) {
      return null;
    }
    return _VerifiedPasswordCredentialConflict(
      preview: CredentialConflictMergePreview(
        conflictId: conflictId,
        recordId: event.recordId,
        branchRevisionId: branch.header['revision_id'] as String,
        currentHeadRevisionId: current.revisionId,
        name: name,
        username: username,
        secret: secret,
      ),
      localPlaintext: branch.plaintext,
      remotePlaintext: verifiedCurrent.plaintext,
    );
  }

  /// Loads a display-safe, signature-verified preview of a Host connection
  /// security conflict. The immutable base revision is fetched by ID and
  /// verified locally; if the server has compacted it or any envelope cannot
  /// be authenticated, no merge preview is offered.
  Future<HostSecurityConflictMergePreview?>
  loadHostSecurityConflictMergePreview({required String conflictId}) =>
      _withKeyOperation(
        () => _runSerialized(() async {
          try {
            final signers = await api.vaultDevices(vaultId);
            return (await _verifiedHostSecurityConflict(
              conflictId: conflictId,
              signerRows: signers,
            ))?.preview;
          } on FormatException {
            return null;
          } on SodiumException {
            return null;
          }
        }),
      );

  /// Stages a current-device-signed Host revision after explicit selection of
  /// the complete connection-security tuple from one verified branch. The
  /// database stage is an exact current-head CAS; stale previews do not write
  /// an outbox row.
  Future<HostSecurityConflictMergeOutcome> mergeHostSecurityConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required HostSecurityMergeBranch choice,
    required String? Function(Map<String, Object?> candidate)
    validateReferences,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      _beginLocalWrite();
      try {
        final signers = await api.vaultDevices(vaultId);
        await _requireCurrentDeviceActive(signers);
        final verified = await _verifiedHostSecurityConflict(
          conflictId: conflictId,
          signerRows: signers,
        );
        if (verified == null ||
            verified.preview.currentHeadRevisionId != expectedHeadRevisionId) {
          return const HostSecurityConflictMergeOutcome.reviewRequired();
        }

        final candidate = mergeHostSecurityConflictRecord(
          recordId: verified.preview.recordId,
          base: verified.basePlaintext,
          conflict: verified.conflictPlaintext,
          current: verified.currentPlaintext,
          choice: choice,
        );
        if (candidate == null) {
          return const HostSecurityConflictMergeOutcome.reviewRequired();
        }
        final referenceIssue = validateReferences(candidate);
        if (referenceIssue != null) throw StateError(referenceIssue);

        final envelope = await _encryptOperation(
          recordId: verified.preview.recordId,
          plaintext: candidate,
          baseRevisionId: expectedHeadRevisionId,
          operation: 'update',
        );
        final generation = await database.activeConflictFeedGeneration(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        final partition = await database.activeConflictFeedPartitionId(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        if (generation == null || partition == null) {
          return const HostSecurityConflictMergeOutcome.reviewRequired();
        }
        try {
          await database.stageFeedConflictAdoption(
            vaultId: vaultId,
            conflictId: conflictId,
            serverGeneration: generation,
            partitionId: partition,
            recordId: verified.preview.recordId,
            expectedHeadRevisionId: expectedHeadRevisionId,
            envelope: envelope,
            deleted: false,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
        } on StateError {
          final current = await database.encryptedRecord(
            vaultId,
            verified.preview.recordId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          final stillEligible = await _verifiedHostSecurityConflict(
            conflictId: conflictId,
            signerRows: signers,
          );
          if (current?.revisionId != expectedHeadRevisionId ||
              current?.commitSeq == null ||
              stillEligible == null) {
            return const HostSecurityConflictMergeOutcome.reviewRequired();
          }
          rethrow;
        }
        final header = envelope['header'] as Map<String, dynamic>;
        return HostSecurityConflictMergeOutcome.staged(
          revisionId: header['revision_id'] as String,
        );
      } finally {
        _endLocalWrite();
      }
    }),
  );

  Future<_VerifiedHostSecurityConflict?> _verifiedHostSecurityConflict({
    required String conflictId,
    required List<Map<String, dynamic>> signerRows,
  }) async {
    if (!_canonicalUuid.hasMatch(conflictId)) return null;
    final target = await database.feedConflictResolution(
      conflictId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (target != null && target.state != 'needs_review') return null;
    final events = await database.activeConflictFeedInbox(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (events.any(
      (event) => event.conflictId == conflictId && event.type == 'resolved',
    )) {
      return null;
    }
    final event = await database.activeCreatedConflictEvent(
      vaultId: vaultId,
      conflictId: conflictId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (event == null || event.baseRevisionId == null) return null;

    final branch = await _verifyFeedConflictEvent(event, signerRows);
    final baseRevisionId = branch.header['base_revision_id'];
    if (branch.header['operation'] != 'update' ||
        baseRevisionId is! String ||
        !_canonicalUuid.hasMatch(baseRevisionId) ||
        baseRevisionId != event.baseRevisionId ||
        !_isLiveHost(branch.plaintext, event.recordId)) {
      return null;
    }

    late final Map<String, dynamic> baseDetail;
    try {
      baseDetail = await api.revision(vaultId, baseRevisionId);
    } on ApiException catch (error) {
      if (error.statusCode == 410 && error.code == 'RECORD_REDACTED') {
        await _applyRecordRedactionFromApiError(
          error,
          expectedRecordId: event.recordId,
        );
        return null;
      }
      rethrow;
    }
    if (baseDetail['record_id'] != event.recordId ||
        baseDetail['envelope'] is! Map) {
      return null;
    }
    final baseEnvelope = Map<String, dynamic>.from(
      baseDetail['envelope'] as Map,
    );
    final baseHeaderValue = baseEnvelope['header'];
    if (baseHeaderValue is! Map) return null;
    final baseHeader = Map<String, dynamic>.from(baseHeaderValue);
    if (baseHeader['revision_id'] != baseRevisionId ||
        baseHeader['record_id'] != event.recordId ||
        baseHeader['vault_id'] != vaultId) {
      return null;
    }
    final baseEvent = ConflictChangeEvent(
      seq: event.seq,
      type: 'created',
      conflictId: event.conflictId,
      recordId: event.recordId,
      baseRevisionId: baseHeader['base_revision_id'] as String?,
      resolvedRevisionId: null,
      createdAt: event.createdAt,
      envelope: baseEnvelope,
    );
    final verifiedBase = await _verifyFeedConflictEvent(baseEvent, signerRows);
    if (!_isLiveHost(verifiedBase.plaintext, event.recordId)) return null;

    final current = await database.encryptedRecord(
      vaultId,
      event.recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (current == null || current.isDeleted || current.commitSeq == null) {
      return null;
    }
    final rawCurrentEnvelope = jsonDecode(current.envelopeJson);
    if (rawCurrentEnvelope is! Map) return null;
    final currentEnvelope = Map<String, dynamic>.from(rawCurrentEnvelope);
    final rawCurrentHeader = currentEnvelope['header'];
    if (rawCurrentHeader is! Map) return null;
    final currentHeader = Map<String, dynamic>.from(rawCurrentHeader);
    if (currentHeader['revision_id'] != current.revisionId ||
        currentHeader['record_id'] != event.recordId ||
        currentHeader['vault_id'] != vaultId ||
        !const {
          'create',
          'update',
          'restore',
        }.contains(currentHeader['operation'])) {
      return null;
    }
    final currentEvent = ConflictChangeEvent(
      seq: event.seq,
      type: 'created',
      conflictId: event.conflictId,
      recordId: event.recordId,
      baseRevisionId: currentHeader['base_revision_id'] as String?,
      resolvedRevisionId: null,
      createdAt: event.createdAt,
      envelope: currentEnvelope,
    );
    final verifiedCurrent = await _verifyFeedConflictEvent(
      currentEvent,
      signerRows,
    );
    if (!_isLiveHost(verifiedCurrent.plaintext, event.recordId)) return null;

    final preview = previewHostSecurityConflict(
      conflictId: conflictId,
      recordId: event.recordId,
      baseRevisionId: baseRevisionId,
      branchRevisionId: branch.header['revision_id'] as String,
      currentHeadRevisionId: current.revisionId,
      base: verifiedBase.plaintext,
      conflict: branch.plaintext,
      current: verifiedCurrent.plaintext,
    );
    if (preview == null) return null;
    return _VerifiedHostSecurityConflict(
      preview: preview,
      basePlaintext: verifiedBase.plaintext,
      conflictPlaintext: branch.plaintext,
      currentPlaintext: verifiedCurrent.plaintext,
    );
  }

  bool _isLiveHost(Map<String, dynamic> plaintext, String recordId) =>
      plaintext['type'] == RecordKind.host.name &&
      plaintext['id'] == recordId &&
      plaintext['deleted'] != true;

  /// Creates a fresh, device-signed revision from a verified remote branch.
  /// The database transaction binds it to the head observed immediately before
  /// staging; the original feed ciphertext remains untouched.
  Future<void> adoptRemoteConflict(String conflictId) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError('This Vault is not writable.');
      }
      _beginLocalWrite();
      try {
        final event = await database.activeCreatedConflictEvent(
          vaultId: vaultId,
          conflictId: conflictId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        if (event == null)
          throw StateError('Conflict is missing from the inbox.');
        final signerRows = await api.vaultDevices(vaultId);
        await _requireCurrentDeviceActive(signerRows);
        final branch = await _verifyFeedConflictEvent(event, signerRows);
        final current = await database.encryptedRecord(
          vaultId,
          event.recordId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        if (current != null && current.commitSeq == null) {
          throw StateError(
            'Synchronize the current local edit before adoption.',
          );
        }
        final remoteDeleted = branch.plaintext['deleted'] == true;
        if (remoteDeleted && current?.isDeleted == true) {
          await database.stageFeedConflictRetainCurrent(
            vaultId: vaultId,
            conflictId: conflictId,
            serverGeneration:
                await database.activeConflictFeedGeneration(
                  vaultId,
                  instanceId: instanceId,
                  serverSpaceId: serverSpaceId,
                ) ??
                (throw StateError('Conflict feed generation is missing.')),
            partitionId:
                await database.activeConflictFeedPartitionId(
                  vaultId,
                  instanceId: instanceId,
                  serverSpaceId: serverSpaceId,
                ) ??
                (throw StateError('Conflict feed partition is missing.')),
            recordId: event.recordId,
            expectedHeadRevisionId: current!.revisionId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          return;
        }
        if (remoteDeleted && current == null) {
          throw StateError(
            'The server head is missing; synchronize before adopting a deletion.',
          );
        }
        final operation = remoteDeleted
            ? 'delete'
            : current == null
            ? 'create'
            : current.isDeleted
            ? 'restore'
            : 'update';
        final envelope = await _encryptOperation(
          recordId: event.recordId,
          plaintext: Map<String, Object?>.from(branch.plaintext),
          baseRevisionId: current?.revisionId,
          operation: operation,
        );
        await database.stageFeedConflictAdoption(
          vaultId: vaultId,
          conflictId: conflictId,
          serverGeneration:
              await database.activeConflictFeedGeneration(
                vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
              ) ??
              (throw StateError('Conflict feed generation is missing.')),
          partitionId:
              await database.activeConflictFeedPartitionId(
                vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
              ) ??
              (throw StateError('Conflict feed partition is missing.')),
          recordId: event.recordId,
          expectedHeadRevisionId: current?.revisionId,
          envelope: envelope,
          deleted: operation == 'delete',
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
      } finally {
        _endLocalWrite();
      }
    }),
  );

  /// Resolves a branch by retaining the current committed head. It intentionally
  /// creates no outbox operation and is disabled for an absent/uncommitted head.
  Future<void> retainCurrentConflictHead(String conflictId) =>
      _withKeyOperation(
        () => _runSerialized(() async {
          if (!canWrite || deletionPending) {
            throw StateError('This Vault is not writable.');
          }
          final event = await database.activeCreatedConflictEvent(
            vaultId: vaultId,
            conflictId: conflictId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          if (event == null)
            throw StateError('Conflict is missing from the inbox.');
          final signerRows = await api.vaultDevices(vaultId);
          await _requireCurrentDeviceActive(signerRows);
          await _verifyFeedConflictEvent(event, signerRows);
          final current = await database.encryptedRecord(
            vaultId,
            event.recordId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          if (current == null || current.commitSeq == null) {
            throw StateError('Only a committed current head can be retained.');
          }
          await database.stageFeedConflictRetainCurrent(
            vaultId: vaultId,
            conflictId: conflictId,
            serverGeneration:
                await database.activeConflictFeedGeneration(
                  vaultId,
                  instanceId: instanceId,
                  serverSpaceId: serverSpaceId,
                ) ??
                (throw StateError('Conflict feed generation is missing.')),
            partitionId:
                await database.activeConflictFeedPartitionId(
                  vaultId,
                  instanceId: instanceId,
                  serverSpaceId: serverSpaceId,
                ) ??
                (throw StateError('Conflict feed partition is missing.')),
            recordId: event.recordId,
            expectedHeadRevisionId: current.revisionId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
        }),
      );

  Future<_VerifiedFeedConflictBranch> _verifyFeedConflictEvent(
    ConflictChangeEvent event,
    List<Map<String, dynamic>> vaultSignerRows,
  ) async {
    if (event.type != 'created' || event.envelope == null) {
      throw const FormatException('Conflict creation envelope is missing.');
    }
    final envelope = Map<String, dynamic>.from(event.envelope!);
    if (!_hasExactKeys(envelope, const {
      'header',
      'nonce',
      'ciphertext',
      'signature',
    })) {
      throw const FormatException('Conflict envelope has an invalid shape.');
    }
    final rawHeader = envelope['header'];
    if (rawHeader is! Map) {
      throw const FormatException('Conflict envelope header is missing.');
    }
    final header = Map<String, dynamic>.from(rawHeader);
    const requiredHeaderKeys = {
      'wire_version',
      'server_space_id',
      'vault_id',
      'record_id',
      'revision_id',
      'base_revision_id',
      'op_id',
      'device_id',
      'device_seq',
      'key_epoch',
      'membership_version',
      'record_schema',
      'operation',
      'crypto_suite',
      'kdf_salt',
    };
    final hasExactHeader = header.containsKey('object_refs')
        ? _hasExactKeys(header, {...requiredHeaderKeys, 'object_refs'})
        : _hasExactKeys(header, requiredHeaderKeys);
    if (!hasExactHeader ||
        utf8.encode(canonicalJson(header)).length > 64 * 1024) {
      throw const FormatException(
        'Conflict envelope header has an invalid shape.',
      );
    }
    final vaultHeader = header['vault_id'];
    final recordHeader = header['record_id'];
    final revisionHeader = header['revision_id'];
    final baseHeader = header['base_revision_id'];
    final operation = header['operation'];
    final deviceId = header['device_id'];
    final epoch = header['key_epoch'];
    final membership = header['membership_version'];
    final opId = header['op_id'];
    final deviceSeq = header['device_seq'];
    if (vaultHeader != vaultId ||
        recordHeader != event.recordId ||
        !_canonicalUuid.hasMatch(vaultHeader is String ? vaultHeader : '') ||
        !_canonicalUuid.hasMatch(recordHeader is String ? recordHeader : '') ||
        revisionHeader is! String ||
        !_canonicalUuid.hasMatch(revisionHeader) ||
        (baseHeader != null &&
            (baseHeader is! String || !_canonicalUuid.hasMatch(baseHeader))) ||
        baseHeader != event.baseRevisionId ||
        deviceId is! String ||
        !_canonicalUuid.hasMatch(deviceId) ||
        epoch is! String ||
        !_canonicalDecimal.hasMatch(epoch) ||
        membership is! String ||
        !_canonicalDecimal.hasMatch(membership) ||
        opId is! String ||
        !_canonicalUuid.hasMatch(opId) ||
        deviceSeq is! String ||
        !_canonicalDecimal.hasMatch(deviceSeq) ||
        header['server_space_id'] != serverSpaceId ||
        header['wire_version'] != 1 ||
        !const {1, 2}.contains(header['record_schema']) ||
        header['crypto_suite'] != 'atermius-vault-v1' ||
        !const {'create', 'update', 'delete', 'restore'}.contains(operation) ||
        envelope['nonce'] is! String ||
        envelope['ciphertext'] is! String ||
        envelope['signature'] is! String) {
      throw const FormatException(
        'Conflict envelope header does not match event metadata.',
      );
    }
    _validateConflictEnvelopeEncoding(envelope, header);
    Uint8List? signerKey;
    for (final row in vaultSignerRows) {
      if (row['device_id'] != deviceId) continue;
      final encodedKey = row['signing_public_key'];
      if (encodedKey is! String) {
        throw const FormatException('Vault signer key is malformed.');
      }
      final candidate = decodeBase64Url(encodedKey);
      if (candidate.length != 32 || encodeBase64Url(candidate) != encodedKey) {
        throw const FormatException('Vault signer key is malformed.');
      }
      if (signerKey != null && !_sameBytes(signerKey, candidate)) {
        throw const FormatException(
          'Vault signer directory contains conflicting device keys.',
        );
      }
      signerKey = candidate;
    }
    if (signerKey == null) {
      throw const FormatException('Conflict signer is not in this Vault.');
    }
    final version = '$epoch:$membership';
    final recordKey =
        vaultKeysByVersion[version] ??
        (epoch == keyEpoch && membership == this.membershipVersion
            ? vaultKey
            : null);
    if (recordKey == null) {
      throw FormatException('Missing Vault key for conflict version $version.');
    }
    final plaintext = await crypto.decryptRecord(
      vaultKey: Uint8List.fromList(recordKey),
      envelope: envelope,
      authorPublicKey: signerKey,
    );
    final deleted = plaintext['deleted'];
    if (plaintext['id'] != event.recordId ||
        (plaintext.containsKey('deleted') && deleted is! bool) ||
        (operation == 'delete') != (deleted == true)) {
      throw const FormatException(
        'Conflict plaintext does not match the signed record context.',
      );
    }
    return _VerifiedFeedConflictBranch(header: header, plaintext: plaintext);
  }

  void _validateConflictEnvelopeEncoding(
    Map<String, dynamic> envelope,
    Map<String, dynamic> header,
  ) {
    final deviceSequence = header['device_seq'] as String;
    final keyEpoch = header['key_epoch'] as String;
    final membershipVersion = header['membership_version'] as String;
    if (!_isBoundedUnsignedDecimal(deviceSequence, maxDigits: 20) ||
        BigInt.parse(deviceSequence) > BigInt.parse('18446744073709551615') ||
        !_isBoundedUnsignedDecimal(keyEpoch, maxDigits: 19, allowZero: false) ||
        BigInt.parse(keyEpoch) > BigInt.parse('9223372036854775807') ||
        !_isBoundedUnsignedDecimal(
          membershipVersion,
          maxDigits: 19,
          allowZero: false,
        ) ||
        BigInt.parse(membershipVersion) > BigInt.parse('9223372036854775807')) {
      throw const FormatException(
        'Conflict counter is outside protocol bounds.',
      );
    }

    final nonceText = envelope['nonce'] as String;
    final ciphertextText = envelope['ciphertext'] as String;
    final signatureText = envelope['signature'] as String;
    final saltText = header['kdf_salt'];
    if (saltText is! String ||
        saltText.length != 43 ||
        nonceText.length != 32 ||
        ciphertextText.length > 1_398_102 ||
        signatureText.length != 86) {
      throw const FormatException('Conflict envelope encoding is invalid.');
    }
    final salt = decodeBase64Url(saltText);
    final nonce = decodeBase64Url(nonceText);
    final ciphertext = decodeBase64Url(ciphertextText);
    final signature = decodeBase64Url(signatureText);
    if (salt.length != 32 ||
        nonce.length != 24 ||
        ciphertext.length < 16 ||
        ciphertext.length > 1024 * 1024 ||
        signature.length != 64 ||
        encodeBase64Url(salt) != saltText ||
        encodeBase64Url(nonce) != nonceText ||
        encodeBase64Url(ciphertext) != ciphertextText ||
        encodeBase64Url(signature) != signatureText) {
      throw const FormatException('Conflict envelope encoding is invalid.');
    }

    final rawObjectRefs = header['object_refs'];
    if (header.containsKey('object_refs')) {
      if (rawObjectRefs is! List || rawObjectRefs.length > 1024) {
        throw const FormatException('Conflict object references are invalid.');
      }
      String? previous;
      for (final value in rawObjectRefs) {
        if (value is! String ||
            !_canonicalUuid.hasMatch(value) ||
            (previous != null && previous.compareTo(value) >= 0)) {
          throw const FormatException(
            'Conflict object references are invalid.',
          );
        }
        previous = value;
      }
    }
  }

  Future<void> _requireCurrentDeviceActive(
    List<Map<String, dynamic>> vaultSignerRows,
  ) async {
    final accountDevices = await api.devices();
    final activeInAccount = accountDevices.any(
      (row) =>
          row['device_id'] == identity.deviceId &&
          row['status'] == 'active' &&
          row['signing_public_key'] == identity.signingPublicKey,
    );
    final activeInVault = vaultSignerRows.any(
      (row) =>
          row['device_id'] == identity.deviceId &&
          row['status'] == 'active' &&
          row['signing_public_key'] == identity.signingPublicKey,
    );
    if (!activeInAccount || !activeInVault) {
      throw StateError('This device is not an active signer for the Vault.');
    }
  }

  Map<String, dynamic>? _safeFeedHeaderPreview(ConflictChangeEvent event) {
    final raw = event.envelope?['header'];
    if (raw is! Map) return null;
    late final Map<String, dynamic> header;
    try {
      header = Map<String, dynamic>.from(raw);
    } on Object {
      return null;
    }
    final revisionId = header['revision_id'];
    if (header['vault_id'] != vaultId ||
        header['record_id'] != event.recordId ||
        header['base_revision_id'] != event.baseRevisionId ||
        revisionId is! String ||
        !_canonicalUuid.hasMatch(revisionId)) {
      return null;
    }
    return {
      'revision_id': revisionId,
      'operation': header['operation'] is String ? header['operation'] : null,
      'key_epoch': header['key_epoch'] is String ? header['key_epoch'] : null,
      'membership_version': header['membership_version'] is String
          ? header['membership_version']
          : null,
    };
  }

  /// Allows one serialized sync pass to rewrap definitively stale operations.
  /// AppController calls this only after it has reloaded and verified the
  /// current signed membership and key envelopes.
  void authorizeStaleOutboxRewrapAfterMembershipRefresh() {
    _staleOutboxRewrapAuthorized = true;
  }

  Future<SyncResult> synchronize() => _withKeyOperation(
    () => _runSerialized(() async {
      try {
        return await _synchronizeLocked();
      } finally {
        _staleOutboxRewrapAuthorized = false;
      }
    }),
  );

  Future<SyncResult> _synchronizeLocked() async {
    var received = 0;
    try {
      // Pull-applied push proofs are needed only for a delayed response. Prune
      // expired rows here as well as when the local database opens so a long
      // running tab also keeps the durable receipt table bounded.
      await database.pruneAuthenticatedPushReceipts();
      // Capability discovery is advisory for legacy v1 sync. A network or
      // older-server failure must not block records that use schema 1; v2
      // publication is separately gated by the signed server capability.
      try {
        await publishDeviceCapabilities?.call();
      } on Object {
        // Continue with the established v1 sync path.
      }
      if (_recoveryRequests > 0) {
        await _setStatus('resnapshot_required');
        return await _result(status: 'resnapshot_required');
      }
      await refreshSignerDirectory();
      var checkpoint = await database.checkpoint(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (checkpoint?.serverGeneration != null &&
          checkpoint!.serverGeneration != serverGeneration) {
        await _setStatus('resnapshot_required');
        return SyncResult(
          pendingCount: await database.countPending(
            vaultId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
          receivedCount: 0,
          conflictCount: (await database.openConflicts(
            vaultId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          )).length,
          status: 'resnapshot_required',
        );
      }

      // Locked receiver pages contain only signature-verified opaque events.
      // Replay them through the ordinary keyed path before fetching any newer
      // page; a crash during replay leaves the page durable and idempotent.
      received += await _replayLockedSyncInboxPages();
      checkpoint = await database.checkpoint(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );

      var cursor = checkpoint?.cursor;
      var checkpointGeneration = checkpoint?.serverGeneration;
      var keepPulling = true;
      while (keepPulling) {
        final page = await api.changes(vaultId, cursor: cursor);
        if (page.serverGeneration != serverGeneration) {
          await _setStatus('resnapshot_required');
          return SyncResult(
            pendingCount: await database.countPending(
              vaultId,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
            ),
            receivedCount: received,
            conflictCount: (await database.openConflicts(
              vaultId,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
            )).length,
            status: 'resnapshot_required',
          );
        }
        await knownHostDecisionLock.run(knownHostDecisionScope, () async {
          for (final event in page.events) {
            await _processEvent(event);
            received++;
          }
        });
        // The cursor is only advanced after all events in its page were safely
        // persisted. Replaying a page after a crash is harmless.
        await beforeSaveInboundCheckpointForE2eTesting(
          expectedCursor: cursor,
          nextCursor: page.nextCursor,
          serverGeneration: serverGeneration,
          pageEventCount: page.events.length,
        );
        final checkpointAdvanced = await database.saveCheckpointIfCurrent(
          vaultId: vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          expectedCursor: cursor,
          expectedServerGeneration: checkpointGeneration,
          cursor: page.nextCursor,
          serverGeneration: serverGeneration,
        );
        if (!checkpointAdvanced) {
          final latestCheckpoint = await database.checkpoint(
            vaultId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          );
          final status = latestCheckpoint?.serverGeneration == serverGeneration
              ? 'retry_wait'
              : 'resnapshot_required';
          await _setStatus(status);
          return await _result(status: status, receivedCount: received);
        }
        cursor = page.nextCursor;
        checkpointGeneration = serverGeneration;
        keepPulling = page.hasMore;
      }

      // Keep the independent locked cursor aligned with the verified primary
      // cursor after this unlocked pull as well. The earlier replay boundary
      // aligns it before the pull; this second alignment prevents the next
      // lock from re-downloading pages fetched by this pass.
      await database.finishLockedSyncInboxReplay(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        serverGeneration: serverGeneration,
      );

      var conflictGeneration = await database.activeConflictFeedGeneration(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      var conflictPartitionId = await database.activeConflictFeedPartitionId(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      conflictPartitionId ??= _uuid.v4();
      conflictGeneration ??= serverGeneration;
      var conflictAfterSeq = (await database.conflictFeedCheckpoint(
        vaultId,
        conflictGeneration,
        partitionId: conflictPartitionId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      ))?.afterSeq;
      var restartedConflictFeed = false;
      String? expectedGenerationAfterRestart;
      var keepPullingConflicts = true;
      while (keepPullingConflicts) {
        ConflictChangesPage page;
        try {
          page = await api.conflictChanges(
            vaultId,
            afterSeq: conflictAfterSeq,
            serverGeneration: conflictAfterSeq == null
                ? null
                : conflictGeneration,
            limit: 100,
          );
        } on ApiException catch (error) {
          if (error.statusCode != 410 ||
              !const {
                'CONFLICT_FEED_GENERATION_CHANGED',
                'CONFLICT_FEED_SEQUENCE_AHEAD',
              }.contains(error.code)) {
            rethrow;
          }
          if (conflictAfterSeq == null || restartedConflictFeed) {
            rethrow;
          }
          if (error.code == 'CONFLICT_FEED_GENERATION_CHANGED') {
            final staleGeneration = error.details['server_generation'];
            final currentGeneration = error.details['current_generation'];
            if (!_hasExactKeys(error.details, const {
                  'server_generation',
                  'current_generation',
                  'recovery',
                }) ||
                staleGeneration != conflictGeneration ||
                currentGeneration is! String ||
                !_canonicalUuid.hasMatch(currentGeneration) ||
                error.details['recovery'] != 'restart_from_zero') {
              rethrow;
            }
            conflictGeneration = currentGeneration;
            expectedGenerationAfterRestart = currentGeneration;
          } else {
            if (!_hasExactKeys(error.details, const {'recovery'}) ||
                error.details['recovery'] != 'restart_from_zero') {
              rethrow;
            }
            // Server generation was checked before the ahead-cursor branch.
            // Keep old data isolated under its partition and start a new local
            // partition at sequence zero for this same server generation.
            expectedGenerationAfterRestart = conflictGeneration;
          }
          restartedConflictFeed = true;
          conflictPartitionId = _uuid.v4();
          conflictAfterSeq = null;
          continue;
        }
        if ((conflictAfterSeq != null ||
                expectedGenerationAfterRestart != null) &&
            page.serverGeneration !=
                (expectedGenerationAfterRestart ?? conflictGeneration)) {
          throw const FormatException(
            'Conflict feed generation changed without a restart response.',
          );
        }
        // The first request omits generation and cursor. Its validated page
        // selects the active generation; later pages must match it exactly.
        if (conflictAfterSeq == null) {
          conflictGeneration = page.serverGeneration;
        }
        final createdEvents = page.events.where(
          (event) => event.type == 'created',
        );
        if (createdEvents.isNotEmpty) {
          // A malformed or unauthenticated creation must not become durable
          // or advance the independent feed cursor. Validate every event in
          // the page before the single transactional page write.
          final currentVaultSigners = await api.vaultDevices(vaultId);
          for (final event in createdEvents) {
            await _verifyFeedConflictEvent(event, currentVaultSigners);
          }
        }
        final verifiedRedactions = <String, Map<String, dynamic>>{};
        for (final event in page.events.where(
          (event) => event.type == 'redacted',
        )) {
          final rawProof = event.redaction;
          if (rawProof == null) {
            throw const FormatException(
              'Redacted conflict feed event has no proof.',
            );
          }
          final proof = _verifyRecordRedactionProof(
            rawProof,
            recordId: event.recordId,
          );
          verifiedRedactions[event.seq] = proof.toJson();
        }
        await database.saveConflictChangesPage(
          page,
          partitionId: conflictPartitionId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          verifiedRedactionProofs: verifiedRedactions,
        );
        conflictAfterSeq = page.nextAfterSeq;
        expectedGenerationAfterRestart = null;
        keepPullingConflicts = page.hasMore;
      }

      if (_recoveryRequests > 0) {
        await _setStatus('resnapshot_required');
        return await _result(
          status: 'resnapshot_required',
          receivedCount: received,
        );
      }
      // A migration may ignore unrelated push failures only when this pass
      // first completed a full, generation-checked pull of the current Vault
      // and conflict feed. This monotonic marker lets the controller
      // distinguish that case from a failed/stale cached snapshot.
      verifiedServerViewRevision++;
      if (!canWrite) {
        final status = deletionPending ? 'deletion_pending' : 'read_only';
        await _setStatus(status);
        return await _result(status: status, receivedCount: received);
      }
      final conflictPublish = await _publishPendingConflicts();
      final allPushed = await _pushQueued();
      await _publishPendingConflictResolutions();
      await _publishPendingFeedConflictResolutions();
      final status = conflictPublish.allUploaded && allPushed
          ? 'idle'
          : 'retry_wait';
      await _setStatus(status);
      return await _result(status: status, receivedCount: received);
    } on ApiException catch (error) {
      if (error.code == 'VAULT_DELETION_PENDING') {
        canWrite = false;
        deletionPending = true;
        await _setStatus('deletion_pending');
        return await _result(
          status: 'deletion_pending',
          receivedCount: received,
        );
      }
      if (error.code == 'CURSOR_EXPIRED') {
        await _setStatus('resnapshot_required');
        return SyncResult(
          pendingCount: await database.countPending(
            vaultId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          ),
          receivedCount: received,
          conflictCount: (await database.openConflicts(
            vaultId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          )).length,
          status: 'resnapshot_required',
        );
      }
      if (_isServerGenerationChanged(error)) {
        await _setStatus('resnapshot_required');
        return await _result(
          status: 'resnapshot_required',
          receivedCount: received,
        );
      }
      if (error.code == 'AUTH_REQUIRED') {
        await _setStatus('auth_required');
      } else if (error.code == 'DEVICE_REVOKED' ||
          error.code == 'VAULT_ACCESS_REVOKED') {
        await _setStatus('revoked');
      } else if (error.code == 'KEY_EPOCH_OUTDATED' ||
          error.code == 'MEMBERSHIP_VERSION_CONFLICT') {
        await _setStatus('epoch_update_required');
      } else {
        await _setStatus(error.isRetryable ? 'retry_wait' : 'error');
      }
      rethrow;
    } on SyncControlPlaneRefreshRequiredException {
      await _setStatus('epoch_update_required');
      rethrow;
    } catch (_) {
      await _setStatus('retry_wait');
      rethrow;
    } finally {}
  }

  Future<int> _replayLockedSyncInboxPages() async {
    final pages = await database.readLockedSyncInboxPages(
      vaultId: vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      serverGeneration: serverGeneration,
    );
    var replayed = 0;
    for (final page in pages) {
      final decoded = jsonDecode(page.eventsJson);
      if (decoded is! List) {
        throw const FormatException('Locked sync inbox page is malformed.');
      }
      for (final rawEvent in decoded) {
        if (rawEvent is! Map || rawEvent.keys.any((key) => key is! String)) {
          throw const FormatException('Locked sync inbox event is malformed.');
        }
        await _processEvent(Map<String, dynamic>.from(rawEvent));
        replayed++;
      }
      await database.completeLockedSyncInboxPage(
        page: page,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
    }
    await database.finishLockedSyncInboxReplay(
      vaultId: vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      serverGeneration: serverGeneration,
    );
    return replayed;
  }

  /// Rebuilds the committed cache from a server snapshot after cursor expiry or
  /// a server-generation change. Verified pages are durable before the next
  /// request; only the final activation transaction replaces cache/checkpoint.
  Future<int> _pullChangesAfterSnapshotActivation(
    String expectedGeneration,
  ) async {
    final activated = await database.checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (activated == null ||
        activated.cursor == null ||
        activated.serverGeneration != expectedGeneration) {
      throw StateError(
        'Snapshot activation did not persist its expected cursor and generation.',
      );
    }
    var cursor = activated.cursor;
    var checkpointGeneration = activated.serverGeneration;
    var received = 0;
    while (true) {
      final page = await api.changes(vaultId, cursor: cursor);
      if (page.serverGeneration != expectedGeneration) {
        throw StateError(
          'Server generation changed while pulling changes after snapshot recovery.',
        );
      }
      await knownHostDecisionLock.run(knownHostDecisionScope, () async {
        for (final event in page.events) {
          await _processEvent(event);
          received++;
        }
      });
      final advanced = await database.saveCheckpointIfCurrent(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        expectedCursor: cursor,
        expectedServerGeneration: checkpointGeneration,
        cursor: page.nextCursor,
        serverGeneration: expectedGeneration,
      );
      if (!advanced) {
        throw StateError(
          'Sync checkpoint changed during post-snapshot catch-up; retry sync before pushing.',
        );
      }
      cursor = page.nextCursor;
      checkpointGeneration = expectedGeneration;
      if (!page.hasMore) return received;
    }
  }

  Future<SyncResult> recoverFromSnapshot() => _withKeyOperation(() {
    _recoveryRequests++;
    _localWritesFrozen = true;
    lastRecoveryCommitted = false;
    return _runSerialized(() async {
      var committed = false;
      try {
        await _waitForLocalWriters();
        await _setStatus('snapshot_recovering');

        final before = await api.fetchInstance();
        _checkInstance(before);
        final scope = _snapshotRecoveryScope(before.generation);
        SnapshotRecoveryStage? stage = await database
            .resumableSnapshotRecoveryStage(scope, now: DateTime.now());
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            if (stage == null) {
              stage = await _createSnapshotRecoveryStage(scope);
              await database.flushCommittedWrites();
            }
            final activeStage = stage;
            await refreshSignerDirectory();
            if (activeStage.pageCount > 0) {
              await _verifyPersistedSnapshotStage(activeStage);
            }
            stage = await _readAndStageSnapshotPages(activeStage);
            break;
          } on ApiException catch (error) {
            if (error.code != 'SNAPSHOT_EXPIRED' || attempt != 0) rethrow;
            final expiredStage = stage;
            if (expiredStage != null) {
              await database.discardSnapshotRecoveryStage(
                scope,
                expiredStage.snapshotId,
              );
              await database.flushCommittedWrites();
            }
            stage = null;
          }
        }
        final completedStage = stage;
        if (completedStage == null || !completedStage.complete) {
          throw const FormatException(
            'No complete verified snapshot stage was available.',
          );
        }
        final after = await api.fetchInstance();
        _checkInstance(after);
        if (after.generation != before.generation) {
          throw StateError(
            'Server generation changed during snapshot recovery; retry with a fresh snapshot.',
          );
        }
        await knownHostDecisionLock.run(
          knownHostDecisionScope,
          () => database.applyStagedVaultSnapshot(
            scope: scope,
            snapshotId: completedStage.snapshotId,
          ),
        );
        // IndexedDB VFS may finish its physical writes after SQL COMMIT returns.
        // Do not report a successful recovery until the activated cache,
        // checkpoint, outbox reconciliation, and stage cleanup are durable.
        await database.flushCommittedWrites();
        serverGeneration = after.generation;
        final receivedCount = completedStage.verifiedItemCount;
        committed = true;
        lastRecoveryCommitted = true;

        // A purge may commit after snapshot creation but before activation.
        // Pull from the activated watermark and durably apply every event
        // before any queued operation can be sent back to the server.
        await _pullChangesAfterSnapshotActivation(after.generation);
        await database.flushCommittedWrites();

        // Snapshot plus its post-watermark change tail is now durable. Only
        // now perform write-side network work.
        var status = 'idle';
        if (!canWrite) {
          status = deletionPending ? 'deletion_pending' : 'read_only';
        } else {
          final conflictPublish = await _publishPendingConflicts();
          status = conflictPublish.allUploaded ? 'idle' : 'retry_wait';
          final allPushed = await _pushQueued(allowSnapshotRecovery: true);
          if (!allPushed) status = 'retry_wait';
          await _publishPendingConflictResolutions();
          await _publishPendingFeedConflictResolutions();
        }
        await _setStatus(status);
        return await _result(
          status: status,
          receivedCount: receivedCount,
          serverGeneration: serverGeneration,
        );
      } on SnapshotBootstrapLimitException {
        if (!committed) await _setStatus('snapshot_too_large');
        rethrow;
      } on ApiException catch (error) {
        if (error.code == 'VAULT_DELETION_PENDING') {
          canWrite = false;
          deletionPending = true;
          await _setStatus('deletion_pending');
          if (committed) {
            return await _result(
              status: 'deletion_pending',
              receivedCount: (await database.cachedEnvelopes(
                vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
              )).length,
              serverGeneration: serverGeneration,
            );
          }
        }
        if (_isServerGenerationChanged(error)) {
          await _setStatus('resnapshot_required');
          if (committed) {
            return await _result(
              status: 'resnapshot_required',
              receivedCount: (await database.cachedEnvelopes(
                vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
              )).length,
            );
          }
          rethrow;
        }
        if (!committed) {
          await _setStatus('resnapshot_required');
          rethrow;
        }
        await _setStatus(
          error.isRetryable ? 'retry_wait' : error.code.toLowerCase(),
        );
        rethrow;
      } catch (_) {
        if (!committed) {
          // Until final activation commits, the original cache and checkpoint
          // remain unchanged and pending local operations stay actionable.
          await _setStatus('resnapshot_required');
          rethrow;
        }
        await _setStatus('retry_wait');
        rethrow;
      } finally {
        _recoveryRequests--;
        _localWritesFrozen = _recoveryRequests > 0;
        _staleOutboxRewrapAuthorized = false;
      }
    });
  });

  SnapshotRecoveryScope _snapshotRecoveryScope(String generation) {
    final authenticatedAccountId = accountId;
    if (authenticatedAccountId == null || authenticatedAccountId.isEmpty) {
      throw StateError(
        'Snapshot recovery requires an authenticated account scope.',
      );
    }
    return SnapshotRecoveryScope(
      serverNamespace: api.baseUrl,
      accountId: authenticatedAccountId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      vaultId: vaultId,
      serverGeneration: generation,
    );
  }

  Future<SnapshotRecoveryStage> _createSnapshotRecoveryStage(
    SnapshotRecoveryScope scope,
  ) async {
    final created = await api.createSnapshot(vaultId);
    final snapshotId = created['snapshot_id'];
    final highWatermark = created['high_watermark'];
    final conflictHighWatermark = created['conflict_high_watermark'];
    final checkpointCursor = created['next_cursor'];
    final expiresAt = created['expires_at'];
    final itemCountPresent = created.containsKey('item_count');
    final itemCount = created['item_count'];
    final parsedExpiration = expiresAt is String
        ? DateTime.tryParse(expiresAt)
        : null;
    if (snapshotId is! String ||
        !_canonicalUuid.hasMatch(snapshotId) ||
        highWatermark is! String ||
        !_isDecimal(highWatermark) ||
        conflictHighWatermark is! String ||
        !_isDecimal(conflictHighWatermark) ||
        checkpointCursor is! String ||
        checkpointCursor.trim().isEmpty ||
        checkpointCursor.length > 2048 ||
        expiresAt is! String ||
        parsedExpiration == null ||
        (itemCountPresent && (itemCount is! int || itemCount < 0))) {
      throw const FormatException('Snapshot creation response is incomplete.');
    }
    if (parsedExpiration.toUtc().isBefore(DateTime.now().toUtc())) {
      throw ApiException(
        statusCode: 410,
        code: 'SNAPSHOT_EXPIRED',
        message: currentL10n.snapshotExpiredBeforeRecoveryCouldStart,
      );
    }
    if (itemCount is int && itemCount > _maxSnapshotManifestHeads) {
      throw const SnapshotBootstrapLimitException();
    }
    await database.beginSnapshotRecoveryStage(
      scope: scope,
      snapshotId: snapshotId,
      highWatermark: highWatermark,
      conflictHighWatermark: conflictHighWatermark,
      checkpointCursor: checkpointCursor,
      expiresAt: expiresAt,
      itemCountPresent: itemCountPresent,
      expectedItemCount: itemCount is int ? itemCount : null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final stage = await database.resumableSnapshotRecoveryStage(
      scope,
      now: DateTime.now(),
    );
    if (stage == null || stage.snapshotId != snapshotId) {
      throw const FormatException('Snapshot stage was not persisted.');
    }
    return stage;
  }

  Future<SnapshotRecoveryStage> _readAndStageSnapshotPages(
    SnapshotRecoveryStage initial,
  ) async {
    var stage = initial;
    while (!stage.complete) {
      final requestedCursor = stage.nextPageCursor;
      final page = await api.snapshot(
        stage.snapshotId,
        limit: _snapshotPageLimit,
        pageCursor: requestedCursor,
      );
      final manifest = page['manifest'];
      final hasMoreFieldPresent = page.containsKey('has_more');
      final nextPageCursorFieldPresent = page.containsKey('next_page_cursor');
      final legacyFullManifest =
          !hasMoreFieldPresent && !nextPageCursorFieldPresent;
      final pageItemCountPresent = page.containsKey('item_count');
      final pageItemCount = page['item_count'];
      final pageGeneration = page['server_generation'];
      if (page['snapshot_id'] != stage.snapshotId ||
          page['high_watermark'] != stage.highWatermark ||
          page['conflict_high_watermark'] != stage.conflictHighWatermark ||
          page['next_cursor'] != stage.checkpointCursor ||
          page['expires_at'] != stage.expiresAt ||
          manifest is! List ||
          (hasMoreFieldPresent != nextPageCursorFieldPresent) ||
          (!legacyFullManifest && page['has_more'] is! bool) ||
          (legacyFullManifest &&
              (requestedCursor != null || stage.pageCount > 0)) ||
          (pageGeneration != null &&
              pageGeneration != stage.scope.serverGeneration)) {
        throw const FormatException(
          'Snapshot page metadata does not match its fixed snapshot boundary.',
        );
      }
      if (page['high_watermark'] is! String ||
          !_isDecimal(page['high_watermark'] as String) ||
          page['conflict_high_watermark'] is! String ||
          !_isDecimal(page['conflict_high_watermark'] as String)) {
        throw const FormatException('Snapshot page watermark is invalid.');
      }
      if (pageItemCountPresent &&
          (pageItemCount is! int || pageItemCount < 0)) {
        throw const FormatException('Snapshot item_count is invalid.');
      }
      final hasMore = legacyFullManifest ? false : page['has_more'] as bool;
      final rawNextCursor = legacyFullManifest
          ? null
          : page['next_page_cursor'];
      if ((!legacyFullManifest &&
              (rawNextCursor != null && rawNextCursor is! String)) ||
          (requestedCursor != null && manifest.isEmpty) ||
          (hasMore && manifest.isEmpty)) {
        throw const FormatException(
          'Snapshot pagination returned an empty or malformed continuation.',
        );
      }
      if (legacyFullManifest) {
        if (manifest.length > _maxSnapshotManifestHeads) {
          throw const SnapshotBootstrapLimitException();
        }
        if (manifest.isEmpty) {
          stage = await _verifyAndPersistSnapshotChunk(
            stage: stage,
            requestedCursor: null,
            rawHeads: const [],
            pageItemCountPresent: pageItemCountPresent,
            pageItemCount: pageItemCount as int?,
            legacyFullManifest: true,
            hasMore: false,
            nextPageCursor: null,
          );
          continue;
        }
        for (
          var offset = 0;
          offset < manifest.length;
          offset += _snapshotPageLimit
        ) {
          final end = (offset + _snapshotPageLimit).clamp(0, manifest.length);
          final isFinalChunk = end == manifest.length;
          stage = await _verifyAndPersistSnapshotChunk(
            stage: stage,
            requestedCursor: null,
            rawHeads: manifest.sublist(offset, end),
            pageItemCountPresent: pageItemCountPresent,
            pageItemCount: pageItemCount as int?,
            legacyFullManifest: true,
            hasMore: !isFinalChunk,
            nextPageCursor: null,
          );
        }
        continue;
      }
      if (manifest.length > _snapshotPageLimit) {
        throw const FormatException(
          'Snapshot manifest exceeds the client entry limit.',
        );
      }
      stage = await _verifyAndPersistSnapshotChunk(
        stage: stage,
        requestedCursor: requestedCursor,
        rawHeads: manifest,
        pageItemCountPresent: pageItemCountPresent,
        pageItemCount: pageItemCount as int?,
        legacyFullManifest: false,
        hasMore: hasMore,
        nextPageCursor: rawNextCursor as String?,
      );
    }
    return stage;
  }

  Future<SnapshotRecoveryStage> _verifyAndPersistSnapshotChunk({
    required SnapshotRecoveryStage stage,
    required String? requestedCursor,
    required List<dynamic> rawHeads,
    required bool pageItemCountPresent,
    required int? pageItemCount,
    required bool legacyFullManifest,
    required bool hasMore,
    required String? nextPageCursor,
  }) async {
    final verified = await _verifySnapshotHeads(
      rawHeads,
      highWatermark: stage.highWatermark,
    );
    var serializedHeadBytes = 0;
    for (final rawHead in rawHeads) {
      serializedHeadBytes += utf8.encode(jsonEncode(rawHead)).length;
    }
    final saved = await database.persistSnapshotRecoveryPage(
      scope: stage.scope,
      snapshotId: stage.snapshotId,
      highWatermark: stage.highWatermark,
      conflictHighWatermark: stage.conflictHighWatermark,
      checkpointCursor: stage.checkpointCursor,
      expiresAt: stage.expiresAt,
      requestedPageCursor: requestedCursor,
      heads: verified,
      serializedHeadBytes: serializedHeadBytes,
      pageItemCountPresent: pageItemCountPresent,
      pageItemCount: pageItemCount,
      legacyFullManifest: legacyFullManifest,
      hasMore: hasMore,
      nextPageCursor: nextPageCursor,
    );
    await database.flushCommittedWrites();
    return saved;
  }

  Future<void> _verifyPersistedSnapshotStage(
    SnapshotRecoveryStage stage,
  ) async {
    var afterOrdinal = -1;
    String? lastRecordId;
    var verifiedCount = 0;
    while (true) {
      final rows = await database.snapshotRecoveryStagedHeads(
        scope: stage.scope,
        snapshotId: stage.snapshotId,
        afterOrdinal: afterOrdinal,
        limit: _snapshotPageLimit,
      );
      if (rows.isEmpty) break;
      final rawHeads = <dynamic>[];
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        if (row.ordinal != afterOrdinal + index + 1 ||
            (lastRecordId != null &&
                row.recordId.compareTo(lastRecordId) <= 0)) {
          throw const FormatException(
            'Persisted snapshot staging order is invalid.',
          );
        }
        if (row.redactionJson != null) {
          final rawProof = jsonDecode(row.redactionJson!);
          if (rawProof is! Map || rawProof.keys.any((key) => key is! String)) {
            throw const FormatException(
              'Persisted snapshot redaction proof is malformed.',
            );
          }
          rawHeads.add({
            'kind': 'graveyard',
            'record_id': row.recordId,
            'deleted_revision_id': row.revisionId,
            'deleted_seq': row.commitSeq,
            'redaction': Map<String, dynamic>.from(rawProof),
          });
        } else {
          final envelope = jsonDecode(row.envelopeJson);
          if (envelope is! Map) {
            throw const FormatException(
              'Persisted snapshot envelope is malformed.',
            );
          }
          rawHeads.add({
            'record_id': row.recordId,
            'revision_id': row.revisionId,
            'deleted': row.deleted,
            if (row.commitSeq != null) 'commit_seq': row.commitSeq,
            'envelope': Map<String, dynamic>.from(envelope),
          });
        }
        lastRecordId = row.recordId;
      }
      final verified = await _verifySnapshotHeads(
        rawHeads,
        highWatermark: stage.highWatermark,
      );
      for (var index = 0; index < rows.length; index++) {
        if (verified[index].recordId != rows[index].recordId ||
            verified[index].revisionId != rows[index].revisionId ||
            verified[index].deleted != rows[index].deleted ||
            verified[index].commitSeq != rows[index].commitSeq ||
            verified[index].isGraveyard !=
                (rows[index].redactionJson != null) ||
            (rows[index].redactionJson != null &&
                canonicalJson(verified[index].redactionProof) !=
                    canonicalJson(jsonDecode(rows[index].redactionJson!)))) {
          throw const FormatException(
            'Persisted snapshot metadata does not match its signed envelope.',
          );
        }
      }
      verifiedCount += rows.length;
      afterOrdinal = rows.last.ordinal;
    }
    if (verifiedCount != stage.verifiedItemCount ||
        lastRecordId != stage.lastRecordId ||
        (stage.expectedItemCount != null &&
            (stage.expectedItemCount! < verifiedCount ||
                (stage.complete &&
                    stage.expectedItemCount != verifiedCount)))) {
      throw const FormatException(
        'Persisted snapshot staging count does not match its manifest.',
      );
    }
  }

  Future<List<SnapshotHead>> _verifySnapshotHeads(
    List<dynamic> manifest, {
    required String highWatermark,
  }) async {
    if (!_canonicalDecimal.hasMatch(highWatermark)) {
      throw const FormatException(
        'Snapshot high-watermark is not a canonical decimal string.',
      );
    }
    final high = BigInt.parse(highWatermark);
    final seen = <String>{};
    final staged = <SnapshotHead>[];
    for (final raw in manifest) {
      if (raw is! Map) {
        throw const FormatException('Snapshot contains a malformed head.');
      }
      final item = Map<String, dynamic>.from(raw);
      final kind = item['kind'];
      if (kind == 'graveyard') {
        if (!_hasExactKeys(item, const {
          'kind',
          'record_id',
          'deleted_revision_id',
          'deleted_seq',
          'redaction',
        })) {
          throw const FormatException('Snapshot graveyard item is malformed.');
        }
        final recordId = item['record_id'];
        final deletedRevisionId = item['deleted_revision_id'];
        final deletedSeq = item['deleted_seq'];
        final rawProof = item['redaction'];
        if (recordId is! String ||
            !_canonicalUuid.hasMatch(recordId) ||
            deletedRevisionId is! String ||
            !_canonicalUuid.hasMatch(deletedRevisionId) ||
            deletedSeq is! String ||
            !_canonicalPositiveDecimal.hasMatch(deletedSeq) ||
            rawProof is! Map ||
            rawProof.keys.any((key) => key is! String) ||
            BigInt.parse(deletedSeq) > high) {
          throw const FormatException('Snapshot graveyard item is invalid.');
        }
        if (!seen.add(recordId)) {
          throw FormatException(
            'Snapshot contains duplicate record $recordId.',
          );
        }
        final proof = _verifyRecordRedactionProof(
          Map<String, dynamic>.from(rawProof),
          recordId: recordId,
        );
        if (proof.deletedRevisionId != deletedRevisionId ||
            proof.deletedSeq != deletedSeq ||
            BigInt.parse(proof.redactionSeq) > high) {
          throw const FormatException(
            'Snapshot graveyard does not match its signed redaction proof.',
          );
        }
        staged.add(
          SnapshotHead(
            recordId: recordId,
            revisionId: deletedRevisionId,
            deleted: true,
            envelope: const {},
            commitSeq: deletedSeq,
            redactionProof: proof.toJson(),
          ),
        );
        continue;
      }
      if (kind != null && kind != 'head') {
        throw const FormatException('Snapshot item kind is unsupported.');
      }
      if (kind == 'head' &&
          !_hasExactKeys(item, const {
            'kind',
            'record_id',
            'revision_id',
            'commit_seq',
            'deleted',
            'envelope',
          })) {
        throw const FormatException('Snapshot head item is malformed.');
      }
      item.remove('kind');
      final recordId = item['record_id'];
      final revisionId = item['revision_id'];
      final deleted = item['deleted'];
      final rawEnvelope = item['envelope'];
      String? commitSeq;
      if (item.containsKey('commit_seq')) {
        final rawCommitSeq = item['commit_seq'];
        if (rawCommitSeq is! String ||
            !_canonicalPositiveDecimal.hasMatch(rawCommitSeq)) {
          throw const FormatException(
            'Snapshot head commit_seq is not a canonical decimal string.',
          );
        }
        if (BigInt.parse(rawCommitSeq) > high) {
          throw const FormatException(
            'Snapshot head commit_seq exceeds the fixed high-watermark.',
          );
        }
        commitSeq = rawCommitSeq;
      }
      if (recordId is! String ||
          !_canonicalUuid.hasMatch(recordId) ||
          revisionId is! String ||
          revisionId.isEmpty ||
          deleted is! bool ||
          rawEnvelope is! Map) {
        throw const FormatException(
          'Snapshot head is missing required fields.',
        );
      }
      if (!seen.add(recordId)) {
        throw FormatException('Snapshot contains duplicate record $recordId.');
      }
      final envelope = Map<String, dynamic>.from(rawEnvelope);
      final rawHeader = envelope['header'];
      if (rawHeader is! Map) {
        throw const FormatException('Snapshot record has no signed header.');
      }
      final header = Map<String, dynamic>.from(rawHeader);
      final operation = header['operation'];
      if (header['vault_id'] != vaultId ||
          header['server_space_id'] != serverSpaceId ||
          header['record_id'] != recordId ||
          header['revision_id'] != revisionId ||
          header['op_id'] is! String ||
          header['device_id'] is! String ||
          !const {
            'create',
            'update',
            'delete',
            'restore',
          }.contains(operation) ||
          (operation == 'delete') != deleted) {
        throw const FormatException(
          'Snapshot metadata does not match its signed record header.',
        );
      }
      final signer = _signers[header['device_id'] as String];
      if (signer == null) {
        throw FormatException(
          'Snapshot head $recordId has an unknown signer; the old cache was preserved.',
        );
      }
      final epoch = header['key_epoch']?.toString();
      final membership = header['membership_version']?.toString();
      if (epoch == null || membership == null) {
        throw const FormatException(
          'Snapshot record has no key-version context.',
        );
      }
      final key =
          vaultKeysByVersion['$epoch:$membership'] ??
          (epoch == keyEpoch && membership == membershipVersion
              ? vaultKey
              : null);
      if (key == null) {
        throw FormatException(
          'Snapshot head $recordId requires unavailable vault key epoch $epoch / membership $membership.',
        );
      }
      final plaintext = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(key),
        envelope: envelope,
        authorPublicKey: Uint8List.fromList(signer),
      );
      if ((plaintext['deleted'] == true) != deleted) {
        throw const FormatException(
          'Snapshot tombstone metadata does not match encrypted plaintext.',
        );
      }
      staged.add(
        SnapshotHead(
          recordId: recordId,
          revisionId: revisionId,
          deleted: deleted,
          envelope: envelope,
          commitSeq: commitSeq,
        ),
      );
    }
    return staged;
  }

  Future<_ConflictPublishResult> _publishPendingConflicts() async {
    final ids = <String, String>{};
    final pending = await database.pendingConflictUploads(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final conflict in pending) {
      final envelope =
          jsonDecode(conflict.branchEnvelopeJson) as Map<String, dynamic>;
      final response = await api.uploadConflict(vaultId, {
        'envelope': envelope,
      });
      final serverId = response['conflict_id'] as String?;
      if (serverId == null || serverId.isEmpty) {
        throw const FormatException(
          'Conflict upload response is missing conflict_id.',
        );
      }
      await database.markSnapshotConflictUploaded(
        localConflictId: conflict.conflictId,
        serverConflictId: serverId,
      );
      ids[conflict.conflictId] = serverId;
    }
    return _ConflictPublishResult(allUploaded: true, ids: ids);
  }

  Future<void> _publishPendingConflictResolutions() async {
    final pending = await database.pendingConflictResolutions(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final conflict in pending) {
      final opId = conflict.resolutionOpId;
      final revisionId = conflict.resolutionRevisionId;
      if (opId == null ||
          opId.isEmpty ||
          revisionId == null ||
          revisionId.isEmpty) {
        throw const FormatException(
          'Conflict resolution is missing its durable operation association.',
        );
      }
      await api.resolveConflict(vaultId, conflict.conflictId, {
        'op_id': opId,
        'resolved_revision_id': revisionId,
      });
      await database.markConflictResolutionCompleted(
        conflictId: conflict.conflictId,
        opId: opId,
        revisionId: revisionId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
    }
  }

  Future<void> _publishPendingFeedConflictResolutions() async {
    final pending = await database.pendingFeedConflictResolutions(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    for (final target in pending) {
      try {
        final response = await api.resolveConflict(vaultId, target.conflictId, {
          'resolved_revision_id': target.resolutionRevisionId,
        });
        final resolutionSeq = response['resolution_seq'];
        if (response['status'] != 'resolved' ||
            response['resolved_revision_id'] != target.resolutionRevisionId ||
            resolutionSeq is! String ||
            !_canonicalDecimal.hasMatch(resolutionSeq)) {
          throw const FormatException(
            'Conflict resolution response does not match its durable target.',
          );
        }
        await database.markFeedConflictResolved(
          conflictId: target.conflictId,
          resolutionRevisionId: target.resolutionRevisionId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
      } on ApiException catch (error) {
        if (error.code != 'REVISION_CONFLICT') rethrow;
        // The chosen revision is already committed. Never create a replacement
        // operation here; pull the latest head and ask the user to choose again.
        await database.markFeedResolutionNeedsReview(
          conflictId: target.conflictId,
          resolutionRevisionId: target.resolutionRevisionId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        await _pullMainChangesAfterCas();
      }
    }
  }

  Future<void> _pullMainChangesAfterCas() async {
    final initialCheckpoint = await database.checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    var cursor = initialCheckpoint?.cursor;
    var checkpointGeneration = initialCheckpoint?.serverGeneration;
    var keepPulling = true;
    while (keepPulling) {
      final page = await api.changes(vaultId, cursor: cursor);
      if (page.serverGeneration != serverGeneration) {
        throw const FormatException(
          'Main sync generation changed while refreshing a CAS conflict.',
        );
      }
      await knownHostDecisionLock.run(knownHostDecisionScope, () async {
        for (final event in page.events) {
          await _processEvent(event);
        }
      });
      final checkpointAdvanced = await database.saveCheckpointIfCurrent(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        expectedCursor: cursor,
        expectedServerGeneration: checkpointGeneration,
        cursor: page.nextCursor,
        serverGeneration: serverGeneration,
      );
      if (!checkpointAdvanced) {
        throw StateError('Another sync pass changed the current cursor.');
      }
      cursor = page.nextCursor;
      checkpointGeneration = serverGeneration;
      keepPulling = page.hasMore;
    }
  }

  Future<T> _runSerialized<T>(Future<T> Function() task) {
    final previous = _serialTail;
    final release = Completer<void>();
    _serialTail = release.future;
    return previous.then((_) async {
      try {
        return await task();
      } finally {
        release.complete();
      }
    });
  }

  Future<SyncResult> _result({
    required String status,
    int receivedCount = 0,
    String? serverGeneration,
  }) async => SyncResult(
    pendingCount: await database.countPending(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    ),
    receivedCount: receivedCount,
    conflictCount: (await database.openConflicts(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    )).length,
    status: status,
    serverGeneration: serverGeneration,
  );

  void _checkInstance(InstanceInfo info) {
    if (info.instanceId != instanceId || info.serverSpaceId != serverSpaceId) {
      throw StateError(
        'Configured instance identity changed; refusing snapshot recovery.',
      );
    }
  }

  static bool _isDecimal(String value) =>
      RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value);

  void _beginLocalWrite() {
    if (_localWritesFrozen || _recoveryRequests > 0) {
      throw StateError(
        'Vault edits are temporarily paused during snapshot recovery.',
      );
    }
    _activeLocalWriters++;
  }

  void _endLocalWrite() {
    _activeLocalWriters--;
    if (_activeLocalWriters == 0) {
      final drained = _localWritersDrained;
      _localWritersDrained = null;
      if (drained != null && !drained.isCompleted) drained.complete();
    }
  }

  Future<void> _waitForLocalWriters() async {
    if (_activeLocalWriters == 0) return;
    _localWritersDrained ??= Completer<void>();
    await _localWritersDrained!.future;
  }

  RecordRedactionProof _verifyRecordRedactionProof(
    Map<String, dynamic> rawProof, {
    required String recordId,
  }) {
    final signingKey = trustedInstanceSigningPublicKey;
    if (signingKey == null || signingKey.isEmpty) {
      throw const FormatException(
        'Record redaction proof cannot be checked without the pinned instance key.',
      );
    }
    return RecordRedactionProof.verify(
      rawProof,
      crypto: crypto,
      expectedInstanceId: instanceId,
      expectedServerSpaceId: serverSpaceId,
      expectedVaultId: vaultId,
      expectedRecordId: recordId,
      currentPinnedSigningPublicKey: signingKey,
    );
  }

  Future<void> _applyRecordRedactionFromApiError(
    ApiException error, {
    required String expectedRecordId,
  }) async {
    if (error.statusCode != 410 || error.code != 'RECORD_REDACTED') {
      throw error;
    }
    final rawProof = error.details['redaction'];
    if (rawProof is! Map || rawProof.keys.any((key) => key is! String)) {
      throw const FormatException(
        'RECORD_REDACTED response did not include a verifiable proof.',
      );
    }
    final proof = _verifyRecordRedactionProof(
      Map<String, dynamic>.from(rawProof),
      recordId: expectedRecordId,
    );
    await database.applyRecordRedaction(
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      vaultId: vaultId,
      serverGeneration: serverGeneration,
      proof: proof.toJson(),
    );
  }

  Future<void> _processEvent(Map<String, dynamic> event) async {
    if (event['event_type'] == 'record_redacted') {
      if (!_hasExactKeys(event, const {
        'commit_seq',
        'event_type',
        'record_id',
        'redaction',
      })) {
        throw const FormatException(
          'Redacted change event fields are invalid.',
        );
      }
      final commitSeq = event['commit_seq'];
      final recordId = event['record_id'];
      final rawProof = event['redaction'];
      if (commitSeq is! String ||
          !_isI64Decimal(commitSeq) ||
          commitSeq == '0' ||
          recordId is! String ||
          !_canonicalUuid.hasMatch(recordId) ||
          rawProof is! Map ||
          rawProof.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Redacted change event metadata is invalid.',
        );
      }
      final proof = _verifyRecordRedactionProof(
        Map<String, dynamic>.from(rawProof),
        recordId: recordId,
      );
      if (_compareDecimalSeq(commitSeq, proof.redactionSeq) > 0) {
        throw const FormatException(
          'Redacted change event is newer than its signed proof.',
        );
      }
      await database.applyRecordRedaction(
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        serverGeneration: serverGeneration,
        proof: proof.toJson(),
      );
      return;
    }
    if (!_hasExactKeys(event, const {
      'commit_seq',
      'event_type',
      'record_id',
      'revision_id',
      'envelope',
    })) {
      throw const FormatException('Change event fields are invalid');
    }
    final commitSeq = event['commit_seq'];
    final eventType = event['event_type'];
    final eventRecordId = event['record_id'];
    final eventRevisionId = event['revision_id'];
    if (commitSeq is! String ||
        !_isI64Decimal(commitSeq) ||
        commitSeq == '0' ||
        eventType is! String ||
        !const {'create', 'update', 'delete', 'restore'}.contains(eventType) ||
        eventRecordId is! String ||
        !_canonicalUuid.hasMatch(eventRecordId) ||
        eventRevisionId is! String ||
        !_canonicalUuid.hasMatch(eventRevisionId)) {
      throw const FormatException('Change event metadata is invalid');
    }
    final rawEnvelope = event['envelope'];
    if (rawEnvelope is! Map) {
      throw const FormatException('Change event has no envelope');
    }
    final envelope = Map<String, dynamic>.from(rawEnvelope);
    final header = crypto.validateRecordEnvelope(envelope);
    final recordId = header['record_id'] as String;
    final revisionId = header['revision_id'] as String;
    final opId = header['op_id'] as String;
    if (recordId != eventRecordId ||
        revisionId != eventRevisionId ||
        header['operation'] != eventType ||
        header['vault_id'] != vaultId ||
        header['server_space_id'] != serverSpaceId) {
      throw const FormatException(
        'Change event metadata does not match its signed envelope',
      );
    }
    final signerId = header['device_id'] as String;
    final signer = _signers[signerId];
    if (signer == null) {
      throw const SyncControlPlaneRefreshRequiredException(
        SyncControlPlaneRefreshReason.missingEventSigner,
      );
    }
    final epoch = header['key_epoch'] as String;
    final membershipVersion = header['membership_version'] as String;
    final versionKey = '$epoch:$membershipVersion';
    final key =
        vaultKeysByVersion[versionKey] ??
        (epoch == keyEpoch && membershipVersion == this.membershipVersion
            ? vaultKey
            : null);
    if (key == null) {
      // A known signer must authenticate the exact ciphertext before a
      // missing epoch key is treated as a recoverable freshness hint.
      crypto.verifyRecordSignature(
        envelope: envelope,
        authorPublicKey: Uint8List.fromList(signer),
      );
      throw const SyncControlPlaneRefreshRequiredException(
        SyncControlPlaneRefreshReason.missingVaultKey,
      );
    }
    await crypto.decryptRecord(
      vaultKey: Uint8List.fromList(key),
      envelope: envelope,
      authorPublicKey: Uint8List.fromList(signer),
    );
    var mergeRaceRetries = 0;
    while (true) {
      final operation = await database.queuedOperations(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final recordOperations = operation
          .where((item) => item.recordId == recordId)
          .toList(growable: false);
      final localPending = recordOperations.firstOrNull;

      if (localPending != null) {
        final localEnvelope =
            jsonDecode(localPending.envelopeJson) as Map<String, dynamic>;
        final localHeader = localEnvelope['header'] as Map<String, dynamic>;
        if (localHeader['op_id'] == opId) {
          if (localHeader['revision_id'] != revisionId ||
              canonicalJson(localEnvelope) != canonicalJson(envelope)) {
            await _recordConflict(
              localOperations: recordOperations,
              local: recordOperations.last,
              remoteEnvelope: envelope,
              kind: 'id_reuse',
              remoteCommitSeq: commitSeq,
            );
            return;
          }
          await database.markCommitted(
            opId: opId,
            commitSeq: commitSeq,
            authenticatedEventEnvelope: envelope,
          );
          return;
        }
        if (localPending.baseRevisionId == revisionId) {
          // This is the base revision the local edit was made from. Keep the
          // encrypted local working copy; it will be pushed after this pull.
          return;
        }
        final mergeAttempt = await _tryAutoMergeConcurrentUpdate(
          localOperations: recordOperations,
          remoteEnvelope: envelope,
        );
        if (mergeAttempt == _AutoMergeAttempt.merged) return;
        if (mergeAttempt == _AutoMergeAttempt.retry && mergeRaceRetries++ < 3) {
          // Another tab edited the same cached head while the merge was being
          // prepared. Reread the entire outbox chain and try against that
          // latest local intent before falling back to a visible conflict.
          continue;
        }
        await _recordConflict(
          localOperations: recordOperations,
          local: recordOperations.last,
          remoteEnvelope: envelope,
          kind: header['operation'] == 'delete'
              ? 'delete_edit'
              : 'concurrent_edit',
          remoteCommitSeq: commitSeq,
        );
        return;
      }

      await beforeStorePulledEventForE2eTesting(
        recordId: recordId,
        revisionId: revisionId,
        commitSeq: commitSeq,
        observedPendingOperationCount: recordOperations.length,
      );
      await beforeStorePulledEventForTesting?.call();
      final stored = await database.storeRemoteEnvelopeIfNoPendingOperation(
        vaultId: vaultId,
        recordId: recordId,
        revisionId: revisionId,
        envelope: envelope,
        commitSeq: commitSeq,
        deleted: header['operation'] == 'delete',
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (stored) return;
      // A local save won the race after the outbox read above. Re-read and
      // feed the signed remote event through the normal base/conflict logic.
    }
  }

  Future<_AutoMergeAttempt> _tryAutoMergeConcurrentUpdate({
    required List<PendingOperation> localOperations,
    required Map<String, dynamic> remoteEnvelope,
  }) async {
    if (!canWrite || deletionPending || localOperations.isEmpty) {
      return _AutoMergeAttempt.notEligible;
    }
    final remoteHeader = Map<String, dynamic>.from(
      remoteEnvelope['header'] as Map,
    );
    final remoteRevisionId = remoteHeader['revision_id'];
    final sharedBaseRevisionId = remoteHeader['base_revision_id'];
    if (remoteHeader['operation'] != 'update' ||
        remoteRevisionId is! String ||
        sharedBaseRevisionId is! String ||
        remoteHeader['key_epoch'] != keyEpoch ||
        remoteHeader['membership_version'] != membershipVersion) {
      return _AutoMergeAttempt.notEligible;
    }
    final orderedOperations = _orderOutboxChain(
      localOperations,
      sharedBaseRevisionId,
    );
    if (orderedOperations == null) return _AutoMergeAttempt.notEligible;
    final first = orderedOperations.first;
    if (first.baseRevisionId != sharedBaseRevisionId ||
        first.baseEnvelopeJson == null ||
        orderedOperations.any(
          (operation) =>
              operation.status != 'queued' && operation.status != 'sent',
        )) {
      return _AutoMergeAttempt.notEligible;
    }

    late final Map<String, dynamic> baseEnvelope;
    try {
      final decoded = jsonDecode(first.baseEnvelopeJson!);
      if (decoded is! Map || decoded['header'] is! Map) {
        return _AutoMergeAttempt.notEligible;
      }
      baseEnvelope = Map<String, dynamic>.from(decoded);
      final baseHeader = Map<String, dynamic>.from(
        baseEnvelope['header'] as Map,
      );
      if (baseHeader['vault_id'] != vaultId ||
          baseHeader['record_id'] != first.recordId ||
          baseHeader['revision_id'] != sharedBaseRevisionId ||
          remoteHeader['vault_id'] != vaultId ||
          remoteHeader['record_id'] != first.recordId) {
        return _AutoMergeAttempt.notEligible;
      }
      for (var index = 0; index < orderedOperations.length; index++) {
        final operation = orderedOperations[index];
        final localEnvelope =
            jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
        final localHeader = Map<String, dynamic>.from(
          localEnvelope['header'] as Map,
        );
        if (operation.recordId != first.recordId ||
            localHeader['vault_id'] != vaultId ||
            localHeader['record_id'] != first.recordId ||
            localHeader['operation'] != 'update' ||
            localHeader['base_revision_id'] != operation.baseRevisionId) {
          return _AutoMergeAttempt.notEligible;
        }
        if (index > 0) {
          final previous = orderedOperations[index - 1];
          final previousEnvelope =
              jsonDecode(previous.envelopeJson) as Map<String, dynamic>;
          final previousHeader = Map<String, dynamic>.from(
            previousEnvelope['header'] as Map,
          );
          if (operation.baseRevisionId != previousHeader['revision_id'] ||
              !_jsonEnvelopesEqual(
                operation.baseEnvelopeJson,
                previous.envelopeJson,
              )) {
            return _AutoMergeAttempt.notEligible;
          }
        }
      }

      final latestLocalEnvelope =
          jsonDecode(orderedOperations.last.envelopeJson)
              as Map<String, dynamic>;
      final candidate = await mergeCandidate(
        baseEnvelopeJson: jsonEncode(baseEnvelope),
        localEnvelopeJson: jsonEncode(latestLocalEnvelope),
        remoteEnvelopeJson: jsonEncode(remoteEnvelope),
        requireAutomaticMergeSafe: true,
      );
      if (candidate == null ||
          !candidate.clean ||
          !_isValidAutomaticallyMergedRecord(
            recordId: first.recordId,
            value: candidate.value,
          )) {
        return _AutoMergeAttempt.notEligible;
      }

      _beginLocalWrite();
      try {
        final replacement = await _encryptOperation(
          recordId: first.recordId,
          plaintext: candidate.value,
          baseRevisionId: remoteRevisionId,
          operation: 'update',
        );
        await beforeReplaceMergedOperationForTesting?.call();
        final replaced = await database.replaceOutboxWithMergedOperation(
          vaultId: vaultId,
          recordId: first.recordId,
          original: orderedOperations,
          baseRevisionId: remoteRevisionId,
          baseEnvelope: remoteEnvelope,
          replacementEnvelope: replacement,
        );
        if (!replaced) return _AutoMergeAttempt.retry;
      } finally {
        _endLocalWrite();
      }
      return _AutoMergeAttempt.merged;
    } on FormatException {
      return _AutoMergeAttempt.notEligible;
    }
  }

  /// Reconstructs a record's pending operation order from the signed revision
  /// links. Millisecond timestamps and random operation IDs cannot establish
  /// the order of two edits created in the same millisecond.
  List<PendingOperation>? _orderOutboxChain(
    List<PendingOperation> operations,
    String baseRevisionId,
  ) {
    final byBaseRevision = <String, List<PendingOperation>>{};
    final revisionByOperation = <String, String>{};
    final seenRevisions = <String>{};
    try {
      for (final operation in operations) {
        final envelope = jsonDecode(operation.envelopeJson);
        if (envelope is! Map || envelope['header'] is! Map) return null;
        final header = Map<String, dynamic>.from(envelope['header'] as Map);
        final base = operation.baseRevisionId;
        final revision = header['revision_id'];
        if (base == null ||
            revision is! String ||
            revision.isEmpty ||
            header['op_id'] != operation.opId ||
            header['base_revision_id'] != base ||
            header['record_id'] != operation.recordId ||
            header['vault_id'] != vaultId ||
            header['operation'] != 'update' ||
            revisionByOperation.containsKey(operation.opId) ||
            !seenRevisions.add(revision)) {
          return null;
        }
        revisionByOperation[operation.opId] = revision;
        byBaseRevision.putIfAbsent(base, () => []).add(operation);
      }

      final roots = byBaseRevision[baseRevisionId] ?? const [];
      if (roots.length != 1) return null;
      final ordered = <PendingOperation>[];
      final used = <String>{};
      PendingOperation? current = roots.single;
      while (current != null) {
        if (!used.add(current.opId)) return null;
        ordered.add(current);
        final next =
            byBaseRevision[revisionByOperation[current.opId]] ?? const [];
        if (next.length > 1) return null;
        current = next.isEmpty ? null : next.single;
      }
      return ordered.length == operations.length ? ordered : null;
    } on Object {
      return null;
    }
  }

  bool _isValidAutomaticallyMergedRecord({
    required String recordId,
    required Map<String, Object?> value,
  }) {
    if (value['id'] != recordId) return false;
    try {
      final json = Map<String, dynamic>.from(value);
      switch (value['type']) {
        case 'host':
          return HostRecord.fromJson(json).validate() == null;
        case 'group':
          GroupRecord.fromJson(json);
          return true;
        case 'credential':
          CredentialRecord.fromJson(json);
          return true;
        case 'snippet':
          SnippetRecord.fromJson(json);
          return true;
        default:
          return false;
      }
    } on Object {
      return false;
    }
  }

  bool _jsonEnvelopesEqual(String? left, String right) {
    if (left == null) return false;
    try {
      return canonicalJson(jsonDecode(left)) ==
          canonicalJson(jsonDecode(right));
    } on FormatException {
      return false;
    }
  }

  Future<void> _recordConflict({
    required List<PendingOperation> localOperations,
    required PendingOperation local,
    required Map<String, dynamic> remoteEnvelope,
    required String kind,
    required String remoteCommitSeq,
  }) async {
    final localEnvelope =
        jsonDecode(local.envelopeJson) as Map<String, dynamic>;
    final localHeader = localEnvelope['header'] as Map<String, dynamic>;
    final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
    final conflictId = _uuid.v4();
    final recorded = await database.recordPulledConflict(
      conflictedOperationIds: localOperations
          .map((operation) => operation.opId)
          .toList(growable: false),
      conflictId: conflictId,
      vaultId: vaultId,
      recordId: local.recordId,
      kind: kind,
      branchEnvelope: localEnvelope,
      remoteEnvelope: remoteEnvelope,
      remoteRevisionId: remoteHeader['revision_id'] as String,
      remoteCommitSeq: remoteCommitSeq,
      remoteDeleted: remoteHeader['operation'] == 'delete',
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    if (!recorded) return;
    // Keep the local revision in ConflictBranches; the main head now follows
    // the server, and no branch is silently discarded.
    assert(localHeader['record_id'] == local.recordId);
  }

  Future<void> _requireV2RecordReaders() async {
    final instance = await api.fetchInstance();
    if (!instance.capabilities.contains('device_capability_reports')) {
      throw StateError(
        'This server does not support the signed device capability gate; the encrypted v2 operation remains queued.',
      );
    }
    final readers = await api.vaultDevices(vaultId);
    // The directory also carries historical and invited users for signature
    // verification. Only an active member's active devices can read new heads.
    for (final device in readers) {
      final membershipStatus = device['membership_status'];
      final deviceStatus = device['status'];
      if (membershipStatus is! String ||
          !const {
            'active',
            'invited',
            'revoked',
            'archived',
          }.contains(membershipStatus) ||
          deviceStatus is! String ||
          !const {'active', 'revoked', 'archived'}.contains(deviceStatus)) {
        throw const FormatException(
          'The Vault device directory has an unknown membership or device status; the encrypted v2 operation remains queued.',
        );
      }
    }
    final activeReaders = readers
        .where(
          (device) =>
              device['membership_status'] == 'active' &&
              device['status'] == 'active',
        )
        .toList(growable: false);
    if (activeReaders.isEmpty) {
      throw StateError('The Vault has no active capability-reporting readers.');
    }
    for (final device in activeReaders) {
      final userId = device['user_id'];
      final deviceId = device['device_id'];
      final signingText = device['signing_public_key'];
      final reportValue = device['capability_report'];
      if (userId is! String ||
          deviceId is! String ||
          signingText is! String ||
          reportValue is! Map) {
        throw StateError(
          'An active Vault reader has not reported v2 attachment support; the encrypted operation remains queued.',
        );
      }
      final signingKey = decodeBase64Url(signingText);
      if (signingKey.length != 32 ||
          encodeBase64Url(signingKey) != signingText) {
        throw const FormatException(
          'An active Vault reader has an invalid capability signer key.',
        );
      }
      final capabilities = crypto.verifyDeviceCapabilityReport(
        report: Map<String, dynamic>.from(reportValue),
        expectedAccountId: userId,
        expectedDeviceId: deviceId,
        signingPublicKey: signingKey,
      );
      if (capabilities.maxRecordSchema < 2 ||
          !capabilities.hostAttachmentManifestVersions.contains(2) ||
          capabilities.maxAttachmentBytes < 1024 * 1024 * 1024) {
        throw StateError(
          'An active Vault reader cannot consume the 1 GiB attachment format; the encrypted operation remains queued.',
        );
      }
    }
  }

  Future<bool> _pushQueued({bool allowSnapshotRecovery = false}) async {
    final allowStaleOutboxRewrap = _staleOutboxRewrapAuthorized;
    _staleOutboxRewrapAuthorized = false;
    try {
      return await _pushQueuedPass(
        allowSnapshotRecovery: allowSnapshotRecovery,
        allowStaleOutboxRewrap: allowStaleOutboxRewrap,
      );
    } finally {
      _staleOutboxRewrapAuthorized = false;
    }
  }

  Future<bool> _pushQueuedPass({
    required bool allowSnapshotRecovery,
    required bool allowStaleOutboxRewrap,
  }) async {
    if (!canWrite) return false;
    var revisionConflictRefreshUsed = false;
    while (true) {
      if (_recoveryRequests > 0 && !allowSnapshotRecovery) return false;
      if (!canWrite) return false;
      final rows = await database.pushableOperations(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (rows.isEmpty) return true;
      final allOperations = await database.allPendingOperations(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final activeChains = <String, List<PendingOperation>>{};
      for (final operation in allOperations) {
        if (operation.status == 'queued' ||
            operation.status == 'sent' ||
            operation.status == 'cas_wait' ||
            operation.status == 'conflict') {
          activeChains
              .putIfAbsent(operation.recordId, () => <PendingOperation>[])
              .add(operation);
        }
      }
      final feedTargetsByOpId = <String, FeedConflictResolution>{};
      for (final target in await database.listFeedConflictResolutions(
        vaultId,
      )) {
        final opId = target.opId;
        if (target.state == 'awaiting_commit' && opId != null) {
          feedTargetsByOpId[opId] = target;
        }
      }
      final feedTargetOpIds = feedTargetsByOpId.keys.toSet();
      final feedTargetRows = rows
          .where((row) => feedTargetOpIds.contains(row.opId))
          .toList(growable: false);
      final candidates = feedTargetRows.isNotEmpty
          ? feedTargetRows.take(1)
          : rows.where((row) => !feedTargetOpIds.contains(row.opId));
      final batch = <PendingOperation>[];
      final recordIds = <String>{};
      var bytes = 0;
      for (final next in candidates) {
        if (batch.length >= 100) break;
        // The server accepts at most one revision per record in a batch.
        // Re-query after each receipt so a dependent edit can follow only once
        // its predecessor has been acknowledged.
        if (recordIds.contains(next.recordId)) continue;
        final recordChain =
            activeChains[next.recordId] ?? const <PendingOperation>[];
        final feedTarget = feedTargetsByOpId[next.opId];
        final chainOperations = feedTarget == null
            ? recordChain
            : recordChain
                  .where((operation) => operation.status != 'conflict')
                  .toList(growable: false);
        if (feedTarget != null &&
            !await _feedResolutionMatchesCommittedHead(next, feedTarget)) {
          throw StateError(
            'Feed conflict resolution no longer matches the committed record head.',
          );
        }
        final chain = _orderPendingChain(chainOperations);
        if (chain.isEmpty || chain.first.opId != next.opId) {
          // Do not send a dependent revision before its predecessor, even if
          // two edits were persisted within the same clock tick.
          continue;
        }
        final size = utf8.encode(next.envelopeJson).length;
        if (batch.isNotEmpty && bytes + size > 900 * 1024) continue;
        if (size > 1024 * 1024) {
          throw const FormatException(
            'Encrypted record exceeds the sync batch size limit',
          );
        }
        batch.add(next);
        recordIds.add(next.recordId);
        bytes += size;
      }
      if (batch.isEmpty) {
        throw StateError('No eligible operation fits in the sync batch.');
      }
      final decoded = batch
          .map((item) => jsonDecode(item.envelopeJson) as Map<String, dynamic>)
          .toList(growable: false);
      if (decoded.any(
        (envelope) => (envelope['header'] as Map?)?['record_schema'] == 2,
      )) {
        await _requireV2RecordReaders();
      }
      await beforePushMarkAttemptedForTesting?.call();
      final attemptedIds = await database.markAttempted(
        batch.map((item) => item.opId),
      );
      final attemptedBatch = batch
          .where((item) => attemptedIds.contains(item.opId))
          .toList(growable: false);
      if (attemptedBatch.isEmpty) continue;
      final attemptedEnvelopes = attemptedBatch
          .map((item) => jsonDecode(item.envelopeJson) as Map<String, dynamic>)
          .toList(growable: false);
      final batchId = _uuid.v4();
      Map<String, dynamic> response;
      try {
        response = await api.push(vaultId, {
          'protocol_version': 1,
          'server_generation': serverGeneration,
          'vault_id': vaultId,
          'device_id': identity.deviceId,
          'batch_id': batchId,
          'operations': attemptedEnvelopes,
        });
      } on ApiException catch (error) {
        if (_isServerGenerationChanged(error)) {
          await database.restoreUnacceptedPushAttempts(attemptedBatch);
          rethrow;
        }
        if (error.statusCode == 409 && error.code == 'RECORD_RESTORE_EXPIRED') {
          await _retryBatchAfterRestoreExpiry(attemptedBatch);
          continue;
        }
        final isFeedAdoption =
            attemptedBatch.length == 1 &&
            feedTargetOpIds.contains(attemptedBatch.single.opId);
        if (_isStaleOutboxVersion(error)) {
          if (!canWrite || deletionPending) {
            throw StateError(
              'Vault is not writable; the encrypted outbox was kept.',
            );
          }
          if (attemptedBatch.length == 1) {
            if (!allowStaleOutboxRewrap ||
                _operationUsesCurrentVersion(attemptedBatch.single)) {
              rethrow;
            }
            await _replaceStaleOutboxChain(attemptedBatch.single);
          } else {
            // A batch-level 409 does not identify which member-versioned
            // operation is stale. Probe each immutable envelope separately;
            // successful old receipts are acknowledged as-is, and only an
            // explicit per-operation stale-version rejection permits rewrite.
            for (final operation in attemptedBatch) {
              await _probeStaleOutboxOperation(
                operation,
                allowStaleOutboxRewrap: allowStaleOutboxRewrap,
              );
            }
          }
          continue;
        }
        if (error.statusCode == 409 &&
            error.code == 'REVISION_CONFLICT' &&
            !isFeedAdoption) {
          if (revisionConflictRefreshUsed) return false;
          // A single operation or batch can race a competing commit after
          // this pass's initial pull. The server rejects the push atomically,
          // so refresh only from the signed main feed, then rebuild from
          // durable local state. Never identify a record from the 409 body or
          // mutate the attempted envelopes based on that response.
          revisionConflictRefreshUsed = true;
          await _pullMainChangesAfterCas();
          // A signed refresh can preserve the stale record as a new local
          // conflict branch. Upload that branch before continuing with
          // independent queued records, matching the normal pre-push order.
          await _publishPendingConflicts();
          continue;
        }
        if (error.code != 'REVISION_CONFLICT' ||
            !isFeedAdoption ||
            !await database.markFeedConflictCasRefresh(
              attemptedBatch.single.opId,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
            )) {
          rethrow;
        }
        // The old signed attempt is held out of push retries. A normal signed
        // main-feed event updates the cached head and moves the target to
        // needs_review; no server envelope is installed from the error body.
        await _pullMainChangesAfterCas();
        await database.releaseUnmatchedFeedCasTargets(
          vaultId,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
        return false;
      }
      final receipts = _validatePushResponse(
        response: response,
        batchId: batchId,
        requested: attemptedBatch,
      );
      await knownHostDecisionLock.run(
        knownHostDecisionScope,
        () => database.acknowledgePushBatch(
          vaultId: vaultId,
          requested: attemptedBatch,
          receipts: receipts,
        ),
      );
    }
  }

  /// A batched push is atomic, so an expired restore can reject unrelated
  /// operations in the same request. Re-submit those immutable operations one
  /// at a time, and roll back only the exact restore the server rejected.
  Future<void> _retryBatchAfterRestoreExpiry(
    List<PendingOperation> attemptedBatch,
  ) async {
    await database.restoreUnacceptedPushAttempts(attemptedBatch);
    for (final operation in attemptedBatch) {
      final attemptedIds = await database.markAttempted([operation.opId]);
      if (!attemptedIds.contains(operation.opId)) continue;
      final envelope =
          jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
      final batchId = _uuid.v4();
      try {
        final response = await api.push(vaultId, {
          'protocol_version': 1,
          'server_generation': serverGeneration,
          'vault_id': vaultId,
          'device_id': identity.deviceId,
          'batch_id': batchId,
          'operations': [envelope],
        });
        final receipts = _validatePushResponse(
          response: response,
          batchId: batchId,
          requested: [operation],
        );
        await knownHostDecisionLock.run(
          knownHostDecisionScope,
          () => database.acknowledgePushBatch(
            vaultId: vaultId,
            requested: [operation],
            receipts: receipts,
          ),
        );
      } on ApiException catch (error) {
        if (_isServerGenerationChanged(error)) {
          await database.restoreUnacceptedPushAttempts([operation]);
          rethrow;
        }
        if (error.statusCode != 409 || error.code != 'RECORD_RESTORE_EXPIRED') {
          rethrow;
        }
        final rawHeader = envelope['header'];
        if (rawHeader is! Map) rethrow;
        final header = Map<String, dynamic>.from(rawHeader);
        final recordId = header['record_id'];
        final restoreRevisionId = header['revision_id'];
        final tombstoneRevisionId = header['base_revision_id'];
        if (header['operation'] != 'restore' ||
            recordId is! String ||
            restoreRevisionId is! String ||
            tombstoneRevisionId is! String) {
          rethrow;
        }
        await database.restoreUnacceptedPushAttempts([operation]);
        final snapshot = await _createVerifiedRecycleBinSnapshot();
        final tombstone = snapshot.tombstones[recordId];
        if (tombstone == null ||
            tombstone.revisionId != tombstoneRevisionId ||
            tombstone.commitSeq == null) {
          rethrow;
        }
        await _verifyRecycleBinRevision(
          envelope: envelope,
          expectedRecordId: recordId,
          expectedRevisionId: restoreRevisionId,
          expectedOperation: 'restore',
          expectedDeleted: false,
        );
        final rolledBack = await database
            .rejectExpiredRestoreAndInstallServerTombstone(
              vaultId: vaultId,
              recordId: recordId,
              restoreOpId: operation.opId,
              restoreRevisionId: restoreRevisionId,
              tombstoneRevisionId: tombstoneRevisionId,
              tombstoneEnvelope: tombstone.envelope,
              tombstoneCommitSeq: tombstone.commitSeq!,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
            );
        if (!rolledBack) rethrow;
        rethrow;
      }
    }
  }

  bool _isStaleOutboxVersion(ApiException error) =>
      error.statusCode == 409 &&
      const {
        'KEY_EPOCH_OUTDATED',
        'MEMBERSHIP_VERSION_CONFLICT',
      }.contains(error.code);

  Future<bool> _feedResolutionMatchesCommittedHead(
    PendingOperation operation,
    FeedConflictResolution target,
  ) async {
    if (target.vaultId != vaultId ||
        target.recordId != operation.recordId ||
        target.state != 'awaiting_commit' ||
        target.opId != operation.opId) {
      return false;
    }
    final envelope = jsonDecode(operation.envelopeJson);
    if (envelope is! Map || envelope['header'] is! Map) return false;
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    if (header['op_id'] != operation.opId ||
        header['vault_id'] != vaultId ||
        header['record_id'] != operation.recordId ||
        header['revision_id'] != target.resolutionRevisionId ||
        header['base_revision_id'] != operation.baseRevisionId) {
      return false;
    }
    final head = await database.encryptedRecord(
      vaultId,
      operation.recordId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    return head?.revisionId == operation.baseRevisionId &&
        (head == null || head.commitSeq != null) &&
        head?.envelopeJson == operation.baseEnvelopeJson;
  }

  bool _isServerGenerationChanged(ApiException error) =>
      error.statusCode == 410 && error.code == 'SERVER_GENERATION_CHANGED';

  Future<void> _probeStaleOutboxOperation(
    PendingOperation operation, {
    required bool allowStaleOutboxRewrap,
  }) async {
    if (!canWrite || deletionPending) {
      throw StateError('Vault is not writable; the encrypted outbox was kept.');
    }
    final attemptedIds = await database.markAttempted([operation.opId]);
    if (!attemptedIds.contains(operation.opId)) return;
    final batchId = _uuid.v4();
    final envelope = jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
    try {
      final response = await api.push(vaultId, {
        'protocol_version': 1,
        'server_generation': serverGeneration,
        'vault_id': vaultId,
        'device_id': identity.deviceId,
        'batch_id': batchId,
        'operations': [envelope],
      });
      final receipts = _validatePushResponse(
        response: response,
        batchId: batchId,
        requested: [operation],
      );
      await knownHostDecisionLock.run(
        knownHostDecisionScope,
        () => database.acknowledgePushBatch(
          vaultId: vaultId,
          requested: [operation],
          receipts: receipts,
        ),
      );
    } on ApiException catch (error) {
      if (_isServerGenerationChanged(error)) {
        await database.restoreUnacceptedPushAttempts([operation]);
        rethrow;
      }
      if (!_isStaleOutboxVersion(error)) rethrow;
      if (!canWrite || deletionPending) {
        throw StateError(
          'Vault is not writable; the encrypted outbox was kept.',
        );
      }
      if (!allowStaleOutboxRewrap || _operationUsesCurrentVersion(operation)) {
        rethrow;
      }
      await _replaceStaleOutboxChain(operation);
    }
  }

  bool _operationUsesCurrentVersion(PendingOperation operation) {
    try {
      final envelope = jsonDecode(operation.envelopeJson);
      if (envelope is! Map || envelope['header'] is! Map) return false;
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      return header['key_epoch'] == keyEpoch &&
          header['membership_version'] == membershipVersion;
    } catch (_) {
      return false;
    }
  }

  List<PendingOperation> _orderPendingChain(List<PendingOperation> operations) {
    if (operations.isEmpty) return const [];
    final byRevision = <String, PendingOperation>{};
    for (final operation in operations) {
      final envelope = jsonDecode(operation.envelopeJson);
      if (envelope is! Map || envelope['header'] is! Map) {
        throw const FormatException('Pending operation header is malformed.');
      }
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final revision = header['revision_id'];
      if (header['op_id'] != operation.opId ||
          header['vault_id'] != operation.vaultId ||
          header['record_id'] != operation.recordId ||
          revision is! String ||
          byRevision.containsKey(revision)) {
        throw const FormatException('Pending operation chain is malformed.');
      }
      byRevision[revision] = operation;
    }
    final roots = operations
        .where((operation) {
          final base = operation.baseRevisionId;
          return base == null || !byRevision.containsKey(base);
        })
        .toList(growable: false);
    if (roots.length != 1) {
      throw const FormatException('Pending operation chain is not linear.');
    }
    final ordered = <PendingOperation>[roots.single];
    while (true) {
      final currentEnvelope =
          jsonDecode(ordered.last.envelopeJson) as Map<String, dynamic>;
      final currentHeader = currentEnvelope['header'] as Map<String, dynamic>;
      final revisionId = currentHeader['revision_id'] as String;
      final children = operations
          .where((operation) {
            if (ordered.any((item) => item.opId == operation.opId)) {
              return false;
            }
            return operation.baseRevisionId == revisionId;
          })
          .toList(growable: false);
      if (children.isEmpty) break;
      if (children.length != 1) {
        throw const FormatException('Pending operation chain has a fork.');
      }
      ordered.add(children.single);
    }
    if (ordered.length != operations.length) {
      throw const FormatException('Pending operation chain is disconnected.');
    }
    for (var index = 0; index < ordered.length; index++) {
      final operation = ordered[index];
      if (index > 0) {
        final previous = ordered[index - 1];
        if (operation.baseEnvelopeJson != previous.envelopeJson) {
          throw const FormatException(
            'Pending operation chain base envelope is inconsistent.',
          );
        }
        continue;
      }
      final baseJson = operation.baseEnvelopeJson;
      if (baseJson == null) continue;
      final baseEnvelope = jsonDecode(baseJson);
      if (baseEnvelope is! Map || baseEnvelope['header'] is! Map) {
        throw const FormatException('Pending operation base is malformed.');
      }
      final baseHeader = Map<String, dynamic>.from(
        baseEnvelope['header'] as Map,
      );
      if (baseHeader['vault_id'] != vaultId ||
          baseHeader['record_id'] != operation.recordId ||
          baseHeader['revision_id'] != operation.baseRevisionId) {
        throw const FormatException(
          'Pending operation base context is invalid.',
        );
      }
    }
    return ordered;
  }

  Future<void> _replaceStaleOutboxChain(PendingOperation rejected) async {
    if (!canWrite || deletionPending) {
      throw StateError('Vault is not writable; the encrypted outbox was kept.');
    }
    final operations =
        (await database.allPendingOperations(
              vaultId,
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
            ))
            .where(
              (operation) =>
                  operation.recordId == rejected.recordId &&
                  operation.status != 'superseded',
            )
            .toList(growable: false);
    if (operations.any(
          (operation) =>
              operation.status == 'cas_wait' || operation.status == 'conflict',
        ) ||
        operations.any(
          (operation) =>
              operation.status != 'queued' && operation.status != 'sent',
        )) {
      throw StateError('Outbox has a conflict that needs review before retry.');
    }
    final chain = _orderPendingChain(operations);
    if (chain.isEmpty || chain.first.opId != rejected.opId) {
      throw StateError('Rejected operation is not the active outbox head.');
    }

    final replacements = <StaleOperationReplacement>[];
    var nextBaseRevisionId = chain.first.baseRevisionId;
    var nextBaseEnvelopeJson = chain.first.baseEnvelopeJson;
    var expectedOldBaseRevisionId = chain.first.baseRevisionId;
    var expectedOldBaseEnvelopeJson = chain.first.baseEnvelopeJson;
    for (final operation in chain) {
      final envelope =
          jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
      final header = Map<String, dynamic>.from(envelope['header'] as Map);
      final oldEpoch = header['key_epoch'];
      final oldMembership = header['membership_version'];
      final oldVersion = '$oldEpoch:$oldMembership';
      final oldKey = vaultKeysByVersion[oldVersion];
      final operationName = header['operation'];
      const baseHeaderKeys = {
        'wire_version',
        'server_space_id',
        'vault_id',
        'record_id',
        'revision_id',
        'base_revision_id',
        'op_id',
        'device_id',
        'device_seq',
        'key_epoch',
        'membership_version',
        'record_schema',
        'operation',
        'crypto_suite',
        'kdf_salt',
      };
      final validHeaderShape = header.containsKey('object_refs')
          ? _hasExactKeys(header, {...baseHeaderKeys, 'object_refs'})
          : _hasExactKeys(header, baseHeaderKeys);
      if (!_hasExactKeys(envelope, const {
            'header',
            'nonce',
            'ciphertext',
            'signature',
          }) ||
          !validHeaderShape ||
          header['wire_version'] != 1 ||
          header['server_space_id'] != serverSpaceId ||
          header['crypto_suite'] != 'atermius-vault-v1' ||
          !const {1, 2}.contains(header['record_schema']) ||
          header['vault_id'] != vaultId ||
          header['record_id'] != operation.recordId ||
          header['op_id'] != operation.opId ||
          header['base_revision_id'] != operation.baseRevisionId ||
          (header['base_revision_id'] != null &&
              (header['base_revision_id'] is! String ||
                  !_canonicalUuid.hasMatch(
                    header['base_revision_id'] as String,
                  ))) ||
          header['revision_id'] is! String ||
          !_canonicalUuid.hasMatch(header['revision_id'] as String) ||
          header['device_id'] != identity.deviceId ||
          header['device_seq'] is! String ||
          !_canonicalPositiveDecimal.hasMatch(header['device_seq'] as String) ||
          oldEpoch is! String ||
          !_canonicalDecimal.hasMatch(oldEpoch) ||
          oldMembership is! String ||
          !_canonicalDecimal.hasMatch(oldMembership) ||
          oldKey == null ||
          oldKey.length != 32 ||
          !const {
            'create',
            'update',
            'delete',
            'restore',
          }.contains(operationName)) {
        throw StateError(
          'The old encrypted operation cannot be verified for a safe key update.',
        );
      }
      if (operation.baseRevisionId != expectedOldBaseRevisionId ||
          operation.baseEnvelopeJson != expectedOldBaseEnvelopeJson) {
        throw StateError('Outbox base changed during key update.');
      }
      final oldKeyCopy = Uint8List.fromList(oldKey);
      late final Map<String, dynamic> plaintext;
      try {
        plaintext = await crypto.decryptRecord(
          vaultKey: oldKeyCopy,
          envelope: envelope,
          authorPublicKey: identity.signing.publicKey,
        );
      } finally {
        oldKeyCopy.fillRange(0, oldKeyCopy.length, 0);
      }
      if (plaintext['id'] != operation.recordId ||
          (operationName == 'delete') != (plaintext['deleted'] == true) ||
          (plaintext.containsKey('deleted') && plaintext['deleted'] is! bool)) {
        throw const FormatException(
          'Old encrypted operation does not match its signed record context.',
        );
      }
      final rewritten = await _encryptOperation(
        recordId: operation.recordId,
        plaintext: plaintext,
        baseRevisionId: nextBaseRevisionId,
        operation: operationName as String,
      );
      final rewrittenHeader = Map<String, dynamic>.from(
        rewritten['header'] as Map,
      );
      if (rewrittenHeader['op_id'] == operation.opId ||
          rewrittenHeader['revision_id'] == header['revision_id'] ||
          canonicalJson(rewrittenHeader['object_refs'] ?? const []) !=
              canonicalJson(header['object_refs'] ?? const [])) {
        throw const FormatException(
          'Re-encrypted operation did not produce a fresh equivalent envelope.',
        );
      }
      final encoded = jsonEncode(rewritten);
      replacements.add(
        StaleOperationReplacement(
          opId: rewrittenHeader['op_id'] as String,
          baseRevisionId: nextBaseRevisionId,
          baseEnvelopeJson: nextBaseEnvelopeJson,
          envelopeJson: encoded,
        ),
      );
      expectedOldBaseRevisionId = header['revision_id'] as String;
      expectedOldBaseEnvelopeJson = operation.envelopeJson;
      nextBaseRevisionId = rewrittenHeader['revision_id'] as String;
      nextBaseEnvelopeJson = encoded;
    }

    await database.replaceStaleOutboxChain(
      vaultId: vaultId,
      recordId: rejected.recordId,
      original: chain,
      replacements: replacements,
    );
  }

  Map<String, PushCommitReceipt> _validatePushResponse({
    required Map<String, dynamic> response,
    required String batchId,
    required List<PendingOperation> requested,
  }) {
    if (response['batch_id'] != batchId) {
      throw const FormatException('Push receipt batch_id does not match.');
    }
    final rawResults = response['results'];
    if (rawResults is! List || rawResults.length != requested.length) {
      throw const FormatException(
        'Push response must contain exactly one receipt per operation.',
      );
    }
    final requestedById = <String, PendingOperation>{};
    for (final operation in requested) {
      if (requestedById.containsKey(operation.opId)) {
        throw const FormatException('Push batch contains a duplicate op_id.');
      }
      requestedById[operation.opId] = operation;
    }
    final receipts = <String, PushCommitReceipt>{};
    for (final raw in rawResults) {
      if (raw is! Map) {
        throw const FormatException(
          'Push response contains a malformed receipt.',
        );
      }
      final item = Map<String, dynamic>.from(raw);
      final opId = item['op_id'];
      final revisionId = item['revision_id'];
      final rawCommitSeq = item['commit_seq'];
      if (opId is! String ||
          revisionId is! String ||
          (rawCommitSeq is! String && rawCommitSeq is! int) ||
          item['already_committed'] is! bool) {
        throw const FormatException(
          'Push response receipt fields are invalid.',
        );
      }
      final operation = requestedById[opId];
      if (operation == null || receipts.containsKey(opId)) {
        throw const FormatException(
          'Push response contains an unknown or duplicate op_id.',
        );
      }
      final envelope =
          jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
      final header = envelope['header'] as Map<String, dynamic>;
      final commitSeq = rawCommitSeq.toString();
      if (header['op_id'] != opId ||
          header['revision_id'] != revisionId ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(commitSeq)) {
        throw const FormatException(
          'Push response receipt does not match its signed operation.',
        );
      }
      receipts[opId] = PushCommitReceipt(
        opId: opId,
        revisionId: revisionId,
        commitSeq: commitSeq,
      );
    }
    if (receipts.length != requestedById.length ||
        !receipts.keys.toSet().containsAll(requestedById.keys)) {
      throw const FormatException(
        'Push response omitted an operation receipt.',
      );
    }
    return receipts;
  }

  Future<MergeResult?> mergeCandidate({
    required String baseEnvelopeJson,
    required String localEnvelopeJson,
    required String remoteEnvelopeJson,
    bool requireAutomaticMergeSafe = false,
  }) => _withKeyOperation(() async {
    try {
      final baseEnvelope = jsonDecode(baseEnvelopeJson) as Map<String, dynamic>;
      final localEnvelope =
          jsonDecode(localEnvelopeJson) as Map<String, dynamic>;
      final remoteEnvelope =
          jsonDecode(remoteEnvelopeJson) as Map<String, dynamic>;
      final baseHeader = baseEnvelope['header'] as Map<String, dynamic>;
      final localHeader = localEnvelope['header'] as Map<String, dynamic>;
      final remoteHeader = remoteEnvelope['header'] as Map<String, dynamic>;
      final baseSigner = _signers[baseHeader['device_id'] as String];
      final localSigner = _signers[localHeader['device_id'] as String];
      final remoteSigner = _signers[remoteHeader['device_id'] as String];
      if (baseSigner == null || localSigner == null || remoteSigner == null)
        return null;
      List<int>? recordKeyFor(Map<String, dynamic> header) {
        final epoch = header['key_epoch'];
        final membership = header['membership_version'];
        if (epoch is! String || membership is! String) return null;
        final versioned = vaultKeysByVersion['$epoch:$membership'];
        if (versioned != null) return versioned;
        if (epoch == keyEpoch && membership == this.membershipVersion) {
          return vaultKey;
        }
        return null;
      }

      final baseKey = recordKeyFor(baseHeader);
      final localKey = recordKeyFor(localHeader);
      final remoteKey = recordKeyFor(remoteHeader);
      if (baseKey == null || localKey == null || remoteKey == null) return null;
      final base = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(baseKey),
        envelope: baseEnvelope,
        authorPublicKey: Uint8List.fromList(baseSigner),
      );
      final local = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(localKey),
        envelope: localEnvelope,
        authorPublicKey: Uint8List.fromList(localSigner),
      );
      final remote = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(remoteKey),
        envelope: remoteEnvelope,
        authorPublicKey: Uint8List.fromList(remoteSigner),
      );
      // A terminal layout is an ordered tree with a selected pane. Field-wise
      // merging can silently combine incompatible layouts, so keep both signed
      // encrypted conflict branches intact for an explicit user decision.
      if ([base, local, remote].any(
        (record) =>
            record['type'] == 'workspace' ||
            record['deleted'] == true ||
            record['id'] != base['id'] ||
            record['type'] != base['type'],
      )) {
        return null;
      }
      final merged = mergeRecord(base: base, local: local, remote: remote);
      if (requireAutomaticMergeSafe &&
          !isAutomaticMergeSafe(
            base: base,
            local: local,
            remote: remote,
            result: merged,
          )) {
        return null;
      }
      return merged;
    } on FormatException {
      return null;
    }
  });

  Future<void> resolveConflictBranch({
    required String conflictId,
    required bool keepLocal,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      final published = await _publishPendingConflicts();
      final serverConflictId = published.ids[conflictId] ?? conflictId;
      await refreshSignerDirectory();
      final conflict = (await database.openConflicts(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).where((item) => item.conflictId == serverConflictId).firstOrNull;
      if (conflict == null)
        throw StateError('Conflict branch is missing or already resolved.');
      if (conflict.kind == 'record_redacted' ||
          conflict.state == 'redacted_draft' ||
          conflict.redactionProofJson != null) {
        throw StateError(
          'This local draft is quarantined by a verified record-redaction proof and cannot be pushed.',
        );
      }
      final pending = await database.conflictedOperation(
        vaultId,
        conflict.recordId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (pending == null)
        throw StateError('Local conflict branch has no pending operation.');
      final localEnvelope =
          jsonDecode(conflict.branchEnvelopeJson) as Map<String, dynamic>;
      final remoteEnvelope =
          jsonDecode(conflict.remoteEnvelopeJson) as Map<String, dynamic>;
      final chosenEnvelope = keepLocal ? localEnvelope : remoteEnvelope;
      final chosenHeader = chosenEnvelope['header'] as Map<String, dynamic>;
      final signer = _signers[chosenHeader['device_id'] as String];
      if (signer == null)
        throw StateError('Missing signing key for conflict branch.');
      final recordKey =
          vaultKeysByVersion['${chosenHeader['key_epoch']}:${chosenHeader['membership_version']}'] ??
          vaultKey;
      final clear = await crypto.decryptRecord(
        vaultKey: Uint8List.fromList(recordKey),
        envelope: chosenEnvelope,
        authorPublicKey: Uint8List.fromList(signer),
      );
      final remoteHeader = remoteEnvelope['header'] is Map
          ? Map<String, dynamic>.from(remoteEnvelope['header'] as Map)
          : null;
      final operation = remoteHeader == null
          ? 'create'
          : chosenHeader['operation'] == 'delete'
          ? 'delete'
          : remoteHeader['operation'] == 'delete'
          ? 'restore'
          : 'update';
      final resolution = await _encryptOperation(
        recordId: conflict.recordId,
        plaintext: clear,
        baseRevisionId: remoteHeader?['revision_id'] as String?,
        operation: operation,
      );
      Future<void> queueResolution() => database.queueConflictResolution(
        conflictId: serverConflictId,
        vaultId: vaultId,
        recordId: conflict.recordId,
        baseRevisionId: remoteHeader?['revision_id'] as String?,
        envelope: resolution,
        deleted: operation == 'delete',
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      if (clear['type'] == 'knownHost') {
        await knownHostDecisionLock.run(
          knownHostDecisionScope,
          queueResolution,
        );
      } else {
        await queueResolution();
      }
    }),
  );

  /// Saves the locally preserved Workspace conflict branch under a new name.
  ///
  /// The original conflict remains open and both original signed encrypted
  /// branches remain untouched. Only the new named copy is added to the local
  /// encrypted record/outbox tables.
  Future<String> saveWorkspaceConflictBranchAsNamedCopy({
    required String conflictId,
    required String copyName,
  }) => _withKeyOperation(
    () => _runSerialized(() async {
      if (!canWrite || deletionPending) {
        throw StateError(
          'This Vault is read-only; workspace copies cannot be saved.',
        );
      }
      final conflict = (await database.openConflicts(
        vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      )).where((item) => item.conflictId == conflictId).firstOrNull;
      if (conflict == null ||
          (conflict.state != 'open' && conflict.state != 'upload_pending')) {
        throw StateError('Open workspace conflict branch was not found.');
      }

      await refreshSignerDirectory();
      final decodedEnvelope = jsonDecode(conflict.branchEnvelopeJson);
      if (decodedEnvelope is! Map ||
          decodedEnvelope.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Local conflict branch envelope is malformed.',
        );
      }
      final branchEnvelope = Map<String, dynamic>.from(decodedEnvelope);
      final rawHeader = branchEnvelope['header'];
      if (rawHeader is! Map || rawHeader.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Local conflict branch header is malformed.',
        );
      }
      final header = Map<String, dynamic>.from(rawHeader);
      final deviceId = header['device_id'];
      final epoch = header['key_epoch'];
      final membership = header['membership_version'];
      if (header['server_space_id'] != serverSpaceId ||
          header['vault_id'] != vaultId ||
          header['record_id'] != conflict.recordId ||
          header['operation'] == 'delete' ||
          deviceId is! String ||
          epoch is! String ||
          membership is! String) {
        throw const FormatException(
          'Local conflict branch does not belong to this Workspace record and Vault.',
        );
      }
      final signer = _signers[deviceId];
      if (signer == null) {
        throw StateError('Missing signing key for local conflict branch.');
      }
      final version = '$epoch:$membership';
      final branchKey =
          vaultKeysByVersion[version] ??
          (epoch == keyEpoch && membership == membershipVersion
              ? vaultKey
              : null);
      if (branchKey == null) {
        throw StateError('Missing Vault key for local conflict branch.');
      }

      late final Map<String, dynamic> clear;
      final keyBytes = Uint8List.fromList(branchKey);
      try {
        clear = await crypto.decryptRecord(
          vaultKey: keyBytes,
          envelope: branchEnvelope,
          authorPublicKey: Uint8List.fromList(signer),
        );
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }
      if (clear['deleted'] == true) {
        throw const FormatException('A deleted Workspace cannot be copied.');
      }
      final source = WorkspaceRecord.fromJson(clear);
      if (source.id != conflict.recordId) {
        throw const FormatException(
          'Local Workspace payload ID does not match conflict metadata.',
        );
      }
      final copy = source.duplicateWithNewIdentity(name: copyName);
      await _saveRecord(
        recordId: copy.id,
        plaintext: copy.toJson(),
        operation: 'create',
      );
      return copy.id;
    }),
  );

  Future<void> _setStatus(String status) async {
    await database
        .into(database.syncCheckpoints)
        .insertOnConflictUpdate(
          SyncCheckpointsCompanion.insert(
            vaultId: vaultId,
            instanceId: Value(instanceId),
            serverSpaceId: Value(serverSpaceId),
            syncStatus: Value(status),
          ),
        );
  }
}
