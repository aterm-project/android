"""IT-25: account deletion, session/device recovery, purge and shared-vault retention."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import subprocess
import urllib.parse
import uuid
from pathlib import Path

import pytest

from conftest import (
    ROOT,
    ApiClient,
    SigningKey,
    b64url,
    initial_vault,
    jcs,
    redact_secrets,
    server_binary_path,
    unb64url,
    verify_ed25519,
)


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _db_path(api: ApiClient) -> Path:
    if not api.admin_env or not api.temp_root:
        pytest.skip("IT-25 needs the suite-owned disposable SQLite database")
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        pytest.skip("IT-25 lifecycle timestamp control requires SQLite")
    return Path(database_url.removeprefix("sqlite://").split("?", 1)[0])


def _admin_cli(api: ApiClient, *args: str) -> subprocess.CompletedProcess[str]:
    if not api.admin_env:
        pytest.skip("IT-25 CLI maintenance requires the suite-owned disposable server")
    executable = server_binary_path(api.admin_env)
    if executable.is_file():
        command = [str(executable), *args]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            *args,
        ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _issue_account_invitation(api: ApiClient, username: str) -> str:
    assert api.admin_env
    executable = server_binary_path(api.admin_env)
    if executable.is_file():
        command = [str(executable), "create-account-invite", "--username", username]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--locked",
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
    if result.returncode:
        pytest.fail("IT-25 account invitation CLI failed: " + redact_secrets(result.stdout + result.stderr)[-2000:])
    token_match = re.search(r"(?m)^([A-Za-z0-9_-]{40,})\s*$", result.stdout)
    assert token_match, "IT-25 account invitation CLI omitted its one-use token"
    return token_match.group(1)


def _register_account(api: ApiClient, username: str, key_dir: Path, label: str) -> dict:
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    vault_id = str(uuid.uuid4())
    signer = SigningKey(key_dir, f"it25-{label}-{account_id[:8]}")
    signing_public_key = b64url(signer.public_key)
    encryption_public_key = b64url(os.urandom(32))
    login_verifier = b64url(os.urandom(32))
    device = {
        "device_id": device_id,
        "name": f"IT-25 {label}",
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
        "instance_invitation_token": _issue_account_invitation(api, username),
        "kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": login_verifier,
        "account_key_envelope": {
            "version": 1,
            "nonce": b64url(os.urandom(24)),
            "ciphertext": b64url(os.urandom(48)),
        },
        "device": device,
    }
    request["initial_vault"] = initial_vault(
        account_id=account_id,
        vault_id=vault_id,
        device_id=device_id,
        encryption_public_key=encryption_public_key,
        signer=signer,
    )
    created = api.request("POST", "/api/v1/auth/register", json_body=request)
    assert created.status in (200, 201), (
        f"IT-25 account enrollment failed: HTTP {created.status} {_error_code(created)}"
    )
    body = created.json()
    assert body["account_id"] == account_id
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "kdf": request["kdf"],
        "login_verifier": login_verifier,
        "access_token": body["access_token"],
        "refresh_token": body["refresh_token"],
        "vault_id": vault_id,
        "signing_key": signer,
        "signing_public_key": signing_public_key,
        "encryption_public_key": encryption_public_key,
    }


def _member(account: dict, role: str) -> dict:
    return {
        "user_id": account["account_id"],
        "role": role,
        "state": "active",
        "encryption_key_fingerprint": b64url(
            hashlib.sha256(unb64url(account["encryption_public_key"])).digest()
        ),
    }


def _membership(vault_id: str, version: int, previous_digest: str | None, members: list[dict], owner: dict) -> dict:
    unsigned = {
        "membership_version": version,
        "previous_digest": previous_digest,
        "manifest": {
            "key_epoch": 1,
            "members": members,
            "signer_device_id": owner["device_id"],
        },
    }
    return {**unsigned, "signature": b64url(owner["signing_key"].sign(jcs({"vault_id": vault_id, **unsigned})))}


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


def _key_envelope(vault_id: str, recipient: dict, version: int, signer: dict) -> dict:
    unsigned = {
        "recipient_device_id": recipient["device_id"],
        "key_epoch": 1,
        "membership_version": version,
        "envelope": {"version": 1, "suite": "crypto_box_seal", "ciphertext": b64url(os.urandom(48))},
    }
    return {**unsigned, "signature": b64url(signer["signing_key"].sign(jcs({"vault_id": vault_id, **unsigned})))}


def _create_shared_vault(api: ApiClient, owner: dict, member: dict) -> tuple[str, str]:
    vault_id = str(uuid.uuid4())
    initial = initial_vault(
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
            "name_envelope": initial["name_envelope"],
            "key_envelope": initial["key_envelope"],
            "membership": initial["membership"],
        },
    )
    assert created.status in (200, 201), f"IT-25 shared-vault creation failed: {_error_code(created)}"
    next_membership = _membership(
        vault_id,
        2,
        _membership_digest(vault_id, initial["membership"]),
        [_member(owner, "owner"), _member(member, "editor")],
        owner,
    )
    invite = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": _key_envelope(vault_id, member, 2, owner),
            "membership": next_membership,
        },
    )
    assert invite.status in (200, 201), f"IT-25 shared-vault invite failed: {_error_code(invite)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=member["access_token"],
        json_body={"token": invite.json()["token"]},
    )
    assert accepted.status in (200, 201), f"IT-25 shared-vault invite acceptance failed: {_error_code(accepted)}"
    return vault_id, _membership_digest(vault_id, next_membership)


def _enroll_device(api: ApiClient, account: dict, key_dir: Path, label: str) -> dict:
    signer = SigningKey(key_dir, f"it25-device-{label}-{uuid.uuid4().hex[:6]}")
    device_id = str(uuid.uuid4())
    signing_public_key = b64url(signer.public_key)
    encryption_public_key = b64url(os.urandom(32))
    device = {
        "device_id": device_id,
        "name": f"IT-25 {label}",
        "signing_public_key": signing_public_key,
        "encryption_public_key": encryption_public_key,
    }
    device["signature"] = b64url(
        signer.sign(jcs({"account_id": account["account_id"], **{key: device[key] for key in ("device_id", "signing_public_key", "encryption_public_key")}}))
    )
    vault_response = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert vault_response.status == 200, f"IT-25 device enrollment vault list failed: {_error_code(vault_response)}"
    vault_envelopes = []
    for vault in vault_response.json()["vaults"]:
        source = [item for item in vault["key_envelopes"] if item["recipient_device_id"] == account["device_id"]]
        assert source, f"IT-25 source device has no key envelope for vault {vault['vault_id']}"
        for key in source:
            unsigned = {
                "vault_id": vault["vault_id"],
                "recipient_device_id": device_id,
                "key_epoch": key["key_epoch"],
                "membership_version": key["membership_version"],
                "envelope": {"version": 1, "suite": "crypto_box_seal", "ciphertext": b64url(os.urandom(48))},
            }
            vault_envelopes.append(
                {**unsigned, "signature": b64url(account["signing_key"].sign(jcs(unsigned)))}
            )
    cert_unsigned = {
        "account_id": account["account_id"],
        "approver_device_id": account["device_id"],
        "device": device,
    }
    enrollment = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body={
            "device": device,
            "approver_device_id": account["device_id"],
            "certificate_signature": b64url(account["signing_key"].sign(jcs(cert_unsigned))),
            "vault_key_envelopes": vault_envelopes,
        },
    )
    assert enrollment.status in (200, 201), f"IT-25 sibling-device enrollment failed: {_error_code(enrollment)}"
    return {"device_id": device_id, "signing_key": signer, "signing_public_key": signing_public_key}


def _login(api: ApiClient, account: dict, device_id: str) -> dict:
    response = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": device_id,
        },
    )
    assert response.status == 200, f"IT-25 device login failed: {_error_code(response)}"
    return response.json()


def _push_shared_record(api: ApiClient, instance: dict, member: dict, vault_id: str) -> dict:
    record_id = str(uuid.uuid4())
    revision_id = str(uuid.uuid4())
    unsigned = {
        "header": {
            "wire_version": 1,
            "server_space_id": instance["server_space_id"],
            "vault_id": vault_id,
            "record_id": record_id,
            "revision_id": revision_id,
            "base_revision_id": None,
            "op_id": str(uuid.uuid4()),
            "device_id": member["device_id"],
            "device_seq": "1",
            "key_epoch": "1",
            "membership_version": "2",
            "record_schema": 1,
            "operation": "create",
            "crypto_suite": "atermius-vault-v1",
            "kdf_salt": b64url(os.urandom(32)),
        },
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(96)),
    }
    envelope = {**unsigned, "signature": b64url(member["signing_key"].sign(jcs(unsigned)))}
    push = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/sync/push",
        token=member["access_token"],
        json_body={
            "protocol_version": instance.get("protocol_version", 1),
            "server_generation": str(instance["generation"]),
            "vault_id": vault_id,
            "device_id": member["device_id"],
            "batch_id": str(uuid.uuid4()),
            "operations": [envelope],
        },
    )
    assert push.status in (200, 201), f"IT-25 shared ciphertext push failed: {_error_code(push)}"
    return {"record_id": record_id, "revision_id": revision_id, "envelope": envelope}


def _auth_bucket_keys(database: Path) -> set[tuple[str, str]]:
    with sqlite3.connect(database) as connection:
        return set(
            connection.execute(
                "SELECT scope,subject_hash FROM auth_rate_limits "
                "WHERE endpoint='login' AND scope IN ('user','pair')"
            ).fetchall()
        )


def _assert_pending_dto(body: dict) -> None:
    assert body.get("status") == "deleting"
    assert body.get("can_cancel") is True
    requested = body.get("requested_at")
    purge_after = body.get("purge_after")
    assert isinstance(requested, str) and isinstance(purge_after, str)
    assert purge_after > requested


def test_account_deletion_lifecycle_preserves_shared_vault_and_anonymous_audit(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """IT-25: cancellation restores marked devices only; due purge removes account data."""
    database = _db_path(api)
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200
    instance = live_instance.json()
    primary = account
    target_username = f"it25-target-{uuid.uuid4().hex[:10]}@example.test"
    target = _register_account(api, target_username, tmp_path, "deletion-target")
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM account_invitations WHERE consumed_user_id=?",
            (target["account_id"],),
        ).fetchone()[0] == 1, "IT-25 must begin with a consumed account invite to verify purge cleanup"
    blocker_username = f"it25-blocked-owner-{uuid.uuid4().hex[:10]}@example.test"
    blocker = _register_account(api, blocker_username, tmp_path, "shared-owner")

    # The target is a member (not owner) of the primary account's shared vault.
    shared_vault_id, _ = _create_shared_vault(api, primary, target)
    # A record signed by the soon-to-be-deleted member proves that the surviving
    # vault keeps opaque ciphertext and a vault-scoped verification key archive.
    # Refresh once so the purge must also remove consumed refresh_history rows.
    original_target_access = target["access_token"]
    consumed_refresh_token = target["refresh_token"]
    rotated = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": consumed_refresh_token}
    )
    assert rotated.status == 200, f"IT-25 refresh rotation failed: {_error_code(rotated)}"
    target["access_token"] = rotated.json()["access_token"]
    target["refresh_token"] = rotated.json()["refresh_token"]
    record = _push_shared_record(api, instance, target, shared_vault_id)
    target_snapshot = api.request(
        "POST", f"/api/v1/vaults/{shared_vault_id}/snapshots", token=target["access_token"]
    )
    assert target_snapshot.status in (200, 201), f"IT-25 snapshot fixture failed: {_error_code(target_snapshot)}"
    snapshot_id = target_snapshot.json()["snapshot_id"]

    # Enroll a second active device and one device that was revoked before the
    # account-deletion request. Only the active pair should be restored.
    active_sibling = _enroll_device(api, target, tmp_path, "active-sibling")
    sibling_login = _login(api, target, active_sibling["device_id"])
    pre_revoked = _enroll_device(api, target, tmp_path, "previously-revoked")
    revoke = api.request(
        "POST",
        f"/api/v1/devices/{pre_revoked['device_id']}/revoke",
        token=target["access_token"],
        json_body={},
    )
    assert revoke.status in (200, 204), f"IT-25 pre-revoke setup failed: {_error_code(revoke)}"

    # A separate owner account owns a shared vault, so account deletion must be
    # refused without changing its lifecycle, devices, sessions, or ledger.
    blocked_vault_id, _ = _create_shared_vault(api, blocker, primary)
    before_buckets = _auth_bucket_keys(database)
    bad_proof = b64url(os.urandom(32))
    reauth = api.request(
        "POST",
        "/api/v1/account/delete",
        token=blocker["access_token"],
        json_body={"login_verifier": bad_proof},
    )
    assert reauth.status == 401 and _error_code(reauth) == "REAUTH_REQUIRED"
    after_bad_proof = _auth_bucket_keys(database)
    created_buckets = after_bad_proof - before_buckets
    user_bucket = next((key for key in created_buckets if key[0] == "user"), None)
    pair_bucket = next((key for key in created_buckets if key[0] == "pair"), None)
    assert user_bucket and pair_bucket, "IT-25 failed proof did not consume normalized Login buckets"

    limited = None
    # Probe the live endpoint limit in a bounded logarithmic loop. Set the
    # current fixed-window rows so the test does not depend on the configured
    # threshold or spend many expensive Argon2 checks. Re-read window_started
    # each iteration because this module can run across a rate-window boundary.
    # Force the rows created by the first failed proof into a stale window once;
    # the first probe must recover by creating and then targeting the new rows.
    with sqlite3.connect(database) as connection:
        for scope, subject_hash in (user_bucket, pair_bucket):
            connection.execute(
                "UPDATE auth_rate_limits SET window_started=0 "
                "WHERE endpoint='login' AND scope=? AND subject_hash=?",
                (scope, subject_hash),
            )
        connection.commit()
    for next_floor in (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1000, 1000):
        with sqlite3.connect(database) as connection:
            for scope, subject_hash in (user_bucket, pair_bucket):
                current_bucket = connection.execute(
                    "SELECT MAX(window_started) FROM auth_rate_limits "
                    "WHERE endpoint='login' AND scope=? AND subject_hash=?",
                    (scope, subject_hash),
                ).fetchone()[0]
                assert current_bucket is not None, "IT-25 current Login bucket disappeared"
                connection.execute(
                    "UPDATE auth_rate_limits SET attempts=? WHERE endpoint='login' AND scope=? AND subject_hash=? AND window_started=?",
                    (next_floor, scope, subject_hash, current_bucket),
                )
            connection.commit()
        limited = api.request(
            "POST",
            "/api/v1/account/delete",
            token=blocker["access_token"],
            json_body={"login_verifier": bad_proof},
        )
        if limited.status == 429:
            break
        assert limited.status == 401 and _error_code(limited) == "REAUTH_REQUIRED"
    else:
        pytest.fail("IT-25 Login step-up did not rate-limit within the configured maximum threshold")
    assert limited is not None
    assert limited.status == 429 and _error_code(limited) == "RATE_LIMITED"
    retry_after = limited.headers.get("Retry-After")
    assert retry_after is not None and int(retry_after) >= 1
    # The test forces a full bucket in its private DB so it does not spend many
    # Argon2 operations; remove only the unique test account user/pair buckets
    # across all rate windows before checking the shared-owner guard.
    with sqlite3.connect(database) as connection:
        for scope, subject_hash in (user_bucket, pair_bucket):
            connection.execute(
                "DELETE FROM auth_rate_limits WHERE endpoint='login' AND scope=? AND subject_hash=?",
                (scope, subject_hash),
            )
        connection.commit()

    owner_block = api.request(
        "POST",
        "/api/v1/account/delete",
        token=blocker["access_token"],
        json_body={"login_verifier": blocker["login_verifier"]},
    )
    assert owner_block.status == 409 and _error_code(owner_block) == "ACCOUNT_OWNS_SHARED_VAULT"
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT status FROM users WHERE user_id=?", (blocker["account_id"],)).fetchone() == ("active",)
        assert connection.execute("SELECT COUNT(*) FROM devices WHERE user_id=? AND status='active'", (blocker["account_id"],)).fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sessions WHERE user_id=? AND revoked_at IS NULL", (blocker["account_id"],)).fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM account_deletion_requests WHERE user_id=?", (blocker["account_id"],)).fetchone()[0] == 0
    assert api.request("GET", "/api/v1/me", token=blocker["access_token"]).status == 200
    assert api.request("GET", f"/api/v1/vaults/{blocked_vault_id}/members", token=blocker["access_token"]).status == 200

    # Account deletion is step-up protected, then immediately invalidates all
    # active sessions and marks exactly the devices changed by this request.
    requested = api.request(
        "POST",
        "/api/v1/account/delete",
        token=target["access_token"],
        json_body={"login_verifier": target["login_verifier"]},
    )
    assert requested.status == 200, f"IT-25 delete request failed: HTTP {requested.status} {_error_code(requested)}"
    pending = requested.json()
    _assert_pending_dto(pending)
    # Deleting accounts still receive their real KDF parameters from prelogin,
    # while the login endpoint denies every session until the deletion is
    # cancelled. This lets the client derive the correct verifier for the
    # sessionless cancellation flow without making the account appear unknown.
    deleting_prelogin = api.request(
        "POST",
        "/api/v1/auth/prelogin",
        json_body={"username": target["username"]},
    )
    assert deleting_prelogin.status == 200, (
        f"IT-25 deleting-account prelogin failed: {_error_code(deleting_prelogin)}"
    )
    assert deleting_prelogin.json()["account_id"] == target["account_id"]
    assert deleting_prelogin.json()["kdf"] == target["kdf"]
    denied_pending_login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": target["username"],
            "login_verifier": target["login_verifier"],
            "device_id": target["device_id"],
        },
    )
    assert denied_pending_login.status == 401 and _error_code(denied_pending_login) == "AUTH_REQUIRED"
    revoked_refresh_token = target["refresh_token"]
    with sqlite3.connect(database) as connection:
        request_row = connection.execute(
            "SELECT request_id,requested_at,purge_after,actor_hash,cancelled_at,purged_at FROM account_deletion_requests WHERE user_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
            (target["account_id"],),
        ).fetchone()
        assert request_row is not None
        request_id, requested_epoch, purge_after, actor_hash, cancelled_at, purged_at = request_row
        assert purge_after > requested_epoch and actor_hash not in (target["username"], target["account_id"], target["device_id"])
        assert cancelled_at is None and purged_at is None
        devices = {
            row[0]: (row[1], row[2])
            for row in connection.execute(
                "SELECT device_id,status,account_deletion_request_id FROM devices WHERE user_id=?",
                (target["account_id"],),
            )
        }
        assert devices[target["device_id"]] == ("revoked", request_id)
        assert devices[active_sibling["device_id"]] == ("revoked", request_id)
        assert devices[pre_revoked["device_id"]] == ("revoked", None)
        assert connection.execute("SELECT status FROM users WHERE user_id=?", (target["account_id"],)).fetchone() == ("deleting",)
        assert connection.execute("SELECT COUNT(*) FROM sessions WHERE user_id=? AND revoked_at IS NOT NULL", (target["account_id"],)).fetchone()[0] >= 2

    for token in (original_target_access, target["access_token"], sibling_login["access_token"]):
        denied = api.request("GET", "/api/v1/me", token=token)
        assert denied.status == 401 and _error_code(denied) == "AUTH_REQUIRED"
    member_list = api.request("GET", f"/api/v1/vaults/{shared_vault_id}/members", token=primary["access_token"])
    assert member_list.status == 200 and any(item["user_id"] == target["account_id"] for item in member_list.json()["members"])

    # Cancellation needs no session. It restores only devices marked by this
    # request; every already-issued access/refresh session stays revoked.
    cancelled = api.request(
        "POST",
        "/api/v1/account/delete/cancel",
        json_body={"username": f"  {target['username'].upper()} ", "login_verifier": target["login_verifier"]},
    )
    assert cancelled.status == 200, f"IT-25 cancel failed: HTTP {cancelled.status} {_error_code(cancelled)}"
    assert cancelled.json() == {
        "status": "active",
        "requested_at": None,
        "purge_after": None,
        "can_cancel": False,
    }
    with sqlite3.connect(database) as connection:
        cancelled_row = connection.execute(
            "SELECT user_id,actor_hash,cancelled_at,purged_at FROM account_deletion_requests WHERE request_id=?",
            (request_id,),
        ).fetchone()
        assert cancelled_row[0] is None and cancelled_row[1] == actor_hash
        assert cancelled_row[2] is not None and cancelled_row[3] is None
        device_states = {
            row[0]: (row[1], row[2])
            for row in connection.execute(
                "SELECT device_id,status,account_deletion_request_id FROM devices WHERE user_id=?",
                (target["account_id"],),
            )
        }
        assert device_states[target["device_id"]] == ("active", None)
        assert device_states[active_sibling["device_id"]] == ("active", None)
        assert device_states[pre_revoked["device_id"]] == ("revoked", None)
        assert connection.execute("SELECT COUNT(*) FROM sessions WHERE user_id=? AND revoked_at IS NULL", (target["account_id"],)).fetchone()[0] == 0
    for token in (original_target_access, target["access_token"], sibling_login["access_token"]):
        denied = api.request("GET", "/api/v1/me", token=token)
        assert denied.status == 401 and _error_code(denied) == "AUTH_REQUIRED"
    assert api.request("GET", "/api/v1/vaults", token=target["access_token"]).status == 401
    fresh_base = _login(api, target, target["device_id"])
    fresh_sibling = _login(api, target, active_sibling["device_id"])
    assert api.request("GET", "/api/v1/me", token=fresh_base["access_token"]).status == 200
    assert api.request("GET", "/api/v1/me", token=fresh_sibling["access_token"]).status == 200
    old_refresh = api.request(
        "POST",
        "/api/v1/auth/refresh",
        json_body={"refresh_token": revoked_refresh_token},
    )
    assert old_refresh.status == 401 and _error_code(old_refresh) == "AUTH_REQUIRED"

    # A second request reaches its deadline. Cancellation is refused before
    # maintenance, then maintenance purges private account rows atomically.
    second_delete = api.request(
        "POST",
        "/api/v1/account/delete",
        token=fresh_base["access_token"],
        json_body={"login_verifier": target["login_verifier"]},
    )
    assert second_delete.status == 200 and _error_code(second_delete) is None
    _assert_pending_dto(second_delete.json())
    with sqlite3.connect(database) as connection:
        second_request_id = connection.execute(
            "SELECT request_id FROM account_deletion_requests WHERE user_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
            (target["account_id"],),
        ).fetchone()[0]
        connection.execute(
            "UPDATE account_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-3600,purge_after=CAST(strftime('%s','now') AS INTEGER)-1 WHERE request_id=?",
            (second_request_id,),
        )
        connection.commit()
    too_late = api.request(
        "POST",
        "/api/v1/account/delete/cancel",
        json_body={"username": target["username"], "login_verifier": target["login_verifier"]},
    )
    assert too_late.status == 410 and _error_code(too_late) == "ACCOUNT_DELETION_WINDOW_EXPIRED"

    maintenance = _admin_cli(api, "maintenance")
    assert maintenance.returncode == 0, redact_secrets(maintenance.stdout + maintenance.stderr)[-3000:]
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT 1 FROM users WHERE user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM auth_credentials WHERE user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM devices WHERE user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM sessions WHERE user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM refresh_history WHERE user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM account_invitations WHERE consumed_user_id=?", (target["account_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM account_invitations WHERE username=?", (target["username"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM vaults WHERE vault_id=?", (target["vault_id"],)).fetchone() is None
        assert connection.execute("SELECT 1 FROM snapshots WHERE snapshot_id=?", (snapshot_id,)).fetchone() is None
        audit = connection.execute(
            "SELECT user_id,requested_at,purge_after,actor_hash,cancelled_at,purged_at FROM account_deletion_requests WHERE request_id=?",
            (second_request_id,),
        ).fetchone()
        assert audit is not None and audit[0] is None and audit[3] == actor_hash and audit[5] is not None
        assert target["username"] not in str(audit)
        assert re.fullmatch(r"[0-9a-f]{64}", audit[3])
        retained_cancelled_audit = connection.execute(
            "SELECT user_id,cancelled_at,purged_at FROM account_deletion_requests WHERE request_id=?",
            (request_id,),
        ).fetchone()
        assert retained_cancelled_audit is not None
        assert retained_cancelled_audit[0] is None and retained_cancelled_audit[1] is not None and retained_cancelled_audit[2] is None
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []

    # Another active member keeps the shared vault and the member-authored
    # immutable ciphertext; public verification material survives in scope.
    listed = api.request("GET", "/api/v1/vaults", token=primary["access_token"])
    assert listed.status == 200 and shared_vault_id in {item["vault_id"] for item in listed.json()["vaults"]}
    surviving_members = api.request(
        "GET", f"/api/v1/vaults/{shared_vault_id}/members", token=primary["access_token"]
    )
    assert surviving_members.status == 200
    assert all(item["user_id"] != target["account_id"] for item in surviving_members.json()["members"])
    retained = api.request(
        "GET",
        f"/api/v1/vaults/{shared_vault_id}/revisions/{record['revision_id']}",
        token=primary["access_token"],
    )
    assert retained.status == 200, f"IT-25 shared ciphertext vanished: {_error_code(retained)}"
    assert retained.json()["record_id"] == record["record_id"]
    assert retained.json()["envelope"] == record["envelope"]
    assert verify_ed25519(
        target["signing_public_key"],
        jcs({key: record["envelope"][key] for key in ("header", "nonce", "ciphertext")}),
        record["envelope"]["signature"],
    ), "retained shared ciphertext must remain verifiable with the archived signing key"
    directory = api.request(
        "GET", f"/api/v1/vaults/{shared_vault_id}/devices", token=primary["access_token"]
    )
    assert directory.status == 200, f"IT-25 archived device directory failed: {_error_code(directory)}"
    archived = next(
        item for item in directory.json()["devices"] if item["device_id"] == target["device_id"]
    )
    assert archived["user_id"] == target["account_id"]
    assert archived["status"] == "archived"
    assert archived["signing_public_key"] == target["signing_public_key"]
    assert archived["encryption_public_key"] == target["encryption_public_key"]

    print("IT-25 passed: reauth/rate-limit, owner guard, cancellation, session revocation, purge cascades and shared-vault key archive.")
