"""IT-21: black-box deletion grace, cancellation, purge and concurrency checks."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import pytest

from conftest import (
    server_binary_path,
    ROOT,
    ApiClient,
    SigningKey,
    b64url,
    initial_vault,
    jcs,
    redact_secrets,
    unb64url,
)


def error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _database_path(api: ApiClient) -> Path:
    if not api.admin_env or not api.temp_root:
        pytest.skip("IT-21 requires the suite-owned disposable SQLite database")
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        pytest.skip("IT-21 direct timestamp fixtures require SQLite")
    return Path(database_url.removeprefix("sqlite://").split("?", 1)[0])


def _server_cli(api: ApiClient, *args: str, env_overrides: dict[str, str] | None = None):
    if not api.admin_env:
        pytest.skip("IT-21 maintenance assertions require the suite-owned server")
    executable = server_binary_path()
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
    env = api.admin_env.copy()
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _issue_account_invitation(api: ApiClient, username: str) -> str:
    assert api.admin_env
    executable = server_binary_path()
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
        pytest.fail("IT-21 account invite CLI failed: " + redact_secrets(result.stdout + result.stderr)[-2000:])
    token_match = re.search(r"(?m)^([A-Za-z0-9_-]{40,})\s*$", result.stdout)
    assert token_match, "IT-21 account invite CLI omitted its one-time token"
    return token_match.group(1)


def _register_owner(api: ApiClient, tmp_path: Path) -> dict:
    username = f"it21-owner-{uuid.uuid4().hex[:10]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_key = b64url(os.urandom(32))
    signer = SigningKey(tmp_path, f"it21-vault-owner-{account_id[:8]}")
    signing_public_key = b64url(signer.public_key)
    login_verifier = b64url(os.urandom(32))
    registration = {
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
        "device": {
            "device_id": device_id,
            "name": "IT-21 deletion owner",
            "signing_public_key": signing_public_key,
            "encryption_public_key": encryption_key,
            "signature": b64url(
                signer.sign(
                    jcs(
                        {
                            "account_id": account_id,
                            "device_id": device_id,
                            "signing_public_key": signing_public_key,
                            "encryption_public_key": encryption_key,
                        }
                    )
                )
            ),
        },
    }
    registration["initial_vault"] = initial_vault(
        account_id=account_id,
        vault_id=str(uuid.uuid4()),
        device_id=device_id,
        encryption_public_key=encryption_key,
        signer=signer,
    )
    created = api.request("POST", "/api/v1/auth/register", json_body=registration)
    assert created.status in (200, 201), (
        f"IT-21 owner enrollment failed: HTTP {created.status} {error_code(created)}"
    )
    response = created.json()
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "login_verifier": login_verifier,
        "access_token": response["access_token"],
        "vault_id": registration["initial_vault"]["vault_id"],
        "encryption_public_key": encryption_key,
        "signing_public_key": signing_public_key,
        "signing_key": signer,
    }


def _member_actor(account: dict) -> dict:
    return {
        "account_id": account["account_id"],
        "device_id": account["device_id"],
        "access_token": account["access_token"],
        "login_verifier": account["login_verifier"],
        "username": account["username"],
        "encryption_public_key": account["encryption_public_key"],
        "signing_key": account["signing_key"],
        "private_vault_id": account.get("private_vault_id", account["vault_id"]),
    }


def _build_device_enrollment(api: ApiClient, owner: dict, tmp_path: Path, name: str) -> dict:
    """Build a signed device card and a sealed envelope for every visible vault epoch."""
    sibling_signer = SigningKey(tmp_path, name)
    sibling_id = str(uuid.uuid4())
    encryption_key = b64url(os.urandom(32))
    device_fields = {
        "device_id": sibling_id,
        "signing_public_key": b64url(sibling_signer.public_key),
        "encryption_public_key": encryption_key,
    }
    device = {
        **device_fields,
        "name": "IT-21 Owner sibling",
        "signature": b64url(
            sibling_signer.sign(jcs({"account_id": owner["account_id"], **device_fields}))
        ),
    }
    vault_list = api.request("GET", "/api/v1/vaults", token=owner["access_token"])
    assert vault_list.status == 200, f"IT-21 sibling source vault list failed: {error_code(vault_list)}"
    envelopes = []
    for vault in vault_list.json()["vaults"]:
        for source in vault["key_envelopes"]:
            assert source["recipient_device_id"] == owner["device_id"]
            unsigned = {
                "vault_id": vault["vault_id"],
                "recipient_device_id": sibling_id,
                "key_epoch": source["key_epoch"],
                "membership_version": source["membership_version"],
                "envelope": {
                    "version": 1,
                    "suite": "crypto_box_seal",
                    "ciphertext": b64url(os.urandom(48)),
                },
            }
            envelopes.append(
                {**unsigned, "signature": b64url(owner["signing_key"].sign(jcs(unsigned)))}
            )
    assert envelopes, "IT-21 Owner fixture has no key envelopes to carry to its sibling device"
    approver_device_id = owner["device_id"]
    enrollment = {
        "device": device,
        "approver_device_id": approver_device_id,
        "certificate_signature": b64url(
            owner["signing_key"].sign(
                jcs(
                    {
                        "account_id": owner["account_id"],
                        "approver_device_id": approver_device_id,
                        "device": device,
                    }
                )
            )
        ),
        "vault_key_envelopes": envelopes,
    }
    return {
        "device_id": sibling_id,
        "signing_key": sibling_signer,
        "envelope_count": len(envelopes),
        "request": enrollment,
    }


def _enroll_sibling_device(api: ApiClient, owner: dict, tmp_path: Path) -> dict:
    """Enroll an Owner's additional device, carrying every available vault epoch."""
    sibling = _build_device_enrollment(api, owner, tmp_path, "it21-sibling-device")
    enrolled = api.request(
        "POST",
        "/api/v1/devices",
        token=owner["access_token"],
        json_body=sibling["request"],
    )
    assert enrolled.status in (200, 201), f"IT-21 sibling enrollment failed: {error_code(enrolled)}"
    assert enrolled.json().get("vault_key_envelope_count") == sibling["envelope_count"]
    login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": owner["username"],
            "login_verifier": owner["login_verifier"],
            "device_id": sibling["device_id"],
        },
    )
    assert login.status == 200, f"IT-21 sibling login failed: {error_code(login)}"
    return {**sibling, "access_token": login.json()["access_token"]}


def _membership_member(user_id: str, role: str, encryption_key: str) -> dict:
    return {
        "user_id": user_id,
        "role": role,
        "state": "active",
        "encryption_key_fingerprint": b64url(hashlib.sha256(unb64url(encryption_key)).digest()),
    }


def _membership(
    vault_id: str,
    version: int,
    previous_digest: str | None,
    epoch: int,
    members: list[dict],
    signer_device_id: str,
    signer: SigningKey,
) -> dict:
    manifest = {"key_epoch": epoch, "members": members, "signer_device_id": signer_device_id}
    unsigned = {
        "membership_version": version,
        "previous_digest": previous_digest,
        "manifest": manifest,
    }
    return {
        **unsigned,
        "signature": b64url(signer.sign(jcs({"vault_id": vault_id, **unsigned}))),
    }


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


def _key_envelope(vault_id: str, recipient_device: str, epoch: int, version: int, signer: SigningKey) -> dict:
    unsigned = {
        "recipient_device_id": recipient_device,
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


def _invite_member(
    api: ApiClient,
    owner: dict,
    vault_id: str,
    member: dict,
    role: str,
    *,
    current_members: list[dict],
    current_version: int,
    previous_digest: str,
    accept: bool,
) -> tuple[str, str]:
    member_entry = _membership_member(
        member["account_id"], role, member["encryption_public_key"]
    )
    next_version = current_version + 1
    membership = _membership(
        vault_id,
        next_version,
        previous_digest,
        1,
        [*current_members, member_entry],
        owner["device_id"],
        owner["signing_key"],
    )
    envelope = _key_envelope(vault_id, member["device_id"], 1, next_version, owner["signing_key"])
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": role,
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": envelope,
            "membership": membership,
        },
    )
    assert invitation.status in (200, 201), (
        f"IT-21 {role} invitation failed: {error_code(invitation)}"
    )
    token = invitation.json()["token"]
    if accept:
        accepted = api.request(
            "POST",
            "/api/v1/invitations/accept",
            token=member["access_token"],
            json_body={"token": token},
        )
        assert accepted.status in (200, 201), (
            f"IT-21 {role} acceptance failed: {error_code(accepted)}"
        )
    member["target_membership_version"] = next_version
    return token, _membership_digest(vault_id, membership)


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
    assert created.status in (200, 201), f"IT-21 test vault creation failed: {error_code(created)}"

    owner_member = _membership_member(
        owner["account_id"],
        "owner",
        owner["encryption_public_key"],
    )
    _, digest = _invite_member(
        api,
        owner,
        vault_id,
        member,
        "editor",
        current_members=[owner_member],
        current_version=1,
        previous_digest=_membership_digest(vault_id, initial["membership"]),
        accept=True,
    )
    return vault_id, digest


def _signed_record(
    instance: dict,
    vault_id: str,
    device_id: str,
    signer: SigningKey,
    sequence: int,
    *,
    operation: str = "create",
    base_revision_id: str | None = None,
    record_id: str | None = None,
    membership_version: int = 2,
) -> dict:
    header = {
        "wire_version": 1,
        "server_space_id": instance["server_space_id"],
        "vault_id": vault_id,
        "record_id": record_id or str(uuid.uuid4()),
        "revision_id": str(uuid.uuid4()),
        "base_revision_id": base_revision_id,
        "op_id": str(uuid.uuid4()),
        "device_id": device_id,
        "device_seq": str(sequence),
        "key_epoch": "1",
        "membership_version": str(membership_version),
        "record_schema": 1,
        "operation": operation,
        "crypto_suite": "atermius-vault-v1",
        "kdf_salt": b64url(os.urandom(32)),
    }
    unsigned = {
        "header": header,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(64)),
    }
    return {**unsigned, "signature": b64url(signer.sign(jcs(unsigned)))}


def _push_record(api: ApiClient, instance: dict, actor: dict, vault_id: str, envelope: dict):
    body = {
        "protocol_version": instance.get("protocol_version", 1),
        "server_generation": str(instance["generation"]),
        "vault_id": vault_id,
        "device_id": actor["device_id"],
        "batch_id": str(uuid.uuid4()),
        "operations": [envelope],
    }
    return api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/sync/push",
        token=actor["access_token"],
        json_body=body,
    )


def _upload_object(api: ApiClient, vault_id: str, token: str, content: bytes) -> tuple[str, str]:
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=token,
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    assert initialized.status in (200, 201), f"IT-21 object init failed: {error_code(initialized)}"
    upload_id = initialized.json()["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=token,
        raw_body=content,
        content_type="application/octet-stream",
    )
    assert chunk.status in (200, 201), f"IT-21 object chunk failed: {error_code(chunk)}"
    complete = api.request(
        "POST", f"/api/v1/uploads/{upload_id}/complete", token=token, json_body={}
    )
    assert complete.status in (200, 201), f"IT-21 object complete failed: {error_code(complete)}"
    return object_id, upload_id


def _latest_request(database: Path, vault_id: str) -> dict:
    with sqlite3.connect(database) as connection:
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            "SELECT * FROM vault_deletion_requests WHERE vault_id=? ORDER BY request_id DESC LIMIT 1",
            (vault_id,),
        ).fetchone()
        assert row is not None, "deletion lifecycle did not persist its audit row"
        return dict(row)


def _row_count(database: Path, table: str, vault_id: str) -> int:
    with sqlite3.connect(database) as connection:
        return int(
            connection.execute(f"SELECT COUNT(*) FROM {table} WHERE vault_id=?", (vault_id,)).fetchone()[0]
        )


def _expect_read(api: ApiClient, token: str, method: str, path: str):
    response = api.request(method, path, token=token)
    assert response.status == 200, f"grace-period read {path} failed: HTTP {response.status} {error_code(response)}"
    return response


def _assert_lifecycle_dto(dto: dict, *, vault_id: str, status: str, can_cancel: bool, can_write: bool):
    assert dto.get("vault_id") == vault_id
    assert dto.get("status") == status
    assert dto.get("can_cancel") is can_cancel
    assert dto.get("can_write") is can_write
    if status == "deleting":
        requested = datetime.fromisoformat(dto["requested_at"].replace("Z", "+00:00"))
        deadline = datetime.fromisoformat(dto["purge_after"].replace("Z", "+00:00"))
        assert deadline > requested
    else:
        assert dto.get("requested_at") is None
        assert dto.get("purge_after") is None


def test_vault_deletion_grace_cancel_and_purge(
    api: ApiClient, account: dict, instance: dict, tmp_path: Path
) -> None:
    """IT-21: exercise permissions, grace-period reads, cancellation, purge and retained audit."""
    database = _database_path(api)
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200
    # IT-19 may rotate the server generation earlier in this session; never
    # build sync envelopes from the cached session fixture's old generation.
    instance = live_instance.json()
    owner = _register_owner(api, tmp_path)
    # Use a fresh account so unrelated integration cases cannot exhaust the
    # session-scoped bootstrap account's normalized Login user+peer bucket.
    member = _member_actor(_register_owner(api, tmp_path))
    viewer = _member_actor(_register_owner(api, tmp_path))
    pending_invitee = _member_actor(_register_owner(api, tmp_path))
    vault_id, editor_digest = _create_shared_vault(api, owner, member)
    owner_manifest_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    editor_manifest_member = _membership_member(
        member["account_id"], "editor", member["encryption_public_key"]
    )
    _, viewer_digest = _invite_member(
        api,
        owner,
        vault_id,
        viewer,
        "viewer",
        current_members=[owner_manifest_member, editor_manifest_member],
        current_version=2,
        previous_digest=editor_digest,
        accept=True,
    )
    viewer_manifest_member = _membership_member(
        viewer["account_id"], "viewer", viewer["encryption_public_key"]
    )
    pending_invitation_token, _ = _invite_member(
        api,
        owner,
        vault_id,
        pending_invitee,
        "viewer",
        current_members=[owner_manifest_member, editor_manifest_member, viewer_manifest_member],
        current_version=3,
        previous_digest=viewer_digest,
        accept=False,
    )

    owner_me = _expect_read(api, owner["access_token"], "GET", "/api/v1/me").json()
    member_me = _expect_read(api, member["access_token"], "GET", "/api/v1/me").json()
    assert owner_me["device_id"] == owner["device_id"]
    assert member_me["device_id"] == member["device_id"]
    active_member = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/members", token=member["access_token"]
    )
    assert active_member.status == 200
    editor = next(item for item in active_member.json()["members"] if item["user_id"] == member["account_id"])
    assert editor["role"] == "editor" and editor["state"] == "active"
    viewer_grant = next(item for item in active_member.json()["members"] if item["user_id"] == viewer["account_id"])
    assert viewer_grant["role"] == "viewer" and viewer_grant["state"] == "active"
    member_vault = api.request("GET", "/api/v1/vaults", token=member["access_token"])
    member_target = next(item for item in member_vault.json()["vaults"] if item["vault_id"] == vault_id)
    _assert_lifecycle_dto(member_target, vault_id=vault_id, status="active", can_cancel=False, can_write=True)
    viewer_vaults = api.request("GET", "/api/v1/vaults", token=viewer["access_token"])
    viewer_target = next(item for item in viewer_vaults.json()["vaults"] if item["vault_id"] == vault_id)
    _assert_lifecycle_dto(viewer_target, vault_id=vault_id, status="active", can_cancel=False, can_write=False)
    viewer_active_write = _push_record(
        api,
        instance,
        viewer,
        vault_id,
        _signed_record(
            instance,
            vault_id,
            viewer["device_id"],
            viewer["signing_key"],
            1,
            membership_version=4,
        ),
    )
    assert viewer_active_write.status == 403 and error_code(viewer_active_write) == "VAULT_READ_ONLY"
    pending_invitee_vaults = api.request("GET", "/api/v1/vaults", token=pending_invitee["access_token"])
    assert pending_invitee_vaults.status == 200
    assert vault_id not in {item["vault_id"] for item in pending_invitee_vaults.json()["vaults"]}
    owner_directory = _expect_read(
        api, owner["access_token"], "GET", f"/api/v1/vaults/{vault_id}/devices"
    ).json()["devices"]
    assert {item["device_id"] for item in owner_directory} >= {owner["device_id"], member["device_id"]}

    sibling = _enroll_sibling_device(api, owner, tmp_path)
    sibling_vaults = api.request("GET", "/api/v1/vaults", token=sibling["access_token"])
    assert sibling_vaults.status == 200
    sibling_shared_vault = next(
        item for item in sibling_vaults.json()["vaults"] if item["vault_id"] == vault_id
    )
    assert len(sibling_shared_vault["key_envelopes"]) == 1
    sibling_bad_proof = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=sibling["access_token"],
        json_body={"login_verifier": b64url(os.urandom(32))},
    )
    assert sibling_bad_proof.status == 401 and error_code(sibling_bad_proof) == "REAUTH_REQUIRED"
    sibling_revoked = api.request(
        "POST",
        f"/api/v1/devices/{sibling['device_id']}/revoke",
        token=owner["access_token"],
        json_body={},
    )
    assert sibling_revoked.status in (200, 204), f"IT-21 sibling revoke failed: {error_code(sibling_revoked)}"
    revoked_device_delete = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=sibling["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert revoked_device_delete.status in (401, 403)
    assert error_code(revoked_device_delete) in ("DEVICE_REVOKED", "AUTH_REQUIRED")

    # Known identifiers belonging to the other account do not grant vault,
    # snapshot or object access.
    owner_private = api.request(
        "GET", f"/api/v1/vaults/{member['private_vault_id']}/changes?limit=1", token=owner["access_token"]
    )
    member_private = api.request(
        "GET", f"/api/v1/vaults/{owner['vault_id']}/changes?limit=1", token=member["access_token"]
    )
    assert owner_private.status in (403, 404) and member_private.status in (403, 404)
    private_snapshot = api.request(
        "POST", f"/api/v1/vaults/{member['private_vault_id']}/snapshots", token=member["access_token"]
    )
    assert private_snapshot.status in (200, 201)
    foreign_snapshot_id = private_snapshot.json()["snapshot_id"]
    foreign_object_id, _ = _upload_object(
        api, member["private_vault_id"], member["access_token"], b"private object idor fixture"
    )
    assert api.request("GET", f"/api/v1/snapshots/{foreign_snapshot_id}", token=owner["access_token"]).status == 404
    assert api.request(
        "GET",
        f"/api/v1/vaults/{member['private_vault_id']}/objects/{foreign_object_id}",
        token=owner["access_token"],
    ).status in (403, 404)

    # Write one revision, tombstone it, and store a conflict branch so purge
    # has representative sync children to cascade.
    create = _signed_record(
        instance, vault_id, owner["device_id"], owner["signing_key"], 1, membership_version=4
    )
    created = _push_record(api, instance, owner, vault_id, create)
    assert created.status in (200, 201), f"IT-21 owner write failed: {error_code(created)}"
    create_revision = created.json()["results"][0]["revision_id"]
    update = _signed_record(
        instance,
        vault_id,
        member["device_id"],
        member["signing_key"],
        1,
        operation="update",
        base_revision_id=create_revision,
        record_id=create["header"]["record_id"],
        membership_version=4,
    )
    updated = _push_record(api, instance, member, vault_id, update)
    assert updated.status in (200, 201), f"IT-21 editor write failed: {error_code(updated)}"
    update_revision = updated.json()["results"][0]["revision_id"]
    deleted_record = _signed_record(
        instance,
        vault_id,
        owner["device_id"],
        owner["signing_key"],
        2,
        operation="delete",
        base_revision_id=update_revision,
        record_id=create["header"]["record_id"],
        membership_version=4,
    )
    tombstoned = _push_record(api, instance, owner, vault_id, deleted_record)
    assert tombstoned.status in (200, 201), f"IT-21 tombstone fixture failed: {error_code(tombstoned)}"
    tombstone_revision = tombstoned.json()["results"][0]["revision_id"]

    branch = _signed_record(
        instance, vault_id, owner["device_id"], owner["signing_key"], 3, membership_version=4
    )
    conflict = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts",
        token=owner["access_token"],
        json_body={"envelope": branch},
    )
    assert conflict.status in (200, 201), f"IT-21 conflict fixture failed: {error_code(conflict)}"
    conflict_id = conflict.json()["conflict_id"]
    object_payload = b"opaque deletion object fixture"
    object_id, _ = _upload_object(api, vault_id, owner["access_token"], object_payload)
    open_payload = b"held"
    open_object_id = str(uuid.uuid4())
    open_init = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": open_object_id,
            "size": len(open_payload),
            "sha256": hashlib.sha256(open_payload).hexdigest(),
        },
    )
    assert open_init.status in (200, 201)
    open_upload_id = open_init.json()["upload_id"]
    held_chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{open_upload_id}/chunks/0",
        token=owner["access_token"],
        raw_body=open_payload,
        content_type="application/octet-stream",
    )
    assert held_chunk.status in (200, 201)
    snapshot = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=owner["access_token"]
    )
    assert snapshot.status in (200, 201)
    snapshot_id = snapshot.json()["snapshot_id"]
    with sqlite3.connect(database) as connection:
        connection.execute(
            "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)",
            (vault_id, tombstone_revision, object_id),
        )
        connection.commit()

    for actor in (owner, member):
        bad_delete = api.request(
            "DELETE",
            f"/api/v1/vaults/{vault_id}",
            token=actor["access_token"],
            # A non-owner proves their own identity successfully; lifecycle
            # authorization must still reject their role.
            json_body={
                "login_verifier": (
                    b64url(os.urandom(32)) if actor is owner else actor["login_verifier"]
                )
            },
        )
        if actor is owner:
            assert bad_delete.status == 401 and error_code(bad_delete) == "REAUTH_REQUIRED"
        else:
            assert bad_delete.status == 403 and error_code(bad_delete) == "VAULT_ROLE_REQUIRED"

    viewer_cancel = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/deletion/cancel",
        token=viewer["access_token"],
        json_body={"login_verifier": viewer["login_verifier"]},
    )
    assert viewer_cancel.status == 403 and error_code(viewer_cancel) == "VAULT_ROLE_REQUIRED"

    deleted = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert deleted.status == 200, f"IT-21 delete request failed: {error_code(deleted)}"
    _assert_lifecycle_dto(deleted.json(), vault_id=vault_id, status="deleting", can_cancel=True, can_write=False)
    deadline = deleted.json()["purge_after"]

    repeated = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert repeated.status == 200
    assert repeated.json()["purge_after"] == deadline, "idempotent DELETE must not extend the grace period"

    pending_device = _build_device_enrollment(
        api, owner, tmp_path, "it21-deleting-device"
    )
    pending_device_response = api.request(
        "POST",
        "/api/v1/devices",
        token=owner["access_token"],
        json_body=pending_device["request"],
    )
    assert pending_device_response.status == 409
    assert error_code(pending_device_response) == "VAULT_DELETION_PENDING"

    for actor, can_cancel in ((owner, True), (member, False), (viewer, False)):
        listed = api.request("GET", "/api/v1/vaults", token=actor["access_token"])
        assert listed.status == 200
        dto = next(item for item in listed.json()["vaults"] if item["vault_id"] == vault_id)
        _assert_lifecycle_dto(
            dto, vault_id=vault_id, status="deleting", can_cancel=can_cancel, can_write=False
        )

    # Only active members keep read access. This includes their signed chain,
    # event stream, current snapshots, immutable revisions and opaque objects.
    for actor in (owner, member, viewer):
        _expect_read(api, actor["access_token"], "GET", f"/api/v1/vaults/{vault_id}/members")
        _expect_read(api, actor["access_token"], "GET", f"/api/v1/vaults/{vault_id}/devices")
        _expect_read(api, actor["access_token"], "GET", f"/api/v1/vaults/{vault_id}/membership?from=0")
        _expect_read(api, actor["access_token"], "GET", f"/api/v1/vaults/{vault_id}/changes?limit=10")
        _expect_read(api, actor["access_token"], "GET", f"/api/v1/vaults/{vault_id}/revisions/{tombstone_revision}")
        assert api.request(
            "GET", f"/api/v1/snapshots/{snapshot_id}", token=actor["access_token"]
        ).status == 200
        object_read = api.request(
            "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=actor["access_token"]
        )
        assert object_read.status == 200 and object_read.body == object_payload

    pending_snapshot = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=member["access_token"]
    )
    assert pending_snapshot.status in (200, 201), "active members may pin snapshots during grace"
    assert api.request(
        "GET", f"/api/v1/snapshots/{pending_snapshot.json()['snapshot_id']}", token=member["access_token"]
    ).status == 200

    pending_viewer_snapshot = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=viewer["access_token"]
    )
    assert pending_viewer_snapshot.status in (200, 201)
    assert api.request(
        "GET",
        f"/api/v1/snapshots/{pending_viewer_snapshot.json()['snapshot_id']}",
        token=viewer["access_token"],
    ).status == 200

    pending_accept = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=pending_invitee["access_token"],
        json_body={"token": pending_invitation_token},
    )
    assert pending_accept.status == 409 and error_code(pending_accept) == "VAULT_DELETION_PENDING"

    for actor, sequence in ((owner, 4), (member, 2)):
        write = _signed_record(
            instance,
            vault_id,
            actor["device_id"],
            actor["signing_key"],
            sequence,
            membership_version=4,
        )
        rejected = _push_record(api, instance, actor, vault_id, write)
        assert rejected.status == 409 and error_code(rejected) == "VAULT_DELETION_PENDING", (
            f"deleting vault accepted a {('owner' if actor is owner else 'editor')} record write"
        )
        init = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=actor["access_token"],
            json_body={
                "object_id": str(uuid.uuid4()),
                "size": 3,
                "sha256": hashlib.sha256(b"abc").hexdigest(),
            },
        )
        assert init.status == 409 and error_code(init) == "VAULT_DELETION_PENDING"

    viewer_write = _push_record(
        api,
        instance,
        viewer,
        vault_id,
        _signed_record(
            instance,
            vault_id,
            viewer["device_id"],
            viewer["signing_key"],
            1,
            membership_version=4,
        ),
    )
    assert viewer_write.status == 409 and error_code(viewer_write) == "VAULT_DELETION_PENDING"

    pending_branch = _signed_record(
        instance, vault_id, owner["device_id"], owner["signing_key"], 5, membership_version=4
    )
    conflict_write = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts",
        token=owner["access_token"],
        json_body={"envelope": pending_branch},
    )
    assert conflict_write.status == 409 and error_code(conflict_write) == "VAULT_DELETION_PENDING"
    conflict_resolve = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{conflict_id}/resolve",
        token=owner["access_token"],
        json_body={"resolved_revision_id": tombstone_revision},
    )
    assert conflict_resolve.status == 409 and error_code(conflict_resolve) == "VAULT_DELETION_PENDING"
    rotation_write = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": {
                "membership_version": 5,
                "previous_digest": "synthetic-but-well-formed",
                "manifest": {"key_epoch": 2, "members": [], "signer_device_id": owner["device_id"]},
                "signature": b64url(os.urandom(64)),
            },
            "key_envelopes": [],
        },
    )
    assert rotation_write.status == 409 and error_code(rotation_write) == "VAULT_DELETION_PENDING"
    chunk_write = api.request(
        "PUT",
        f"/api/v1/uploads/{open_upload_id}/chunks/1",
        token=owner["access_token"],
        raw_body=b"new chunk",
        content_type="application/octet-stream",
    )
    assert chunk_write.status == 409 and error_code(chunk_write) == "VAULT_DELETION_PENDING"
    upload_complete = api.request(
        "POST",
        f"/api/v1/uploads/{open_upload_id}/complete",
        token=owner["access_token"],
        json_body={},
    )
    assert upload_complete.status == 409 and error_code(upload_complete) == "VAULT_DELETION_PENDING"

    first_request = _latest_request(database, vault_id)
    assert first_request["cancelled_at"] is None and first_request["purged_at"] is None
    assert first_request["actor_hash"] not in (owner["account_id"], owner["device_id"], owner["username"])
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-400*86400 WHERE request_id=?",
            (first_request["request_id"],),
        )
        connection.commit()
    maintenance = _server_cli(api, "maintenance", env_overrides={"ATERMIUS_AUDIT_RETENTION_DAYS": "1"})
    assert maintenance.returncode == 0, redact_secrets(maintenance.stdout + maintenance.stderr)[-2000:]
    still_pending = _latest_request(database, vault_id)
    assert still_pending["request_id"] == first_request["request_id"]
    assert still_pending["cancelled_at"] is None and still_pending["purged_at"] is None

    # An active member is not an owner and cannot cancel; the owner can cancel
    # before the deadline, preserving the record/object/snapshot data.
    viewer_cancel_during_grace = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/deletion/cancel",
        token=viewer["access_token"],
        json_body={"login_verifier": viewer["login_verifier"]},
    )
    assert viewer_cancel_during_grace.status == 403
    assert error_code(viewer_cancel_during_grace) == "VAULT_ROLE_REQUIRED"
    cancelled = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/deletion/cancel",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert cancelled.status == 200, f"IT-21 cancellation failed: {error_code(cancelled)}"
    _assert_lifecycle_dto(cancelled.json(), vault_id=vault_id, status="active", can_cancel=False, can_write=True)
    accepted_after_cancel = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=pending_invitee["access_token"],
        json_body={"token": pending_invitation_token},
    )
    assert accepted_after_cancel.status in (200, 201), (
        f"IT-21 deferred invitation acceptance after cancel failed: {error_code(accepted_after_cancel)}"
    )
    assert api.request(
        "GET", f"/api/v1/vaults/{vault_id}/revisions/{tombstone_revision}", token=member["access_token"]
    ).status == 200
    assert api.request(
        "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=member["access_token"]
    ).body == object_payload
    cancelled_request = _latest_request(database, vault_id)
    assert cancelled_request["cancelled_at"] is not None and cancelled_request["purged_at"] is None

    # Completed audit entries expire by configured retention; pending ones did
    # not expire in the earlier maintenance pass.
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET cancelled_at=CAST(strftime('%s','now') AS INTEGER)-2*86400 WHERE request_id=?",
            (cancelled_request["request_id"],),
        )
        connection.commit()
    prune_audit = _server_cli(api, "maintenance", env_overrides={"ATERMIUS_AUDIT_RETENTION_DAYS": "1"})
    assert prune_audit.returncode == 0, redact_secrets(prune_audit.stdout + prune_audit.stderr)[-2000:]
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_deletion_requests WHERE request_id=?",
            (cancelled_request["request_id"],),
        ).fetchone()[0] == 0

    redelete = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert redelete.status == 200 and redelete.json()["status"] == "deleting"
    purge_request = _latest_request(database, vault_id)
    assert purge_request["request_id"] != cancelled_request["request_id"]
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-400*86400,purge_after=CAST(strftime('%s','now') AS INTEGER)-1 WHERE request_id=?",
            (purge_request["request_id"],),
        )
        connection.commit()

    expired_cancel = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/deletion/cancel",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert expired_cancel.status == 410 and error_code(expired_cancel) == "VAULT_DELETION_WINDOW_EXPIRED"
    expired_reads = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=member["access_token"]
    )
    assert expired_reads.status == 200, "data remains readable until the atomic maintenance purge"

    # Race coverage also exists in the separate IT-21 terminal-state test.
    # Keep this test's owner authentication bucket available for the explicit
    # invalid-proof throttling case at the end.
    maintenance_after_deadline = _server_cli(api, "maintenance")
    assert maintenance_after_deadline.returncode == 0, redact_secrets(
        maintenance_after_deadline.stdout + maintenance_after_deadline.stderr
    )[-2000:]
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT COUNT(*) FROM vaults WHERE vault_id=?", (vault_id,)).fetchone()[0] == 0
    purge_audit = _latest_request(database, vault_id)
    assert purge_audit["cancelled_at"] is None and purge_audit["purged_at"] is not None
    assert purge_audit["actor_hash"] and len(purge_audit["actor_hash"]) == 64

    # The FK cascade removes records, immutable history, snapshots, upload
    # chunks/blobs, membership chains/invitations, and references. The audit
    # ledger deliberately survives until its own retention expires.
    cascading_tables = (
        "vault_members",
        "vault_key_envelopes",
        "vault_counters",
        "record_heads",
        "record_versions",
        "change_events",
        "op_receipts",
        "batch_receipts",
        "record_graveyard",
        "snapshots",
        "conflicts",
        "uploads",
        "blob_objects",
        "object_references",
        "invitations",
        "membership_manifests",
    )
    for table in cascading_tables:
        assert _row_count(database, table, vault_id) == 0, f"purge did not cascade {table}"
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?", (open_upload_id,)
        ).fetchone()[0] == 0

    for actor in (owner, member, viewer, pending_invitee):
        listed = api.request("GET", "/api/v1/vaults", token=actor["access_token"])
        assert listed.status == 200 and vault_id not in {v["vault_id"] for v in listed.json()["vaults"]}
        assert api.request("GET", f"/api/v1/snapshots/{snapshot_id}", token=actor["access_token"]).status == 404
        assert api.request(
            "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=actor["access_token"]
        ).status in (403, 404)
        assert api.request(
            "GET", f"/api/v1/vaults/{vault_id}/revisions/{tombstone_revision}", token=actor["access_token"]
        ).status in (403, 404)
        assert api.request(
            "GET", f"/api/v1/vaults/{vault_id}/changes?limit=1", token=actor["access_token"]
        ).status == 404, "purged vault routes must not reveal existence to former members"
    assert api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=account["access_token"]
    ).status == 404, "a former member's known snapshot ID must not survive purge"

    # Purged ledger rows are also subject to audit retention. Age the one row
    # directly, then let maintenance remove it under a one-day test policy.
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET purged_at=CAST(strftime('%s','now') AS INTEGER)-2*86400 WHERE request_id=?",
            (purge_audit["request_id"],),
        )
        connection.commit()
    prune_purge_audit = _server_cli(
        api, "maintenance", env_overrides={"ATERMIUS_AUDIT_RETENTION_DAYS": "1"}
    )
    assert prune_purge_audit.returncode == 0, redact_secrets(
        prune_purge_audit.stdout + prune_purge_audit.stderr
    )[-2000:]
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_deletion_requests WHERE request_id=?",
            (purge_audit["request_id"],),
        ).fetchone()[0] == 0

    # Step-up failures count against a fresh account's Login bucket. The
    # default pair limit is 8 per 15-minute window.
    throttle_account = _member_actor(_register_owner(api, tmp_path))
    for attempt in range(9):
        throttled = api.request(
            "DELETE",
            f"/api/v1/vaults/{throttle_account['private_vault_id']}",
            token=throttle_account["access_token"],
            json_body={"login_verifier": b64url(os.urandom(32))},
        )
        if attempt < 8:
            assert throttled.status == 401 and error_code(throttled) == "REAUTH_REQUIRED"
        else:
            assert throttled.status == 429
    assert error_code(throttled) == "RATE_LIMITED"
    assert int(throttled.headers.get("Retry-After", "0")) > 0


def test_vault_deletion_expired_cancel_races_maintenance(
    api: ApiClient, tmp_path: Path
) -> None:
    """IT-21 race case: deadline-winning maintenance leaves a single purged terminal state."""
    database = _database_path(api)
    owner = _register_owner(api, tmp_path)
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
    assert created.status in (200, 201), f"IT-21 race vault creation failed: {error_code(created)}"
    started = api.request(
        "DELETE",
        f"/api/v1/vaults/{vault_id}",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert started.status == 200, f"IT-21 race delete start failed: {error_code(started)}"
    request = _latest_request(database, vault_id)
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-400*86400,purge_after=CAST(strftime('%s','now') AS INTEGER)-1 WHERE request_id=?",
            (request["request_id"],),
        )
        connection.commit()

    barrier = threading.Barrier(2)

    def cancel():
        barrier.wait(timeout=5)
        return api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/deletion/cancel",
            token=owner["access_token"],
            json_body={"login_verifier": owner["login_verifier"]},
        )

    def maintain():
        barrier.wait(timeout=5)
        return _server_cli(api, "maintenance")

    with ThreadPoolExecutor(max_workers=2) as executor:
        cancel_future = executor.submit(cancel)
        maintenance_future = executor.submit(maintain)
        result = cancel_future.result(timeout=45)
        maintenance = maintenance_future.result(timeout=45)
    assert maintenance.returncode == 0, redact_secrets(maintenance.stdout + maintenance.stderr)[-2000:]
    assert result.status in (404, 410), (
        "cancel-versus-maintenance race must not reactivate a vault after the purge deadline"
    )
    if result.status == 410:
        assert error_code(result) == "VAULT_DELETION_WINDOW_EXPIRED"
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT COUNT(*) FROM vaults WHERE vault_id=?", (vault_id,)).fetchone()[0] == 0
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            "SELECT cancelled_at,purged_at FROM vault_deletion_requests WHERE request_id=?",
            (request["request_id"],),
        ).fetchone()
        assert row and row["cancelled_at"] is None and row["purged_at"] is not None
