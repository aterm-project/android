use std::future::Future;

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
    pub request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Value>,
}

/// Request-scoped, server-generated context shared by response errors and
/// tracing. Keep this context deliberately small: it must never contain the
/// request URI, headers, body, account data, or other caller-controlled values.
#[derive(Clone, Debug)]
pub(crate) struct RequestContext {
    request_id: String,
    api_request: bool,
}

impl RequestContext {
    pub(crate) fn new(request_id: String, api_request: bool) -> Self {
        Self {
            request_id,
            api_request,
        }
    }

    pub(crate) fn request_id(&self) -> &str {
        &self.request_id
    }
}

tokio::task_local! {
    static REQUEST_CONTEXT: RequestContext;
}

pub(crate) async fn with_request_context<T>(
    context: RequestContext,
    future: impl Future<Output = T>,
) -> T {
    REQUEST_CONTEXT.scope(context, future).await
}

fn current_request_context() -> Option<RequestContext> {
    REQUEST_CONTEXT.try_with(Clone::clone).ok()
}

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub body: ErrorBody,
    pub retry_after_secs: Option<u64>,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &str, message: &str) -> Self {
        let request_id = current_request_context()
            .map(|context| context.request_id)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        Self {
            status,
            retry_after_secs: None,
            body: ErrorBody {
                code: code.into(),
                message: message.into(),
                request_id,
                details: None,
            },
        }
    }
    pub fn internal(_: impl std::fmt::Display) -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "request could not be completed",
        )
    }
    pub fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "AUTH_REQUIRED",
            "authentication is required",
        )
    }
    pub fn reauth_required() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "REAUTH_REQUIRED",
            "reauthentication is required",
        )
    }
    pub fn forbidden(code: &str, message: &str) -> Self {
        Self::new(StatusCode::FORBIDDEN, code, message)
    }
    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "NOT_FOUND", "resource was not found")
    }
    pub fn conflict(code: &str, message: &str) -> Self {
        Self::new(StatusCode::CONFLICT, code, message)
    }
    pub fn vault_deletion_pending() -> Self {
        Self::conflict(
            "VAULT_DELETION_PENDING",
            "vault is read-only while deletion is pending",
        )
    }
    pub fn invalid_envelope(message: &str) -> Self {
        Self::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "INVALID_ENVELOPE",
            message,
        )
    }
    pub fn bad_request(code: &str, message: &str) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, message)
    }
    pub fn gone(code: &str, message: &str) -> Self {
        Self::new(StatusCode::GONE, code, message)
    }
    pub fn too_large(message: &str) -> Self {
        Self::new(StatusCode::PAYLOAD_TOO_LARGE, "PAYLOAD_TOO_LARGE", message)
    }
    pub fn rate_limited(retry_after_secs: u64) -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "authentication attempts exceeded; try again later",
        )
        .with_retry_after(retry_after_secs)
    }
    pub fn presence_heartbeat_rate_limited() -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "PRESENCE_HEARTBEAT_RATE_LIMITED",
            "presence heartbeat was recently renewed",
        )
        .with_retry_after(5)
    }
    pub(crate) fn with_retry_after(mut self, seconds: u64) -> Self {
        self.retry_after_secs = Some(seconds.max(1));
        self
    }
    pub fn with_details(mut self, details: serde_json::Value) -> Self {
        self.body.details = Some(details);
        self
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.body.code, self.body.message)
    }
}
impl std::error::Error for ApiError {}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        if let Some(context) = current_request_context()
            && context.api_request
        {
            tracing::info!(
                request_id = %context.request_id,
                error_category = safe_error_category(&self.body.code),
                http_status = self.status.as_u16(),
                "API request returned an error"
            );
        }
        let retry_after_secs = self.retry_after_secs;
        let mut response = (self.status, Json(ErrorEnvelope { error: self.body })).into_response();
        if let Some(seconds) = retry_after_secs
            && let Ok(value) = axum::http::HeaderValue::from_str(&seconds.to_string())
        {
            response
                .headers_mut()
                .insert(axum::http::header::RETRY_AFTER, value);
        }
        response
    }
}

fn safe_error_category(code: &str) -> &str {
    if !code.is_empty()
        && code.len() <= 64
        && code
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
    {
        code
    } else {
        "UNCLASSIFIED"
    }
}

#[cfg(test)]
mod tests {
    use axum::{http::StatusCode, response::IntoResponse};

    use crate::ApiError;

    #[test]
    fn rate_limited_error_has_retry_after_without_changing_body_shape() {
        let response = ApiError::rate_limited(47).into_response();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[axum::http::header::RETRY_AFTER], "47");
    }

    #[test]
    fn error_categories_are_bounded_and_do_not_accept_arbitrary_values() {
        assert_eq!(
            super::safe_error_category("INVALID_ENVELOPE"),
            "INVALID_ENVELOPE"
        );
        assert_eq!(super::safe_error_category(""), "UNCLASSIFIED");
        assert_eq!(super::safe_error_category("secret marker"), "UNCLASSIFIED");
        assert_eq!(super::safe_error_category(&"A".repeat(65)), "UNCLASSIFIED");
    }
}
