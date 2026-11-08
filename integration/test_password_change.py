"""Black-box coverage for verifier rotation and response-loss recovery."""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from conftest import ApiClient, b64url
from test_account_deletion import _db_path, _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _login(api: ApiClient, account: dict, verifier: str):
    return api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": verifier,
            "device_id": account["device_id"],
        },
    )


def test_password_change_reauth_atomicity_session_revocation_and_retry(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Password changes rotate credentials atomically and keep one retry safe."""
    assert account.get("account_id"), "the suite-owned bootstrap account must be available"
    database = _db_path(api)
    user = _register_account(
        api,
        f"password-change-{uuid.uuid4().hex[:12]}@example.test",
        tmp_path,
        "password-change",
    )
    second_session = _login(api, user, user["login_verifier"])
    assert second_session.status == 200, f"second login failed: {_error_code(second_session)}"

    me_before = api.request("GET", "/api/v1/me", token=user["access_token"])
    assert me_before.status == 200
    envelope_before = me_before.json()["account_key_envelope"]
    version_before = me_before.json()["account_key_envelope_version"]

    new_verifier = b64url(os.urandom(32))
    new_kdf = {
        "id": "argon2id13",
        "salt": b64url(os.urandom(16)),
        "mem_kib": 65536,
        "iterations": 3,
        "parallelism": 1,
        "version": 1,
    }
    new_envelope = {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(48)),
    }
    request = {
        "operation_id": str(uuid.uuid4()),
        "current_login_verifier": user["login_verifier"],
        "new_kdf": new_kdf,
        "new_login_verifier": new_verifier,
        "account_key_envelope": new_envelope,
    }

    wrong_proof_request = {**request, "current_login_verifier": b64url(os.urandom(32))}
    wrong_proof = api.request(
        "POST",
        "/api/v1/auth/password-change",
        token=user["access_token"],
        json_body=wrong_proof_request,
    )
    assert wrong_proof.status == 401
    assert _error_code(wrong_proof) == "REAUTH_REQUIRED"
    me_after_wrong_proof = api.request("GET", "/api/v1/me", token=user["access_token"])
    assert me_after_wrong_proof.status == 200
    assert me_after_wrong_proof.json()["account_key_envelope"] == envelope_before
    assert me_after_wrong_proof.json()["account_key_envelope_version"] == version_before
    failure_audit = api.request(
        "GET", "/api/v1/audit?limit=200", token=user["access_token"]
    )
    assert failure_audit.status == 200
    failed_changes = [
        event
        for event in failure_audit.json()["events"]
        if event["action"] == "auth.password_change_failed"
    ]
    assert len(failed_changes) == 1
    assert failed_changes[0]["result"] == "failure"
    assert failed_changes[0]["scope"] == "account"
    assert failed_changes[0]["actor_user_id"] == user["account_id"]
    assert failed_changes[0]["actor_device_id"] == user["device_id"]
    assert failed_changes[0]["resource_type"] == "account"
    assert failed_changes[0]["resource_id"] == user["account_id"]
    assert failed_changes[0]["source"] == "api"
    assert (
        wrong_proof_request["current_login_verifier"] not in json.dumps(failed_changes)
    )

    changed = api.request(
        "POST",
        "/api/v1/auth/password-change",
        token=user["access_token"],
        json_body=request,
    )
    assert changed.status == 200, f"password change failed: {_error_code(changed)}"
    changed_body = changed.json()
    assert changed_body == {
        "status": "changed",
        "operation_id": request["operation_id"],
        "credential_version": version_before + 1,
        "session_preserved": True,
        "other_sessions_revoked": True,
        "already_applied": False,
    }
    serialized_response = json.dumps(changed_body, sort_keys=True)
    for secret in (
        request["current_login_verifier"],
        request["new_login_verifier"],
        new_envelope["nonce"],
        new_envelope["ciphertext"],
    ):
        assert secret not in serialized_response

    me_after = api.request("GET", "/api/v1/me", token=user["access_token"])
    assert me_after.status == 200, "the calling session must remain active"
    assert me_after.json()["account_key_envelope"] == new_envelope
    assert me_after.json()["account_key_envelope_version"] == version_before + 1

    revoked_session = api.request("GET", "/api/v1/me", token=second_session.json()["access_token"])
    assert revoked_session.status == 401
    assert _error_code(revoked_session) == "AUTH_REQUIRED"

    exact_retry = api.request(
        "POST",
        "/api/v1/auth/password-change",
        token=user["access_token"],
        json_body=request,
    )
    assert exact_retry.status == 200
    assert exact_retry.json()["already_applied"] is True
    assert exact_retry.json()["credential_version"] == version_before + 1

    reused_operation = {**request, "new_login_verifier": b64url(os.urandom(32))}
    rejected_reuse = api.request(
        "POST",
        "/api/v1/auth/password-change",
        token=user["access_token"],
        json_body=reused_operation,
    )
    assert rejected_reuse.status == 409
    assert _error_code(rejected_reuse) == "IDEMPOTENCY_KEY_REUSED"

    old_login = _login(api, user, user["login_verifier"])
    assert old_login.status == 401
    assert _error_code(old_login) == "AUTH_REQUIRED"
    new_login = _login(api, user, new_verifier)
    assert new_login.status == 200

    prelogin = api.request(
        "POST",
        "/api/v1/auth/prelogin",
        json_body={"username": user["username"]},
    )
    assert prelogin.status == 200
    assert prelogin.json()["kdf"] == new_kdf

    audit = api.request("GET", "/api/v1/audit?limit=200", token=user["access_token"])
    assert audit.status == 200
    change_events = [
        event
        for event in audit.json()["events"]
        if event["action"] == "auth.password_changed"
    ]
    assert len(change_events) == 1
    assert change_events[0]["result"] == "success"
    assert change_events[0]["scope"] == "account"

    # The receipt is metadata only and can’t retain any part of the request body.
    import sqlite3

    with sqlite3.connect(database) as connection:
        receipt = connection.execute(
            "SELECT operation_id,request_digest,credential_version FROM password_change_receipts WHERE session_id IN (SELECT session_id FROM sessions WHERE user_id=?)",
            (user["account_id"],),
        ).fetchone()
    assert receipt is not None
    assert receipt[0] == request["operation_id"]
    assert len(receipt[1]) == 64
    assert receipt[2] == version_before + 1
