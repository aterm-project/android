use std::{net::SocketAddr, path::PathBuf, time::Duration};

use axum::{Router, body::Body, http::Request};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{SecondsFormat, Utc};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::{net::TcpListener, task::JoinHandle, time::timeout};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{
        Message,
        client::IntoClientRequest,
        http::{HeaderValue, Request as WsRequest, header::ORIGIN},
    },
};
use tower::ServiceExt;
use uuid::Uuid;

use atermius_server::{AppState, AuthRateLimits, BackupReplicationEnv, Config, open_state, router};

const PUBLIC_ORIGIN: &str = "https://app.example.test";
const MAX_WS_MESSAGE_BYTES: usize = 64 * 1024;

struct TestIdentity {
    user_id: String,
    device_id: String,
    access_token: String,
    signing: SigningKey,
}

type TestWebSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct ConnectedRoom {
    host: TestIdentity,
    observer: TestIdentity,
    admin: TestIdentity,
    vault_id: String,
    session_id: String,
    rejoin_ticket: String,
    host_socket: TestWebSocket,
    observer_socket: TestWebSocket,
}

struct TestServer {
    state: AppState,
    app: Router,
    addr: SocketAddr,
    task: JoinHandle<Result<(), std::io::Error>>,
    data_dir: PathBuf,
}

impl TestServer {
    async fn start() -> Self {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-terminal-ws-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let config = Config {
            data_dir: data_dir.clone(),
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: true,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: Some(PUBLIC_ORIGIN.to_owned()),
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 60,
            admin_usernames: vec!["live-admin@example.test".to_owned()],
            auth_rate_limits: AuthRateLimits::default(),
        };
        let state = open_state(&database_url, config)
            .await
            .expect("open isolated terminal collaboration database");
        let app = router(state.clone()).await;
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind isolated WebSocket server");
        let addr = listener.local_addr().unwrap();
        let server_app = app.clone();
        let task = tokio::spawn(async move {
            axum::serve(
                listener,
                server_app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
        });
        Self {
            state,
            app,
            addr,
            task,
            data_dir,
        }
    }

    async fn stop(self) {
        self.task.abort();
        let _ = self.task.await;
        self.state.db.close().await;
        let _ = tokio::fs::remove_dir_all(self.data_dir).await;
    }

    async fn post(
        &self,
        path: &str,
        identity: &TestIdentity,
        body: Option<Value>,
    ) -> (axum::http::StatusCode, Value) {
        self.request(axum::http::Method::POST, path, identity, body)
            .await
    }

    async fn put(
        &self,
        path: &str,
        identity: &TestIdentity,
        body: Option<Value>,
    ) -> (axum::http::StatusCode, Value) {
        self.request(axum::http::Method::PUT, path, identity, body)
            .await
    }

    async fn request(
        &self,
        method: axum::http::Method,
        path: &str,
        identity: &TestIdentity,
        body: Option<Value>,
    ) -> (axum::http::StatusCode, Value) {
        let builder = Request::builder()
            .method(method)
            .uri(path)
            .header("authorization", format!("Bearer {}", identity.access_token))
            .header("x-atermius-capability-marker", "v2")
            .header("content-type", "application/json");
        let request_body = body
            .map(|body| Body::from(body.to_string()))
            .unwrap_or_else(Body::empty);
        let request = builder.body(request_body).unwrap();
        let response = self
            .app
            .clone()
            .oneshot(request)
            .await
            .expect("route response");
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("read route response");
        let value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).expect("JSON route response")
        };
        (status, value)
    }

    fn ws_url(&self) -> String {
        format!("ws://{}/collaboration/v1/connect", self.addr)
    }
}

#[tokio::test]
async fn websocket_origin_tickets_read_only_and_size_limits_are_enforced() {
    let server = TestServer::start().await;
    let host = seed_identity(&server.state, "host", 600).await;
    let observer = seed_identity(&server.state, "observer", 600).await;
    // This member's access session also bounds its observer ticket. The short
    // lifetime lets the test exercise real expiry without sleeping 30 seconds.
    let short_lived_observer = seed_identity(&server.state, "short-observer", 12).await;
    let vault_id = Uuid::new_v4().to_string();
    seed_vault(
        &server.state,
        &vault_id,
        &host,
        &[&observer, &short_lived_observer],
    )
    .await;

    let session_id = Uuid::new_v4().to_string();
    let expires_at =
        (Utc::now() + chrono::Duration::minutes(8)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let create_body = create_body(
        &host,
        &vault_id,
        &session_id,
        &expires_at,
        &[&observer, &short_lived_observer],
    );
    let (status, created) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions"),
            &host,
            Some(create_body),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{created}");
    let host_ticket = created["host_ticket"].as_str().unwrap().to_owned();

    // Missing, incorrect, and duplicate Origin values must fail before the
    // ticket is consumed, so the same ticket remains usable with the exact
    // configured origin.
    for origin in [
        OriginCase::Missing,
        OriginCase::Wrong,
        OriginCase::Duplicate,
    ] {
        let error = connect_with_origin(&server.ws_url(), origin)
            .await
            .expect_err("origin must be rejected before upgrade");
        assert_eq!(
            http_error_status(error),
            axum::http::StatusCode::FORBIDDEN,
            "origin case {origin:?}"
        );
    }

    let mut host_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("exact configured Origin upgrades");
    authenticate(&mut host_socket, &host_ticket, "host", &session_id).await;

    // Replaying the successfully consumed host ticket must be rejected by the
    // real WebSocket handler, while the first host connection remains alive.
    let mut replay_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("replay is rejected after WebSocket upgrade");
    replay_socket
        .send(Message::Text(
            json!({"type":"authenticate","ticket":host_ticket})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    expect_close(&mut replay_socket, 4001, "AUTH_REQUIRED").await;

    // Authenticate an observer, send application data, and require a policy
    // close. A fresh observer ticket must still work, proving the violation
    // does not tear down the host-owned room.
    let observer_ticket = issue_observer_ticket(&server, &vault_id, &session_id, &observer).await;
    let mut observer_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("observer WebSocket upgrades");
    authenticate(
        &mut observer_socket,
        observer_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;
    let denied_lease_id = Uuid::new_v4().to_string();
    let denied_lease_expiry =
        (Utc::now() + chrono::Duration::minutes(2)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let v1_lease_attempt = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &denied_lease_id,
        1,
        &denied_lease_expiry,
    );
    let (v1_lease_status, v1_lease_error) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(v1_lease_attempt),
        )
        .await;
    assert_eq!(
        v1_lease_status,
        axum::http::StatusCode::NOT_FOUND,
        "v1 sessions cannot be upgraded with a v2 lease: {v1_lease_error}"
    );
    expect_pong(&mut host_socket).await;
    expect_pong(&mut observer_socket).await;
    observer_socket
        .send(Message::Text(
            json!({"type":"input","data":"x"}).to_string().into(),
        ))
        .await
        .unwrap();
    expect_close(&mut observer_socket, 1008, "PROTOCOL_ERROR").await;

    let retry_ticket = issue_observer_ticket(&server, &vault_id, &session_id, &observer).await;
    let mut retry_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("observer violation does not end the room");
    authenticate(
        &mut retry_socket,
        retry_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;

    // An observer ticket expires at or before the short login session expiry.
    // Wait for the advertised deadline and verify that the expired credential
    // cannot authenticate, even though the room and host socket remain live.
    let expired_ticket =
        issue_observer_ticket(&server, &vault_id, &session_id, &short_lived_observer).await;
    let deadline =
        chrono::DateTime::parse_from_rfc3339(expired_ticket["ticket_expires_at"].as_str().unwrap())
            .unwrap()
            .to_utc()
            + chrono::Duration::milliseconds(150);
    let remaining = (deadline - Utc::now()).to_std().unwrap_or(Duration::ZERO);
    tokio::time::sleep(remaining).await;
    let mut expired_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("expired tickets are rejected after HTTP upgrade");
    expired_socket
        .send(Message::Text(
            json!({
                "type":"authenticate",
                "ticket":expired_ticket["ticket"].as_str().unwrap()
            })
            .to_string()
            .into(),
        ))
        .await
        .unwrap();
    expect_close(&mut expired_socket, 4001, "AUTH_REQUIRED").await;

    // A single over-limit application message must close the host transport
    // and remove the room. The room's observer socket receives SESSION_ENDED.
    host_socket
        .send(Message::Text("x".repeat(MAX_WS_MESSAGE_BYTES + 1).into()))
        .await
        .expect("client can transmit a message above the server limit");
    wait_for_socket_end(&mut host_socket).await;
    expect_close(&mut retry_socket, 1000, "SESSION_ENDED").await;

    let (status, error) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/ticket"),
            &observer,
            None,
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::NOT_FOUND, "{error}");

    server.stop().await;
}

#[tokio::test]
async fn client_initiated_close_is_echoed_with_its_code_and_reason() {
    let server = TestServer::start().await;
    let mut room = connect_live_room(&server).await;
    let client_close = tokio_tungstenite::tungstenite::protocol::CloseFrame {
        code: 1000.into(),
        reason: "CLIENT_CLOSE_ECHO".into(),
    };

    room.observer_socket
        .send(Message::Close(Some(client_close.clone())))
        .await
        .expect("observer sends a normal close frame");
    expect_close(&mut room.observer_socket, 1000, "CLIENT_CLOSE_ECHO").await;
    expect_pong(&mut room.host_socket).await;

    drop(room);
    server.stop().await;
}

#[tokio::test]
async fn live_websocket_connections_close_and_deny_rejoin_after_revocation() {
    // Principal revocation removes only that participant. Revoking the host
    // or changing Vault membership invalidates the room and closes both peers.
    for (principal, revocation) in [
        (Principal::Observer, Revocation::Session),
        (Principal::Observer, Revocation::Device),
        (Principal::Observer, Revocation::Account),
        (Principal::Host, Revocation::Session),
        (Principal::Host, Revocation::Device),
        (Principal::Host, Revocation::Account),
        (Principal::Observer, Revocation::VaultMembership),
    ] {
        let server = TestServer::start().await;
        let mut room = connect_live_room(&server).await;
        let principal_identity = match principal {
            Principal::Host => &room.host,
            Principal::Observer => &room.observer,
        };
        revoke_live_principal(&server, &room, principal_identity, revocation).await;

        match (principal, revocation) {
            (
                Principal::Observer,
                Revocation::Session | Revocation::Device | Revocation::Account,
            ) => {
                expect_close(&mut room.observer_socket, 4001, "AUTH_REQUIRED").await;
                expect_pong(&mut room.host_socket).await;
            }
            (Principal::Host, Revocation::Session | Revocation::Device | Revocation::Account) => {
                expect_close(&mut room.host_socket, 4001, "AUTH_REQUIRED").await;
                expect_close(&mut room.observer_socket, 1000, "SESSION_ENDED").await;
            }
            (Principal::Observer, Revocation::VaultMembership) => {
                expect_close(&mut room.host_socket, 1000, "SESSION_ENDED").await;
                expect_close(&mut room.observer_socket, 1000, "SESSION_ENDED").await;
            }
            _ => unreachable!("unsupported live revocation case"),
        }

        let (ticket_status, ticket_error) = server
            .post(
                &format!(
                    "/api/v1/vaults/{}/terminal-sessions/{}/ticket",
                    room.vault_id, room.session_id
                ),
                &room.observer,
                None,
            )
            .await;
        let expected_ticket_status = match (principal, revocation) {
            (
                Principal::Observer,
                Revocation::Session | Revocation::Device | Revocation::Account,
            ) => axum::http::StatusCode::UNAUTHORIZED,
            _ => axum::http::StatusCode::NOT_FOUND,
        };
        assert_eq!(
            ticket_status, expected_ticket_status,
            "ticket issuance after {principal:?} {revocation:?}: {ticket_error}"
        );

        // A ticket issued before revocation cannot restore the socket: it is
        // either revalidated against the revoked principal or removed when
        // the room is invalidated.
        let mut rejoin_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
            .await
            .expect("rejoin handshake upgrades before ticket authentication");
        rejoin_socket
            .send(Message::Text(
                json!({"type":"authenticate","ticket":room.rejoin_ticket})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        expect_close(&mut rejoin_socket, 4001, "AUTH_REQUIRED").await;

        drop(room);
        server.stop().await;
    }
}

#[tokio::test]
async fn protocol_v2_controller_lease_authorizes_one_input_socket_and_revokes_live_capabilities() {
    let server = TestServer::start().await;
    let host = seed_identity(&server.state, "v2-host", 600).await;
    let observer = seed_identity(&server.state, "v2-observer", 600).await;
    let other_observer = seed_identity(&server.state, "v2-other-observer", 600).await;
    let stranger = seed_identity(&server.state, "v2-stranger", 600).await;
    let vault_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    seed_vault(
        &server.state,
        &vault_id,
        &host,
        &[&observer, &other_observer],
    )
    .await;
    let session_expires_at =
        (Utc::now() + chrono::Duration::minutes(8)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let mut create = create_body(
        &host,
        &vault_id,
        &session_id,
        &session_expires_at,
        &[&observer, &other_observer],
    );
    create["protocol_version"] = json!(2);
    let (status, created) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions"),
            &host,
            Some(create),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{created}");

    let mut host_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("host WebSocket upgrades");
    authenticate(
        &mut host_socket,
        created["host_ticket"].as_str().unwrap(),
        "host",
        &session_id,
    )
    .await;
    let observer_ticket = issue_observer_ticket(&server, &vault_id, &session_id, &observer).await;
    let mut observer_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("observer WebSocket upgrades");
    authenticate(
        &mut observer_socket,
        observer_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;
    let other_ticket =
        issue_observer_ticket(&server, &vault_id, &session_id, &other_observer).await;
    let mut other_observer_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("second observer WebSocket upgrades");
    authenticate(
        &mut other_observer_socket,
        other_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;

    // A host signature alone cannot grant control to a device outside the
    // observer allowlist or active Vault membership.
    let unauthorized_lease_id = Uuid::new_v4().to_string();
    let unauthorized_expiry =
        (Utc::now() + chrono::Duration::minutes(2)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let unauthorized = controller_lease_body(
        &host,
        &stranger,
        &vault_id,
        &session_id,
        &unauthorized_lease_id,
        1,
        &unauthorized_expiry,
    );
    let (status, error) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(unauthorized),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::FORBIDDEN, "{error}");

    let forged_lease_id = Uuid::new_v4().to_string();
    let forged_expiry =
        (Utc::now() + chrono::Duration::minutes(2)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let mut forged_keybox = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &forged_lease_id,
        1,
        &forged_expiry,
    );
    forged_keybox["keybox"]["sealed_secret"] = json!(URL_SAFE_NO_PAD.encode([0x11; 80]));
    let (status, error) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(forged_keybox),
        )
        .await;
    assert_eq!(
        status,
        axum::http::StatusCode::UNPROCESSABLE_ENTITY,
        "{error}"
    );

    let lease_id = Uuid::new_v4().to_string();
    let lease_expiry =
        (Utc::now() + chrono::Duration::minutes(2)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let grant = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &lease_id,
        1,
        &lease_expiry,
    );
    let (status, lease) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(grant.clone()),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{lease}");
    assert_eq!(
        lease,
        json!({"lease_id":lease_id,"control_epoch":1,"expires_at":lease_expiry})
    );
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_granted","session_id":session_id,"lease_id":lease_id,"control_epoch":1,"expires_at":lease_expiry})
    );
    assert!(
        timeout(
            Duration::from_millis(150),
            next_json(&mut other_observer_socket)
        )
        .await
        .is_err()
    );

    // An identical lost-response retry is idempotent and does not send a
    // duplicate epoch notification. A second, different active lease conflicts.
    let (status, non_host_grant) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &observer,
            Some(grant.clone()),
        )
        .await;
    assert_eq!(
        status,
        axum::http::StatusCode::NOT_FOUND,
        "{non_host_grant}"
    );
    let (status, retry) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(grant),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{retry}");
    assert!(
        timeout(Duration::from_millis(150), next_json(&mut observer_socket))
            .await
            .is_err()
    );
    let different_id = Uuid::new_v4().to_string();
    let different_expiry =
        (Utc::now() + chrono::Duration::minutes(3)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let different = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &different_id,
        2,
        &different_expiry,
    );
    let (status, error) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(different),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::CONFLICT, "{error}");

    let issue_controller_ticket = || async {
        server
            .post(
                &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease/ticket"),
                &observer,
                None,
            )
            .await
    };
    let (status, ticket) = issue_controller_ticket().await;
    assert_eq!(status, axum::http::StatusCode::OK, "{ticket}");
    assert_eq!(ticket["role"], "controller");
    assert_eq!(ticket["lease_id"], lease_id);
    assert_eq!(ticket["control_epoch"], 1);
    assert!(ticket["control_keybox"].is_object());
    assert!(ticket.get("observer_keybox").is_none());
    let (status, other_approved_ticket) = server
        .post(
            &format!(
                "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease/ticket"
            ),
            &other_observer,
            None,
        )
        .await;
    assert_eq!(
        status,
        axum::http::StatusCode::NOT_FOUND,
        "another approved observer cannot take the active controller lease: {other_approved_ticket}"
    );
    let (status, stranger_ticket) = server
        .post(
            &format!(
                "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease/ticket"
            ),
            &stranger,
            None,
        )
        .await;
    assert_eq!(
        status,
        axum::http::StatusCode::NOT_FOUND,
        "{stranger_ticket}"
    );

    let mut controller_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("controller WebSocket upgrades");
    authenticate_controller(
        &mut controller_socket,
        ticket["ticket"].as_str().unwrap(),
        &session_id,
        &lease_id,
        1,
    )
    .await;
    let (status, already_connected) = issue_controller_ticket().await;
    assert_eq!(
        status,
        axum::http::StatusCode::NOT_FOUND,
        "{already_connected}"
    );

    let output = host_output_frame(&host, &observer, &vault_id, &session_id, 1, 1);
    host_socket
        .send(Message::Text(
            json!({"type":"frame","frame":output}).to_string().into(),
        ))
        .await
        .unwrap();
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"frame","frame":output})
    );
    controller_socket
        .send(Message::Ping(Vec::new().into()))
        .await
        .unwrap();
    let controller_pong = timeout(Duration::from_secs(3), controller_socket.next())
        .await
        .expect("controller ping response deadline")
        .expect("controller socket closed before the ping response")
        .expect("read controller ping response");
    assert!(
        matches!(controller_pong, Message::Pong(_)),
        "controller receives no host output: {controller_pong:?}"
    );

    // Input is verified then forwarded opaquely only to the host. Exact replay
    // closes this controller and destroys the lease while preserving output.
    let input = controller_input_frame(&host, &observer, &vault_id, &session_id, &lease_id, 1, 1);
    controller_socket
        .send(Message::Text(
            json!({"type":"input","frame":input}).to_string().into(),
        ))
        .await
        .unwrap();
    assert_eq!(
        next_json(&mut host_socket).await,
        json!({"type":"input","frame":input})
    );
    controller_socket
        .send(Message::Text(
            json!({"type":"input","frame":input}).to_string().into(),
        ))
        .await
        .unwrap();
    expect_close(&mut controller_socket, 1008, "PROTOCOL_ERROR").await;
    assert_eq!(
        next_json(&mut host_socket).await,
        json!({"type":"controller_lease_ended","lease_id":lease_id,"reason":"controller_disconnected"})
    );
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_ended","lease_id":lease_id,"reason":"controller_disconnected"})
    );
    assert!(
        timeout(
            Duration::from_millis(150),
            next_json(&mut other_observer_socket)
        )
        .await
        .is_err()
    );
    expect_pong(&mut host_socket).await;

    observer_socket.close(None).await.unwrap();

    // A fresh lease advances the epoch. Revocation closes its live controller,
    // notifies only the host and exact target observer, and kills a pending
    // second-use ticket before it can rejoin.
    let second_lease_id = Uuid::new_v4().to_string();
    let second_expiry =
        (Utc::now() + chrono::Duration::minutes(2)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let second_grant = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &second_lease_id,
        2,
        &second_expiry,
    );
    let (status, second_lease) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(second_grant),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{second_lease}");
    let observer_ticket = issue_observer_ticket(&server, &vault_id, &session_id, &observer).await;
    let mut observer_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("target observer rejoins after grant");
    authenticate(
        &mut observer_socket,
        observer_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_granted","session_id":session_id,"lease_id":second_lease_id,"control_epoch":2,"expires_at":second_expiry})
    );
    assert!(
        timeout(
            Duration::from_millis(150),
            next_json(&mut other_observer_socket)
        )
        .await
        .is_err()
    );
    let (status, active_ticket) = issue_controller_ticket().await;
    assert_eq!(status, axum::http::StatusCode::OK, "{active_ticket}");
    let (status, pending_ticket) = issue_controller_ticket().await;
    assert_eq!(status, axum::http::StatusCode::OK, "{pending_ticket}");
    let mut second_controller_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("second controller WebSocket upgrades");
    authenticate_controller(
        &mut second_controller_socket,
        active_ticket["ticket"].as_str().unwrap(),
        &session_id,
        &second_lease_id,
        2,
    )
    .await;
    let (status, non_host_revoke) = server
        .request(
            axum::http::Method::DELETE,
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &observer,
            None,
        )
        .await;
    assert_eq!(
        status,
        axum::http::StatusCode::NOT_FOUND,
        "{non_host_revoke}"
    );
    let (status, revoked) = server
        .request(
            axum::http::Method::DELETE,
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            None,
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{revoked}");
    assert_eq!(revoked["status"], "revoked");
    assert_eq!(
        next_json(&mut host_socket).await,
        json!({"type":"controller_lease_ended","lease_id":second_lease_id,"reason":"revoked"})
    );
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_ended","lease_id":second_lease_id,"reason":"revoked"})
    );
    assert!(
        timeout(
            Duration::from_millis(150),
            next_json(&mut other_observer_socket)
        )
        .await
        .is_err()
    );
    expect_close(&mut second_controller_socket, 4003, "CONTROL_REVOKED").await;

    let mut pending_rejoin = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("pending rejoin handshake upgrades");
    pending_rejoin
        .send(Message::Text(
            json!({"type":"authenticate","ticket":pending_ticket["ticket"]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    expect_close(&mut pending_rejoin, 4001, "AUTH_REQUIRED").await;
    let (status, denied_rejoin) = issue_controller_ticket().await;
    assert_eq!(status, axum::http::StatusCode::NOT_FOUND, "{denied_rejoin}");

    let third_lease_id = Uuid::new_v4().to_string();
    let third_expiry = chrono::DateTime::<Utc>::from_timestamp(Utc::now().timestamp() + 3, 0)
        .unwrap()
        .to_rfc3339_opts(SecondsFormat::Secs, true);
    let third_grant = controller_lease_body(
        &host,
        &observer,
        &vault_id,
        &session_id,
        &third_lease_id,
        3,
        &third_expiry,
    );
    let (status, third_lease) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease"),
            &host,
            Some(third_grant),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{third_lease}");
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_granted","session_id":session_id,"lease_id":third_lease_id,"control_epoch":3,"expires_at":third_expiry})
    );
    let (status, expiring_ticket) = issue_controller_ticket().await;
    assert_eq!(status, axum::http::StatusCode::OK, "{expiring_ticket}");
    let (status, pending_expiring_ticket) = issue_controller_ticket().await;
    assert_eq!(
        status,
        axum::http::StatusCode::OK,
        "{pending_expiring_ticket}"
    );
    let mut expiring_controller_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("expiring controller WebSocket upgrades");
    authenticate_controller(
        &mut expiring_controller_socket,
        expiring_ticket["ticket"].as_str().unwrap(),
        &session_id,
        &third_lease_id,
        3,
    )
    .await;
    expect_close(&mut expiring_controller_socket, 4003, "CONTROL_EXPIRED").await;
    assert_eq!(
        next_json(&mut host_socket).await,
        json!({"type":"controller_lease_ended","lease_id":third_lease_id,"reason":"expired"})
    );
    assert_eq!(
        next_json(&mut observer_socket).await,
        json!({"type":"controller_lease_ended","lease_id":third_lease_id,"reason":"expired"})
    );
    let mut expired_rejoin = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("expired ticket rejoin handshake upgrades");
    expired_rejoin
        .send(Message::Text(
            json!({"type":"authenticate","ticket":pending_expiring_ticket["ticket"]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    expect_close(&mut expired_rejoin, 4001, "AUTH_REQUIRED").await;
    assert!(
        timeout(
            Duration::from_millis(150),
            next_json(&mut other_observer_socket)
        )
        .await
        .is_err()
    );
    expect_pong(&mut host_socket).await;
    server.stop().await;
}

#[derive(Clone, Copy, Debug)]
enum Principal {
    Host,
    Observer,
}

#[derive(Clone, Copy, Debug)]
enum Revocation {
    Session,
    Device,
    Account,
    VaultMembership,
}

async fn connect_live_room(server: &TestServer) -> ConnectedRoom {
    let host = seed_identity(&server.state, "live-host", 600).await;
    let observer = seed_identity(&server.state, "live-observer", 600).await;
    let admin = seed_identity_named(
        &server.state,
        "live-admin",
        600,
        "live-admin@example.test".to_owned(),
    )
    .await;
    let vault_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    seed_vault(&server.state, &vault_id, &host, &[&observer]).await;
    let expires_at =
        (Utc::now() + chrono::Duration::minutes(8)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let (status, created) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions"),
            &host,
            Some(create_body(
                &host,
                &vault_id,
                &session_id,
                &expires_at,
                &[&observer],
            )),
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{created}");

    let mut host_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("host WebSocket upgrades");
    authenticate(
        &mut host_socket,
        created["host_ticket"].as_str().unwrap(),
        "host",
        &session_id,
    )
    .await;

    let observer_ticket = issue_observer_ticket(server, &vault_id, &session_id, &observer).await;
    let mut observer_socket = connect_with_origin(&server.ws_url(), OriginCase::Exact)
        .await
        .expect("observer WebSocket upgrades");
    authenticate(
        &mut observer_socket,
        observer_ticket["ticket"].as_str().unwrap(),
        "observer",
        &session_id,
    )
    .await;

    let rejoin_ticket =
        issue_observer_ticket(server, &vault_id, &session_id, &observer).await["ticket"]
            .as_str()
            .unwrap()
            .to_owned();
    ConnectedRoom {
        host,
        observer,
        admin,
        vault_id,
        session_id,
        rejoin_ticket,
        host_socket,
        observer_socket,
    }
}

async fn revoke_live_principal(
    server: &TestServer,
    room: &ConnectedRoom,
    identity: &TestIdentity,
    revocation: Revocation,
) {
    match revocation {
        Revocation::Session => {
            let (status, body) = server.post("/api/v1/auth/logout", identity, None).await;
            assert_eq!(status, axum::http::StatusCode::OK, "{body}");
        }
        Revocation::Device => {
            let (status, body) = server
                .post(
                    &format!("/api/v1/devices/{}/revoke", identity.device_id),
                    identity,
                    None,
                )
                .await;
            assert_eq!(status, axum::http::StatusCode::OK, "{body}");
        }
        Revocation::Account => {
            let (status, body) = server
                .put(
                    &format!("/api/v1/admin/accounts/{}/status", identity.user_id),
                    &room.admin,
                    Some(json!({"status":"disabled"})),
                )
                .await;
            assert_eq!(status, axum::http::StatusCode::OK, "{body}");
        }
        Revocation::VaultMembership => {
            sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
                .bind(&room.vault_id)
                .bind(&identity.user_id)
                .execute(&server.state.db)
                .await
                .unwrap();
            sqlx::query(
                "UPDATE vaults SET membership_version=membership_version+1 WHERE vault_id=?",
            )
            .bind(&room.vault_id)
            .execute(&server.state.db)
            .await
            .unwrap();
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum OriginCase {
    Missing,
    Wrong,
    Duplicate,
    Exact,
}

fn http_error_status(error: tokio_tungstenite::tungstenite::Error) -> axum::http::StatusCode {
    match error {
        tokio_tungstenite::tungstenite::Error::Http(response) => response.status(),
        other => panic!("expected HTTP handshake rejection, got {other:?}"),
    }
}

async fn connect_with_origin(
    url: &str,
    origin: OriginCase,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    tokio_tungstenite::tungstenite::Error,
> {
    let mut request: WsRequest<()> = url.into_client_request().unwrap();
    match origin {
        OriginCase::Missing => {}
        OriginCase::Wrong => {
            request.headers_mut().insert(
                ORIGIN,
                HeaderValue::from_static("https://attacker.example.test"),
            );
        }
        OriginCase::Duplicate => {
            request
                .headers_mut()
                .append(ORIGIN, HeaderValue::from_static(PUBLIC_ORIGIN));
            request
                .headers_mut()
                .append(ORIGIN, HeaderValue::from_static(PUBLIC_ORIGIN));
        }
        OriginCase::Exact => {
            request
                .headers_mut()
                .insert(ORIGIN, HeaderValue::from_static(PUBLIC_ORIGIN));
        }
    }
    connect_async(request).await.map(|(socket, _)| socket)
}

async fn authenticate(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    ticket: &str,
    role: &str,
    session_id: &str,
) {
    socket
        .send(Message::Text(
            json!({"type":"authenticate","ticket":ticket})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let message = timeout(Duration::from_secs(3), socket.next())
        .await
        .expect("authentication acknowledgement deadline")
        .expect("socket closes only on rejection")
        .expect("read authentication acknowledgement");
    let Message::Text(text) = message else {
        panic!("expected authentication acknowledgement, got {message:?}");
    };
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        json!({"type":"authenticated","role":role,"session_id":session_id})
    );
}

async fn authenticate_controller(
    socket: &mut TestWebSocket,
    ticket: &str,
    session_id: &str,
    lease_id: &str,
    control_epoch: i64,
) {
    socket
        .send(Message::Text(
            json!({"type":"authenticate","ticket":ticket})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let message = timeout(Duration::from_secs(3), socket.next())
        .await
        .expect("controller authentication acknowledgement deadline")
        .expect("controller socket closes only on rejection")
        .expect("read controller authentication acknowledgement");
    let Message::Text(text) = message else {
        panic!("expected controller authentication acknowledgement, got {message:?}");
    };
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        json!({
            "type":"authenticated",
            "role":"controller",
            "session_id":session_id,
            "lease_id":lease_id,
            "control_epoch":control_epoch,
        })
    );
}

async fn next_json(socket: &mut TestWebSocket) -> Value {
    let message = timeout(Duration::from_secs(3), socket.next())
        .await
        .expect("WebSocket application message deadline")
        .expect("WebSocket ended before expected application message")
        .expect("read WebSocket application message");
    let Message::Text(text) = message else {
        panic!("expected WebSocket text message, got {message:?}");
    };
    serde_json::from_str(&text).expect("valid JSON WebSocket message")
}

fn controller_lease_body(
    host: &TestIdentity,
    controller: &TestIdentity,
    vault_id: &str,
    session_id: &str,
    lease_id: &str,
    control_epoch: i64,
    expires_at: &str,
) -> Value {
    let unsigned = json!({
        "format":"atermius-terminal-control-keybox-v2",
        "session_id":session_id,
        "vault_id":vault_id,
        "membership_version":5,
        "host_user_id":host.user_id,
        "host_device_id":host.device_id,
        "controller_user_id":controller.user_id,
        "controller_device_id":controller.device_id,
        "lease_id":lease_id,
        "control_epoch":control_epoch,
        "purpose":"input",
        "expires_at":expires_at,
        "sealed_secret":URL_SAFE_NO_PAD.encode([0x6b; 80]),
    });
    let signature = host
        .signing
        .sign(&serde_jcs::to_vec(&unsigned).expect("JCS control keybox payload"));
    let mut keybox = unsigned.as_object().unwrap().clone();
    keybox.insert(
        "signature".to_owned(),
        json!(URL_SAFE_NO_PAD.encode(signature.to_bytes())),
    );
    json!({
        "controller_user_id":controller.user_id,
        "controller_device_id":controller.device_id,
        "lease_id":lease_id,
        "control_epoch":control_epoch,
        "expires_at":expires_at,
        "keybox":keybox,
    })
}

fn controller_input_frame(
    host: &TestIdentity,
    controller: &TestIdentity,
    vault_id: &str,
    session_id: &str,
    lease_id: &str,
    control_epoch: i64,
    sequence: u64,
) -> Value {
    let unsigned = json!({
        "format":"atermius-terminal-input-frame-v2",
        "session_id":session_id,
        "vault_id":vault_id,
        "membership_version":5,
        "host_user_id":host.user_id,
        "host_device_id":host.device_id,
        "controller_user_id":controller.user_id,
        "controller_device_id":controller.device_id,
        "lease_id":lease_id,
        "control_epoch":control_epoch,
        "sequence":sequence,
        "nonce":URL_SAFE_NO_PAD.encode([0x27; 24]),
        "ciphertext":URL_SAFE_NO_PAD.encode([0xa4; 40]),
    });
    let signature = controller
        .signing
        .sign(&serde_jcs::to_vec(&unsigned).expect("JCS terminal input frame"));
    let mut frame = unsigned.as_object().unwrap().clone();
    frame.insert(
        "signature".to_owned(),
        json!(URL_SAFE_NO_PAD.encode(signature.to_bytes())),
    );
    Value::Object(frame)
}

fn host_output_frame(
    host: &TestIdentity,
    observer: &TestIdentity,
    vault_id: &str,
    session_id: &str,
    epoch: i64,
    sequence: u64,
) -> Value {
    let unsigned = json!({
        "format":"atermius-terminal-frame-v1",
        "session_id":session_id,
        "vault_id":vault_id,
        "membership_version":5,
        "host_user_id":host.user_id,
        "host_device_id":host.device_id,
        "recipient_user_id":observer.user_id,
        "recipient_device_id":observer.device_id,
        "role":"observer",
        "epoch":epoch,
        "sequence":sequence,
        "kind":"output",
        "nonce":URL_SAFE_NO_PAD.encode([0x35; 24]),
        "ciphertext":URL_SAFE_NO_PAD.encode([0xc2; 50]),
    });
    let signature = host
        .signing
        .sign(&serde_jcs::to_vec(&unsigned).expect("JCS terminal output frame"));
    let mut frame = unsigned.as_object().unwrap().clone();
    frame.insert(
        "signature".to_owned(),
        json!(URL_SAFE_NO_PAD.encode(signature.to_bytes())),
    );
    Value::Object(frame)
}

async fn expect_close(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    expected_code: u16,
    expected_reason: &str,
) {
    let message = timeout(Duration::from_secs(3), socket.next())
        .await
        .expect("WebSocket close deadline");
    let Some(Ok(Message::Close(Some(frame)))) = message else {
        panic!("expected close frame, got {message:?}");
    };
    assert_eq!(u16::from(frame.code), expected_code);
    assert_eq!(frame.reason, expected_reason);
}

async fn wait_for_socket_end(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) {
    let ended = timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break true,
                _ => {}
            }
        }
    })
    .await
    .expect("oversized frame did not end the host WebSocket");
    assert!(ended);
}

async fn expect_pong(socket: &mut TestWebSocket) {
    socket.send(Message::Ping(Vec::new().into())).await.unwrap();
    let pong = timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Pong(_))) => break true,
                Some(Ok(Message::Close(frame))) => {
                    panic!("host socket unexpectedly closed: {frame:?}")
                }
                None | Some(Err(_)) => panic!("host socket ended while observer was revoked"),
                _ => {}
            }
        }
    })
    .await
    .expect("host socket did not answer ping after observer revocation");
    assert!(pong);
}

async fn issue_observer_ticket(
    server: &TestServer,
    vault_id: &str,
    session_id: &str,
    observer: &TestIdentity,
) -> Value {
    let (status, body) = server
        .post(
            &format!("/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/ticket"),
            observer,
            None,
        )
        .await;
    assert_eq!(status, axum::http::StatusCode::OK, "{body}");
    body
}

fn create_body(
    host: &TestIdentity,
    vault_id: &str,
    session_id: &str,
    expires_at: &str,
    observers: &[&TestIdentity],
) -> Value {
    let grants = observers
        .iter()
        .map(|observer| {
            let unsigned = json!({
                "format":"atermius-terminal-keybox-v1",
                "session_id":session_id,
                "vault_id":vault_id,
                "membership_version":5,
                "host_user_id":host.user_id,
                "host_device_id":host.device_id,
                "observer_user_id":observer.user_id,
                "observer_device_id":observer.device_id,
                "role":"observer",
                "epoch":1,
                "expires_at":expires_at,
                "sealed_secret":URL_SAFE_NO_PAD.encode([0x5a; 80]),
            });
            let signature = host
                .signing
                .sign(&serde_jcs::to_vec(&unsigned).expect("JCS keybox payload"));
            let mut keybox = unsigned.as_object().unwrap().clone();
            keybox.insert(
                "signature".to_owned(),
                json!(URL_SAFE_NO_PAD.encode(signature.to_bytes())),
            );
            json!({
                "user_id":observer.user_id,
                "device_id":observer.device_id,
                "keybox":keybox,
            })
        })
        .collect::<Vec<_>>();
    json!({
        "protocol_version":1,
        "session_id":session_id,
        "expires_at":expires_at,
        "observers":grants,
    })
}

async fn seed_vault(
    state: &AppState,
    vault_id: &str,
    host: &TestIdentity,
    observers: &[&TestIdentity],
) {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO vaults(vault_id,owner_user_id,membership_version,created_at) VALUES(?,?,5,?)",
    )
    .bind(vault_id)
    .bind(&host.user_id)
    .bind(&now)
    .execute(&state.db)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)",
    )
    .bind(vault_id)
    .bind(&host.user_id)
    .bind(&now)
    .execute(&state.db)
    .await
    .unwrap();
    for observer in observers {
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)",
        )
        .bind(vault_id)
        .bind(&observer.user_id)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
    }
}

async fn seed_identity(state: &AppState, label: &str, access_ttl_seconds: i64) -> TestIdentity {
    let username = format!("{label}-{}@example.test", Uuid::new_v4());
    seed_identity_named(state, label, access_ttl_seconds, username).await
}

async fn seed_identity_named(
    state: &AppState,
    label: &str,
    access_ttl_seconds: i64,
    username: String,
) -> TestIdentity {
    let user_id = Uuid::new_v4().to_string();
    let device_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    let access_token = format!("ws-test-{label}-{}", Uuid::new_v4());
    let refresh_token = format!("ws-refresh-{label}-{}", Uuid::new_v4());
    let signing = SigningKey::from_bytes(&[label.as_bytes()[0]; 32]);
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let created_at = now.to_rfc3339_opts(SecondsFormat::Millis, true);
    let access_expires_at = (now + chrono::Duration::seconds(access_ttl_seconds))
        .to_rfc3339_opts(SecondsFormat::Millis, true);
    let refresh_expires_at =
        (now + chrono::Duration::days(30)).to_rfc3339_opts(SecondsFormat::Millis, true);
    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
        .bind(&user_id)
        .bind(username)
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
        .bind(&device_id)
        .bind(&user_id)
        .bind(label)
        .bind(URL_SAFE_NO_PAD.encode(signing.verifying_key().to_bytes()))
        .bind(URL_SAFE_NO_PAD.encode([0x31; 32]))
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(hex::encode(Sha256::digest(access_token.as_bytes())))
        .bind(hex::encode(Sha256::digest(refresh_token.as_bytes())))
        .bind(access_expires_at)
        .bind(refresh_expires_at)
        .bind(now_text)
        .execute(&state.db)
        .await
        .unwrap();
    TestIdentity {
        user_id,
        device_id,
        access_token,
        signing,
    }
}
