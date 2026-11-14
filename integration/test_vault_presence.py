"""Black-box tests for authenticated, expiring Vault device presence leases."""

from __future__ import annotations

import hashlib
import sqlite3
import subprocess
import time
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from conftest import ROOT, ApiClient, initial_vault, server_binary_path
from test_acceptance import (
    _membership_digest,
    _membership_member,
    _signed_key_envelope,
    _signed_membership,
)
from test_vault_membership_rotation import (
    _display_name_envelope,
    _register_account,
    _rotation_envelopes,
    _signed_rotation_membership,
)


def _error_code(response) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _presence(api: ApiClient, vault_id: str, token: str | None):
    return api.request("GET", f"/api/v1/vaults/{vault_id}/presence", token=token)


def _heartbeat(api: ApiClient, vault_id: str, token: str | None):
    return api.request("POST", f"/api/v1/vaults/{vault_id}/presence", token=token)


def _database_path(api: ApiClient) -> str:
    database_url = (api.admin_env or {}).get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://"), (
        "expected a suite-owned SQLite database"
    )
    return database_url.removeprefix("sqlite://").split("?", 1)[0]


def _run_maintenance(api: ApiClient) -> subprocess.CompletedProcess[str]:
    if not api.admin_env:
        pytest.skip("presence cleanup assertions require the suite-owned server")
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), "maintenance"]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            "maintenance",
        ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env.copy(),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _seed_valid_sessions(api: ApiClient, account: dict, count: int) -> list[str]:
    """Create independent persisted bearer sessions for lease-cap coverage."""
    now = datetime.now(timezone.utc)
    created_at = now.isoformat()
    access_expires_at = (now + timedelta(minutes=10)).isoformat()
    refresh_expires_at = (now + timedelta(days=30)).isoformat()
    sessions: list[tuple[str, ...]] = []
    tokens: list[str] = []
    for _ in range(count):
        token = uuid.uuid4().hex + uuid.uuid4().hex
        refresh_token = uuid.uuid4().hex + uuid.uuid4().hex
        tokens.append(token)
        sessions.append(
            (
                str(uuid.uuid4()),
                account["account_id"],
                account["device_id"],
                str(uuid.uuid4()),
                hashlib.sha256(token.encode()).hexdigest(),
                hashlib.sha256(refresh_token.encode()).hexdigest(),
                access_expires_at,
                refresh_expires_at,
                created_at,
            )
        )
    with sqlite3.connect(_database_path(api)) as database:
        database.executemany(
            "INSERT INTO sessions(session_id,user_id,device_id,family_id,"
            "access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            sessions,
        )
    return tokens


def test_presence_leases_bind_sessions_membership_and_expiration(
    api: ApiClient, account: dict, tmp_path
) -> None:
    """Leases are authenticated, per-session, privacy-minimal and temporary."""
    # This fixture performs the one-time bootstrap before the test creates
    # additional accounts through operator-issued invitations.
    assert account["access_token"]
    owner = _register_account(api, tmp_path, "presence-owner")
    member = _register_account(api, tmp_path, "presence-member")
    vault_id = str(uuid.uuid4())

    shared = initial_vault(
        account_id=owner["account_id"],
        vault_id=vault_id,
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    created = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": vault_id,
            "name_envelope": shared["name_envelope"],
            "key_envelope": shared["key_envelope"],
            "membership": shared["membership"],
        },
    )
    assert created.status in (200, 201), (
        f"vault create failed: {_error_code(created)}"
    )

    # A session's heartbeat gate is Vault-scoped: a just-renewed profile can
    # switch immediately to a different authorized Vault.
    other_vault_id = str(uuid.uuid4())
    other_shared = initial_vault(
        account_id=owner["account_id"],
        vault_id=other_vault_id,
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    other_created = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": other_vault_id,
            "name_envelope": other_shared["name_envelope"],
            "key_envelope": other_shared["key_envelope"],
            "membership": other_shared["membership"],
        },
    )
    assert other_created.status in (200, 201), (
        f"second vault create failed: {_error_code(other_created)}"
    )

    assert _presence(api, vault_id, None).status == 401
    assert _heartbeat(api, vault_id, None).status == 401
    # A second account cannot create a lease or read a directory for a Vault
    # it has not joined, even when it supplies its own valid session.
    assert _presence(api, vault_id, member["access_token"]).status == 404
    assert _heartbeat(api, vault_id, member["access_token"]).status == 404

    forged = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/presence",
        token=owner["access_token"],
        json_body={
            "user_id": member["account_id"],
            "device_id": member["device_id"],
            "host": "ssh.example.test",
            "terminal": "do not store",
        },
    )
    assert forged.status == 400 and _error_code(forged) == (
        "PRESENCE_BODY_NOT_ALLOWED"
    )

    owner_heartbeat = _heartbeat(api, vault_id, owner["access_token"])
    assert owner_heartbeat.status == 200, (
        f"heartbeat failed: {_error_code(owner_heartbeat)}"
    )
    assert owner_heartbeat.json()["ttl_seconds"] == 90
    assert owner_heartbeat.json()["expires_at"].endswith("+00:00")
    switched_heartbeat = _heartbeat(api, other_vault_id, owner["access_token"])
    assert switched_heartbeat.status == 200, (
        "a distinct Vault heartbeat must have an independent rate gate: "
        f"{_error_code(switched_heartbeat)}"
    )
    owner_access_hash = hashlib.sha256(owner["access_token"].encode()).hexdigest()
    with sqlite3.connect(_database_path(api)) as database:
        owner_session_id = database.execute(
            "SELECT session_id FROM sessions WHERE access_hash=?",
            (owner_access_hash,),
        ).fetchone()[0]
        original_expiry_before_limit = database.execute(
            "SELECT expires_at FROM vault_presence WHERE vault_id=? AND session_id=?",
            (vault_id, owner_session_id),
        ).fetchone()[0]
        gate_rows = database.execute(
            "SELECT COUNT(*) FROM vault_presence_heartbeat_limits "
            "WHERE session_id=? AND vault_id IN (?,?)",
            (owner_session_id, vault_id, other_vault_id),
        ).fetchone()[0]
        assert gate_rows == 2
        # Use SQLite's clock to make the following same-Vault retry a stable
        # test of the five-second rate window, independent of setup latency.
        database.execute(
            "UPDATE vault_presence_heartbeat_limits "
            "SET last_heartbeat_at=CAST(strftime('%s','now') AS INTEGER) * 1000 "
            "WHERE vault_id=? AND session_id=?",
            (vault_id, owner_session_id),
        )
    limited_heartbeat = _heartbeat(api, vault_id, owner["access_token"])
    assert limited_heartbeat.status == 429
    assert _error_code(limited_heartbeat) == "PRESENCE_HEARTBEAT_RATE_LIMITED"
    assert limited_heartbeat.headers.get("Retry-After") == "5"
    with sqlite3.connect(_database_path(api)) as database:
        assert database.execute(
            "SELECT expires_at FROM vault_presence WHERE vault_id=? AND session_id=?",
            (vault_id, owner_session_id),
        ).fetchone()[0] == original_expiry_before_limit
        database.execute(
            "UPDATE vault_presence_heartbeat_limits SET last_heartbeat_at=? "
            "WHERE vault_id=? AND session_id=?",
            (time.time_ns() // 1_000_000 - 2_000, vault_id, owner_session_id),
        )
    still_limited = _heartbeat(api, vault_id, owner["access_token"])
    assert still_limited.status == 429
    assert _error_code(still_limited) == "PRESENCE_HEARTBEAT_RATE_LIMITED"
    with sqlite3.connect(_database_path(api)) as database:
        database.execute(
            "UPDATE vault_presence_heartbeat_limits SET last_heartbeat_at=? "
            "WHERE vault_id=? AND session_id=?",
            (time.time_ns() // 1_000_000 - 6_000, vault_id, owner_session_id),
        )
    elapsed_heartbeat = _heartbeat(api, vault_id, owner["access_token"])
    assert elapsed_heartbeat.status == 200, (
        "the same session should renew after the five-second gate: "
        f"{_error_code(elapsed_heartbeat)}"
    )
    limited_body = str(limited_heartbeat.json())
    assert owner["account_id"] not in limited_body
    assert owner["device_id"] not in limited_body
    assert vault_id not in limited_body
    owner_list = _presence(api, vault_id, owner["access_token"])
    assert owner_list.status == 200
    body = owner_list.json()
    assert set(body) == {"devices", "ttl_seconds"}
    assert body["ttl_seconds"] == 90
    assert len(body["devices"]) == 1
    assert body["devices"][0] == {
        "user_id": owner["account_id"],
        "device_id": owner["device_id"],
        "last_seen_at": body["devices"][0]["last_seen_at"],
    }
    assert vault_id not in body
    serialized = str(body).lower()
    for forbidden in (
        "host",
        "terminal",
        "ciphertext",
        "content",
        "token",
        "ip_address",
    ):
        assert forbidden not in serialized

    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    member_entry = _membership_member(
        member["account_id"], "viewer", member["encryption_public_key"]
    )
    invitation_membership = _signed_membership(
        vault_id,
        2,
        _membership_digest(vault_id, shared["membership"]),
        1,
        [owner_member, member_entry],
        owner["device_id"],
        owner["signing_key"],
    )
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "viewer",
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": _signed_key_envelope(
                vault_id, member["device_id"], 1, 2, owner["signing_key"]
            ),
            "membership": invitation_membership,
        },
    )
    assert invitation.status in (200, 201), (
        f"invite failed: {_error_code(invitation)}"
    )
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=member["access_token"],
        json_body={"token": invitation.json()["token"]},
    )
    assert accepted.status in (200, 201), (
        f"invite acceptance failed: {_error_code(accepted)}"
    )

    assert _heartbeat(api, vault_id, member["access_token"]).status == 200
    shared_list = _presence(api, vault_id, owner["access_token"])
    assert shared_list.status == 200
    shared_devices = shared_list.json()["devices"]
    assert {(item["user_id"], item["device_id"]) for item in shared_devices} == {
        (owner["account_id"], owner["device_id"]),
        (member["account_id"], member["device_id"]),
    }

    # Independent active sessions retain independent leases, but one device
    # appears only once in the authorized member view.
    second_login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": owner["username"],
            "login_verifier": owner["login_verifier"],
            "device_id": owner["device_id"],
        },
    )
    assert second_login.status == 200
    second_session = second_login.json()
    assert _heartbeat(api, vault_id, second_session["access_token"]).status == 200
    repeated_device_list = _presence(api, vault_id, owner["access_token"])
    assert repeated_device_list.status == 200
    repeated_devices = repeated_device_list.json()["devices"]
    assert len(repeated_devices) == 2
    assert sum(
        item["user_id"] == owner["account_id"] for item in repeated_devices
    ) == 1
    assert sum(
        item["user_id"] == member["account_id"] for item in repeated_devices
    ) == 1
    assert {
        (item["user_id"], item["device_id"]) for item in repeated_devices
    } == {
        (owner["account_id"], owner["device_id"]),
        (member["account_id"], member["device_id"]),
    }
    additional_sessions = _seed_valid_sessions(api, owner, 6)
    for token in additional_sessions:
        renewed = _heartbeat(api, vault_id, token)
        assert renewed.status == 200, (
            f"independent profile lease failed: {_error_code(renewed)}"
        )
    overflow_token = _seed_valid_sessions(api, owner, 1)[0]
    overflow = _heartbeat(api, vault_id, overflow_token)
    assert overflow.status == 409 and _error_code(overflow) == (
        "PRESENCE_LEASE_LIMIT"
    )
    with sqlite3.connect(_database_path(api)) as database:
        overflow_session_id = database.execute(
            "SELECT session_id FROM sessions WHERE access_hash=?",
            (hashlib.sha256(overflow_token.encode()).hexdigest(),),
        ).fetchone()[0]
    with sqlite3.connect(_database_path(api)) as database:
        assert database.execute(
            "SELECT COUNT(*) FROM vault_presence "
            "WHERE vault_id=? AND user_id=? AND device_id=?",
            (vault_id, owner["account_id"], owner["device_id"]),
        ).fetchone()[0] == 8

    # Revoking one profile frees exactly one lease; other profile leases stay
    # visible and a previously rejected profile can retry successfully.
    revoked_profile = api.request(
        "POST",
        "/api/v1/auth/logout",
        token=additional_sessions[0],
        json_body={},
    )
    assert revoked_profile.status in (200, 204)
    # Capacity rejection commits the write gate, so the same profile cannot
    # retry until its five-second interval has elapsed.
    limited_overflow_retry = _heartbeat(api, vault_id, overflow_token)
    assert limited_overflow_retry.status == 429
    assert _error_code(limited_overflow_retry) == "PRESENCE_HEARTBEAT_RATE_LIMITED"
    with sqlite3.connect(_database_path(api)) as database:
        database.execute(
            "UPDATE vault_presence_heartbeat_limits SET last_heartbeat_at=0 "
            "WHERE vault_id=? AND session_id=?",
            (vault_id, overflow_session_id),
        )
    retry = _heartbeat(api, vault_id, overflow_token)
    assert retry.status == 200, f"lease retry failed: {_error_code(retry)}"
    assert _presence(api, vault_id, additional_sessions[0]).status == 401

    logout = api.request(
        "POST", "/api/v1/auth/logout", token=owner["access_token"], json_body={}
    )
    assert logout.status in (200, 204)
    assert _presence(api, vault_id, owner["access_token"]).status == 401
    owner_list = _presence(api, vault_id, second_session["access_token"])
    assert owner_list.status == 200
    assert len(owner_list.json()["devices"]) == 2

    refreshed = api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": second_session["refresh_token"]},
    )
    assert refreshed.status == 200
    refreshed_session = refreshed.json()
    assert _presence(api, vault_id, second_session["access_token"]).status == 401
    refreshed_list = _presence(api, vault_id, refreshed_session["access_token"])
    assert refreshed_list.status == 200
    assert len(refreshed_list.json()["devices"]) == 2

    # Hard expiry is applied by the read predicate, even before cleanup runs.
    with sqlite3.connect(_database_path(api)) as database:
        database.execute(
            "UPDATE vault_presence SET expires_at=0 WHERE vault_id=?", (vault_id,)
        )
    expired = _presence(api, vault_id, refreshed_session["access_token"])
    assert expired.status == 200 and expired.json()["devices"] == []
    with sqlite3.connect(_database_path(api)) as database:
        assert database.execute(
            "SELECT COUNT(*) FROM vault_presence WHERE vault_id=?", (vault_id,)
        ).fetchone()[0] > 0
        stale_gate_rows = database.execute(
            "UPDATE vault_presence_heartbeat_limits SET last_heartbeat_at=0 "
            "WHERE vault_id IN (?,?)",
            (vault_id, other_vault_id),
        ).rowcount
        assert stale_gate_rows >= 1
    cleanup = _run_maintenance(api)
    assert cleanup.returncode == 0, "presence maintenance cleanup failed"
    with sqlite3.connect(_database_path(api)) as database:
        assert database.execute(
            "SELECT COUNT(*) FROM vault_presence WHERE vault_id=?", (vault_id,)
        ).fetchone()[0] == 0
        assert database.execute(
            "SELECT COUNT(*) FROM vault_presence_heartbeat_limits "
            "WHERE session_id=? AND vault_id IN (?,?)",
            (owner_session_id, vault_id, other_vault_id),
        ).fetchone()[0] == 0
    assert _heartbeat(api, vault_id, refreshed_session["access_token"]).status == 200
    assert _heartbeat(api, vault_id, member["access_token"]).status == 200

    revoked_member_entry = {**member_entry, "state": "revoked"}
    revoke_membership = _signed_rotation_membership(
        vault_id,
        3,
        _membership_digest(vault_id, invitation_membership),
        2,
        [owner_member, revoked_member_entry],
        owner["device_id"],
        owner["signing_key"],
        _display_name_envelope(),
    )
    rotated = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=refreshed_session["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": revoke_membership,
            "key_envelopes": _rotation_envelopes(
                vault_id, 3, 2, [owner["device_id"]], owner
            ),
        },
    )
    assert rotated.status in (200, 201), f"member revoke failed: {_error_code(rotated)}"
    assert _presence(api, vault_id, member["access_token"]).status == 404
    after_member_revoke = _presence(api, vault_id, refreshed_session["access_token"])
    assert after_member_revoke.status == 200
    assert [item["user_id"] for item in after_member_revoke.json()["devices"]] == [
        owner["account_id"]
    ]

    revoked_device = api.request(
        "POST",
        f"/api/v1/devices/{owner['device_id']}/revoke",
        token=refreshed_session["access_token"],
    )
    assert revoked_device.status == 200
    assert _presence(api, vault_id, refreshed_session["access_token"]).status == 401
    assert _heartbeat(api, vault_id, refreshed_session["access_token"]).status == 401

    audit = api.request("GET", "/api/v1/audit?limit=200", token=member["access_token"])
    assert audit.status == 200
    assert all("presence" not in event["action"] for event in audit.json()["events"])
    with sqlite3.connect(_database_path(api)) as database:
        columns = {
            row[1]
            for row in database.execute("PRAGMA table_info(vault_presence)").fetchall()
        }
        assert columns == {
            "vault_id",
            "user_id",
            "device_id",
            "session_id",
            "last_seen_at",
            "expires_at",
        }
        rate_limit_keys = {
            row[1]: row[5]
            for row in database.execute(
                "PRAGMA table_info(vault_presence_heartbeat_limits)"
            ).fetchall()
            if row[5]
        }
        assert rate_limit_keys == {"vault_id": 1, "session_id": 2}
        assert database.execute(
            "SELECT COUNT(*) FROM audit_events WHERE action LIKE '%presence%'"
        ).fetchone()[0] == 0
        assert database.execute(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=?", (vault_id,)
        ).fetchone()[0] == 0
