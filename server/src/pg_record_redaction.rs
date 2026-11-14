//! PostgreSQL helpers for the RECORD-REDACTION-v1 read protocol.
//!
//! This module deliberately provides projection and compatibility helpers
//! only. It does not implement or authorize a purge transaction.

use std::sync::Arc;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use uuid::Uuid;

use crate::{ApiError, InstanceInfo, auth::AuthUser};

const PROOF_FORMAT: &str = "atermius-record-redaction-proof-v1";

#[derive(Clone)]
pub(crate) struct PgRedactionProofSigner {
    instance: InstanceInfo,
    signing_key: Arc<SigningKey>,
}

#[derive(Clone, Debug)]
pub(crate) struct RedactionStatement {
    pub(crate) redaction_id: String,
    pub(crate) vault_id: String,
    pub(crate) record_id: String,
    pub(crate) deleted_revision_id: String,
    pub(crate) deleted_seq: i64,
    pub(crate) redaction_seq: i64,
}

impl PgRedactionProofSigner {
    pub(crate) fn new(instance: InstanceInfo, signing_key: Arc<SigningKey>) -> Self {
        Self {
            instance,
            signing_key,
        }
    }

    pub(crate) fn proof(&self, statement: &RedactionStatement) -> Result<Value, ApiError> {
        for id in [
            &self.instance.instance_id,
            &self.instance.server_space_id,
            &statement.vault_id,
            &statement.record_id,
            &statement.deleted_revision_id,
            &statement.redaction_id,
        ] {
            let parsed = Uuid::parse_str(id).map_err(ApiError::internal)?;
            if parsed.to_string() != *id {
                return Err(ApiError::internal("redaction identifier is not canonical"));
            }
        }
        if statement.deleted_seq <= 0 || statement.redaction_seq <= statement.deleted_seq {
            return Err(ApiError::internal("redaction sequence is invalid"));
        }
        let public_key = URL_SAFE_NO_PAD.encode(self.signing_key.verifying_key().as_bytes());
        if public_key != self.instance.signing_public_key {
            return Err(ApiError::internal(
                "instance signing identity does not match the active signing key",
            ));
        }
        let mut unsigned = json!({
            "format": PROOF_FORMAT,
            "redaction_id": statement.redaction_id,
            "instance_id": self.instance.instance_id,
            "server_space_id": self.instance.server_space_id,
            "vault_id": statement.vault_id,
            "record_id": statement.record_id,
            "deleted_revision_id": statement.deleted_revision_id,
            "deleted_seq": statement.deleted_seq.to_string(),
            "redaction_seq": statement.redaction_seq.to_string(),
            "signing_public_key": self.instance.signing_public_key,
        });
        let signature = self.signing_key.sign(&crate::jcs(&unsigned)?);
        unsigned["signature"] = json!(URL_SAFE_NO_PAD.encode(signature.to_bytes()));
        Ok(unsigned)
    }

    pub(crate) fn graveyard_item(&self, statement: &RedactionStatement) -> Result<Value, ApiError> {
        Ok(json!({
            "kind": "graveyard",
            "record_id": statement.record_id,
            "deleted_revision_id": statement.deleted_revision_id,
            "deleted_seq": statement.deleted_seq.to_string(),
            "redaction": self.proof(statement)?,
        }))
    }
}

pub(crate) fn redaction_columns(alias: &str) -> String {
    format!(
        "{alias}.redaction_id AS rr_redaction_id,{alias}.vault_id AS rr_vault_id,\
         {alias}.record_id AS rr_record_id,{alias}.deleted_revision_id AS rr_deleted_revision_id,\
         {alias}.deleted_seq AS rr_deleted_seq,{alias}.redaction_seq AS rr_redaction_seq"
    )
}

pub(crate) fn redaction_from_join_row(row: &PgRow) -> Result<Option<RedactionStatement>, ApiError> {
    let Some(redaction_id) = row
        .try_get::<Option<String>, _>("rr_redaction_id")
        .map_err(ApiError::internal)?
    else {
        return Ok(None);
    };
    Ok(Some(RedactionStatement {
        redaction_id,
        vault_id: row
            .try_get::<Option<String>, _>("rr_vault_id")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
        record_id: row
            .try_get::<Option<String>, _>("rr_record_id")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
        deleted_revision_id: row
            .try_get::<Option<String>, _>("rr_deleted_revision_id")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
        deleted_seq: row
            .try_get::<Option<i64>, _>("rr_deleted_seq")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
        redaction_seq: row
            .try_get::<Option<i64>, _>("rr_redaction_seq")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
    }))
}

pub(crate) async fn require_redaction_client_for_vault_tx(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let has_redactions: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=$1)")
            .bind(vault_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if has_redactions && !user.declares_sync_redaction_v1 {
        return Err(ApiError::new(
            axum::http::StatusCode::UPGRADE_REQUIRED,
            "CLIENT_REDACTION_CAPABILITY_REQUIRED",
            "this Vault contains redacted records and requires a compatible client",
        ));
    }
    Ok(())
}

pub(crate) async fn reject_redacted_record_tx(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    record_id: &str,
) -> Result<(), ApiError> {
    let redacted: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=$1 AND record_id=$2)",
    )
    .bind(vault_id)
    .bind(record_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if redacted {
        return Err(ApiError::conflict(
            "RECORD_REDACTED",
            "record ID is permanently reserved by a redaction",
        ));
    }
    Ok(())
}

pub(crate) fn record_redacted_error(
    signer: &PgRedactionProofSigner,
    statement: &RedactionStatement,
) -> Result<ApiError, ApiError> {
    let proof = signer.proof(statement)?;
    Ok(ApiError::gone(
        "RECORD_REDACTED",
        "the requested revision belongs to a redacted record",
    )
    .with_details(json!({"redaction":proof})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    #[test]
    fn proof_is_jcs_signed_by_the_current_instance_key() {
        let key = Arc::new(SigningKey::from_bytes(&[0x37; 32]));
        let instance = InstanceInfo {
            instance_id: "3a25ea6e-53f5-47b6-9d82-97c43acb8a0b".to_owned(),
            server_space_id: "60fa13ac-45b6-449a-a980-b83d77a0f5b0".to_owned(),
            generation: "af428ab9-7f94-4207-8ec1-ab0f1f47b69a".to_owned(),
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
            signing_key_transitions: Vec::new(),
        };
        let signer = PgRedactionProofSigner::new(instance, key.clone());
        let proof = signer
            .proof(&RedactionStatement {
                redaction_id: "818deeba-9dbe-4854-8dad-479d341217ec".to_owned(),
                vault_id: "e950523f-c2bd-42fb-a66c-d9c87d86d331".to_owned(),
                record_id: "e1f825e6-a166-47de-a953-3b9facf16a9e".to_owned(),
                deleted_revision_id: "00df06aa-1bdb-4c7c-8e8d-a7d6abce45b4".to_owned(),
                deleted_seq: 7,
                redaction_seq: 8,
            })
            .unwrap();

        let signature_bytes = URL_SAFE_NO_PAD
            .decode(proof["signature"].as_str().unwrap())
            .unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&signature_bytes).unwrap();
        let mut unsigned = proof;
        unsigned.as_object_mut().unwrap().remove("signature");
        key.verifying_key()
            .verify(&crate::jcs(&unsigned).unwrap(), &signature)
            .unwrap();
    }
}
