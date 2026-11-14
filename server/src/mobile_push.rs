//! Durable, metadata-only mobile sync hint routing.
//!
//! Provider-specific HTTP adapters are injected through `PushProvider`. The
//! FCM HTTP v1 and direct APNs adapters are optional and independently
//! configured from owner-only secret files. Sync correctness continues to use
//! the changes API and existing WebSocket hint channel.

use crate::{ApiError, AppState, current_user};
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use rand::RngCore;
use reqwest::{
    Client,
    header::{AUTHORIZATION, HeaderValue},
    redirect::Policy,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Row, Sqlite, Transaction};
use std::{
    future::Future,
    pin::Pin,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering as AtomicOrdering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    sync::Mutex as AsyncMutex,
    time::{MissedTickBehavior, interval, timeout},
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

type HmacSha256 = Hmac<Sha256>;
type PushSendFuture<'a> = Pin<Box<dyn Future<Output = PushSendResult> + Send + 'a>>;

const ENDPOINT_ENVELOPE_PREFIX: &str = "npe1:";
const TOKEN_MAX_BYTES: usize = 4096;
pub(crate) const PUSH_WORKER_POLL: Duration = Duration::from_secs(2);
pub(crate) const PUSH_SEND_TIMEOUT: Duration = Duration::from_secs(10);
pub(crate) const PUSH_LEASE_SECONDS: i64 = 30;
pub(crate) const PUSH_RETRY_BASE_SECONDS: i64 = 5;
pub(crate) const PUSH_RETRY_MAX_SECONDS: i64 = 15 * 60;
pub(crate) const PUSH_MAX_ATTEMPTS: i64 = 8;
pub(crate) const PUSH_DEAD_LETTER_TIME: i64 = i64::MAX;
const FCM_SERVICE_ACCOUNT_ENV: &str = "ATERMIUS_FCM_SERVICE_ACCOUNT_FILE";
const FCM_SERVICE_ACCOUNT_MAX_BYTES: u64 = 16 * 1024;
const FCM_OAUTH_URL: &str = "https://oauth2.googleapis.com/token";
const FCM_API_BASE_URL: &str = "https://fcm.googleapis.com/v1/projects/";
const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:jwt-bearer";
const FCM_OAUTH_RESPONSE_MAX_BYTES: usize = 8 * 1024;
const FCM_ERROR_RESPONSE_MAX_BYTES: usize = 16 * 1024;
const APNS_PRIVATE_KEY_ENV: &str = "ATERMIUS_APNS_PRIVATE_KEY_FILE";
const APNS_TEAM_ID_ENV: &str = "ATERMIUS_APNS_TEAM_ID";
const APNS_KEY_ID_ENV: &str = "ATERMIUS_APNS_KEY_ID";
const APNS_TOPIC_ENV: &str = "ATERMIUS_APNS_TOPIC";
const APNS_USE_SANDBOX_ENV: &str = "ATERMIUS_APNS_USE_SANDBOX";
const APNS_PRIVATE_KEY_MAX_BYTES: u64 = 16 * 1024;
const APNS_JWT_REFRESH: Duration = Duration::from_secs(20 * 60);
const APNS_RESPONSE_MAX_BYTES: usize = 16 * 1024;
const APNS_TOKEN_MIN_HEX_CHARS: usize = 32;
const APNS_TOKEN_MAX_HEX_CHARS: usize = 512;
const APNS_PRODUCTION_HOST: &str = "https://api.push.apple.com";
const APNS_SANDBOX_HOST: &str = "https://api.sandbox.push.apple.com";

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PushProviderKind {
    FcmV1,
    Apns,
}

impl PushProviderKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::FcmV1 => "fcm_v1",
            Self::Apns => "apns",
        }
    }

    pub(crate) fn parse(value: &str) -> Result<Self, ApiError> {
        match value {
            "fcm_v1" => Ok(Self::FcmV1),
            "apns" => Ok(Self::Apns),
            _ => Err(ApiError::bad_request(
                "INVALID_PUSH_PROVIDER",
                "push provider is invalid",
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PushPayload {
    SyncAvailable,
}

impl PushPayload {
    /// Deliberately has no fields that can identify a Vault, record, or host.
    #[allow(dead_code)] // The fake provider and adapter contract tests assert this wire value.
    pub(crate) fn wire_json(self) -> &'static str {
        match self {
            Self::SyncAvailable => r#"{"type":"sync_available"}"#,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PushSendResult {
    Accepted,
    RetryableFailure,
    InvalidToken,
}

impl PushSendResult {
    pub(crate) fn outcome_key(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::InvalidToken => "invalid_token",
            Self::RetryableFailure => "retryable_failure",
        }
    }
}

fn utc_day_start(timestamp: i64) -> i64 {
    timestamp.div_euclid(86_400) * 86_400
}

async fn record_delivery_result(
    tx: &mut Transaction<'_, Sqlite>,
    provider: PushProviderKind,
    result: PushSendResult,
    now: i64,
) -> Result<(), ApiError> {
    let day_start = utc_day_start(now);
    sqlx::query(
        "INSERT INTO notification_push_delivery_daily(provider,outcome,day_start,count) \
         VALUES(?,?,?,1) ON CONFLICT(provider,outcome,day_start) \
         DO UPDATE SET count=count+1",
    )
    .bind(provider.as_str())
    .bind(result.outcome_key())
    .bind(day_start)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM notification_push_delivery_daily WHERE day_start<?")
        .bind(day_start.saturating_sub(30 * 86_400))
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

const PUSH_SEND_RESULT_COUNT: usize = 6;
static PUSH_SEND_RESULT_COUNTS: [AtomicU64; PUSH_SEND_RESULT_COUNT] = [
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
];

fn push_send_result_metric_index(provider: PushProviderKind, result: PushSendResult) -> usize {
    let provider_index = match provider {
        PushProviderKind::Apns => 0,
        PushProviderKind::FcmV1 => 1,
    };
    let result_index = match result {
        PushSendResult::Accepted => 0,
        PushSendResult::InvalidToken => 1,
        PushSendResult::RetryableFailure => 2,
    };
    provider_index * 3 + result_index
}

/// Count provider adapter results observed by this server process. These
/// counters are intentionally process-local and reset on restart; they do not
/// record endpoint identity or persist provider responses.
pub(crate) fn record_push_send_result(provider: PushProviderKind, result: PushSendResult) {
    PUSH_SEND_RESULT_COUNTS[push_send_result_metric_index(provider, result)]
        .fetch_update(AtomicOrdering::Relaxed, AtomicOrdering::Relaxed, |count| {
            Some(count.saturating_add(1))
        })
        .expect("a push result counter update always returns the previous value");
}

/// Fixed matrix ordered by APNs then FCM v1, and accepted, invalid token,
/// retryable failure. Labels for this matrix are defined by the metrics
/// renderer, so no caller-controlled values can become Prometheus labels.
pub(crate) fn push_send_result_metric_counts() -> [[u64; 3]; 2] {
    std::array::from_fn(|provider_index| {
        std::array::from_fn(|result_index| {
            PUSH_SEND_RESULT_COUNTS[provider_index * 3 + result_index].load(AtomicOrdering::Relaxed)
        })
    })
}

/// Provider adapters receive only a provider kind, the decrypted opaque
/// provider token, and a constant payload with no Vault or record metadata.
pub(crate) trait PushProvider: Send + Sync {
    fn supports(&self, provider: PushProviderKind) -> bool;

    fn send<'a>(
        &'a self,
        provider: PushProviderKind,
        token: Zeroizing<String>,
        payload: PushPayload,
    ) -> PushSendFuture<'a>;
}

#[derive(Deserialize)]
struct FcmServiceAccountDocument {
    #[serde(rename = "type")]
    kind: String,
    project_id: String,
    client_email: String,
    private_key: String,
}

impl Drop for FcmServiceAccountDocument {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

#[derive(Serialize)]
struct FcmJwtClaims<'a> {
    iss: &'a str,
    scope: &'static str,
    aud: &'static str,
    iat: i64,
    exp: i64,
}

#[derive(Deserialize)]
struct FcmOAuthResponse {
    access_token: String,
    expires_in: u64,
    token_type: String,
}

impl Drop for FcmOAuthResponse {
    fn drop(&mut self) {
        self.access_token.zeroize();
    }
}

struct CachedFcmAccessToken {
    value: Zeroizing<String>,
    expires_at: Instant,
}

struct FcmProvider {
    client: Client,
    client_email: String,
    signing_key: EncodingKey,
    oauth_url: String,
    messages_url: String,
    access_token: AsyncMutex<Option<CachedFcmAccessToken>>,
}

impl FcmProvider {
    fn from_env() -> Result<Self, ()> {
        let path = std::env::var_os(FCM_SERVICE_ACCOUNT_ENV)
            .map(std::path::PathBuf::from)
            .ok_or(())?;
        if !path.is_absolute() {
            return Err(());
        }
        let bytes =
            crate::secure_file::read_private_secret_file(&path, FCM_SERVICE_ACCOUNT_MAX_BYTES)
                .map_err(|_| ())?;
        let (project_id, client_email, signing_key) = parse_fcm_service_account(&bytes)?;
        let oauth_url = reqwest::Url::parse(FCM_OAUTH_URL).map_err(|_| ())?;
        let mut messages_url = reqwest::Url::parse(FCM_API_BASE_URL).map_err(|_| ())?;
        messages_url.set_path(&format!("/v1/projects/{project_id}/messages:send"));
        Self::with_urls(client_email, signing_key, oauth_url, messages_url)
    }

    #[cfg(test)]
    fn from_test_service_account_json(
        bytes: &[u8],
        oauth_url: &str,
        api_base_url: &str,
    ) -> Result<Self, ()> {
        let (project_id, client_email, signing_key) = parse_fcm_service_account(bytes)?;
        let oauth_url = reqwest::Url::parse(oauth_url).map_err(|_| ())?;
        let mut messages_url = reqwest::Url::parse(api_base_url).map_err(|_| ())?;
        messages_url.set_path(&format!("/v1/projects/{project_id}/messages:send"));
        Self::with_urls(client_email, signing_key, oauth_url, messages_url)
    }

    fn with_urls(
        client_email: String,
        signing_key: EncodingKey,
        oauth_url: reqwest::Url,
        messages_url: reqwest::Url,
    ) -> Result<Self, ()> {
        let client = Client::builder()
            .timeout(PUSH_SEND_TIMEOUT)
            .no_proxy()
            .redirect(Policy::none())
            .build()
            .map_err(|_| ())?;
        Ok(Self {
            client,
            client_email,
            signing_key,
            oauth_url: oauth_url.to_string(),
            messages_url: messages_url.to_string(),
            access_token: AsyncMutex::new(None),
        })
    }

    async fn access_token(&self) -> Option<Zeroizing<String>> {
        let mut cached = self.access_token.lock().await;
        if let Some(token) = cached.as_ref()
            && token.expires_at > Instant::now() + Duration::from_secs(60)
        {
            return Some(Zeroizing::new(token.value.to_string()));
        }

        let issued_at = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
        let issued_at = i64::try_from(issued_at).ok()?;
        let expires_at = issued_at.checked_add(3600)?;
        let claims = FcmJwtClaims {
            iss: &self.client_email,
            scope: FCM_SCOPE,
            aud: FCM_OAUTH_URL,
            iat: issued_at,
            exp: expires_at,
        };
        let assertion = Zeroizing::new(
            jsonwebtoken::encode(&Header::new(Algorithm::RS256), &claims, &self.signing_key)
                .ok()?,
        );
        let response = self
            .client
            .post(&self.oauth_url)
            .form(&[
                ("grant_type", FCM_GRANT_TYPE),
                ("assertion", assertion.as_str()),
            ])
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let body = read_bounded_response(response, FCM_OAUTH_RESPONSE_MAX_BYTES).await?;
        let mut token: FcmOAuthResponse = serde_json::from_slice(&body).ok()?;
        if token.token_type != "Bearer"
            || token.access_token.is_empty()
            || token.access_token.len() > 8192
            || token
                .access_token
                .bytes()
                .any(|byte| byte.is_ascii_control())
            || !(60..=86_400).contains(&token.expires_in)
        {
            return None;
        }
        let duration = Duration::from_secs(token.expires_in.min(3600));
        let expires_at = Instant::now().checked_add(duration)?;
        let value = Zeroizing::new(std::mem::take(&mut token.access_token));
        let result = Zeroizing::new(value.to_string());
        *cached = Some(CachedFcmAccessToken { value, expires_at });
        Some(result)
    }
}

impl PushProvider for FcmProvider {
    fn supports(&self, provider: PushProviderKind) -> bool {
        provider == PushProviderKind::FcmV1
    }

    fn send<'a>(
        &'a self,
        provider: PushProviderKind,
        token: Zeroizing<String>,
        payload: PushPayload,
    ) -> PushSendFuture<'a> {
        Box::pin(async move {
            if provider != PushProviderKind::FcmV1 || payload != PushPayload::SyncAvailable {
                return PushSendResult::RetryableFailure;
            }
            let Some(access_token) = self.access_token().await else {
                return PushSendResult::RetryableFailure;
            };
            let mut authorization = Zeroizing::new(String::with_capacity(access_token.len() + 7));
            authorization.push_str("Bearer ");
            authorization.push_str(access_token.as_str());
            let Ok(mut authorization) = HeaderValue::from_str(&authorization) else {
                return PushSendResult::RetryableFailure;
            };
            authorization.set_sensitive(true);
            let body = json!({
                "message": {
                    "token": token.as_str(),
                    "data": {"type": "sync_available"},
                    "apns": {
                        "headers": {
                            "apns-push-type": "background",
                            "apns-priority": "5"
                        },
                        "payload": {"aps": {"content-available": 1}}
                    }
                }
            });
            let response = self
                .client
                .post(&self.messages_url)
                .header(AUTHORIZATION, authorization)
                .json(&body)
                .send()
                .await;
            let Ok(response) = response else {
                return PushSendResult::RetryableFailure;
            };
            if response.status().is_success() {
                return PushSendResult::Accepted;
            }
            let status = response.status();
            let Some(body) = read_bounded_response(response, FCM_ERROR_RESPONSE_MAX_BYTES).await
            else {
                return PushSendResult::RetryableFailure;
            };
            if status == reqwest::StatusCode::NOT_FOUND && fcm_unregistered(&body) {
                PushSendResult::InvalidToken
            } else {
                PushSendResult::RetryableFailure
            }
        })
    }
}

#[derive(Serialize)]
struct ApnsJwtClaims<'a> {
    iss: &'a str,
    iat: i64,
}

struct CachedApnsProviderToken {
    value: Zeroizing<String>,
    expires_at: Instant,
}

struct ApnsProvider {
    client: Client,
    team_id: String,
    key_id: String,
    topic: String,
    signing_key: EncodingKey,
    host: String,
    provider_token: AsyncMutex<Option<CachedApnsProviderToken>>,
}

impl ApnsProvider {
    fn from_env() -> Result<Self, ()> {
        let team_id = std::env::var(APNS_TEAM_ID_ENV).map_err(|_| ())?;
        let key_id = std::env::var(APNS_KEY_ID_ENV).map_err(|_| ())?;
        let topic = std::env::var(APNS_TOPIC_ENV).map_err(|_| ())?;
        if !valid_apple_identifier(&team_id)
            || !valid_apple_identifier(&key_id)
            || !valid_apns_topic(&topic)
        {
            return Err(());
        }
        let private_key_path = std::env::var_os(APNS_PRIVATE_KEY_ENV)
            .map(std::path::PathBuf::from)
            .ok_or(())?;
        if !private_key_path.is_absolute() {
            return Err(());
        }
        let private_key = crate::secure_file::read_private_secret_file(
            &private_key_path,
            APNS_PRIVATE_KEY_MAX_BYTES,
        )
        .map_err(|_| ())?;
        let signing_key = parse_apns_signing_key(private_key.as_slice())?;
        let sandbox = match std::env::var_os(APNS_USE_SANDBOX_ENV) {
            None => false,
            Some(value) => parse_apns_sandbox(Some(value.to_str().ok_or(())?))?,
        };
        Self::with_config(
            team_id,
            key_id,
            topic,
            signing_key,
            apns_host(sandbox).to_owned(),
        )
    }

    #[cfg(test)]
    fn from_test_private_key(
        private_key: &[u8],
        team_id: &str,
        key_id: &str,
        topic: &str,
        host: &str,
    ) -> Result<Self, ()> {
        if !valid_apple_identifier(team_id)
            || !valid_apple_identifier(key_id)
            || !valid_apns_topic(topic)
        {
            return Err(());
        }
        let signing_key = parse_apns_signing_key(private_key)?;
        Self::with_config(
            team_id.to_owned(),
            key_id.to_owned(),
            topic.to_owned(),
            signing_key,
            host.to_owned(),
        )
    }

    fn with_config(
        team_id: String,
        key_id: String,
        topic: String,
        signing_key: EncodingKey,
        host: String,
    ) -> Result<Self, ()> {
        let client = Client::builder()
            .timeout(PUSH_SEND_TIMEOUT)
            .no_proxy()
            .redirect(Policy::none())
            // `http2` is enabled in Cargo features; TLS ALPN negotiates h2 with Apple.
            .http2_adaptive_window(true)
            .build()
            .map_err(|_| ())?;
        Ok(Self {
            client,
            team_id,
            key_id,
            topic,
            signing_key,
            host,
            provider_token: AsyncMutex::new(None),
        })
    }

    async fn provider_token(&self) -> Option<Zeroizing<String>> {
        let mut cached = self.provider_token.lock().await;
        if let Some(token) = cached.as_ref()
            && token.expires_at > Instant::now()
        {
            return Some(Zeroizing::new(token.value.to_string()));
        }
        let issued_at = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
        let issued_at = i64::try_from(issued_at).ok()?;
        let claims = ApnsJwtClaims {
            iss: &self.team_id,
            iat: issued_at,
        };
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let token = Zeroizing::new(jsonwebtoken::encode(&header, &claims, &self.signing_key).ok()?);
        let expires_at = Instant::now().checked_add(APNS_JWT_REFRESH)?;
        let result = Zeroizing::new(token.to_string());
        *cached = Some(CachedApnsProviderToken {
            value: token,
            expires_at,
        });
        Some(result)
    }
}

impl PushProvider for ApnsProvider {
    fn supports(&self, provider: PushProviderKind) -> bool {
        provider == PushProviderKind::Apns
    }

    fn send<'a>(
        &'a self,
        provider: PushProviderKind,
        token: Zeroizing<String>,
        payload: PushPayload,
    ) -> PushSendFuture<'a> {
        Box::pin(async move {
            if provider != PushProviderKind::Apns || payload != PushPayload::SyncAvailable {
                return PushSendResult::RetryableFailure;
            }
            let Some(device_token) = normalize_apns_device_token(token.as_str()) else {
                return PushSendResult::RetryableFailure;
            };
            let Some(provider_token) = self.provider_token().await else {
                return PushSendResult::RetryableFailure;
            };
            let mut authorization = Zeroizing::new(String::with_capacity(provider_token.len() + 7));
            authorization.push_str("Bearer ");
            authorization.push_str(provider_token.as_str());
            let Ok(mut authorization) = HeaderValue::from_str(&authorization) else {
                return PushSendResult::RetryableFailure;
            };
            authorization.set_sensitive(true);
            let url = format!(
                "{}/3/device/{device_token}",
                self.host.trim_end_matches('/')
            );
            let body = json!({
                "aps": {"content-available": 1},
                "type": "sync_available"
            });
            let response = self
                .client
                .post(url)
                .header(AUTHORIZATION, authorization)
                .header("apns-topic", &self.topic)
                .header("apns-push-type", "background")
                .header("apns-priority", "5")
                .json(&body)
                .send()
                .await;
            let Ok(response) = response else {
                return PushSendResult::RetryableFailure;
            };
            if response.status().is_success() {
                return PushSendResult::Accepted;
            }
            let status = response.status();
            let Some(body) = read_bounded_response(response, APNS_RESPONSE_MAX_BYTES).await else {
                return PushSendResult::RetryableFailure;
            };
            if status == reqwest::StatusCode::GONE && apns_unregistered(&body) {
                PushSendResult::InvalidToken
            } else {
                PushSendResult::RetryableFailure
            }
        })
    }
}

fn valid_apple_identifier(value: &str) -> bool {
    value.len() == 10 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn parse_apns_signing_key(private_key: &[u8]) -> Result<EncodingKey, ()> {
    let signing_key = EncodingKey::from_ec_pem(private_key).map_err(|_| ())?;
    let header = Header::new(Algorithm::ES256);
    let claims = ApnsJwtClaims {
        iss: "TEAM123456",
        iat: 1,
    };
    jsonwebtoken::encode(&header, &claims, &signing_key).map_err(|_| ())?;
    Ok(signing_key)
}

fn valid_apns_topic(value: &str) -> bool {
    if value.is_empty() || value.len() > 255 || !value.is_ascii() {
        return false;
    }
    let labels: Vec<&str> = value.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    labels.iter().all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label.as_bytes()[0].is_ascii_alphanumeric()
            && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

fn parse_apns_sandbox(value: Option<&str>) -> Result<bool, ()> {
    match value {
        None | Some("false") => Ok(false),
        Some("true") => Ok(true),
        _ => Err(()),
    }
}

fn apns_host(sandbox: bool) -> &'static str {
    if sandbox {
        APNS_SANDBOX_HOST
    } else {
        APNS_PRODUCTION_HOST
    }
}

fn normalize_apns_device_token(token: &str) -> Option<String> {
    let bytes = token.as_bytes();
    if !(APNS_TOKEN_MIN_HEX_CHARS..=APNS_TOKEN_MAX_HEX_CHARS).contains(&bytes.len())
        || bytes.len() % 2 != 0
        || !bytes.iter().all(u8::is_ascii_hexdigit)
    {
        return None;
    }
    Some(token.to_ascii_lowercase())
}

fn apns_unregistered(body: &[u8]) -> bool {
    serde_json::from_slice::<Value>(body)
        .ok()
        .is_some_and(|value| value.get("reason").and_then(Value::as_str) == Some("Unregistered"))
}

struct ConfiguredPushProvider {
    fcm: Option<FcmProvider>,
    apns: Option<ApnsProvider>,
}

impl PushProvider for ConfiguredPushProvider {
    fn supports(&self, provider: PushProviderKind) -> bool {
        match provider {
            PushProviderKind::FcmV1 => self.fcm.is_some(),
            PushProviderKind::Apns => self.apns.is_some(),
        }
    }

    fn send<'a>(
        &'a self,
        provider: PushProviderKind,
        token: Zeroizing<String>,
        payload: PushPayload,
    ) -> PushSendFuture<'a> {
        let adapter = match provider {
            PushProviderKind::FcmV1 => self
                .fcm
                .as_ref()
                .map(|adapter| adapter as &dyn PushProvider),
            PushProviderKind::Apns => self
                .apns
                .as_ref()
                .map(|adapter| adapter as &dyn PushProvider),
        };
        if let Some(adapter) = adapter {
            adapter.send(provider, token, payload)
        } else {
            Box::pin(async { PushSendResult::RetryableFailure })
        }
    }
}

fn parse_fcm_service_account(bytes: &[u8]) -> Result<(String, String, EncodingKey), ()> {
    let mut document: FcmServiceAccountDocument = serde_json::from_slice(bytes).map_err(|_| ())?;
    let private_key = Zeroizing::new(std::mem::take(&mut document.private_key));
    let project_id = std::mem::take(&mut document.project_id);
    let client_email = std::mem::take(&mut document.client_email);
    if document.kind != "service_account"
        || !valid_fcm_project_id(&project_id)
        || client_email.len() > 320
        || !client_email.ends_with(".iam.gserviceaccount.com")
        || client_email.bytes().any(|byte| byte.is_ascii_control())
        || private_key.is_empty()
        || private_key.len() > 8 * 1024
    {
        return Err(());
    }
    let signing_key = EncodingKey::from_rsa_pem(private_key.as_bytes()).map_err(|_| ())?;
    Ok((project_id, client_email, signing_key))
}

fn valid_fcm_project_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (6..=30).contains(&bytes.len())
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
}

async fn read_bounded_response(
    mut response: reqwest::Response,
    max_bytes: usize,
) -> Option<Zeroizing<Vec<u8>>> {
    if response
        .content_length()
        .is_some_and(|length| length > max_bytes as u64)
    {
        return None;
    }
    let mut body = Zeroizing::new(Vec::new());
    loop {
        let Some(chunk) = response.chunk().await.ok()? else {
            break;
        };
        if body.len().saturating_add(chunk.len()) > max_bytes {
            return None;
        }
        body.extend_from_slice(&chunk);
    }
    Some(body)
}

fn fcm_unregistered(body: &[u8]) -> bool {
    let Ok(value) = serde_json::from_slice::<Value>(body) else {
        return false;
    };
    value
        .pointer("/error/details")
        .and_then(Value::as_array)
        .is_some_and(|details| {
            details.iter().any(|detail| {
                detail.get("errorCode").and_then(Value::as_str) == Some("UNREGISTERED")
            })
        })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RegisterPushEndpointRequest {
    provider: PushProviderKind,
    token: String,
}

impl Drop for RegisterPushEndpointRequest {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}

fn invalid_endpoint() -> ApiError {
    ApiError::bad_request("INVALID_PUSH_ENDPOINT", "push endpoint is invalid")
}

fn validate_token(token: &str) -> Result<(), ApiError> {
    if !(16..=TOKEN_MAX_BYTES).contains(&token.len())
        || !token.is_ascii()
        || !token.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
    {
        return Err(invalid_endpoint());
    }
    Ok(())
}

fn validate_provider_token(provider: PushProviderKind, token: &str) -> Result<(), ApiError> {
    match provider {
        PushProviderKind::FcmV1 => validate_token(token),
        PushProviderKind::Apns => normalize_apns_device_token(token)
            .map(|_| ())
            .ok_or_else(invalid_endpoint),
    }
}

fn derive_push_keys(
    state: &AppState,
) -> Result<(Zeroizing<[u8; 32]>, Zeroizing<[u8; 32]>), ApiError> {
    derive_push_keys_from_key(state.auth_rate_key.as_ref())
}

pub(crate) fn derive_push_keys_from_key(
    auth_rate_key: &[u8; 32],
) -> Result<(Zeroizing<[u8; 32]>, Zeroizing<[u8; 32]>), ApiError> {
    let mut encryption_key = Zeroizing::new([0_u8; 32]);
    let mut fingerprint_key = Zeroizing::new([0_u8; 32]);
    let hkdf = Hkdf::<Sha256>::new(
        Some(b"atermius/notification-push/v1/domain-separation"),
        auth_rate_key,
    );
    hkdf.expand(
        b"atermius/notification-push/token-encryption/v1",
        &mut *encryption_key,
    )
    .map_err(ApiError::internal)?;
    hkdf.expand(
        b"atermius/notification-push/token-fingerprint/v1",
        &mut *fingerprint_key,
    )
    .map_err(ApiError::internal)?;
    Ok((encryption_key, fingerprint_key))
}

fn push_key_id(key: &[u8; 32]) -> String {
    let digest = Sha256::digest(key);
    hex::encode(&digest[..8])
}

pub(crate) fn token_fingerprint(key: &[u8; 32], token: &str) -> Result<String, ApiError> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(token.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn endpoint_aad(
    endpoint_id: &str,
    device_id: &str,
    provider: PushProviderKind,
    token_hash: &str,
) -> Vec<u8> {
    let mut aad = b"atermius/notification-push-endpoint/aad/v1\0".to_vec();
    for part in [endpoint_id, device_id, provider.as_str(), token_hash] {
        aad.extend_from_slice(part.as_bytes());
        aad.push(0);
    }
    aad
}

fn encrypt_token(
    state: &AppState,
    endpoint_id: &str,
    device_id: &str,
    provider: PushProviderKind,
    token_hash: &str,
    token: &str,
) -> Result<String, ApiError> {
    encrypt_push_token(
        state.auth_rate_key.as_ref(),
        endpoint_id,
        device_id,
        provider,
        token_hash,
        token,
    )
}

pub(crate) fn encrypt_push_token(
    auth_rate_key: &[u8; 32],
    endpoint_id: &str,
    device_id: &str,
    provider: PushProviderKind,
    token_hash: &str,
    token: &str,
) -> Result<String, ApiError> {
    let (key, _) = derive_push_keys_from_key(auth_rate_key)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(ApiError::internal)?;
    let mut nonce = [0_u8; 24];
    rand::thread_rng().fill_bytes(&mut nonce);
    let plaintext = Zeroizing::new(token.as_bytes().to_vec());
    let encrypted = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: &plaintext,
                aad: &endpoint_aad(endpoint_id, device_id, provider, token_hash),
            },
        )
        .map_err(ApiError::internal)?;
    let mut packed = Vec::with_capacity(nonce.len() + encrypted.len());
    packed.extend_from_slice(&nonce);
    packed.extend_from_slice(&encrypted);
    Ok(format!(
        "{ENDPOINT_ENVELOPE_PREFIX}{}:{}",
        push_key_id(&key),
        URL_SAFE_NO_PAD.encode(packed)
    ))
}

fn decrypt_token(
    state: &AppState,
    endpoint_id: &str,
    device_id: &str,
    provider: PushProviderKind,
    token_hash: &str,
    envelope: &str,
) -> Result<Zeroizing<String>, ()> {
    decrypt_push_token(
        state.auth_rate_key.as_ref(),
        endpoint_id,
        device_id,
        provider,
        token_hash,
        envelope,
    )
}

pub(crate) fn decrypt_push_token(
    auth_rate_key: &[u8; 32],
    endpoint_id: &str,
    device_id: &str,
    provider: PushProviderKind,
    token_hash: &str,
    envelope: &str,
) -> Result<Zeroizing<String>, ()> {
    let rest = envelope.strip_prefix(ENDPOINT_ENVELOPE_PREFIX).ok_or(())?;
    let (stored_key_id, encoded) = rest.split_once(':').ok_or(())?;
    let (key, _) = derive_push_keys_from_key(auth_rate_key).map_err(|_| ())?;
    if stored_key_id != push_key_id(&key) {
        return Err(());
    }
    let packed = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| ())?;
    if packed.len() < 24 + 16 || URL_SAFE_NO_PAD.encode(&packed) != encoded {
        return Err(());
    }
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(|_| ())?;
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                XNonce::from_slice(&packed[..24]),
                chacha20poly1305::aead::Payload {
                    msg: &packed[24..],
                    aad: &endpoint_aad(endpoint_id, device_id, provider, token_hash),
                },
            )
            .map_err(|_| ())?,
    );
    let token = std::str::from_utf8(&plaintext).map_err(|_| ())?;
    if validate_provider_token(provider, token).is_err() {
        return Err(());
    }
    Ok(Zeroizing::new(token.to_owned()))
}

pub(crate) async fn register_endpoint(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    request: Json<RegisterPushEndpointRequest>,
) -> Result<Json<Value>, ApiError> {
    let adapter = configured_provider();
    register_endpoint_with_provider(
        State(state),
        headers,
        Path(device_id),
        request,
        adapter.as_deref(),
    )
    .await
}

pub(crate) fn normalize_push_token(
    provider: PushProviderKind,
    token: String,
) -> Result<Zeroizing<String>, ApiError> {
    // Own the request token in zeroizing storage before validation can return
    // an error. A rejected credential must not take the ordinary String drop
    // path in either runtime backend.
    let mut token = Zeroizing::new(token);
    match provider {
        PushProviderKind::FcmV1 => {
            validate_provider_token(provider, token.as_str())?;
            Ok(token)
        }
        PushProviderKind::Apns => {
            let normalized =
                normalize_apns_device_token(token.as_str()).ok_or_else(invalid_endpoint)?;
            token.zeroize();
            Ok(Zeroizing::new(normalized))
        }
    }
}

async fn register_endpoint_with_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(mut request): Json<RegisterPushEndpointRequest>,
    adapter: Option<&dyn PushProvider>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_MISMATCH",
            "push endpoint must belong to the current device",
        ));
    }
    if !adapter.is_some_and(|adapter| adapter.supports(request.provider)) {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "PUSH_DELIVERY_DISABLED",
            "mobile push delivery is unavailable for this provider",
        ));
    }
    if let Some(repository) = state.pg_mobile_push.as_ref() {
        let provider = request.provider;
        let token = normalize_push_token(provider, std::mem::take(&mut request.token))?;
        return repository
            .register_endpoint(&user, provider, token)
            .await
            .map(Json);
    }
    register_endpoint_enabled(State(state), headers, Path(device_id), Json(request)).await
}

async fn register_endpoint_enabled(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(mut request): Json<RegisterPushEndpointRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_MISMATCH",
            "push endpoint must belong to the current device",
        ));
    }
    let provider = request.provider;
    let token = normalize_push_token(provider, std::mem::take(&mut request.token))?;
    let (_, fingerprint_key) = derive_push_keys(&state)?;
    let token_hash = token_fingerprint(&fingerprint_key, &token)?;
    let now = chrono::Utc::now().timestamp();

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let existing_endpoint: Option<String> = sqlx::query_scalar(
        "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=? AND provider=?",
    )
    .bind(&device_id)
    .bind(provider.as_str())
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let endpoint_id = existing_endpoint.unwrap_or_else(|| Uuid::new_v4().to_string());
    let existing_token_owner: Option<(String, String)> = sqlx::query_as(
        "SELECT device_id,provider FROM notification_push_endpoints WHERE token_hash=?",
    )
    .bind(&token_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if existing_token_owner
        .as_ref()
        .is_some_and(|(owner, owner_provider)| {
            owner != &device_id || owner_provider != provider.as_str()
        })
    {
        return Err(ApiError::conflict(
            "PUSH_ENDPOINT_IN_USE",
            "push endpoint is already registered",
        ));
    }
    let envelope = encrypt_token(
        &state,
        &endpoint_id,
        &device_id,
        provider,
        &token_hash,
        &token,
    )?;
    sqlx::query("INSERT INTO notification_push_endpoints(endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(device_id,provider) DO UPDATE SET token_hash=excluded.token_hash,token_envelope=excluded.token_envelope,updated_at=excluded.updated_at")
        .bind(&endpoint_id)
        .bind(&device_id)
        .bind(&user.user_id)
        .bind(provider.as_str())
        .bind(&token_hash)
        .bind(envelope)
        .bind(now)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(|_| ApiError::conflict("PUSH_ENDPOINT_IN_USE", "push endpoint is already registered"))?;
    sqlx::query("UPDATE notification_push_outbox SET requested_seq=requested_seq+1,attempt_count=0,next_attempt_at=?,lease_id=NULL,lease_until=NULL,dead_lettered=0,updated_at=? WHERE endpoint_id=?")
        .bind(now)
        .bind(now)
        .bind(&endpoint_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "status": "registered",
        "device_id": device_id,
        "provider": provider.as_str(),
    })))
}

pub(crate) async fn delete_endpoint(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((device_id, provider)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_MISMATCH",
            "push endpoint must belong to the current device",
        ));
    }
    let provider = PushProviderKind::parse(&provider)?;
    if let Some(repository) = state.pg_mobile_push.as_ref() {
        return repository.delete_endpoint(&user, provider).await.map(Json);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    sqlx::query(
        "DELETE FROM notification_push_endpoints WHERE device_id=? AND user_id=? AND provider=?",
    )
    .bind(&device_id)
    .bind(&user.user_id)
    .bind(provider.as_str())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"status":"removed","device_id":device_id,"provider":provider.as_str()}),
    ))
}

/// Adds one coalesced hint for each active member device other than the
/// device that committed the Vault change. Callers must use the same write
/// transaction as the Vault commit; no network I/O occurs here.
pub(crate) async fn enqueue_sync_available_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    source_device_id: &str,
    now: i64,
) -> Result<(), ApiError> {
    enqueue_sync_available_for_vault_tx(tx, vault_id, Some(source_device_id), now).await
}

/// Enqueues a durable hint for every eligible active endpoint in the Vault.
/// Maintenance has no source device to exclude and must not synthesize one.
pub(crate) async fn enqueue_sync_available_all_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    now: i64,
) -> Result<(), ApiError> {
    enqueue_sync_available_for_vault_tx(tx, vault_id, None, now).await
}

async fn enqueue_sync_available_for_vault_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    source_device_id: Option<&str>,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO notification_push_outbox(endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at,lease_id,lease_until,dead_lettered,updated_at) SELECT e.endpoint_id,1,0,0,?,NULL,NULL,0,? FROM notification_push_endpoints e JOIN devices d ON d.device_id=e.device_id JOIN users u ON u.user_id=e.user_id JOIN vault_members vm ON vm.user_id=e.user_id JOIN vaults v ON v.vault_id=vm.vault_id WHERE vm.vault_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND v.state='active' AND d.status='active' AND u.status='active' AND (? IS NULL OR d.device_id!=?) ON CONFLICT(endpoint_id) DO UPDATE SET requested_seq=notification_push_outbox.requested_seq+1,attempt_count=0,next_attempt_at=MIN(notification_push_outbox.next_attempt_at,excluded.next_attempt_at),dead_lettered=0,updated_at=excluded.updated_at")
        .bind(now)
        .bind(now)
        .bind(vault_id)
        .bind(source_device_id)
        .bind(source_device_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[derive(Debug)]
struct PushDelivery {
    endpoint_id: String,
    device_id: String,
    provider: PushProviderKind,
    token_hash: String,
    token_envelope: String,
    requested_seq: i64,
    attempt_count: i64,
    lease_id: String,
}

async fn claim_one_due(state: &AppState, now: i64) -> Result<Option<PushDelivery>, ApiError> {
    let lease_id = Uuid::new_v4().to_string();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let claimed = sqlx::query("UPDATE notification_push_outbox SET lease_id=?,lease_until=?,attempt_count=attempt_count+1,updated_at=? WHERE endpoint_id=(SELECT o.endpoint_id FROM notification_push_outbox o JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id JOIN devices d ON d.device_id=e.device_id JOIN users u ON u.user_id=e.user_id WHERE o.requested_seq>o.delivered_seq AND o.dead_lettered=0 AND o.next_attempt_at<=? AND (o.lease_id IS NULL OR o.lease_until<=?) AND d.status='active' AND u.status='active' ORDER BY o.next_attempt_at,o.updated_at LIMIT 1) RETURNING endpoint_id,requested_seq,attempt_count")
        .bind(&lease_id)
        .bind(now.saturating_add(PUSH_LEASE_SECONDS))
        .bind(now)
        .bind(now)
        .bind(now)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(claimed) = claimed else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let endpoint_id: String = claimed.get("endpoint_id");
    let row = sqlx::query("SELECT e.device_id,e.provider,e.token_hash,e.token_envelope FROM notification_push_endpoints e JOIN devices d ON d.device_id=e.device_id JOIN users u ON u.user_id=e.user_id WHERE e.endpoint_id=? AND d.status='active' AND u.status='active'")
        .bind(&endpoint_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        sqlx::query("DELETE FROM notification_push_outbox WHERE endpoint_id=?")
            .bind(&endpoint_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let delivery = PushDelivery {
        endpoint_id,
        device_id: row.get("device_id"),
        provider: PushProviderKind::parse(&row.get::<String, _>("provider"))?,
        token_hash: row.get("token_hash"),
        token_envelope: row.get("token_envelope"),
        requested_seq: claimed.get("requested_seq"),
        attempt_count: claimed.get("attempt_count"),
        lease_id,
    };
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(delivery))
}

fn retry_delay(attempt_count: i64) -> i64 {
    let exponent = attempt_count.saturating_sub(1).clamp(0, 30) as u32;
    PUSH_RETRY_BASE_SECONDS
        .saturating_mul(1_i64.checked_shl(exponent).unwrap_or(i64::MAX))
        .min(PUSH_RETRY_MAX_SECONDS)
}

async fn finish_delivery(
    state: &AppState,
    delivery: &PushDelivery,
    result: PushSendResult,
    now: i64,
) -> Result<(), ApiError> {
    match result {
        PushSendResult::Accepted => {
            let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result, now).await?;
            sqlx::query("UPDATE notification_push_outbox SET delivered_seq=MAX(delivered_seq,?),lease_id=NULL,lease_until=NULL,attempt_count=0,next_attempt_at=?,dead_lettered=0,updated_at=? WHERE endpoint_id=? AND lease_id=?")
                .bind(delivery.requested_seq)
                .bind(now)
                .bind(now)
                .bind(&delivery.endpoint_id)
                .bind(&delivery.lease_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("DELETE FROM notification_push_outbox WHERE endpoint_id=? AND delivered_seq>=requested_seq AND lease_id IS NULL")
                .bind(&delivery.endpoint_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
        PushSendResult::InvalidToken => {
            let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result, now).await?;
            sqlx::query("DELETE FROM notification_push_endpoints WHERE endpoint_id=? AND token_hash=? AND EXISTS (SELECT 1 FROM notification_push_outbox WHERE endpoint_id=? AND lease_id=?)")
                .bind(&delivery.endpoint_id)
                .bind(&delivery.token_hash)
                .bind(&delivery.endpoint_id)
                .bind(&delivery.lease_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
        PushSendResult::RetryableFailure => {
            let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result, now).await?;
            let current: Option<(i64, i64)> = sqlx::query_as(
                "SELECT requested_seq,attempt_count FROM notification_push_outbox WHERE endpoint_id=? AND lease_id=?",
            )
            .bind(&delivery.endpoint_id)
            .bind(&delivery.lease_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let Some((current_requested_seq, current_attempt_count)) = current else {
                tx.commit().await.map_err(ApiError::internal)?;
                return Ok(());
            };
            let newer_work_arrived = current_requested_seq > delivery.requested_seq
                || current_attempt_count < delivery.attempt_count;
            let exhausted = !newer_work_arrived && delivery.attempt_count >= PUSH_MAX_ATTEMPTS;
            let next_attempt = if exhausted {
                PUSH_DEAD_LETTER_TIME
            } else if newer_work_arrived {
                now
            } else {
                now.saturating_add(retry_delay(delivery.attempt_count))
            };
            sqlx::query("UPDATE notification_push_outbox SET lease_id=NULL,lease_until=NULL,next_attempt_at=?,dead_lettered=?,updated_at=? WHERE endpoint_id=? AND lease_id=?")
                .bind(next_attempt)
                .bind(exhausted as i64)
                .bind(now)
                .bind(&delivery.endpoint_id)
                .bind(&delivery.lease_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
    }
    Ok(())
}

/// Claims at most one durable hint and performs provider I/O after the claim
/// transaction has committed. `now` is injected so lease/retry behavior is
/// deterministic in tests and no provider network request is made in SQLite.
pub(crate) async fn run_one_due<P: PushProvider + ?Sized>(
    state: &AppState,
    provider: &P,
    now: i64,
) -> Result<bool, ApiError> {
    let Some(delivery) = claim_one_due(state, now).await? else {
        return Ok(false);
    };
    let token = match decrypt_token(
        state,
        &delivery.endpoint_id,
        &delivery.device_id,
        delivery.provider,
        &delivery.token_hash,
        &delivery.token_envelope,
    ) {
        Ok(token) => token,
        Err(()) => {
            park_unreadable_endpoint(state, &delivery, now).await?;
            return Ok(true);
        }
    };
    let result = timeout(
        PUSH_SEND_TIMEOUT,
        provider.send(delivery.provider, token, PushPayload::SyncAvailable),
    )
    .await
    .unwrap_or(PushSendResult::RetryableFailure);
    record_push_send_result(delivery.provider, result);
    finish_delivery(state, &delivery, result, now).await?;
    Ok(true)
}

async fn park_unreadable_endpoint(
    state: &AppState,
    delivery: &PushDelivery,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query("UPDATE notification_push_outbox SET lease_id=NULL,lease_until=NULL,next_attempt_at=?,dead_lettered=1,updated_at=? WHERE endpoint_id=? AND lease_id=?")
        .bind(PUSH_DEAD_LETTER_TIME)
        .bind(now)
        .bind(&delivery.endpoint_id)
        .bind(&delivery.lease_id)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

/// An absent provider means the worker does not start and queued hints remain
/// coalesced in SQLite until a supported provider is configured.
pub(crate) fn start_worker(state: AppState, provider: Option<Arc<dyn PushProvider>>) {
    let Some(provider) = provider else {
        return;
    };
    tokio::spawn(async move {
        let mut poll = interval(PUSH_WORKER_POLL);
        poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
        loop {
            poll.tick().await;
            match run_one_due(&state, provider.as_ref(), chrono::Utc::now().timestamp()).await {
                Ok(_) => {}
                Err(error) => tracing::warn!(
                    error_code = %error.body.code,
                    "mobile push delivery iteration failed"
                ),
            }
        }
    });
}

pub(crate) fn configured_provider() -> Option<Arc<dyn PushProvider>> {
    static PROVIDER: OnceLock<Option<Arc<dyn PushProvider>>> = OnceLock::new();
    PROVIDER
        .get_or_init(|| {
            let fcm = FcmProvider::from_env().ok();
            let apns = ApnsProvider::from_env().ok();
            (fcm.is_some() || apns.is_some())
                .then(|| Arc::new(ConfiguredPushProvider { fcm, apns }) as Arc<dyn PushProvider>)
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AuthRateLimits, Config, auth::AuthUser, open_state, secure_file::create_private_data_dir,
    };
    use axum::{
        Form, Router,
        body::Body,
        extract::{OriginalUri, State as AxumState},
        http::{HeaderValue, Response, StatusCode, header::AUTHORIZATION},
        routing::{get, post},
    };
    use chrono::{Duration as ChronoDuration, Utc};
    use serde_json::Value;
    use std::{
        collections::HashMap,
        path::PathBuf,
        sync::{
            Mutex as StdMutex,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
    };

    #[test]
    fn provider_result_metrics_use_only_the_fixed_provider_and_outcome_matrix() {
        let before = push_send_result_metric_counts();
        let cases = [
            (PushProviderKind::Apns, PushSendResult::Accepted, 0, 0),
            (PushProviderKind::Apns, PushSendResult::InvalidToken, 0, 1),
            (
                PushProviderKind::Apns,
                PushSendResult::RetryableFailure,
                0,
                2,
            ),
            (PushProviderKind::FcmV1, PushSendResult::Accepted, 1, 0),
            (PushProviderKind::FcmV1, PushSendResult::InvalidToken, 1, 1),
            (
                PushProviderKind::FcmV1,
                PushSendResult::RetryableFailure,
                1,
                2,
            ),
        ];
        let indexes: Vec<_> = cases
            .iter()
            .map(|(provider, result, _, _)| push_send_result_metric_index(*provider, *result))
            .collect();
        assert_eq!(indexes, vec![0, 1, 2, 3, 4, 5]);

        for (provider, result, _, _) in cases {
            record_push_send_result(provider, result);
        }
        let after = push_send_result_metric_counts();
        for (_, _, provider_index, outcome_index) in cases {
            assert!(after[provider_index][outcome_index] > before[provider_index][outcome_index]);
        }
    }

    struct MockFcmState {
        oauth_calls: AtomicUsize,
        send_calls: AtomicUsize,
        oauth_form_valid: AtomicBool,
        authorization_valid: AtomicBool,
        claims: StdMutex<Option<Value>>,
        message: StdMutex<Option<Value>>,
        send_status: StdMutex<StatusCode>,
        send_body: StdMutex<String>,
    }

    impl MockFcmState {
        fn new() -> Self {
            Self {
                oauth_calls: AtomicUsize::new(0),
                send_calls: AtomicUsize::new(0),
                oauth_form_valid: AtomicBool::new(false),
                authorization_valid: AtomicBool::new(false),
                claims: StdMutex::new(None),
                message: StdMutex::new(None),
                send_status: StdMutex::new(StatusCode::OK),
                send_body: StdMutex::new(r#"{"name":"accepted"}"#.to_owned()),
            }
        }
    }

    struct MockApnsState {
        send_calls: AtomicUsize,
        redirect_target_calls: AtomicUsize,
        authorization_valid: AtomicBool,
        topic_valid: AtomicBool,
        background_headers_valid: AtomicBool,
        jwt_header: StdMutex<Option<Value>>,
        jwt_claims: StdMutex<Option<Value>>,
        authorization_values: StdMutex<Vec<String>>,
        path: StdMutex<Option<String>>,
        message: StdMutex<Option<Value>>,
        send_status: StdMutex<StatusCode>,
        send_body: StdMutex<String>,
    }

    impl MockApnsState {
        fn new() -> Self {
            Self {
                send_calls: AtomicUsize::new(0),
                redirect_target_calls: AtomicUsize::new(0),
                authorization_valid: AtomicBool::new(false),
                topic_valid: AtomicBool::new(false),
                background_headers_valid: AtomicBool::new(false),
                jwt_header: StdMutex::new(None),
                jwt_claims: StdMutex::new(None),
                authorization_values: StdMutex::new(Vec::new()),
                path: StdMutex::new(None),
                message: StdMutex::new(None),
                send_status: StdMutex::new(StatusCode::OK),
                send_body: StdMutex::new("{}".to_owned()),
            }
        }
    }

    async fn mock_apns_send(
        AxumState(state): AxumState<Arc<MockApnsState>>,
        OriginalUri(uri): OriginalUri,
        headers: HeaderMap,
        axum::Json(message): axum::Json<Value>,
    ) -> Response<Body> {
        state.send_calls.fetch_add(1, Ordering::SeqCst);
        let authorization = headers
            .get(AUTHORIZATION)
            .and_then(|header| header.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        let mut parts = authorization
            .strip_prefix("Bearer ")
            .unwrap_or_default()
            .split('.');
        let decoded_header = parts
            .next()
            .and_then(|part| URL_SAFE_NO_PAD.decode(part).ok())
            .and_then(|part| serde_json::from_slice::<Value>(&part).ok());
        let decoded_claims = parts
            .next()
            .and_then(|part| URL_SAFE_NO_PAD.decode(part).ok())
            .and_then(|part| serde_json::from_slice::<Value>(&part).ok());
        let valid_authorization = authorization.starts_with("Bearer ")
            && decoded_header.as_ref().is_some_and(|header| {
                header.get("alg").and_then(Value::as_str) == Some("ES256")
                    && header.get("kid").and_then(Value::as_str) == Some("K1D2345678")
            })
            && decoded_claims.as_ref().is_some_and(|claims| {
                claims.get("iss").and_then(Value::as_str) == Some("TEAM123456")
                    && claims
                        .get("iat")
                        .and_then(Value::as_i64)
                        .is_some_and(|iat| iat > 0)
            });
        state
            .authorization_valid
            .store(valid_authorization, Ordering::SeqCst);
        state.topic_valid.store(
            headers.get("apns-topic").and_then(|h| h.to_str().ok()) == Some("com.example.app"),
            Ordering::SeqCst,
        );
        state.background_headers_valid.store(
            headers.get("apns-push-type").and_then(|h| h.to_str().ok()) == Some("background")
                && headers.get("apns-priority").and_then(|h| h.to_str().ok()) == Some("5"),
            Ordering::SeqCst,
        );
        *state.jwt_header.lock().unwrap() = decoded_header;
        *state.jwt_claims.lock().unwrap() = decoded_claims;
        state
            .authorization_values
            .lock()
            .unwrap()
            .push(authorization);
        *state.path.lock().unwrap() = Some(uri.path().to_owned());
        *state.message.lock().unwrap() = Some(message);
        let status = *state.send_status.lock().unwrap();
        let body = state.send_body.lock().unwrap().clone();
        let mut response = Response::builder().status(status);
        if status == StatusCode::FOUND {
            response = response.header("location", "/redirect-target");
        }
        response
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap()
    }

    async fn mock_apns_redirect_target(
        AxumState(state): AxumState<Arc<MockApnsState>>,
    ) -> StatusCode {
        state.redirect_target_calls.fetch_add(1, Ordering::SeqCst);
        StatusCode::NO_CONTENT
    }

    async fn start_mock_apns_server(
        state: Arc<MockApnsState>,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new()
            .route("/redirect-target", get(mock_apns_redirect_target))
            .fallback(mock_apns_send)
            .with_state(state);
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (format!("http://{address}"), task)
    }

    fn mock_apns_provider(host: &str) -> ApnsProvider {
        ApnsProvider::from_test_private_key(
            include_bytes!("../tests/fixtures/apns_test_private.p8"),
            "TEAM123456",
            "K1D2345678",
            "com.example.app",
            host,
        )
        .unwrap()
    }

    async fn mock_fcm_oauth(
        AxumState(state): AxumState<Arc<MockFcmState>>,
        Form(form): Form<HashMap<String, String>>,
    ) -> axum::Json<Value> {
        state.oauth_calls.fetch_add(1, Ordering::SeqCst);
        let valid_form = form.get("grant_type").map(String::as_str) == Some(FCM_GRANT_TYPE);
        let claims = form
            .get("assertion")
            .and_then(|assertion| assertion.split('.').nth(1))
            .and_then(|payload| URL_SAFE_NO_PAD.decode(payload).ok())
            .and_then(|payload| serde_json::from_slice::<Value>(&payload).ok());
        state.oauth_form_valid.store(valid_form, Ordering::SeqCst);
        *state.claims.lock().unwrap() = claims;
        axum::Json(json!({
            "access_token": "mock-fcm-oauth-access-token",
            "expires_in": 3600,
            "token_type": "Bearer"
        }))
    }

    async fn mock_fcm_send(
        AxumState(state): AxumState<Arc<MockFcmState>>,
        headers: HeaderMap,
        axum::Json(message): axum::Json<Value>,
    ) -> Response<Body> {
        state.send_calls.fetch_add(1, Ordering::SeqCst);
        let authorization = headers
            .get(AUTHORIZATION)
            .and_then(|header| header.to_str().ok());
        state.authorization_valid.store(
            authorization == Some("Bearer mock-fcm-oauth-access-token"),
            Ordering::SeqCst,
        );
        *state.message.lock().unwrap() = Some(message);
        let status = *state.send_status.lock().unwrap();
        let body = state.send_body.lock().unwrap().clone();
        Response::builder()
            .status(status)
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap()
    }

    async fn start_mock_fcm_server(
        state: Arc<MockFcmState>,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new()
            .route("/oauth/token", post(mock_fcm_oauth))
            .fallback(mock_fcm_send)
            .with_state(state);
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (format!("http://{address}"), task)
    }

    fn mock_fcm_provider(base_url: &str) -> FcmProvider {
        let service_account = json!({
            "type": "service_account",
            "project_id": "atermius-test-123",
            "client_email": "push@atermius-test-123.iam.gserviceaccount.com",
            "private_key": include_str!("../tests/fixtures/fcm_test_private.pem"),
            "token_uri": "https://attacker.invalid/token"
        });
        FcmProvider::from_test_service_account_json(
            service_account.to_string().as_bytes(),
            &format!("{base_url}/oauth/token"),
            base_url,
        )
        .unwrap()
    }

    struct FakeProvider {
        result: StdMutex<PushSendResult>,
        calls: AtomicUsize,
        saw_only_generic_payload: AtomicBool,
        expected_token: String,
        token_matched: AtomicBool,
    }

    impl FakeProvider {
        fn new(expected_token: &str, result: PushSendResult) -> Self {
            Self {
                result: StdMutex::new(result),
                calls: AtomicUsize::new(0),
                saw_only_generic_payload: AtomicBool::new(false),
                expected_token: expected_token.to_owned(),
                token_matched: AtomicBool::new(false),
            }
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    impl PushProvider for FakeProvider {
        fn supports(&self, _provider: PushProviderKind) -> bool {
            true
        }

        fn send<'a>(
            &'a self,
            _provider: PushProviderKind,
            token: Zeroizing<String>,
            payload: PushPayload,
        ) -> PushSendFuture<'a> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.token_matched
                .store(token.as_str() == self.expected_token, Ordering::SeqCst);
            self.saw_only_generic_payload.store(
                payload.wire_json() == r#"{"type":"sync_available"}"#,
                Ordering::SeqCst,
            );
            let result = *self.result.lock().unwrap();
            Box::pin(async move { result })
        }
    }

    fn test_config(data_dir: PathBuf) -> Config {
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
            relay_max_connections_per_user: 1,
            public_origin: Some("https://app.example.test".to_owned()),
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

    async fn test_state() -> AppState {
        let dir = std::env::temp_dir().join(format!("atermius-mobile-push-{}", Uuid::new_v4()));
        create_private_data_dir(&dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", dir.display());
        open_state(&database, test_config(dir)).await.unwrap()
    }

    async fn close_state(state: &AppState) {
        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    async fn seed_session(state: &AppState) -> (AuthUser, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("mobile-push-access-{}", Uuid::new_v4());
        let now = Utc::now();
        let created = now.to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{}@example.test", Uuid::new_v4()))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'push-test','sign','encrypt',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'family',?,?,?,? ,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(crate::sha256_hex(access.as_bytes()))
            .bind(format!("refresh-{}", Uuid::new_v4()))
            .bind((now + ChronoDuration::minutes(10)).to_rfc3339())
            .bind((now + ChronoDuration::days(30)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        (
            AuthUser {
                user_id,
                device_id,
                session_id,
                access_hash: crate::sha256_hex(access.as_bytes()),
                declares_record_schema2: false,
                declares_sync_redaction_v1: true,
            },
            access,
        )
    }

    fn headers(access: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access}")).unwrap(),
        );
        headers
    }

    async fn register(state: &AppState, user: &AuthUser, access: &str, token: &str) {
        let _ = register_endpoint_enabled(
            State(state.clone()),
            headers(access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: token.to_owned(),
            }),
        )
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn endpoint_registration_is_device_bound_encrypted_and_revocation_cleans_it() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let token = "fcm-installation-token-abcdefghijklmnop";
        let disabled = register_endpoint_with_provider(
            State(state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: token.to_owned(),
            }),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(disabled.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(disabled.body.code, "PUSH_DELIVERY_DISABLED");
        let stored_while_disabled: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(stored_while_disabled, 0);
        register(&state, &user, &access, token).await;
        let (stored_hash, stored_envelope): (String, String) = sqlx::query_as(
            "SELECT token_hash,token_envelope FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(stored_envelope.starts_with("npe1:"));
        assert!(!stored_envelope.contains(token));
        assert_ne!(stored_hash, crate::sha256_hex(token.as_bytes()));
        assert_eq!(
            decrypt_token(
                &state,
                &sqlx::query_scalar::<_, String>(
                    "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=?"
                )
                .bind(&user.device_id)
                .fetch_one(&state.db)
                .await
                .unwrap(),
                &user.device_id,
                PushProviderKind::FcmV1,
                &stored_hash,
                &stored_envelope,
            )
            .unwrap()
            .as_str(),
            token
        );

        let other_device = Uuid::new_v4().to_string();
        let mismatch = register_endpoint_enabled(
            State(state.clone()),
            headers(&access),
            Path(other_device),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: "fcm-installation-token-qrstuvwxyz123456".to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(mismatch.body.code, "DEVICE_MISMATCH");

        sqlx::query("UPDATE devices SET status='revoked',revoked_at=? WHERE device_id=?")
            .bind(Utc::now().to_rfc3339())
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();
        let remaining: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(remaining, 0);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn registration_only_enables_the_provider_supported_by_the_configured_adapter() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let fcm = mock_fcm_provider("http://127.0.0.1:1");
        let apns = register_endpoint_with_provider(
            State(state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::Apns,
                token: "apns-device-token-abcdefghijklmnop".to_owned(),
            }),
            Some(&fcm),
        )
        .await
        .unwrap_err();
        assert_eq!(apns.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(apns.body.code, "PUSH_DELIVERY_DISABLED");
        let absent: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(absent, 0);

        let registered = register_endpoint_with_provider(
            State(state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: "fcm-device-token-abcdefghijklmnop".to_owned(),
            }),
            Some(&fcm),
        )
        .await
        .unwrap();
        assert_eq!(registered.0["status"], "registered");
        assert_eq!(registered.0["provider"], "fcm_v1");
        let apns_adapter = mock_apns_provider("http://127.0.0.1:1");
        let configured = ConfiguredPushProvider {
            fcm: Some(fcm),
            apns: Some(apns_adapter),
        };
        let malformed_apns = register_endpoint_with_provider(
            State(state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::Apns,
                token: "not-a-hex-device-token-abcdefghijkl".to_owned(),
            }),
            Some(&configured),
        )
        .await
        .unwrap_err();
        assert_eq!(malformed_apns.status, StatusCode::BAD_REQUEST);
        assert_eq!(malformed_apns.body.code, "INVALID_PUSH_ENDPOINT");
        let apns_token = "AB".repeat(32);
        let normalized_apns_token = "ab".repeat(32);
        let registered_apns = register_endpoint_with_provider(
            State(state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::Apns,
                token: apns_token.clone(),
            }),
            Some(&configured),
        )
        .await
        .unwrap();
        assert_eq!(registered_apns.0["provider"], "apns");
        let providers: Vec<String> = sqlx::query_scalar(
            "SELECT provider FROM notification_push_endpoints WHERE device_id=? ORDER BY provider",
        )
        .bind(&user.device_id)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(providers, vec!["apns".to_owned(), "fcm_v1".to_owned()]);
        let (apns_endpoint_id, apns_hash, apns_envelope): (String, String, String) =
            sqlx::query_as(
                "SELECT endpoint_id,token_hash,token_envelope FROM notification_push_endpoints WHERE device_id=? AND provider='apns'",
            )
            .bind(&user.device_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert!(!apns_envelope.contains(&apns_token));
        assert_eq!(
            decrypt_token(
                &state,
                &apns_endpoint_id,
                &user.device_id,
                PushProviderKind::Apns,
                &apns_hash,
                &apns_envelope,
            )
            .unwrap()
            .as_str(),
            normalized_apns_token.as_str()
        );
        let (other_user, other_access) = seed_session(&state).await;
        let case_variant_duplicate = register_endpoint_with_provider(
            State(state.clone()),
            headers(&other_access),
            Path(other_user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::Apns,
                token: normalized_apns_token,
            }),
            Some(&configured),
        )
        .await
        .unwrap_err();
        assert_eq!(case_variant_duplicate.status, StatusCode::CONFLICT);
        assert_eq!(case_variant_duplicate.body.code, "PUSH_ENDPOINT_IN_USE");
        let duplicate_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id=? AND provider='apns'",
        )
        .bind(&other_user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(duplicate_rows, 0);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn registration_rejects_another_devices_token_and_delete_is_idempotent() {
        let state = test_state().await;
        let (owner, owner_access) = seed_session(&state).await;
        let (other, other_access) = seed_session(&state).await;
        let token = "fcm-installation-token-abcdefghijklmnop";
        register(&state, &owner, &owner_access, token).await;
        let conflict = register_endpoint_enabled(
            State(state.clone()),
            headers(&other_access),
            Path(other.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: token.to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(conflict.status, StatusCode::CONFLICT);
        assert_eq!(conflict.body.code, "PUSH_ENDPOINT_IN_USE");

        let invalid_provider = delete_endpoint(
            State(state.clone()),
            headers(&owner_access),
            Path((owner.device_id.clone(), "future_provider".to_owned())),
        )
        .await
        .unwrap_err();
        assert_eq!(invalid_provider.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid_provider.body.code, "INVALID_PUSH_PROVIDER");

        let _ = delete_endpoint(
            State(state.clone()),
            headers(&owner_access),
            Path((owner.device_id.clone(), "fcm_v1".to_owned())),
        )
        .await
        .unwrap();
        let _ = delete_endpoint(
            State(state.clone()),
            headers(&owner_access),
            Path((owner.device_id.clone(), "fcm_v1".to_owned())),
        )
        .await
        .unwrap();
        let remaining: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&owner.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(remaining, 0);
        close_state(&state).await;
    }

    async fn seed_vault_and_other_endpoint(
        state: &AppState,
        source: &AuthUser,
        source_access: &str,
        recipient: &AuthUser,
        recipient_access: &str,
    ) -> String {
        let vault_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,name_envelope,active_epoch,membership_version,created_at) VALUES(?,?,'opaque',1,1,?)")
            .bind(&vault_id)
            .bind(&source.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&source.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
            .bind(&vault_id)
            .bind(&recipient.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        register(
            state,
            recipient,
            recipient_access,
            "fcm-installation-token-abcdefghijklmnop",
        )
        .await;
        // An additional endpoint on the committing device must not be woken.
        register(
            state,
            source,
            source_access,
            "fcm-source-installation-token-abcdefghijkl",
        )
        .await;
        vault_id
    }

    #[tokio::test]
    async fn commit_hint_is_coalesced_and_provider_payload_has_no_vault_metadata() {
        let state = test_state().await;
        let (source, source_access) = seed_session(&state).await;
        let (recipient, recipient_access) = seed_session(&state).await;
        let vault = seed_vault_and_other_endpoint(
            &state,
            &source,
            &source_access,
            &recipient,
            &recipient_access,
        )
        .await;
        let (revoked_member, revoked_member_access) = seed_session(&state).await;
        let now_rfc3339 = Utc::now().to_rfc3339();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','revoked',?)")
            .bind(&vault)
            .bind(&revoked_member.user_id)
            .bind(&now_rfc3339)
            .execute(&state.db)
            .await
            .unwrap();
        register(
            &state,
            &revoked_member,
            &revoked_member_access,
            "fcm-revoked-member-token-abcdefghijklmnop",
        )
        .await;

        let (disabled_user, disabled_user_access) = seed_session(&state).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
            .bind(&vault)
            .bind(&disabled_user.user_id)
            .bind(&now_rfc3339)
            .execute(&state.db)
            .await
            .unwrap();
        register(
            &state,
            &disabled_user,
            &disabled_user_access,
            "fcm-disabled-user-token-abcdefghijklmnop",
        )
        .await;
        sqlx::query("UPDATE users SET status='disabled' WHERE user_id=?")
            .bind(&disabled_user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        let now = Utc::now().timestamp();
        for _ in 0..3 {
            let mut tx = state.db.begin().await.unwrap();
            enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now)
                .await
                .unwrap();
            tx.commit().await.unwrap();
        }
        let recipient_endpoint: String = sqlx::query_scalar(
            "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&recipient.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let (requested, delivered): (i64, i64) = sqlx::query_as(
            "SELECT requested_seq,delivered_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!((requested, delivered), (3, 0));
        let source_endpoint_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM notification_push_outbox o JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id WHERE e.device_id=?")
            .bind(&source.device_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(source_endpoint_count, 0);
        for device_id in [&revoked_member.device_id, &disabled_user.device_id] {
            let excluded_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM notification_push_outbox o JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id WHERE e.device_id=?",
            )
            .bind(device_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            assert_eq!(excluded_count, 0, "inactive recipients get no hint");
        }
        let queued_endpoints: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notification_push_outbox")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(queued_endpoints, 1);

        let fake = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::Accepted,
        );
        assert!(run_one_due(&state, &fake, now).await.unwrap());
        assert_eq!(fake.calls(), 1);
        assert!(fake.token_matched.load(Ordering::SeqCst));
        assert!(fake.saw_only_generic_payload.load(Ordering::SeqCst));
        let remaining: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=?")
                .bind(&recipient_endpoint)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining, 0);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn provider_retry_restart_invalid_token_and_dead_letter_are_bounded() {
        let state = test_state().await;
        let (source, source_access) = seed_session(&state).await;
        let (recipient, recipient_access) = seed_session(&state).await;
        let vault = seed_vault_and_other_endpoint(
            &state,
            &source,
            &source_access,
            &recipient,
            &recipient_access,
        )
        .await;
        let now = Utc::now().timestamp();
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let interrupted = claim_one_due(&state, now).await.unwrap().unwrap();
        let not_sent = claim_one_due(&state, now + 1).await.unwrap();
        assert!(
            not_sent.is_none(),
            "active lease must prevent duplicate sends"
        );
        // Simulate a process restart after the lease expires; the same durable
        // row is claimed again and accepted by the deterministic fake.
        let fake = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::Accepted,
        );
        assert!(
            run_one_due(&state, &fake, now + PUSH_LEASE_SECONDS + 1)
                .await
                .unwrap()
        );
        assert_eq!(fake.calls(), 1);
        assert!(interrupted.attempt_count > 0);

        let endpoint_id: String = sqlx::query_scalar(
            "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&recipient.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now + 100)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let unavailable = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::RetryableFailure,
        );
        assert!(run_one_due(&state, &unavailable, now + 100).await.unwrap());
        let next_attempt: i64 = sqlx::query_scalar(
            "SELECT next_attempt_at FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(next_attempt, now + 100 + PUSH_RETRY_BASE_SECONDS);
        assert!(
            !run_one_due(&state, &unavailable, next_attempt - 1)
                .await
                .unwrap()
        );

        let invalid = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::InvalidToken,
        );
        assert!(run_one_due(&state, &invalid, next_attempt).await.unwrap());
        let remaining: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(remaining, 0);
        let remaining_outbox: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=?")
                .bind(&endpoint_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining_outbox, 0);
        let delivery_results: Vec<(String, i64)> = sqlx::query_as(
            "SELECT outcome,count FROM notification_push_delivery_daily \
             WHERE provider='fcm_v1' AND day_start=? ORDER BY outcome",
        )
        .bind(utc_day_start(now))
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(
            delivery_results,
            vec![
                ("accepted".to_owned(), 1),
                ("invalid_token".to_owned(), 1),
                ("retryable_failure".to_owned(), 1),
            ],
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn endpoint_key_id_mismatch_fails_closed_until_device_reregisters() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let token = "fcm-installation-token-abcdefghijklmnop";
        register(&state, &user, &access, token).await;
        let (endpoint_id, token_hash, envelope): (String, String, String) = sqlx::query_as(
            "SELECT endpoint_id,token_hash,token_envelope FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&user.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let rotated_state = AppState {
            auth_rate_key: Arc::new([42_u8; 32]),
            ..state.clone()
        };
        assert!(
            decrypt_token(
                &rotated_state,
                &endpoint_id,
                &user.device_id,
                PushProviderKind::FcmV1,
                &token_hash,
                &envelope,
            )
            .is_err()
        );
        let now = Utc::now().timestamp();
        sqlx::query("INSERT INTO notification_push_outbox(endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at,lease_id,lease_until,dead_lettered,updated_at) VALUES(?,1,0,0,?,NULL,NULL,0,?)")
            .bind(&endpoint_id)
            .bind(now)
            .bind(now)
            .execute(&state.db)
            .await
            .unwrap();
        let provider = FakeProvider::new(token, PushSendResult::Accepted);
        assert!(run_one_due(&rotated_state, &provider, now).await.unwrap());
        assert_eq!(
            provider.calls(),
            0,
            "unreadable endpoint must never be sent"
        );
        let parked: (i64, i64) = sqlx::query_as(
            "SELECT dead_lettered,next_attempt_at FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(parked, (1, PUSH_DEAD_LETTER_TIME));

        let replacement_token = token;
        let _ = register_endpoint_enabled(
            State(rotated_state.clone()),
            headers(&access),
            Path(user.device_id.clone()),
            Json(RegisterPushEndpointRequest {
                provider: PushProviderKind::FcmV1,
                token: replacement_token.to_owned(),
            }),
        )
        .await
        .unwrap();
        let reawakened: (i64, i64, i64) = sqlx::query_as(
            "SELECT requested_seq,attempt_count,dead_lettered FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(reawakened, (2, 0, 0));
        let replacement_provider = FakeProvider::new(replacement_token, PushSendResult::Accepted);
        assert!(
            run_one_due(&rotated_state, &replacement_provider, now)
                .await
                .unwrap()
        );
        assert_eq!(replacement_provider.calls(), 1);
        assert!(replacement_provider.token_matched.load(Ordering::SeqCst));
        close_state(&state).await;
    }

    #[tokio::test]
    async fn retry_exhaustion_dead_letters_until_a_new_commit_reawakens_it() {
        let state = test_state().await;
        let (source, source_access) = seed_session(&state).await;
        let (recipient, recipient_access) = seed_session(&state).await;
        let vault = seed_vault_and_other_endpoint(
            &state,
            &source,
            &source_access,
            &recipient,
            &recipient_access,
        )
        .await;
        let now = Utc::now().timestamp();
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let endpoint_id: String = sqlx::query_scalar(
            "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&recipient.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let failing = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::RetryableFailure,
        );
        let mut due_at = now;
        for attempt in 1..=PUSH_MAX_ATTEMPTS {
            assert!(run_one_due(&state, &failing, due_at).await.unwrap());
            let (stored_attempt, next_attempt, dead_lettered): (i64, i64, i64) =
                sqlx::query_as("SELECT attempt_count,next_attempt_at,dead_lettered FROM notification_push_outbox WHERE endpoint_id=?")
                    .bind(&endpoint_id)
                    .fetch_one(&state.db)
                    .await
                    .unwrap();
            assert_eq!(stored_attempt, attempt);
            if attempt < PUSH_MAX_ATTEMPTS {
                assert_eq!(dead_lettered, 0);
                assert_eq!(next_attempt, due_at + retry_delay(attempt));
                due_at = next_attempt;
            } else {
                assert_eq!(dead_lettered, 1);
                assert_eq!(next_attempt, PUSH_DEAD_LETTER_TIME);
            }
        }
        assert_eq!(failing.calls(), PUSH_MAX_ATTEMPTS as usize);
        assert!(!run_one_due(&state, &failing, due_at + 3600).await.unwrap());

        let recommitted_at = due_at + 3600;
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, recommitted_at)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let reawakened: (i64, i64, i64, i64) = sqlx::query_as(
            "SELECT requested_seq,attempt_count,next_attempt_at,dead_lettered FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(reawakened, (2, 0, recommitted_at, 0));
        let accepted = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::Accepted,
        );
        assert!(
            run_one_due(&state, &accepted, recommitted_at)
                .await
                .unwrap()
        );
        assert_eq!(accepted.calls(), 1);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn new_commit_during_last_inflight_attempt_is_not_dead_lettered_by_old_failure() {
        let state = test_state().await;
        let (source, source_access) = seed_session(&state).await;
        let (recipient, recipient_access) = seed_session(&state).await;
        let vault = seed_vault_and_other_endpoint(
            &state,
            &source,
            &source_access,
            &recipient,
            &recipient_access,
        )
        .await;
        let now = Utc::now().timestamp();
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let endpoint_id: String = sqlx::query_scalar(
            "SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=?",
        )
        .bind(&recipient.device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        sqlx::query("UPDATE notification_push_outbox SET attempt_count=?,next_attempt_at=? WHERE endpoint_id=?")
            .bind(PUSH_MAX_ATTEMPTS - 1)
            .bind(now)
            .bind(&endpoint_id)
            .execute(&state.db)
            .await
            .unwrap();
        let last_attempt = claim_one_due(&state, now).await.unwrap().unwrap();
        assert_eq!(last_attempt.attempt_count, PUSH_MAX_ATTEMPTS);

        // A second commit arrives while the last attempt still owns the lease.
        // It increments the requested sequence and resets retry bookkeeping.
        let mut tx = state.db.begin().await.unwrap();
        enqueue_sync_available_tx(&mut tx, &vault, &source.device_id, now + 1)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        finish_delivery(
            &state,
            &last_attempt,
            PushSendResult::RetryableFailure,
            now + 2,
        )
        .await
        .unwrap();

        let after_stale_failure: (i64, i64, i64, Option<String>, i64) = sqlx::query_as(
            "SELECT requested_seq,attempt_count,next_attempt_at,lease_id,dead_lettered FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after_stale_failure, (2, 0, now + 2, None, 0));
        let accepted = FakeProvider::new(
            "fcm-installation-token-abcdefghijklmnop",
            PushSendResult::Accepted,
        );
        assert!(run_one_due(&state, &accepted, now + 2).await.unwrap());
        assert_eq!(accepted.calls(), 1);
        let remaining: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=?")
                .bind(&endpoint_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining, 0);
        close_state(&state).await;
    }

    #[test]
    fn generic_payload_and_retry_schedule_are_bounded() {
        let payload = PushPayload::SyncAvailable.wire_json();
        let parsed: Value = serde_json::from_str(payload).unwrap();
        assert_eq!(parsed, json!({"type":"sync_available"}));
        assert!(retry_delay(1) <= PUSH_RETRY_MAX_SECONDS);
        assert!(retry_delay(30) <= PUSH_RETRY_MAX_SECONDS);
        assert_eq!(retry_delay(1), PUSH_RETRY_BASE_SECONDS);
        assert_eq!(retry_delay(9), PUSH_RETRY_MAX_SECONDS);
        assert!(validate_token("bad token with spaces").is_err());
        assert!(validate_token("短").is_err());
        assert!(validate_token("tiny").is_err());
    }

    #[test]
    fn invalid_push_registration_token_returns_only_a_generic_error() {
        let rejected_secret = "credential-that-is-invalid because it contains spaces";
        let error =
            normalize_push_token(PushProviderKind::FcmV1, rejected_secret.to_owned()).unwrap_err();
        assert_eq!(error.body.code, "INVALID_PUSH_ENDPOINT");
        assert!(!error.body.message.contains(rejected_secret));
    }

    #[test]
    fn apns_configuration_and_device_token_validation_are_strict() {
        assert!(valid_apple_identifier("TEAM123456"));
        assert!(valid_apple_identifier("K1D2345678"));
        assert!(!valid_apple_identifier("TEAM12345"));
        assert!(!valid_apple_identifier("TEAM-23456"));
        assert!(!valid_apple_identifier("TEAM12345é"));

        assert!(valid_apns_topic("com.example.app"));
        assert!(!valid_apns_topic("example"));
        assert!(!valid_apns_topic("com..app"));
        assert!(!valid_apns_topic("-com.example"));
        assert!(!valid_apns_topic("com.example_underscore"));
        assert!(!valid_apns_topic(&format!("{}.app", "a".repeat(64))));
        assert!(!valid_apns_topic(&format!("{}.app", "a".repeat(250))));

        assert_eq!(parse_apns_sandbox(None), Ok(false));
        assert_eq!(parse_apns_sandbox(Some("false")), Ok(false));
        assert_eq!(parse_apns_sandbox(Some("true")), Ok(true));
        assert!(parse_apns_sandbox(Some("TRUE")).is_err());
        assert_eq!(apns_host(false), APNS_PRODUCTION_HOST);
        assert_eq!(apns_host(true), APNS_SANDBOX_HOST);

        let uppercase = "AB".repeat(32);
        let normalized = "ab".repeat(32);
        assert_eq!(
            normalize_apns_device_token(&uppercase).as_deref(),
            Some(normalized.as_str())
        );
        for invalid in [
            "a".repeat(31),
            "a".repeat(33),
            "g".repeat(64),
            format!("{}?path=/attacker", "a".repeat(32)),
            "a".repeat(APNS_TOKEN_MAX_HEX_CHARS + 2),
        ] {
            assert!(normalize_apns_device_token(&invalid).is_none());
        }
        assert!(validate_provider_token(PushProviderKind::Apns, &uppercase).is_ok());
        assert!(validate_provider_token(PushProviderKind::Apns, "not-an-apns-token").is_err());
        assert!(
            ApnsProvider::from_test_private_key(
                b"not a p8 private key",
                "TEAM123456",
                "K1D2345678",
                "com.example.app",
                "http://127.0.0.1:1",
            )
            .is_err()
        );
    }

    #[tokio::test]
    async fn apns_adapter_signs_caches_and_sends_only_the_generic_hint() {
        let state = Arc::new(MockApnsState::new());
        let (host, server) = start_mock_apns_server(state.clone()).await;
        let provider = mock_apns_provider(&host);
        assert!(provider.supports(PushProviderKind::Apns));
        assert!(!provider.supports(PushProviderKind::FcmV1));
        let uppercase_token = "AB".repeat(32);

        for _ in 0..2 {
            let result = provider
                .send(
                    PushProviderKind::Apns,
                    Zeroizing::new(uppercase_token.clone()),
                    PushPayload::SyncAvailable,
                )
                .await;
            assert_eq!(result, PushSendResult::Accepted);
        }

        assert_eq!(state.send_calls.load(Ordering::SeqCst), 2);
        assert!(state.authorization_valid.load(Ordering::SeqCst));
        assert!(state.topic_valid.load(Ordering::SeqCst));
        assert!(state.background_headers_valid.load(Ordering::SeqCst));
        let expected_path = format!("/3/device/{}", "ab".repeat(32));
        assert_eq!(
            state.path.lock().unwrap().as_deref(),
            Some(expected_path.as_str())
        );
        let header = state.jwt_header.lock().unwrap().clone().unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "K1D2345678");
        let claims = state.jwt_claims.lock().unwrap().clone().unwrap();
        assert_eq!(claims["iss"], "TEAM123456");
        assert!(claims["iat"].as_i64().is_some_and(|iat| iat > 0));
        let authorization_values = state.authorization_values.lock().unwrap();
        assert_eq!(authorization_values.len(), 2);
        assert_eq!(authorization_values[0], authorization_values[1]);
        let jwt = authorization_values[0].strip_prefix("Bearer ").unwrap();
        let verification_key = jsonwebtoken::DecodingKey::from_ec_pem(include_bytes!(
            "../tests/fixtures/apns_test_public.pem"
        ))
        .unwrap();
        let mut validation = jsonwebtoken::Validation::new(Algorithm::ES256);
        validation.validate_exp = false;
        validation.validate_aud = false;
        validation.required_spec_claims.clear();
        let verified = jsonwebtoken::decode::<Value>(jwt, &verification_key, &validation).unwrap();
        assert_eq!(verified.claims["iss"], "TEAM123456");
        assert_eq!(
            state.message.lock().unwrap().as_ref().unwrap(),
            &json!({"aps":{"content-available":1},"type":"sync_available"})
        );
        server.abort();
    }

    #[tokio::test]
    async fn apns_invalid_tokens_are_rejected_before_path_and_only_exact_410_unregisters() {
        let state = Arc::new(MockApnsState::new());
        let (host, server) = start_mock_apns_server(state.clone()).await;
        let provider = mock_apns_provider(&host);

        let invalid = provider
            .send(
                PushProviderKind::Apns,
                Zeroizing::new("aa/../../attacker".to_owned()),
                PushPayload::SyncAvailable,
            )
            .await;
        assert_eq!(invalid, PushSendResult::RetryableFailure);
        assert_eq!(state.send_calls.load(Ordering::SeqCst), 0);

        *state.send_status.lock().unwrap() = StatusCode::GONE;
        *state.send_body.lock().unwrap() = json!({"reason":"Unregistered"}).to_string();
        let token = Zeroizing::new("cd".repeat(32));
        assert_eq!(
            provider
                .send(
                    PushProviderKind::Apns,
                    token.clone(),
                    PushPayload::SyncAvailable
                )
                .await,
            PushSendResult::InvalidToken
        );

        *state.send_body.lock().unwrap() = json!({"reason":"BadDeviceToken"}).to_string();
        assert_eq!(
            provider
                .send(
                    PushProviderKind::Apns,
                    token.clone(),
                    PushPayload::SyncAvailable
                )
                .await,
            PushSendResult::RetryableFailure
        );
        *state.send_status.lock().unwrap() = StatusCode::BAD_REQUEST;
        *state.send_body.lock().unwrap() = json!({"reason":"Unregistered"}).to_string();
        assert_eq!(
            provider
                .send(
                    PushProviderKind::Apns,
                    token.clone(),
                    PushPayload::SyncAvailable
                )
                .await,
            PushSendResult::RetryableFailure
        );

        *state.send_status.lock().unwrap() = StatusCode::GONE;
        *state.send_body.lock().unwrap() = json!({
            "reason": "Unregistered",
            "padding": "x".repeat(APNS_RESPONSE_MAX_BYTES)
        })
        .to_string();
        assert_eq!(
            provider
                .send(
                    PushProviderKind::Apns,
                    token.clone(),
                    PushPayload::SyncAvailable
                )
                .await,
            PushSendResult::RetryableFailure
        );

        *state.send_status.lock().unwrap() = StatusCode::FOUND;
        *state.send_body.lock().unwrap() = "{}".to_owned();
        assert_eq!(
            provider
                .send(PushProviderKind::Apns, token, PushPayload::SyncAvailable)
                .await,
            PushSendResult::RetryableFailure
        );
        assert_eq!(state.redirect_target_calls.load(Ordering::SeqCst), 0);
        assert_eq!(state.send_calls.load(Ordering::SeqCst), 5);
        server.abort();
    }

    #[tokio::test]
    async fn fcm_http_v1_sends_only_generic_hint_and_reuses_oauth_access_token() {
        let state = Arc::new(MockFcmState::new());
        let (base_url, server) = start_mock_fcm_server(state.clone()).await;
        let provider = mock_fcm_provider(&base_url);
        assert!(provider.supports(PushProviderKind::FcmV1));
        assert!(!provider.supports(PushProviderKind::Apns));

        for _ in 0..2 {
            let result = provider
                .send(
                    PushProviderKind::FcmV1,
                    Zeroizing::new("test-device-push-token-0123456789".to_owned()),
                    PushPayload::SyncAvailable,
                )
                .await;
            assert_eq!(result, PushSendResult::Accepted);
        }

        assert!(state.oauth_form_valid.load(Ordering::SeqCst));
        assert!(state.authorization_valid.load(Ordering::SeqCst));
        assert_eq!(state.oauth_calls.load(Ordering::SeqCst), 1);
        assert_eq!(state.send_calls.load(Ordering::SeqCst), 2);
        let claims = state.claims.lock().unwrap().clone().unwrap();
        assert_eq!(
            claims["iss"],
            "push@atermius-test-123.iam.gserviceaccount.com"
        );
        assert_eq!(claims["scope"], FCM_SCOPE);
        assert_eq!(claims["aud"], FCM_OAUTH_URL);
        assert_eq!(
            claims["exp"].as_i64().unwrap() - claims["iat"].as_i64().unwrap(),
            3600
        );

        let message = state.message.lock().unwrap().clone().unwrap();
        assert_eq!(
            message,
            json!({
                "message": {
                    "token": "test-device-push-token-0123456789",
                    "data": {"type": "sync_available"},
                    "apns": {
                        "headers": {
                            "apns-push-type": "background",
                            "apns-priority": "5"
                        },
                        "payload": {"aps": {"content-available": 1}}
                    }
                }
            })
        );
        server.abort();
    }

    #[tokio::test]
    async fn fcm_only_marks_explicit_unregistered_tokens_invalid() {
        let state = Arc::new(MockFcmState::new());
        let (base_url, server) = start_mock_fcm_server(state.clone()).await;
        let provider = mock_fcm_provider(&base_url);
        *state.send_status.lock().unwrap() = StatusCode::NOT_FOUND;
        *state.send_body.lock().unwrap() = json!({
            "error": {
                "status": "NOT_FOUND",
                "details": [{"errorCode": "UNREGISTERED"}]
            }
        })
        .to_string();
        async fn send(provider: &FcmProvider) -> PushSendResult {
            provider
                .send(
                    PushProviderKind::FcmV1,
                    Zeroizing::new("test-device-push-token-0123456789".to_owned()),
                    PushPayload::SyncAvailable,
                )
                .await
        }
        assert_eq!(send(&provider).await, PushSendResult::InvalidToken);

        *state.send_status.lock().unwrap() = StatusCode::UNAUTHORIZED;
        assert_eq!(send(&provider).await, PushSendResult::RetryableFailure);
        *state.send_status.lock().unwrap() = StatusCode::BAD_REQUEST;
        *state.send_body.lock().unwrap() = json!({
            "error": {"details": [{"errorCode": "INVALID_ARGUMENT"}]}
        })
        .to_string();
        assert_eq!(send(&provider).await, PushSendResult::RetryableFailure);
        *state.send_body.lock().unwrap() = json!({
            "error": {"details": [{"errorCode": "UNREGISTERED"}]}
        })
        .to_string();
        assert_eq!(send(&provider).await, PushSendResult::RetryableFailure);
        *state.send_status.lock().unwrap() = StatusCode::NOT_FOUND;
        *state.send_body.lock().unwrap() = json!({
            "error": {"details": [{"errorCode": "NOT_FOUND"}]}
        })
        .to_string();
        assert_eq!(send(&provider).await, PushSendResult::RetryableFailure);
        assert_eq!(state.oauth_calls.load(Ordering::SeqCst), 1);
        assert_eq!(state.send_calls.load(Ordering::SeqCst), 5);
        server.abort();
    }
}
