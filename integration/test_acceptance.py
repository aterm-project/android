"""Black-box acceptance cases mapped to PROJECT_PLAN.md and API-CONTRACT.md."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from conftest import (
    server_binary_path,
    ROOT,
    ApiClient,
    Response,
    SigningKey,
    b64url,
    initial_vault,
    jcs,
    prepare_web_root,
    redact_secrets,
    unb64url,
    verify_ed25519,
)


def error_code(response: Response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _read_all_audit_events(api: ApiClient, token: str) -> list[dict]:
    events: list[dict] = []
    cursor: str | None = None
    seen_cursors: set[str] = set()
    while True:
        query = {"limit": "200"}
        if cursor is not None:
            query["cursor"] = cursor
        response = api.request(
            "GET", "/api/v1/audit?" + urllib.parse.urlencode(query), token=token
        )
        assert response.status == 200, f"audit read returned HTTP {response.status}"
        body = response.json()
        assert isinstance(body, dict) and isinstance(body.get("events"), list)
        events.extend(body["events"])
        cursor = body.get("next_cursor")
        if cursor is None:
            return events
        assert isinstance(cursor, str) and cursor not in seen_cursors, "audit cursor looped"
        seen_cursors.add(cursor)


def vault_ids(body: object) -> set[str]:
    if isinstance(body, dict):
        entries = body.get("vaults", [])
    else:
        entries = body
    if not isinstance(entries, list):
        return set()
    result = set()
    for entry in entries:
        if isinstance(entry, dict):
            vault_id = entry.get("vault_id") or entry.get("id")
            if vault_id:
                result.add(vault_id)
    return result


def push_body(instance: dict, account: dict, operations: list[dict], batch_id: str | None = None) -> dict:
    return {
        "protocol_version": instance.get("protocol_version", 1),
        "server_generation": str(instance["generation"]),
        "vault_id": account["vault_id"],
        "device_id": account["device_id"],
        "batch_id": batch_id or str(uuid.uuid4()),
        "operations": operations,
    }


def push_request(api: ApiClient, account: dict, body: dict) -> Response:
    return api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/sync/push",
        token=account["access_token"],
        json_body=body,
    )


def test_health_and_instance_contract(api: ApiClient, instance: dict) -> None:
    for endpoint in ("/health/live", "/health/ready"):
        response = api.request("GET", endpoint)
        assert response.status == 200, f"{endpoint} returned {response.status}: {response.json()}"
        assert not any(secret in response.body.lower() for secret in (b"password", b"token", b"database_url"))

    assert instance.get("protocol_version") is not None
    assert isinstance(instance.get("capabilities"), list)
    assert all(isinstance(capability, str) for capability in instance["capabilities"])
    assert isinstance(instance.get("setup_required"), bool)
    assert "account_key_envelope" not in instance


def test_bootstrap_registration_login_and_personal_vault(api: ApiClient, instance: dict, account: dict) -> None:
    assert account.get("account_id")
    assert account.get("access_token") and account.get("refresh_token")
    assert account["device_id"]

    me = api.request("GET", "/api/v1/me", token=account["access_token"])
    assert me.status == 200, f"/me returned {me.status}: {me.json()}"
    me_body = me.json()
    assert me_body.get("account_id") == account["account_id"]
    assert me_body.get("device_id") == account["device_id"]
    assert me_body.get("account_key_envelope") == account["account_key_envelope"]
    assert me_body.get("account_key_envelope_version") == 1
    assert me_body.get("policy", {}).get("registration_open") is False

    listed = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert listed.status == 200, f"vault listing returned {listed.status}: {listed.json()}"
    assert account["vault_id"] in vault_ids(listed.json()), "registration must atomically create an accessible personal vault"
    own_vault = next(v for v in listed.json()["vaults"] if v["vault_id"] == account["vault_id"])
    assert own_vault.get("name_envelope") == account["initial_vault"]["name_envelope"]
    initial_key = account["initial_vault"]["key_envelope"]
    assert own_vault.get("key_envelopes") == [
        {
            "recipient_device_id": account["device_id"],
            "key_epoch": 1,
            "membership_version": 1,
            "envelope": initial_key["envelope"],
            "signature": initial_key["signature"],
            "signer_device_id": account["device_id"],
        }
    ]

    prelogin = api.request("POST", "/api/v1/auth/prelogin", json_body={"username": account["username"]})
    assert prelogin.status == 200, f"prelogin returned {prelogin.status}: {prelogin.json()}"
    assert prelogin.json().get("kdf", {}).get("id") == "argon2id13"
    assert "account_key_envelope" not in prelogin.json()

    login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )
    assert login.status == 200, f"login returned {login.status}: {login.json()}"
    assert login.json().get("access_token") and login.json().get("refresh_token")
    login_vaults = login.json().get("vaults")
    assert isinstance(login_vaults, list)
    login_vault = next(
        (vault for vault in login_vaults if vault.get("vault_id") == account["vault_id"]),
        None,
    )
    assert isinstance(login_vault, dict), "login must return the registered personal vault"
    assert isinstance(login_vault.get("name_envelope"), dict), (
        "login vault name_envelope must be the JSON object, not the database JSON string"
    )
    assert login_vault["name_envelope"] == account["initial_vault"]["name_envelope"]

    unknown = api.request("POST", "/api/v1/auth/prelogin", json_body={"username": "missing@example.test"})
    assert unknown.status == 200
    assert set(unknown.json()) == set(prelogin.json()), "prelogin must not expose account existence by response shape"

    after_setup = api.request("GET", "/api/v1/instance")
    assert after_setup.status == 200 and after_setup.json().get("setup_required") is False


def test_bootstrap_is_single_use_and_signup_is_closed(api: ApiClient, account: dict) -> None:
    device_id = str(uuid.uuid4())
    new_account_id = str(uuid.uuid4())
    vault_id = str(uuid.uuid4())
    device_public = account["signing_public_key"]
    encryption_public = b64url(os.urandom(32))
    device_fields = {
        "device_id": device_id,
        "encryption_public_key": encryption_public,
        "signing_public_key": device_public,
    }
    proof = {"account_id": new_account_id, **device_fields}
    request_body = {
        "bootstrap_token": account["bootstrap_token"],
        "account_id": new_account_id,
        "username": f"second-{uuid.uuid4().hex[:12]}@example.test",
        "kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": b64url(os.urandom(32)),
        "account_key_envelope": account["account_key_envelope"],
        "device": {
            **device_fields,
            "name": "bootstrap-replay-attempt",
            "signature": b64url(account["signing_key"].sign(jcs(proof))),
        },
        "initial_vault": initial_vault(
            account_id=new_account_id,
            vault_id=vault_id,
            device_id=device_id,
            encryption_public_key=encryption_public,
            signer=account["signing_key"],
        ),
    }
    replay = api.request("POST", "/api/v1/auth/register", json_body=request_body)
    assert replay.status == 400
    assert error_code(replay) == "INVALID_ENROLLMENT_CREDENTIAL"


def test_refresh_rotation_and_logout_revoke_only_the_session(api: ApiClient, account: dict) -> None:
    prior_reuse_event_ids = {
        event["event_id"]
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.refresh_reuse_detected"
    }
    unknown_refresh = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": "unknown-refresh-token"}
    )
    assert unknown_refresh.status == 401
    assert {
        event["event_id"]
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.refresh_reuse_detected"
    } == prior_reuse_event_ids, "unknown refresh tokens must not be audited"

    fresh_login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )
    assert fresh_login.status == 200
    old = fresh_login.json()

    rotated = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old["refresh_token"]}
    )
    assert rotated.status == 200, f"refresh returned {rotated.status}: {rotated.json()}"
    new = rotated.json()
    assert new.get("access_token") and new.get("refresh_token")
    assert new["refresh_token"] != old["refresh_token"]
    rotated_again = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": new["refresh_token"]}
    )
    assert rotated_again.status == 200, "second token rotation in one family failed"
    current = rotated_again.json()
    assert api.request("GET", "/api/v1/me", token=current["access_token"]).status == 200

    reused = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old["refresh_token"]}
    )
    assert reused.status == 401, "refresh rotation must reject reuse of the consumed credential"
    replay_detection = api.request("GET", "/api/v1/me", token=current["access_token"])
    assert replay_detection.status == 401, "refresh reuse must revoke the credential family"
    second_consumed_reuse = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": new["refresh_token"]}
    )
    assert second_consumed_reuse.status == 401
    repeated_reuse = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old["refresh_token"]}
    )
    assert repeated_reuse.status == 401
    reuse_events = [
        event
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.refresh_reuse_detected"
        and event["event_id"] not in prior_reuse_event_ids
    ]
    assert len(reuse_events) == 1, "replaying one consumed family must emit at most one event"
    reuse_event = reuse_events[0]
    assert reuse_event["scope"] == "account" and reuse_event["vault_id"] is None
    assert reuse_event["actor_user_id"] is None and reuse_event["actor_device_id"] is None
    assert reuse_event["resource_type"] == "session_family"
    assert re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        reuse_event["resource_id"],
    ), "refresh reuse event must carry only an opaque session-family ID"
    assert reuse_event["result"] == "failure" and reuse_event["source"] == "api"
    for private_value in (
        account["username"],
        account["account_id"],
        account["device_id"],
        old["refresh_token"],
        old["access_token"],
        new["refresh_token"],
        new["access_token"],
        current["refresh_token"],
        current["access_token"],
    ):
        assert private_value not in str(reuse_event), "refresh reuse event leaked request or identity data"

    parallel_login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )
    assert parallel_login.status == 200
    parallel_old = parallel_login.json()
    parallel_rotation = api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": parallel_old["refresh_token"]},
    )
    assert parallel_rotation.status == 200
    parallel_new = parallel_rotation.json()
    with ThreadPoolExecutor(max_workers=2) as executor:
        parallel_replays = list(
            executor.map(
                lambda _: api.request(
                    "POST",
                    "/api/v1/auth/refresh",
                    json_body={"refresh_token": parallel_old["refresh_token"]},
                ),
                range(2),
            )
        )
    assert [response.status for response in parallel_replays] == [401, 401]
    assert api.request("GET", "/api/v1/me", token=parallel_new["access_token"]).status == 401
    all_reuse_events = [
        event
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.refresh_reuse_detected"
        and event["event_id"] not in prior_reuse_event_ids
    ]
    assert len(all_reuse_events) == 2, "two replayed families must create two events total"
    parallel_event = next(event for event in all_reuse_events if event["event_id"] != reuse_event["event_id"])
    assert parallel_event["actor_user_id"] is None and parallel_event["actor_device_id"] is None
    for private_value in (
        account["username"],
        account["account_id"],
        account["device_id"],
        parallel_old["refresh_token"],
        parallel_old["access_token"],
        parallel_new["refresh_token"],
        parallel_new["access_token"],
    ):
        assert private_value not in str(parallel_event)

    events_before_logout = _read_all_audit_events(api, account["access_token"])
    existing_logout_event_ids = {
        event["event_id"]
        for event in events_before_logout
        if event["action"] == "auth.logout_succeeded"
    }
    unauthenticated_logout = api.request("POST", "/api/v1/auth/logout")
    invalid_token_logout = api.request(
        "POST", "/api/v1/auth/logout", token="invalid-logout-token"
    )
    assert unauthenticated_logout.status == 401
    assert invalid_token_logout.status == 401
    assert {
        event["event_id"]
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.logout_succeeded"
    } == existing_logout_event_ids, "invalid logout attempts must not create audit events"

    logout_session = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )
    assert logout_session.status == 200
    logout_token = logout_session.json()["access_token"]
    logout_refresh_token = logout_session.json()["refresh_token"]
    logout_session_id = None
    if api.admin_env:
        database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
        if database_url.startswith("sqlite://"):
            database_path = database_url.removeprefix("sqlite://").split("?", 1)[0]
            with sqlite3.connect(database_path) as database:
                logout_session_id = database.execute(
                    "SELECT session_id FROM sessions WHERE access_hash=?",
                    (hashlib.sha256(logout_token.encode()).hexdigest(),),
                ).fetchone()[0]
    logout = api.request("POST", "/api/v1/auth/logout", token=logout_token, json_body={})
    assert logout.status in (200, 204)
    repeated_logout = api.request("POST", "/api/v1/auth/logout", token=logout_token)
    assert repeated_logout.status == 401, "a revoked session cannot create another logout event"
    after_logout = api.request("GET", "/api/v1/me", token=logout_token)
    assert after_logout.status == 401
    assert api.request("GET", "/api/v1/me", token=account["access_token"]).status == 200
    logout_events = [
        event
        for event in _read_all_audit_events(api, account["access_token"])
        if event["action"] == "auth.logout_succeeded"
        and event["event_id"] not in existing_logout_event_ids
    ]
    assert len(logout_events) == 1, "one committed logout must create one audit event"
    logout_event = logout_events[0]
    assert logout_event["scope"] == "account" and logout_event["vault_id"] is None
    assert logout_event["actor_user_id"] == account["account_id"]
    assert logout_event["actor_device_id"] == account["device_id"]
    assert logout_event["resource_type"] == "session"
    assert re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        logout_event["resource_id"],
    ), "logout event must carry only an opaque canonical session ID"
    if logout_session_id is not None:
        assert logout_event["resource_id"] == logout_session_id
    assert logout_event["result"] == "success" and logout_event["source"] == "api"
    for private_value in (account["username"], logout_token, logout_refresh_token):
        assert private_value not in str(logout_event), "logout audit leaked a private value"


def test_encrypted_create_update_and_cas_conflict(account: dict, make_envelope, push, api: ApiClient) -> None:
    record_id = str(uuid.uuid4())
    create = make_envelope(record_id=record_id, operation="create", ciphertext=os.urandom(73))
    created = push(create)
    assert created.status in (200, 201), f"create returned {created.status}: {created.json()}"
    created_result = created.json()["results"][0]
    assert created_result["revision_id"] == create["header"]["revision_id"]

    update_a = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=create["header"]["revision_id"],
    )
    updated = push(update_a)
    assert updated.status in (200, 201), f"update returned {updated.status}: {updated.json()}"
    update_revision = updated.json()["results"][0]["revision_id"]

    concurrent = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=create["header"]["revision_id"],
    )
    conflict = push(concurrent)
    assert conflict.status == 409, f"stale-base write must conflict: HTTP {conflict.status}: {conflict.json()}"
    assert error_code(conflict) == "REVISION_CONFLICT"
    details = (conflict.json().get("error") or {}).get("details") or {}
    assert details.get("current_revision_id") == update_revision
    assert details.get("current_envelope") == update_a

    fetched = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/revisions/{update_revision}",
        token=account["access_token"],
    )
    assert fetched.status == 200, f"revision fetch returned {fetched.status}: {fetched.json()}"
    assert fetched.json().get("envelope") == update_a, "server must return the exact opaque signed envelope"


def test_workspace_payload_type_remains_opaque_to_server(
    account: dict, make_envelope, push, api: ApiClient
) -> None:
    record_id = str(uuid.uuid4())
    private_marker = f"workspace-layout-private-{uuid.uuid4()}"
    # The service treats this byte string as ciphertext; it cannot infer the
    # client-only Workspace record type or its layout from the envelope.
    opaque_payload = (
        '{"type":"workspace","name":"'
        + private_marker
        + '","layout_tree":{"kind":"terminal_tabs","panes":[]}}'
    ).encode()
    envelope = make_envelope(
        record_id=record_id,
        operation="create",
        ciphertext=opaque_payload,
    )
    created = push(envelope)
    assert created.status in (200, 201), (
        f"opaque Workspace envelope returned {created.status}: {created.json()}"
    )
    revision_id = created.json()["results"][0]["revision_id"]

    fetched = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/revisions/{revision_id}",
        token=account["access_token"],
    )
    assert fetched.status == 200, f"Workspace revision returned {fetched.status}: {fetched.json()}"
    assert fetched.json().get("envelope") == envelope
    assert private_marker not in str(fetched.json())
    assert "record_type" not in envelope["header"]


def test_idempotent_retry_returns_same_commit(account: dict, make_envelope, api: ApiClient, instance: dict) -> None:
    envelope = make_envelope(operation="create")
    body = push_body(instance, account, [envelope])
    first = push_request(api, account, body)
    assert first.status in (200, 201), f"initial push returned {first.status}: {first.json()}"
    first_result = first.json()["results"][0]

    # Reusing the same batch ID exercises batch_receipts.
    retried = push_request(api, account, body)
    assert retried.status in (200, 201), f"retry returned {retried.status}: {retried.json()}"
    retry_result = retried.json()["results"][0]
    assert retry_result["commit_seq"] == first_result["commit_seq"]
    assert retry_result["revision_id"] == first_result["revision_id"]
    assert retry_result.get("already_committed") is True

    # A client that lost the first response normally creates a fresh batch ID
    # while replaying the immutable signed envelope. This must use op_receipts.
    retry_with_new_batch = push_body(instance, account, [envelope])
    assert retry_with_new_batch["batch_id"] != body["batch_id"]
    op_retried = push_request(api, account, retry_with_new_batch)
    assert op_retried.status in (200, 201), (
        f"same operation under a fresh batch ID returned {op_retried.status}: {op_retried.json()}"
    )
    op_retry_result = op_retried.json()["results"][0]
    assert op_retry_result["commit_seq"] == first_result["commit_seq"]
    assert op_retry_result["revision_id"] == first_result["revision_id"]
    assert op_retry_result.get("already_committed") is True

    if api.admin_env:
        database_url = api.admin_env["ATERMIUS_DATABASE_URL"]
        assert database_url.startswith("sqlite://"), "idempotency acceptance requires its disposable SQLite database"
        database_path = database_url.removeprefix("sqlite://").split("?", 1)[0]
        with sqlite3.connect(database_path) as database:
            receipts = database.execute(
                "SELECT revision_id, commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?",
                (account["vault_id"], envelope["header"]["op_id"]),
            ).fetchall()
            versions = database.execute(
                "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?",
                (account["vault_id"], envelope["header"]["record_id"]),
            ).fetchone()[0]
            events = database.execute(
                "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=? AND revision_id=?",
                (account["vault_id"], envelope["header"]["record_id"], envelope["header"]["revision_id"]),
            ).fetchone()[0]
            batch_receipts = database.execute(
                "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id IN (?,?)",
                (account["vault_id"], account["device_id"], body["batch_id"], retry_with_new_batch["batch_id"]),
            ).fetchone()[0]
            vault_sequence = database.execute(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
                (account["vault_id"],),
            ).fetchone()[0]
        assert receipts == [(first_result["revision_id"], int(first_result["commit_seq"]))]
        assert versions == 1, "same op_id under a fresh batch ID must not add a record version"
        assert events == 1, "same op_id under a fresh batch ID must not add a change event"
        assert batch_receipts == 2, "both distinct batch IDs must retain their batch receipts"
        assert str(vault_sequence) == first_result["commit_seq"], "idempotent replay must not advance the Vault sequence"
    else:
        changes = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?limit=500",
            token=account["access_token"],
        )
        assert changes.status == 200
        matching = [
            event for event in changes.json()["events"]
            if event.get("envelope", {}).get("header", {}).get("op_id") == envelope["header"]["op_id"]
        ]
        assert len(matching) == 1, "same op_id under a fresh batch ID must appear once in the changes feed"

    changed = {**body, "operations": [make_envelope(record_id=envelope["header"]["record_id"])]}
    reused = push_request(api, account, changed)
    assert reused.status == 409, f"different payload under an existing batch ID must be rejected: {reused.json()}"
    assert error_code(reused) == "IDEMPOTENCY_KEY_REUSED"


def test_sync_rejects_noncanonical_signed_counters_without_commit_side_effects(
    account: dict, make_envelope, api: ApiClient, push
) -> None:
    accepted = make_envelope(operation="create")
    committed = push(accepted)
    assert committed.status in (200, 201), f"baseline sync push returned {committed.status}: {committed.json()}"

    database_url = api.admin_env["ATERMIUS_DATABASE_URL"] if api.admin_env else None
    if database_url:
        assert database_url.startswith("sqlite://"), "counter acceptance requires its disposable SQLite database"
        database_path = database_url.removeprefix("sqlite://").split("?", 1)[0]

    def sync_snapshot(envelope: dict) -> tuple[int, int, int, int, int]:
        if not database_url:
            raise AssertionError("this direct side-effect regression requires a disposable server with admin_env")
        with sqlite3.connect(database_path) as database:
            counter = database.execute(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
                (account["vault_id"],),
            ).fetchone()[0]
            versions = database.execute(
                "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND revision_id=?",
                (account["vault_id"], envelope["header"]["revision_id"]),
            ).fetchone()[0]
            events = database.execute(
                "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?",
                (account["vault_id"], envelope["header"]["record_id"]),
            ).fetchone()[0]
            heads = database.execute(
                "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
                (account["vault_id"], envelope["header"]["record_id"]),
            ).fetchone()[0]
            receipts = database.execute(
                "SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?",
                (account["vault_id"], envelope["header"]["op_id"]),
            ).fetchone()[0]
        return counter, versions, events, heads, receipts

    def sign_header_change(envelope: dict, field: str, value: str) -> dict:
        changed = {**envelope, "header": {**envelope["header"], field: value}}
        unsigned = {
            "header": changed["header"],
            "nonce": changed["nonce"],
            "ciphertext": changed["ciphertext"],
        }
        changed["signature"] = b64url(account["signing_key"].sign(jcs(unsigned)))
        return changed

    # The device sequence is the exact numeric sequence from the accepted
    # operation, with only a leading zero added. Earlier servers compared
    # receipt sequence strings, so "1" and "01" could both commit.
    device_sequence_candidate = make_envelope(operation="create")
    device_sequence_alias = "0" + accepted["header"]["device_seq"]
    cases = [(device_sequence_candidate, "device_seq", device_sequence_alias)]
    for field in ("key_epoch", "membership_version"):
        candidate = make_envelope(operation="create")
        cases.append((candidate, field, "0" + candidate["header"][field]))

    for candidate, field, value in cases:
        invalid = sign_header_change(candidate, field, value)
        if field == "device_seq":
            assert invalid["header"]["device_seq"] == "0" + accepted["header"]["device_seq"]
        before = sync_snapshot(invalid) if database_url else None
        response = push(invalid)
        assert response.status == 422, f"noncanonical {field} returned {response.status}: {response.json()}"
        assert error_code(response) == "INVALID_ENVELOPE"
        if database_url:
            after = sync_snapshot(invalid)
            assert after == before, (
                f"noncanonical {field} changed the Vault sequence or revision/event/head/receipt state"
            )
            batch_id = getattr(response, "_request_body")["batch_id"]
            with sqlite3.connect(database_path) as database:
                batch_receipts = database.execute(
                    "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
                    (account["vault_id"], account["device_id"], batch_id),
                ).fetchone()[0]
            assert batch_receipts == 0, f"noncanonical {field} left a batch receipt"


def test_bad_signature_is_rejected_without_committing(account: dict, make_envelope, api: ApiClient, instance: dict) -> None:
    envelope = make_envelope(operation="create")
    envelope["ciphertext"] = b64url(os.urandom(64))
    response = push_request(api, account, push_body(instance, account, [envelope]))
    assert response.status == 422
    assert error_code(response) == "INVALID_ENVELOPE"
    changes = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/changes?limit=500",
        token=account["access_token"],
    )
    assert changes.status == 200
    assert all(event.get("record_id") != envelope["header"]["record_id"] for event in changes.json()["events"])


def test_batch_with_cas_conflict_is_atomic(account: dict, make_envelope, api: ApiClient, instance: dict) -> None:
    independent = make_envelope(operation="create")
    invalid_cas = make_envelope(
        operation="update",
        record_id=str(uuid.uuid4()),
        base_revision_id=str(uuid.uuid4()),
    )
    batch = push_request(api, account, push_body(instance, account, [independent, invalid_cas]))
    assert batch.status == 409, f"conflicting batch returned {batch.status}: {batch.json()}"
    assert error_code(batch) == "REVISION_CONFLICT"

    changes = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/changes?limit=500",
        token=account["access_token"],
    )
    assert changes.status == 200
    assert all(event.get("record_id") != independent["header"]["record_id"] for event in changes.json()["events"]), (
        "an otherwise valid operation from a rejected batch must not partially commit"
    )


def test_cursor_paging_is_ordered_and_has_no_duplicates(account: dict, make_envelope, push, changes) -> None:
    expected_ids = {str(uuid.uuid4()) for _ in range(3)}
    envelopes = [make_envelope(record_id=record_id, operation="create") for record_id in expected_ids]
    expected_envelopes = {item["header"]["record_id"]: item for item in envelopes}
    result = push(*envelopes)
    assert result.status in (200, 201), f"batch create returned {result.status}: {result.json()}"

    cursor = None
    observed: list[dict] = []
    seen_cursors: set[str | None] = set()
    for _ in range(40):
        page = changes(cursor=cursor, limit=1)
        assert page.status == 200, f"changes returned {page.status}: {page.json()}"
        body = page.json()
        assert body.get("server_generation") is not None
        events = body.get("events")
        assert isinstance(events, list) and len(events) <= 1
        observed.extend(events)
        next_cursor = body.get("next_cursor")
        assert next_cursor != cursor or not body.get("has_more"), "cursor must advance whenever more events remain"
        if not body.get("has_more"):
            break
        assert next_cursor not in seen_cursors, "cursor paging looped"
        seen_cursors.add(next_cursor)
        cursor = next_cursor
    else:
        pytest.fail("changes paging exceeded 40 pages")

    target_events = [event for event in observed if event.get("record_id") in expected_ids]
    assert {event["record_id"] for event in target_events} == expected_ids
    assert all(event.get("envelope") == expected_envelopes[event["record_id"]] for event in target_events)
    seqs = [int(event["commit_seq"]) for event in observed]
    assert seqs == sorted(seqs) and len(seqs) == len(set(seqs))
    malformed = changes(cursor="not-a-signed-cursor", limit=1)
    assert malformed.status == 400
    assert error_code(malformed) == "INVALID_CURSOR"


def test_tombstone_and_graveyard_prevent_resurrection(account: dict, make_envelope, push) -> None:
    record_id = str(uuid.uuid4())
    created = make_envelope(record_id=record_id, operation="create")
    response = push(created)
    assert response.status in (200, 201), f"create returned {response.status}: {response.json()}"
    live_revision = response.json()["results"][0]["revision_id"]

    deleted = make_envelope(record_id=record_id, operation="delete", base_revision_id=live_revision)
    delete_response = push(deleted)
    assert delete_response.status in (200, 201), f"delete returned {delete_response.status}: {delete_response.json()}"

    stale_update = make_envelope(record_id=record_id, operation="update", base_revision_id=live_revision)
    rejected_update = push(stale_update)
    assert rejected_update.status == 409
    assert error_code(rejected_update) == "RECORD_TOMBSTONED"

    stale_create = make_envelope(record_id=record_id, operation="create")
    rejected_create = push(stale_create)
    assert rejected_create.status == 409
    assert error_code(rejected_create) == "RECORD_TOMBSTONED"

    tombstone_revision = delete_response.json()["results"][0]["revision_id"]
    restored = make_envelope(record_id=record_id, operation="restore", base_revision_id=tombstone_revision)
    restore_response = push(restored)
    assert restore_response.status in (200, 201), f"explicit restore returned {restore_response.status}: {restore_response.json()}"
    restored_revision = restore_response.json()["results"][0]["revision_id"]
    update_after_restore = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=restored_revision,
    )
    updated = push(update_after_restore)
    assert updated.status in (200, 201), f"restored record could not be updated: {updated.json()}"


def test_expired_tombstone_restore_is_rejected_atomically(
    api: ApiClient, account: dict, make_envelope, push
) -> None:
    if not api.started_by_suite or api.temp_root is None:
        pytest.skip("restore deadline aging requires the disposable server database")

    instance = api.request("GET", "/api/v1/instance")
    assert instance.status == 200
    restore_retention_days = instance.json()["restore_retention_days"]
    assert 1 <= restore_retention_days <= 3650

    record_id = str(uuid.uuid4())
    created = push(make_envelope(record_id=record_id, operation="create"))
    assert created.status in (200, 201), f"create returned {created.status}: {created.json()}"
    live_revision = created.json()["results"][0]["revision_id"]
    deleted = push(
        make_envelope(
            record_id=record_id,
            operation="delete",
            base_revision_id=live_revision,
        )
    )
    assert deleted.status in (200, 201), f"delete returned {deleted.status}: {deleted.json()}"
    tombstone_revision = deleted.json()["results"][0]["revision_id"]

    expired_at = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    newer_created_at = datetime.now(timezone.utc).isoformat()
    database_path = api.temp_root / "data" / "atermius.db"
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            "UPDATE record_versions SET created_at=?,restore_until=? WHERE vault_id=? AND record_id=? "
            "AND revision_id=? AND operation='delete'",
            (newer_created_at, expired_at, account["vault_id"], record_id, tombstone_revision),
        )
        connection.commit()

        def state() -> tuple[object, ...]:
            head = connection.execute(
                "SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?",
                (account["vault_id"], record_id),
            ).fetchone()
            grave = connection.execute(
                "SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?",
                (account["vault_id"], record_id),
            ).fetchone()
            counters = connection.execute(
                "SELECT last_committed_seq,minimum_available_seq FROM vault_counters WHERE vault_id=?",
                (account["vault_id"],),
            ).fetchone()
            counts = tuple(
                connection.execute(query, args).fetchone()[0]
                for query, args in (
                    ("SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?", (account["vault_id"], record_id)),
                    ("SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?", (account["vault_id"], record_id)),
                    ("SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND record_id=?", (account["vault_id"], record_id)),
                    ("SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=?", (account["vault_id"], account["device_id"])),
                    ("SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=?", (account["vault_id"],)),
                    ("SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id IN (SELECT endpoint_id FROM notification_push_endpoints WHERE user_id=?)", (account["account_id"],)),
                )
            )
            return head, grave, counters, counts

        before = state()
        attempted = push(
            make_envelope(
                record_id=record_id,
                operation="restore",
                base_revision_id=tombstone_revision,
            )
        )
        assert attempted.status == 409, f"expired restore returned {attempted.status}: {attempted.json()}"
        assert error_code(attempted) == "RECORD_RESTORE_EXPIRED"
        details = attempted.json()["error"]["details"]
        assert details["recovery"] == "create_new_record"
        assert details["restore_retention_days"] == restore_retention_days
        assert datetime.fromisoformat(details["restore_until"].replace("Z", "+00:00")) < datetime.now(timezone.utc)
        assert datetime.fromisoformat(details["restore_expires_at"].replace("Z", "+00:00")) < datetime.now(timezone.utc)
        assert state() == before, "expired restore must not change the head, graveyard, receipts, audit, events, or notifications"


def test_conflict_branch_is_preserved_and_resolved(api: ApiClient, account: dict, make_envelope, push) -> None:
    record_id = str(uuid.uuid4())
    created = push(make_envelope(record_id=record_id, operation="create"))
    assert created.status in (200, 201)
    base_revision = created.json()["results"][0]["revision_id"]

    branch = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=base_revision,
    )
    stored = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/conflicts",
        token=account["access_token"],
        json_body={"envelope": branch},
    )
    assert stored.status in (200, 201), f"conflict branch returned {stored.status}: {stored.json()}"
    conflict_id = stored.json().get("conflict_id")
    assert conflict_id

    main_update = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=base_revision,
    )
    main_response = push(main_update)
    assert main_response.status in (200, 201)
    main_revision = main_response.json()["results"][0]["revision_id"]

    resolved = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/conflicts/{conflict_id}/resolve",
        token=account["access_token"],
        json_body={"resolved_revision_id": main_revision},
    )
    assert resolved.status in (200, 201), f"conflict resolution returned {resolved.status}: {resolved.json()}"
    assert resolved.json().get("resolved_revision_id") == main_revision


def test_snapshot_manifest_is_a_fixed_rebuild_point(
    api: ApiClient, account: dict, make_envelope, push
) -> None:
    record_id = str(uuid.uuid4())
    initial = make_envelope(record_id=record_id, operation="create")
    created = push(initial)
    assert created.status in (200, 201)
    initial_revision = created.json()["results"][0]["revision_id"]
    initial_commit_seq = created.json()["results"][0]["commit_seq"]

    requested = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/snapshots",
        token=account["access_token"],
    )
    assert requested.status in (200, 201), f"snapshot request returned {requested.status}: {requested.json()}"
    snapshot_id = requested.json().get("snapshot_id")
    assert snapshot_id

    later = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=initial_revision,
    )
    later_response = push(later)
    assert later_response.status in (200, 201)
    later_revision = later_response.json()["results"][0]["revision_id"]
    later_commit_seq = later_response.json()["results"][0]["commit_seq"]

    fetched = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=account["access_token"]
    )
    assert fetched.status == 200, f"snapshot fetch returned {fetched.status}: {fetched.json()}"
    snapshot = fetched.json()
    assert snapshot.get("high_watermark") == requested.json().get("high_watermark")
    manifest = snapshot.get("manifest")
    assert isinstance(manifest, list)
    entry = next((item for item in manifest if item.get("record_id") == record_id), None)
    assert entry is not None, "snapshot manifest omitted a committed record"
    assert entry.get("revision_id") == initial_revision
    assert entry.get("revision_id") != later_revision, "snapshot must not move after its high-water mark"
    assert entry.get("commit_seq") == initial_commit_seq
    assert entry.get("commit_seq") != later_commit_seq
    assert int(entry["commit_seq"]) <= int(snapshot["high_watermark"])


def test_auth_membership_and_device_revocation(api: ApiClient, account: dict, tmp_path) -> None:
    unauthorized = api.request("GET", "/api/v1/devices")
    assert unauthorized.status == 401
    assert error_code(unauthorized) == "AUTH_REQUIRED"
    forged_token = api.request("GET", "/api/v1/me", token=b64url(os.urandom(32)))
    assert forged_token.status == 401
    assert error_code(forged_token) == "AUTH_REQUIRED"
    membership = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/membership?from=0",
        token=account["access_token"],
    )
    assert membership.status == 200, f"membership fetch returned {membership.status}: {membership.json()}"
    manifests = membership.json().get("manifests")
    assert isinstance(manifests, list) and manifests
    assert manifests[0].get("membership_version") == 1
    assert manifests[0].get("signer_device_id") == account["device_id"]
    initial_membership = account["initial_vault"]["membership"]
    stored_initial = manifests[0].get("manifest")
    assert isinstance(stored_initial, dict)
    assert set(stored_initial) == {
        "vault_id",
        "membership_version",
        "previous_digest",
        "manifest",
        "signature",
    }
    assert stored_initial == {
        "vault_id": account["vault_id"],
        "membership_version": 1,
        "previous_digest": None,
        "manifest": initial_membership["manifest"],
        "signature": initial_membership["signature"],
    }
    membership_signed_fields = {
        "vault_id": account["vault_id"],
        "membership_version": initial_membership["membership_version"],
        "previous_digest": initial_membership["previous_digest"],
        "manifest": initial_membership["manifest"],
    }
    assert verify_ed25519(
        account["signing_public_key"],
        jcs(membership_signed_fields),
        manifests[0]["signature"],
    )

    devices_response = api.request("GET", "/api/v1/devices", token=account["access_token"])
    assert devices_response.status == 200, f"device listing returned {devices_response.status}: {devices_response.json()}"
    owner_device = next(
        d for d in devices_response.json()["devices"] if d["device_id"] == account["device_id"]
    )
    assert owner_device.get("user_id") == account["account_id"]
    assert owner_device.get("signing_public_key") == account["signing_public_key"]
    vault_directory = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/devices",
        token=account["access_token"],
    )
    assert vault_directory.status == 200, f"vault device directory returned {vault_directory.status}: {vault_directory.json()}"
    directory_devices = vault_directory.json().get("devices")
    assert isinstance(directory_devices, list) and directory_devices
    directory_owner = next(d for d in directory_devices if d["device_id"] == account["device_id"])
    assert directory_owner["user_id"] == account["account_id"]
    assert directory_owner["signing_public_key"] == account["signing_public_key"]
    assert directory_owner["encryption_public_key"] == account["encryption_public_key"]
    assert directory_owner["status"] == "active"
    assert directory_owner.get("name")
    members_response = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/members",
        token=account["access_token"],
    )
    assert members_response.status == 200, f"vault members returned {members_response.status}: {members_response.json()}"
    owner_member = next(
        member
        for member in members_response.json().get("members", [])
        if member.get("user_id") == account["account_id"]
    )
    assert owner_member.get("role") == "owner" and owner_member.get("state") == "active"
    owner_vaults_response = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert owner_vaults_response.status == 200
    owner_vault = next(
        v for v in owner_vaults_response.json()["vaults"] if v["vault_id"] == account["vault_id"]
    )
    initial_key = account["initial_vault"]["key_envelope"]
    assert verify_ed25519(
        owner_device["signing_public_key"],
        jcs(
            {
                "vault_id": account["vault_id"],
                "recipient_device_id": account["device_id"],
                "key_epoch": 1,
                "membership_version": 1,
                "envelope": initial_key["envelope"],
            }
        ),
        owner_vault["key_envelopes"][0]["signature"],
    )

    sibling_key = SigningKey(tmp_path, "sibling-device")
    sibling_id = str(uuid.uuid4())
    sibling_encryption_key = b64url(os.urandom(32))
    signed_device_fields = {
        "device_id": sibling_id,
        "encryption_public_key": sibling_encryption_key,
        "signing_public_key": b64url(sibling_key.public_key),
    }
    self_proof = {
        "account_id": account["account_id"],
        **signed_device_fields,
    }
    new_device = {
        **signed_device_fields,
        "name": "pytest-sibling",
        "signature": b64url(sibling_key.sign(jcs(self_proof))),
    }
    signed_key_fields = {
        "vault_id": account["vault_id"],
        "recipient_device_id": sibling_id,
        "key_epoch": 1,
        "membership_version": 1,
        "envelope": {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        },
    }
    key_envelope = {
        **signed_key_fields,
        "signature": b64url(account["signing_key"].sign(jcs(signed_key_fields))),
    }
    enrollment = {
        "device": new_device,
        "approver_device_id": account["device_id"],
        "certificate_signature": b64url(
            account["signing_key"].sign(
                jcs(
                    {
                        "account_id": account["account_id"],
                        "approver_device_id": account["device_id"],
                        "device": new_device,
                    }
                )
            )
        ),
        "vault_key_envelopes": [key_envelope],
    }

    missing_envelope = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body={**enrollment, "vault_key_envelopes": []},
    )
    assert missing_envelope.status == 422
    assert error_code(missing_envelope) == "INVALID_ENVELOPE"

    wrong_approver = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body={**enrollment, "approver_device_id": str(uuid.uuid4())},
    )
    assert wrong_approver.status == 403
    assert error_code(wrong_approver) == "DEVICE_REVOKED"

    bad_certificate = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body={**enrollment, "certificate_signature": b64url(os.urandom(64))},
    )
    assert bad_certificate.status == 422
    assert error_code(bad_certificate) == "INVALID_ENVELOPE"

    bad_vault_signature = dict(enrollment)
    bad_vault_signature["vault_key_envelopes"] = [
        {**key_envelope, "signature": b64url(os.urandom(64))}
    ]
    invalid_vault_envelope = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body=bad_vault_signature,
    )
    assert invalid_vault_envelope.status == 422
    assert error_code(invalid_vault_envelope) == "INVALID_ENVELOPE"

    enrolled = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body=enrollment,
    )
    assert enrolled.status in (200, 201), f"sibling enrollment returned {enrolled.status}: {enrolled.json()}"
    assert enrolled.json().get("vault_key_envelope_count") == 1

    sibling_login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": sibling_id,
        },
    )
    assert sibling_login.status == 200, f"sibling login returned {sibling_login.status}: {sibling_login.json()}"
    sibling_token = sibling_login.json()["access_token"]
    sibling_me = api.request("GET", "/api/v1/me", token=sibling_token)
    assert sibling_me.status == 200 and sibling_me.json().get("device_id") == sibling_id
    sibling_devices = api.request("GET", "/api/v1/devices", token=sibling_token)
    assert sibling_devices.status == 200
    listed_sibling = next(
        d for d in sibling_devices.json()["devices"] if d["device_id"] == sibling_id
    )
    assert listed_sibling.get("user_id") == account["account_id"]
    sibling_vaults = api.request("GET", "/api/v1/vaults", token=sibling_token)
    assert sibling_vaults.status == 200
    listed_vault = next(v for v in sibling_vaults.json()["vaults"] if v["vault_id"] == account["vault_id"])
    assert listed_vault["key_envelopes"] == [
        {
            "key_epoch": 1,
            "recipient_device_id": sibling_id,
            "envelope": key_envelope["envelope"],
            "signature": key_envelope["signature"],
            "signer_device_id": account["device_id"],
            "membership_version": 1,
        }
    ]
    assert verify_ed25519(
        owner_device["signing_public_key"],
        jcs(signed_key_fields),
        listed_vault["key_envelopes"][0]["signature"],
    )
    after_enrollment_directory = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/devices",
        token=account["access_token"],
    )
    assert after_enrollment_directory.status == 200
    sibling_directory_device = next(
        d for d in after_enrollment_directory.json()["devices"] if d["device_id"] == sibling_id
    )
    assert sibling_directory_device["user_id"] == account["account_id"]
    assert sibling_directory_device["signing_public_key"] == b64url(sibling_key.public_key)
    assert sibling_directory_device["encryption_public_key"] == sibling_encryption_key
    assert sibling_directory_device["status"] == "active"

    revoked = api.request(
        "POST",
        f"/api/v1/devices/{sibling_id}/revoke",
        token=account["access_token"],
        json_body={},
    )
    assert revoked.status in (200, 204), f"device revoke returned {revoked.status}: {revoked.json()}"
    after_revoke = api.request("GET", "/api/v1/me", token=sibling_token)
    assert after_revoke.status in (401, 403)
    assert error_code(after_revoke) in ("DEVICE_REVOKED", "AUTH_REQUIRED")

    foreign_id = str(uuid.uuid4())
    foreign_vault = api.request(
        "GET",
        f"/api/v1/vaults/{foreign_id}/changes?limit=1",
        token=account["access_token"],
    )
    assert foreign_vault.status in (403, 404), "random inaccessible vault IDs must never bypass membership checks"
    foreign_directory = api.request(
        "GET",
        f"/api/v1/vaults/{foreign_id}/devices",
        token=account["access_token"],
    )
    assert foreign_directory.status in (403, 404), (
        "vault-scoped device directory must reject inaccessible vault IDs"
    )
    foreign_members = api.request(
        "GET",
        f"/api/v1/vaults/{foreign_id}/members",
        token=account["access_token"],
    )
    assert foreign_members.status in (403, 404), (
        "vault-scoped membership endpoint must reject inaccessible vault IDs"
    )


def test_encrypted_object_roundtrip_and_size_bounds(api: ApiClient, account: dict) -> None:
    # The default chunk size equals the server's 1 MiB request-body cap; exercise
    # the exact boundary to catch framework/proxy off-by-one limits.
    opaque = os.urandom(1_048_576)
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/uploads/init",
        token=account["access_token"],
        json_body={"object_id": object_id, "size": len(opaque), "sha256": hashlib.sha256(opaque).hexdigest()},
    )
    assert initialized.status in (200, 201), f"upload init returned {initialized.status}: {initialized.json()}"
    init_body = initialized.json()
    upload_id = init_body.get("upload_id")
    chunk_size = int(init_body.get("chunk_size", 1_048_576))
    assert upload_id and chunk_size == 1_048_576

    chunk_index = 0
    for start in range(0, len(opaque), chunk_size):
        chunk = opaque[start : start + chunk_size]
        put = api.request(
            "PUT",
            f"/api/v1/uploads/{upload_id}/chunks/{chunk_index}",
            token=account["access_token"],
            raw_body=chunk,
            content_type="application/octet-stream",
        )
        assert put.status in (200, 201, 204), f"chunk upload returned {put.status}: {put.json()}"
        chunk_index += 1

    repeated_chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=account["access_token"],
        raw_body=opaque[:chunk_size],
        content_type="application/octet-stream",
    )
    assert repeated_chunk.status in (200, 201)
    assert repeated_chunk.json().get("already_uploaded") is True

    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=account["access_token"],
        json_body={},
    )
    assert completed.status in (200, 201), f"upload completion returned {completed.status}: {completed.json()}"
    repeated_complete = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=account["access_token"],
        json_body={},
    )
    assert repeated_complete.status in (200, 201)
    assert repeated_complete.json().get("already_completed") is True
    downloaded = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/objects/{object_id}",
        token=account["access_token"],
    )
    assert downloaded.status == 200
    assert downloaded.body == opaque, "object service must preserve opaque ciphertext bytes"

    oversize = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/uploads/init",
        token=account["access_token"],
        json_body={
            "object_id": str(uuid.uuid4()),
            "size": 64 * 1024 * 1024 + 1,
            "sha256": hashlib.sha256(b"declared-only").hexdigest(),
        },
    )
    assert oversize.status == 413, f"object size bound must be enforced, received HTTP {oversize.status}: {oversize.json()}"
    assert error_code(oversize) == "PAYLOAD_TOO_LARGE"

    incomplete_payload = os.urandom(1_048_577)
    incomplete = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/uploads/init",
        token=account["access_token"],
        json_body={
            "object_id": str(uuid.uuid4()),
            "size": len(incomplete_payload),
            "sha256": hashlib.sha256(incomplete_payload).hexdigest(),
        },
    )
    assert incomplete.status in (200, 201)
    incomplete_id = incomplete.json()["upload_id"]
    missing = api.request(
        "POST",
        f"/api/v1/uploads/{incomplete_id}/complete",
        token=account["access_token"],
        json_body={},
    )
    assert missing.status == 409
    assert error_code(missing) == "UPLOAD_INCOMPLETE"

    wrong_bytes = os.urandom(777)
    wrong = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/uploads/init",
        token=account["access_token"],
        json_body={
            "object_id": str(uuid.uuid4()),
            "size": len(wrong_bytes),
            "sha256": "0" * 64,
        },
    )
    assert wrong.status in (200, 201)
    wrong_id = wrong.json()["upload_id"]
    put_wrong = api.request(
        "PUT",
        f"/api/v1/uploads/{wrong_id}/chunks/0",
        token=account["access_token"],
        raw_body=wrong_bytes,
        content_type="application/octet-stream",
    )
    assert put_wrong.status in (200, 201)
    mismatch = api.request(
        "POST",
        f"/api/v1/uploads/{wrong_id}/complete",
        token=account["access_token"],
        json_body={},
    )
    assert mismatch.status == 409
    assert error_code(mismatch) == "OBJECT_HASH_MISMATCH"


def test_signed_key_rotation_retains_history_for_new_device(
    api: ApiClient, account: dict, instance: dict, make_envelope, tmp_path
) -> None:
    vault_id = account["vault_id"]
    token = account["access_token"]
    signer = account["signing_key"]

    original_membership = account["initial_vault"]["membership"]
    previous_payload = {
        "vault_id": vault_id,
        "membership_version": original_membership["membership_version"],
        "previous_digest": original_membership["previous_digest"],
        "manifest": original_membership["manifest"],
    }
    previous_digest = hashlib.sha256(jcs(previous_payload)).hexdigest()
    next_version = 2
    next_epoch = 2
    owner_fingerprint = b64url(hashlib.sha256(unb64url(account["encryption_public_key"])).digest())
    display_name_envelope = {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(48)),
    }
    rotation_manifest = {
        "key_epoch": next_epoch,
        "members": [
            {
                "user_id": account["account_id"],
                "role": "owner",
                "state": "active",
                "encryption_key_fingerprint": owner_fingerprint,
            }
        ],
        "signer_device_id": account["device_id"],
        "display_name_envelope": display_name_envelope,
    }
    membership_fields = {
        "vault_id": vault_id,
        "membership_version": next_version,
        "previous_digest": previous_digest,
        "manifest": rotation_manifest,
    }
    rotation_membership = {
        "membership_version": next_version,
        "previous_digest": previous_digest,
        "manifest": rotation_manifest,
        "signature": b64url(signer.sign(jcs(membership_fields))),
    }

    devices_response = api.request("GET", "/api/v1/devices", token=token)
    assert devices_response.status == 200, f"device listing returned {devices_response.status}: {devices_response.json()}"
    active_devices = [d for d in devices_response.json()["devices"] if d.get("status") == "active"]
    assert active_devices and all(d["device_id"] == account["device_id"] for d in active_devices), (
        "this acceptance account should have only its active owner device before rotation"
    )
    new_keys = []
    for device in active_devices:
        unsigned = {
            "recipient_device_id": device["device_id"],
            "key_epoch": next_epoch,
            "membership_version": next_version,
            "envelope": {
                "version": 1,
                "suite": "crypto_box_seal",
                "ciphertext": b64url(os.urandom(48)),
            },
            "signer_device_id": account["device_id"],
        }
        signed = {
            "vault_id": vault_id,
            "recipient_device_id": unsigned["recipient_device_id"],
            "key_epoch": unsigned["key_epoch"],
            "membership_version": unsigned["membership_version"],
            "envelope": unsigned["envelope"],
        }
        new_keys.append({**unsigned, "signature": b64url(signer.sign(jcs(signed)))})

    rotation_body = {
        "new_epoch": next_epoch,
        "membership": rotation_membership,
        "key_envelopes": new_keys,
    }
    invalid_rotation = {
        **rotation_body,
        "key_envelopes": [{**new_keys[0], "signature": b64url(os.urandom(64))}],
    }
    rejected_rotation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=token,
        json_body=invalid_rotation,
    )
    assert rejected_rotation.status == 422
    assert error_code(rejected_rotation) == "INVALID_ENVELOPE"
    before_commit = api.request("GET", "/api/v1/vaults", token=token)
    before_vault = next(v for v in before_commit.json()["vaults"] if v["vault_id"] == vault_id)
    assert before_vault["active_key_epoch"] == 1 and before_vault["membership_version"] == 1, (
        "a failed key-envelope signature must roll back the membership and active epoch"
    )

    rotated = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=token,
        json_body=rotation_body,
    )
    assert rotated.status in (200, 201), f"rotation returned {rotated.status}: {rotated.json()}"
    assert rotated.json().get("active_key_epoch") == next_epoch
    assert rotated.json().get("membership_version") == next_version
    rotated_vaults = api.request("GET", "/api/v1/vaults", token=token)
    assert rotated_vaults.status == 200
    rotated_vault = next(v for v in rotated_vaults.json()["vaults"] if v["vault_id"] == vault_id)
    assert rotated_vault["name_envelope"] == display_name_envelope

    stale_record = make_envelope(operation="create")
    assert stale_record["header"]["key_epoch"] == "1"
    stale_batch = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/sync/push",
        token=token,
        json_body={
            "protocol_version": instance.get("protocol_version", 1),
            "server_generation": str(instance["generation"]),
            "vault_id": vault_id,
            "device_id": account["device_id"],
            "batch_id": str(uuid.uuid4()),
            "operations": [stale_record],
        },
    )
    assert stale_batch.status == 409
    assert error_code(stale_batch) == "KEY_EPOCH_OUTDATED"

    membership_response = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/membership?from=0", token=token
    )
    assert membership_response.status == 200
    chain = membership_response.json().get("manifests")
    assert isinstance(chain, list) and [entry["membership_version"] for entry in chain] == [1, 2]
    rotated_entry = chain[1]
    assert verify_ed25519(
        account["signing_public_key"],
        jcs(membership_fields),
        rotated_entry["signature"],
    ), "the stored epoch transition must retain a verifiable owner signature"

    vault_response = api.request("GET", "/api/v1/vaults", token=token)
    assert vault_response.status == 200
    rotated_vault = next(v for v in vault_response.json()["vaults"] if v["vault_id"] == vault_id)
    assert rotated_vault["active_key_epoch"] == next_epoch
    assert rotated_vault["membership_version"] == next_version
    historical = rotated_vault["key_envelopes"]
    assert {(item["key_epoch"], item["membership_version"]) for item in historical} == {(1, 1), (2, 2)}
    assert all(item["recipient_device_id"] == account["device_id"] for item in historical)
    for item in historical:
        signed = {
            "vault_id": vault_id,
            "recipient_device_id": item["recipient_device_id"],
            "key_epoch": item["key_epoch"],
            "membership_version": item["membership_version"],
            "envelope": item["envelope"],
        }
        assert item["signer_device_id"] == account["device_id"]
        assert verify_ed25519(account["signing_public_key"], jcs(signed), item["signature"])

    sibling_signer = SigningKey(tmp_path, "post-rotation-sibling")
    sibling_id = str(uuid.uuid4())
    sibling_encryption_key = b64url(os.urandom(32))
    device_fields = {
        "device_id": sibling_id,
        "encryption_public_key": sibling_encryption_key,
        "signing_public_key": b64url(sibling_signer.public_key),
    }
    new_device = {
        **device_fields,
        "name": "pytest-post-rotation",
        "signature": b64url(
            sibling_signer.sign(jcs({"account_id": account["account_id"], **device_fields}))
        ),
    }
    envelope_wrappers = []
    for source in historical:
        unsigned = {
            "vault_id": vault_id,
            "recipient_device_id": sibling_id,
            "key_epoch": source["key_epoch"],
            "membership_version": source["membership_version"],
            "envelope": {
                "version": 1,
                "suite": "crypto_box_seal",
                "ciphertext": b64url(os.urandom(48)),
            },
        }
        envelope_wrappers.append({**unsigned, "signature": b64url(signer.sign(jcs(unsigned)))})
    certificate_signature = b64url(
        signer.sign(
            jcs(
                {
                    "account_id": account["account_id"],
                    "approver_device_id": account["device_id"],
                    "device": new_device,
                }
            )
        )
    )
    enrollment = {
        "device": new_device,
        "approver_device_id": account["device_id"],
        "certificate_signature": certificate_signature,
        "vault_key_envelopes": envelope_wrappers,
    }
    incomplete = api.request(
        "POST",
        "/api/v1/devices",
        token=token,
        json_body={**enrollment, "vault_key_envelopes": envelope_wrappers[:1]},
    )
    assert incomplete.status == 422
    assert error_code(incomplete) == "INVALID_ENVELOPE"
    enrolled = api.request("POST", "/api/v1/devices", token=token, json_body=enrollment)
    assert enrolled.status in (200, 201), f"device enrollment returned {enrolled.status}: {enrolled.json()}"
    assert enrolled.json().get("vault_key_envelope_count") == 2

    login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": sibling_id,
        },
    )
    assert login.status == 200, f"new-device login returned {login.status}: {login.json()}"
    new_token = login.json()["access_token"]
    new_me = api.request("GET", "/api/v1/me", token=new_token)
    assert new_me.status == 200 and new_me.json().get("account_id") == account["account_id"]
    listed = api.request("GET", "/api/v1/vaults", token=new_token)
    assert listed.status == 200
    sibling_vault = next(v for v in listed.json()["vaults"] if v["vault_id"] == vault_id)
    sibling_keys = sibling_vault["key_envelopes"]
    assert {(item["key_epoch"], item["membership_version"]) for item in sibling_keys} == {(1, 1), (2, 2)}
    assert all(item["recipient_device_id"] == sibling_id for item in sibling_keys)
    owner_device = next(
        device
        for device in api.request("GET", "/api/v1/devices", token=token).json()["devices"]
        if device["device_id"] == account["device_id"]
    )
    for item in sibling_keys:
        signed = {
            "vault_id": vault_id,
            "recipient_device_id": item["recipient_device_id"],
            "key_epoch": item["key_epoch"],
            "membership_version": item["membership_version"],
            "envelope": item["envelope"],
        }
        assert item["signer_device_id"] == account["device_id"]
        assert verify_ed25519(owner_device["signing_public_key"], jcs(signed), item["signature"])

    # Later cases share this fixture account. Keep envelope helpers aligned
    # with the just-committed epoch after IT-15's deliberate stale-write check.
    account["vault"]["active_key_epoch"] = next_epoch
    account["vault"]["membership_version"] = next_version


def test_vault_create_list_delete_and_snapshot_read_during_grace(api: ApiClient, account: dict) -> None:
    """IT-16: deletion starts a grace period; authorized data stays readable."""
    created_vault = initial_vault(
        account_id=account["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=account["device_id"],
        encryption_public_key=account["encryption_public_key"],
        signer=account["signing_key"],
    )
    body = {
        "vault_id": created_vault["vault_id"],
        "name_envelope": created_vault["name_envelope"],
        "key_envelope": created_vault["key_envelope"],
        "membership": created_vault["membership"],
    }
    response = api.request("POST", "/api/v1/vaults", token=account["access_token"], json_body=body)
    assert response.status in (200, 201), f"vault create returned {response.status}: {response.json()}"
    created_id = response.json().get("vault_id")
    assert created_id == created_vault["vault_id"]
    assert response.json().get("role") == "owner"
    assert response.json().get("active_key_epoch") == 1

    listed = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert listed.status == 200
    created_item = next(v for v in listed.json()["vaults"] if v["vault_id"] == created_id)
    assert created_item["name_envelope"] == created_vault["name_envelope"]
    assert created_item["key_envelopes"][0]["envelope"] == created_vault["key_envelope"]["envelope"]

    snapshot_response = api.request(
        "POST",
        f"/api/v1/vaults/{created_id}/snapshots",
        token=account["access_token"],
    )
    assert snapshot_response.status in (200, 201), (
        f"snapshot create returned {snapshot_response.status}: {snapshot_response.json()}"
    )
    snapshot_id = snapshot_response.json()["snapshot_id"]

    deleted = api.request(
        "DELETE",
        f"/api/v1/vaults/{created_id}",
        token=account["access_token"],
        json_body={"login_verifier": account["login_verifier"]},
    )
    assert deleted.status in (200, 202), f"vault delete returned {deleted.status}: {deleted.json()}"
    delete_body = deleted.json()
    assert delete_body.get("status") == "deleting"
    assert delete_body.get("requested_at") and delete_body.get("purge_after")
    assert delete_body.get("can_cancel") is True
    assert delete_body.get("can_write") is False
    after_delete = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert after_delete.status == 200
    deleting_vault = next(
        item for item in after_delete.json()["vaults"] if item["vault_id"] == created_id
    )
    assert deleting_vault["status"] == "deleting"
    assert deleting_vault["can_cancel"] is True and deleting_vault["can_write"] is False
    retained_snapshot = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=account["access_token"]
    )
    assert retained_snapshot.status == 200, (
        "an authorized member must read a retained snapshot during the deletion grace period"
    )
    changes = api.request(
        "GET", f"/api/v1/vaults/{created_id}/changes?limit=1", token=account["access_token"]
    )
    assert changes.status == 200, "authorized members retain read access during deletion grace"

    # This suite-scoped account is reused by later modules. End the lifecycle
    # fixture in its original active state after asserting all grace-period
    # read behavior, so unrelated tests can enroll devices normally.
    cancelled = api.request(
        "POST",
        f"/api/v1/vaults/{created_id}/deletion/cancel",
        token=account["access_token"],
        json_body={"login_verifier": account["login_verifier"]},
    )
    assert cancelled.status == 200, (
        f"vault deletion cleanup returned {cancelled.status}: {cancelled.json()}"
    )
    assert cancelled.json().get("status") == "active"


def _assert_security_headers(response, cache_control: str) -> None:
    headers = response.headers
    csp = headers.get("Content-Security-Policy", "")
    assert "default-src 'none'" in csp
    assert "script-src 'self' 'wasm-unsafe-eval'" in csp
    assert "frame-ancestors 'none'" in csp
    assert headers.get("X-Content-Type-Options") == "nosniff"
    assert headers.get("X-Frame-Options") == "DENY"
    assert headers.get("Referrer-Policy") == "no-referrer"
    assert headers.get("Permissions-Policy") == "camera=(), geolocation=(), microphone=(), payment=()"
    assert headers.get("Cache-Control") == cache_control


def test_relay_disabled_static_assets_spa_and_api_404(api: ApiClient, instance: dict, account: dict) -> None:
    api_instance = api.request("GET", "/api/v1/instance")
    assert api_instance.status == 200
    _assert_security_headers(api_instance, "no-store")

    if "relay" not in instance.get("capabilities", []):
        relay = api.request(
            "POST",
            "/api/v1/relay/tickets",
            token=account["access_token"],
            json_body={
                "device_id": account["device_id"],
                "target_host": "203.0.113.1",
                "target_port": 22,
            },
        )
        assert relay.status == 503, f"disabled relay returned {relay.status}: {relay.json()}"
        assert error_code(relay) == "RELAY_DISABLED"

    if "web_static" not in instance.get("capabilities", []):
        pytest.skip("server was started without a static web directory; Flutter Web bundle acceptance is pending")

    home = api.request("GET", "/")
    assert home.status == 200, f"web root returned {home.status}: {home.body[:300]!r}"
    assert home.headers.get_content_type() == "text/html"
    _assert_security_headers(home, "no-cache")
    html = home.body.decode("utf-8", errors="replace")
    if getattr(api, "synthetic_web_fixture", False):
        assert "static-handler-fixture" in html
        asset_path = "/fixture.js"
    else:
        root = getattr(api, "web_root", None)
        if root:
            expected_flutter_assets = {
                "/main.dart.js": {"text/javascript", "application/javascript"},
                "/drift_worker.js": {"text/javascript", "application/javascript"},
                "/sqlite3.wasm": {"application/wasm"},
            }
            for path, expected_types in expected_flutter_assets.items():
                local_path = root / path.lstrip("/")
                assert local_path.is_file(), f"compiled Flutter Web asset is missing: {local_path}"
                served = api.request("GET", path)
                assert served.status == 200, f"compiled Flutter Web asset {path} returned {served.status}"
                assert served.body, f"compiled Flutter Web asset {path} was empty"
                assert served.headers.get_content_type() in expected_types, (
                    f"compiled Flutter Web asset {path} had MIME {served.headers.get_content_type()}"
                )
                if path == "/main.dart.js":
                    _assert_security_headers(served, "no-cache")
            asset_path = "/main.dart.js"
        else:
            referenced = re.search(r'''(?:src|href)=["']([^"']+\.js(?:\?[^"']*)?)["']''', html)
            asset_path = referenced.group(1).split("?", 1)[0] if referenced else ""
            if asset_path and not asset_path.startswith("/"):
                asset_path = "/" + asset_path
        assert asset_path, "Web index did not include or contain a JavaScript asset to verify"

    asset = api.request("GET", urllib.parse.quote(asset_path, safe="/:"))
    assert asset.status == 200, f"static JavaScript asset {asset_path} returned {asset.status}"
    assert asset.headers.get_content_type() in {"text/javascript", "application/javascript"}
    if asset_path == "/fixture.js":
        _assert_security_headers(asset, "no-cache")

    deep_link = api.request("GET", "/acceptance/settings/hosts")
    assert deep_link.status == 200
    assert deep_link.body == home.body, "extensionless client route must fall back to the SPA index"

    missing_asset = api.request("GET", "/acceptance-missing-asset.js")
    assert missing_asset.status == 404
    unknown_api = api.request("GET", "/api/v1/acceptance-missing-route")
    assert unknown_api.status == 404
    assert unknown_api.headers.get_content_type() == "application/json"
    assert unknown_api.json() is not None, "unknown API routes must return a JSON 404, not the SPA shell"

    openapi = api.request("GET", "/api/v1/openapi.yaml")
    assert openapi.status == 200
    assert openapi.headers.get_content_type() in {"application/yaml", "text/yaml"}
    assert b"openapi:" in openapi.body[:200]


def _new_account_registration(
    account_id: str,
    username: str,
    device_id: str,
    encryption_public_key: str,
    signer: SigningKey,
) -> dict:
    signing_public_key = b64url(signer.public_key)
    device_fields = {
        "device_id": device_id,
        "encryption_public_key": encryption_public_key,
        "signing_public_key": signing_public_key,
    }
    return {
        "account_id": account_id,
        "username": username,
        "kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": b64url(os.urandom(32)),
        "account_key_envelope": {
            "version": 1,
            "nonce": b64url(os.urandom(24)),
            "ciphertext": b64url(os.urandom(48)),
        },
        "device": {
            **device_fields,
            "name": "pytest-invited-account",
            "signature": b64url(
                signer.sign(
                    jcs(
                        {
                            "account_id": account_id,
                            "device_id": device_id,
                            "signing_public_key": signing_public_key,
                            "encryption_public_key": encryption_public_key,
                        }
                    )
                )
            ),
        },
        "initial_vault": initial_vault(
            account_id=account_id,
            vault_id=str(uuid.uuid4()),
            device_id=device_id,
            encryption_public_key=encryption_public_key,
            signer=signer,
        ),
    }


def _membership_member(account_id: str, role: str, encryption_public_key: str) -> dict:
    return {
        "user_id": account_id,
        "role": role,
        "state": "active",
        "encryption_key_fingerprint": b64url(
            hashlib.sha256(unb64url(encryption_public_key)).digest()
        ),
    }


def _signed_membership(
    vault_id: str,
    version: int,
    previous_digest: str | None,
    epoch: int,
    members: list[dict],
    signer_device_id: str,
    signer: SigningKey,
    display_name_envelope: dict | None = None,
) -> dict:
    manifest = {
        "key_epoch": epoch,
        "members": members,
        "signer_device_id": signer_device_id,
    }
    if display_name_envelope is not None:
        manifest["display_name_envelope"] = display_name_envelope
    unsigned = {
        "membership_version": version,
        "previous_digest": previous_digest,
        "manifest": manifest,
    }
    payload = {"vault_id": vault_id, **unsigned}
    return {**unsigned, "signature": b64url(signer.sign(jcs(payload)))}


def _membership_digest(vault_id: str, membership: dict) -> str:
    return hashlib.sha256(
        jcs(
            {
                "vault_id": vault_id,
                "membership_version": membership["membership_version"],
                "previous_digest": membership["previous_digest"],
                "manifest": membership["manifest"],
            }
        )
    ).hexdigest()


def _signed_key_envelope(
    vault_id: str,
    device_id: str,
    epoch: int,
    version: int,
    signer: SigningKey,
) -> dict:
    unsigned = {
        "recipient_device_id": device_id,
        "key_epoch": epoch,
        "membership_version": version,
        "envelope": {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        },
    }
    return {
        **unsigned,
        "signature": b64url(signer.sign(jcs({"vault_id": vault_id, **unsigned}))),
    }


def _issue_account_invitation(api: ApiClient, username: str) -> str:
    if not api.admin_env or not api.temp_root:
        pytest.skip("IT-18 requires the suite-owned temporary database to issue an operator invitation")
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), "create-account-invite", "--username", username]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            "create-account-invite",
            "--username",
            username,
        ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        safe_output = redact_secrets(result.stdout + "\n" + result.stderr)
        pytest.fail(f"operator account-invitation command failed: {safe_output[-3000:]}")
    match = re.search(r"(?m)^([A-Za-z0-9_-]{40,})\s*$", result.stdout)
    assert match, "account-invitation CLI did not print its one-time token on a separate line"
    return match.group(1)


def _run_server_cli(
    api: ApiClient, arguments: list[str], *, env_overrides: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    if not api.admin_env or not api.temp_root:
        pytest.skip("operator CLI acceptance requires the suite-owned temporary database")
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), *arguments]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            *arguments,
        ]
    env = api.admin_env.copy()
    if env_overrides:
        env.update(env_overrides)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return result


def test_operator_account_invite_and_cross_account_vault_invite(
    api: ApiClient, account: dict, tmp_path
) -> None:
    """IT-18: operator enrollment and owner-authorized sharing remain separate grants."""
    if not api.admin_env or not api.temp_root:
        pytest.skip("IT-18 requires a suite-started server and its disposable database")

    normalized_username = f"it18-enroll-{uuid.uuid4().hex[:10]}@example.test"
    raw_username = f"  {normalized_username.upper()}  "
    superseded_username = f"it18-reissue-{uuid.uuid4().hex[:10]}@example.test"
    superseded_raw_username = f"  {superseded_username.upper()}  "
    superseded_token = _issue_account_invitation(api, superseded_raw_username)
    _issue_account_invitation(api, superseded_raw_username)
    enrollment_token = _issue_account_invitation(api, raw_username)
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    second_signer = SigningKey(tmp_path, "it18-second-account")
    registration = _new_account_registration(
        account_id, raw_username, device_id, encryption_public_key, second_signer
    )

    no_token = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={**registration, "username": f"it18-no-token-{uuid.uuid4().hex[:8]}@example.test"},
    )
    assert no_token.status == 403 and error_code(no_token) == "ACCOUNT_INVITATION_REQUIRED"

    invalid_token = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "username": f"it18-invalid-token-{uuid.uuid4().hex[:8]}@example.test",
            "instance_invitation_token": b64url(os.urandom(32)),
        },
    )
    assert invalid_token.status == 401 and error_code(invalid_token) == "ACCOUNT_INVITATION_INVALID"

    wrong_username = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "username": f"other-{uuid.uuid4().hex[:8]}@example.test",
            "instance_invitation_token": enrollment_token,
        },
    )
    assert wrong_username.status == 401 and error_code(wrong_username) == "ACCOUNT_INVITATION_INVALID"

    superseded = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "username": superseded_raw_username,
            "instance_invitation_token": superseded_token,
        },
    )
    assert superseded.status == 401 and error_code(superseded) == "ACCOUNT_INVITATION_INVALID"

    duplicate_vault = initial_vault(
        account_id=account_id,
        vault_id=account["vault_id"],
        device_id=device_id,
        encryption_public_key=encryption_public_key,
        signer=second_signer,
    )
    rolled_back = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "initial_vault": duplicate_vault,
            "instance_invitation_token": enrollment_token,
        },
    )
    assert rolled_back.status == 409 and error_code(rolled_back) == "VAULT_EXISTS", (
        "a failure after invitation validation must not consume the account token"
    )

    registered = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={**registration, "instance_invitation_token": enrollment_token},
    )
    assert registered.status in (200, 201), (
        f"valid username-bound account invitation returned HTTP {registered.status}: "
        f"{error_code(registered)}"
    )
    second = {
        "account_id": account_id,
        "device_id": device_id,
        "username": normalized_username,
        "login_verifier": registration["login_verifier"],
        "access_token": registered.json()["access_token"],
        "vault_id": registration["initial_vault"]["vault_id"],
        "encryption_public_key": encryption_public_key,
        "signing_key": second_signer,
    }
    assert registered.json()["account_id"] == account_id
    second_vaults = api.request("GET", "/api/v1/vaults", token=second["access_token"])
    assert second_vaults.status == 200
    assert vault_ids(second_vaults.json()) == {second["vault_id"]}, (
        "operator account invitation should create only the new account's personal vault"
    )

    replay = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={**registration, "instance_invitation_token": enrollment_token},
    )
    assert replay.status == 401 and error_code(replay) == "ACCOUNT_INVITATION_INVALID"

    owner_token = account["access_token"]
    owner_private_vault = account["vault_id"]
    owner_signer = account["signing_key"]
    shared = initial_vault(
        account_id=account["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=account["device_id"],
        encryption_public_key=account["encryption_public_key"],
        signer=owner_signer,
    )
    create_shared = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner_token,
        json_body={
            "vault_id": shared["vault_id"],
            "name_envelope": shared["name_envelope"],
            "key_envelope": shared["key_envelope"],
            "membership": shared["membership"],
        },
    )
    assert create_shared.status in (200, 201), f"shared vault create failed: {error_code(create_shared)}"
    shared_id = shared["vault_id"]
    genesis_digest = _membership_digest(shared_id, shared["membership"])
    owner_member = _membership_member(
        account["account_id"], "owner", account["encryption_public_key"]
    )
    invitee_member = _membership_member(
        second["account_id"], "editor", second["encryption_public_key"]
    )

    invite_membership = _signed_membership(
        shared_id,
        2,
        genesis_digest,
        1,
        [owner_member, invitee_member],
        account["device_id"],
        owner_signer,
    )
    invite_envelope = _signed_key_envelope(
        shared_id, second["device_id"], 1, 2, owner_signer
    )
    invitation_body = {
        "role": "editor",
        "recipient_device_id": second["device_id"],
        "recipient_encryption_public_key": second["encryption_public_key"],
        "key_envelope": invite_envelope,
        "membership": invite_membership,
    }
    wrong_recipient_key = api.request(
        "POST",
        f"/api/v1/vaults/{shared_id}/invitations",
        token=owner_token,
        json_body={
            **invitation_body,
            "recipient_encryption_public_key": b64url(os.urandom(32)),
        },
    )
    assert wrong_recipient_key.status == 422
    assert error_code(wrong_recipient_key) == "INVALID_ENVELOPE"

    bad_fingerprint_member = {
        **invitee_member,
        "encryption_key_fingerprint": b64url(os.urandom(32)),
    }
    bad_fingerprint_membership = _signed_membership(
        shared_id,
        2,
        genesis_digest,
        1,
        [owner_member, bad_fingerprint_member],
        account["device_id"],
        owner_signer,
    )
    wrong_manifest_fingerprint = api.request(
        "POST",
        f"/api/v1/vaults/{shared_id}/invitations",
        token=owner_token,
        json_body={**invitation_body, "membership": bad_fingerprint_membership},
    )
    assert wrong_manifest_fingerprint.status == 422
    assert error_code(wrong_manifest_fingerprint) == "INVALID_ENVELOPE"

    unchanged_vaults = api.request("GET", "/api/v1/vaults", token=owner_token)
    unchanged_shared = next(
        item for item in unchanged_vaults.json()["vaults"] if item["vault_id"] == shared_id
    )
    assert unchanged_shared["membership_version"] == 1
    unchanged_members = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/members", token=owner_token
    )
    assert all(
        member["user_id"] != second["account_id"]
        for member in unchanged_members.json()["members"]
    ), "invalid recipient public key/fingerprint must not create an ACL row"
    unchanged_chain = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/membership?from=0", token=owner_token
    )
    assert [entry["membership_version"] for entry in unchanged_chain.json()["manifests"]] == [1]

    issued = api.request(
        "POST",
        f"/api/v1/vaults/{shared_id}/invitations",
        token=owner_token,
        json_body=invitation_body,
    )
    assert issued.status in (200, 201), f"vault invitation failed: {error_code(issued)}"
    stale_token = issued.json()["token"]
    stale_invitation_id = issued.json()["invitation_id"]

    owner_members = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/members", token=owner_token
    )
    invited_member = next(
        member for member in owner_members.json()["members"] if member["user_id"] == second["account_id"]
    )
    assert invited_member["state"] == "invited", "signed grant must not activate ACL before token acceptance"
    assert shared_id not in vault_ids(
        api.request("GET", "/api/v1/vaults", token=second["access_token"]).json()
    )
    for path in (
        f"/api/v1/vaults/{shared_id}/members",
        f"/api/v1/vaults/{shared_id}/devices",
        f"/api/v1/vaults/{shared_id}/changes?limit=1",
    ):
        denied = api.request("GET", path, token=second["access_token"])
        assert denied.status in (403, 404), f"pending invite exposed {path} with HTTP {denied.status}"
    for foreign_vault in (owner_private_vault,):
        denied = api.request(
            "GET",
            f"/api/v1/vaults/{foreign_vault}/changes?limit=1",
            token=second["access_token"],
        )
        assert denied.status in (403, 404), "an enrolled account must not enumerate another account's known vault ID"

    rotation_name_envelope = {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(48)),
    }
    rotation_membership = _signed_membership(
        shared_id,
        3,
        _membership_digest(shared_id, invite_membership),
        2,
        [owner_member, invitee_member],
        account["device_id"],
        owner_signer,
        display_name_envelope=rotation_name_envelope,
    )
    active_owner_devices_response = api.request(
        "GET", "/api/v1/devices", token=owner_token
    )
    assert active_owner_devices_response.status == 200
    active_owner_devices = [
        device["device_id"]
        for device in active_owner_devices_response.json()["devices"]
        if device.get("status") == "active"
    ]
    assert account["device_id"] in active_owner_devices
    rotation_envelopes = []
    for recipient_device_id in sorted(set(active_owner_devices + [second["device_id"]])):
        item = _signed_key_envelope(
            shared_id, recipient_device_id, 2, 3, owner_signer
        )
        rotation_envelopes.append({**item, "signer_device_id": account["device_id"]})
    rotated = api.request(
        "POST",
        f"/api/v1/vaults/{shared_id}/keys/rotate",
        token=owner_token,
        json_body={
            "new_epoch": 2,
            "membership": rotation_membership,
            "key_envelopes": rotation_envelopes,
        },
    )
    assert rotated.status in (200, 201), f"rotation with pending member failed: {error_code(rotated)}"
    rotation_vaults = api.request("GET", "/api/v1/vaults", token=owner_token)
    assert rotation_vaults.status == 200
    rotated_shared = next(
        item for item in rotation_vaults.json()["vaults"] if item["vault_id"] == shared_id
    )
    assert rotated_shared["name_envelope"] == rotation_name_envelope
    stale_member_page = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/members", token=owner_token
    )
    stale_member = next(
        member for member in stale_member_page.json()["members"]
        if member["user_id"] == second["account_id"]
    )
    assert stale_member["state"] == "invited"
    assert stale_member["invitation"]["status"] == "stale"
    stale_accept = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=second["access_token"],
        json_body={"token": stale_token},
    )
    assert stale_accept.status == 409 and error_code(stale_accept) == "INVITATION_STALE"

    fresh_membership = _signed_membership(
        shared_id,
        4,
        _membership_digest(shared_id, rotation_membership),
        2,
        [owner_member, invitee_member],
        account["device_id"],
        owner_signer,
    )
    fresh_envelope = _signed_key_envelope(
        shared_id, second["device_id"], 2, 4, owner_signer
    )
    fresh = api.request(
        "POST",
        f"/api/v1/vaults/{shared_id}/invitations",
        token=owner_token,
        json_body={
            "role": "editor",
            "recipient_device_id": second["device_id"],
            "recipient_encryption_public_key": second["encryption_public_key"],
            "key_envelope": fresh_envelope,
            "membership": fresh_membership,
        },
    )
    assert fresh.status in (200, 201), f"fresh post-rotation invitation failed: {error_code(fresh)}"
    fresh_token = fresh.json()["token"]

    # Force the two issuances to share the same timestamp. The monotonic
    # issuance order must still select the fresh invite, regardless of its
    # expiry or the invitation IDs' lexical ordering.
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://")
    database_path = Path(urllib.parse.unquote(database_url[len("sqlite://") :].split("?", 1)[0]))
    with sqlite3.connect(database_path) as connection:
        old_order, _old_created_at = connection.execute(
            "SELECT issuance_order,created_at FROM invitations WHERE invitation_id=?",
            (stale_invitation_id,),
        ).fetchone()
        fresh_order, tied_created_at = connection.execute(
            "SELECT issuance_order,created_at FROM invitations WHERE invitation_id=?",
            (fresh.json()["invitation_id"],),
        ).fetchone()
        assert fresh_order > old_order
        connection.execute(
            "UPDATE invitations SET created_at=?,expires_at='2099-01-01T00:00:00+00:00' WHERE invitation_id=?",
            (tied_created_at, stale_invitation_id),
        )
        connection.execute(
            "UPDATE invitations SET created_at=? WHERE invitation_id=?",
            (tied_created_at, fresh.json()["invitation_id"]),
        )
        connection.commit()
    current_member_page = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/members", token=owner_token
    )
    current_member = next(
        member for member in current_member_page.json()["members"]
        if member["user_id"] == second["account_id"]
    )
    assert current_member["invitation"] == {
        "status": "pending",
        "expires_at": fresh.json()["expires_at"],
    }
    assert set(current_member["invitation"]) == {"status", "expires_at"}

    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=second["access_token"],
        json_body={"token": fresh_token},
    )
    assert accepted.status in (200, 201), f"vault invitation acceptance failed: {error_code(accepted)}"
    assert accepted.json().get("status") == "accepted"
    replay_vault_invite = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=second["access_token"],
        json_body={"token": fresh_token},
    )
    assert replay_vault_invite.status == 409 and error_code(replay_vault_invite) == "INVITATION_USED"

    accepted_vaults = api.request("GET", "/api/v1/vaults", token=second["access_token"])
    assert accepted_vaults.status == 200
    shared_item = next(v for v in accepted_vaults.json()["vaults"] if v["vault_id"] == shared_id)
    assert shared_item["role"] == "editor"
    accepted_envelope = next(
        item
        for item in shared_item["key_envelopes"]
        if item["recipient_device_id"] == second["device_id"]
        and item["key_epoch"] == 2
        and item["membership_version"] == 4
    )
    assert accepted_envelope["envelope"] == fresh_envelope["envelope"]
    assert accepted_envelope["signature"] == fresh_envelope["signature"]
    assert accepted_envelope["signer_device_id"] == account["device_id"]
    owner_devices = api.request(
        "GET", f"/api/v1/vaults/{shared_id}/devices", token=second["access_token"]
    )
    assert owner_devices.status == 200
    owner_public_key = next(
        device["signing_public_key"]
        for device in owner_devices.json()["devices"]
        if device["device_id"] == account["device_id"]
    )
    signature_payload = {
        "vault_id": shared_id,
        "recipient_device_id": second["device_id"],
        "key_epoch": 2,
        "membership_version": 4,
        "envelope": fresh_envelope["envelope"],
    }
    assert verify_ed25519(owner_public_key, jcs(signature_payload), accepted_envelope["signature"])

    owner_private_access = api.request(
        "GET",
        f"/api/v1/vaults/{owner_private_vault}/changes?limit=1",
        token=second["access_token"],
    )
    assert owner_private_access.status in (403, 404), "sharing one vault must not expose owner's private vault"
    second_private_access = api.request(
        "GET",
        f"/api/v1/vaults/{second['vault_id']}/changes?limit=1",
        token=owner_token,
    )
    assert second_private_access.status in (403, 404), "account enrollment must not grant owner access to the recipient's vault"


def test_cursor_retention_snapshot_rebuild_and_generation_recovery(
    api: ApiClient, account: dict, instance: dict, make_envelope, push
) -> None:
    """IT-19: old history fails closed and clients recover without losing heads/outbox."""
    if not api.admin_env or not api.temp_root:
        pytest.skip("IT-19 requires a suite-owned server and a disposable SQLite database")

    vault_id = account["vault_id"]
    token = account["access_token"]
    old_generation = instance["generation"]
    before = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/changes?limit=500", token=token
    )
    assert before.status == 200, f"initial pull failed: {error_code(before)}"
    old_cursor = before.json()["next_cursor"]

    record_id = str(uuid.uuid4())
    created = push(make_envelope(record_id=record_id, operation="create"))
    assert created.status in (200, 201), f"retention fixture write failed: {error_code(created)}"

    database_url = api.admin_env["ATERMIUS_DATABASE_URL"]
    assert database_url.startswith("sqlite://"), "IT-19 requires its disposable SQLite database"
    database_path = database_url.removeprefix("sqlite://").split("?", 1)[0]
    assert database_path
    old_timestamp = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    with sqlite3.connect(database_path) as database:
        aged = database.execute(
            "UPDATE change_events SET created_at=? WHERE vault_id=?",
            (old_timestamp, vault_id),
        )
        assert aged.rowcount > 0, "deterministic retention setup did not age a committed event"

    maintenance = _run_server_cli(
        api, ["maintenance"], env_overrides={"ATERMIUS_HISTORY_RETENTION_DAYS": "1"}
    )
    if maintenance.returncode != 0:
        output = redact_secrets(maintenance.stdout + "\n" + maintenance.stderr)
        pytest.fail(f"history maintenance command failed: {output[-3000:]}")

    expired = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/changes?cursor={urllib.parse.quote(old_cursor, safe='')}&limit=10",
        token=token,
    )
    assert expired.status == 410 and error_code(expired) == "CURSOR_EXPIRED"
    recovery_details = (expired.json().get("error") or {}).get("details") or {}
    assert recovery_details.get("recovery") == "create_snapshot"
    assert recovery_details.get("preserve_local_outbox") is True

    snapshot_created = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=token
    )
    assert snapshot_created.status in (200, 201), (
        f"retention recovery snapshot failed: {error_code(snapshot_created)}"
    )
    snapshot_id = snapshot_created.json()["snapshot_id"]
    snapshot = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=token
    )
    assert snapshot.status == 200, f"snapshot rebuild fetch failed: {error_code(snapshot)}"
    manifest = snapshot.json().get("manifest")
    assert isinstance(manifest, list)
    assert any(entry.get("record_id") == record_id for entry in manifest), (
        "compaction must retain current record heads for snapshot rebuild"
    )
    usable_cursor = snapshot.json().get("next_cursor") or snapshot_created.json().get("next_cursor")
    assert usable_cursor, "snapshot recovery response must return a pull cursor"
    resumed = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/changes?cursor={urllib.parse.quote(usable_cursor, safe='')}&limit=10",
        token=token,
    )
    assert resumed.status == 200 and resumed.json().get("events") == []
    old_generation_snapshot_id = snapshot_id

    recovery_while_running = _run_server_cli(api, ["recover-generation", "--server-stopped"])
    assert recovery_while_running.returncode != 0
    running_error = redact_secrets(recovery_while_running.stdout + "\n" + recovery_while_running.stderr)
    assert "SERVER_RUNNING" in running_error, "generation recovery must refuse to run under a live server lock"

    api.stop_managed_server()
    recovery = _run_server_cli(api, ["recover-generation", "--server-stopped"])
    if recovery.returncode != 0:
        output = redact_secrets(recovery.stdout + "\n" + recovery.stderr)
        pytest.fail(f"offline generation recovery command failed: {output[-3000:]}")
    api.start_managed_server()

    current_instance = api.request("GET", "/api/v1/instance")
    assert current_instance.status == 200
    assert current_instance.json()["generation"] != old_generation
    stale_generation_cursor = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/changes?cursor={urllib.parse.quote(usable_cursor, safe='')}&limit=10",
        token=token,
    )
    assert stale_generation_cursor.status == 410
    assert error_code(stale_generation_cursor) == "CURSOR_EXPIRED"
    stale_details = (stale_generation_cursor.json().get("error") or {}).get("details") or {}
    assert stale_details.get("recovery") == "create_snapshot"
    assert stale_details.get("preserve_local_outbox") is True

    invalidated_snapshot = api.request(
        "GET", f"/api/v1/snapshots/{old_generation_snapshot_id}", token=token
    )
    assert invalidated_snapshot.status == 410
    assert error_code(invalidated_snapshot) == "SNAPSHOT_EXPIRED"

    rebuilt = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=token
    )
    assert rebuilt.status in (200, 201), f"post-recovery snapshot failed: {error_code(rebuilt)}"
    rebuilt_snapshot = api.request(
        "GET", f"/api/v1/snapshots/{rebuilt.json()['snapshot_id']}", token=token
    )
    assert rebuilt_snapshot.status == 200
    assert any(
        entry.get("record_id") == record_id
        for entry in rebuilt_snapshot.json().get("manifest", [])
    ), "generation recovery must preserve current record heads"
    rebuilt_cursor = rebuilt_snapshot.json().get("next_cursor") or rebuilt.json().get("next_cursor")
    assert rebuilt_cursor
    rebuilt_pull = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/changes?cursor={urllib.parse.quote(rebuilt_cursor, safe='')}&limit=10",
        token=token,
    )
    assert rebuilt_pull.status == 200 and rebuilt_pull.json().get("events") == []


def test_auth_enumeration_resistance_and_rate_limits(api: ApiClient, tmp_path) -> None:
    """IT-20: decoy prelogin, uniform login failures and scoped throttling."""
    if not api.started_by_suite:
        pytest.skip("IT-20 requires the suite-owned compile fixture for its isolated low-limit service")
    executable = server_binary_path()
    if not executable.is_file():
        pytest.skip("IT-20 requires the debug binary built by the suite-owned server fixture")

    temp_root = tmp_path / "it20-rate-limits"
    data_dir = temp_root / "data"
    data_dir.mkdir(parents=True, mode=0o700)
    os.chmod(data_dir, 0o700)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = os.environ.copy()
    env.update(
        {
            "ATERMIUS_BIND": f"127.0.0.1:{port}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{data_dir / 'atermius.db'}?mode=rwc",
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "false",
            "ATERMIUS_AUTH_RATE_WINDOW_SECONDS": "3600",
            "ATERMIUS_AUTH_PRELOGIN_USER_LIMIT": "2",
            "ATERMIUS_AUTH_PRELOGIN_PAIR_LIMIT": "1000",
            "ATERMIUS_AUTH_PRELOGIN_IP_LIMIT": "100",
            "ATERMIUS_AUTH_LOGIN_USER_LIMIT": "10",
            "ATERMIUS_AUTH_LOGIN_PAIR_LIMIT": "2",
            "ATERMIUS_AUTH_LOGIN_IP_LIMIT": "100",
            "ATERMIUS_AUTH_REGISTER_USER_LIMIT": "10",
            "ATERMIUS_AUTH_REGISTER_PAIR_LIMIT": "2",
            "ATERMIUS_AUTH_REGISTER_IP_LIMIT": "10",
        }
    )
    bootstrap = subprocess.run(
        [str(executable), "bootstrap"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if bootstrap.returncode != 0:
        pytest.fail("IT-20 bootstrap failed: " + redact_secrets(bootstrap.stdout + bootstrap.stderr)[-2000:])
    bootstrap_tokens = re.findall(
        r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap.stdout
    )
    assert bootstrap_tokens, "IT-20 bootstrap CLI did not produce its one-time token"
    bootstrap_token = bootstrap_tokens[-1]
    del bootstrap, bootstrap_tokens

    web_root, _ = prepare_web_root(temp_root)
    env["ATERMIUS_WEB_DIR"] = str(web_root)
    server_log_path = temp_root / "server.log"
    log_handle = server_log_path.open("wb")
    server_process = subprocess.Popen(
        [str(executable), "serve"],
        cwd=ROOT,
        env=env,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    limited_api = ApiClient(f"http://127.0.0.1:{port}")

    def assert_rate_limited(response: Response) -> None:
        assert response.status == 429, f"expected HTTP 429, received {response.status}: {error_code(response)}"
        assert error_code(response) == "RATE_LIMITED"
        retry_after = response.headers.get("Retry-After")
        assert retry_after is not None and 1 <= int(retry_after) <= 3600

    registration: dict

    def register_without_enrollment(username: str) -> Response:
        body = {key: value for key, value in registration.items() if key != "bootstrap_token"}
        body["username"] = username
        return limited_api.request("POST", "/api/v1/auth/register", json_body=body)

    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if limited_api.request("GET", "/health/ready").status == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            if server_process.poll() is not None:
                log_handle.flush()
                detail = redact_secrets(server_log_path.read_text(errors="replace"), bootstrap_token)[-2000:]
                pytest.fail(f"IT-20 server exited during startup: {detail}")
            time.sleep(0.2)
        else:
            log_handle.flush()
            detail = redact_secrets(server_log_path.read_text(errors="replace"), bootstrap_token)[-2000:]
            pytest.fail(f"IT-20 server readiness timed out: {detail}")

        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        encryption_key = b64url(os.urandom(32))
        signer = SigningKey(tmp_path, "it20-known-account")
        known_username = f"it20-known-{uuid.uuid4().hex[:8]}@example.test"
        registration = _new_account_registration(
            account_id, known_username, device_id, encryption_key, signer
        )
        registration["bootstrap_token"] = bootstrap_token
        created = limited_api.request("POST", "/api/v1/auth/register", json_body=registration)
        assert created.status in (200, 201), (
            f"IT-20 first account registration returned {created.status}: {error_code(created)}"
        )
        del bootstrap_token

        decoy_username = f"it20-decoy-{uuid.uuid4().hex[:8]}@example.test"
        first_prelogin = limited_api.request(
            "POST", "/api/v1/auth/prelogin", json_body={"username": f"  {decoy_username.upper()}  "}
        )
        second_prelogin = limited_api.request(
            "POST", "/api/v1/auth/prelogin", json_body={"username": decoy_username}
        )
        assert first_prelogin.status == second_prelogin.status == 200
        assert first_prelogin.json().get("account_id") == second_prelogin.json().get("account_id")
        assert first_prelogin.json().get("kdf") == second_prelogin.json().get("kdf"), (
            "unknown-user prelogin must return stable account and KDF decoys for normalized usernames"
        )
        assert first_prelogin.json().get("account_id") != account_id
        blocked_prelogin = limited_api.request(
            "POST", "/api/v1/auth/prelogin", json_body={"username": f"{decoy_username.upper()} "}
        )
        assert_rate_limited(blocked_prelogin)

        bad_verifier = b64url(os.urandom(32))
        known_login = limited_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={"username": known_username, "login_verifier": bad_verifier, "device_id": device_id},
        )
        unknown_login_name = f"it20-unknown-login-{uuid.uuid4().hex[:8]}@example.test"
        unknown_login = limited_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": unknown_login_name,
                "login_verifier": bad_verifier,
                "device_id": str(uuid.uuid4()),
            },
        )
        assert known_login.status == unknown_login.status == 401
        known_error = (known_login.json() or {}).get("error", {})
        unknown_error = (unknown_login.json() or {}).get("error", {})
        assert known_error.keys() == unknown_error.keys()
        assert known_error.get("code") == unknown_error.get("code") == "AUTH_REQUIRED"
        assert known_error.get("message") == unknown_error.get("message")
        assert known_error.get("details") == unknown_error.get("details")

        # An exhausted prelogin bucket must not block the independent login or
        # registration buckets for the same normalized username.
        decoy_login = limited_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": decoy_username,
                "login_verifier": bad_verifier,
                "device_id": str(uuid.uuid4()),
            },
        )
        assert decoy_login.status == 401 and error_code(decoy_login) == "AUTH_REQUIRED"
        independent_register = register_without_enrollment(decoy_username)
        assert independent_register.status == 403
        assert error_code(independent_register) == "ACCOUNT_INVITATION_REQUIRED"

        pair_login_name = f"it20-login-pair-{uuid.uuid4().hex[:8]}@example.test"
        pair_login_body = {
            "username": pair_login_name,
            "login_verifier": bad_verifier,
            "device_id": str(uuid.uuid4()),
        }
        assert limited_api.request("POST", "/api/v1/auth/login", json_body=pair_login_body).status == 401
        assert limited_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={**pair_login_body, "username": f"  {pair_login_name.upper()}  "},
        ).status == 401
        pair_login_limited = limited_api.request(
            "POST", "/api/v1/auth/login", json_body=pair_login_body
        )
        assert_rate_limited(pair_login_limited)
        other_login = limited_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": f"it20-login-other-{uuid.uuid4().hex[:8]}@example.test",
                "login_verifier": bad_verifier,
                "device_id": str(uuid.uuid4()),
            },
        )
        assert other_login.status == 401, "a per-username+peer limit must not block a different username"

        pair_register_name = f"it20-register-pair-{uuid.uuid4().hex[:8]}@example.test"
        first_pair_register = register_without_enrollment(pair_register_name)
        second_pair_register = register_without_enrollment(f"  {pair_register_name.upper()}  ")
        assert first_pair_register.status == second_pair_register.status == 403
        assert error_code(first_pair_register) == error_code(second_pair_register) == "ACCOUNT_INVITATION_REQUIRED"
        pair_register_limited = register_without_enrollment(pair_register_name)
        assert_rate_limited(pair_register_limited)
        other_register = register_without_enrollment(
            f"it20-register-other-{uuid.uuid4().hex[:8]}@example.test"
        )
        assert other_register.status == 403 and error_code(other_register) == "ACCOUNT_INVITATION_REQUIRED"

        # Registration IP limit has a minimum of 10. Unique usernames bypass
        # user/pair limits and fill only the shared TCP-peer budget.
        for attempt in range(20):
            response = register_without_enrollment(
                f"it20-register-ip-{attempt}-{uuid.uuid4().hex[:6]}@example.test"
            )
            if response.status == 429:
                assert_rate_limited(response)
                break
            assert response.status == 403 and error_code(response) == "ACCOUNT_INVITATION_REQUIRED"
        else:
            pytest.fail("registration requests across distinct usernames did not hit the configured peer-IP limit")

        # Prelogin's IP limit has a minimum of 100. Count requests are unique
        # so they cannot hit the per-user or per-pair buckets first.
        prelogin_ip_limited = False
        for attempt in range(200):
            response = limited_api.request(
                "POST",
                "/api/v1/auth/prelogin",
                json_body={"username": f"it20-prelogin-ip-{attempt}-{uuid.uuid4().hex[:6]}@example.test"},
            )
            if response.status == 429:
                assert_rate_limited(response)
                prelogin_ip_limited = True
                break
            assert response.status == 200
        assert prelogin_ip_limited, "prelogin requests across distinct usernames did not hit the peer-IP limit"
    finally:
        try:
            os.killpg(server_process.pid, signal.SIGTERM)
        except (AttributeError, ProcessLookupError):
            server_process.terminate()
        try:
            server_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server_process.kill()
            server_process.wait(timeout=5)
        log_handle.close()
