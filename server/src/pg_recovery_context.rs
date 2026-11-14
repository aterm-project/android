//! PostgreSQL recovery context and historical membership verification helpers.
//!
//! This module only reads and updates the Recovery rows and validates the
//! public membership history needed to identify an account's recoverable Vault
//! key contexts. It never decrypts any Recovery or Vault envelope.

use std::collections::{BTreeMap, BTreeSet};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction};

use crate::{
    ApiError,
    recovery::{Context, PresentContext, RecoveryDescriptor},
};

const MAX_KEY_ENVELOPES: usize = 1000;
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;

/// Returns the current Recovery descriptor, if Recovery is enabled for this
/// account. The identity envelope is opaque serialized JSON as in SQLite.
pub(crate) async fn descriptor(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<Option<RecoveryDescriptor>, ApiError> {
    let row = sqlx::query(
        "SELECT recovery_generation,recovery_public_signing_key,\
                recovery_public_encryption_key,recovery_identity_envelope \
         FROM account_recovery WHERE user_id=$1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    row.map(|row| {
        Ok(RecoveryDescriptor {
            generation: row
                .try_get("recovery_generation")
                .map_err(ApiError::internal)?,
            public_signing_key: row
                .try_get("recovery_public_signing_key")
                .map_err(ApiError::internal)?,
            public_encryption_key: row
                .try_get("recovery_public_encryption_key")
                .map_err(ApiError::internal)?,
            identity_envelope: row
                .try_get("recovery_identity_envelope")
                .map_err(ApiError::internal)?,
        })
    })
    .transpose()
}

/// Returns the persistent generation counter. Accounts without a counter have
/// not configured Recovery and begin at generation zero.
pub(crate) async fn last_generation(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<i64, ApiError> {
    Ok(sqlx::query_scalar::<_, i64>(
        "SELECT last_generation FROM account_recovery_generation WHERE user_id=$1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .unwrap_or(0))
}

pub(crate) async fn save_generation(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    generation: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO account_recovery_generation(user_id,last_generation) VALUES($1,$2) \
         ON CONFLICT(user_id) DO UPDATE SET last_generation=EXCLUDED.last_generation",
    )
    .bind(user_id)
    .bind(generation)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn validate_membership_chain(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    expected_version: i64,
    active_user_id: &str,
) -> Result<BTreeMap<i64, i64>, ApiError> {
    let rows = sqlx::query(
        "SELECT membership_version,previous_digest,manifest_json::text AS manifest_json,\
                digest,signer_device_id,signature \
         FROM membership_manifests WHERE vault_id=$1 ORDER BY membership_version",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let expected_count = usize::try_from(expected_version).ok();
    if expected_version < 1 || expected_count != Some(rows.len()) {
        return Err(ApiError::internal("membership history is incomplete"));
    }

    let mut previous: Option<String> = None;
    let mut active_version = 0_i64;
    let mut active_key_versions = BTreeMap::<i64, i64>::new();

    for (index, row) in rows.iter().enumerate() {
        let version: i64 = row
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        if version != index as i64 + 1 {
            return Err(ApiError::internal("membership history version is invalid"));
        }

        let previous_digest: Option<String> =
            row.try_get("previous_digest").map_err(ApiError::internal)?;
        if previous_digest != previous {
            return Err(ApiError::internal(
                "membership history digest chain is invalid",
            ));
        }

        let stored: String = row.try_get("manifest_json").map_err(ApiError::internal)?;
        let record: Value = serde_json::from_str(&stored).map_err(ApiError::internal)?;
        let manifest = record
            .get("manifest")
            .cloned()
            .ok_or_else(|| ApiError::internal("membership history manifest is missing"))?;
        let signature: String = row.try_get("signature").map_err(ApiError::internal)?;
        let record_signature = record
            .get("signature")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::internal("membership history signature is missing"))?;
        if signature != record_signature
            || record.get("vault_id").and_then(Value::as_str) != Some(vault_id)
            || crate::auth::as_counter(record.get("membership_version").unwrap_or(&Value::Null))
                != Some(version)
        {
            return Err(ApiError::internal(
                "membership history record is inconsistent",
            ));
        }

        let record_previous = match record.get("previous_digest") {
            Some(Value::Null) | None => None,
            Some(Value::String(value)) => Some(value.clone()),
            _ => {
                return Err(ApiError::internal(
                    "membership history previous digest is invalid",
                ));
            }
        };
        if record_previous != previous_digest {
            return Err(ApiError::internal(
                "membership history previous digest is inconsistent",
            ));
        }

        let payload = json!({
            "vault_id": vault_id,
            "membership_version": version,
            "previous_digest": previous_digest,
            "manifest": manifest,
        });
        let payload_bytes = crate::jcs(&payload)?;
        let digest = crate::sha256_hex(&payload_bytes);
        let stored_digest: String = row.try_get("digest").map_err(ApiError::internal)?;
        if stored_digest != digest {
            return Err(ApiError::internal("membership history digest is invalid"));
        }

        let signer_id: String = row
            .try_get("signer_device_id")
            .map_err(ApiError::internal)?;
        // A purged member's device row may be gone while signed Vault history
        // remains. Device IDs are globally unique; archive lookup is therefore
        // scoped by this Vault to avoid borrowing another Vault's archive.
        let signer_key: Option<String> = sqlx::query_scalar(
            "SELECT signing_public_key FROM devices WHERE device_id=$1 \
             UNION ALL \
             SELECT signing_public_key FROM vault_device_archives \
             WHERE vault_id=$2 AND device_id=$1 \
             LIMIT 1",
        )
        .bind(&signer_id)
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let signer_key =
            signer_key.ok_or_else(|| ApiError::internal("membership signer key is unavailable"))?;
        crate::auth::verify_key_signature(&signer_key, &signature, &payload_bytes)
            .map_err(|_| ApiError::internal("membership history signature is invalid"))?;

        let members = manifest
            .get("members")
            .and_then(Value::as_array)
            .ok_or_else(|| ApiError::internal("membership history member list is invalid"))?;
        let user_is_active = members.iter().any(|member| {
            member.get("user_id").and_then(Value::as_str) == Some(active_user_id)
                && member.get("state").and_then(Value::as_str) == Some("active")
        });
        if user_is_active {
            active_version = version;
            if let Some(epoch) = manifest
                .get("key_epoch")
                .and_then(crate::auth::as_counter)
                .filter(|epoch| *epoch > 0)
            {
                active_key_versions.insert(epoch, version);
            }
        }
        previous = Some(digest);
    }

    if active_version != expected_version {
        return Err(ApiError::internal(
            "active vault member is absent from signed history",
        ));
    }
    Ok(active_key_versions)
}

/// Computes every readable historical key epoch plus each active epoch for
/// this account, validating the complete signed membership chain first.
pub(crate) async fn required_contexts(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<Vec<Context>, ApiError> {
    let vault_rows = sqlx::query(
        "SELECT v.vault_id,v.active_epoch,v.membership_version \
         FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id \
         WHERE vm.user_id=$1 AND vm.state='active' \
           AND v.state IN ('active','deleting') \
         ORDER BY v.vault_id",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let mut contexts = BTreeMap::<(String, i64), i64>::new();
    let mut membership_by_vault = BTreeMap::<String, BTreeMap<i64, i64>>::new();
    let mut active_epochs = BTreeMap::<String, i64>::new();

    for row in &vault_rows {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let active_epoch: i64 = row.try_get("active_epoch").map_err(ApiError::internal)?;
        let current_version: i64 = row
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let versions = validate_membership_chain(tx, &vault_id, current_version, user_id).await?;
        if versions.get(&active_epoch) != Some(&current_version) {
            return Err(ApiError::internal(
                "active Vault epoch lacks a current signed membership manifest",
            ));
        }
        active_epochs.insert(vault_id.clone(), active_epoch);
        membership_by_vault.insert(vault_id, versions);
    }

    let epochs = sqlx::query(
        "SELECT DISTINCT e.vault_id,e.epoch \
         FROM vault_key_envelopes e \
         JOIN vaults v ON v.vault_id=e.vault_id \
         JOIN vault_members vm ON vm.vault_id=e.vault_id \
                              AND vm.user_id=e.recipient_user_id \
         WHERE e.recipient_user_id=$1 AND vm.state='active' \
           AND v.state IN ('active','deleting') \
         ORDER BY e.vault_id,e.epoch",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    for row in epochs {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let epoch: i64 = row.try_get("epoch").map_err(ApiError::internal)?;
        if epoch <= 0 {
            return Err(ApiError::internal("stored vault key epoch is invalid"));
        }
        let membership_version = *membership_by_vault
            .get(&vault_id)
            .and_then(|versions| versions.get(&epoch))
            .ok_or_else(|| {
                ApiError::internal(
                    "historical Vault epoch has no validated active membership manifest",
                )
            })?;
        contexts
            .entry((vault_id, epoch))
            .or_insert(membership_version);
    }

    for (vault_id, epoch) in active_epochs {
        let membership_version = *membership_by_vault
            .get(&vault_id)
            .and_then(|versions| versions.get(&epoch))
            .ok_or_else(|| {
                ApiError::internal("active Vault epoch has no validated membership version")
            })?;
        contexts
            .entry((vault_id, epoch))
            .or_insert(membership_version);
    }

    if contexts.len() > MAX_KEY_ENVELOPES {
        return Err(ApiError::conflict(
            "RECOVERY_CONTEXT_LIMIT",
            "account has too many Vault key contexts for recovery",
        ));
    }

    Ok(contexts
        .into_iter()
        .map(|((vault_id, key_epoch), membership_version)| Context {
            vault_id,
            key_epoch,
            membership_version,
        })
        .collect())
}

fn recovery_box_bytes(envelope: &Value) -> Result<Vec<u8>, ApiError> {
    let object = envelope
        .as_object()
        .ok_or_else(|| ApiError::internal("stored recovery key envelope is invalid"))?;
    if object.len() != 3
        || envelope.get("version").and_then(Value::as_i64) != Some(1)
        || envelope.get("suite").and_then(Value::as_str) != Some("crypto_box_seal")
    {
        return Err(ApiError::internal(
            "stored recovery key envelope has an invalid shape",
        ));
    }
    let ciphertext = envelope
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::internal("stored recovery key envelope ciphertext is missing"))?;
    let raw = URL_SAFE_NO_PAD
        .decode(ciphertext)
        .map_err(|_| ApiError::internal("stored recovery key envelope encoding is invalid"))?;
    if raw.len() < 48 || raw.len() > MAX_ENVELOPE_BYTES {
        return Err(ApiError::internal(
            "stored recovery key envelope size is invalid",
        ));
    }
    Ok(raw)
}

pub(crate) async fn present_contexts(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    generation: i64,
) -> Result<Vec<PresentContext>, ApiError> {
    let rows = sqlx::query(
        "SELECT vault_id,key_epoch,envelope,recovery_signature,uploader_device_id \
         FROM account_recovery_key_envelopes \
         WHERE user_id=$1 AND recovery_generation=$2 \
         ORDER BY vault_id,key_epoch",
    )
    .bind(user_id)
    .bind(generation)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let envelope_json: String = row.try_get("envelope").map_err(ApiError::internal)?;
        let envelope: Value = serde_json::from_str(&envelope_json).map_err(ApiError::internal)?;
        let envelope_sha256 = crate::sha256_hex(&recovery_box_bytes(&envelope)?);
        result.push(PresentContext {
            vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
            key_epoch: row.try_get("key_epoch").map_err(ApiError::internal)?,
            envelope,
            envelope_sha256,
            recovery_signature: row
                .try_get("recovery_signature")
                .map_err(ApiError::internal)?,
            uploader_device_id: row
                .try_get("uploader_device_id")
                .map_err(ApiError::internal)?,
        });
    }
    Ok(result)
}

pub(crate) async fn context_holding_device(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    device_id: &str,
    vault_id: &str,
    epoch: i64,
) -> Result<bool, ApiError> {
    let exists: Option<i64> = sqlx::query_scalar(
        "SELECT 1::BIGINT FROM vault_key_envelopes \
         WHERE recipient_user_id=$1 AND recipient_device_id=$2 \
           AND vault_id=$3 AND epoch=$4",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(vault_id)
    .bind(epoch)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(exists.is_some())
}

/// Ensures every required context still has at least one syntactically
/// readable source envelope for this account. This is checked in completion's
/// final writer transaction so a missing row causes an atomic stale failure.
pub(crate) async fn ensure_readable_source_key_envelopes(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    required: &BTreeMap<(String, i64), i64>,
) -> Result<(), ApiError> {
    let rows = sqlx::query(
        "SELECT e.vault_id,e.epoch,e.envelope::text AS envelope \
         FROM vault_key_envelopes e \
         JOIN devices d ON d.device_id=e.recipient_device_id \
         WHERE e.recipient_user_id=$1 AND d.user_id=$1",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let mut readable = BTreeSet::new();
    for row in rows {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let epoch: i64 = row.try_get("epoch").map_err(ApiError::internal)?;
        let envelope_json: String = row.try_get("envelope").map_err(ApiError::internal)?;
        if serde_json::from_str::<Value>(&envelope_json).is_ok_and(|value| value.is_object()) {
            readable.insert((vault_id, epoch));
        }
    }

    if required.keys().any(|context| !readable.contains(context)) {
        return Err(ApiError::conflict(
            "RECOVERY_STALE",
            "the account Vault key context changed; refresh recovery data and retry",
        ));
    }
    Ok(())
}
