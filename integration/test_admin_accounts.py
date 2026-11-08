"""Black-box acceptance for instance-admin account and session controls."""

from __future__ import annotations

import hashlib
import sqlite3
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from test_account_deletion import _db_path, _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _login(api, account: dict) -> dict:
    response = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )
    assert response.status == 200
    return response.json()


def _session_id_for_access_token(db_path, access_token: str) -> str:
    digest = hashlib.sha256(access_token.encode()).hexdigest()
    with sqlite3.connect(db_path) as connection:
        row = connection.execute(
            "SELECT session_id FROM sessions WHERE access_hash=?", (digest,)
        ).fetchone()
    assert row is not None
    return row[0]


def test_instance_admin_account_and_session_controls_are_scoped_and_audited(
    api, account, tmp_path
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin account acceptance needs the suite-owned disposable server")

    target = _register_account(
        api,
        f"admin-account-target-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "admin-account-target",
    )
    refreshed = api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": target["refresh_token"]},
    )
    assert refreshed.status == 200
    refreshed_session = refreshed.json()
    assert set(refreshed_session) == {
        "account_id",
        "device_id",
        "access_token",
        "expires_in",
        "refresh_token",
    }
    assert refreshed_session["account_id"] == target["account_id"]
    assert refreshed_session["device_id"] == target["device_id"]
    assert refreshed_session["expires_in"] > 0
    target.update(refreshed_session)
    db_path = _db_path(api)
    no_auth = api.request("GET", "/api/v1/admin/accounts")
    assert no_auth.status == 401
    no_auth_write = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        json_body={"status": "disabled"},
    )
    assert no_auth_write.status == 401

    denied = api.request("GET", "/api/v1/admin/accounts", token=target["access_token"])
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"
    denied_mutation = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=target["access_token"],
        json_body={"status": "disabled"},
    )
    assert denied_mutation.status == 403

    page = api.request(
        "GET",
        "/api/v1/admin/accounts?limit=1&offset=0",
        token=account["access_token"],
    )
    assert page.status == 200
    assert page.json()["limit"] == 1
    assert page.json()["offset"] == 0
    assert page.json()["total"] >= 2
    assert len(page.json()["accounts"]) == 1

    inventory = api.request(
        "GET", "/api/v1/admin/accounts?limit=100", token=account["access_token"]
    )
    assert inventory.status == 200
    listed = next(
        item for item in inventory.json()["accounts"] if item["user_id"] == target["account_id"]
    )
    assert set(listed) == {
        "user_id",
        "username",
        "status",
        "created_at",
        "active_device_count",
        "active_session_count",
    }
    assert listed["username"] == target["username"]
    assert listed["status"] == "active"
    assert listed["active_device_count"] == 1
    assert listed["active_session_count"] == 1
    serialized = str(inventory.json()).lower()
    for secret_field in (
        "login_verifier",
        "account_key_envelope",
        "access_hash",
        "refresh_hash",
        "signing_public_key",
        "ciphertext",
        "vault_id",
    ):
        assert secret_field not in serialized

    sessions = api.request(
        "GET",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions?limit=100",
        token=account["access_token"],
    )
    assert sessions.status == 200
    session_page = sessions.json()
    assert set(session_page) == {"sessions", "total", "limit", "offset"}
    assert session_page["total"] == 1
    session_row = session_page["sessions"][0]
    assert set(session_row) == {
        "session_id",
        "device_id",
        "device_name",
        "created_at",
        "access_expires_at",
        "refresh_expires_at",
        "revoked_at",
        "active",
    }
    assert session_row["device_id"] == target["device_id"]
    assert session_row["active"] is True
    assert session_row["revoked_at"] is None
    assert "hash" not in str(session_row).lower()

    # The new session listing supports precise revocation; revoking one login
    # does not disable the account or affect another session on the same device.
    second_login = _login(api, target)
    second_session_id = _session_id_for_access_token(db_path, second_login["access_token"])
    revoked_one = api.request(
        "POST",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions/{second_session_id}/revoke",
        token=account["access_token"],
    )
    assert revoked_one.status == 200
    assert revoked_one.json() == {
        "account_id": target["account_id"],
        "session_id": second_session_id,
        "revoked": True,
        "changed": True,
        "updated_at": revoked_one.json()["updated_at"],
    }
    assert api.request("GET", "/api/v1/me", token=second_login["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": second_login["refresh_token"]},
    ).status == 401
    assert api.request("GET", "/api/v1/me", token=target["access_token"]).status == 200
    repeated_one = api.request(
        "POST",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions/{second_session_id}/revoke",
        token=account["access_token"],
    )
    assert repeated_one.status == 200
    assert repeated_one.json()["changed"] is False

    revoked_all = api.request(
        "POST",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions/revoke",
        token=account["access_token"],
    )
    assert revoked_all.status == 200
    assert revoked_all.json()["revoked_sessions"] == 1
    repeated_all = api.request(
        "POST",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions/revoke",
        token=account["access_token"],
    )
    assert repeated_all.status == 200
    assert repeated_all.json()["revoked_sessions"] == 0
    assert api.request("GET", "/api/v1/me", token=target["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": target["refresh_token"]},
    ).status == 401

    fresh_login = _login(api, target)
    disable_path = f"/api/v1/admin/accounts/{target['account_id']}/status"
    disable_body = {"status": "disabled"}
    rollback_session_id = _session_id_for_access_token(db_path, fresh_login["access_token"])
    access_hash = hashlib.sha256(fresh_login["access_token"].encode()).hexdigest()
    refresh_hash = hashlib.sha256(fresh_login["refresh_token"].encode()).hexdigest()
    with sqlite3.connect(db_path) as connection:
        initial_status = connection.execute(
            "SELECT status FROM users WHERE user_id=?", (target["account_id"],)
        ).fetchone()
        assert initial_status == ("active",)
        initial_session = connection.execute(
            "SELECT revoked_at,access_hash,refresh_hash FROM sessions WHERE session_id=?",
            (rollback_session_id,),
        ).fetchone()
        assert initial_session == (None, access_hash, refresh_hash)
        initial_disable_audits = connection.execute(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.account_disabled'"
        ).fetchone()[0]
        connection.execute(
            "CREATE TRIGGER reject_admin_account_disabled_audit "
            "BEFORE INSERT ON audit_events WHEN NEW.action='admin.account_disabled' "
            "BEGIN SELECT RAISE(ABORT,'injected admin disable audit failure'); END"
        )

    try:
        audit_failure = api.request(
            "PUT",
            disable_path,
            token=account["access_token"],
            json_body=disable_body,
        )
        assert audit_failure.status == 500
        assert _error_code(audit_failure) == "INTERNAL"

        with sqlite3.connect(db_path) as connection:
            status_after_failure = connection.execute(
                "SELECT status FROM users WHERE user_id=?", (target["account_id"],)
            ).fetchone()
            session_after_failure = connection.execute(
                "SELECT revoked_at,access_hash,refresh_hash FROM sessions WHERE session_id=?",
                (rollback_session_id,),
            ).fetchone()
            disable_audits_after_failure = connection.execute(
                "SELECT COUNT(*) FROM audit_events WHERE action='admin.account_disabled'"
            ).fetchone()[0]
        assert status_after_failure == ("active",)
        assert session_after_failure == (None, access_hash, refresh_hash)
        assert disable_audits_after_failure == initial_disable_audits
        assert api.request("GET", "/api/v1/me", token=fresh_login["access_token"]).status == 200
    finally:
        with sqlite3.connect(db_path) as connection:
            connection.execute("DROP TRIGGER IF EXISTS reject_admin_account_disabled_audit")

    # Retry the exact same administrator request after removing the injected
    # audit failure; this also proves the preceding failure came from the
    # targeted audit insert rather than an invalid request fixture.
    disabled = api.request(
        "PUT",
        disable_path,
        token=account["access_token"],
        json_body=disable_body,
    )
    assert disabled.status == 200
    assert disabled.json()["status"] == "disabled"
    assert disabled.json()["changed"] is True
    assert disabled.json()["revoked_sessions"] == 1
    assert api.request("GET", "/api/v1/me", token=fresh_login["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": fresh_login["refresh_token"]},
    ).status == 401
    assert api.request("POST", "/api/v1/auth/login", json_body={
        "username": target["username"],
        "login_verifier": target["login_verifier"],
        "device_id": target["device_id"],
    }).status == 401
    with sqlite3.connect(db_path) as connection:
        device_status = connection.execute(
            "SELECT status FROM devices WHERE device_id=?", (target["device_id"],)
        ).fetchone()[0]
    assert device_status == "active", "disable blocks server sessions without revoking trusted devices"

    disabled_inventory = api.request(
        "GET", "/api/v1/admin/accounts?limit=100", token=account["access_token"]
    )
    disabled_row = next(
        item
        for item in disabled_inventory.json()["accounts"]
        if item["user_id"] == target["account_id"]
    )
    assert disabled_row["status"] == "disabled"
    assert disabled_row["active_device_count"] == 1
    assert disabled_row["active_session_count"] == 0

    enabled = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "active"},
    )
    assert enabled.status == 200
    assert enabled.json()["status"] == "active"
    assert enabled.json()["changed"] is True
    assert enabled.json()["revoked_sessions"] == 0
    repeated_enable = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "active"},
    )
    assert repeated_enable.status == 200
    assert repeated_enable.json()["changed"] is False
    assert api.request("GET", "/api/v1/me", token=fresh_login["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": fresh_login["refresh_token"]},
    ).status == 401
    reauthenticated = _login(api, target)
    assert api.request("GET", "/api/v1/me", token=reauthenticated["access_token"]).status == 200

    # Login and disable share the account writer lock. Whichever request wins,
    # no unrevoked login session may remain after the disable response commits.
    with ThreadPoolExecutor(max_workers=2) as pool:
        concurrent_login_future = pool.submit(
            api.request,
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": target["username"],
                "login_verifier": target["login_verifier"],
                "device_id": target["device_id"],
            },
        )
        concurrent_disable_future = pool.submit(
            api.request,
            "PUT",
            f"/api/v1/admin/accounts/{target['account_id']}/status",
            token=account["access_token"],
            json_body={"status": "disabled"},
        )
        concurrent_login = concurrent_login_future.result(timeout=20)
        concurrent_disable = concurrent_disable_future.result(timeout=20)
    assert concurrent_login.status in (200, 401)
    assert concurrent_disable.status == 200
    assert concurrent_disable.json()["status"] == "disabled"
    assert api.request("GET", "/api/v1/me", token=reauthenticated["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": reauthenticated["refresh_token"]},
    ).status == 401
    if concurrent_login.status == 200:
        assert api.request(
            "GET", "/api/v1/me", token=concurrent_login.json()["access_token"]
        ).status == 401
        assert api.request(
            "POST",
            "/api/v1/auth/refresh",
            json_body={"refresh_token": concurrent_login.json()["refresh_token"]},
        ).status == 401

    reenabled_for_refresh_race = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "active"},
    )
    assert reenabled_for_refresh_race.status == 200
    refresh_source = _login(api, target)
    with ThreadPoolExecutor(max_workers=2) as pool:
        concurrent_refresh_future = pool.submit(
            api.request,
            "POST",
            "/api/v1/auth/refresh",
            json_body={"refresh_token": refresh_source["refresh_token"]},
        )
        refresh_race_disable_future = pool.submit(
            api.request,
            "PUT",
            f"/api/v1/admin/accounts/{target['account_id']}/status",
            token=account["access_token"],
            json_body={"status": "disabled"},
        )
        concurrent_refresh = concurrent_refresh_future.result(timeout=20)
        refresh_race_disable = refresh_race_disable_future.result(timeout=20)
    assert concurrent_refresh.status in (200, 401)
    assert refresh_race_disable.status == 200
    assert refresh_race_disable.json()["status"] == "disabled"
    assert api.request("GET", "/api/v1/me", token=refresh_source["access_token"]).status == 401
    assert api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": refresh_source["refresh_token"]},
    ).status == 401
    if concurrent_refresh.status == 200:
        assert api.request(
            "GET", "/api/v1/me", token=concurrent_refresh.json()["access_token"]
        ).status == 401
        assert api.request(
            "POST",
            "/api/v1/auth/refresh",
            json_body={"refresh_token": concurrent_refresh.json()["refresh_token"]},
        ).status == 401

    for method, path, body in (
        ("POST", f"/api/v1/admin/accounts/{account['account_id']}/sessions/revoke", None),
        ("PUT", f"/api/v1/admin/accounts/{account['account_id']}/status", {"status": "disabled"}),
    ):
        response = api.request(
            method,
            path,
            token=account["access_token"],
            json_body=body,
        )
        assert response.status == 409
        assert _error_code(response) == "ADMIN_SELF_TARGET"

    with sqlite3.connect(db_path) as connection:
        connection.execute("UPDATE users SET status='deleting' WHERE user_id=?", (target["account_id"],))
    cannot_enable_deleting = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "active"},
    )
    assert cannot_enable_deleting.status == 409
    assert _error_code(cannot_enable_deleting) == "ACCOUNT_DELETING"
    cannot_revoke_deleting = api.request(
        "POST",
        f"/api/v1/admin/accounts/{target['account_id']}/sessions/revoke",
        token=account["access_token"],
    )
    assert cannot_revoke_deleting.status == 409
    assert _error_code(cannot_revoke_deleting) == "ACCOUNT_DELETING"

    invalid_status = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "suspended"},
    )
    assert invalid_status.status == 400
    assert _error_code(invalid_status) == "INVALID_ACCOUNT_STATUS"
    extra_status_field = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{target['account_id']}/status",
        token=account["access_token"],
        json_body={"status": "disabled", "reason": "not accepted"},
    )
    assert extra_status_field.status == 400
    assert _error_code(extra_status_field) == "INVALID_ACCOUNT_STATUS"
    invalid_page = api.request(
        "GET", "/api/v1/admin/accounts?limit=101", token=account["access_token"]
    )
    assert invalid_page.status == 400
    assert _error_code(invalid_page) == "INVALID_LIMIT"
    invalid_user_id = api.request(
        "PUT",
        "/api/v1/admin/accounts/not-an-account/status",
        token=account["access_token"],
        json_body={"status": "disabled"},
    )
    assert invalid_user_id.status == 400
    missing = api.request(
        "PUT",
        f"/api/v1/admin/accounts/{uuid.uuid4()}/status",
        token=account["access_token"],
        json_body={"status": "disabled"},
    )
    assert missing.status == 404

    with sqlite3.connect(db_path) as connection:
        audit_rows = connection.execute(
            "SELECT actor_user_id,actor_device_id,action,resource_type,resource_id,source "
            "FROM audit_events WHERE action IN ('admin.account_disabled','admin.account_enabled',"
            "'admin.account_session_revoked','admin.account_sessions_revoked') ORDER BY event_id"
        ).fetchall()
    actions = [row[2] for row in audit_rows]
    assert actions.count("admin.account_disabled") == 3
    assert actions.count("admin.account_enabled") == 2
    assert actions.count("admin.account_session_revoked") == 1
    assert actions.count("admin.account_sessions_revoked") == 1
    assert all(row[:2] == (account["account_id"], account["device_id"]) for row in audit_rows)
    assert all(row[3] == "account" and row[5] == "api" for row in audit_rows)
    assert all(row[4] != target["account_id"] and len(row[4]) == 64 for row in audit_rows)
