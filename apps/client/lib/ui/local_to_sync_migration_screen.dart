import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../storage/client_database.dart';
import '../storage/application_reload.dart';
import '../storage/database_quarantine.dart';
import '../storage/local_migration_target_validator.dart';
import '../storage/local_host_repository.dart';
import '../storage/local_profile_catalog.dart';
import '../storage/local_profile_service.dart';
import '../storage/local_vault_database.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

const _migrationUuid = Uuid();

typedef LocalVaultDatabaseFactoryForTesting =
    Future<LocalVaultDatabase> Function(
      UnlockedLocalProfile profile, {
      required LocalVaultOpenMode mode,
    });

/// Guided, client-side migration from an encrypted LocalVault into a newly
/// created empty server Vault. Source secrets are decrypted only in memory;
/// the durable journal stores the exact target ciphertext needed for replay.
class LocalToSyncMigrationScreen extends StatefulWidget {
  const LocalToSyncMigrationScreen({
    required this.controller,
    required this.catalog,
    required this.service,
    required this.crypto,
    this.quarantineRegistry,
    this.reloadPageForTesting,
    @visibleForTesting this.databaseFactoryForTesting,
    super.key,
  });

  final AppController controller;
  final LocalProfileCatalog catalog;
  final LocalProfileService service;
  final VaultCrypto crypto;
  @visibleForTesting
  final DatabaseQuarantineRegistry? quarantineRegistry;
  @visibleForTesting
  final VoidCallback? reloadPageForTesting;
  @visibleForTesting
  final LocalVaultDatabaseFactoryForTesting? databaseFactoryForTesting;

  @override
  State<LocalToSyncMigrationScreen> createState() =>
      _LocalToSyncMigrationScreenState();
}

class _LocalToSyncMigrationScreenState
    extends State<LocalToSyncMigrationScreen> {
  final _password = TextEditingController();
  final _vaultName = TextEditingController(text: currentL10n.importedLocalProfiles);

  List<LocalProfileRecord> _profiles = const [];
  List<LocalMigrationJournalSummary> _journals = const [];
  Set<String> _cancelableMigrationIds = const {};
  String? _selectedProfileId;
  UnlockedLocalProfile? _profile;
  LocalVaultDatabase? _database;
  LocalHostRepository? _repository;
  String? _activeMigrationId;
  String? _status;
  String? _error;
  int _stagedCount = 0;
  int _totalCount = 0;
  bool _loadingProfiles = true;
  bool _busy = false;
  bool _complete = false;
  bool _storageRecoveryRequired = false;
  String? _pendingProfileId;

  late final LocalVaultDatabaseFactoryForTesting _databaseFactory =
      widget.databaseFactoryForTesting ??
      ((profile, {required mode}) =>
          LocalVaultDatabase.open(profile, mode: mode));

  DatabaseQuarantineRegistry get _databaseQuarantineRegistry =>
      widget.quarantineRegistry ?? databaseQuarantineRegistry;

  bool get _hasRelevantDatabaseQuarantine {
    final names = _databaseQuarantineRegistry.quarantinedDatabaseNames;
    if (names.contains(localProfileCatalogDatabaseName)) return true;
    final profileId =
        _pendingProfileId ?? _profile?.record.profileId ?? _selectedProfileId;
    return profileId != null &&
        names.contains(localVaultDatabaseName(profileId));
  }

  @override
  void initState() {
    super.initState();
    _databaseQuarantineRegistry.addListener(_onDatabaseQuarantineChanged);
    _storageRecoveryRequired = _hasRelevantDatabaseQuarantine;
    if (!_storageRecoveryRequired) unawaited(_loadProfiles());
  }

  @override
  void dispose() {
    _databaseQuarantineRegistry.removeListener(_onDatabaseQuarantineChanged);
    _password.dispose();
    _vaultName.dispose();
    final profile = _profile;
    final database = _database;
    _profile = null;
    _database = null;
    _repository = null;
    if (profile != null) {
      unawaited(_closeLocalSession(profile, database));
    } else if (database != null) {
      unawaited(database.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  void _onDatabaseQuarantineChanged() {
    if (_hasRelevantDatabaseQuarantine) _requireDatabaseRecovery();
  }

  void _requireDatabaseRecovery() {
    if (!mounted || _storageRecoveryRequired) return;
    final profile = _profile;
    final database = _database;
    setState(() {
      _storageRecoveryRequired = true;
      _loadingProfiles = false;
      _busy = false;
      _profiles = const [];
      _journals = const [];
      _cancelableMigrationIds = const {};
      _profile = null;
      _database = null;
      _repository = null;
      _pendingProfileId = null;
      _activeMigrationId = null;
      _status = null;
      _error = null;
      _complete = false;
    });
    if (profile != null) {
      unawaited(_closeLocalSession(profile, database));
    } else if (database != null) {
      unawaited(database.close().catchError((Object _) {}));
    }
  }

  Future<T> _runLocalStorageOperation<T>(
    Future<T> Function() operation, {
    FutureOr<void> Function(T result)? onQuarantinedResult,
  }) async {
    _throwIfStorageRecoveryRequired();
    try {
      final result = await operation();
      if (_storageRecoveryRequired) {
        if (onQuarantinedResult != null) {
          try {
            await onQuarantinedResult(result);
          } on Object {
            // Preserve the recovery error even if best-effort cleanup fails.
          }
        }
        throw const DatabaseRecoveryRequiredException();
      }
      return result;
    } on DatabaseRecoveryRequiredException {
      _requireDatabaseRecovery();
      rethrow;
    }
  }

  Future<T> _runMigrationStep<T>(Future<T> Function() operation) async {
    _throwIfStorageRecoveryRequired();
    final result = await operation();
    // A controller/API call already in flight cannot be cancelled here, but
    // its completion must not start another step after LocalVault quarantine.
    _throwIfStorageRecoveryRequired();
    return result;
  }

  void _throwIfStorageRecoveryRequired() {
    if (_storageRecoveryRequired) {
      throw const DatabaseRecoveryRequiredException();
    }
  }

  Future<void> _reloadPage() async {
    final reload = widget.reloadPageForTesting;
    if (reload != null) {
      reload();
    } else {
      reloadApplication();
    }
  }

  Future<void> _closeLocalSession(
    UnlockedLocalProfile profile,
    LocalVaultDatabase? database,
  ) async {
    try {
      await profile.lock();
    } on Object {
      // Closing the database below still invalidates this screen's session.
    }
    if (database != null) {
      try {
        await database.close();
      } on Object {
        // The browser may already have disposed the local storage delegate.
      }
    }
  }

  Future<void> _loadProfiles() async {
    if (_storageRecoveryRequired) return;
    try {
      final profiles = await _runLocalStorageOperation(widget.catalog.list);
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _profiles = profiles;
        _selectedProfileId = profiles.isEmpty ? null : profiles.first.profileId;
        _loadingProfiles = false;
        _error = null;
      });
      // A LocalVault may have been quarantined before this screen knew which
      // profile would be selected. Recheck as soon as catalog hydration picks
      // the initial profile rather than waiting for a user selection event.
      if (_hasRelevantDatabaseQuarantine) _requireDatabaseRecovery();
    } on DatabaseRecoveryRequiredException {
      if (mounted && !_storageRecoveryRequired) _requireDatabaseRecovery();
    } on Object {
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _loadingProfiles = false;
        _error = context.l10n.couldntReadTheLocalProfileList;
      });
    }
  }

  Future<void> _unlockProfile() async {
    final profileId = _selectedProfileId;
    if (_hasRelevantDatabaseQuarantine) {
      _requireDatabaseRecovery();
      return;
    }
    if (_storageRecoveryRequired ||
        _busy ||
        profileId == null ||
        _password.text.isEmpty) {
      return;
    }
    _pendingProfileId = profileId;
    setState(() {
      _busy = true;
      _error = null;
      _status = context.l10n.verifyingTheLocalProfileAndChecking;
    });
    UnlockedLocalProfile? unlocked;
    LocalVaultDatabase? database;
    try {
      final serviceUnlocked =
          await _runLocalStorageOperation<UnlockedLocalProfile>(
            () => widget.service.unlock(
              profileId: profileId,
              password: _password.text,
            ),
            onQuarantinedResult: (profile) => profile.lock(),
          );
      unlocked = serviceUnlocked;
      _throwIfStorageRecoveryRequired();
      _password.clear();
      final openedDatabase =
          await _runLocalStorageOperation<LocalVaultDatabase>(
            () => _databaseFactory(
              serviceUnlocked,
              mode: LocalVaultOpenMode.openExisting,
            ),
            onQuarantinedResult: (opened) async {
              try {
                await opened.close();
              } on Object {
                // The local storage delegate may already be unavailable.
              }
            },
          );
      database = openedDatabase;
      _throwIfStorageRecoveryRequired();
      final repository = LocalHostRepository(
        database: openedDatabase,
        profile: serviceUnlocked,
        crypto: widget.crypto,
      );
      final journals = await _runLocalStorageOperation(
        repository.listMigrationJournals,
      );
      final cancelableIds = await _findCancelablePreparations(
        repository,
        journals,
      );
      if (!mounted || _storageRecoveryRequired) {
        await _closeLocalSession(serviceUnlocked, openedDatabase);
        return;
      }
      setState(() {
        _profile = serviceUnlocked;
        _database = openedDatabase;
        _repository = repository;
        _journals = journals;
        _cancelableMigrationIds = cancelableIds;
        _busy = false;
        _status = null;
        _pendingProfileId = null;
        final frozen = journals.where((item) => item.state == 'frozen');
        if (frozen.length == 1) _activeMigrationId = frozen.single.migrationId;
      });
      unlocked = null;
      database = null;
    } on DatabaseRecoveryRequiredException {
      if (unlocked != null) await _closeLocalSession(unlocked, database);
      _pendingProfileId = null;
      if (!mounted || _storageRecoveryRequired) return;
      _requireDatabaseRecovery();
    } on Object {
      if (unlocked != null) await _closeLocalSession(unlocked, database);
      _pendingProfileId = null;
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = context.l10n.couldntUnlockOrVerifyThisLocal;
      });
    }
  }

  Future<void> _startMigration() async {
    final repository = _repository;
    final instanceId = widget.controller.instance?.instanceId;
    if (_storageRecoveryRequired || _busy || repository == null) return;
    if (instanceId == null) {
      setState(() => _error = context.l10n.theSyncServiceIdentityIsntVerified);
      return;
    }
    final name = _vaultName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.enterANameForTheNew);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = context.l10n.preflightingAllLocalRecordsWritesTo;
      _complete = false;
    });
    try {
      final prepared = await _runMigrationStep(
        () => widget.controller.prepareMigrationVaultCreation(name),
      );
      final migrationId = _migrationUuid.v4();
      final snapshot = await _runLocalStorageOperation(
        () => repository.prepareMigrationSnapshot(
          migrationId: migrationId,
          targetInstanceId: instanceId,
          targetVaultId: prepared.vaultId,
        ),
      );
      await _runLocalStorageOperation(
        () => repository.stageMigrationCreatePayload(
          migrationId: migrationId,
          payloadJson: prepared.payloadJson,
        ),
      );
      if (mounted) {
        setState(() {
          _activeMigrationId = migrationId;
          _totalCount = snapshot.items.length;
          _stagedCount = 0;
          _status = context.l10n.localDataWasFullyPreflightedAnd;
        });
      }
      await _continueMigration(snapshot, prepared.payloadJson);
    } on DatabaseRecoveryRequiredException {
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _error = context.l10n.migrationIncompleteTheSourceDataIs;
        _status = null;
      });
    } on Object {
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _error = context.l10n.migrationIncompleteTheSourceDataIs;
        _status = null;
      });
    } finally {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _busy = false);
      }
      if (!_storageRecoveryRequired) await _reloadJournals();
    }
  }

  Future<void> _resumeMigration(String migrationId) async {
    final repository = _repository;
    if (_storageRecoveryRequired || _busy || repository == null) return;
    setState(() {
      _busy = true;
      _activeMigrationId = migrationId;
      _error = null;
      _status = context.l10n.reVerifyingTheLocalSourceSnapshot;
      _complete = false;
    });
    try {
      final snapshot = await _runLocalStorageOperation(
        () => repository.readMigrationSnapshot(migrationId),
      );
      final payload = await _runLocalStorageOperation(
        () => repository.readMigrationCreatePayload(migrationId),
      );
      if (payload == null) {
        throw StateError(currentL10n.migrationPreparationHasntSavedTheVault);
      }
      if (mounted) {
        setState(() {
          _totalCount = snapshot.items.length;
          _status = context.l10n.localSourceSnapshotVerifiedResumingThe;
        });
      }
      await _continueMigration(snapshot, payload);
    } on DatabaseRecoveryRequiredException {
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _error = context.l10n.thisMigrationCantBeResumedSafely;
        _status = null;
      });
    } on Object {
      if (!mounted || _storageRecoveryRequired) return;
      setState(() {
        _error = context.l10n.thisMigrationCantBeResumedSafely;
        _status = null;
      });
    } finally {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _busy = false);
      }
      if (!_storageRecoveryRequired) await _reloadJournals();
    }
  }

  Future<void> _continueMigration(
    LocalMigrationSnapshot snapshot,
    String createPayload,
  ) async {
    final repository = _repository;
    final database = _database;
    if (repository == null || database == null) {
      throw StateError(context.l10n.theLocalProfileIsLocked);
    }
    final currentInstanceId = widget.controller.instance?.instanceId;
    if (snapshot.targetInstanceId != currentInstanceId) {
      throw StateError(context.l10n.theMigrationDestinationBelongsToA);
    }

    await _runMigrationStep(
      () => widget.controller.createOrResumeMigrationVault(
        vaultId: snapshot.targetVaultId,
        payloadJson: createPayload,
      ),
    );
    if (mounted) {
      setState(() => _status = context.l10n.confirmingTheSameDestinationVaultAnd);
    }
    await _runMigrationStep(
      () =>
          widget.controller.synchronizeMigrationTarget(snapshot.targetVaultId),
    );

    final staged = await _runLocalStorageOperation(
      () => repository.listStagedMigrationItems(snapshot.migrationId),
    );
    final stagedById = {for (final item in staged) item.recordId: item};
    if (stagedById.length != staged.length ||
        staged.length > snapshot.items.length) {
      throw StateError(currentL10n.theMigrationJournalContainsDuplicateOr);
    }
    final sourceById = {for (final item in snapshot.items) item.recordId: item};
    for (final item in staged) {
      final source = sourceById[item.recordId];
      if (source == null ||
          source.sourceRevisionId != item.sourceRevisionId ||
          source.recordType != item.recordType) {
        throw StateError(currentL10n.theMigrationJournalDoesntMatchThe);
      }
    }
    await _verifyStagedTargetState(snapshot: snapshot, stagedById: stagedById);

    // Stable dependency order keeps referential records available as early as
    // possible when the target is observed by another approved device.
    final ordered = [...snapshot.items]
      ..sort((left, right) {
        final byKind = _migrationKindOrder(
          left.recordType,
        ).compareTo(_migrationKindOrder(right.recordType));
        return byKind != 0 ? byKind : left.recordId.compareTo(right.recordId);
      });
    for (final source in ordered) {
      var stagedItem = stagedById[source.recordId];
      if (stagedItem == null) {
        if (mounted) {
          setState(() {
            _status = context.l10n.encryptingAndStagingRecordsWithThe;
            _stagedCount = stagedById.length;
          });
        }
        final envelope = await _runMigrationStep(
          () => widget.controller.encryptMigrationRecord(
            targetVaultId: snapshot.targetVaultId,
            recordId: source.recordId,
            plaintext: Map<String, Object?>.from(source.plaintext),
          ),
        );
        final envelopeJson = canonicalJson(envelope);
        final newlyStagedItem =
            await _runLocalStorageOperation<LocalMigrationStagedItem>(
              () => repository.stageMigrationItem(
                migrationId: snapshot.migrationId,
                recordId: source.recordId,
                sourceRevisionId: source.sourceRevisionId,
                recordType: source.recordType,
                targetEnvelopeJson: envelopeJson,
              ),
            );
        stagedItem = newlyStagedItem;
        stagedById[source.recordId] = newlyStagedItem;
      }
      final targetEnvelope = jsonDecode(stagedItem.targetEnvelopeJson);
      if (targetEnvelope is! Map ||
          targetEnvelope.keys.any((key) => key is! String)) {
        throw FormatException(currentL10n.theStagedDestinationCiphertextHasAn);
      }
      await _runMigrationStep(
        () => widget.controller.enqueueMigrationEnvelope(
          targetVaultId: snapshot.targetVaultId,
          envelope: Map<String, Object?>.from(targetEnvelope),
        ),
      );
      if (mounted) {
        setState(() {
          _stagedCount = stagedById.length;
          _status =
              context.l10n.countCount2EncryptedRecordsSafelyStaged(stagedById.length, snapshot.items.length);
        });
      }
    }

    if (mounted) setState(() => _status = context.l10n.syncingEncryptedRecordsToTheNew);
    await _runMigrationStep(
      () =>
          widget.controller.synchronizeMigrationTarget(snapshot.targetVaultId),
    );

    var allCommitted = true;
    for (final source in ordered) {
      final item = stagedById[source.recordId];
      if (item == null) throw StateError(currentL10n.migrationCiphertextStagingIsIncomplete);
      final decoded = jsonDecode(item.targetEnvelopeJson);
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw FormatException(currentL10n.theStagedDestinationCiphertextHasAn);
      }
      final result = await _runMigrationStep(
        () => widget.controller.enqueueMigrationEnvelope(
          targetVaultId: snapshot.targetVaultId,
          envelope: Map<String, Object?>.from(decoded),
        ),
      );
      if (result != ExactCreateOperationResult.committed) allCommitted = false;
    }
    if (!allCommitted) {
      if (mounted) {
        setState(() {
          _status = context.l10n.recordsAreSavedEncryptedInThe;
        });
      }
      return;
    }

    await _verifyStagedTargetState(
      snapshot: snapshot,
      stagedById: stagedById,
      requireAllCommitted: true,
    );
    await _runLocalStorageOperation(
      () => repository.finishMigration(snapshot.migrationId),
    );
    if (mounted) {
      setState(() {
        _complete = true;
        _status = context.l10n.migrationCompleteTheServerConfirmedEvery;
      });
    }
  }

  Future<void> _verifyStagedTargetState({
    required LocalMigrationSnapshot snapshot,
    required Map<String, LocalMigrationStagedItem> stagedById,
    bool requireAllCommitted = false,
  }) async {
    if (_database == null) throw StateError(context.l10n.theLocalProfileIsLocked);
    if (widget.controller.preferenceError != null) {
      throw StateError(context.l10n.theDestinationVaultsSyncPreferencesConflict);
    }
    final instance = widget.controller.instance;
    if (instance == null || instance.instanceId != snapshot.targetInstanceId) {
      throw StateError(context.l10n.theMigrationDestinationBelongsToA);
    }
    final database = widget.controller.database;
    final cached = await _runMigrationStep(
      () => database.cachedEnvelopes(
        snapshot.targetVaultId,
        instanceId: instance.instanceId,
        serverSpaceId: instance.serverSpaceId,
      ),
    );
    final pending = await _runMigrationStep(
      () => database.allPendingOperations(
        snapshot.targetVaultId,
        instanceId: instance.instanceId,
        serverSpaceId: instance.serverSpaceId,
      ),
    );
    validateLocalMigrationTargetState(
      cached: cached,
      pending: pending,
      stagedById: stagedById,
      requireAllCommitted: requireAllCommitted,
    );
  }

  int _migrationKindOrder(String kind) => switch (kind) {
    'credential' => 0,
    'group' => 1,
    'snippet' => 2,
    'preference' => 3,
    'host' => 4,
    _ => 99,
  };

  Future<void> _cancelIncompletePreparation(
    LocalMigrationJournalSummary journal,
  ) async {
    final repository = _repository;
    if (_storageRecoveryRequired || _busy || repository == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = await _runLocalStorageOperation(
        () => repository.readMigrationCreatePayload(journal.migrationId),
      );
      final staged = await _runLocalStorageOperation(
        () => repository.listStagedMigrationItems(journal.migrationId),
      );
      if (payload != null || staged.isNotEmpty) {
        throw StateError(currentL10n.destinationDataIsAlreadyStagedThis);
      }
      await _runLocalStorageOperation(
        () => repository.cancelMigration(journal.migrationId),
      );
      if (mounted) {
        setState(() {
          _activeMigrationId = null;
          _status = context.l10n.noVaultCreationRequestWasSent;
        });
      }
    } on DatabaseRecoveryRequiredException {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _error = context.l10n.thisMigrationCantBeCancelledSafely);
      }
    } on Object {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _error = context.l10n.thisMigrationCantBeCancelledSafely);
      }
    } finally {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _busy = false);
      }
      if (!_storageRecoveryRequired) await _reloadJournals();
    }
  }

  Future<void> _abandonMigration(LocalMigrationJournalSummary journal) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.stopMigrationAndKeepLocalData),
        content: Text(
          context.l10n.theLocalSourceWillBecomeWritable,
        ),
        actions: [
          TextButton(
            key: const ValueKey('migration_abandon_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.continueMigration),
          ),
          FilledButton(
            key: const ValueKey('migration_abandon_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.stopAndKeepBoth),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _storageRecoveryRequired) return;
    final repository = _repository;
    if (_storageRecoveryRequired || _busy || repository == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _runLocalStorageOperation(
        () => repository.abandonMigration(journal.migrationId),
      );
      if (mounted) {
        setState(() {
          _activeMigrationId = null;
          _complete = false;
          _status = context.l10n.migrationStoppedTheLocalSourceData;
        });
      }
    } on DatabaseRecoveryRequiredException {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _error = context.l10n.couldntStopTheMigrationTheSource);
      }
    } on Object {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _error = context.l10n.couldntStopTheMigrationTheSource);
      }
    } finally {
      if (mounted && !_storageRecoveryRequired) {
        setState(() => _busy = false);
      }
      if (!_storageRecoveryRequired) await _reloadJournals();
    }
  }

  Future<void> _reloadJournals() async {
    final repository = _repository;
    if (_storageRecoveryRequired || repository == null) return;
    try {
      final journals = await _runLocalStorageOperation(
        repository.listMigrationJournals,
      );
      if (_storageRecoveryRequired) return;
      final cancelableIds = await _findCancelablePreparations(
        repository,
        journals,
      );
      if (!mounted) return;
      setState(() {
        _journals = journals;
        _cancelableMigrationIds = cancelableIds;
        final active = journals.where((item) => item.state == 'frozen');
        _activeMigrationId = active.length == 1
            ? active.single.migrationId
            : null;
      });
    } on DatabaseRecoveryRequiredException {
      if (!_storageRecoveryRequired) _requireDatabaseRecovery();
    } on Object {
      // Keep the last safely loaded journal summaries visible.
    }
  }

  Future<Set<String>> _findCancelablePreparations(
    LocalHostRepository repository,
    List<LocalMigrationJournalSummary> journals,
  ) async {
    final result = <String>{};
    for (final journal in journals) {
      if (_storageRecoveryRequired) {
        throw const DatabaseRecoveryRequiredException();
      }
      if (journal.state != 'frozen' || journal.stagedItemCount != 0) continue;
      try {
        if (await _runLocalStorageOperation(
              () => repository.readMigrationCreatePayload(journal.migrationId),
            ) ==
            null) {
          result.add(journal.migrationId);
        }
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        // A damaged or unavailable journal must never be offered for cancel.
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (_storageRecoveryRequired) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.migrateLocalProfiles)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: appDialogWidth(context, 560)),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.storage_rounded, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.aLocalStorageWriteWasInterrupted,
                      key: const ValueKey('migration_storage_recovery_message'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.45),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      key: const ValueKey('migration_storage_reload'),
                      onPressed: () => unawaited(_reloadPage()),
                      icon: const Icon(Icons.refresh),
                      label: Text(context.l10n.reloadPage),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.migrateLocalProfiles),
        leading: IconButton(
          key: const ValueKey('migration_close'),
          tooltip: context.l10n.close,
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: appDialogWidth(context, 780)),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
              children: [
                Text(
                  context.l10n.moveLocalEncryptedRecordsToA,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 9),
                Text(
                  context.l10n.theClientDecryptsAndValidatesEvery,
                  style: TextStyle(color: context.palette.muted, height: 1.5),
                ),
                const SizedBox(height: 18),
                if (_loadingProfiles)
                  const Center(child: CircularProgressIndicator())
                else if (_profile == null)
                  _buildUnlockCard()
                else ...[
                  _buildLocalProfileCard(),
                  const SizedBox(height: 12),
                  if (_activeMigrationId == null) _buildStartCard(),
                  ..._journals.map(_buildJournalCard),
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    _StatusCard(
                      text: _status!,
                      busy: _busy,
                      complete: _complete,
                      stagedCount: _stagedCount,
                      totalCount: _totalCount,
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: _MessageCard(error: true, text: _error!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.unlockALocalOnlyProfile,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (_profiles.isEmpty)
            Text(
              context.l10n.noLocalOnlyProfileExistsIn,
              style: TextStyle(color: context.palette.muted, height: 1.45),
            )
          else ...[
            DropdownButtonFormField<String>(
              key: const ValueKey('migration_profile_select'),
              initialValue: _selectedProfileId,
              decoration: InputDecoration(labelText: context.l10n.localProfile),
              items: _profiles
                  .map(
                    (profile) => DropdownMenuItem(
                      value: profile.profileId,
                      child: Text(
                        context.l10n.localProfileSubstring(profile.createdAt.toLocal().toIso8601String().substring(0, 10)),
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _busy ? null : _selectProfile,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('migration_profile_password'),
              controller: _password,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.l10n.localProfilePassword,
              ),
              onSubmitted: (_) => _unlockProfile(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('migration_unlock'),
              onPressed: _busy ? null : _unlockProfile,
              icon: const Icon(Icons.lock_open_outlined),
              label: Text(context.l10n.unlockAndValidate),
            ),
          ],
        ],
      ),
    ),
  );

  void _selectProfile(String? profileId) {
    if (_storageRecoveryRequired) return;
    setState(() => _selectedProfileId = profileId);
    if (_hasRelevantDatabaseQuarantine) _requireDatabaseRecovery();
  }

  Widget _buildLocalProfileCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: context.palette.teal),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.localProfileUnlockedCountResumableMigration(_journals.where((item) => item.state == 'frozen').length),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _lockLocalProfile,
            child: Text(context.l10n.lock),
          ),
        ],
      ),
    ),
  );

  Widget _buildStartCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.startANewMigration,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            context.l10n.allLocalRecordsArePreflightedBefore,
            style: TextStyle(color: context.palette.muted, height: 1.45),
          ),
          const SizedBox(height: 11),
          TextField(
            key: const ValueKey('migration_vault_name'),
            controller: _vaultName,
            enabled: !_busy,
            maxLength: 64,
            decoration: InputDecoration(labelText: context.l10n.newSyncVaultName),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('migration_start'),
            onPressed: _busy ? null : _startMigration,
            icon: const Icon(Icons.sync_alt_rounded),
            label: Text(context.l10n.preflightAndMigrate),
          ),
        ],
      ),
    ),
  );

  Widget _buildJournalCard(LocalMigrationJournalSummary journal) {
    final frozen = journal.state == 'frozen';
    final done = journal.state == 'completed';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              done
                  ? context.l10n.migrationCompleted
                  : frozen
                  ? context.l10n.migrationNeedsRecovery
                  : context.l10n.migrationStoppedLocalSourceKept,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.stageditemcountItemcountEncryptedRecordsStagedTarget(journal.stagedItemCount, journal.itemCount, journal.targetVaultId.substring(0, 8)),
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (frozen) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: ValueKey('migration_resume_${journal.migrationId}'),
                    onPressed: _busy
                        ? null
                        : () => _resumeMigration(journal.migrationId),
                    icon: const Icon(Icons.replay_rounded),
                    label: Text(context.l10n.continueMigration),
                  ),
                  if (_cancelableMigrationIds.contains(journal.migrationId))
                    TextButton(
                      key: ValueKey('migration_cancel_${journal.migrationId}'),
                      onPressed: _busy
                          ? null
                          : () => _cancelIncompletePreparation(journal),
                      child: Text(context.l10n.cancelEmptyPreparation),
                    )
                  else
                    TextButton(
                      key: ValueKey('migration_abandon_${journal.migrationId}'),
                      onPressed: _busy
                          ? null
                          : () => _abandonMigration(journal),
                      child: Text(context.l10n.stopAndKeepLocalData),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _lockLocalProfile() async {
    final profile = _profile;
    final database = _database;
    if (_busy || profile == null) return;
    setState(() => _busy = true);
    await _closeLocalSession(profile, database);
    if (!mounted) return;
    setState(() {
      _profile = null;
      _database = null;
      _repository = null;
      _journals = const [];
      _activeMigrationId = null;
      _busy = false;
      _status = null;
      _error = null;
    });
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.text,
    required this.busy,
    required this.complete,
    required this.stagedCount,
    required this.totalCount,
  });

  final String text;
  final bool busy;
  final bool complete;
  final int stagedCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  complete ? Icons.cloud_done_outlined : Icons.sync_outlined,
                  color: complete ? context.palette.teal : context.palette.orange,
                ),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
            ],
          ),
          if (totalCount > 0) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: (stagedCount / totalCount).clamp(0, 1).toDouble(),
              color: complete ? context.palette.teal : context.palette.lime,
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.stagedcountTotalcountEncryptedRecordsStaged(stagedCount, totalCount),
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
          ],
        ],
      ),
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.error, required this.text});
  final bool error;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    color: error
        ? context.palette.red.withValues(alpha: .12)
        : context.palette.teal.withValues(alpha: .12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Text(text, style: const TextStyle(height: 1.4)),
    ),
  );
}
