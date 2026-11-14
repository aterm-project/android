//! Handler-level tests for credential visibility v1 (per-account modes,
//! client-side Vault-key escrow and administrator reads), run through the
//! real router against real SQLite migrations.
use std::sync::Arc;

use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey, Verifier};
use rand::RngCore;
use serde_json::{Value, json};
use sha2::Digest;
use uuid::Uuid;

use crate::cloud_tests::{Account, World};
use crate::credential_visibility::ESCROW_SEALED_FORMAT;

const ADMIN: &str = "admin@example.test";

fn random_b64(len: usize) -> String {
    let mut bytes = vec![0_u8; len];
    rand::thread_rng().fill_bytes(&mut bytes);
    if bytes.iter().all(|byte| *byte == 0) {
        bytes[0] = 1;
    }
    URL_SAFE_NO_PAD.encode(bytes)
}

fn sign_jcs(key: &SigningKey, value: &Value) -> String {
    URL_SAFE_NO_PAD.encode(key.sign(&serde_jcs::to_vec(value).unwrap()).to_bytes())
}

fn account_wrap() -> Value {
    json!({"version": 1, "nonce": random_b64(24), "ciphertext": random_b64(48)})
}

fn recovery_wrap() -> Value {
    json!({
        "version": 1,
        "kdf": {
            "id": "argon2id13",
            "salt": random_b64(16),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
        },
        "nonce": random_b64(24),
        "ciphertext": random_b64(48),
    })
}

struct EscrowFixture {
    key_id: String,
    public_key: String,
    secret: crypto_box::SecretKey,
}

fn instance_id(world: &World) -> String {
    world.state.instance.instance_id.clone()
}

fn creation_body(world: &World, admin: &Account, key_id: &str, public_key: &str) -> Value {
    let statement = json!({
        "format": "atermius-credential-escrow-key-creation-v1",
        "instance_id": instance_id(world),
        "key_id": key_id,
        "public_key": public_key,
        "account_id": admin.user_id,
        "device_id": admin.device_id,
    });
    json!({
        "key_id": key_id,
        "public_key": public_key,
        "creator_signature": sign_jcs(&admin.signing, &statement),
        "account_wrap": account_wrap(),
        "recovery_wrap": recovery_wrap(),
    })
}

async fn create_escrow_key(world: &World, admin: &Account) -> EscrowFixture {
    let secret = crypto_box::SecretKey::generate(&mut rand::rngs::OsRng);
    let public_key = URL_SAFE_NO_PAD.encode(secret.public_key().as_bytes());
    let key_id = Uuid::new_v4().to_string();
    let (status, value) = world
        .bearer(
            admin,
            Method::POST,
            "/api/v1/admin/credential-escrow/key",
            Some(creation_body(world, admin, &key_id, &public_key)),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{value}");
    verify_descriptor(world, &value["escrow_key"], &key_id, &public_key);
    EscrowFixture {
        key_id,
        public_key,
        secret,
    }
}

/// Client-side descriptor verification, as the Dart `verifyGatewayKey`
/// pattern does against the pinned instance signing key.
fn verify_descriptor(world: &World, descriptor: &Value, key_id: &str, public_key: &str) {
    let signed_payload = descriptor["signed_payload"].as_str().unwrap();
    let signature = URL_SAFE_NO_PAD
        .decode(descriptor["signature"].as_str().unwrap())
        .unwrap();
    world
        .state
        .signing_key
        .verifying_key()
        .verify(
            signed_payload.as_bytes(),
            &ed25519_dalek::Signature::from_slice(&signature).unwrap(),
        )
        .expect("descriptor must be signed by the pinned instance key");
    let payload: Value = serde_json::from_str(signed_payload).unwrap();
    assert_eq!(payload["format"], "atermius-credential-escrow-key-v1");
    assert_eq!(payload["instance_id"], instance_id(world));
    assert_eq!(payload["key_id"], key_id);
    assert_eq!(payload["public_key"], public_key);
    assert_eq!(payload["created_at"], descriptor["created_at"]);
    assert_eq!(descriptor["key_id"], key_id);
    assert_eq!(descriptor["public_key"], public_key);
    assert_eq!(serde_jcs::to_string(&payload).unwrap(), signed_payload);
}

/// `World::account` creates no password credential row; `/me` needs one.
async fn with_credentials(world: &World, account: &Account) {
    sqlx::query(
        "INSERT INTO auth_credentials(user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope) \
         VALUES(?,'hash','salt','{}','{\"version\":1}')",
    )
    .bind(&account.user_id)
    .execute(&world.state.db)
    .await
    .unwrap();
}

async fn set_mode(world: &World, account: &Account, mode: &str) {
    sqlx::query("UPDATE users SET credential_visibility=? WHERE user_id=?")
        .bind(mode)
        .bind(&account.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
}

/// Records that `epoch` of `vault_id` was delivered to `account`'s device.
async fn deliver(world: &World, vault_id: &str, epoch: i64, account: &Account) {
    deliver_to_device(world, vault_id, epoch, &account.user_id, &account.device_id).await;
}

async fn deliver_to_device(
    world: &World,
    vault_id: &str,
    epoch: i64,
    user_id: &str,
    device_id: &str,
) {
    sqlx::query(
        "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,\
         envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,'{}','sig',?,1)",
    )
    .bind(vault_id)
    .bind(epoch)
    .bind(user_id)
    .bind(device_id)
    .bind(device_id)
    .execute(&world.state.db)
    .await
    .unwrap();
    sqlx::query("UPDATE vaults SET active_epoch=MAX(active_epoch,?) WHERE vault_id=?")
        .bind(epoch)
        .bind(vault_id)
        .execute(&world.state.db)
        .await
        .unwrap();
}

fn vault_key_for(vault_id: &str, epoch: i64) -> String {
    URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(format!(
        "vault-key:{vault_id}:{epoch}"
    )))
}

fn deposit_body(
    world: &World,
    depositor: &Account,
    fixture: &EscrowFixture,
    vault_id: &str,
    epoch: i64,
) -> Value {
    let inner = json!({
        "format": ESCROW_SEALED_FORMAT,
        "instance_id": instance_id(world),
        "key_id": fixture.key_id,
        "vault_id": vault_id,
        "key_epoch": epoch,
        "vault_key": vault_key_for(vault_id, epoch),
    });
    let sealed = fixture
        .secret
        .public_key()
        .seal(&mut rand::rngs::OsRng, &serde_jcs::to_vec(&inner).unwrap())
        .unwrap();
    let statement = json!({
        "format": "atermius-credential-escrow-deposit-v1",
        "instance_id": instance_id(world),
        "key_id": fixture.key_id,
        "vault_id": vault_id,
        "key_epoch": epoch,
        "sealed_sha256": URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed)),
    });
    json!({
        "key_id": fixture.key_id,
        "sealed": URL_SAFE_NO_PAD.encode(&sealed),
        "signature": sign_jcs(&depositor.signing, &statement),
    })
}

async fn deposit(
    world: &World,
    depositor: &Account,
    fixture: &EscrowFixture,
    vault_id: &str,
    epoch: i64,
) -> (StatusCode, Value) {
    world
        .bearer(
            depositor,
            Method::PUT,
            &format!("/api/v1/credential-visibility/escrow/{vault_id}/{epoch}"),
            Some(deposit_body(world, depositor, fixture, vault_id, epoch)),
        )
        .await
}

async fn status_of(world: &World, account: &Account) -> Value {
    let (status, value) = world
        .bearer(account, Method::GET, "/api/v1/credential-visibility", None)
        .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    value
}

async fn put_mode(
    world: &World,
    admin: &Account,
    target: &Account,
    mode: &str,
) -> (StatusCode, Value) {
    world
        .bearer(
            admin,
            Method::PUT,
            &format!(
                "/api/v1/admin/accounts/{}/credential-visibility",
                target.user_id
            ),
            Some(json!({"mode": mode})),
        )
        .await
}

async fn envelope_count(world: &World, vault_id: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM credential_escrow_envelopes WHERE vault_id=?")
        .bind(vault_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap()
}

async fn audit_count(world: &World, action: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE action=?")
        .bind(action)
        .fetch_one(&world.state.db)
        .await
        .unwrap()
}

async fn put_record(
    world: &World,
    vault_id: &str,
    device_id: &str,
    record_id: &str,
    seq: i64,
    deleted: bool,
) -> (String, Value) {
    let revision_id = Uuid::new_v4().to_string();
    let envelope = json!({
        "header": {"record_id": record_id, "revision_id": revision_id, "device_id": device_id},
        "ciphertext": format!("opaque-{record_id}"),
    });
    sqlx::query(
        "INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,\
         operation,created_at) VALUES(?,?,?,?,'digest',?,?,?,?)",
    )
    .bind(vault_id)
    .bind(record_id)
    .bind(&revision_id)
    .bind(envelope.to_string())
    .bind(seq)
    .bind(device_id)
    .bind(if deleted { "delete" } else { "create" })
    .bind(crate::now_rfc3339())
    .execute(&world.state.db)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,?,?)",
    )
    .bind(vault_id)
    .bind(record_id)
    .bind(&revision_id)
    .bind(i64::from(deleted))
    .bind(seq)
    .execute(&world.state.db)
    .await
    .unwrap();
    (revision_id, envelope)
}

fn records_path(vault_id: &str, target: &Account, extra: &str) -> String {
    format!(
        "/api/v1/admin/credential-escrow/vaults/{vault_id}/records?user_id={}{extra}",
        target.user_id
    )
}

async fn admin_records(
    world: &World,
    admin: &Account,
    path: &str,
    redaction_marker: bool,
) -> (StatusCode, Value) {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {}", admin.access)).unwrap(),
    );
    if redaction_marker {
        headers.insert(
            "x-atermius-redaction-marker",
            HeaderValue::from_static("v1"),
        );
    }
    let (status, _, value) = world.call(Method::GET, path, headers, None).await;
    (status, value)
}

async fn view_count(world: &World, target: &Account) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM credential_admin_views WHERE target_user_id=?")
        .bind(&target.user_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap()
}

// ---------------------------------------------------------------------------
// Capability, /me and authentication
// ---------------------------------------------------------------------------

#[tokio::test]
async fn capability_default_and_me_policy_are_reported() {
    let world = World::new().await;
    let (status, _, info) = world
        .call(Method::GET, "/api/v1/instance", HeaderMap::new(), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        info["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("credential_visibility"))
    );
    assert_eq!(info["credential_visibility_default"], "private");

    let user = world.account("user@example.test").await;
    with_credentials(&world, &user).await;
    let (status, me) = world.bearer(&user, Method::GET, "/api/v1/me", None).await;
    assert_eq!(status, StatusCode::OK, "{me}");
    assert_eq!(
        me["policy"]["credential_visibility"],
        json!({"mode": "private", "changed_at": null})
    );
    let status_value = status_of(&world, &user).await;
    assert_eq!(status_value["mode"], "private");
    assert_eq!(status_value["changed_at"], Value::Null);
    assert_eq!(status_value["escrow_status"], "not_required");
    assert_eq!(status_value["escrow_key"], Value::Null);
    assert_eq!(status_value["missing"], json!([]));
    assert_eq!(status_value["admin_views"], json!([]));

    sqlx::query("UPDATE instance_credential_policy SET default_visibility='admin_visible'")
        .execute(&world.state.db)
        .await
        .unwrap();
    let (_, _, info) = world
        .call(Method::GET, "/api/v1/instance", HeaderMap::new(), None)
        .await;
    assert_eq!(info["credential_visibility_default"], "admin_visible");
}

#[tokio::test]
async fn routes_require_authentication_and_the_admin_allowlist() {
    let world = World::new().await;
    let user = world.account("user@example.test").await;
    let vault = Uuid::new_v4().to_string();
    let key = Uuid::new_v4().to_string();
    let routes: Vec<(Method, String, Option<Value>, bool)> = vec![
        (
            Method::GET,
            "/api/v1/credential-visibility".into(),
            None,
            false,
        ),
        (
            Method::PUT,
            format!("/api/v1/credential-visibility/escrow/{vault}/1"),
            Some(json!({"key_id": key, "sealed": "x", "signature": "y"})),
            false,
        ),
        (
            Method::GET,
            "/api/v1/admin/credential-visibility".into(),
            None,
            true,
        ),
        (
            Method::PUT,
            "/api/v1/admin/credential-visibility".into(),
            Some(json!({"default_mode": "private"})),
            true,
        ),
        (
            Method::PUT,
            format!(
                "/api/v1/admin/accounts/{}/credential-visibility",
                user.user_id
            ),
            Some(json!({"mode": "private"})),
            true,
        ),
        (
            Method::POST,
            "/api/v1/admin/credential-escrow/key".into(),
            Some(creation_body(&world, &user, &key, &random_b64(32))),
            true,
        ),
        (
            Method::PUT,
            "/api/v1/admin/credential-escrow/key/wrap".into(),
            Some(json!({"key_id": key, "account_wrap": account_wrap()})),
            true,
        ),
        (
            Method::DELETE,
            "/api/v1/admin/credential-escrow/key".into(),
            Some(json!({"key_id": key, "confirm": "reset"})),
            true,
        ),
        (
            Method::GET,
            format!(
                "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                user.user_id
            ),
            None,
            true,
        ),
        (
            Method::GET,
            format!(
                "/api/v1/admin/credential-escrow/vaults/{vault}/records?user_id={}",
                user.user_id
            ),
            None,
            true,
        ),
    ];
    for (method, path, body, admin_only) in routes {
        let (status, _, value) = world
            .call(method.clone(), &path, HeaderMap::new(), body.clone())
            .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}: {value}");
        assert_eq!(value["error"]["code"], "AUTH_REQUIRED");
        if admin_only {
            let (status, value) = world.bearer(&user, method.clone(), &path, body).await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{method} {path}: {value}");
            assert_eq!(value["error"]["code"], "INSTANCE_ADMIN_REQUIRED");
        }
    }
    // Non-admin probes changed nothing.
    let keys: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM credential_escrow_keys")
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(keys, 0);
}

// ---------------------------------------------------------------------------
// Escrow key lifecycle
// ---------------------------------------------------------------------------

#[tokio::test]
async fn escrow_key_creation_is_validated_single_and_wrapped_per_admin() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let secret = crypto_box::SecretKey::generate(&mut rand::rngs::OsRng);
    let public_key = URL_SAFE_NO_PAD.encode(secret.public_key().as_bytes());
    let key_id = Uuid::new_v4().to_string();
    let path = "/api/v1/admin/credential-escrow/key";

    // Malformed requests fail before anything is stored.
    let mut bad_signature = creation_body(&world, &admin, &key_id, &public_key);
    bad_signature["creator_signature"] = json!(sign_jcs(&admin.signing, &json!({"other": true})));
    let mut other_device = creation_body(&world, &admin, &key_id, &public_key);
    let stranger = SigningKey::generate(&mut rand::rngs::OsRng);
    other_device["creator_signature"] = json!(sign_jcs(
        &stranger,
        &json!({
            "format": "atermius-credential-escrow-key-creation-v1",
            "instance_id": instance_id(&world),
            "key_id": key_id,
            "public_key": public_key,
            "account_id": admin.user_id,
            "device_id": admin.device_id,
        })
    ));
    let mut bad_wrap = creation_body(&world, &admin, &key_id, &public_key);
    bad_wrap["account_wrap"]["ciphertext"] = json!(random_b64(47));
    let mut extra_wrap_field = creation_body(&world, &admin, &key_id, &public_key);
    extra_wrap_field["account_wrap"]["extra"] = json!(1);
    let mut weak_kdf = creation_body(&world, &admin, &key_id, &public_key);
    weak_kdf["recovery_wrap"]["kdf"]["iterations"] = json!(2);
    let mut zero_salt = creation_body(&world, &admin, &key_id, &public_key);
    zero_salt["recovery_wrap"]["kdf"]["salt"] = json!(URL_SAFE_NO_PAD.encode([0_u8; 16]));
    let mut short_key = creation_body(&world, &admin, &key_id, &public_key);
    short_key["public_key"] = json!(random_b64(31));
    let mut unknown_field = creation_body(&world, &admin, &key_id, &public_key);
    unknown_field["secret_key"] = json!(random_b64(32));
    let mut bad_key_id = creation_body(&world, &admin, &key_id, &public_key);
    bad_key_id["key_id"] = json!(key_id.to_uppercase());
    for body in [
        bad_signature,
        other_device,
        bad_wrap,
        extra_wrap_field,
        weak_kdf,
        zero_salt,
        short_key,
        unknown_field,
        bad_key_id,
    ] {
        let (status, value) = world.bearer(&admin, Method::POST, path, Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{value}");
        assert_eq!(
            value["error"]["code"], "CREDENTIAL_ESCROW_INVALID",
            "{value}"
        );
    }
    let (status, value) = world
        .bearer(
            &admin,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["escrow_key"], Value::Null);
    assert_eq!(value["caller_wrap"], Value::Null);
    assert_eq!(value["recovery_wrap"], Value::Null);

    let body = creation_body(&world, &admin, &key_id, &public_key);
    let (status, created) = world
        .bearer(&admin, Method::POST, path, Some(body.clone()))
        .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    verify_descriptor(&world, &created["escrow_key"], &key_id, &public_key);
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_key_created").await,
        1
    );

    // A second key is refused while one exists, also at the database layer.
    let other = creation_body(&world, &admin, &Uuid::new_v4().to_string(), &random_b64(32));
    let (status, value) = world.bearer(&admin, Method::POST, path, Some(other)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_KEY_EXISTS");
    let direct = sqlx::query(
        "INSERT INTO credential_escrow_keys(key_id,public_key,signed_payload,instance_signature,\
         creator_signature,recovery_wrap,created_at) VALUES('k2','p2','s','i','c','r','t')",
    )
    .execute(&world.state.db)
    .await;
    assert!(
        direct.is_err(),
        "the single-row trigger must refuse a second key"
    );

    let (status, policy) = world
        .bearer(
            &admin,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(policy["default_mode"], "private");
    assert_eq!(policy["escrow_key"], created["escrow_key"]);
    assert_eq!(policy["caller_wrap"], body["account_wrap"]);
    assert_eq!(policy["recovery_wrap"], body["recovery_wrap"]);

    // A second administrator has no wrap until it stores its own.
    let second = world.account("second-admin@example.test").await;
    let mut config = (*world.state.config).clone();
    config
        .admin_usernames
        .push("second-admin@example.test".into());
    let mut world = world;
    world.state.config = Arc::new(config);
    let (_, policy) = world
        .bearer(
            &second,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(policy["caller_wrap"], Value::Null);
    assert_eq!(policy["recovery_wrap"], body["recovery_wrap"]);
    let wrap = account_wrap();
    let (status, value) = world
        .bearer(
            &second,
            Method::PUT,
            "/api/v1/admin/credential-escrow/key/wrap",
            Some(json!({"key_id": Uuid::new_v4().to_string(), "account_wrap": wrap})),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_KEY_MISMATCH");
    let (status, value) = world
        .bearer(
            &second,
            Method::PUT,
            "/api/v1/admin/credential-escrow/key/wrap",
            Some(json!({"key_id": key_id, "account_wrap": wrap})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value, json!({"status": "stored"}));
    let (_, policy) = world
        .bearer(
            &second,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(policy["caller_wrap"], wrap);
    let (_, policy) = world
        .bearer(
            &admin,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(
        policy["caller_wrap"], body["account_wrap"],
        "wraps are per administrator"
    );
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_key_wrap_stored").await,
        1
    );
    // The secret half is never sent to or stored by the server.
    let bytes = world.db_bytes().await;
    let secret_b64 = URL_SAFE_NO_PAD.encode(secret.to_bytes());
    assert!(
        !bytes
            .windows(secret_b64.len())
            .any(|window| window == secret_b64.as_bytes())
    );
}

#[tokio::test]
async fn descriptor_is_resigned_after_instance_key_rotation_only_when_previously_signed() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let fixture = create_escrow_key(&world, &admin).await;
    let user = world.account("user@example.test").await;

    let old_public = world.state.instance.signing_public_key.clone();
    let new_key = SigningKey::generate(&mut rand::rngs::OsRng);
    let mut instance = (*world.state.instance).clone();
    instance
        .signing_key_transitions
        .push(crate::InstanceKeyTransition {
            format: "atermius-instance-key-transition-v1".into(),
            instance_id: instance.instance_id.clone(),
            from_public_key: old_public,
            to_public_key: URL_SAFE_NO_PAD.encode(new_key.verifying_key().as_bytes()),
            issued_at: crate::now_rfc3339(),
            signature: String::new(),
        });
    instance.signing_public_key = URL_SAFE_NO_PAD.encode(new_key.verifying_key().as_bytes());
    let mut rotated = world;
    rotated.state.instance = Arc::new(instance);
    rotated.state.signing_key = Arc::new(new_key);
    let status = status_of(&rotated, &user).await;
    verify_descriptor(
        &rotated,
        &status["escrow_key"],
        &fixture.key_id,
        &fixture.public_key,
    );

    // A stored statement that no instance key ever signed fails closed.
    sqlx::query("UPDATE credential_escrow_keys SET instance_signature=?")
        .bind(URL_SAFE_NO_PAD.encode([7_u8; 64]))
        .execute(&rotated.state.db)
        .await
        .unwrap();
    let (code, value) = rotated
        .bearer(&user, Method::GET, "/api/v1/credential-visibility", None)
        .await;
    assert_eq!(code, StatusCode::INTERNAL_SERVER_ERROR, "{value}");
    assert_eq!(value["error"]["code"], "INTERNAL");
}

#[tokio::test]
async fn tampered_escrow_key_row_fails_closed() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    create_escrow_key(&world, &admin).await;
    let user = world.account("user@example.test").await;
    sqlx::query("UPDATE credential_escrow_keys SET public_key=?")
        .bind(random_b64(32))
        .execute(&world.state.db)
        .await
        .unwrap();
    let (status, value) = world
        .bearer(&user, Method::GET, "/api/v1/credential-visibility", None)
        .await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{value}");
    assert!(!value.to_string().contains("public_key"));
}

#[tokio::test]
async fn key_reset_requires_confirmation_and_cascades() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    set_mode(&world, &user, "admin_visible").await;
    let vault = world.vault(&user, &[]).await;
    deliver(&world, &vault, 1, &user).await;
    let fixture = create_escrow_key(&world, &admin).await;
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    assert_eq!(status_of(&world, &user).await["escrow_status"], "complete");

    let path = "/api/v1/admin/credential-escrow/key";
    let (status, value) = world
        .bearer(
            &admin,
            Method::DELETE,
            path,
            Some(json!({"key_id": fixture.key_id, "confirm": "yes"})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_INVALID");
    let (status, value) = world
        .bearer(
            &admin,
            Method::DELETE,
            path,
            Some(json!({"key_id": Uuid::new_v4().to_string(), "confirm": "reset"})),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_KEY_MISMATCH");
    let (status, value) = world
        .bearer(
            &admin,
            Method::DELETE,
            path,
            Some(json!({"key_id": fixture.key_id, "confirm": "reset"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value, json!({"status": "reset"}));
    for table in [
        "credential_escrow_keys",
        "credential_escrow_key_wraps",
        "credential_escrow_envelopes",
    ] {
        let count: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table}"))
            .fetch_one(&world.state.db)
            .await
            .unwrap();
        assert_eq!(count, 0, "{table} must be emptied by reset");
    }
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_key_reset").await,
        1
    );
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "no_key");
    assert_eq!(status["missing"], json!([]));
    // Deposits under the old key are refused; a new key makes them pending.
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.1["error"]["code"],
        "CREDENTIAL_ESCROW_KEY_MISMATCH"
    );
    let fresh = create_escrow_key(&world, &admin).await;
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "pending");
    assert_eq!(
        status["missing"],
        json!([{"vault_id": vault, "key_epoch": 1}])
    );
    assert_eq!(
        deposit(&world, &user, &fresh, &vault, 1).await.0,
        StatusCode::CREATED
    );
    assert_eq!(status_of(&world, &user).await["escrow_status"], "complete");
}

// ---------------------------------------------------------------------------
// Deposits and status
// ---------------------------------------------------------------------------

#[tokio::test]
async fn deposit_round_trip_and_duplicate_is_never_overwritten() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let vault = world.vault(&user, &[]).await;
    deliver(&world, &vault, 1, &user).await;
    set_mode(&world, &user, "admin_visible").await;
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "no_key");
    assert_eq!(status["missing"], json!([]));

    let fixture = create_escrow_key(&world, &admin).await;
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "pending");
    assert_eq!(
        status["missing"],
        json!([{"vault_id": vault, "key_epoch": 1}])
    );
    verify_descriptor(
        &world,
        &status["escrow_key"],
        &fixture.key_id,
        &fixture.public_key,
    );

    let body = deposit_body(&world, &user, &fixture, &vault, 1);
    let path = format!("/api/v1/credential-visibility/escrow/{vault}/1");
    let (code, value) = world
        .bearer(&user, Method::PUT, &path, Some(body.clone()))
        .await;
    assert_eq!(code, StatusCode::CREATED, "{value}");
    assert_eq!(value, json!({"status": "stored"}));
    let (code, value) = deposit(&world, &user, &fixture, &vault, 1).await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(value, json!({"status": "already_present"}));
    let stored: String =
        sqlx::query_scalar("SELECT sealed FROM credential_escrow_envelopes WHERE vault_id=?")
            .bind(&vault)
            .fetch_one(&world.state.db)
            .await
            .unwrap();
    assert_eq!(
        stored, body["sealed"],
        "an existing deposit is never overwritten"
    );
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "complete");
    assert_eq!(status["missing"], json!([]));

    // Administrator listing returns the deposit and the depositor's key; the
    // administrator client verifies the signature and opens the seal.
    let (code, listing) = world
        .bearer(
            &admin,
            Method::GET,
            &format!(
                "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                user.user_id
            ),
            None,
        )
        .await;
    assert_eq!(code, StatusCode::OK, "{listing}");
    assert_eq!(
        listing["account"],
        json!({"user_id": user.user_id, "username": "user@example.test", "mode": "admin_visible"})
    );
    let vaults = listing["vaults"].as_array().unwrap();
    assert_eq!(vaults.len(), 1);
    assert_eq!(vaults[0]["vault_id"], vault);
    assert_eq!(vaults[0]["role"], "owner");
    assert_eq!(vaults[0]["owner_user_id"], user.user_id);
    assert_eq!(vaults[0]["active_epoch"], 1);
    let escrow = &vaults[0]["escrow"][0];
    assert_eq!(escrow["key_epoch"], 1);
    assert_eq!(escrow["depositor_device_id"], user.device_id);
    let sealed = URL_SAFE_NO_PAD
        .decode(escrow["sealed"].as_str().unwrap())
        .unwrap();
    let statement = json!({
        "format": "atermius-credential-escrow-deposit-v1",
        "instance_id": instance_id(&world),
        "key_id": fixture.key_id,
        "vault_id": vault,
        "key_epoch": 1,
        "sealed_sha256": URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed)),
    });
    crate::auth::verify_key_signature(
        escrow["depositor_signing_public_key"].as_str().unwrap(),
        escrow["signature"].as_str().unwrap(),
        &serde_jcs::to_vec(&statement).unwrap(),
    )
    .unwrap();
    let inner: Value = serde_json::from_slice(&fixture.secret.unseal(&sealed).unwrap()).unwrap();
    assert_eq!(inner["format"], ESCROW_SEALED_FORMAT);
    assert_eq!(inner["vault_id"], vault);
    assert_eq!(inner["key_epoch"], 1);
    assert_eq!(inner["key_id"], fixture.key_id);
    assert_eq!(inner["vault_key"], vault_key_for(&vault, 1));
    // Listing is not a view.
    assert_eq!(view_count(&world, &user).await, 0);
}

#[tokio::test]
async fn deposit_rejections_are_specific_and_do_not_reveal_foreign_vaults() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let other = world.account("other@example.test").await;
    let vault = world.vault(&user, &[]).await;
    let foreign = world.vault(&other, &[]).await;
    deliver(&world, &vault, 1, &user).await;
    deliver(&world, &foreign, 1, &other).await;
    let fixture = create_escrow_key(&world, &admin).await;

    // Private accounts never escrow.
    let (code, value) = deposit(&world, &user, &fixture, &vault, 1).await;
    assert_eq!(code, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_REQUIRED");
    set_mode(&world, &user, "admin_visible").await;

    // Wrong key.
    let stale = EscrowFixture {
        key_id: Uuid::new_v4().to_string(),
        public_key: fixture.public_key.clone(),
        secret: crypto_box::SecretKey::from_bytes(fixture.secret.to_bytes()),
    };
    let (code, value) = deposit(&world, &user, &stale, &vault, 1).await;
    assert_eq!(code, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_KEY_MISMATCH");

    // Foreign, unknown, malformed and inactive Vaults all look absent.
    for target in [foreign.clone(), Uuid::new_v4().to_string()] {
        let (code, value) = deposit(&world, &user, &fixture, &target, 1).await;
        assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
        assert_eq!(value["error"]["code"], "NOT_FOUND");
    }
    let (code, _) = world
        .bearer(
            &user,
            Method::PUT,
            &format!(
                "/api/v1/credential-visibility/escrow/{}/1",
                vault.to_uppercase()
            ),
            Some(deposit_body(&world, &user, &fixture, &vault, 1)),
        )
        .await;
    assert_eq!(code, StatusCode::NOT_FOUND);
    let deleting = world.vault(&user, &[]).await;
    deliver(&world, &deleting, 1, &user).await;
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?")
        .bind(&deleting)
        .execute(&world.state.db)
        .await
        .unwrap();
    assert_eq!(
        deposit(&world, &user, &fixture, &deleting, 1).await.0,
        StatusCode::NOT_FOUND
    );
    let left = world.vault(&other, &[(&user, "editor")]).await;
    deliver(&world, &left, 1, &user).await;
    sqlx::query("UPDATE vault_members SET state='removed' WHERE vault_id=? AND user_id=?")
        .bind(&left)
        .bind(&user.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    assert_eq!(
        deposit(&world, &user, &fixture, &left, 1).await.0,
        StatusCode::NOT_FOUND
    );

    // Epoch not delivered to any active device of the caller.
    let (code, value) = deposit(&world, &user, &fixture, &vault, 2).await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_INVALID");

    // Signature and shape failures.
    let path = format!("/api/v1/credential-visibility/escrow/{vault}/1");
    let mut wrong_signer = deposit_body(&world, &user, &fixture, &vault, 1);
    wrong_signer["signature"] =
        deposit_body(&world, &other, &fixture, &vault, 1)["signature"].clone();
    let mut wrong_epoch_signature = deposit_body(&world, &user, &fixture, &vault, 1);
    wrong_epoch_signature["signature"] =
        deposit_body(&world, &user, &fixture, &vault, 2)["signature"].clone();
    let mut tampered_seal = deposit_body(&world, &user, &fixture, &vault, 1);
    let mut sealed = URL_SAFE_NO_PAD
        .decode(tampered_seal["sealed"].as_str().unwrap())
        .unwrap();
    sealed[60] ^= 1;
    tampered_seal["sealed"] = json!(URL_SAFE_NO_PAD.encode(&sealed));
    let mut extra = deposit_body(&world, &user, &fixture, &vault, 1);
    extra["vault_key"] = json!(random_b64(32));
    let mut too_large = deposit_body(&world, &user, &fixture, &vault, 1);
    too_large["sealed"] = json!(random_b64(1025));
    let mut too_small = deposit_body(&world, &user, &fixture, &vault, 1);
    too_small["sealed"] = json!(random_b64(48));
    let mut padded = deposit_body(&world, &user, &fixture, &vault, 1);
    padded["sealed"] = json!(format!("{}=", padded["sealed"].as_str().unwrap()));
    for body in [
        wrong_signer,
        wrong_epoch_signature,
        tampered_seal,
        extra,
        too_large,
        too_small,
        padded,
    ] {
        let (code, value) = world.bearer(&user, Method::PUT, &path, Some(body)).await;
        assert_eq!(code, StatusCode::BAD_REQUEST, "{value}");
        assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_INVALID");
    }
    for epoch in ["0", "01", "-1", "x", "99999999999999999999"] {
        let (code, value) = world
            .bearer(
                &user,
                Method::PUT,
                &format!("/api/v1/credential-visibility/escrow/{vault}/{epoch}"),
                Some(deposit_body(&world, &user, &fixture, &vault, 1)),
            )
            .await;
        assert_eq!(code, StatusCode::BAD_REQUEST, "{epoch}: {value}");
        assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_INVALID");
    }
    assert_eq!(envelope_count(&world, &vault).await, 0);
    // Error messages never echo submitted material.
    let (_, value) = world
        .bearer(
            &user,
            Method::PUT,
            &path,
            Some(json!({"key_id": fixture.key_id, "sealed": "SENTINEL-SEALED", "signature": "x"})),
        )
        .await;
    assert!(!value.to_string().contains("SENTINEL-SEALED"));
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn missing_items_cover_only_epochs_the_accounts_active_devices_can_open() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let other = world.account("other@example.test").await;
    set_mode(&world, &user, "admin_visible").await;
    let fixture = create_escrow_key(&world, &admin).await;

    let own = world.vault(&user, &[]).await;
    deliver(&world, &own, 1, &user).await;
    deliver(&world, &own, 2, &user).await;
    // Shared Vault: epoch 1 delivered to the user, epoch 2 only to the owner.
    let shared = world.vault(&other, &[(&user, "editor")]).await;
    deliver(&world, &shared, 1, &user).await;
    deliver(&world, &shared, 2, &other).await;
    // Epoch delivered only to a revoked device of the user.
    let revoked_device = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status,created_at) VALUES(?,?,'old',?,?,'revoked',?)")
        .bind(&revoked_device)
        .bind(&user.user_id)
        .bind(random_b64(32))
        .bind(random_b64(32))
        .bind(crate::now_rfc3339())
        .execute(&world.state.db)
        .await
        .unwrap();
    deliver_to_device(&world, &own, 3, &user.user_id, &revoked_device).await;
    // Deleting Vault, removed membership and organization-hidden membership.
    let deleting = world.vault(&user, &[]).await;
    deliver(&world, &deleting, 1, &user).await;
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?")
        .bind(&deleting)
        .execute(&world.state.db)
        .await
        .unwrap();
    let removed = world.vault(&other, &[(&user, "viewer")]).await;
    deliver(&world, &removed, 1, &user).await;
    sqlx::query("UPDATE vault_members SET state='removed' WHERE vault_id=? AND user_id=?")
        .bind(&removed)
        .bind(&user.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    let hidden = world.vault(&other, &[(&user, "viewer")]).await;
    deliver(&world, &hidden, 1, &user).await;
    sqlx::query("INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,'none',0)")
        .bind(&hidden)
        .bind(&user.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();

    let mut expected = vec![(own.clone(), 1), (own.clone(), 2), (shared.clone(), 1)];
    expected.sort();
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "pending");
    let missing = status["missing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            (
                item["vault_id"].as_str().unwrap().to_owned(),
                item["key_epoch"].as_i64().unwrap(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(missing, expected);
    // An epoch delivered only to a revoked device or another account is refused.
    assert_eq!(
        deposit(&world, &user, &fixture, &own, 3).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        deposit(&world, &user, &fixture, &shared, 2).await.0,
        StatusCode::BAD_REQUEST
    );

    // Another member's deposit for the same (Vault, epoch) satisfies the item.
    set_mode(&world, &other, "admin_visible").await;
    deliver(&world, &shared, 1, &other).await;
    assert_eq!(
        deposit(&world, &other, &fixture, &shared, 1).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        deposit(&world, &user, &fixture, &shared, 1).await.0,
        StatusCode::OK
    );
    // The other admin_visible member holds epoch 2 and escrows it itself.
    assert_eq!(
        deposit(&world, &other, &fixture, &shared, 2).await.0,
        StatusCode::CREATED
    );
    for (vault, epoch) in [(&own, 1), (&own, 2)] {
        assert_eq!(
            deposit(&world, &user, &fixture, vault, epoch).await.0,
            StatusCode::CREATED
        );
    }
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "complete");
    assert_eq!(status["missing"], json!([]));
    // A key rotation adds a new pending item.
    deliver(&world, &own, 4, &user).await;
    let status = status_of(&world, &user).await;
    assert_eq!(status["escrow_status"], "pending");
    assert_eq!(
        status["missing"],
        json!([{"vault_id": own, "key_epoch": 4}])
    );

    // Admin views report the same computed status.
    let (_, accounts) = world
        .bearer(&admin, Method::GET, "/api/v1/admin/accounts", None)
        .await;
    let row = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["user_id"] == user.user_id)
        .unwrap()
        .clone();
    assert_eq!(row["credential_visibility"], "admin_visible");
    assert_eq!(row["escrow_status"], "pending");
    let admin_row = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["user_id"] == admin.user_id)
        .unwrap()
        .clone();
    assert_eq!(admin_row["credential_visibility"], "private");
    assert_eq!(admin_row["escrow_status"], "not_required");
    let (_, policy) = world
        .bearer(
            &admin,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(
        policy["counts"],
        json!({"admin_visible": 2, "private": 1, "pending": 1})
    );
}

// ---------------------------------------------------------------------------
// Mode changes
// ---------------------------------------------------------------------------

#[tokio::test]
async fn switching_to_private_deletes_escrow_only_when_no_admin_visible_member_remains() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let alice = world.account("alice@example.test").await;
    let bob = world.account("bob@example.test").await;
    let fixture = create_escrow_key(&world, &admin).await;
    let shared = world.vault(&alice, &[(&bob, "editor")]).await;
    let alone = world.vault(&alice, &[]).await;
    for vault in [&shared, &alone] {
        deliver(&world, vault, 1, &alice).await;
    }
    deliver(&world, &shared, 1, &bob).await;

    for account in [&alice, &bob] {
        let (code, value) = put_mode(&world, &admin, account, "admin_visible").await;
        assert_eq!(code, StatusCode::OK, "{value}");
        assert_eq!(value["user_id"], account.user_id);
        assert_eq!(value["mode"], "admin_visible");
        assert!(value["changed_at"].is_string());
        assert_eq!(value["escrow_status"], "pending");
    }
    assert_eq!(
        audit_count(&world, "instance.credential_visibility_changed").await,
        2
    );
    assert_eq!(
        audit_count(&world, "account.credential_visibility_changed").await,
        2
    );
    with_credentials(&world, &alice).await;
    let (_, me) = world.bearer(&alice, Method::GET, "/api/v1/me", None).await;
    assert_eq!(
        me["policy"]["credential_visibility"]["mode"],
        "admin_visible"
    );
    let alice_changed_at = me["policy"]["credential_visibility"]["changed_at"].clone();
    assert!(alice_changed_at.is_string());

    // Idempotent: no audit and no changed_at bump.
    let (code, value) = put_mode(&world, &admin, &alice, "admin_visible").await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(value["changed_at"], alice_changed_at);
    assert_eq!(
        audit_count(&world, "instance.credential_visibility_changed").await,
        2
    );

    assert_eq!(
        deposit(&world, &alice, &fixture, &shared, 1).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        deposit(&world, &alice, &fixture, &alone, 1).await.0,
        StatusCode::CREATED
    );
    let (_, vaults) = world
        .bearer(&bob, Method::GET, "/api/v1/vaults", None)
        .await;
    assert_eq!(vaults["vaults"][0]["admin_visible"], true);

    let (code, value) = put_mode(&world, &admin, &alice, "private").await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(value["escrow_status"], "not_required");
    assert_ne!(value["changed_at"], alice_changed_at);
    assert_eq!(
        envelope_count(&world, &alone).await,
        0,
        "unshared escrow is deleted"
    );
    assert_eq!(
        envelope_count(&world, &shared).await,
        1,
        "bob still needs the shared escrow"
    );
    assert_eq!(status_of(&world, &bob).await["escrow_status"], "complete");

    let (code, _) = put_mode(&world, &admin, &bob, "private").await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(envelope_count(&world, &shared).await, 0);
    let (_, vaults) = world
        .bearer(&bob, Method::GET, "/api/v1/vaults", None)
        .await;
    assert_eq!(vaults["vaults"][0]["admin_visible"], false);
    assert_eq!(
        audit_count(&world, "account.credential_visibility_changed").await,
        4
    );

    // The affected account sees the change in its own audit feed.
    let (_, audit) = world
        .bearer(&alice, Method::GET, "/api/v1/audit", None)
        .await;
    let actions = audit["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["action"] == "account.credential_visibility_changed")
        .map(|event| event["actor_user_id"].clone())
        .collect::<Vec<_>>();
    assert_eq!(actions, vec![json!(admin.user_id), json!(admin.user_id)]);

    // An administrator may change their own mode; bad bodies and IDs fail.
    let (code, value) = put_mode(&world, &admin, &admin, "admin_visible").await;
    assert_eq!(code, StatusCode::OK, "{value}");
    for body in [
        json!({"mode": "public"}),
        json!({"mode": "private", "x": 1}),
        json!({}),
    ] {
        let (code, value) = world
            .bearer(
                &admin,
                Method::PUT,
                &format!(
                    "/api/v1/admin/accounts/{}/credential-visibility",
                    bob.user_id
                ),
                Some(body),
            )
            .await;
        assert_eq!(code, StatusCode::BAD_REQUEST);
        assert_eq!(value["error"]["code"], "INVALID_CREDENTIAL_VISIBILITY");
    }
    let (code, _) = world
        .bearer(
            &admin,
            Method::PUT,
            &format!(
                "/api/v1/admin/accounts/{}/credential-visibility",
                Uuid::new_v4()
            ),
            Some(json!({"mode": "private"})),
        )
        .await;
    assert_eq!(code, StatusCode::NOT_FOUND);
    let (code, value) = world
        .bearer(
            &admin,
            Method::PUT,
            "/api/v1/admin/accounts/not-a-uuid/credential-visibility",
            Some(json!({"mode": "private"})),
        )
        .await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"]["code"], "INVALID_ACCOUNT_ID");
    // A deleting account cannot be made visible but can always become private.
    sqlx::query("UPDATE users SET status='deleting' WHERE user_id=?")
        .bind(&bob.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    let (code, value) = put_mode(&world, &admin, &bob, "admin_visible").await;
    assert_eq!(code, StatusCode::CONFLICT);
    assert_eq!(value["error"]["code"], "ACCOUNT_DELETING");
}

#[tokio::test]
async fn instance_default_policy_is_audited_and_idempotent() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let path = "/api/v1/admin/credential-visibility";
    let (code, value) = world
        .bearer(
            &admin,
            Method::PUT,
            path,
            Some(json!({"default_mode": "admin_visible"})),
        )
        .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(value["default_mode"], "admin_visible");
    assert_eq!(
        value["counts"],
        json!({"admin_visible": 0, "private": 1, "pending": 0})
    );
    let (_, again) = world
        .bearer(
            &admin,
            Method::PUT,
            path,
            Some(json!({"default_mode": "admin_visible"})),
        )
        .await;
    assert_eq!(again["default_mode"], "admin_visible");
    assert_eq!(
        audit_count(&world, "instance.credential_policy_changed").await,
        1
    );
    let updated_by: Option<String> =
        sqlx::query_scalar("SELECT updated_by_user_id FROM instance_credential_policy WHERE id=1")
            .fetch_one(&world.state.db)
            .await
            .unwrap();
    assert_eq!(updated_by.as_deref(), Some(admin.user_id.as_str()));
    let (code, value) = world
        .bearer(
            &admin,
            Method::PUT,
            path,
            Some(json!({"default_mode": "visible"})),
        )
        .await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"]["code"], "INVALID_CREDENTIAL_VISIBILITY");
    // Existing accounts are not changed by the default.
    with_credentials(&world, &admin).await;
    let (_, me) = world.bearer(&admin, Method::GET, "/api/v1/me", None).await;
    assert_eq!(me["policy"]["credential_visibility"]["mode"], "private");
}

// ---------------------------------------------------------------------------
// Administrator record reads
// ---------------------------------------------------------------------------

#[tokio::test]
async fn escrowed_records_are_served_paged_and_every_read_is_recorded() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let private_member = world.account("private@example.test").await;
    let vault = world.vault(&user, &[(&private_member, "editor")]).await;
    deliver(&world, &vault, 1, &user).await;
    set_mode(&world, &user, "admin_visible").await;
    let fixture = create_escrow_key(&world, &admin).await;

    // No escrow yet.
    let (code, value) = admin_records(&world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );

    let mut live = Vec::new();
    for seq in 1..=3 {
        let record_id = Uuid::new_v4().to_string();
        let (revision, envelope) =
            put_record(&world, &vault, &user.device_id, &record_id, seq, false).await;
        live.push((record_id, revision, envelope));
    }
    live.sort_by(|a, b| a.0.cmp(&b.0));
    let tombstone = Uuid::new_v4().to_string();
    put_record(&world, &vault, &user.device_id, &tombstone, 4, true).await;

    // Private target and non-member target are denied without a view.
    for target in [&private_member, &admin] {
        let (code, value) =
            admin_records(&world, &admin, &records_path(&vault, target, ""), true).await;
        assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
        assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
    }
    assert_eq!(view_count(&world, &user).await, 0);
    assert_eq!(view_count(&world, &private_member).await, 0);
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_viewed").await,
        0
    );
    for (path, code) in [
        (
            format!("/api/v1/admin/credential-escrow/vaults/{vault}/records"),
            "INVALID_ACCOUNT_ID",
        ),
        (records_path(&vault, &user, "&limit=0"), "INVALID_LIMIT"),
        (records_path(&vault, &user, "&limit=501"), "INVALID_LIMIT"),
        (records_path(&vault, &user, "&after=zzz"), "INVALID_CURSOR"),
        (
            format!(
                "/api/v1/admin/credential-escrow/vaults/NOT-A-UUID/records?user_id={}",
                user.user_id
            ),
            "INVALID_VAULT_ID",
        ),
    ] {
        let (status, value) = admin_records(&world, &admin, &path, true).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{path}: {value}");
        assert_eq!(value["error"]["code"], code);
    }

    let (code, page) = admin_records(
        &world,
        &admin,
        &records_path(&vault, &user, "&limit=2"),
        true,
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{page}");
    let records = page["records"].as_array().unwrap();
    assert_eq!(records.len(), 2);
    for (record, (record_id, revision, envelope)) in records.iter().zip(&live) {
        assert_eq!(record["record_id"], *record_id);
        assert_eq!(record["revision_id"], *revision);
        assert_eq!(
            record["envelope"], *envelope,
            "envelopes are returned exactly as stored"
        );
        assert_eq!(record["author_device_id"], user.device_id);
        assert_eq!(
            record["author_signing_public_key"],
            URL_SAFE_NO_PAD.encode(user.signing.verifying_key().as_bytes())
        );
    }
    assert_eq!(page["next_after"], live[1].0);
    let (code, page) = admin_records(
        &world,
        &admin,
        &records_path(&vault, &user, &format!("&after={}", live[1].0)),
        true,
    )
    .await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(page["records"].as_array().unwrap().len(), 1);
    assert_eq!(page["records"][0]["record_id"], live[2].0);
    assert_eq!(page["next_after"], Value::Null);
    assert!(
        !page.to_string().contains(&tombstone),
        "deleted records are not served"
    );

    // Every served page is an instance audit event; within ten minutes the
    // user-facing view row and account event are coalesced per account.
    // The private co-member's entries were read too, so it is told as well.
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_viewed").await,
        2,
        "the administrator accountability log is never coalesced"
    );
    for account in [&user, &private_member] {
        assert_eq!(view_count(&world, account).await, 1);
        let status = status_of(&world, account).await;
        let views = status["admin_views"].as_array().unwrap();
        assert_eq!(views.len(), 1);
        assert_eq!(views[0]["admin_username"], ADMIN);
        assert_eq!(views[0]["vault_id"], vault);
        assert!(views[0]["viewed_at"].is_string());
    }
    assert_eq!(
        audit_count(&world, "account.credential_viewed_by_admin").await,
        2,
        "one coalesced account event for each affected member"
    );
    // The account audit feed attributes the read to the administrator.
    let (_, audit) = world
        .bearer(&user, Method::GET, "/api/v1/audit", None)
        .await;
    let viewed = audit["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["action"] == "account.credential_viewed_by_admin")
        .unwrap()
        .clone();
    assert_eq!(viewed["actor_user_id"], admin.user_id);
    assert_eq!(viewed["actor_device_id"], Value::Null);
    assert_eq!(viewed["resource_id"], vault);

    // An older view no longer coalesces.
    sqlx::query("UPDATE credential_admin_views SET viewed_at=?")
        .bind(
            (chrono::Utc::now() - chrono::Duration::minutes(11))
                .to_rfc3339_opts(chrono::SecondsFormat::Micros, true),
        )
        .execute(&world.state.db)
        .await
        .unwrap();
    assert_eq!(
        admin_records(&world, &admin, &records_path(&vault, &user, ""), true)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(view_count(&world, &user).await, 2);
    assert_eq!(
        status_of(&world, &user).await["admin_views"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    // A private member of the same Vault is listed without any deposit, while
    // the admin_visible member's listing carries it.
    for (account, expected) in [(&private_member, 0), (&user, 1)] {
        let (code, listing) = world
            .bearer(
                &admin,
                Method::GET,
                &format!(
                    "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                    account.user_id
                ),
                None,
            )
            .await;
        assert_eq!(code, StatusCode::OK, "{listing}");
        assert_eq!(listing["vaults"][0]["vault_id"], vault);
        assert_eq!(
            listing["vaults"][0]["escrow"].as_array().unwrap().len(),
            expected
        );
    }
    // A Vault in deletion grace is neither listed nor readable.
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?")
        .bind(&vault)
        .execute(&world.state.db)
        .await
        .unwrap();
    let (code, value) = admin_records(&world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
    let (_, listing) = world
        .bearer(
            &admin,
            Method::GET,
            &format!(
                "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                user.user_id
            ),
            None,
        )
        .await;
    assert_eq!(listing["vaults"], json!([]));
    sqlx::query("UPDATE vaults SET state='active' WHERE vault_id=?")
        .bind(&vault)
        .execute(&world.state.db)
        .await
        .unwrap();

    // Switching the account to private removes access immediately.
    let (code, _) = put_mode(&world, &admin, &user, "private").await;
    assert_eq!(code, StatusCode::OK);
    let (code, value) = admin_records(&world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::NOT_FOUND);
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
}

#[tokio::test]
async fn admin_views_are_pruned_and_survive_admin_account_deletion() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let vault = world.vault(&user, &[]).await;
    deliver(&world, &vault, 1, &user).await;
    set_mode(&world, &user, "admin_visible").await;
    let fixture = create_escrow_key(&world, &admin).await;
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    let base = chrono::Utc::now() - chrono::Duration::days(30);
    for index in 0..205 {
        sqlx::query("INSERT INTO credential_admin_views(view_id,target_user_id,admin_user_id,vault_id,viewed_at) VALUES(?,?,?,?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&user.user_id)
            .bind(&admin.user_id)
            .bind(&vault)
            .bind((base + chrono::Duration::seconds(index)).to_rfc3339_opts(chrono::SecondsFormat::Micros, true))
            .execute(&world.state.db)
            .await
            .unwrap();
    }
    assert_eq!(
        admin_records(&world, &admin, &records_path(&vault, &user, ""), true)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(view_count(&world, &user).await, 200);
    let status = status_of(&world, &user).await;
    let views = status["admin_views"].as_array().unwrap();
    assert_eq!(views.len(), 20, "the newest 20 views are returned");
    let newest: String = views[0]["viewed_at"].as_str().unwrap().to_owned();
    assert!(newest > (chrono::Utc::now() - chrono::Duration::minutes(1)).to_rfc3339());

    // A deleted administrator account leaves an anonymous view entry.
    sqlx::query("DELETE FROM users WHERE user_id=?")
        .bind(&admin.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    let status = status_of(&world, &user).await;
    assert_eq!(status["admin_views"][0]["admin_username"], Value::Null);
    assert_eq!(view_count(&world, &user).await, 200);
}

#[tokio::test]
async fn record_reads_respect_redaction_gate_and_rate_limit() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let user = world.account("user@example.test").await;
    let vault = world.vault(&user, &[]).await;
    deliver(&world, &vault, 1, &user).await;
    set_mode(&world, &user, "admin_visible").await;
    let fixture = create_escrow_key(&world, &admin).await;
    assert_eq!(
        deposit(&world, &user, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    let live = Uuid::new_v4().to_string();
    put_record(&world, &vault, &user.device_id, &live, 1, false).await;
    let redacted = Uuid::new_v4().to_string();
    let (deleted_revision, _) =
        put_record(&world, &vault, &user.device_id, &redacted, 2, true).await;
    sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,2)")
        .bind(&vault)
        .bind(&redacted)
        .bind(&deleted_revision)
        .execute(&world.state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,2,3,?)")
        .bind(Uuid::new_v4().to_string())
        .bind(&vault)
        .bind(&redacted)
        .bind(&deleted_revision)
        .bind(crate::now_rfc3339())
        .execute(&world.state.db)
        .await
        .unwrap();

    // Like ordinary reads, a pre-redaction client is refused for this Vault.
    let (code, value) =
        admin_records(&world, &admin, &records_path(&vault, &user, ""), false).await;
    assert_eq!(code, StatusCode::UPGRADE_REQUIRED, "{value}");
    assert_eq!(
        value["error"]["code"],
        "CLIENT_REDACTION_CAPABILITY_REQUIRED"
    );
    assert_eq!(
        view_count(&world, &user).await,
        0,
        "a refused read is not recorded"
    );
    let (code, page) = admin_records(&world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::OK, "{page}");
    assert_eq!(page["records"].as_array().unwrap().len(), 1);
    assert_eq!(page["records"][0]["record_id"], live);

    // Baseline per-administrator page limit.
    let now = chrono::Utc::now().timestamp();
    let key = format!("credential-escrow-records:{}", admin.user_id);
    while world.state.cloud.rate.check(&key, 120, 60, now).is_ok() {}
    let (code, value) = admin_records(&world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::TOO_MANY_REQUESTS, "{value}");
    assert_eq!(value["error"]["code"], "RATE_LIMITED");
}

#[tokio::test]
async fn vault_list_marks_admin_visible_vaults() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let member = world.account("member@example.test").await;
    let vault = world.vault(&owner, &[(&member, "viewer")]).await;
    let own = world.vault(&member, &[]).await;
    let flags = |value: &Value| {
        value["vaults"]
            .as_array()
            .unwrap()
            .iter()
            .map(|vault| {
                (
                    vault["vault_id"].as_str().unwrap().to_owned(),
                    vault["admin_visible"].as_bool().unwrap(),
                )
            })
            .collect::<std::collections::HashMap<_, _>>()
    };
    set_mode(&world, &owner, "admin_visible").await;
    let (_, list) = world
        .bearer(&member, Method::GET, "/api/v1/vaults", None)
        .await;
    assert_eq!(flags(&list)[&vault], false, "no escrow key yet");
    assert_eq!(status_of(&world, &member).await["admin_visible_vaults"], 0);
    create_escrow_key(&world, &admin).await;
    let (_, list) = world
        .bearer(&member, Method::GET, "/api/v1/vaults", None)
        .await;
    let flags_now = flags(&list);
    assert!(flags_now[&vault]);
    assert!(!flags_now[&own]);
    // Review finding: the private member's status counts the shared Vault
    // another member made administrator visible, so its client does not
    // claim administrators cannot read anything.
    let status = status_of(&world, &member).await;
    assert_eq!(status["mode"], "private");
    assert_eq!(status["admin_visible_vaults"], 1);
    assert_eq!(status_of(&world, &owner).await["admin_visible_vaults"], 1);
    // Same Vault set as the list: a Vault in deletion grace still counts, a
    // hidden membership does not.
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?")
        .bind(&vault)
        .execute(&world.state.db)
        .await
        .unwrap();
    assert_eq!(status_of(&world, &member).await["admin_visible_vaults"], 1);
    sqlx::query(
        "INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,'none',0)",
    )
    .bind(&vault)
    .bind(&member.user_id)
    .execute(&world.state.db)
    .await
    .unwrap();
    assert_eq!(status_of(&world, &member).await["admin_visible_vaults"], 0);
    let (_, list) = world
        .bearer(&member, Method::GET, "/api/v1/vaults", None)
        .await;
    assert!(!flags(&list).contains_key(&vault));
}

// ---------------------------------------------------------------------------
// Escrow invariant: no active admin_visible member, no deposits
// ---------------------------------------------------------------------------

/// Signed key rotation through the real route. `members` lists every
/// membership row with the role and state the owner signs for the new epoch;
/// active members' devices receive owner-signed key envelopes.
async fn rotate_membership(
    world: &World,
    owner: &Account,
    vault_id: &str,
    members: &[(&Account, &str, &str)],
) -> (StatusCode, Value) {
    let (epoch, version): (i64, i64) =
        sqlx::query_as("SELECT active_epoch,membership_version FROM vaults WHERE vault_id=?")
            .bind(vault_id)
            .fetch_one(&world.state.db)
            .await
            .unwrap();
    let previous_digest: Option<String> = sqlx::query_scalar(
        "SELECT digest FROM membership_manifests WHERE vault_id=? \
         ORDER BY membership_version DESC LIMIT 1",
    )
    .bind(vault_id)
    .fetch_optional(&world.state.db)
    .await
    .unwrap();
    let (new_epoch, new_version) = (epoch + 1, version + 1);
    let manifest = json!({
        "signer_device_id": owner.device_id,
        "key_epoch": new_epoch,
        "display_name_envelope": {"version": 1, "nonce": random_b64(24), "ciphertext": random_b64(32)},
        "members": members
            .iter()
            .map(|(account, role, state)| {
                json!({"user_id": account.user_id, "role": role, "state": state})
            })
            .collect::<Vec<_>>(),
    });
    let signature = sign_jcs(
        &owner.signing,
        &json!({
            "vault_id": vault_id,
            "membership_version": new_version,
            "previous_digest": previous_digest,
            "manifest": manifest,
        }),
    );
    let key_envelopes = members
        .iter()
        .filter(|(_, _, state)| *state == "active")
        .map(|(account, _, _)| {
            let envelope = json!({"opaque": account.user_id});
            let signed = json!({
                "vault_id": vault_id,
                "recipient_device_id": account.device_id,
                "key_epoch": new_epoch,
                "membership_version": new_version,
                "envelope": envelope,
            });
            json!({
                "recipient_device_id": account.device_id,
                "key_epoch": new_epoch,
                "membership_version": new_version,
                "envelope": envelope,
                "signature": sign_jcs(&owner.signing, &signed),
                "signer_device_id": owner.device_id,
            })
        })
        .collect::<Vec<_>>();
    world
        .bearer(
            owner,
            Method::POST,
            &format!("/api/v1/vaults/{vault_id}/keys/rotate"),
            Some(json!({
                "new_epoch": new_epoch,
                "membership": {
                    "membership_version": new_version,
                    "previous_digest": previous_digest,
                    "manifest": manifest,
                    "signature": signature,
                },
                "key_envelopes": key_envelopes,
            })),
        )
        .await
}

/// An additional active device of `account`.
async fn add_device(world: &World, account: &Account) -> (String, SigningKey) {
    let device_id = Uuid::new_v4().to_string();
    let signing = SigningKey::generate(&mut rand::rngs::OsRng);
    sqlx::query(
        "INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) \
         VALUES(?,?,'second',?,?,?)",
    )
    .bind(&device_id)
    .bind(&account.user_id)
    .bind(URL_SAFE_NO_PAD.encode(signing.verifying_key().as_bytes()))
    .bind(random_b64(32))
    .bind(crate::now_rfc3339())
    .execute(&world.state.db)
    .await
    .unwrap();
    (device_id, signing)
}

/// Requests deletion of `account` with an expired grace period and runs the
/// real purge maintenance.
async fn purge_account(world: &World, account: &Account) {
    let now = chrono::Utc::now().timestamp();
    sqlx::query("UPDATE users SET status='deleting' WHERE user_id=?")
        .bind(&account.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) \
         VALUES(?,?,?,?,'opaque-hmac')",
    )
    .bind(Uuid::new_v4().to_string())
    .bind(&account.user_id)
    .bind(now - 20)
    .bind(now - 10)
    .execute(&world.state.db)
    .await
    .unwrap();
    crate::account::purge_due_account_deletions(&world.state, now)
        .await
        .unwrap();
    let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE user_id=?")
        .bind(&account.user_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(remaining, 0, "the account was purged");
}

async fn escrow_listing(world: &World, admin: &Account, target: &Account) -> Value {
    let (code, listing) = world
        .bearer(
            admin,
            Method::GET,
            &format!(
                "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                target.user_id
            ),
            None,
        )
        .await;
    assert_eq!(code, StatusCode::OK, "{listing}");
    listing
}

fn missing_set(status: &Value) -> Vec<(String, i64)> {
    let mut items = status["missing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            (
                item["vault_id"].as_str().unwrap().to_owned(),
                item["key_epoch"].as_i64().unwrap(),
            )
        })
        .collect::<Vec<_>>();
    items.sort();
    items
}

/// Reviewer scenario: A and C (admin_visible) share V with private owner B.
/// A becomes private (deposits kept for C), then C is revoked by a signed
/// rotation. The deposits must go with C, so making B admin_visible later
/// gives the administrator nothing until B's own client deposits.
#[tokio::test]
async fn escrow_is_pruned_when_the_last_admin_visible_member_is_revoked() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let alice = world.account("alice@example.test").await;
    let carol = world.account("carol@example.test").await;
    let vault = world
        .vault(&owner, &[(&alice, "editor"), (&carol, "editor")])
        .await;
    for account in [&owner, &alice, &carol] {
        deliver(&world, &vault, 1, account).await;
    }
    let fixture = create_escrow_key(&world, &admin).await;
    for account in [&alice, &carol] {
        assert_eq!(
            put_mode(&world, &admin, account, "admin_visible").await.0,
            StatusCode::OK
        );
    }
    assert_eq!(
        deposit(&world, &alice, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        put_mode(&world, &admin, &alice, "private").await.0,
        StatusCode::OK
    );
    assert_eq!(
        envelope_count(&world, &vault).await,
        1,
        "carol is still admin_visible, so the deposit stays"
    );

    // An unrelated rotation that keeps carol active keeps the deposit.
    let (code, value) = rotate_membership(
        &world,
        &owner,
        &vault,
        &[
            (&owner, "owner", "active"),
            (&alice, "editor", "active"),
            (&carol, "editor", "active"),
        ],
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(envelope_count(&world, &vault).await, 1);

    // Revoking carol, the last admin_visible member, removes it.
    let (code, value) = rotate_membership(
        &world,
        &owner,
        &vault,
        &[
            (&owner, "owner", "active"),
            (&alice, "editor", "active"),
            (&carol, "editor", "revoked"),
        ],
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(value["active_key_epoch"], 3);
    assert_eq!(
        envelope_count(&world, &vault).await,
        0,
        "no deposit outlives the last admin_visible member"
    );
    let (_, vaults) = world
        .bearer(&owner, Method::GET, "/api/v1/vaults", None)
        .await;
    assert_eq!(vaults["vaults"][0]["admin_visible"], false);

    // The owner is made admin_visible: nothing is readable before its own
    // client deposits, and the status asks for every epoch it holds.
    assert_eq!(
        put_mode(&world, &admin, &owner, "admin_visible").await.0,
        StatusCode::OK
    );
    let (code, value) =
        admin_records(&world, &admin, &records_path(&vault, &owner, ""), true).await;
    assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_viewed").await,
        0
    );
    let status = status_of(&world, &owner).await;
    assert_eq!(status["escrow_status"], "pending");
    assert_eq!(
        missing_set(&status),
        vec![(vault.clone(), 1), (vault.clone(), 2), (vault.clone(), 3)]
    );
    let listing = escrow_listing(&world, &admin, &owner).await;
    assert_eq!(listing["vaults"][0]["escrow"], json!([]));

    // The owner's own deposit makes the Vault readable again.
    assert_eq!(
        deposit(&world, &owner, &fixture, &vault, 3).await.0,
        StatusCode::CREATED
    );
    let (code, value) =
        admin_records(&world, &admin, &records_path(&vault, &owner, ""), true).await;
    assert_eq!(code, StatusCode::OK, "{value}");
}

#[tokio::test]
async fn organization_none_restriction_prunes_orphaned_escrow() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let member = world.account("member@example.test").await;
    let other = world.account("other@example.test").await;
    let alone = world.vault(&owner, &[(&member, "editor")]).await;
    let shared = world
        .vault(&owner, &[(&member, "editor"), (&other, "editor")])
        .await;
    for vault in [&alone, &shared] {
        deliver(&world, vault, 1, &member).await;
    }
    let fixture = create_escrow_key(&world, &admin).await;
    set_mode(&world, &member, "admin_visible").await;
    set_mode(&world, &other, "admin_visible").await;
    for vault in [&alone, &shared] {
        assert_eq!(
            deposit(&world, &member, &fixture, vault, 1).await.0,
            StatusCode::CREATED
        );
    }

    // The member came from an organization grant that no longer covers it:
    // reconciliation restricts it to `none` in both Vaults.
    let now = chrono::Utc::now().timestamp();
    let mut tx = world.state.db.begin().await.unwrap();
    for vault in [&alone, &shared] {
        sqlx::query(
            "INSERT INTO cloud_vault_member_sources(vault_id,user_id,created_epoch) VALUES(?,?,?)",
        )
        .bind(vault)
        .bind(&member.user_id)
        .bind(now)
        .execute(&mut *tx)
        .await
        .unwrap();
        crate::cloud_orgs::reconcile_vault_tx(&mut tx, vault, now)
            .await
            .unwrap();
    }
    tx.commit().await.unwrap();
    let restricted: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM cloud_member_restrictions WHERE user_id=? AND max_role='none'",
    )
    .bind(&member.user_id)
    .fetch_one(&world.state.db)
    .await
    .unwrap();
    assert_eq!(restricted, 2);
    assert_eq!(
        envelope_count(&world, &alone).await,
        0,
        "the hidden member was the last admin_visible one"
    );
    assert_eq!(
        envelope_count(&world, &shared).await,
        1,
        "another active member is still admin_visible"
    );

    // A remaining member made admin_visible later sees nothing stale.
    set_mode(&world, &owner, "admin_visible").await;
    let (code, value) =
        admin_records(&world, &admin, &records_path(&alone, &owner, ""), true).await;
    assert_eq!(code, StatusCode::NOT_FOUND, "{value}");
    assert_eq!(value["error"]["code"], "CREDENTIAL_ESCROW_NOT_AVAILABLE");
}

#[tokio::test]
async fn account_purge_prunes_orphaned_escrow_and_keeps_survivors_verifiable() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let leaver = world.account("leaver@example.test").await;
    let stayer = world.account("stayer@example.test").await;
    let shared = world
        .vault(&owner, &[(&leaver, "editor"), (&stayer, "editor")])
        .await;
    let alone = world.vault(&owner, &[(&leaver, "editor")]).await;
    // The leaver's Vault keys reach only its second device; its first device
    // deposits and is referenced by nothing else in these Vaults.
    let (second_device, second_signing) = add_device(&world, &leaver).await;
    for vault in [&shared, &alone] {
        deliver_to_device(&world, vault, 1, &leaver.user_id, &second_device).await;
    }
    deliver(&world, &shared, 1, &stayer).await;
    let fixture = create_escrow_key(&world, &admin).await;
    set_mode(&world, &leaver, "admin_visible").await;
    set_mode(&world, &stayer, "admin_visible").await;
    for vault in [&shared, &alone] {
        assert_eq!(
            deposit(&world, &leaver, &fixture, vault, 1).await.0,
            StatusCode::CREATED
        );
    }
    let record_id = Uuid::new_v4().to_string();
    put_record(&world, &shared, &second_device, &record_id, 1, false).await;
    // A read through the leaver gives it an account-scope view event that
    // names the Vault.
    assert_eq!(
        admin_records(&world, &admin, &records_path(&alone, &leaver, ""), true)
            .await
            .0,
        StatusCode::OK
    );
    let leaver_scope =
        crate::audit::account_scope_id(&world.state.cursor_key, &leaver.user_id).unwrap();
    let owner_scope =
        crate::audit::account_scope_id(&world.state.cursor_key, &owner.user_id).unwrap();
    let vault_resources = |scope: String| {
        let db = world.state.db.clone();
        async move {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='account' AND scope_id=? \
                 AND action='account.credential_viewed_by_admin' AND resource_id IS NOT NULL",
            )
            .bind(scope)
            .fetch_one(&db)
            .await
            .unwrap()
        }
    };
    assert_eq!(vault_resources(leaver_scope.clone()).await, 1);
    assert_eq!(vault_resources(owner_scope.clone()).await, 1);

    purge_account(&world, &leaver).await;

    assert_eq!(
        envelope_count(&world, &alone).await,
        0,
        "the purged account was the Vault's last admin_visible member"
    );
    assert_eq!(envelope_count(&world, &shared).await, 1);
    // The purged account's view events keep no raw Vault ID; the surviving
    // owner's do.
    assert_eq!(vault_resources(leaver_scope).await, 0);
    assert_eq!(vault_resources(owner_scope).await, 1);

    // The surviving deposit and the purged author's record stay verifiable:
    // their device keys come from the Vault-scoped device archive.
    let listing = escrow_listing(&world, &admin, &stayer).await;
    let deposit_row = &listing["vaults"][0]["escrow"][0];
    assert_eq!(deposit_row["depositor_device_id"], leaver.device_id);
    let depositor_key = deposit_row["depositor_signing_public_key"]
        .as_str()
        .expect("depositor key resolved from the archive");
    assert_eq!(
        depositor_key,
        URL_SAFE_NO_PAD.encode(leaver.signing.verifying_key().as_bytes())
    );
    let sealed = URL_SAFE_NO_PAD
        .decode(deposit_row["sealed"].as_str().unwrap())
        .unwrap();
    let statement = json!({
        "format": "atermius-credential-escrow-deposit-v1",
        "instance_id": instance_id(&world),
        "key_id": fixture.key_id,
        "vault_id": shared,
        "key_epoch": 1,
        "sealed_sha256": URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed)),
    });
    let signature = URL_SAFE_NO_PAD
        .decode(deposit_row["signature"].as_str().unwrap())
        .unwrap();
    verifying(depositor_key)
        .verify(
            &serde_jcs::to_vec(&statement).unwrap(),
            &ed25519_dalek::Signature::from_slice(&signature).unwrap(),
        )
        .expect("an administrator client can still verify the deposit");
    let (code, page) =
        admin_records(&world, &admin, &records_path(&shared, &stayer, ""), true).await;
    assert_eq!(code, StatusCode::OK, "{page}");
    assert_eq!(page["records"][0]["author_device_id"], second_device);
    assert_eq!(
        page["records"][0]["author_signing_public_key"],
        URL_SAFE_NO_PAD.encode(second_signing.verifying_key().as_bytes())
    );
}

/// A read named after any member, even a disabled one, is shown to every
/// active member of the Vault, so the target choice cannot hide it.
#[tokio::test]
async fn a_read_is_recorded_for_every_active_member_of_the_vault() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let disabled = world.account("disabled@example.test").await;
    let private_member = world.account("private@example.test").await;
    let hidden = world.account("hidden@example.test").await;
    let revoked = world.account("revoked@example.test").await;
    let vault = world
        .vault(
            &owner,
            &[
                (&disabled, "editor"),
                (&private_member, "viewer"),
                (&hidden, "viewer"),
                (&revoked, "viewer"),
            ],
        )
        .await;
    sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
        .bind(&vault)
        .bind(&revoked.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,'none',0)",
    )
    .bind(&vault)
    .bind(&hidden.user_id)
    .execute(&world.state.db)
    .await
    .unwrap();
    deliver(&world, &vault, 1, &owner).await;
    let fixture = create_escrow_key(&world, &admin).await;
    set_mode(&world, &owner, "admin_visible").await;
    set_mode(&world, &disabled, "admin_visible").await;
    assert_eq!(
        deposit(&world, &owner, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    let (code, _) = world
        .bearer(
            &admin,
            Method::PUT,
            &format!("/api/v1/admin/accounts/{}/status", disabled.user_id),
            Some(json!({"status": "disabled"})),
        )
        .await;
    assert_eq!(code, StatusCode::OK);

    // The administrator names the disabled member, who cannot sign in.
    for _ in 0..2 {
        let (code, value) =
            admin_records(&world, &admin, &records_path(&vault, &disabled, ""), true).await;
        assert_eq!(code, StatusCode::OK, "{value}");
    }
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_viewed").await,
        2
    );
    for account in [&owner, &disabled, &private_member] {
        assert_eq!(
            view_count(&world, account).await,
            1,
            "coalesced per account"
        );
    }
    for account in [&hidden, &revoked] {
        assert_eq!(
            view_count(&world, account).await,
            0,
            "accounts without an active membership are not affected"
        );
    }
    assert_eq!(
        audit_count(&world, "account.credential_viewed_by_admin").await,
        3
    );
    // The active owner, whose credentials were read, sees the read.
    let status = status_of(&world, &owner).await;
    assert_eq!(status["admin_views"][0]["admin_username"], ADMIN);
    assert_eq!(status["admin_views"][0]["vault_id"], vault);
    let (_, audit) = world
        .bearer(&owner, Method::GET, "/api/v1/audit", None)
        .await;
    assert!(
        audit["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(
                |event| event["action"] == "account.credential_viewed_by_admin"
                    && event["actor_user_id"] == admin.user_id
                    && event["resource_id"] == vault
            )
    );
}

/// Review finding: an organization `none` restriction (or a revocation)
/// hides a member from the Vault, but the records it authored are still
/// served. The author must still be told that its credentials were read.
#[tokio::test]
async fn authors_of_served_records_are_told_even_when_hidden_or_revoked() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let hidden = world.account("hidden@example.test").await;
    let revoked = world.account("revoked@example.test").await;
    let bystander = world.account("bystander@example.test").await;
    let vault = world
        .vault(
            &owner,
            &[
                (&hidden, "editor"),
                (&revoked, "editor"),
                (&bystander, "viewer"),
            ],
        )
        .await;
    deliver(&world, &vault, 1, &owner).await;
    let fixture = create_escrow_key(&world, &admin).await;
    set_mode(&world, &owner, "admin_visible").await;
    assert_eq!(
        deposit(&world, &owner, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    let mut authored = Vec::new();
    for (seq, author) in [&hidden, &revoked].into_iter().enumerate() {
        let record_id = Uuid::new_v4().to_string();
        put_record(
            &world,
            &vault,
            &author.device_id,
            &record_id,
            seq as i64 + 1,
            false,
        )
        .await;
        authored.push(record_id);
    }
    sqlx::query(
        "INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,'none',0)",
    )
    .bind(&vault)
    .bind(&hidden.user_id)
    .execute(&world.state.db)
    .await
    .unwrap();
    sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
        .bind(&vault)
        .bind(&revoked.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    // The bystander, hidden too, authored nothing on the page.
    sqlx::query(
        "INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,'none',0)",
    )
    .bind(&vault)
    .bind(&bystander.user_id)
    .execute(&world.state.db)
    .await
    .unwrap();

    let (code, page) = admin_records(&world, &admin, &records_path(&vault, &owner, ""), true).await;
    assert_eq!(code, StatusCode::OK, "{page}");
    let served = page["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["author_device_id"].as_str().unwrap().to_owned())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        served,
        [hidden.device_id.clone(), revoked.device_id.clone()]
            .into_iter()
            .collect()
    );
    for account in [&owner, &hidden, &revoked] {
        assert_eq!(view_count(&world, account).await, 1, "told once");
    }
    assert_eq!(
        view_count(&world, &bystander).await,
        0,
        "a hidden member whose records were not served is not affected"
    );
    // Each author sees the read in its own status and account audit feed.
    for author in [&hidden, &revoked] {
        let status = status_of(&world, author).await;
        assert_eq!(status["admin_views"][0]["admin_username"], ADMIN);
        assert_eq!(status["admin_views"][0]["vault_id"], vault);
        let (_, audit) = world
            .bearer(author, Method::GET, "/api/v1/audit", None)
            .await;
        assert!(
            audit["events"].as_array().unwrap().iter().any(|event| {
                event["action"] == "account.credential_viewed_by_admin"
                    && event["actor_user_id"] == admin.user_id
            }),
            "{audit}"
        );
    }
    // Coalesced like every other affected account.
    assert_eq!(
        admin_records(&world, &admin, &records_path(&vault, &owner, ""), true)
            .await
            .0,
        StatusCode::OK
    );
    for account in [&owner, &hidden, &revoked] {
        assert_eq!(view_count(&world, account).await, 1);
    }
    assert_eq!(
        audit_count(&world, "account.credential_viewed_by_admin").await,
        3
    );
}

/// Review finding: the listing releases sealed Vault keys (and the Vault
/// names they open) without any trace. A listing that returns a deposit now
/// writes an instance audit event; one without deposits does not.
#[tokio::test]
async fn escrow_listing_that_releases_deposits_is_audited() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let visible = world.account("visible@example.test").await;
    let private_member = world.account("private@example.test").await;
    let vault = world.vault(&visible, &[(&private_member, "viewer")]).await;
    deliver(&world, &vault, 1, &visible).await;
    set_mode(&world, &visible, "admin_visible").await;
    let fixture = create_escrow_key(&world, &admin).await;

    // Nothing deposited yet: nothing released, nothing recorded.
    let listing = escrow_listing(&world, &admin, &visible).await;
    assert_eq!(listing["vaults"][0]["escrow"], json!([]));
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_listed").await,
        0
    );
    assert_eq!(
        deposit(&world, &visible, &fixture, &vault, 1).await.0,
        StatusCode::CREATED
    );
    // A private account's listing carries no deposit.
    let listing = escrow_listing(&world, &admin, &private_member).await;
    assert_eq!(listing["vaults"][0]["escrow"], json!([]));
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_listed").await,
        0
    );
    for expected in 1..=2 {
        let listing = escrow_listing(&world, &admin, &visible).await;
        assert_eq!(listing["vaults"][0]["escrow"].as_array().unwrap().len(), 1);
        assert_eq!(
            audit_count(&world, "instance.credential_escrow_listed").await,
            expected,
            "every releasing listing is recorded"
        );
    }
    // Instance scope, attributed to the administrator, HMACed account ID.
    let (actor, resource_type, resource_id): (Option<String>, String, Option<String>) =
        sqlx::query_as(
            "SELECT actor_user_id,resource_type,resource_id FROM audit_events \
             WHERE action='instance.credential_escrow_listed' LIMIT 1",
        )
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(actor.as_deref(), Some(admin.user_id.as_str()));
    assert_eq!(resource_type, "account");
    let resource_id = resource_id.expect("resource id");
    assert_ne!(resource_id, visible.user_id, "never the raw account ID");
    // Listing is still not a view of anyone's credentials.
    assert_eq!(view_count(&world, &visible).await, 0);
    assert_eq!(view_count(&world, &private_member).await, 0);
    // A non-admin is refused and records nothing.
    let (code, _) = world
        .bearer(
            &visible,
            Method::GET,
            &format!(
                "/api/v1/admin/credential-escrow/accounts/{}/vaults",
                visible.user_id
            ),
            None,
        )
        .await;
    assert_eq!(code, StatusCode::FORBIDDEN);
    assert_eq!(
        audit_count(&world, "instance.credential_escrow_listed").await,
        2
    );
}

/// Review finding: a private owner sharing a Vault with an `admin_visible`
/// account got no warning. The owner can now ask about the recipient before
/// inviting it, and the key-distribution list reports it for grantees.
#[tokio::test]
async fn vault_owner_can_check_a_recipient_before_sharing() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    let owner = world.account("owner@example.test").await;
    let editor = world.account("editor@example.test").await;
    let visible = world.account("visible@example.test").await;
    let private_user = world.account("private@example.test").await;
    let stranger = world.account("stranger@example.test").await;
    let vault = world.vault(&owner, &[(&editor, "editor")]).await;
    set_mode(&world, &visible, "admin_visible").await;
    let path = |device_id: &str| {
        format!("/api/v1/credential-visibility/vaults/{vault}/recipients/{device_id}")
    };

    // Reported before any escrow key exists: a key created later needs no
    // further consent from the owner.
    let (code, value) = world
        .bearer(&owner, Method::GET, &path(&visible.device_id), None)
        .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(
        value,
        json!({"recipient_admin_visible": true, "vault_admin_visible": false})
    );
    let (code, value) = world
        .bearer(&owner, Method::GET, &path(&private_user.device_id), None)
        .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(value["recipient_admin_visible"], false);

    // Only the owner of the active Vault may ask, with uniform answers for
    // unknown, malformed and inactive devices.
    let (code, value) = world
        .bearer(&editor, Method::GET, &path(&visible.device_id), None)
        .await;
    assert_eq!(code, StatusCode::FORBIDDEN, "{value}");
    assert_eq!(value["error"]["code"], "VAULT_ROLE_REQUIRED");
    let (code, _) = world
        .bearer(&stranger, Method::GET, &path(&visible.device_id), None)
        .await;
    assert_eq!(code, StatusCode::NOT_FOUND);
    for device_id in [
        Uuid::new_v4().to_string(),
        "not-a-uuid".to_owned(),
        visible.device_id.to_uppercase(),
    ] {
        let (code, _) = world
            .bearer(&owner, Method::GET, &path(&device_id), None)
            .await;
        assert_eq!(code, StatusCode::NOT_FOUND, "{device_id}");
    }
    let (revoked_device, _) = add_device(&world, &visible).await;
    sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
        .bind(&revoked_device)
        .execute(&world.state.db)
        .await
        .unwrap();
    let (code, _) = world
        .bearer(&owner, Method::GET, &path(&revoked_device), None)
        .await;
    assert_eq!(code, StatusCode::NOT_FOUND);
    let (code, _, _) = world
        .call(
            Method::GET,
            &path(&visible.device_id),
            HeaderMap::new(),
            None,
        )
        .await;
    assert_eq!(code, StatusCode::UNAUTHORIZED);
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?")
        .bind(&vault)
        .execute(&world.state.db)
        .await
        .unwrap();
    let (code, _) = world
        .bearer(&owner, Method::GET, &path(&visible.device_id), None)
        .await;
    assert_eq!(code, StatusCode::NOT_FOUND, "inactive Vault");
    sqlx::query("UPDATE vaults SET state='active' WHERE vault_id=?")
        .bind(&vault)
        .execute(&world.state.db)
        .await
        .unwrap();

    // The Vault's own flag follows the A2 definition.
    create_escrow_key(&world, &admin).await;
    set_mode(&world, &editor, "admin_visible").await;
    let (_, value) = world
        .bearer(&owner, Method::GET, &path(&private_user.device_id), None)
        .await;
    assert_eq!(
        value,
        json!({"recipient_admin_visible": false, "vault_admin_visible": true})
    );

    // Organization grants: the owner's key-distribution list says which
    // pending grantee is admin_visible before the owner delivers a key.
    let (code, org) = world
        .bearer(
            &admin,
            Method::POST,
            "/api/v1/orgs",
            Some(json!({"name": "Ops"})),
        )
        .await;
    assert_eq!(code, StatusCode::CREATED, "{org}");
    let org_id = org["org_id"].as_str().unwrap().to_owned();
    for (account, role) in [
        (&owner, "admin"),
        (&visible, "member"),
        (&private_user, "member"),
    ] {
        let (code, invite) = world
            .bearer(
                &admin,
                Method::POST,
                &format!("/api/v1/orgs/{org_id}/invitations"),
                Some(json!({"role": role})),
            )
            .await;
        assert_eq!(code, StatusCode::CREATED, "{invite}");
        let (code, _) = world
            .bearer(
                account,
                Method::POST,
                "/api/v1/org-invitations/accept",
                Some(json!({"token": invite["token"]})),
            )
            .await;
        assert_eq!(code, StatusCode::OK);
    }
    let (code, _) = world
        .bearer(
            &owner,
            Method::PUT,
            &format!("/api/v1/vaults/{vault}/organization"),
            Some(json!({"org_id": org_id})),
        )
        .await;
    assert_eq!(code, StatusCode::OK);
    for (revision, account) in [(1, &visible), (2, &private_user)] {
        let (code, value) = world
            .bearer(
                &owner,
                Method::PUT,
                &format!("/api/v1/vaults/{vault}/grants/user/{}", account.user_id),
                Some(json!({"role": "viewer", "expected_grants_revision": revision})),
            )
            .await;
        assert_eq!(code, StatusCode::OK, "{value}");
    }
    let (code, dist) = world
        .bearer(
            &owner,
            Method::GET,
            &format!("/api/v1/vaults/{vault}/key-distribution"),
            None,
        )
        .await;
    assert_eq!(code, StatusCode::OK, "{dist}");
    let flags = dist["pending_additions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|addition| {
            (
                addition["user_id"].as_str().unwrap().to_owned(),
                addition["admin_visible"].as_bool().unwrap(),
            )
        })
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(flags.len(), 2, "{dist}");
    assert!(flags[&visible.user_id]);
    assert!(!flags[&private_user.user_id]);
}

// ---------------------------------------------------------------------------
// Registration and invitations
// ---------------------------------------------------------------------------

fn registration_body(username: &str, enrollment: (&str, &str)) -> (Value, String) {
    let account_id = Uuid::new_v4().to_string();
    let device_id = Uuid::new_v4().to_string();
    let vault_id = Uuid::new_v4().to_string();
    let signing = SigningKey::generate(&mut rand::rngs::OsRng);
    let signing_public_key = URL_SAFE_NO_PAD.encode(signing.verifying_key().as_bytes());
    let encryption_public_key = random_b64(32);
    let fingerprint = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(
        URL_SAFE_NO_PAD.decode(&encryption_public_key).unwrap(),
    ));
    let device_signature = sign_jcs(
        &signing,
        &json!({
            "account_id": account_id,
            "device_id": device_id,
            "encryption_public_key": encryption_public_key,
            "signing_public_key": signing_public_key,
        }),
    );
    let manifest = json!({
        "key_epoch": 1,
        "members": [{
            "user_id": account_id,
            "role": "owner",
            "state": "active",
            "encryption_key_fingerprint": fingerprint,
        }],
        "signer_device_id": device_id,
    });
    let membership_signature = sign_jcs(
        &signing,
        &json!({"vault_id": vault_id, "membership_version": 1, "previous_digest": null, "manifest": manifest}),
    );
    let envelope = json!({"version": 1, "suite": "crypto_box_seal", "ciphertext": random_b64(48)});
    let key_signature = sign_jcs(
        &signing,
        &json!({
            "vault_id": vault_id,
            "recipient_device_id": device_id,
            "key_epoch": 1,
            "membership_version": 1,
            "envelope": envelope,
        }),
    );
    let mut body = json!({
        "account_id": account_id,
        "username": username,
        "kdf": {
            "id": "argon2id13",
            "salt": random_b64(16),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": random_b64(32),
        "account_key_envelope": {"version": 1, "nonce": random_b64(24), "ciphertext": random_b64(48)},
        "device": {
            "device_id": device_id,
            "name": "registration test",
            "signing_public_key": signing_public_key,
            "encryption_public_key": encryption_public_key,
            "signature": device_signature,
        },
        "initial_vault": {
            "vault_id": vault_id,
            "name_envelope": {"version": 1, "nonce": random_b64(24), "ciphertext": random_b64(32)},
            "key_epoch": 1,
            "membership_version": 1,
            "key_envelope": {
                "recipient_device_id": device_id,
                "key_epoch": 1,
                "membership_version": 1,
                "envelope": envelope,
                "signature": key_signature,
            },
            "membership": {
                "membership_version": 1,
                "previous_digest": null,
                "manifest": manifest,
                "signature": membership_signature,
            },
        },
    });
    body[enrollment.0] = json!(enrollment.1);
    (body, account_id)
}

async fn register(world: &World, body: Value) -> (StatusCode, Value) {
    let (status, _, value) = world
        .call(
            Method::POST,
            "/api/v1/auth/register",
            HeaderMap::new(),
            Some(body),
        )
        .await;
    (status, value)
}

async fn stored_mode(world: &World, user_id: &str) -> (String, Option<String>) {
    sqlx::query_as(
        "SELECT credential_visibility,credential_visibility_changed_at FROM users WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_one(&world.state.db)
    .await
    .unwrap()
}

#[tokio::test]
async fn bootstrap_account_uses_the_instance_default() {
    let world = World::new().await;
    let token = crate::create_bootstrap_token(&world.state).await.unwrap();
    let (body, account_id) = registration_body("first@example.test", ("bootstrap_token", &token));
    let (code, value) = register(&world, body).await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(
        stored_mode(&world, &account_id).await,
        ("private".to_owned(), None)
    );

    let world = World::new().await;
    sqlx::query("UPDATE instance_credential_policy SET default_visibility='admin_visible'")
        .execute(&world.state.db)
        .await
        .unwrap();
    let token = crate::create_bootstrap_token(&world.state).await.unwrap();
    let (body, account_id) = registration_body("first@example.test", ("bootstrap_token", &token));
    let (code, value) = register(&world, body).await;
    assert_eq!(code, StatusCode::OK, "{value}");
    assert_eq!(
        stored_mode(&world, &account_id).await,
        ("admin_visible".to_owned(), None)
    );
}

#[tokio::test]
async fn invitation_mode_or_instance_default_applies_at_registration() {
    let world = World::new().await;
    let admin = world.account(ADMIN).await;
    sqlx::query("UPDATE instance_meta SET setup_consumed_at=? WHERE id=1")
        .bind(crate::now_rfc3339())
        .execute(&world.state.db)
        .await
        .unwrap();
    let invite = |username: &'static str, mode: Value| {
        let world = &world;
        let admin = &admin;
        async move {
            let mut body = json!({"username": username});
            if !mode.is_null() || username.starts_with("explicit-null") {
                body["credential_visibility"] = mode;
            }
            let (code, value) = world
                .bearer(
                    admin,
                    Method::POST,
                    "/api/v1/admin/account-invitations",
                    Some(body),
                )
                .await;
            assert_eq!(code, StatusCode::CREATED, "{value}");
            value["invitation"].clone()
        }
    };
    let visible = invite("visible@example.test", json!("admin_visible")).await;
    assert_eq!(visible["credential_visibility"], "admin_visible");
    let private = invite("private@example.test", json!("private")).await;
    assert_eq!(private["credential_visibility"], "private");
    let defaulted = invite("default@example.test", Value::Null).await;
    assert_eq!(defaulted["credential_visibility"], Value::Null);
    let explicit_null = invite("explicit-null@example.test", Value::Null).await;
    assert_eq!(explicit_null["credential_visibility"], Value::Null);
    let (code, value) = world
        .bearer(
            &admin,
            Method::POST,
            "/api/v1/admin/account-invitations",
            Some(json!({"username": "bad@example.test", "credential_visibility": "public"})),
        )
        .await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"]["code"], "INVALID_ACCOUNT_INVITATION");

    let (_, list) = world
        .bearer(
            &admin,
            Method::GET,
            "/api/v1/admin/account-invitations",
            None,
        )
        .await;
    let listed = list["invitations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            (
                row["username"].as_str().unwrap().to_owned(),
                row["credential_visibility"].clone(),
            )
        })
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(listed["visible@example.test"], "admin_visible");
    assert_eq!(listed["private@example.test"], "private");
    assert_eq!(listed["default@example.test"], Value::Null);

    // Default changes after issuance still apply to default invitations.
    sqlx::query("UPDATE instance_credential_policy SET default_visibility='admin_visible'")
        .execute(&world.state.db)
        .await
        .unwrap();
    for (username, invitation, expected) in [
        ("visible@example.test", &visible, "admin_visible"),
        ("private@example.test", &private, "private"),
        ("default@example.test", &defaulted, "admin_visible"),
    ] {
        let (body, account_id) = registration_body(
            username,
            (
                "instance_invitation_token",
                invitation["token"].as_str().unwrap(),
            ),
        );
        let (code, value) = register(&world, body).await;
        assert_eq!(code, StatusCode::OK, "{value}");
        assert_eq!(
            stored_mode(&world, &account_id).await,
            (expected.to_owned(), None)
        );
    }
}

#[tokio::test]
async fn operator_cli_invitation_accepts_a_credential_visibility_mode() {
    let world = World::new().await;
    world.account(ADMIN).await;
    sqlx::query("UPDATE instance_meta SET setup_consumed_at=? WHERE id=1")
        .bind(crate::now_rfc3339())
        .execute(&world.state.db)
        .await
        .unwrap();
    crate::create_account_invitation_with_credential_visibility(
        &world.state,
        "cli@example.test",
        None,
        Some("admin_visible"),
    )
    .await
    .unwrap();
    let stored: Option<String> = sqlx::query_scalar(
        "SELECT credential_visibility FROM account_invitations WHERE username='cli@example.test'",
    )
    .fetch_one(&world.state.db)
    .await
    .unwrap();
    assert_eq!(stored.as_deref(), Some("admin_visible"));
    let error = crate::create_account_invitation_with_credential_visibility(
        &world.state,
        "cli2@example.test",
        None,
        Some("visible"),
    )
    .await
    .unwrap_err();
    assert_eq!(error.body.code, "INVALID_CREDENTIAL_VISIBILITY");
    crate::create_account_invitation(&world.state, "cli3@example.test", None)
        .await
        .unwrap();
    let stored: Option<String> = sqlx::query_scalar(
        "SELECT credential_visibility FROM account_invitations WHERE username='cli3@example.test'",
    )
    .fetch_one(&world.state.db)
    .await
    .unwrap();
    assert_eq!(stored, None);
}

// ---------------------------------------------------------------------------
// PostgreSQL scope
// ---------------------------------------------------------------------------

#[test]
fn pg_scope_guard_keeps_credential_visibility_routes_closed() {
    let vault = Uuid::new_v4();
    let user = Uuid::new_v4();
    for (method, path) in [
        (Method::GET, "/api/v1/credential-visibility".to_owned()),
        (
            Method::PUT,
            format!("/api/v1/credential-visibility/escrow/{vault}/1"),
        ),
        (
            Method::GET,
            "/api/v1/admin/credential-visibility".to_owned(),
        ),
        (
            Method::PUT,
            "/api/v1/admin/credential-visibility".to_owned(),
        ),
        (
            Method::PUT,
            format!("/api/v1/admin/accounts/{user}/credential-visibility"),
        ),
        (
            Method::POST,
            "/api/v1/admin/credential-escrow/key".to_owned(),
        ),
        (
            Method::DELETE,
            "/api/v1/admin/credential-escrow/key".to_owned(),
        ),
        (
            Method::PUT,
            "/api/v1/admin/credential-escrow/key/wrap".to_owned(),
        ),
        (
            Method::GET,
            format!("/api/v1/admin/credential-escrow/accounts/{user}/vaults"),
        ),
        (
            Method::GET,
            format!("/api/v1/admin/credential-escrow/vaults/{vault}/records"),
        ),
    ] {
        assert!(
            !crate::pg_sync_route_is_supported(&method, &path),
            "{method} {path}"
        );
    }
}

#[tokio::test]
async fn pg_mode_does_not_expose_credential_visibility() {
    let mut world = World::new().await;
    let admin = world.account(ADMIN).await;
    world.state.pg_sync_only = true;
    let (code, value) = world
        .bearer(&admin, Method::GET, "/api/v1/credential-visibility", None)
        .await;
    assert_eq!(code, StatusCode::SERVICE_UNAVAILABLE, "{value}");
    assert_eq!(value["error"]["code"], "PG_SYNC_SCOPE_LIMITED");
    let (code, value) = put_mode(&world, &admin, &admin, "admin_visible").await;
    assert_eq!(code, StatusCode::SERVICE_UNAVAILABLE, "{value}");
    let (_, _, info) = world
        .call(Method::GET, "/api/v1/instance", HeaderMap::new(), None)
        .await;
    assert!(
        !info["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("credential_visibility"))
    );
    assert!(info.get("credential_visibility_default").is_none());
    with_credentials(&world, &admin).await;
    let (code, me) = world.bearer(&admin, Method::GET, "/api/v1/me", None).await;
    assert_eq!(code, StatusCode::OK, "{me}");
    assert_eq!(me["policy"]["credential_visibility"], Value::Null);
    let (code, value) = world
        .bearer(
            &admin,
            Method::POST,
            "/api/v1/admin/account-invitations",
            Some(json!({"username": "pg@example.test", "credential_visibility": "admin_visible"})),
        )
        .await;
    assert_eq!(code, StatusCode::SERVICE_UNAVAILABLE, "{value}");
    assert_eq!(value["error"]["code"], "PG_SYNC_SCOPE_LIMITED");
}

// ---------------------------------------------------------------------------
// Cross-implementation vector (protocol/test-vectors/credential-escrow-v1.json)
// ---------------------------------------------------------------------------

const BASE32_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// RFC 4648 Base32, uppercase, without padding (the input is 20 bytes).
fn base32(bytes: &[u8]) -> String {
    let mut out = String::new();
    let (mut buffer, mut bits) = (0_u32, 0_u32);
    for byte in bytes {
        buffer = (buffer << 8) | u32::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(BASE32_ALPHABET[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(BASE32_ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    out
}

fn format_recovery_code(code: &str) -> String {
    code.as_bytes()
        .chunks(4)
        .map(|chunk| std::str::from_utf8(chunk).unwrap())
        .collect::<Vec<_>>()
        .join("-")
}

fn normalize_recovery_code(input: &str) -> String {
    input
        .chars()
        .filter(|c| *c != '-' && !c.is_whitespace())
        .collect::<String>()
        .to_uppercase()
}

/// Client `derivePurposeKey`: HKDF-SHA256, 32 zero-byte salt,
/// info = UTF-8 JCS of `["atermius", purpose, 1, context]`.
fn derive_purpose_key(input: &[u8], purpose: &str, context: &Value) -> ([u8; 32], String) {
    let info = serde_jcs::to_string(&json!(["atermius", purpose, 1, context])).unwrap();
    let mut out = [0_u8; 32];
    hkdf::Hkdf::<sha2::Sha256>::new(Some(&[0_u8; 32]), input)
        .expand(info.as_bytes(), &mut out)
        .unwrap();
    (out, info)
}

fn xchacha_seal(key: &[u8; 32], nonce: &[u8; 24], aad: &str, plaintext: &[u8]) -> Vec<u8> {
    use chacha20poly1305::{
        KeyInit, XChaCha20Poly1305, XNonce,
        aead::{Aead, Payload},
    };
    XChaCha20Poly1305::new_from_slice(key)
        .unwrap()
        .encrypt(
            XNonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .unwrap()
}

fn xchacha_open(key: &[u8; 32], nonce: &[u8], aad: &str, ciphertext: &[u8]) -> Vec<u8> {
    use chacha20poly1305::{
        KeyInit, XChaCha20Poly1305, XNonce,
        aead::{Aead, Payload},
    };
    XChaCha20Poly1305::new_from_slice(key)
        .unwrap()
        .decrypt(
            XNonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad: aad.as_bytes(),
            },
        )
        .unwrap()
}

fn fixed(byte: u8, len: usize) -> Vec<u8> {
    (0..len)
        .map(|index| byte.wrapping_add(index as u8))
        .collect()
}

/// Rebuilds every deterministic value from fixed test-only inputs; the
/// randomized `crypto_box_seal` output is taken from the stored vector (or
/// generated when the vector is being written).
fn build_escrow_vector(sealed: Option<Vec<u8>>) -> Value {
    let b64 = |bytes: &[u8]| URL_SAFE_NO_PAD.encode(bytes);
    let instance_id = "0b1e5c1a-7d2f-4e3a-9c4b-5d6e7f8091a2";
    let key_id = "4f6a2b1c-3d5e-4f70-8a9b-0c1d2e3f4a5b";
    let admin_account_id = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
    let admin_device_id = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e";
    let depositor_account_id = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";
    let depositor_device_id = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f70";
    let vault_id = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7081";
    let created_at = "2026-11-13T00:00:00Z";
    let key_epoch = 3_i64;

    let instance_seed: [u8; 32] = fixed(0x10, 32).try_into().unwrap();
    let instance_key = SigningKey::from_bytes(&instance_seed);
    let admin_seed: [u8; 32] = fixed(0x30, 32).try_into().unwrap();
    let admin_key = SigningKey::from_bytes(&admin_seed);
    let depositor_seed: [u8; 32] = fixed(0x50, 32).try_into().unwrap();
    let depositor_key = SigningKey::from_bytes(&depositor_seed);
    let escrow_secret_bytes: [u8; 32] = fixed(0x70, 32).try_into().unwrap();
    let escrow_secret = crypto_box::SecretKey::from_bytes(escrow_secret_bytes);
    let escrow_public = b64(escrow_secret.public_key().as_bytes());
    let account_key = fixed(0x90, 32);
    let vault_key = fixed(0xb0, 32);
    let account_wrap_nonce: [u8; 24] = fixed(0xd0, 24).try_into().unwrap();
    let recovery_nonce: [u8; 24] = fixed(0xe0, 24).try_into().unwrap();
    let recovery_salt = fixed(0xf0, 16);
    let recovery_code_bytes = fixed(0x21, 20);

    let signed_payload = crate::credential_visibility::escrow_key_signed_payload(
        instance_id,
        key_id,
        &escrow_public,
        created_at,
    )
    .unwrap();
    let creation = String::from_utf8(
        crate::credential_visibility::escrow_key_creation_bytes(
            instance_id,
            key_id,
            &escrow_public,
            admin_account_id,
            admin_device_id,
        )
        .unwrap(),
    )
    .unwrap();

    let (wrap_key, wrap_info) = derive_purpose_key(
        &account_key,
        "credential-escrow-key-wrap",
        &json!({"version": 1, "key_id": key_id}),
    );
    let wrap_aad = serde_jcs::to_string(&json!({
        "context": "credential-escrow-key",
        "version": 1,
        "instance_id": instance_id,
        "key_id": key_id,
        "account_id": admin_account_id,
    }))
    .unwrap();
    let account_wrap_ciphertext = xchacha_seal(
        &wrap_key,
        &account_wrap_nonce,
        &wrap_aad,
        &escrow_secret_bytes,
    );

    let recovery_code_plain = base32(&recovery_code_bytes);
    let recovery_code = format_recovery_code(&recovery_code_plain);
    let normalized = normalize_recovery_code(&format!(" {} ", recovery_code.to_lowercase()));
    assert_eq!(normalized, recovery_code_plain);
    let mut recovery_kdf_key = [0_u8; 32];
    argon2::Argon2::new(
        argon2::Algorithm::Argon2id,
        argon2::Version::V0x13,
        argon2::Params::new(65_536, 3, 1, Some(32)).unwrap(),
    )
    .hash_password_into(normalized.as_bytes(), &recovery_salt, &mut recovery_kdf_key)
    .unwrap();
    let recovery_aad = serde_jcs::to_string(&json!({
        "context": "credential-escrow-recovery",
        "version": 1,
        "instance_id": instance_id,
        "key_id": key_id,
    }))
    .unwrap();
    let recovery_ciphertext = xchacha_seal(
        &recovery_kdf_key,
        &recovery_nonce,
        &recovery_aad,
        &escrow_secret_bytes,
    );

    let deposit_plaintext = serde_jcs::to_string(&json!({
        "format": ESCROW_SEALED_FORMAT,
        "instance_id": instance_id,
        "key_id": key_id,
        "vault_id": vault_id,
        "key_epoch": key_epoch,
        "vault_key": b64(&vault_key),
    }))
    .unwrap();
    let sealed = sealed.unwrap_or_else(|| {
        escrow_secret
            .public_key()
            .seal(&mut rand::rngs::OsRng, deposit_plaintext.as_bytes())
            .unwrap()
    });
    let deposit_statement = String::from_utf8(
        crate::credential_visibility::escrow_deposit_bytes(
            instance_id,
            key_id,
            vault_id,
            key_epoch,
            &b64(&sha2::Sha256::digest(&sealed)),
        )
        .unwrap(),
    )
    .unwrap();

    json!({
        "description": "Test-only keys. Credential visibility v1 escrow formats: instance-signed escrow key descriptor, administrator creation statement, account wrap (HKDF purpose key + XChaCha20-Poly1305), recovery code and Argon2id recovery wrap, and a sealed, device-signed Vault-key deposit. All JSON strings are RFC 8785 JCS; base64url has no padding. `deposit.sealed` is randomized (crypto_box_seal) and must be opened, not recomputed.",
        "instance_id": instance_id,
        "instance_signing_seed": b64(&instance_seed),
        "instance_signing_public_key": b64(instance_key.verifying_key().as_bytes()),
        "admin_account_id": admin_account_id,
        "admin_device_id": admin_device_id,
        "admin_device_signing_seed": b64(&admin_seed),
        "admin_device_signing_public_key": b64(admin_key.verifying_key().as_bytes()),
        "admin_account_key": b64(&account_key),
        "escrow_secret_key": b64(&escrow_secret_bytes),
        "escrow_public_key": escrow_public,
        "key_id": key_id,
        "created_at": created_at,
        "descriptor": {
            "key_id": key_id,
            "public_key": escrow_public,
            "signed_payload": signed_payload,
            "signature": b64(&instance_key.sign(signed_payload.as_bytes()).to_bytes()),
            "created_at": created_at,
        },
        "creation_statement": creation,
        "creator_signature": b64(&admin_key.sign(creation.as_bytes()).to_bytes()),
        "account_wrap_info": wrap_info,
        "account_wrap_key": b64(&wrap_key),
        "account_wrap_aad": wrap_aad,
        "account_wrap": {
            "version": 1,
            "nonce": b64(&account_wrap_nonce),
            "ciphertext": b64(&account_wrap_ciphertext),
        },
        "recovery_code_bytes": b64(&recovery_code_bytes),
        "recovery_code": recovery_code,
        "recovery_code_normalized": recovery_code_plain,
        "recovery_kdf_key": b64(&recovery_kdf_key),
        "recovery_wrap_aad": recovery_aad,
        "recovery_wrap": {
            "version": 1,
            "kdf": {
                "id": "argon2id13",
                "salt": b64(&recovery_salt),
                "mem_kib": 65536,
                "iterations": 3,
                "parallelism": 1,
            },
            "nonce": b64(&recovery_nonce),
            "ciphertext": b64(&recovery_ciphertext),
        },
        "depositor_account_id": depositor_account_id,
        "depositor_device_id": depositor_device_id,
        "depositor_device_signing_seed": b64(&depositor_seed),
        "depositor_device_signing_public_key": b64(depositor_key.verifying_key().as_bytes()),
        "vault_id": vault_id,
        "key_epoch": key_epoch,
        "vault_key": b64(&vault_key),
        "deposit_plaintext": deposit_plaintext,
        "deposit_statement": deposit_statement,
        "deposit": {
            "key_id": key_id,
            "sealed": b64(&sealed),
            "signature": b64(&depositor_key.sign(deposit_statement.as_bytes()).to_bytes()),
        },
    })
}

/// Shared with the client implementation: every deterministic value must be
/// reproduced exactly, the sealed deposit must open, and the server-side
/// shape validators must accept the wraps.
/// Regenerate with ATERMIUS_WRITE_CREDENTIAL_ESCROW_VECTOR=1.
#[test]
fn credential_escrow_cross_implementation_vector() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../protocol/test-vectors/credential-escrow-v1.json");
    if std::env::var_os("ATERMIUS_WRITE_CREDENTIAL_ESCROW_VECTOR").is_some() {
        let vector = build_escrow_vector(None);
        std::fs::write(&path, serde_json::to_string_pretty(&vector).unwrap() + "\n").unwrap();
        return;
    }
    let stored: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let text = |key: &str| stored[key].as_str().unwrap().to_owned();
    let bytes = |value: &Value| URL_SAFE_NO_PAD.decode(value.as_str().unwrap()).unwrap();
    let sealed = bytes(&stored["deposit"]["sealed"]);
    assert_eq!(build_escrow_vector(Some(sealed.clone())), stored);

    // Descriptor verifies against the instance key as clients check it.
    let instance_public = verifying(&text("instance_signing_public_key"));
    let descriptor = &stored["descriptor"];
    instance_public
        .verify(
            descriptor["signed_payload"].as_str().unwrap().as_bytes(),
            &ed25519_dalek::Signature::from_slice(&bytes(&descriptor["signature"])).unwrap(),
        )
        .unwrap();
    // Creator and deposit signatures verify with the server's device check.
    crate::auth::verify_key_signature(
        &text("admin_device_signing_public_key"),
        &text("creator_signature"),
        text("creation_statement").as_bytes(),
    )
    .unwrap();
    crate::auth::verify_key_signature(
        &text("depositor_device_signing_public_key"),
        stored["deposit"]["signature"].as_str().unwrap(),
        text("deposit_statement").as_bytes(),
    )
    .unwrap();
    // The administrator opens the deposit and the wraps.
    let escrow_secret: [u8; 32] = bytes(&stored["escrow_secret_key"]).try_into().unwrap();
    let opened = crypto_box::SecretKey::from_bytes(escrow_secret)
        .unseal(&sealed)
        .unwrap();
    assert_eq!(opened, text("deposit_plaintext").into_bytes());
    let wrap_key: [u8; 32] = bytes(&stored["account_wrap_key"]).try_into().unwrap();
    assert_eq!(
        xchacha_open(
            &wrap_key,
            &bytes(&stored["account_wrap"]["nonce"]),
            &text("account_wrap_aad"),
            &bytes(&stored["account_wrap"]["ciphertext"]),
        ),
        escrow_secret
    );
    let recovery_key: [u8; 32] = bytes(&stored["recovery_kdf_key"]).try_into().unwrap();
    assert_eq!(
        xchacha_open(
            &recovery_key,
            &bytes(&stored["recovery_wrap"]["nonce"]),
            &text("recovery_wrap_aad"),
            &bytes(&stored["recovery_wrap"]["ciphertext"]),
        ),
        escrow_secret
    );
    let account_wrap: crate::credential_visibility::AccountWrap =
        serde_json::from_value(stored["account_wrap"].clone()).unwrap();
    account_wrap.validated_json().unwrap();
    let recovery_wrap: crate::credential_visibility::RecoveryWrap =
        serde_json::from_value(stored["recovery_wrap"].clone()).unwrap();
    recovery_wrap.validated_json().unwrap();
    assert_eq!(text("recovery_code").len(), 39);
}

fn verifying(public_b64: &str) -> ed25519_dalek::VerifyingKey {
    let bytes: [u8; 32] = URL_SAFE_NO_PAD
        .decode(public_b64)
        .unwrap()
        .try_into()
        .unwrap();
    ed25519_dalek::VerifyingKey::from_bytes(&bytes).unwrap()
}

// ---------------------------------------------------------------------------
// Storage at rest: SQLCipher encryption and backup/restore of escrow data
// ---------------------------------------------------------------------------

const AT_REST_CANARY_USER: &str = "escrow-at-rest-canary-91c4@example.test";
const ESCROW_DESCRIPTOR_FORMAT: &str = "atermius-credential-escrow-key-v1";

fn private_test_root(label: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::temp_dir().join(format!("atermius-cv-{label}-{}", Uuid::new_v4()));
    std::fs::create_dir(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

fn write_key_file(path: &std::path::Path, byte: u8) {
    crate::secure_file::write_new_private_key(path, &[byte; 32]).unwrap();
}

/// Every regular file below `directory`, without following symlinks: the
/// database, its `-wal`/`-shm` sidecars and the instance key files.
fn files_below(directory: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        let file_type = std::fs::symlink_metadata(&path).unwrap().file_type();
        if file_type.is_dir() {
            files.extend(files_below(&path));
        } else if file_type.is_file() {
            files.push(path);
        }
    }
    files
}

fn file_contains(path: &std::path::Path, needle: &[u8]) -> bool {
    std::fs::read(path)
        .map(|bytes| bytes.windows(needle.len()).any(|window| window == needle))
        .unwrap_or(false)
}

fn files_containing(directory: &std::path::Path, needle: &str) -> Vec<std::path::PathBuf> {
    files_below(directory)
        .into_iter()
        .filter(|path| file_contains(path, needle.as_bytes()))
        .collect()
}

/// What the storage tests seed through the real routes.
struct SeededEscrow {
    admin: Account,
    user: Account,
    vault: String,
    fixture: EscrowFixture,
    sealed: String,
    record_id: String,
}

/// Key creation, an `admin_visible` account, a deposit and one administrator
/// read of the account's records (which writes the view row).
async fn seed_escrow_through_routes(world: &World, username: &str) -> SeededEscrow {
    let admin = world.account(ADMIN).await;
    let user = world.account(username).await;
    let vault = world.vault(&user, &[]).await;
    deliver(world, &vault, 1, &user).await;
    let (code, value) = put_mode(world, &admin, &user, "admin_visible").await;
    assert_eq!(code, StatusCode::OK, "{value}");
    let fixture = create_escrow_key(world, &admin).await;
    let body = deposit_body(world, &user, &fixture, &vault, 1);
    let sealed = body["sealed"].as_str().unwrap().to_owned();
    let (code, value) = world
        .bearer(
            &user,
            Method::PUT,
            &format!("/api/v1/credential-visibility/escrow/{vault}/1"),
            Some(body),
        )
        .await;
    assert_eq!(code, StatusCode::CREATED, "{value}");
    let record_id = Uuid::new_v4().to_string();
    put_record(world, &vault, &user.device_id, &record_id, 1, false).await;
    let (code, page) = admin_records(world, &admin, &records_path(&vault, &user, ""), true).await;
    assert_eq!(code, StatusCode::OK, "{page}");
    assert_eq!(page["records"][0]["record_id"], record_id);
    assert_eq!(view_count(world, &user).await, 1);
    let status = status_of(world, &user).await;
    assert_eq!(status["escrow_status"], "complete");
    assert_eq!(status["admin_views"][0]["admin_username"], ADMIN);
    SeededEscrow {
        admin,
        user,
        vault,
        fixture,
        sealed,
        record_id,
    }
}

#[tokio::test]
async fn escrow_data_never_appears_in_the_raw_bytes_of_a_sqlcipher_database() {
    use crate::database::{DatabaseEncryption, DatabaseFileFormat, detect_database_file};

    let root = private_test_root("at-rest");
    let key_file = root.join("database.key");
    write_key_file(&key_file, 0x5a);
    // The unkeyed control proves the markers are really stored, so the
    // encrypted assertions cannot pass vacuously.
    for keyed in [true, false] {
        let data_dir = root.join(if keyed { "encrypted" } else { "control" });
        let world = World::at(data_dir.clone(), keyed.then(|| key_file.clone())).await;
        assert_eq!(
            world.state.database_encryption,
            if keyed {
                DatabaseEncryption::Enabled
            } else {
                DatabaseEncryption::Disabled
            }
        );
        let seeded = seed_escrow_through_routes(&world, AT_REST_CANARY_USER).await;
        let markers = [
            ("descriptor format", ESCROW_DESCRIPTOR_FORMAT.to_owned()),
            ("username", AT_REST_CANARY_USER.to_owned()),
            ("sealed deposit prefix", seeded.sealed[..24].to_owned()),
            ("escrow public key", seeded.fixture.public_key.clone()),
            ("viewed account id", seeded.user.user_id.clone()),
        ];
        if keyed {
            // WAL frames are encrypted too, before any checkpoint.
            for (label, marker) in &markers {
                let hits = files_containing(&data_dir, marker);
                assert!(
                    hits.is_empty(),
                    "{label} readable before checkpoint in {hits:?}"
                );
            }
        }
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .fetch_all(&world.state.db)
            .await
            .unwrap();
        world.state.db.close().await;

        let database = data_dir.join("atermius.db");
        assert_eq!(
            detect_database_file(&database).unwrap(),
            if keyed {
                DatabaseFileFormat::Encrypted
            } else {
                DatabaseFileFormat::Plaintext
            }
        );
        for (label, marker) in &markers {
            let hits = files_containing(&data_dir, marker);
            if keyed {
                assert!(hits.is_empty(), "{label} readable in {hits:?}");
            } else {
                assert!(
                    hits.contains(&database),
                    "control: {label} must be stored in the unkeyed database file"
                );
            }
        }
    }
    std::fs::remove_dir_all(root).unwrap();
}

/// Every row of the credential-visibility tables and the new columns of
/// `users` and `account_invitations`, in a stable order.
async fn credential_visibility_rows(world: &World) -> Vec<String> {
    let mut rows = Vec::new();
    for table in [
        "instance_credential_policy",
        "credential_escrow_keys",
        "credential_escrow_key_wraps",
        "credential_escrow_envelopes",
        "credential_admin_views",
    ] {
        let columns: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT name FROM pragma_table_info('{table}') ORDER BY cid"
        ))
        .fetch_all(&world.state.db)
        .await
        .unwrap();
        assert!(!columns.is_empty(), "{table} exists");
        let table_rows: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT json_array({}) FROM {table} ORDER BY 1",
            columns.join(",")
        ))
        .fetch_all(&world.state.db)
        .await
        .unwrap();
        assert!(!table_rows.is_empty(), "{table} is seeded");
        rows.extend(table_rows.into_iter().map(|row| format!("{table}:{row}")));
    }
    for (label, select) in [
        (
            "users",
            "SELECT json_array(user_id,username,credential_visibility,\
             credential_visibility_changed_at) FROM users ORDER BY 1",
        ),
        (
            "account_invitations",
            "SELECT json_array(username,credential_visibility) FROM account_invitations ORDER BY 1",
        ),
    ] {
        let table_rows: Vec<String> = sqlx::query_scalar(select)
            .fetch_all(&world.state.db)
            .await
            .unwrap();
        rows.extend(table_rows.into_iter().map(|row| format!("{label}:{row}")));
    }
    rows
}

async fn admin_policy(world: &World, admin: &Account) -> Value {
    let (code, value) = world
        .bearer(
            admin,
            Method::GET,
            "/api/v1/admin/credential-visibility",
            None,
        )
        .await;
    assert_eq!(code, StatusCode::OK, "{value}");
    value
}

#[tokio::test]
async fn backup_and_restore_keep_escrow_data_on_plaintext_and_encrypted_instances() {
    use crate::database::{DatabaseFileFormat, detect_database_file};

    let root = private_test_root("restore");
    let backup_key = root.join("backup.key");
    write_key_file(&backup_key, 0x51);
    let key_a = root.join("database-a.key");
    let key_b = root.join("database-b.key");
    write_key_file(&key_a, 0xa1);
    write_key_file(&key_b, 0xb2);
    for (label, source_key, target_key) in [
        ("plaintext", None, None),
        (
            "encrypted-rekeyed",
            Some(key_a.clone()),
            Some(key_b.clone()),
        ),
        (
            "encrypted-same-key",
            Some(key_a.clone()),
            Some(key_a.clone()),
        ),
        ("plaintext-to-encrypted", None, Some(key_b.clone())),
    ] {
        let source_dir = root.join(format!("{label}-source"));
        let world = World::at(source_dir.clone(), source_key.clone()).await;
        sqlx::query("UPDATE instance_meta SET setup_consumed_at=? WHERE id=1")
            .bind(crate::now_rfc3339())
            .execute(&world.state.db)
            .await
            .unwrap();
        let seeded = seed_escrow_through_routes(&world, "user@example.test").await;
        let (code, value) = world
            .bearer(
                &seeded.admin,
                Method::PUT,
                "/api/v1/admin/credential-visibility",
                Some(json!({"default_mode": "admin_visible"})),
            )
            .await;
        assert_eq!(code, StatusCode::OK, "{value}");
        let (code, value) = world
            .bearer(
                &seeded.admin,
                Method::POST,
                "/api/v1/admin/account-invitations",
                Some(json!({
                    "username": "invited@example.test",
                    "credential_visibility": "admin_visible",
                })),
            )
            .await;
        assert_eq!(code, StatusCode::CREATED, "{value}");
        let invitation_token = value["invitation"]["token"].as_str().unwrap().to_owned();

        let rows = credential_visibility_rows(&world).await;
        let policy = admin_policy(&world, &seeded.admin).await;
        assert_eq!(policy["default_mode"], "admin_visible");
        assert!(policy["caller_wrap"].is_object() && policy["recovery_wrap"].is_object());
        let status = status_of(&world, &seeded.user).await;
        let listing = escrow_listing(&world, &seeded.admin, &seeded.user).await;
        assert_eq!(listing["vaults"][0]["escrow"][0]["sealed"], seeded.sealed);

        let archive = root.join(format!("{label}.atb"));
        crate::backup_instance(
            &world.state.config,
            &format!("sqlite://{}/atermius.db?mode=rwc", source_dir.display()),
            &archive,
            &backup_key,
        )
        .await
        .unwrap();
        let target_dir = root.join(format!("{label}-restored"));
        let mut restore_config = (*world.state.config).clone();
        restore_config.database_key_file = target_key.clone();
        let result = crate::restore_instance_with_runtime_policy_drift(
            restore_config,
            &archive,
            &backup_key,
            &target_dir,
            false,
        )
        .await
        .unwrap();
        assert!(result.accepted_runtime_policy_drift_fields.is_empty());
        let source_instance_id = instance_id(&world);
        world.state.db.close().await;

        let database = target_dir.join("atermius.db");
        assert_eq!(
            detect_database_file(&database).unwrap(),
            if target_key.is_some() {
                DatabaseFileFormat::Encrypted
            } else {
                DatabaseFileFormat::Plaintext
            },
            "{label}"
        );
        for marker in [ESCROW_DESCRIPTOR_FORMAT, &seeded.sealed[..24]] {
            assert_eq!(
                !files_containing(&target_dir, marker).is_empty(),
                target_key.is_none(),
                "{label}: escrow rows are plaintext only in a plaintext target"
            );
        }

        let restored = World::at(target_dir.clone(), target_key.clone()).await;
        assert_eq!(instance_id(&restored), source_instance_id);
        assert_eq!(restored.state.instance.generation, result.generation);
        assert_eq!(credential_visibility_rows(&restored).await, rows, "{label}");

        // Restore revoked every session; the same devices sign in again.
        let (code, _) = restored
            .bearer(
                &seeded.user,
                Method::GET,
                "/api/v1/credential-visibility",
                None,
            )
            .await;
        assert_eq!(code, StatusCode::UNAUTHORIZED);
        let admin = restored
            .sign_in(
                &seeded.admin.user_id,
                &seeded.admin.device_id,
                seeded.admin.signing.clone(),
            )
            .await;
        let user = restored
            .sign_in(
                &seeded.user.user_id,
                &seeded.user.device_id,
                seeded.user.signing.clone(),
            )
            .await;
        assert_eq!(admin_policy(&restored, &admin).await, policy, "{label}");
        let restored_status = status_of(&restored, &user).await;
        assert_eq!(restored_status, status, "{label}");
        verify_descriptor(
            &restored,
            &restored_status["escrow_key"],
            &seeded.fixture.key_id,
            &seeded.fixture.public_key,
        );
        let restored_listing = escrow_listing(&restored, &admin, &user).await;
        assert_eq!(restored_listing, listing, "{label}");
        // The restored deposit still opens with the escrow key.
        let sealed = URL_SAFE_NO_PAD
            .decode(
                restored_listing["vaults"][0]["escrow"][0]["sealed"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap();
        let inner: Value =
            serde_json::from_slice(&seeded.fixture.secret.unseal(&sealed).unwrap()).unwrap();
        assert_eq!(inner["vault_key"], vault_key_for(&seeded.vault, 1));
        // Administrators can still read the records, and each read is still
        // accounted for.
        let (code, page) = admin_records(
            &restored,
            &admin,
            &records_path(&seeded.vault, &user, ""),
            true,
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{page}");
        assert_eq!(page["records"][0]["record_id"], seeded.record_id);
        assert_eq!(
            audit_count(&restored, "instance.credential_escrow_viewed").await,
            2
        );
        // The invitation's mode still applies at registration.
        let (body, account_id) = registration_body(
            "invited@example.test",
            ("instance_invitation_token", &invitation_token),
        );
        let (code, value) = register(&restored, body).await;
        assert_eq!(code, StatusCode::OK, "{value}");
        assert_eq!(
            stored_mode(&restored, &account_id).await,
            ("admin_visible".to_owned(), None)
        );
        restored.state.db.close().await;
    }
    std::fs::remove_dir_all(root).unwrap();
}

/// The full schema (tables, indexes and triggers such as the single-key
/// trigger of migration 0055), in a stable order.
async fn schema_rows(world: &World) -> Vec<String> {
    sqlx::query_scalar(
        "SELECT json_array(type,name,tbl_name,sql) FROM sqlite_master \
         WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type,name",
    )
    .fetch_all(&world.state.db)
    .await
    .unwrap()
}

async fn checkpoint_and_close(world: &World) {
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_all(&world.state.db)
        .await
        .unwrap();
    world.state.db.close().await;
}

#[tokio::test]
async fn offline_encrypt_and_rekey_keep_escrow_rows_schema_and_reads() {
    use crate::database::{DatabaseFileFormat, detect_database_file};

    let root = private_test_root("encrypt");
    let data_dir = root.join("instance");
    let key_a = root.join("database-a.key");
    let key_b = root.join("database-b.key");
    write_key_file(&key_a, 0xa7);
    write_key_file(&key_b, 0xb8);
    let url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());

    let world = World::at(data_dir.clone(), None).await;
    let seeded = seed_escrow_through_routes(&world, AT_REST_CANARY_USER).await;
    let rows = credential_visibility_rows(&world).await;
    let schema = schema_rows(&world).await;
    assert!(
        schema
            .iter()
            .any(|row| row.contains("credential_escrow_keys_single_row")),
        "the single-key trigger is part of the compared schema"
    );
    let status = status_of(&world, &seeded.user).await;
    let listing = escrow_listing(&world, &seeded.admin, &seeded.user).await;
    let mut config = (*world.state.config).clone();
    checkpoint_and_close(&world).await;
    assert!(!files_containing(&data_dir, ESCROW_DESCRIPTOR_FORMAT).is_empty());

    // `database-encrypt`, then `database-rekey`: the same rows, schema and
    // behaviour every time, and no readable escrow marker on disk.
    config.database_key_file = Some(key_a.clone());
    crate::encrypt_database_offline(&config, &url)
        .await
        .unwrap();
    let rekey_config = config.clone();
    for (step, key) in [("encrypt", &key_a), ("rekey", &key_b)] {
        if step == "rekey" {
            crate::rekey_database_offline(&rekey_config, &url, &key_b)
                .await
                .unwrap();
        }
        assert_eq!(
            detect_database_file(&data_dir.join("atermius.db")).unwrap(),
            DatabaseFileFormat::Encrypted
        );
        for marker in [
            ESCROW_DESCRIPTOR_FORMAT,
            AT_REST_CANARY_USER,
            &seeded.sealed[..24],
        ] {
            let hits = files_containing(&data_dir, marker);
            assert!(hits.is_empty(), "{step}: {marker} readable in {hits:?}");
        }
        let reopened = World::at(data_dir.clone(), Some(key.clone())).await;
        assert_eq!(credential_visibility_rows(&reopened).await, rows, "{step}");
        assert_eq!(schema_rows(&reopened).await, schema, "{step}");
        // Offline commands keep sessions, so the same tokens still work.
        assert_eq!(status_of(&reopened, &seeded.user).await, status, "{step}");
        assert_eq!(
            escrow_listing(&reopened, &seeded.admin, &seeded.user).await,
            listing,
            "{step}"
        );
        let (code, page) = admin_records(
            &reopened,
            &seeded.admin,
            &records_path(&seeded.vault, &seeded.user, ""),
            true,
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{step}: {page}");
        assert_eq!(page["records"][0]["record_id"], seeded.record_id);
        // The single-key trigger still guards the copied table.
        let second_key = sqlx::query(
            "INSERT INTO credential_escrow_keys(key_id,public_key,signed_payload,instance_signature,\
             creator_signature,recovery_wrap,created_at) VALUES(?,?,'{}','sig','sig','{}',?)",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(random_b64(32))
        .bind(crate::now_rfc3339())
        .execute(&reopened.state.db)
        .await;
        let error = second_key.expect_err("a second escrow key row must be rejected");
        assert!(
            error
                .to_string()
                .contains("credential escrow key already exists"),
            "{step}: {error}"
        );
        checkpoint_and_close(&reopened).await;
    }
    std::fs::remove_dir_all(root).unwrap();
}
