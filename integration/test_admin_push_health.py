"""Black-box checks for privacy-safe aggregate mobile push health snapshots."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import sqlite3
import time
import urllib.parse
import uuid

import pytest

from test_account_deletion import _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _database_path(api) -> str:
    database_url = (api.admin_env or {}).get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://")
    return urllib.parse.unquote(database_url[len("sqlite://") :].split("?", 1)[0])


def _insert_endpoint(database, user_id: str, device_id: str, provider: str, marker: str):
    endpoint_id = str(uuid.uuid4())
    token_hash = hashlib.sha256(("push-health-token-" + marker).encode()).hexdigest()
    token_envelope = "npe1:" + ("opaque-envelope-" + marker).ljust(96, "x")
    database.execute(
        "INSERT INTO notification_push_endpoints "
        "(endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (endpoint_id, device_id, user_id, provider, token_hash, token_envelope, int(time.time()), int(time.time())),
    )
    return endpoint_id, token_hash, token_envelope


def _insert_outbox(database, endpoint_id: str, marker: str, *, state: str, now: int):
    requested = 2 if state == "complete" else 1
    delivered = 2 if state == "complete" else 0
    next_attempt = now + 600 if state == "retry" else now - 10
    lease_id = None
    lease_until = None
    dead_lettered = 0
    if state == "leased":
        lease_id, lease_until = "lease-" + marker, now + 600
    elif state == "expired_lease":
        lease_id, lease_until = "lease-" + marker, now - 10
    elif state == "dead":
        dead_lettered = 1
    database.execute(
        "INSERT INTO notification_push_outbox "
        "(endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at,lease_id,lease_until,dead_lettered,updated_at) "
        "VALUES (?,?,?,0,?,?,?,?,?)",
        (endpoint_id, requested, delivered, next_attempt, lease_id, lease_until, dead_lettered, now),
    )


def _push_row_fingerprint(database) -> str:
    rows = {
        "endpoints": database.execute(
            "SELECT * FROM notification_push_endpoints ORDER BY endpoint_id"
        ).fetchall(),
        "outbox": database.execute(
            "SELECT * FROM notification_push_outbox ORDER BY endpoint_id"
        ).fetchall(),
        "delivery_daily": database.execute(
            "SELECT * FROM notification_push_delivery_daily ORDER BY provider,outcome,day_start"
        ).fetchall(),
    }
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def test_admin_push_health_requires_admin_and_returns_exact_safe_sqlite_snapshot(
    api, account, tmp_path
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("push health acceptance needs the suite-owned disposable SQLite server")
    provider_environment = (
        "ATERMIUS_FCM_SERVICE_ACCOUNT_FILE",
        "ATERMIUS_APNS_PRIVATE_KEY_FILE",
        "ATERMIUS_APNS_TEAM_ID",
        "ATERMIUS_APNS_KEY_ID",
        "ATERMIUS_APNS_TOPIC",
        "ATERMIUS_APNS_USE_SANDBOX",
    )
    if any(api.admin_env.get(name) for name in provider_environment):
        pytest.skip("push health no-adapter assertion requires provider credentials to be absent")

    outsider = _register_account(
        api,
        f"push-health-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "push-health-outsider",
    )
    missing = api.request("GET", "/api/v1/admin/push-health")
    denied = api.request(
        "GET", "/api/v1/admin/push-health", token=outsider["access_token"]
    )
    assert missing.status == 401 and _error_code(missing) == "AUTH_REQUIRED"
    assert denied.status == 403 and _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"

    database_path = _database_path(api)
    now = int(time.time())
    private_values: list[str] = []
    with sqlite3.connect(database_path, timeout=5) as database:
        def add_device(user_id: str, marker: str) -> str:
            device_id = str(uuid.uuid4())
            database.execute(
                "INSERT INTO devices(device_id,user_id,name,signing_public_key,"
                "encryption_public_key,created_at) VALUES (?,?,?,?,?,?)",
                (device_id, user_id, "push-health-" + marker, "sign-" + marker, "encrypt-" + marker, str(now)),
            )
            private_values.extend([device_id, "sign-" + marker, "encrypt-" + marker])
            return device_id

        def add(provider: str, marker: str, state: str | None = None, *, user_id=None, device_id=None):
            selected_user = user_id or account["account_id"]
            selected_device = device_id or add_device(selected_user, marker)
            endpoint_id, token_hash, token_envelope = _insert_endpoint(
                database, selected_user, selected_device, provider, marker
            )
            private_values.extend([endpoint_id, token_hash, token_envelope])
            if state is not None:
                _insert_outbox(database, endpoint_id, marker, state=state, now=now)

        # Reuse the account's active device for one provider; other rows get
        # independent devices because registrations are unique per device/provider.
        add("apns", "due", "due", device_id=account["device_id"])
        add("apns", "expired", "expired_lease")
        add("apns", "leased", "leased")
        add("apns", "retry", "retry")
        add("apns", "dead", "dead")
        add("apns", "complete", "complete")
        add("apns", "registered-only")
        disabled_user = str(uuid.uuid4())
        disabled_device = str(uuid.uuid4())
        disabled_marker = "disabled-account-due-private-marker"
        database.execute(
            "INSERT INTO users(user_id,username,status,created_at) VALUES (?,?, 'disabled',?)",
            (disabled_user, f"{disabled_user}@example.test", str(now)),
        )
        database.execute(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,"
            "encryption_public_key,created_at) VALUES (?,?,?,?,?,?)",
            (disabled_device, disabled_user, "disabled-device", "disabled-sign", "disabled-encrypt", str(now)),
        )
        private_values.extend([disabled_user, disabled_device, disabled_marker])
        add("apns", disabled_marker, "due", user_id=disabled_user, device_id=disabled_device)
        inactive_device = str(uuid.uuid4())
        database.execute(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,"
            "encryption_public_key,status,created_at) VALUES (?,?,?,?,?,'revoked',?)",
            (inactive_device, account["account_id"], "inactive-device", "inactive-sign", "inactive-encrypt", str(now)),
        )
        private_values.extend([inactive_device, "inactive-sign", "inactive-encrypt"])
        add("apns", "inactive-device-due-private", "due", device_id=inactive_device)

        add("fcm_v1", "fcm-due", "due", device_id=account["device_id"])
        add("fcm_v1", "fcm-registered-only")
        today_start = now // 86400 * 86400
        database.executemany(
            "INSERT INTO notification_push_delivery_daily(provider,outcome,day_start,count) VALUES (?,?,?,?)",
            [
                ("apns", "accepted", today_start, 5),
                ("apns", "accepted", today_start - 6 * 86400, 3),
                ("apns", "invalid_token", today_start, 1),
                ("apns", "retryable_failure", today_start, 2),
                ("apns", "accepted", today_start - 7 * 86400, 99),
                ("fcm_v1", "retryable_failure", today_start, 4),
            ],
        )

        before = database.execute(
            "SELECT (SELECT COUNT(*) FROM notification_push_endpoints), "
            "(SELECT COUNT(*) FROM notification_push_outbox), "
            "(SELECT COUNT(*) FROM notification_push_delivery_daily)"
        ).fetchone()
        before_fingerprint = _push_row_fingerprint(database)

    response = api.request(
        "GET", "/api/v1/admin/push-health", token=account["access_token"]
    )
    assert response.status == 200, response.body.decode("utf-8", errors="replace")
    body = response.json()
    assert isinstance(body, dict) and set(body) == {"generated_at", "delivery_window", "providers"}
    generated_at = datetime.fromisoformat(body["generated_at"].replace("Z", "+00:00"))
    assert generated_at.tzinfo == timezone.utc
    assert [item.get("provider") for item in body["providers"]] == ["apns", "fcm_v1"]
    assert body["delivery_window"]["days"] == 7
    assert body["delivery_window"]["start_date_utc"] == datetime.fromtimestamp(
        now // 86400 * 86400 - 6 * 86400, tz=timezone.utc
    ).date().isoformat()
    assert body["delivery_window"]["end_date_utc"] == datetime.fromtimestamp(
        now // 86400 * 86400, tz=timezone.utc
    ).date().isoformat()
    assert len(body["providers"]) == 2
    expected_fields = {
        "provider",
        "configured",
        "registered_endpoints",
        "due",
        "retry_waiting",
        "leased",
        "dead_lettered",
        "delivery_results",
    }
    for item in body["providers"]:
        assert set(item) == expected_fields
        assert item["configured"] is False
        assert all(
            type(item[key]) is int and item[key] >= 0
            for key in expected_fields - {"provider", "configured", "delivery_results"}
        )
        assert set(item["delivery_results"]) == {"accepted", "invalid_token", "retryable_failure"}
        assert all(type(value) is int and value >= 0 for value in item["delivery_results"].values())
    apns, fcm = body["providers"]
    assert {key: apns[key] for key in expected_fields - {"provider", "configured"}} == {
        "registered_endpoints": 9,
        "due": 4,
        "retry_waiting": 1,
        "leased": 1,
        "dead_lettered": 1,
        "delivery_results": {"accepted": 8, "invalid_token": 1, "retryable_failure": 2},
    }
    assert {key: fcm[key] for key in expected_fields - {"provider", "configured"}} == {
        "registered_endpoints": 2,
        "due": 1,
        "retry_waiting": 0,
        "leased": 0,
        "dead_lettered": 0,
        "delivery_results": {"accepted": 0, "invalid_token": 0, "retryable_failure": 4},
    }

    serialized = json.dumps(body, sort_keys=True)
    for private_value in private_values:
        assert private_value not in serialized
    for private_field in ("endpoint_id", "device_id", "token_hash", "token_envelope", "token_value", "payload", "project_id", "provider_error", "body"):
        assert private_field not in serialized

    with sqlite3.connect(database_path, timeout=5) as database:
        after = database.execute(
            "SELECT (SELECT COUNT(*) FROM notification_push_endpoints), "
            "(SELECT COUNT(*) FROM notification_push_outbox), "
            "(SELECT COUNT(*) FROM notification_push_delivery_daily)"
        ).fetchone()
        after_fingerprint = _push_row_fingerprint(database)
        database_now = database.execute(
            "SELECT CAST(strftime('%s','now') AS INTEGER)"
        ).fetchone()[0]
    assert after == before, "push-health GET must not change endpoint or queue rows"
    assert after_fingerprint == before_fingerprint, "push-health GET changed stored row contents"
    assert abs(int(generated_at.timestamp()) - database_now) <= 3
