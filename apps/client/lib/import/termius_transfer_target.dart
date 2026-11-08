/// Where a Termius transfer reads from and applies to.
///
/// Both adapters use the existing encrypted repositories: the Cloud adapter
/// goes through [AppController] (signed, encrypted, outbox-synced records) and
/// the Local adapter through [LocalHostRepository] (profile-bound encrypted
/// envelopes). Neither writes anything until [TermiusTransferTarget.apply].
library;

import '../app_controller.dart';
import '../domain/models.dart';
import '../storage/local_host_repository.dart';
import 'termius_transfer.dart';

enum TermiusApplyFailure {
  /// The target is read-only (no writes were attempted).
  readOnly,

  /// The catalog changed after the preview (no writes were attempted).
  stalePlan,

  /// The Vault/profile changed while applying.
  contextChanged,

  /// A repository write failed.
  writeFailed,
}

/// Raised by [TermiusTransferTarget.apply]. The written counts are records
/// confirmed created before the failure; [rolledBack] is true only when every
/// one of them was removed again AND no write was left in an unknown state.
class TermiusApplyException implements Exception {
  const TermiusApplyException(
    this.failure, {
    this.writtenHosts = 0,
    this.writtenGroups = 0,
    this.writtenCredentials = 0,
    this.rolledBack = true,
  });

  final TermiusApplyFailure failure;
  final int writtenHosts;
  final int writtenGroups;
  final int writtenCredentials;
  final bool rolledBack;

  /// True whenever records (including Keychain Credentials) may remain.
  bool get mutatedTarget => !rolledBack;

  @override
  String toString() =>
      'TermiusApplyException(${failure.name}, hosts: $writtenHosts, '
      'groups: $writtenGroups, credentials: $writtenCredentials, '
      'rolledBack: $rolledBack)';
}

class TermiusApplyReport {
  const TermiusApplyReport({
    required this.createdHosts,
    required this.createdGroups,
    this.createdCredentials = 0,
  });

  final int createdHosts;
  final int createdGroups;
  final int createdCredentials;
}

abstract interface class TermiusTransferTarget {
  /// False means export-only.
  bool get canWrite;

  /// Identity of the Vault/profile; apply aborts when it changes.
  String? get contextKey;

  Future<TermiusCatalog> loadCatalog();

  Future<TermiusApplyReport> apply(TermiusImportPlan plan);
}

/// Shared apply algorithm: validate freshness, write groups parent-first then
/// hosts in jump order, and compensate (delete what was created, newest
/// first, only at the exact revision this apply created) if a write fails.
abstract class TermiusTransferTargetBase implements TermiusTransferTarget {
  /// Opaque identity of the repository lifetime writes are bound to.
  Object? get writeScope;

  /// Creates a new record only while [scope] is current; returns its revision.
  Future<String> createGroup(GroupRecord group, Object scope);
  Future<String> createHost(HostRecord host, Object scope);
  Future<String> createCredential(CredentialRecord credential, Object scope);

  /// Deletes a record this apply created, only at [revisionId] and in [scope].
  Future<void> removeCreated(
    RecordKind kind,
    String id,
    String revisionId,
    Object scope,
  );

  /// Whether a record exists in [scope] (proves a failed create's outcome).
  Future<bool> recordExists(RecordKind kind, String id, Object scope);

  /// Called once after a successful or compensated apply.
  Future<void> afterApply() async {}

  bool _sameScope(Object scope) => identical(writeScope, scope);

  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) async {
    if (!canWrite) {
      throw const TermiusApplyException(TermiusApplyFailure.readOnly);
    }
    if (!plan.canApply) {
      throw const TermiusApplyException(TermiusApplyFailure.stalePlan);
    }
    final scope = writeScope;
    if (scope == null) {
      throw const TermiusApplyException(TermiusApplyFailure.stalePlan);
    }
    final catalog = await loadCatalog();
    if (!_sameScope(scope) || catalog.fingerprint != plan.catalogFingerprint) {
      throw const TermiusApplyException(TermiusApplyFailure.stalePlan);
    }
    final hosts = orderHostsForCreation(plan.hostsToCreate, {
      for (final host in catalog.hosts) host.id,
    });
    final created = <({RecordKind kind, String id, String revision})>[];
    ({RecordKind kind, String id})? inFlight;
    try {
      for (final group in plan.newGroups) {
        if (!_sameScope(scope)) {
          throw const TermiusApplyException(TermiusApplyFailure.contextChanged);
        }
        inFlight = (kind: RecordKind.group, id: group.id);
        final revision = await createGroup(group, scope);
        inFlight = null;
        created.add((kind: RecordKind.group, id: group.id, revision: revision));
      }
      for (final credential in plan.newCredentials) {
        if (!_sameScope(scope)) {
          throw const TermiusApplyException(TermiusApplyFailure.contextChanged);
        }
        inFlight = (kind: RecordKind.credential, id: credential.id);
        final revision = await createCredential(credential, scope);
        inFlight = null;
        created.add((
          kind: RecordKind.credential,
          id: credential.id,
          revision: revision,
        ));
      }
      for (final host in hosts) {
        if (!_sameScope(scope)) {
          throw const TermiusApplyException(TermiusApplyFailure.contextChanged);
        }
        inFlight = (kind: RecordKind.host, id: host.id);
        final revision = await createHost(host, scope);
        inFlight = null;
        created.add((kind: RecordKind.host, id: host.id, revision: revision));
      }
      if (!_sameScope(scope)) {
        throw const TermiusApplyException(TermiusApplyFailure.contextChanged);
      }
    } on Object catch (error) {
      final scopeLost = !_sameScope(scope);
      final failure = scopeLost
          ? TermiusApplyFailure.contextChanged
          : error is TermiusApplyException
          ? error.failure
          : TermiusApplyFailure.writeFailed;
      // A create that failed may still have committed (commit-then-throw).
      // Only a proven absence in the same scope counts as clean; a present
      // record is kept (its revision is unproven) and reported.
      var rolledBack = true;
      final pending = inFlight;
      var keptInFlight = <RecordKind, int>{};
      if (pending != null) {
        if (scopeLost) {
          rolledBack = false;
        } else {
          try {
            if (await recordExists(pending.kind, pending.id, scope)) {
              rolledBack = false;
              keptInFlight = {pending.kind: 1};
            }
          } on Object {
            rolledBack = false;
          }
        }
      }
      if (scopeLost) {
        // Never delete through a different Vault/profile.
        rolledBack = rolledBack && created.isEmpty;
      } else {
        for (final record in created.reversed) {
          try {
            await removeCreated(record.kind, record.id, record.revision, scope);
          } on Object {
            // Changed or referenced since creation: leave it, report partial.
            rolledBack = false;
          }
        }
      }
      try {
        await afterApply();
      } on Object {
        // Refresh failures do not change the apply outcome.
      }
      int written(RecordKind kind) =>
          created.where((r) => r.kind == kind).length +
          (keptInFlight[kind] ?? 0);
      throw TermiusApplyException(
        failure,
        writtenHosts: written(RecordKind.host),
        writtenGroups: written(RecordKind.group),
        writtenCredentials: written(RecordKind.credential),
        rolledBack: rolledBack,
      );
    }
    await afterApply();
    return TermiusApplyReport(
      createdHosts: created.where((r) => r.kind == RecordKind.host).length,
      createdGroups: created.where((r) => r.kind == RecordKind.group).length,
      createdCredentials: created
          .where((r) => r.kind == RecordKind.credential)
          .length,
    );
  }
}

/// Server Vault target through [AppController]. Every write and compensating
/// delete is scope-checked inside the controller's mutation queue.
class CloudTermiusTransferTarget extends TermiusTransferTargetBase {
  CloudTermiusTransferTarget(this.app);

  final AppController app;

  @override
  bool get canWrite =>
      app.activeVault?.canWrite == true && app.activeVault?.status == 'active';

  @override
  String? get contextKey => app.activeVault?.id;

  @override
  Object? get writeScope => app.recordWriteScope;

  @override
  Future<TermiusCatalog> loadCatalog() async => TermiusCatalog(
    hosts: List.of(app.hosts),
    groups: List.of(app.groups),
    credentials: List.of(app.credentials),
  );

  @override
  Future<String> createGroup(GroupRecord group, Object scope) =>
      app.createGroupInScope(group, scope: scope);

  @override
  Future<String> createHost(HostRecord host, Object scope) =>
      app.createHostInScope(host, scope: scope);

  @override
  Future<String> createCredential(CredentialRecord credential, Object scope) =>
      app.createCredentialInScope(credential, scope: scope);

  @override
  Future<bool> recordExists(RecordKind kind, String id, Object scope) =>
      app.recordExistsInScope(id, scope: scope);

  @override
  Future<void> removeCreated(
    RecordKind kind,
    String id,
    String revisionId,
    Object scope,
  ) => app.deleteCreatedRecordAtRevision(
    recordId: id,
    kind: kind,
    revisionId: revisionId,
    scope: scope,
  );
}

/// Local-only profile target through [LocalHostRepository]. Deletes use the
/// repository's revision CAS, so a concurrently edited record is kept.
class LocalTermiusTransferTarget extends TermiusTransferTargetBase {
  LocalTermiusTransferTarget(this.repository, {this.onChanged});

  final LocalHostRepository repository;

  /// Lets the owning screen reload its lists after an apply.
  final Future<void> Function()? onChanged;

  @override
  bool get canWrite => true;

  @override
  String? get contextKey => repository.localVaultId;

  @override
  Object? get writeScope => repository;

  @override
  Future<TermiusCatalog> loadCatalog() async {
    final hosts = await repository.listHosts();
    final groups = await repository.listGroups();
    final credentials = await repository.listCredentials();
    return TermiusCatalog(
      hosts: hosts,
      groups: [for (final group in groups) group.group],
      credentials: credentials,
    );
  }

  @override
  Future<String> createGroup(GroupRecord group, Object scope) async =>
      (await repository.createGroup(group)).revisionId;

  @override
  Future<String> createCredential(
    CredentialRecord credential,
    Object scope,
  ) async {
    final saved = await repository.createCredential(credential);
    final revision = saved.revisionId;
    if (revision == null) throw StateError('Local Credential revision missing.');
    return revision;
  }

  @override
  Future<String> createHost(HostRecord host, Object scope) async {
    final saved = await repository.createHost(host, recordId: host.id);
    final revision = saved.revisionId;
    if (revision == null) throw StateError('Local Host revision missing.');
    return revision;
  }

  @override
  Future<void> removeCreated(
    RecordKind kind,
    String id,
    String revisionId,
    Object scope,
  ) => switch (kind) {
    RecordKind.host => repository.deleteHost(
      recordId: id,
      baseRevisionId: revisionId,
    ),
    RecordKind.group => repository.deleteGroup(
      recordId: id,
      baseRevisionId: revisionId,
    ),
    _ => repository.deleteCredential(recordId: id, baseRevisionId: revisionId),
  };

  @override
  Future<bool> recordExists(RecordKind kind, String id, Object scope) async =>
      switch (kind) {
        RecordKind.host => await repository.getHost(id) != null,
        RecordKind.group => await repository.getGroup(id) != null,
        _ => await repository.getCredential(id) != null,
      };

  @override
  Future<void> afterApply() async => onChanged?.call();
}
