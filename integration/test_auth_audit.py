"""Black-box tests for privacy-safe login audit outcomes."""

from __future__ import annotations

import sqlite3
import uuid
from pathlib import Path

from conftest import ApiClient
from test_account_deletion import _db_path, _register_account


def _login(api: ApiClient, username: str, verifier: str, device_id: str):
    return api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": username,
            "login_verifier": verifier,
            "device_id": device_id,
        },
    )


def _auth_error_identity(response) -> tuple[int, str | None, str | None, object]:
    body = response.json() or {}
    error = body.get("error") or {}
    # request_id is deliberately excluded because it is fresh for every response.
    return response.status, error.get("code"), error.get("message"), error.get("details")


def test_login_audit_is_attributed_without_persisting_unverified_identifiers(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Unknown/non-active login inputs stay indistinguishable and leave no audit row."""
    assert account.get("account_id"), "the suite-owned bootstrap account must be available"
    database = _db_path(api)
    active = _register_account(
        api,
        f"auth-audit-active-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "auth-audit-active",
    )
    inactive = _register_account(
        api,
        f"auth-audit-inactive-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "auth-audit-inactive",
    )
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE users SET status='deleting' WHERE user_id=?",
            (inactive["account_id"],),
        )
        login_event_count_before = connection.execute(
            "SELECT COUNT(*) FROM audit_events WHERE action IN ('auth.login_succeeded','auth.login_failed')"
        ).fetchone()[0]

    success = _login(
        api,
        active["username"],
        active["login_verifier"],
        active["device_id"],
    )
    assert success.status == 200, "valid credentials must still create a session"

    wrong_verifier = _login(
        api,
        active["username"],
        "A" * 43,
        active["device_id"],
    )
    assert wrong_verifier.status == 401
    assert _auth_error_identity(wrong_verifier)[1] == "AUTH_REQUIRED"

    with sqlite3.connect(database) as connection:
        attributable_count = connection.execute(
            "SELECT COUNT(*) FROM audit_events WHERE action IN ('auth.login_succeeded','auth.login_failed')"
        ).fetchone()[0]
    assert attributable_count == login_event_count_before + 2, (
        "valid and known-account failed logins should both be audited"
    )

    unknown_username = f"auth-audit-missing-{uuid.uuid4().hex[:10]}@example.test"
    unknown_verifier = "B" * 43
    unknown = _login(api, unknown_username, unknown_verifier, str(uuid.uuid4()))
    non_active = _login(
        api,
        inactive["username"],
        inactive["login_verifier"],
        inactive["device_id"],
    )
    assert _auth_error_identity(unknown) == _auth_error_identity(non_active)
    assert _auth_error_identity(unknown)[1] == "AUTH_REQUIRED"

    with sqlite3.connect(database) as connection:
        after_unattributable_count = connection.execute(
            "SELECT COUNT(*) FROM audit_events WHERE action IN ('auth.login_succeeded','auth.login_failed')"
        ).fetchone()[0]
    assert after_unattributable_count == attributable_count, (
        "unknown and non-active attempts must not create attributable audit rows"
    )

    audit_page = api.request("GET", "/api/v1/audit?limit=200", token=success.json()["access_token"])
    assert audit_page.status == 200, "authenticated account should read its own audit scope"
    events = [
        event
        for event in audit_page.json()["events"]
        if event["action"] in {"auth.login_succeeded", "auth.login_failed"}
    ]
    assert len(events) == 2
    success_event = next(event for event in events if event["action"] == "auth.login_succeeded")
    failure_event = next(event for event in events if event["action"] == "auth.login_failed")
    assert success_event["result"] == "success"
    assert success_event["scope"] == "account"
    assert success_event["actor_user_id"] == active["account_id"]
    assert success_event["actor_device_id"] == active["device_id"]
    assert failure_event["result"] == "failure"
    assert failure_event["scope"] == "account"
    assert failure_event["actor_user_id"] is None
    assert failure_event["actor_device_id"] is None
    assert failure_event["resource_id"] is None
    assert failure_event["source"] == "api"

    # Audit storage has only fixed metadata columns; check the attempted
    # identifiers and verifier are not present in those rows.
    with sqlite3.connect(database) as connection:
        rows = connection.execute(
            "SELECT scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source "
            "FROM audit_events"
        ).fetchall()
    audit_text = " ".join(str(value) for row in rows for value in row)
    for sensitive_input in (
        active["username"],
        inactive["username"],
        unknown_username,
        active["login_verifier"],
        inactive["login_verifier"],
        unknown_verifier,
    ):
        assert sensitive_input not in audit_text
