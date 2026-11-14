use super::*;

use crate::{AuthRateLimits, Config, control, open_state, secure_file};
use axum::http::StatusCode;
use chrono::{Duration, Utc};
use ed25519_dalek::{Signer, SigningKey as Ed25519SigningKey};
use rand::{RngCore, rngs::OsRng};
use serde_json::{Value, json};
use sqlx::SqlitePool;
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration as StdDuration};
use tokio::task::JoinHandle;
use uuid::Uuid;

const CURRENT_RECOVERY_GENERATION: i64 = 4;
const TARGET_RECOVERY_GENERATION: i64 = CURRENT_RECOVERY_GENERATION + 1;
const TEST_TIMEOUT: StdDuration = StdDuration::from_secs(30);

struct Fixture {
    state: crate::AppState,
    account_id: String,
    old_device_id: String,
    new_device_id: String,
    vault_id: String,
    request_id: i64,
    challenge_id: String,
    operation_id: String,
    request: CompleteRequest,
    now_epoch: i64,
}

fn config(data_dir: PathBuf) -> Config {
    Config {
        backup_archive_dir: None,
        backup_key_file: None,
        mfa_encryption_key_file: None,
        database_key_file: None,
        backup_retention_count: None,
        backup_replication_env: crate::BackupReplicationEnv::default(),
        data_dir,
        registration_open: false,
        guacd_address: None,
        relay_enabled: false,
        terminal_collaboration_enabled: false,
        relay_allow_cidrs: Vec::new(),
        relay_allow_ports: Vec::new(),
        relay_max_connections_per_user: 4,
        public_origin: None,
        web_dir: None,
        max_object_bytes: 64 * 1024 * 1024,
        max_request_bytes: 1024 * 1024,
        history_retention_days: 90,
        record_restore_retention_days: 30,
        vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
        account_deletion_grace_seconds: 7 * 24 * 60 * 60,
        audit_retention_days: 365,
        object_gc_grace_seconds: 7 * 24 * 60 * 60,
        admin_usernames: Vec::new(),
        auth_rate_limits: AuthRateLimits::default(),
    }
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0_u8; N];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

fn b64(bytes: impl AsRef<[u8]>) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

fn sign(key: &Ed25519SigningKey, bytes: &[u8]) -> String {
    b64(key.sign(bytes).to_bytes())
}

fn opaque_envelope(ciphertext_size: usize) -> Value {
    json!({
        "version": 1,
        "suite": "xchacha20-poly1305-ietf",
        "nonce": b64(random::<24>()),
        "ciphertext": b64(random_vec(ciphertext_size)),
    })
}

fn random_vec(size: usize) -> Vec<u8> {
    let mut bytes = vec![0_u8; size];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

fn crypto_box_envelope() -> Value {
    json!({
        "version": 1,
        "suite": "crypto_box_seal",
        "ciphertext": b64(random::<48>()),
    })
}

fn recovery_box(
    state: &crate::AppState,
    account_id: &str,
    generation: i64,
    signing_key: &Ed25519SigningKey,
    encryption_public_key: &str,
    vault_id: &str,
    device_id: &str,
) -> RecoveryKeyEnvelope {
    let envelope = crypto_box_envelope();
    let ciphertext = URL_SAFE_NO_PAD
        .decode(envelope["ciphertext"].as_str().unwrap())
        .unwrap();
    let signing_public_key = b64(signing_key.verifying_key().to_bytes());
    let recovery_descriptor = descriptor_hash(
        state,
        account_id,
        generation,
        &signing_public_key,
        encryption_public_key,
    )
    .unwrap();
    let payload = recovery_box_payload(
        state,
        account_id,
        generation,
        &recovery_descriptor,
        vault_id,
        1,
        &envelope,
        device_id,
    )
    .unwrap();
    RecoveryKeyEnvelope {
        vault_id: vault_id.to_owned(),
        key_epoch: 1,
        envelope,
        uploader_device_id: device_id.to_owned(),
        envelope_sha256: Some(crate::sha256_hex(&ciphertext)),
        recovery_signature: sign(signing_key, &crate::jcs(&payload).unwrap()),
    }
}

async fn make_fixture(label: &str) -> Fixture {
    let data_dir = std::env::temp_dir().join(format!(
        "atermius-recovery-purge-{label}-{}",
        Uuid::new_v4()
    ));
    secure_file::create_private_data_dir(&data_dir).unwrap();
    let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
    let state = open_state(&database_url, config(data_dir)).await.unwrap();

    let account_id = Uuid::new_v4().to_string();
    let old_device_id = Uuid::new_v4().to_string();
    let new_device_id = Uuid::new_v4().to_string();
    let vault_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    let family_id = Uuid::new_v4().to_string();
    let challenge_id = Uuid::new_v4().to_string();
    let operation_id = Uuid::new_v4().to_string();
    let username = format!("recovery-purge-{label}-{}@example.test", Uuid::new_v4());
    let now = Utc::now();
    let now_epoch = now.timestamp();
    let now_text = now.to_rfc3339();
    let session_expiry = (now + Duration::hours(1)).to_rfc3339();
    let old_device_signer = Ed25519SigningKey::generate(&mut OsRng);
    let old_device_signing_public_key = b64(old_device_signer.verifying_key().to_bytes());
    let old_device_encryption_public_key = b64(random::<32>());
    let recovery_signer = Ed25519SigningKey::generate(&mut OsRng);
    let recovery_signing_public_key = b64(recovery_signer.verifying_key().to_bytes());
    let recovery_encryption_public_key = b64(random::<32>());
    let new_device_signer = Ed25519SigningKey::generate(&mut OsRng);
    let new_device_signing_public_key = b64(new_device_signer.verifying_key().to_bytes());
    let new_device_encryption_public_key = b64(random::<32>());
    let next_recovery_signer = Ed25519SigningKey::generate(&mut OsRng);
    let next_recovery_signing_public_key = b64(next_recovery_signer.verifying_key().to_bytes());
    let next_recovery_encryption_public_key = b64(random::<32>());
    let challenge = random::<32>();

    sqlx::query("INSERT INTO users(user_id,username,status,created_at) VALUES(?,?,'active',?)")
        .bind(&account_id)
        .bind(&username)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO auth_credentials(user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope,credential_version) VALUES(?,'old-hash','old-salt','{}','{}',7)")
        .bind(&account_id)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status,created_at) VALUES(?,?, 'old recovery device', ?, ?, 'active', ?)")
        .bind(&old_device_id)
        .bind(&account_id)
        .bind(&old_device_signing_public_key)
        .bind(&old_device_encryption_public_key)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
        .bind(&session_id)
        .bind(&account_id)
        .bind(&old_device_id)
        .bind(&family_id)
        .bind("old-access-hash")
        .bind("old-refresh-hash")
        .bind(&session_expiry)
        .bind(&session_expiry)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();
    let relay_ticket_hash = crate::sha256_hex(Uuid::new_v4().to_string().as_bytes());
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at) VALUES(?,?,?,'127.0.0.1',22,?)")
        .bind(relay_ticket_hash)
        .bind(&account_id)
        .bind(&old_device_id)
        .bind(&session_expiry)
        .execute(&state.db)
        .await
        .unwrap();
    let notification_ticket_hash = crate::sha256_hex(Uuid::new_v4().to_string().as_bytes());
    sqlx::query("INSERT INTO notification_tickets(ticket_hash,user_id,device_id,session_id,server_generation,session_access_expires_at,created_at,expires_at,consumed_at) VALUES(?,?,?,?,?,?,?,?,NULL)")
        .bind(notification_ticket_hash)
        .bind(&account_id)
        .bind(&old_device_id)
        .bind(&session_id)
        .bind(&state.instance.generation)
        .bind(&session_expiry)
        .bind(now_epoch)
        .bind(now_epoch + 60)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version,created_at) VALUES(?,?,'deleting',1,1,?)")
        .bind(&vault_id)
        .bind(&account_id)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
        .bind(&vault_id)
        .bind(&account_id)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();

    let manifest = json!({
        "key_epoch": 1,
        "members": [{"user_id":account_id,"role":"owner","state":"active"}],
    });
    let manifest_payload = json!({
        "vault_id": vault_id,
        "membership_version": 1,
        "previous_digest": Value::Null,
        "manifest": manifest,
    });
    let manifest_signature = sign(&old_device_signer, &crate::jcs(&manifest_payload).unwrap());
    let manifest_digest = crate::sha256_hex(&crate::jcs(&manifest_payload).unwrap());
    let manifest_record = json!({
        "vault_id": vault_id,
        "membership_version": 1,
        "previous_digest": Value::Null,
        "manifest": manifest,
        "signature": manifest_signature,
    });
    sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,1,NULL,?,?,?,?,?)")
        .bind(&vault_id)
        .bind(manifest_record.to_string())
        .bind(&manifest_digest)
        .bind(&old_device_id)
        .bind(&manifest_signature)
        .bind(&now_text)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,1,?,?,?,'source-signature',?,1)")
        .bind(&vault_id)
        .bind(&account_id)
        .bind(&old_device_id)
        .bind(crypto_box_envelope().to_string())
        .bind(&old_device_id)
        .execute(&state.db)
        .await
        .unwrap();

    let old_recovery_envelope = opaque_envelope(528);
    let old_identity_envelope = opaque_envelope(96);
    sqlx::query("INSERT INTO account_recovery(user_id,recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)")
        .bind(&account_id)
        .bind(CURRENT_RECOVERY_GENERATION)
        .bind(&recovery_signing_public_key)
        .bind(&recovery_encryption_public_key)
        .bind(old_recovery_envelope.to_string())
        .bind(old_identity_envelope.to_string())
        .bind(now_epoch)
        .bind(now_epoch)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO account_recovery_generation(user_id,last_generation) VALUES(?,?)")
        .bind(&account_id)
        .bind(CURRENT_RECOVERY_GENERATION)
        .execute(&state.db)
        .await
        .unwrap();
    let old_box = recovery_box(
        &state,
        &account_id,
        CURRENT_RECOVERY_GENERATION,
        &recovery_signer,
        &recovery_encryption_public_key,
        &vault_id,
        &old_device_id,
    );
    sqlx::query("INSERT INTO account_recovery_key_envelopes(user_id,recovery_generation,vault_id,key_epoch,envelope,recovery_signature,uploader_device_id,created_at) VALUES(?,?,?,?,?,?,?,?)")
        .bind(&account_id)
        .bind(CURRENT_RECOVERY_GENERATION)
        .bind(&vault_id)
        .bind(1_i64)
        .bind(old_box.envelope.to_string())
        .bind(&old_box.recovery_signature)
        .bind(&old_device_id)
        .bind(now_epoch)
        .execute(&state.db)
        .await
        .unwrap();

    let challenge_hash = crate::sha256_hex(&challenge);
    let challenge_id_hash = crate::sha256_hex(challenge_id.as_bytes());
    sqlx::query("INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at) VALUES(?,?,?,?,?,NULL)")
        .bind(&challenge_id_hash)
        .bind(&challenge_hash)
        .bind(&account_id)
        .bind(CURRENT_RECOVERY_GENERATION)
        .bind(now_epoch + 600)
        .execute(&state.db)
        .await
        .unwrap();
    let request_id: i64 = sqlx::query_scalar("INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,'test-actor') RETURNING request_id")
        .bind(&vault_id)
        .bind(now_epoch - 60)
        .bind(now_epoch - 1)
        .fetch_one(&state.db)
        .await
        .unwrap();

    let target_vault_envelope = crypto_box_envelope();
    let target_vault_payload = json!({
        "vault_id": vault_id,
        "recipient_device_id": new_device_id,
        "key_epoch": 1,
        "membership_version": 1,
        "envelope": target_vault_envelope,
    });
    let target_vault_key_envelope = CompletionVaultKeyEnvelope {
        vault_id: vault_id.clone(),
        recipient_device_id: new_device_id.clone(),
        key_epoch: 1,
        membership_version: 1,
        envelope: target_vault_envelope,
        signature: sign(
            &new_device_signer,
            &crate::jcs(&target_vault_payload).unwrap(),
        ),
    };
    let next_box = recovery_box(
        &state,
        &account_id,
        TARGET_RECOVERY_GENERATION,
        &next_recovery_signer,
        &next_recovery_encryption_public_key,
        &vault_id,
        &new_device_id,
    );
    let next_recovery_envelope = opaque_envelope(528);
    let next_identity_envelope = opaque_envelope(96);
    let next_identity_proof = recovery_identity_proof_payload(
        &state,
        &account_id,
        TARGET_RECOVERY_GENERATION,
        &next_recovery_signing_public_key,
        &next_recovery_encryption_public_key,
        &next_recovery_envelope,
        &next_identity_envelope,
    )
    .unwrap();
    let mut request = CompleteRequest {
        operation_id: operation_id.clone(),
        account_id: account_id.clone(),
        instance_id: state.instance.instance_id.clone(),
        server_space_id: state.instance.server_space_id.clone(),
        recovery_generation: CURRENT_RECOVERY_GENERATION,
        challenge_id: challenge_id.clone(),
        challenge: b64(challenge),
        recovery_signature: String::new(),
        new_kdf: crate::auth::KdfParams {
            id: "argon2id13".into(),
            salt: b64(random::<16>()),
            mem_kib: 65_536,
            iterations: 3,
            parallelism: 1,
            version: 1,
        },
        new_login_verifier: b64(random::<32>()),
        account_key_envelope: json!({
            "version": 1,
            "nonce": b64(random::<24>()),
            "ciphertext": b64(random::<96>()),
        }),
        device: CompletionDevice {
            device_id: new_device_id.clone(),
            name: "Recovered race test device".into(),
            signing_public_key: new_device_signing_public_key.clone(),
            encryption_public_key: new_device_encryption_public_key,
            signature: String::new(),
        },
        vault_key_envelopes: vec![target_vault_key_envelope],
        next_recovery: NextRecovery {
            recovery_public_signing_key: next_recovery_signing_public_key,
            recovery_public_encryption_key: next_recovery_encryption_public_key,
            recovery_envelope: next_recovery_envelope.clone(),
            recovery_identity_envelope: next_identity_envelope.clone(),
            key_envelopes: vec![next_box],
            recovery_identity_proof_signature: sign(&next_recovery_signer, &next_identity_proof),
        },
    };
    let device_payload = json!({
        "account_id": account_id,
        "device_id": new_device_id,
        "encryption_public_key": request.device.encryption_public_key,
        "signing_public_key": request.device.signing_public_key,
    });
    request.device.signature = sign(&new_device_signer, &crate::jcs(&device_payload).unwrap());
    request.recovery_signature = sign(&recovery_signer, &complete_payload(&request).unwrap());

    Fixture {
        state,
        account_id,
        old_device_id,
        new_device_id,
        vault_id,
        request_id,
        challenge_id,
        operation_id,
        request,
        now_epoch,
    }
}

async fn scalar_i64(
    pool: &SqlitePool,
    sql: &str,
    first: &str,
    second: Option<&str>,
    third: Option<&str>,
) -> i64 {
    let query = sqlx::query_scalar::<_, i64>(sql).bind(first);
    let query = if let Some(second) = second {
        query.bind(second)
    } else {
        query
    };
    let query = if let Some(third) = third {
        query.bind(third)
    } else {
        query
    };
    query.fetch_one(pool).await.unwrap()
}

async fn credentials(pool: &SqlitePool, account_id: &str) -> (String, String, String, String, i64) {
    sqlx::query_as("SELECT login_verifier_hash,verifier_salt,kdf_json,account_key_envelope,credential_version FROM auth_credentials WHERE user_id=?")
        .bind(account_id)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn recovery_descriptor(
    pool: &SqlitePool,
    account_id: &str,
) -> (i64, String, String, String, String) {
    sqlx::query_as("SELECT recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope FROM account_recovery WHERE user_id=?")
        .bind(account_id)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn wait_gate(gate: &TestPause) {
    tokio::time::timeout(TEST_TIMEOUT, gate.wait_until_reached())
        .await
        .expect("transaction did not reach its test gate");
}

async fn join<T>(task: JoinHandle<T>) -> T {
    tokio::time::timeout(TEST_TIMEOUT, task)
        .await
        .expect("transaction task timed out")
        .expect("transaction task panicked")
}

#[tokio::test]
async fn completion_first_commits_before_due_purge_cascades_vault_key_material() {
    let fixture = make_fixture("completion-first").await;
    let completion_gate = Arc::new(TestPause::new());
    let purge_start_gate = Arc::new(TestPause::new());
    let purge_writer_gate = Arc::new(TestPause::new());
    let _release_completion = ReleasePauseOnDrop::new(completion_gate.clone());
    let _release_purge_start = ReleasePauseOnDrop::new(purge_start_gate.clone());
    let _release_purge_writer = ReleasePauseOnDrop::new(purge_writer_gate.clone());
    let completion_hooks = Arc::new(RecoveryPurgeTestHooks {
        completion_writer_reserved: Some(completion_gate.clone()),
        ..RecoveryPurgeTestHooks::default()
    });
    let purge_hooks = Arc::new(RecoveryPurgeTestHooks {
        purge_before_writer_reservation: Some(purge_start_gate.clone()),
        purge_writer_reserved: Some(purge_writer_gate.clone()),
        ..RecoveryPurgeTestHooks::default()
    });
    let peer: SocketAddr = "127.0.0.1:43101".parse().unwrap();
    let complete_task = tokio::spawn(complete_with_test_hooks(
        fixture.state.clone(),
        peer,
        fixture.request,
        completion_hooks,
    ));

    // Completion has the SQLite writer reservation before purge is allowed to
    // attempt its own writer UPDATE.
    wait_gate(&completion_gate).await;
    let purge_state = fixture.state.clone();
    let purge_task = tokio::spawn(async move {
        control::purge_due_vault_deletions_with_test_hooks(
            &purge_state,
            fixture.now_epoch,
            &purge_hooks,
        )
        .await
    });
    wait_gate(&purge_start_gate).await;
    purge_start_gate.release();
    completion_gate.release();

    let response = join(complete_task).await.unwrap().0;
    assert_eq!(response["status"], "recovered");
    assert_eq!(response["recovery_generation"], TARGET_RECOVERY_GENERATION);
    assert_eq!(response["device_id"], fixture.new_device_id);
    wait_gate(&purge_writer_gate).await;

    // Purge is now holding its writer transaction, but has not yet deleted the
    // Vault. Observe the complete commit independently from the later cascade.
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT recovery_generation FROM account_recovery WHERE user_id=?",
            &fixture.account_id,
            None,
            None,
        )
        .await,
        TARGET_RECOVERY_GENERATION
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT last_generation FROM account_recovery_generation WHERE user_id=?",
            &fixture.account_id,
            None,
            None,
        )
        .await,
        TARGET_RECOVERY_GENERATION
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT credential_version FROM auth_credentials WHERE user_id=?",
            &fixture.account_id,
            None,
            None,
        )
        .await,
        8
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM devices WHERE user_id=? AND device_id=? AND status='active'",
            &fixture.account_id,
            Some(&fixture.new_device_id),
            None,
        )
        .await,
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT revoked_at FROM devices WHERE user_id=? AND device_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.old_device_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap()
        .is_some(),
        true,
        "completion revokes the pre-existing device before purge"
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT revoked_at FROM sessions WHERE user_id=? AND device_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.old_device_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap()
        .is_some(),
        true,
        "completion revokes the pre-existing refresh/session family before purge"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM relay_tickets WHERE user_id=?")
            .bind(&fixture.account_id)
            .fetch_one(&fixture.state.db)
            .await
            .unwrap(),
        0,
        "completion clears pre-existing Relay tickets"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM notification_tickets WHERE user_id=?",)
            .bind(&fixture.account_id)
            .fetch_one(&fixture.state.db)
            .await
            .unwrap(),
        0,
        "completion clears pre-existing notification tickets"
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=? AND recipient_device_id=?",
            &fixture.vault_id,
            Some(&fixture.new_device_id),
            None,
        )
        .await,
        1
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM account_recovery_key_envelopes WHERE user_id=? AND recovery_generation=? AND vault_id=?",
            &fixture.account_id,
            Some(&TARGET_RECOVERY_GENERATION.to_string()),
            Some(&fixture.vault_id),
        )
        .await,
        1
    );

    purge_writer_gate.release();
    join(purge_task).await.unwrap();

    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM vaults WHERE vault_id=?",
            &fixture.vault_id,
            None,
            None,
        )
        .await,
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<i64>>(
            "SELECT purged_at FROM vault_deletion_requests WHERE request_id=?",
        )
        .bind(fixture.request_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap()
        .is_some(),
        true
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=?",
            &fixture.vault_id,
            None,
            None,
        )
        .await,
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM account_recovery_key_envelopes WHERE user_id=? AND vault_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.vault_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM devices WHERE user_id=? AND device_id=? AND status='active'",
            &fixture.account_id,
            Some(&fixture.new_device_id),
            None,
        )
        .await,
        1,
        "Vault purge retains the recovered account device"
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM account_recovery_receipts WHERE user_id=? AND operation_id=?",
            &fixture.account_id,
            Some(&fixture.operation_id),
            None,
        )
        .await,
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM account_recovery_challenges WHERE challenge_id_hash=? AND consumed_at IS NOT NULL",
        )
        .bind(crate::sha256_hex(fixture.challenge_id.as_bytes()))
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.account_recovered' AND resource_id=?",
        )
        .bind(&fixture.account_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        1
    );
    let (purge_count, purge_actor_user, purge_actor_device): (i64, Option<String>, Option<String>) =
        sqlx::query_as("SELECT COUNT(*),MAX(actor_user_id),MAX(actor_device_id) FROM audit_events WHERE action='vault.purged' AND resource_id=?")
            .bind(&fixture.vault_id)
            .fetch_one(&fixture.state.db)
            .await
            .unwrap();
    assert_eq!(purge_count, 1);
    assert_eq!(purge_actor_user, None);
    assert_eq!(purge_actor_device, None);
}

#[tokio::test]
async fn maintenance_prunes_recovery_challenges_in_batches_and_keeps_live_real_and_decoy_rows() {
    let fixture = make_fixture("maintenance-challenge-prune").await;
    let live_decoy_id_hash = crate::sha256_hex(Uuid::new_v4().to_string().as_bytes());
    let live_decoy_challenge_hash = crate::sha256_hex(b"live decoy challenge");
    sqlx::query(
        "INSERT INTO account_recovery_challenges(\
            challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at\
        ) VALUES(?,?,NULL,?,?,NULL)",
    )
    .bind(&live_decoy_id_hash)
    .bind(live_decoy_challenge_hash)
    .bind(CURRENT_RECOVERY_GENERATION)
    .bind(fixture.now_epoch + 600)
    .execute(&fixture.state.db)
    .await
    .unwrap();

    // More than one maintenance pass is needed. Alternate expired and
    // consumed rows and include both real owners and NULL-owner decoys.
    let mut tx = fixture.state.db.begin().await.unwrap();
    for index in 0..2501 {
        let challenge_id_hash = crate::sha256_hex(Uuid::new_v4().to_string().as_bytes());
        let challenge_hash = crate::sha256_hex(format!("challenge-{index}").as_bytes());
        let user_id = if index % 2 == 0 {
            Some(fixture.account_id.as_str())
        } else {
            None
        };
        let (expires_at, consumed_at) = if index % 2 == 0 {
            (fixture.now_epoch - 1, None)
        } else {
            (fixture.now_epoch + 600, Some(fixture.now_epoch))
        };
        sqlx::query(
            "INSERT INTO account_recovery_challenges(\
                challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at\
            ) VALUES(?,?,?,?,?,?)",
        )
        .bind(challenge_id_hash)
        .bind(challenge_hash)
        .bind(user_id)
        .bind(CURRENT_RECOVERY_GENERATION)
        .bind(expires_at)
        .bind(consumed_at)
        .execute(&mut *tx)
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();

    // Exercise the scheduled/operator maintenance entry point directly; no
    // subsequent Recovery /start request is involved in pruning. Each pass is
    // capped at four batches (2000 rows), leaving a backlog for the next pass.
    crate::run_maintenance(&fixture.state).await.unwrap();

    let remaining_stale: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM account_recovery_challenges WHERE expires_at<=? OR consumed_at IS NOT NULL",
    )
    .bind(Utc::now().timestamp())
    .fetch_one(&fixture.state.db)
    .await
    .unwrap();
    assert_eq!(
        remaining_stale, 501,
        "one pass removes no more than 2000 rows"
    );
    let total_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_recovery_challenges")
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
    assert_eq!(
        total_rows, 503,
        "the remaining backlog plus two live rows remain"
    );
    let decoy_owner: Option<String> = sqlx::query_scalar(
        "SELECT user_id FROM account_recovery_challenges WHERE challenge_id_hash=?",
    )
    .bind(&live_decoy_id_hash)
    .fetch_one(&fixture.state.db)
    .await
    .unwrap();
    assert_eq!(decoy_owner, None);

    crate::run_maintenance(&fixture.state).await.unwrap();
    let total_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_recovery_challenges")
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
    assert_eq!(
        total_rows, 2,
        "the next pass drains the remaining stale rows"
    );

    // The existing completion validator still accepts the retained real
    // challenge after the global cleanup pass.
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&fixture.request.challenge)
        .unwrap();
    let mut tx = fixture.state.db.begin().await.unwrap();
    valid_challenge(
        &mut tx,
        &fixture.account_id,
        CURRENT_RECOVERY_GENERATION,
        &fixture.request.challenge_id,
        &challenge,
    )
    .await
    .unwrap();
    tx.rollback().await.unwrap();

    fixture.state.db.close().await;
    std::fs::remove_dir_all(&fixture.state.config.data_dir).unwrap();
}

#[tokio::test]
async fn purge_first_makes_old_completion_stale_without_account_side_effects() {
    let fixture = make_fixture("purge-first").await;
    let completion_preflight_gate = Arc::new(TestPause::new());
    let purge_writer_gate = Arc::new(TestPause::new());
    let _release_completion = ReleasePauseOnDrop::new(completion_preflight_gate.clone());
    let _release_purge = ReleasePauseOnDrop::new(purge_writer_gate.clone());
    let completion_hooks = Arc::new(RecoveryPurgeTestHooks {
        completion_after_preflight: Some(completion_preflight_gate.clone()),
        ..RecoveryPurgeTestHooks::default()
    });
    let purge_hooks = Arc::new(RecoveryPurgeTestHooks {
        purge_writer_reserved: Some(purge_writer_gate.clone()),
        ..RecoveryPurgeTestHooks::default()
    });
    let before_credentials = credentials(&fixture.state.db, &fixture.account_id).await;
    let before_recovery = recovery_descriptor(&fixture.state.db, &fixture.account_id).await;
    let peer: SocketAddr = "127.0.0.1:43102".parse().unwrap();
    let complete_task = tokio::spawn(complete_with_test_hooks(
        fixture.state.clone(),
        peer,
        fixture.request,
        completion_hooks,
    ));

    // The old signed request has passed exact-context validation and its
    // read-only snapshot has closed, but it has not begun its final write txn.
    wait_gate(&completion_preflight_gate).await;
    let purge_state = fixture.state.clone();
    let purge_hooks_for_task = purge_hooks.clone();
    let purge_task = tokio::spawn(async move {
        control::purge_due_vault_deletions_with_test_hooks(
            &purge_state,
            fixture.now_epoch,
            &purge_hooks_for_task,
        )
        .await
    });
    wait_gate(&purge_writer_gate).await;
    purge_writer_gate.release();
    join(purge_task).await.unwrap();
    completion_preflight_gate.release();

    let error = join(complete_task).await.unwrap_err();
    assert_eq!(error.status, StatusCode::CONFLICT);
    assert_eq!(error.body.code, "RECOVERY_STALE");
    assert_eq!(
        credentials(&fixture.state.db, &fixture.account_id).await,
        before_credentials
    );
    assert_eq!(
        recovery_descriptor(&fixture.state.db, &fixture.account_id).await,
        before_recovery
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT last_generation FROM account_recovery_generation WHERE user_id=?",
            &fixture.account_id,
            None,
            None,
        )
        .await,
        CURRENT_RECOVERY_GENERATION
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM devices WHERE user_id=? AND device_id=?",
            &fixture.account_id,
            Some(&fixture.new_device_id),
            None,
        )
        .await,
        0
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM devices WHERE user_id=? AND device_id=? AND status='active'",
            &fixture.account_id,
            Some(&fixture.old_device_id),
            None,
        )
        .await,
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT revoked_at FROM sessions WHERE user_id=? AND device_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.old_device_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        None
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM relay_tickets WHERE user_id=?")
            .bind(&fixture.account_id)
            .fetch_one(&fixture.state.db)
            .await
            .unwrap(),
        1,
        "stale completion does not clear Relay tickets"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM notification_tickets WHERE user_id=?",)
            .bind(&fixture.account_id)
            .fetch_one(&fixture.state.db)
            .await
            .unwrap(),
        1,
        "stale completion does not clear notification tickets"
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<i64>>(
            "SELECT consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=?",
        )
        .bind(crate::sha256_hex(fixture.challenge_id.as_bytes()))
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        None
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM account_recovery_receipts WHERE user_id=? AND operation_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.operation_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.account_recovered' AND resource_id=?",
        )
        .bind(&fixture.account_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        scalar_i64(
            &fixture.state.db,
            "SELECT COUNT(*) FROM vaults WHERE vault_id=?",
            &fixture.vault_id,
            None,
            None,
        )
        .await,
        0,
        "the purge side effect remains committed"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM account_recovery_key_envelopes WHERE user_id=? AND vault_id=?",
        )
        .bind(&fixture.account_id)
        .bind(&fixture.vault_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap(),
        0,
        "the expected Vault FK cascade is distinct from completion side effects"
    );
}
