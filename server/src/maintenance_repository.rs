//! Backend-owned transactions for server-side retention and payload maintenance.
//!
//! Per-Vault event retention commits independently; snapshot/upload/object
//! catalogue bookkeeping remains one transaction. External provider deletion
//! runs only after that transaction commits, through the durable delete queue.

use std::{future::Future, pin::Pin};

use sqlx::{Row, SqlitePool};

use crate::{ApiError, object_store::ObjectStore};

pub(crate) struct PayloadCleanupCommand {
    pub(crate) object_store: ObjectStore,
    pub(crate) instance_id: String,
    pub(crate) now_text: String,
    pub(crate) now_epoch: i64,
    pub(crate) audit_cutoff: i64,
}

type MaintenanceFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub(crate) trait MaintenanceRepository: Send + Sync {
    fn compact_history_events(&self, cutoff: String)
    -> MaintenanceFuture<'_, Result<(), ApiError>>;

    fn compact_expired_payloads(
        &self,
        command: PayloadCleanupCommand,
    ) -> MaintenanceFuture<'_, Result<(), ApiError>>;
}

pub(crate) struct SqliteMaintenanceRepository {
    pool: SqlitePool,
}

impl SqliteMaintenanceRepository {
    pub(crate) fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    async fn compact_history_events_sqlite(&self, cutoff: String) -> Result<(), ApiError> {
        let vaults: Vec<String> =
            sqlx::query_scalar("SELECT vault_id FROM vault_counters ORDER BY vault_id")
                .fetch_all(&self.pool)
                .await
                .map_err(ApiError::internal)?;

        for vault_id in vaults {
            let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
            // Reserve this Vault's writer order before reading the event
            // high-watermark. Page readers and sync writes then see either
            // the complete old prefix/floor or the complete new one.
            sqlx::query(
                "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
            )
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let high: i64 = sqlx::query_scalar(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
            )
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let previous_floor: i64 = sqlx::query_scalar(
                "SELECT minimum_available_seq FROM vault_counters WHERE vault_id=?",
            )
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            // Prune by sequence prefix, not timestamp predicate: timestamps
            // may move backwards, and deleting sparse rows would make a
            // cursor silently skip events that were never returned.
            let first_fresh: Option<i64> = sqlx::query_scalar(
                "SELECT MIN(commit_seq) FROM change_events WHERE vault_id=? AND created_at>=?",
            )
            .bind(&vault_id)
            .bind(&cutoff)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let next_floor = if let Some(first_fresh) = first_fresh {
                sqlx::query("DELETE FROM change_events WHERE vault_id=? AND commit_seq<?")
                    .bind(&vault_id)
                    .bind(first_fresh)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                first_fresh
            } else {
                sqlx::query("DELETE FROM change_events WHERE vault_id=? AND commit_seq<=?")
                    .bind(&vault_id)
                    .bind(high)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                high.saturating_add(1)
            };
            let floor = previous_floor.max(next_floor);
            sqlx::query("UPDATE vault_counters SET minimum_available_seq=? WHERE vault_id=?")
                .bind(floor)
                .bind(&vault_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
        Ok(())
    }

    async fn compact_expired_payloads_sqlite(
        &self,
        command: PayloadCleanupCommand,
    ) -> Result<(), ApiError> {
        let PayloadCleanupCommand {
            object_store,
            instance_id,
            now_text,
            now_epoch,
            audit_cutoff,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query(
            "DELETE FROM snapshot_items WHERE snapshot_id IN (SELECT snapshot_id FROM snapshots WHERE expires_at<=?)",
        )
        .bind(&now_text)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "UPDATE snapshots SET manifest_json='[]',snapshot_item_count=0,snapshot_manifest_format='expired' WHERE expires_at<=? AND (manifest_json!='[]' OR snapshot_item_count!=0 OR snapshot_manifest_format!='expired')",
        )
        .bind(&now_text)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        object_store
            .queue_expired_completions_tx(&mut tx, &instance_id, &now_text, now_epoch)
            .await?;
        sqlx::query("UPDATE uploads SET state='expired' WHERE state='open' AND expires_at<=?")
            .bind(&now_text)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM upload_chunks WHERE upload_id IN (SELECT upload_id FROM uploads WHERE state='expired')")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        // Finalize upload metadata before making blobs collectible. Keeping
        // reachability checks, delete intents and catalogue state together
        // prevents a reference insert from racing with GC bookkeeping.
        sqlx::query("UPDATE uploads SET state='collected' WHERE state='completed' AND EXISTS (SELECT 1 FROM blob_objects b WHERE b.vault_id=uploads.vault_id AND b.object_id=uploads.object_id AND b.gc_after IS NOT NULL AND b.gc_after<=? AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id))")
            .bind(now_epoch)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let external_gc = sqlx::query(
            "SELECT storage_backend,storage_key,storage_store_id,size,sha256 FROM blob_objects b \
             WHERE storage_backend IN ('s3','filesystem') AND storage_state='available' AND gc_after IS NOT NULL AND gc_after<=? \
             AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id)",
        )
        .bind(now_epoch)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        for object in external_gc {
            let key: String = object.get("storage_key");
            let storage_backend: String = object.get("storage_backend");
            let store_id: String = object.get("storage_store_id");
            let size: i64 = object.get("size");
            let digest: String = object.get("sha256");
            crate::object_store::ObjectStore::queue_external_delete_tx(
                &mut tx,
                &storage_backend,
                &store_id,
                &key,
                size,
                &digest,
                now_epoch,
            )
            .await?;
        }
        sqlx::query("UPDATE blob_objects SET storage_state='deleting' WHERE storage_backend IN ('s3','filesystem') AND storage_state='available' AND gc_after IS NOT NULL AND gc_after<=? AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=blob_objects.vault_id AND r.object_id=blob_objects.object_id)")
            .bind(now_epoch)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM blob_objects WHERE storage_backend='sqlite' AND gc_after IS NOT NULL AND gc_after<=? AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=blob_objects.vault_id AND r.object_id=blob_objects.object_id)")
            .bind(now_epoch)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        // Completed uploads no longer need their temporary chunk payloads.
        sqlx::query("DELETE FROM upload_chunks WHERE upload_id IN (SELECT upload_id FROM uploads WHERE state IN ('expired','completed','collected'))")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        // Retain only the recent one-use ticket issuance window used by the
        // account/session throttles, including consumed Relay tickets.
        let ticket_cutoff = now_epoch.saturating_sub(60);
        sqlx::query("DELETE FROM notification_tickets WHERE expires_at<=? OR created_at<=?")
            .bind(now_epoch)
            .bind(ticket_cutoff)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::relay::prune_tickets_tx(&mut tx, ticket_cutoff).await?;
        crate::audit::prune_expired_tx(&mut tx, audit_cutoff).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(())
    }
}

impl MaintenanceRepository for SqliteMaintenanceRepository {
    fn compact_history_events(
        &self,
        cutoff: String,
    ) -> MaintenanceFuture<'_, Result<(), ApiError>> {
        Box::pin(self.compact_history_events_sqlite(cutoff))
    }

    fn compact_expired_payloads(
        &self,
        command: PayloadCleanupCommand,
    ) -> MaintenanceFuture<'_, Result<(), ApiError>> {
        Box::pin(self.compact_expired_payloads_sqlite(command))
    }
}
