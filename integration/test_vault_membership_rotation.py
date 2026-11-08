"""Black-box checks for signed membership role changes and member revocation."""

from __future__ import annotations

import os
import sqlite3
import uuid

import pytest

from conftest import ApiClient, SigningKey, b64url, initial_vault, jcs, verify_ed25519
from test_acceptance import (
    _issue_account_invitation,
    _membership_digest,
    _membership_member,
    _new_account_registration,
    _signed_key_envelope,
    _signed_membership,
)


def _error_code(response) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _vault_ids(response) -> set[str]:
    body = response.json()
    if not isinstance(body, dict) or not isinstance(body.get("vaults"), list):
        return set()
    return {
        item["vault_id"]
        for item in body["vaults"]
        if isinstance(item, dict) and isinstance(item.get("vault_id"), str)
    }


def _audit_events(api: ApiClient, token: str) -> list[dict]:
    response = api.request("GET", "/api/v1/audit?limit=200", token=token)
    assert response.status == 200, f"audit request failed: {_error_code(response)}"
    body = response.json()
    assert isinstance(body, dict) and isinstance(body.get("events"), list)
    return body["events"]


def _register_account(api: ApiClient, tmp_path, label: str) -> dict:
    username = f"it-membership-{label}-{uuid.uuid4().hex[:10]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    signer = SigningKey(tmp_path, f"membership-{label}")
    token = _issue_account_invitation(api, username)
    registration = _new_account_registration(
        account_id, username, device_id, encryption_public_key, signer
    )
    response = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={**registration, "instance_invitation_token": token},
    )
    assert response.status in (200, 201), (
        f"{label} account enrollment failed with HTTP {response.status}: {_error_code(response)}"
    )
    body = response.json()
    assert isinstance(body, dict) and isinstance(body.get("access_token"), str)
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "login_verifier": registration["login_verifier"],
        "access_token": body["access_token"],
        "encryption_public_key": encryption_public_key,
        "signing_key": signer,
        "signing_public_key": b64url(signer.public_key),
    }


def _active_device_ids(api: ApiClient, account: dict) -> list[str]:
    response = api.request("GET", "/api/v1/devices", token=account["access_token"])
    assert response.status == 200, f"device list failed with HTTP {response.status}"
    return sorted(
        device["device_id"]
        for device in response.json().get("devices", [])
        if device.get("status") == "active"
    )


def _rotation_envelopes(
    vault_id: str, version: int, epoch: int, device_ids: list[str], owner: dict
) -> list[dict]:
    return [
        {
            **_signed_key_envelope(
                vault_id,
                recipient_device_id,
                epoch,
                version,
                owner["signing_key"],
            ),
            "signer_device_id": owner["device_id"],
        }
        for recipient_device_id in device_ids
    ]


def _display_name_envelope() -> dict:
    return {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(48)),
    }


def _signed_rotation_membership(
    vault_id: str,
    version: int,
    previous_digest: str,
    epoch: int,
    members: list[dict],
    signer_device_id: str,
    signer: SigningKey,
    display_name_envelope: dict,
) -> dict:
    membership = _signed_membership(
        vault_id,
        version,
        previous_digest,
        epoch,
        members,
        signer_device_id,
        signer,
    )
    manifest = {
        **membership["manifest"],
        "display_name_envelope": display_name_envelope,
    }
    unsigned = {
        "membership_version": membership["membership_version"],
        "previous_digest": membership["previous_digest"],
        "manifest": manifest,
    }
    payload = {"vault_id": vault_id, **unsigned}
    return {**unsigned, "signature": b64url(signer.sign(jcs(payload)))}


def _record_envelope(
    instance: dict,
    vault_id: str,
    account: dict,
    *,
    epoch: int,
    membership_version: int,
    device_seq: int,
) -> dict:
    header = {
        "wire_version": 1,
        "server_space_id": instance["server_space_id"],
        "vault_id": vault_id,
        "record_id": str(uuid.uuid4()),
        "revision_id": str(uuid.uuid4()),
        "base_revision_id": None,
        "op_id": str(uuid.uuid4()),
        "device_id": account["device_id"],
        "device_seq": str(device_seq),
        "key_epoch": str(epoch),
        "membership_version": str(membership_version),
        "record_schema": 1,
        "operation": "create",
        "crypto_suite": "atermius-vault-v1",
        "kdf_salt": b64url(os.urandom(32)),
    }
    unsigned = {
        "header": header,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(64)),
    }
    return {**unsigned, "signature": b64url(account["signing_key"].sign(jcs(unsigned)))}


def _push(
    api: ApiClient,
    instance: dict,
    vault_id: str,
    account: dict,
    envelope: dict,
    *,
    batch_id: str | None = None,
):
    return api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/sync/push",
        token=account["access_token"],
        json_body={
            "protocol_version": instance.get("protocol_version", 1),
            "server_generation": str(instance["generation"]),
            "vault_id": vault_id,
            "device_id": account["device_id"],
            "batch_id": batch_id or str(uuid.uuid4()),
            "operations": [envelope],
        },
    )


def _assert_current_device_envelope(
    api: ApiClient, account: dict, vault_id: str, epoch: int, version: int
) -> None:
    listed = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert listed.status == 200, f"vault list failed with HTTP {listed.status}"
    vault = next(item for item in listed.json()["vaults"] if item["vault_id"] == vault_id)
    assert vault["active_key_epoch"] == epoch
    assert vault["membership_version"] == version
    item = next(
        key
        for key in vault["key_envelopes"]
        if key["recipient_device_id"] == account["device_id"]
        and key["key_epoch"] == epoch
        and key["membership_version"] == version
    )
    assert item["signer_device_id"] == account["device_id"]
    signed = {
        "vault_id": vault_id,
        "recipient_device_id": item["recipient_device_id"],
        "key_epoch": item["key_epoch"],
        "membership_version": item["membership_version"],
        "envelope": item["envelope"],
    }
    assert verify_ed25519(
        account["signing_public_key"], jcs(signed), item["signature"]
    ), "returned key envelope must retain its owner signature"


def _assert_vault_name_envelope(
    api: ApiClient, account: dict, vault_id: str, expected: dict
) -> None:
    listed = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert listed.status == 200, f"vault list failed with HTTP {listed.status}"
    vault = next(item for item in listed.json()["vaults"] if item["vault_id"] == vault_id)
    assert vault["name_envelope"] == expected


def _sync_write_state(database_path, vault_id: str) -> dict:
    with sqlite3.connect(database_path) as connection:
        counter = connection.execute(
            "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
            (vault_id,),
        ).fetchone()
        assert counter is not None, "shared Vault must have a commit counter"
        return {
            "last_committed_seq": counter[0],
            "versions": connection.execute(
                "SELECT COUNT(*) FROM record_versions WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            "events": connection.execute(
                "SELECT COUNT(*) FROM change_events WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            "heads": connection.execute(
                "SELECT COUNT(*) FROM record_heads WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            "operation_receipts": connection.execute(
                "SELECT COUNT(*) FROM op_receipts WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            "batch_receipts": connection.execute(
                "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
        }


def test_revoked_editor_cannot_commit_pre_signed_outbox_operation(
    api: ApiClient, account: dict, instance: dict, tmp_path
) -> None:
    """A ciphertext operation signed while Editor is active cannot commit after revocation."""
    if api.temp_root is None:
        pytest.skip("exact sync-ledger assertions require the disposable server database")
    database_path = api.temp_root / "data" / "atermius.db"

    owner = _register_account(api, tmp_path, "revocation-owner")
    editor = _register_account(api, tmp_path, "revocation-editor")
    shared = initial_vault(
        account_id=owner["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    created = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": shared["vault_id"],
            "name_envelope": shared["name_envelope"],
            "key_envelope": shared["key_envelope"],
            "membership": shared["membership"],
        },
    )
    assert created.status in (200, 201), f"Vault create failed: {_error_code(created)}"
    vault_id = shared["vault_id"]

    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    editor_member = _membership_member(
        editor["account_id"], "editor", editor["encryption_public_key"]
    )
    membership_v2 = _signed_membership(
        vault_id,
        2,
        _membership_digest(vault_id, shared["membership"]),
        1,
        [owner_member, editor_member],
        owner["device_id"],
        owner["signing_key"],
    )
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": editor["device_id"],
            "recipient_encryption_public_key": editor["encryption_public_key"],
            "key_envelope": _signed_key_envelope(
                vault_id, editor["device_id"], 1, 2, owner["signing_key"]
            ),
            "membership": membership_v2,
        },
    )
    assert invitation.status in (200, 201), f"Vault invite failed: {_error_code(invitation)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=editor["access_token"],
        json_body={"token": invitation.json()["token"]},
    )
    assert accepted.status in (200, 201), f"invite acceptance failed: {_error_code(accepted)}"

    # This is the exact signed envelope an offline Editor would retain in its
    # outbox. It is created while membership v2 and key epoch 1 still grant
    # write access, then left unsent until after the Owner revokes the Editor.
    queued_operation = _record_envelope(
        instance,
        vault_id,
        editor,
        epoch=1,
        membership_version=2,
        device_seq=1,
    )
    assert set(queued_operation) == {"header", "nonce", "ciphertext", "signature"}
    batch_id = str(uuid.uuid4())

    revoked_member = {
        **_membership_member(
            editor["account_id"], "editor", editor["encryption_public_key"]
        ),
        "state": "revoked",
    }
    membership_v3 = _signed_rotation_membership(
        vault_id,
        3,
        _membership_digest(vault_id, membership_v2),
        2,
        [owner_member, revoked_member],
        owner["device_id"],
        owner["signing_key"],
        _display_name_envelope(),
    )
    owner_device_ids = _active_device_ids(api, owner)
    assert editor["device_id"] not in owner_device_ids
    rotated = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": membership_v3,
            "key_envelopes": _rotation_envelopes(
                vault_id, 3, 2, owner_device_ids, owner
            ),
        },
    )
    assert rotated.status in (200, 201), f"member revocation failed: {_error_code(rotated)}"

    before = _sync_write_state(database_path, vault_id)
    denied = _push(
        api, instance, vault_id, editor, queued_operation, batch_id=batch_id
    )
    assert denied.status == 404, "revoked member's already-signed outbox write must be hidden/denied"
    after = _sync_write_state(database_path, vault_id)
    assert after == before, "denied revoked-member write mutated shared sync state"

    with sqlite3.connect(database_path) as connection:
        assert connection.execute(
            "SELECT 1 FROM op_receipts WHERE vault_id=? AND op_id=?",
            (vault_id, queued_operation["header"]["op_id"]),
        ).fetchone() is None
        assert connection.execute(
            "SELECT 1 FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
            (vault_id, editor["device_id"], batch_id),
        ).fetchone() is None
        assert connection.execute(
            "SELECT 1 FROM record_versions WHERE vault_id=? AND record_id=?",
            (vault_id, queued_operation["header"]["record_id"]),
        ).fetchone() is None
        assert connection.execute(
            "SELECT 1 FROM change_events WHERE vault_id=? AND record_id=?",
            (vault_id, queued_operation["header"]["record_id"]),
        ).fetchone() is None
        assert connection.execute(
            "SELECT 1 FROM record_heads WHERE vault_id=? AND record_id=?",
            (vault_id, queued_operation["header"]["record_id"]),
        ).fetchone() is None


def test_signed_rotation_changes_role_then_revokes_member(
    api: ApiClient, account: dict, instance: dict, tmp_path
) -> None:
    """A signed rotation updates ACLs and stops key delivery to a revoked member."""
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200, "could not read current server generation"
    instance = live_instance.json()
    owner = _register_account(api, tmp_path, "owner")
    member = _register_account(api, tmp_path, "member")

    shared = initial_vault(
        account_id=owner["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    created = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": shared["vault_id"],
            "name_envelope": shared["name_envelope"],
            "key_envelope": shared["key_envelope"],
            "membership": shared["membership"],
        },
    )
    assert created.status in (200, 201), f"vault create failed: {_error_code(created)}"
    vault_id = shared["vault_id"]
    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    editor_member = _membership_member(
        member["account_id"], "editor", member["encryption_public_key"]
    )
    genesis_digest = _membership_digest(vault_id, shared["membership"])

    invitation_membership = _signed_membership(
        vault_id,
        2,
        genesis_digest,
        1,
        [owner_member, editor_member],
        owner["device_id"],
        owner["signing_key"],
    )
    invitation_key = _signed_key_envelope(
        vault_id, member["device_id"], 1, 2, owner["signing_key"]
    )
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": invitation_key,
            "membership": invitation_membership,
        },
    )
    assert invitation.status in (200, 201), f"vault invite failed: {_error_code(invitation)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=member["access_token"],
        json_body={"token": invitation.json()["token"]},
    )
    assert accepted.status in (200, 201), f"invite acceptance failed: {_error_code(accepted)}"

    member_vaults = api.request("GET", "/api/v1/vaults", token=member["access_token"])
    assert member_vaults.status == 200
    shared_item = next(
        item for item in member_vaults.json()["vaults"] if item["vault_id"] == vault_id
    )
    assert shared_item["role"] == "editor"
    assert shared_item["active_key_epoch"] == 1
    assert shared_item["membership_version"] == 2

    record = _record_envelope(
        instance,
        vault_id,
        owner,
        epoch=1,
        membership_version=2,
        device_seq=1,
    )
    committed = _push(api, instance, vault_id, owner, record)
    assert committed.status in (200, 201), f"owner push failed: {_error_code(committed)}"
    record_id = record["header"]["record_id"]
    snapshot_response = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=owner["access_token"]
    )
    assert snapshot_response.status in (200, 201), "owner could not create shared vault snapshot"
    snapshot_id = snapshot_response.json()["snapshot_id"]

    viewer_member = _membership_member(
        member["account_id"], "viewer", member["encryption_public_key"]
    )
    viewer_name_envelope = _display_name_envelope()
    viewer_membership = _signed_rotation_membership(
        vault_id,
        3,
        _membership_digest(vault_id, invitation_membership),
        2,
        [owner_member, viewer_member],
        owner["device_id"],
        owner["signing_key"],
        viewer_name_envelope,
    )
    viewer_recipients = sorted(
        set(_active_device_ids(api, owner) + _active_device_ids(api, member))
    )
    viewer_rotation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": viewer_membership,
            "key_envelopes": _rotation_envelopes(
                vault_id, 3, 2, viewer_recipients, owner
            ),
        },
    )
    assert viewer_rotation.status in (200, 201), (
        f"editor-to-viewer rotation failed: {_error_code(viewer_rotation)}"
    )

    owner_audit = _audit_events(api, owner["access_token"])
    role_events = [
        event
        for event in owner_audit
        if event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.member_role_changed"
    ]
    assert len(role_events) == 1, "role rotation must audit its target once"
    role_event = role_events[0]
    assert role_event["resource_type"] == "membership"
    assert role_event["resource_id"] == member["account_id"]
    assert role_event["actor_user_id"] == owner["account_id"]
    assert role_event["actor_device_id"] == owner["device_id"]
    assert role_event["result"] == "success" and role_event["source"] == "api"
    assert member["username"] not in str(role_event), "audit row must not store usernames"
    assert any(
        event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.key_rotated"
        for event in owner_audit
    ), "member change must retain the separate key-rotation event"
    assert not any(
        event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.membership_changed"
        for event in owner_audit
    ), "generic membership event must be replaced by target-specific audit"

    member_vaults = api.request("GET", "/api/v1/vaults", token=member["access_token"])
    shared_item = next(
        item for item in member_vaults.json()["vaults"] if item["vault_id"] == vault_id
    )
    assert shared_item["role"] == "viewer"
    assert shared_item["active_key_epoch"] == 2
    assert shared_item["membership_version"] == 3
    assert shared_item["name_envelope"] == viewer_name_envelope
    member_audit = _audit_events(api, member["access_token"])
    assert all(event["vault_id"] != vault_id for event in member_audit), (
        "Viewer must not receive Owner/Editor Vault audit events"
    )
    member_key = next(
        key
        for key in shared_item["key_envelopes"]
        if key["recipient_device_id"] == member["device_id"]
        and key["key_epoch"] == 2
        and key["membership_version"] == 3
    )
    owner_directory = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/devices", token=member["access_token"]
    )
    assert owner_directory.status == 200
    owner_public_key = next(
        device["signing_public_key"]
        for device in owner_directory.json()["devices"]
        if device["device_id"] == owner["device_id"]
    )
    member_key_payload = {
        "vault_id": vault_id,
        "recipient_device_id": member_key["recipient_device_id"],
        "key_epoch": member_key["key_epoch"],
        "membership_version": member_key["membership_version"],
        "envelope": member_key["envelope"],
    }
    assert member_key["signer_device_id"] == owner["device_id"]
    assert verify_ed25519(owner_public_key, jcs(member_key_payload), member_key["signature"])
    _assert_current_device_envelope(api, owner, vault_id, epoch=2, version=3)
    _assert_vault_name_envelope(api, owner, vault_id, viewer_name_envelope)

    members = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/members", token=owner["access_token"]
    )
    changed_member = next(
        item
        for item in members.json()["members"]
        if item["user_id"] == member["account_id"]
    )
    assert changed_member["role"] == "viewer" and changed_member["state"] == "active"

    readable_snapshot = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=member["access_token"]
    )
    assert readable_snapshot.status == 200, (
        "viewer should retain read access to committed ciphertext"
    )
    assert any(
        item.get("record_id") == record_id
        for item in readable_snapshot.json().get("manifest", [])
    ), "viewer snapshot omitted the owner's existing record"
    viewer_write = _push(
        api,
        instance,
        vault_id,
        member,
        _record_envelope(
            instance,
            vault_id,
            member,
            epoch=2,
            membership_version=3,
            device_seq=1,
        ),
    )
    assert viewer_write.status == 403 and _error_code(viewer_write) == "VAULT_READ_ONLY"

    revoked_name_envelope = _display_name_envelope()
    revoked_member = {
        **_membership_member(
            member["account_id"], "editor", member["encryption_public_key"]
        ),
        "state": "revoked",
    }
    revoked_membership = _signed_rotation_membership(
        vault_id,
        4,
        _membership_digest(vault_id, viewer_membership),
        3,
        [owner_member, revoked_member],
        owner["device_id"],
        owner["signing_key"],
        revoked_name_envelope,
    )
    owner_recipients = _active_device_ids(api, owner)
    assert member["device_id"] not in owner_recipients
    final_key_envelopes = _rotation_envelopes(
        vault_id, 4, 3, owner_recipients, owner
    )
    assert {item["recipient_device_id"] for item in final_key_envelopes} == set(owner_recipients)
    assert all(item["recipient_device_id"] != member["device_id"] for item in final_key_envelopes)
    revoked_rotation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 3,
            "membership": revoked_membership,
            "key_envelopes": final_key_envelopes,
        },
    )
    assert revoked_rotation.status in (200, 201), (
        f"member revocation rotation failed: {_error_code(revoked_rotation)}"
    )

    owner_audit = _audit_events(api, owner["access_token"])
    revoke_events = [
        event
        for event in owner_audit
        if event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.member_revoked"
    ]
    assert len(revoke_events) == 1, "revocation rotation must audit its target once"
    revoke_event = revoke_events[0]
    assert revoke_event["resource_type"] == "membership"
    assert revoke_event["resource_id"] == member["account_id"]
    assert revoke_event["actor_user_id"] == owner["account_id"]
    assert revoke_event["actor_device_id"] == owner["device_id"]
    assert member["username"] not in str(revoke_event), "audit row must not store usernames"
    assert sum(
        event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.member_role_changed"
        and event["resource_id"] == member["account_id"]
        for event in owner_audit
    ) == 1, "combined role change and revocation must be represented only by revocation"
    assert sum(
        event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.key_rotated"
        for event in owner_audit
    ) == 2, "both role change and revocation must retain their key-rotation audit"
    assert not any(
        event["scope"] == "vault"
        and event["vault_id"] == vault_id
        and event["action"] == "vault.membership_changed"
        for event in owner_audit
    ), "generic membership event must not be emitted"

    owner_members = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/members", token=owner["access_token"]
    )
    revoked_member = next(
        item
        for item in owner_members.json()["members"]
        if item["user_id"] == member["account_id"]
    )
    assert revoked_member["state"] == "revoked"

    membership_chain = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/membership?from=0",
        token=owner["access_token"],
    )
    assert membership_chain.status == 200
    chain = membership_chain.json()["manifests"]
    assert [entry["membership_version"] for entry in chain] == [1, 2, 3, 4]
    viewer_record = next(
        entry["manifest"] for entry in chain if entry["membership_version"] == 3
    )
    revoked_record = next(
        entry["manifest"] for entry in chain if entry["membership_version"] == 4
    )
    for record, version in ((viewer_record, 3), (revoked_record, 4)):
        signed_membership = {
            "vault_id": vault_id,
            "membership_version": record["membership_version"],
            "previous_digest": record["previous_digest"],
            "manifest": record["manifest"],
        }
        assert record["membership_version"] == version
        assert verify_ed25519(
            owner["signing_public_key"],
            jcs(signed_membership),
            record["signature"],
        ), "stored role and revocation transitions must retain owner signatures"
    viewer_roles = {
        item["user_id"]: item["role"] for item in viewer_record["manifest"]["members"]
    }
    revoked_states = {
        item["user_id"]: item["state"]
        for item in revoked_record["manifest"]["members"]
    }
    assert viewer_roles[member["account_id"]] == "viewer"
    assert revoked_states[member["account_id"]] == "revoked"
    assert viewer_record["manifest"]["display_name_envelope"] == viewer_name_envelope
    assert revoked_record["manifest"]["display_name_envelope"] == revoked_name_envelope

    _assert_current_device_envelope(api, owner, vault_id, epoch=3, version=4)
    _assert_vault_name_envelope(api, owner, vault_id, revoked_name_envelope)
    owner_vaults = api.request("GET", "/api/v1/vaults", token=owner["access_token"])
    owner_item = next(
        item for item in owner_vaults.json()["vaults"] if item["vault_id"] == vault_id
    )
    assert not any(
        key["recipient_device_id"] == member["device_id"] and key["key_epoch"] == 3
        for key in owner_item["key_envelopes"]
    ), "owner device response must not contain a revoked member's epoch envelope"

    member_vaults = api.request("GET", "/api/v1/vaults", token=member["access_token"])
    assert member_vaults.status == 200
    assert vault_id not in _vault_ids(member_vaults), (
        "revoked member must lose the shared vault listing"
    )
    for path in (
        f"/api/v1/vaults/{vault_id}/members",
        f"/api/v1/vaults/{vault_id}/devices",
        f"/api/v1/vaults/{vault_id}/membership?from=0",
        f"/api/v1/vaults/{vault_id}/changes?limit=1",
        f"/api/v1/snapshots/{snapshot_id}",
    ):
        denied = api.request("GET", path, token=member["access_token"])
        assert denied.status == 404, (
            f"revoked member retained access to {path}: HTTP {denied.status}"
        )

    revoked_write = _push(
        api,
        instance,
        vault_id,
        member,
        _record_envelope(
            instance,
            vault_id,
            member,
            epoch=2,
            membership_version=3,
            device_seq=2,
        ),
    )
    assert revoked_write.status == 404, "revoked device must not write into the shared vault"

    owner_snapshot = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=owner["access_token"]
    )
    assert owner_snapshot.status == 200
    assert any(
        item.get("record_id") == record_id
        for item in owner_snapshot.json().get("manifest", [])
    ), "revocation must preserve the owner's historical record"


def test_empty_workspace_can_enroll_device_and_create_a_new_vault(
    api: ApiClient, account: dict, tmp_path
) -> None:
    """An account with no active membership can enroll a device with no envelopes."""
    if not api.temp_root:
        pytest.skip("empty-workspace state setup requires the disposable server database")

    user = _register_account(api, tmp_path, "empty-workspace")
    database = api.temp_root / "data" / "atermius.db"
    with sqlite3.connect(database, timeout=10) as connection:
        changed = connection.execute(
            "UPDATE vault_members SET state='revoked' WHERE user_id=?",
            (user["account_id"],),
        )
        assert changed.rowcount == 1, "fixture should revoke the user's only Vault membership"
        connection.commit()

    vaults = api.request("GET", "/api/v1/vaults", token=user["access_token"])
    assert vaults.status == 200
    assert vaults.json().get("vaults") == [], "revoked account should have an empty workspace"

    signer = SigningKey(tmp_path, "empty-workspace-device")
    new_device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    device_fields = {
        "device_id": new_device_id,
        "encryption_public_key": encryption_public_key,
        "signing_public_key": b64url(signer.public_key),
    }
    device = {
        **device_fields,
        "name": "empty-workspace-device",
        "signature": b64url(
            signer.sign(jcs({"account_id": user["account_id"], **device_fields}))
        ),
    }
    certificate = b64url(
        user["signing_key"].sign(
            jcs(
                {
                    "account_id": user["account_id"],
                    "approver_device_id": user["device_id"],
                    "device": device,
                }
            )
        )
    )
    enrollment = api.request(
        "POST",
        "/api/v1/devices",
        token=user["access_token"],
        json_body={
            "device": device,
            "approver_device_id": user["device_id"],
            "certificate_signature": certificate,
            "vault_key_envelopes": [],
        },
    )
    assert enrollment.status in (200, 201), (
        f"empty-envelope enrollment failed with HTTP {enrollment.status}: {_error_code(enrollment)}"
    )
    assert enrollment.json().get("vault_key_envelope_count") == 0

    login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": user["username"],
            "login_verifier": user["login_verifier"],
            "device_id": new_device_id,
        },
    )
    assert login.status == 200, f"new empty-workspace device login failed: {_error_code(login)}"
    new_token = login.json()["access_token"]
    empty_vaults = api.request("GET", "/api/v1/vaults", token=new_token)
    assert empty_vaults.status == 200 and empty_vaults.json().get("vaults") == []

    new_id = str(uuid.uuid4())
    initial = initial_vault(
        account_id=user["account_id"],
        vault_id=new_id,
        device_id=new_device_id,
        encryption_public_key=encryption_public_key,
        signer=signer,
    )
    created = api.request(
        "POST",
        "/api/v1/vaults",
        token=new_token,
        json_body={
            "vault_id": new_id,
            "name_envelope": initial["name_envelope"],
            "key_envelope": initial["key_envelope"],
            "membership": initial["membership"],
        },
    )
    assert created.status in (200, 201), (
        f"new Vault creation failed with HTTP {created.status}: {_error_code(created)}"
    )
    restored = api.request("GET", "/api/v1/vaults", token=new_token)
    assert restored.status == 200
    assert _vault_ids(restored) == {new_id}
