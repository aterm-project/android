//! Composite PostgreSQL implementation of the complete sync repository trait.
//!
//! Construct this only with a `PgPool` whose dedicated schema is provisioned
//! with PostgreSQL migrations `0001` through `0032` and present on that pool's
//! `search_path`. The SQL migration files are intentionally separate from the
//! SQLite `./migrations` directory. The explicit restricted sync-core runtime
//! composes this repository after schema and shared-key validation. Separate
//! lifecycle repositories also wire bootstrap/registration and auth sessions,
//! account/Vault reads, device enrollment/capability/revocation, Vault creation,
//! invitations/member lifecycle/key rotation/ownership transfer/deletion,
//! account deletion, and Recovery. These are bounded route capabilities, not
//! general PostgreSQL parity: ordinary object upload/download and full object
//! GC and ordinary MFA flows, general admin/maintenance and
//! collaboration APIs, backup/restore, HA, and other unported management
//! operations remain blocked.

use ed25519_dalek::SigningKey;
use serde_json::Value;
use sqlx::PgPool;

use crate::{
    ApiError,
    pg_record_redaction::PgRedactionProofSigner,
    pg_sync_auth::PgSyncAuthRepository,
    pg_sync_commit::PgSyncCommitRepository,
    pg_sync_conflict_read::{
        PgSyncConflictChangesReadRepository, SyncConflictChangesReadRepository,
    },
    pg_sync_conflict_write::{PgSyncConflictWriteRepository, SyncConflictWriteRepository},
    pg_sync_history_read::{PgSyncHistoryReadRepository, SyncHistoryReadRepository},
    pg_sync_read::{PgSyncChangesReadRepository, SyncChangesReadRepository},
    pg_sync_snapshots::{PgSyncSnapshotsRepository, SyncSnapshotsRepository},
    sync_repository::{
        ChangesPageCommand, ConflictChangesPageCommand, CreateConflictCommand,
        CreateSnapshotCommand, HistoryPageCommand, PushCommit, ReadRevisionCommand,
        ReadSnapshotCommand, RepositoryFuture, ResolveConflictCommand, SyncCommitRepository,
        SyncRepository,
    },
};

/// Full sync-trait composition over PostgreSQL-backed bounded capabilities.
/// All components receive clones of this same pool, so they share its
/// connection configuration and dedicated `search_path`.
pub(crate) struct PgSyncRepository {
    // Keep the source pool explicit as the ownership/configuration boundary;
    // each capability below owns a clone of the same underlying `PgPool`.
    _pool: PgPool,
    commit: PgSyncCommitRepository,
    auth: PgSyncAuthRepository,
    changes: PgSyncChangesReadRepository,
    conflict_changes: PgSyncConflictChangesReadRepository,
    history: PgSyncHistoryReadRepository,
    snapshots: PgSyncSnapshotsRepository,
    conflict_write: PgSyncConflictWriteRepository,
}

impl PgSyncRepository {
    /// Creates a composition for an already-provisioned dedicated PG schema.
    /// Runtime startup validates the schema and shared instance keys first.
    pub(crate) fn new(
        pool: PgPool,
        instance: crate::InstanceInfo,
        signing_key: std::sync::Arc<SigningKey>,
    ) -> Self {
        let proof_signer = PgRedactionProofSigner::new(instance, signing_key);
        Self {
            _pool: pool.clone(),
            commit: PgSyncCommitRepository::new(pool.clone()),
            auth: PgSyncAuthRepository::new(pool.clone()),
            changes: PgSyncChangesReadRepository::with_signer(pool.clone(), proof_signer.clone()),
            conflict_changes: PgSyncConflictChangesReadRepository::with_signer(
                pool.clone(),
                proof_signer.clone(),
            ),
            history: PgSyncHistoryReadRepository::with_signer(pool.clone(), proof_signer.clone()),
            snapshots: PgSyncSnapshotsRepository::with_signer(pool.clone(), proof_signer),
            conflict_write: PgSyncConflictWriteRepository::new(pool),
        }
    }
}

impl SyncCommitRepository for PgSyncRepository {
    fn commit_batch(&self, command: PushCommit) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.commit.commit_batch(command)
    }
}

impl SyncRepository for PgSyncRepository {
    fn active_device_signing_key(
        &self,
        user_id: String,
        device_id: String,
    ) -> RepositoryFuture<'_, Result<Option<String>, ApiError>> {
        Box::pin(async move {
            self.auth
                .active_device_signing_key(&user_id, &device_id)
                .await
        })
    }

    fn read_changes_page(
        &self,
        command: ChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.changes.read_changes_page(command)
    }

    fn read_conflict_changes_page(
        &self,
        command: ConflictChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.conflict_changes.read_conflict_changes_page(command)
    }

    fn read_history_page(
        &self,
        command: HistoryPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.history.read_history_page(command)
    }

    fn read_snapshot(
        &self,
        command: ReadSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.snapshots.read_snapshot(command)
    }

    fn read_revision(
        &self,
        command: ReadRevisionCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.history.read_revision(command)
    }

    fn create_snapshot(
        &self,
        command: CreateSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.snapshots.create_snapshot(command)
    }

    fn resolve_conflict(
        &self,
        command: ResolveConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.conflict_write.resolve_conflict(command)
    }

    fn create_conflict(
        &self,
        command: CreateConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        self.conflict_write.create_conflict(command)
    }
}

#[cfg(test)]
mod tests {
    use super::PgSyncRepository;
    use crate::sync_repository::{SyncCommitRepository, SyncRepository};

    fn assert_sync_contract<T: SyncRepository + SyncCommitRepository>() {}

    #[test]
    fn pg_repository_implements_the_complete_sync_contract() {
        assert_sync_contract::<PgSyncRepository>();
    }
}
