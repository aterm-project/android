"""Black-box acceptance for allowlisted account invitation management."""

from __future__ import annotations

import datetime as dt
import hashlib
import os
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from conftest import SigningKey, b64url, initial_vault, jcs
from test_account_deletion import _db_path


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _register_from_invitation(api, username: str, token: str, directory, label: str):
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    vault_id = str(uuid.uuid4())
    signer = SigningKey(directory, f"admin-invitation-{label}-{account_id[:8]}")
    signing_public_key = b64url(signer.public_key)
    encryption_public_key = b64url(os.urandom(32))
    device = {
        "device_id": device_id,
        "name": f"Account invitation {label}",
        "signing_public_key": signing_public_key,
        "encryption_public_key": encryption_public_key,
    }
    device["signature"] = b64url(
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
    )
    request = {
        "account_id": account_id,
        "username": username,
        "instance_invitation_token": token,
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
        "device": device,
        "initial_vault": initial_vault(
            account_id=account_id,
            vault_id=vault_id,
            device_id=device_id,
            encryption_public_key=encryption_public_key,
            signer=signer,
        ),
    }
    return api.request("POST", "/api/v1/auth/register", json_body=request)


def _issue(api, token: str, username: str, ttl: int | None = None):
    body = {"username": username}
    if ttl is not None:
        body["expires_in_seconds"] = ttl
    return api.request(
        "POST", "/api/v1/admin/account-invitations", token=token, json_body=body
    )


def _parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def test_account_invitation_admin_api_lifecycle_is_private_and_audited(api, account, tmp_path):
    if not api.admin_env or not api.temp_root:
        pytest.skip("account invitation API acceptance needs the suite-owned disposable server")

    db_path = _db_path(api)
    admin_token = account["access_token"]
    unauthenticated = api.request("GET", "/api/v1/admin/account-invitations")
    assert unauthenticated.status == 401
    unauthenticated_write = _issue(api, "", "missing-auth@example.test")
    assert unauthenticated_write.status == 401

    for ttl in (59, 2_592_001, -1):
        invalid = _issue(api, admin_token, f"invalid-ttl-{uuid.uuid4().hex}@example.test", ttl)
        assert invalid.status == 400
        assert _error_code(invalid) == "INVALID_INVITATION_TTL"
    malformed = api.request(
        "POST",
        "/api/v1/admin/account-invitations",
        token=admin_token,
        json_body={"username": "strict@example.test", "unexpected": True},
    )
    assert malformed.status == 400
    malformed_body = api.request(
        "POST",
        "/api/v1/admin/account-invitations",
        token=admin_token,
        raw_body=b"{",
        content_type="application/json",
    )
    assert malformed_body.status == 400
    invalid_username = _issue(api, admin_token, "not-an-account-name")
    assert invalid_username.status == 400
    assert _error_code(invalid_username) == "INVALID_USERNAME"

    member_username = f"account-invitation-nonadmin-{uuid.uuid4().hex}@example.test"
    member_issued = _issue(api, admin_token, member_username, 3600)
    assert member_issued.status == 201
    member_invitation = member_issued.json()["invitation"]
    member_registration = _register_from_invitation(
        api, member_username, member_invitation["token"], tmp_path, "nonadmin"
    )
    assert member_registration.status in (200, 201), "issued account invitation was not accepted"
    member_profile = member_registration.json()
    member_page = api.request(
        "GET", "/api/v1/admin/account-invitations", token=member_profile["access_token"]
    )
    assert member_page.status == 403
    assert _error_code(member_page) == "INSTANCE_ADMIN_REQUIRED"
    member_issue = _issue(api, member_profile["access_token"], "denied@example.test")
    assert member_issue.status == 403
    member_revoke = api.request(
        "POST",
        f"/api/v1/admin/account-invitations/{member_invitation['invitation_id']}/revoke",
        token=member_profile["access_token"],
    )
    assert member_revoke.status == 403

    normalized_username = f"admin-invite-{uuid.uuid4().hex}@example.test"
    first = _issue(api, admin_token, f"  {normalized_username.upper()}  ")
    assert first.status == 201
    first_body = first.json()
    assert set(first_body) == {"invitation"}
    first_invitation = first_body["invitation"]
    assert set(first_invitation) == {
        "invitation_id",
        "username",
        "created_at",
        "expires_at",
        "token",
        "credential_visibility",
    }
    # No explicit mode: the instance default applies at registration.
    assert first_invitation["credential_visibility"] is None
    assert first_invitation["username"] == normalized_username
    assert len(first_invitation["token"]) == 43
    assert round(
        (
            _parse_time(first_invitation["expires_at"])
            - _parse_time(first_invitation["created_at"])
        ).total_seconds()
    ) == 604800

    with sqlite3.connect(db_path) as database:
        stored = database.execute(
            "SELECT token_hash,revoked_at FROM account_invitations WHERE invitation_id=?",
            (first_invitation["invitation_id"],),
        ).fetchone()
    assert stored is not None
    first_token_hash = hashlib.sha256(first_invitation["token"].encode("ascii")).hexdigest()
    if stored != (first_token_hash, None):
        pytest.fail("issued invitation token was not stored only as its SHA-256 hash")

    page = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=2&offset=0", token=admin_token
    )
    assert page.status == 200
    page_body = page.json()
    assert set(page_body) == {"invitations", "total", "limit", "offset"}
    assert page_body["limit"] == 2 and page_body["offset"] == 0
    assert page_body["total"] >= 2
    assert all(
        item["status"] in {"pending", "expired", "consumed", "revoked"}
        for item in page_body["invitations"]
    )
    assert all(
        set(item)
        == {
            "invitation_id",
            "username",
            "created_at",
            "expires_at",
            "status",
            "credential_visibility",
        }
        for item in page_body["invitations"]
    )
    assert all(
        item["credential_visibility"] in {None, "private", "admin_visible"}
        for item in page_body["invitations"]
    )
    next_page = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=2&offset=2", token=admin_token
    )
    assert next_page.status == 200
    assert next_page.json()["total"] == page_body["total"]
    assert not {
        item["invitation_id"] for item in page_body["invitations"]
    } & {item["invitation_id"] for item in next_page.json()["invitations"]}
    serialized_list = str(page_body)
    if (
        first_invitation["token"] in serialized_list
        or first_token_hash in serialized_list
        or "token_hash" in serialized_list
    ):
        pytest.fail("invitation list exposed the one-time token or stored hash")

    # Reissuing the normalized username revokes the previous pending token in
    # the same transaction that inserts and audits the replacement.
    replacement = _issue(api, admin_token, normalized_username, 60)
    assert replacement.status == 201
    replacement_invitation = replacement.json()["invitation"]
    with sqlite3.connect(db_path) as database:
        revoked_at = database.execute(
            "SELECT revoked_at FROM account_invitations WHERE invitation_id=?",
            (first_invitation["invitation_id"],),
        ).fetchone()[0]
    assert revoked_at is not None
    first_registration = _register_from_invitation(
        api, normalized_username, first_invitation["token"], tmp_path, "superseded"
    )
    assert first_registration.status == 401
    assert _error_code(first_registration) == "ACCOUNT_INVITATION_INVALID"
    replacement_registration = _register_from_invitation(
        api, normalized_username, replacement_invitation["token"], tmp_path, "accepted"
    )
    assert replacement_registration.status in (200, 201), "replacement invitation was not accepted"
    replay_registration = _register_from_invitation(
        api, normalized_username, replacement_invitation["token"], tmp_path, "replay"
    )
    assert replay_registration.status == 401
    assert _error_code(replay_registration) == "ACCOUNT_INVITATION_INVALID"

    concurrent_username = f"concurrent-invite-{uuid.uuid4().hex}@example.test"
    concurrent_issue = _issue(api, admin_token, concurrent_username, 3600)
    assert concurrent_issue.status == 201
    concurrent_invitation = concurrent_issue.json()["invitation"]
    registration_barrier = threading.Barrier(2)

    def register_same_invitation(label: str):
        registration_barrier.wait(timeout=10)
        return _register_from_invitation(
            api, concurrent_username, concurrent_invitation["token"], tmp_path, label
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        registration_futures = [
            pool.submit(register_same_invitation, "race-one"),
            pool.submit(register_same_invitation, "race-two"),
        ]
        concurrent_registrations = [future.result(timeout=30) for future in registration_futures]
    successes = [response for response in concurrent_registrations if response.status in (200, 201)]
    failures = [response for response in concurrent_registrations if response.status == 401]
    assert len(successes) == 1
    assert len(failures) == 1
    assert _error_code(failures[0]) == "ACCOUNT_INVITATION_INVALID"
    with sqlite3.connect(db_path) as database:
        concurrent_account_count = database.execute(
            "SELECT COUNT(*) FROM users WHERE username=?", (concurrent_username,)
        ).fetchone()[0]
        concurrent_invitation_state = database.execute(
            "SELECT consumed_at,revoked_at FROM account_invitations WHERE invitation_id=?",
            (concurrent_invitation["invitation_id"],),
        ).fetchone()
    assert concurrent_account_count == 1
    assert concurrent_invitation_state is not None
    assert concurrent_invitation_state[0] is not None
    assert concurrent_invitation_state[1] is None

    consumed_revoke = api.request(
        "POST",
        f"/api/v1/admin/account-invitations/{replacement_invitation['invitation_id']}/revoke",
        token=admin_token,
    )
    assert consumed_revoke.status == 409
    assert _error_code(consumed_revoke) == "ACCOUNT_INVITATION_NOT_PENDING"

    revocable_username = f"revocable-invite-{uuid.uuid4().hex}@example.test"
    revocable = _issue(api, admin_token, revocable_username, 3600)
    assert revocable.status == 201
    revocable_invitation = revocable.json()["invitation"]
    revoke_path = f"/api/v1/admin/account-invitations/{revocable_invitation['invitation_id']}/revoke"
    revoked = api.request("POST", revoke_path, token=admin_token)
    assert revoked.status == 200
    revoked_body = revoked.json()
    assert set(revoked_body) == {"invitation_id", "status", "revoked_at"}
    assert revoked_body["status"] == "revoked"
    repeated_revoke = api.request("POST", revoke_path, token=admin_token)
    assert repeated_revoke.status == 200
    if repeated_revoke.json() != revoked_body:
        pytest.fail("repeated invitation revoke changed its result or timestamp")
    revoked_registration = _register_from_invitation(
        api, revocable_username, revocable_invitation["token"], tmp_path, "revoked"
    )
    assert revoked_registration.status == 401
    assert _error_code(revoked_registration) == "ACCOUNT_INVITATION_INVALID"

    expired_username = f"expired-invite-{uuid.uuid4().hex}@example.test"
    expired = _issue(api, admin_token, expired_username, 60)
    assert expired.status == 201
    expired_invitation = expired.json()["invitation"]
    expired_at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=2)).isoformat()
    with sqlite3.connect(db_path) as database:
        database.execute(
            "UPDATE account_invitations SET expires_at=? WHERE invitation_id=?",
            (expired_at, expired_invitation["invitation_id"]),
        )
    expired_revoke = api.request(
        "POST",
        f"/api/v1/admin/account-invitations/{expired_invitation['invitation_id']}/revoke",
        token=admin_token,
    )
    assert expired_revoke.status == 409
    assert _error_code(expired_revoke) == "ACCOUNT_INVITATION_NOT_PENDING"

    long_lived = _issue(
        api,
        admin_token,
        f"max-lifetime-invite-{uuid.uuid4().hex}@example.test",
        2_592_000,
    )
    assert long_lived.status == 201
    long_lived_invitation = long_lived.json()["invitation"]
    assert round(
        (
            _parse_time(long_lived_invitation["expires_at"])
            - _parse_time(long_lived_invitation["created_at"])
        ).total_seconds()
    ) == 2_592_000

    invalid_revoke_id = api.request(
        "POST",
        "/api/v1/admin/account-invitations/not-a-uuid/revoke",
        token=admin_token,
    )
    assert invalid_revoke_id.status == 400
    assert _error_code(invalid_revoke_id) == "INVALID_INVITATION_ID"

    taken = _issue(api, admin_token, member_username)
    assert taken.status == 409
    assert _error_code(taken) == "USERNAME_TAKEN"
    invalid_page = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=0", token=admin_token
    )
    assert invalid_page.status == 400
    assert _error_code(invalid_page) == "INVALID_LIMIT"
    invalid_offset = api.request(
        "GET", "/api/v1/admin/account-invitations?offset=1000001", token=admin_token
    )
    assert invalid_offset.status == 400
    assert _error_code(invalid_offset) == "INVALID_OFFSET"

    # Force an equal creation timestamp so the secondary order key is observable.
    tied_created_at = "2000-01-01T00:00:00+00:00"
    with sqlite3.connect(db_path) as database:
        database.executemany(
            "UPDATE account_invitations SET created_at=? WHERE invitation_id=?",
            [
                (tied_created_at, revocable_invitation["invitation_id"]),
                (tied_created_at, expired_invitation["invitation_id"]),
            ],
        )

    inventory = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=100", token=admin_token
    )
    assert inventory.status == 200
    inventory_items = inventory.json()["invitations"]
    statuses = {item["invitation_id"]: item["status"] for item in inventory_items}
    assert statuses[member_invitation["invitation_id"]] == "consumed"
    assert statuses[first_invitation["invitation_id"]] == "revoked"
    assert statuses[replacement_invitation["invitation_id"]] == "consumed"
    assert statuses[concurrent_invitation["invitation_id"]] == "consumed"
    assert statuses[revocable_invitation["invitation_id"]] == "revoked"
    assert statuses[expired_invitation["invitation_id"]] == "expired"
    assert statuses[long_lived_invitation["invitation_id"]] == "pending"
    listed_text = str(inventory.json())
    invitation_tokens = (
        member_invitation["token"],
        first_invitation["token"],
        replacement_invitation["token"],
        concurrent_invitation["token"],
        revocable_invitation["token"],
        expired_invitation["token"],
        long_lived_invitation["token"],
    )
    if any(token in listed_text for token in invitation_tokens) or "token_hash" in listed_text:
        pytest.fail("invitation list exposed a one-time token or stored hash")

    tied_items = [item for item in inventory_items if item["created_at"] == tied_created_at]
    assert [item["invitation_id"] for item in tied_items] == sorted(
        [revocable_invitation["invitation_id"], expired_invitation["invitation_id"]],
        reverse=True,
    )
    first_tied_offset = next(
        index
        for index, item in enumerate(inventory_items)
        if item["invitation_id"] == tied_items[0]["invitation_id"]
    )
    for offset in (first_tied_offset, first_tied_offset + 1):
        single_item_page = api.request(
            "GET",
            f"/api/v1/admin/account-invitations?limit=1&offset={offset}",
            token=admin_token,
        )
        assert single_item_page.status == 200
        assert single_item_page.json()["total"] == inventory.json()["total"]
        assert single_item_page.json()["invitations"] == [inventory_items[offset]]

    with sqlite3.connect(db_path) as database:
        database.row_factory = sqlite3.Row
        events = database.execute(
            "SELECT scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source "
            "FROM audit_events WHERE action IN ('instance.account_invitation_issued','instance.account_invitation_revoked') "
            "ORDER BY event_id"
        ).fetchall()
    issued_events = [row for row in events if row["action"] == "instance.account_invitation_issued"]
    revoked_events = [row for row in events if row["action"] == "instance.account_invitation_revoked"]
    assert len(issued_events) == 7
    assert len(revoked_events) == 2
    for row in events:
        assert row["scope_type"] == "instance"
        assert row["scope_id"] and len(row["scope_id"]) == 64
        assert row["actor_user_id"] == account["account_id"]
        assert row["actor_device_id"] == account["device_id"]
        assert row["resource_type"] == "account_invitation"
        assert row["resource_id"] and len(row["resource_id"]) == 64
        assert row["result"] == "success"
        assert row["source"] == "api"
        assert row["resource_id"] not in {
            member_invitation["invitation_id"],
            first_invitation["invitation_id"],
            replacement_invitation["invitation_id"],
            concurrent_invitation["invitation_id"],
            revocable_invitation["invitation_id"],
            expired_invitation["invitation_id"],
            long_lived_invitation["invitation_id"],
        }

    serialized_events = " ".join(str(value) for row in events for value in row)
    invitation_secrets = [*invitation_tokens]
    invitation_secrets.extend(
        hashlib.sha256(token.encode("ascii")).hexdigest() for token in invitation_tokens
    )
    if any(secret in serialized_events for secret in invitation_secrets):
        pytest.fail("instance invitation audit rows exposed a token or token hash")

    with sqlite3.connect(db_path) as database:
        current_session_hash = hashlib.sha256(admin_token.encode("ascii")).hexdigest()
        database.execute(
            "UPDATE sessions SET revoked_at=? WHERE access_hash=?",
            (dt.datetime.now(dt.timezone.utc).isoformat(), current_session_hash),
        )
    stale_admin_page = api.request(
        "GET", "/api/v1/admin/account-invitations", token=admin_token
    )
    assert stale_admin_page.status == 401
    stale_admin_write = _issue(api, admin_token, "stale-admin@example.test")
    assert stale_admin_write.status == 401
