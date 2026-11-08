"""Black-box checks for owner-authorized, signed Vault ownership transfer."""

from __future__ import annotations

import uuid

from conftest import ApiClient, b64url, initial_vault, jcs, verify_ed25519
from test_acceptance import (
    _membership_digest,
    _membership_member,
    _signed_key_envelope,
)
from test_vault_membership_rotation import (
    _active_device_ids,
    _audit_events,
    _display_name_envelope,
    _error_code,
    _register_account,
    _rotation_envelopes,
    _signed_rotation_membership,
)


def _signed_transfer_membership(
    vault_id: str,
    version: int,
    previous_digest: str,
    epoch: int,
    members: list[dict],
    signer_device_id: str,
    signer: dict,
) -> dict:
    membership = _signed_rotation_membership(
        vault_id,
        version,
        previous_digest,
        epoch,
        members,
        signer_device_id,
        signer["signing_key"],
        _display_name_envelope(),
    )
    manifest = {
        **membership["manifest"],
        "ownership_transfer": {
            "from_user_id": signer["account_id"],
            "to_user_id": next(
                member["user_id"]
                for member in members
                if member["role"] == "owner" and member["state"] == "active"
            ),
        },
    }
    unsigned = {
        "membership_version": membership["membership_version"],
        "previous_digest": membership["previous_digest"],
        "manifest": manifest,
    }
    payload = {"vault_id": vault_id, **unsigned}
    return {**unsigned, "signature": b64url(signer["signing_key"].sign(jcs(payload)))}


def _transfer_request(
    vault_id: str,
    owner: dict,
    target: dict,
    membership: dict,
    recipients: list[str],
    *,
    epoch: int = 2,
) -> dict:
    return {
        "new_owner_user_id": target["account_id"],
        "new_epoch": epoch,
        "membership": membership,
        "key_envelopes": _rotation_envelopes(
            vault_id,
            membership["membership_version"],
            epoch,
            recipients,
            owner,
        ),
    }


def _listed_vault(api: ApiClient, account: dict, vault_id: str) -> dict:
    response = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert response.status == 200, f"vault list failed with HTTP {response.status}"
    return next(item for item in response.json()["vaults"] if item["vault_id"] == vault_id)


def _assert_failed_attempt_kept_state(
    api: ApiClient,
    owner: dict,
    vault_id: str,
    *,
    expected_name: dict,
    expected_versions: int = 3,
) -> None:
    vault = _listed_vault(api, owner, vault_id)
    assert vault["role"] == "owner"
    assert vault["active_key_epoch"] == 1
    assert vault["membership_version"] == 3
    assert vault["name_envelope"] == expected_name
    chain = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/membership?from=0",
        token=owner["access_token"],
    )
    assert chain.status == 200
    assert len(chain.json()["manifests"]) == expected_versions


def test_owner_transfer_is_signed_atomic_and_usable_by_new_owner(
    api: ApiClient, account: dict, tmp_path
) -> None:
    instance = api.request("GET", "/api/v1/instance")
    assert instance.status == 200
    owner = _register_account(api, tmp_path, "transfer-owner")
    target = _register_account(api, tmp_path, "transfer-viewer")
    pending = _register_account(api, tmp_path, "transfer-pending")

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
    target_member = _membership_member(
        target["account_id"], "viewer", target["encryption_public_key"]
    )
    pending_member = _membership_member(
        pending["account_id"], "editor", pending["encryption_public_key"]
    )

    target_name = _display_name_envelope()
    target_membership = _signed_rotation_membership(
        vault_id,
        2,
        _membership_digest(vault_id, shared["membership"]),
        1,
        [owner_member, target_member],
        owner["device_id"],
        owner["signing_key"],
        target_name,
    )
    target_invite = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "viewer",
            "recipient_device_id": target["device_id"],
            "recipient_encryption_public_key": target["encryption_public_key"],
            "key_envelope": _signed_key_envelope(
                vault_id, target["device_id"], 1, 2, owner["signing_key"]
            ),
            "membership": target_membership,
        },
    )
    assert target_invite.status in (200, 201), f"target invite failed: {_error_code(target_invite)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=target["access_token"],
        json_body={"token": target_invite.json()["token"]},
    )
    assert accepted.status in (200, 201), f"target accept failed: {_error_code(accepted)}"

    pending_name = _display_name_envelope()
    pending_membership = _signed_rotation_membership(
        vault_id,
        3,
        _membership_digest(vault_id, target_membership),
        1,
        [owner_member, target_member, pending_member],
        owner["device_id"],
        owner["signing_key"],
        pending_name,
    )
    pending_invite = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": pending["device_id"],
            "recipient_encryption_public_key": pending["encryption_public_key"],
            "key_envelope": _signed_key_envelope(
                vault_id, pending["device_id"], 1, 3, owner["signing_key"]
            ),
            "membership": pending_membership,
        },
    )
    assert pending_invite.status in (200, 201), f"pending invite failed: {_error_code(pending_invite)}"

    owner_member_after = _membership_member(
        owner["account_id"], "editor", owner["encryption_public_key"]
    )
    target_owner_member = _membership_member(
        target["account_id"], "owner", target["encryption_public_key"]
    )
    pending_recipients = sorted(
        set(
            _active_device_ids(api, owner)
            + _active_device_ids(api, target)
            + _active_device_ids(api, pending)
        )
    )
    transfer_membership = _signed_transfer_membership(
        vault_id,
        4,
        _membership_digest(vault_id, pending_membership),
        2,
        [owner_member_after, target_owner_member, pending_member],
        owner["device_id"],
        owner,
    )

    # Self-transfer is rejected before any membership or key state can change.
    self_request = _transfer_request(
        vault_id,
        owner,
        {**owner, "account_id": owner["account_id"]},
        transfer_membership,
        pending_recipients,
    )
    self_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=self_request,
    )
    assert self_response.status == 400 and _error_code(self_response) == "INVALID_OWNER_TRANSFER"
    _assert_failed_attempt_kept_state(api, owner, vault_id, expected_name=pending_name)

    # A still-invited target cannot become Owner, even when the outgoing Owner signs it.
    pending_owner_member = _membership_member(
        pending["account_id"], "owner", pending["encryption_public_key"]
    )
    pending_transfer = _signed_transfer_membership(
        vault_id,
        4,
        _membership_digest(vault_id, pending_membership),
        2,
        [owner_member_after, target_member, pending_owner_member],
        owner["device_id"],
        owner,
    )
    pending_request = _transfer_request(
        vault_id,
        owner,
        pending,
        pending_transfer,
        pending_recipients,
    )
    pending_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=pending_request,
    )
    assert pending_response.status == 409
    assert _error_code(pending_response) == "OWNER_TRANSFER_TARGET_INVALID"
    _assert_failed_attempt_kept_state(api, owner, vault_id, expected_name=pending_name)

    stale_membership = _signed_transfer_membership(
        vault_id,
        3,
        _membership_digest(vault_id, target_membership),
        2,
        [owner_member_after, target_owner_member],
        owner["device_id"],
        owner,
    )
    stale_request = _transfer_request(
        vault_id, owner, target, stale_membership, pending_recipients
    )
    stale_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=stale_request,
    )
    assert stale_response.status == 409
    assert _error_code(stale_response) == "MEMBERSHIP_VERSION_CONFLICT"
    _assert_failed_attempt_kept_state(api, owner, vault_id, expected_name=pending_name)

    # Omit one retained active device: the whole transfer must roll back.
    valid_request = _transfer_request(
        vault_id, owner, target, transfer_membership, pending_recipients
    )
    valid_request["key_envelopes"] = valid_request["key_envelopes"][:-1]
    incomplete_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=valid_request,
    )
    assert incomplete_response.status == 422
    _assert_failed_attempt_kept_state(api, owner, vault_id, expected_name=pending_name)

    valid_request = _transfer_request(
        vault_id, owner, target, transfer_membership, pending_recipients
    )
    transferred = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=valid_request,
    )
    assert transferred.status in (200, 201), f"transfer failed: {_error_code(transferred)}"
    assert transferred.json()["owner_user_id"] == target["account_id"]
    assert transferred.json()["active_key_epoch"] == 2
    assert transferred.json()["membership_version"] == 4

    former_owner_vault = _listed_vault(api, owner, vault_id)
    new_owner_vault = _listed_vault(api, target, vault_id)
    assert former_owner_vault["role"] == "editor"
    assert new_owner_vault["role"] == "owner"
    assert former_owner_vault["active_key_epoch"] == 2
    assert new_owner_vault["membership_version"] == 4
    assert former_owner_vault["name_envelope"] == transfer_membership["manifest"]["display_name_envelope"]

    transfer_audit = [
        event
        for event in _audit_events(api, owner["access_token"])
        if event["scope"] == "vault" and event["vault_id"] == vault_id
    ]
    transfer_role_events = [
        event
        for event in transfer_audit
        if event["action"] == "vault.member_role_changed"
    ]
    assert len(transfer_role_events) == 2
    assert {event["resource_id"] for event in transfer_role_events} == {
        owner["account_id"],
        target["account_id"],
    }, "ownership transfer must audit both actual member role changes"
    assert all(
        event["resource_type"] == "membership"
        and event["actor_user_id"] == owner["account_id"]
        and event["actor_device_id"] == owner["device_id"]
        and event["result"] == "success"
        and event["source"] == "api"
        for event in transfer_role_events
    )
    ownership_events = [
        event
        for event in transfer_audit
        if event["action"] == "vault.ownership_transferred"
    ]
    assert len(ownership_events) == 1
    assert ownership_events[0]["resource_type"] == "membership"
    assert ownership_events[0]["resource_id"] == target["account_id"]
    assert ownership_events[0]["actor_user_id"] == owner["account_id"]
    assert any(event["action"] == "vault.key_rotated" for event in transfer_audit)

    transfer_record = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/membership?from=0",
        token=target["access_token"],
    )
    assert transfer_record.status == 200
    chain = transfer_record.json()["manifests"]
    assert [entry["membership_version"] for entry in chain] == [1, 2, 3, 4]
    record = chain[-1]["manifest"]
    assert record["manifest"]["ownership_transfer"] == {
        "from_user_id": owner["account_id"],
        "to_user_id": target["account_id"],
    }
    assert record["vault_id"] == vault_id
    assert record["membership_version"] == chain[-1]["membership_version"]
    assert record["previous_digest"] == chain[-1]["previous_digest"]
    signed_record = {
        "vault_id": record["vault_id"],
        "membership_version": record["membership_version"],
        "previous_digest": record["previous_digest"],
        "manifest": record["manifest"],
    }
    assert verify_ed25519(
        owner["signing_public_key"],
        jcs(signed_record),
        record["signature"],
    ), "transfer membership must remain signed by the outgoing Owner"
    target_key = next(
        item
        for item in new_owner_vault["key_envelopes"]
        if item["recipient_device_id"] == target["device_id"]
        and item["key_epoch"] == 2
        and item["membership_version"] == 4
    )
    key_payload = {
        "vault_id": vault_id,
        "recipient_device_id": target_key["recipient_device_id"],
        "key_epoch": target_key["key_epoch"],
        "membership_version": target_key["membership_version"],
        "envelope": target_key["envelope"],
    }
    assert target_key["signer_device_id"] == owner["device_id"]
    assert verify_ed25519(
        owner["signing_public_key"], jcs(key_payload), target_key["signature"]
    )

    former_owner_action = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/ownership/transfer",
        token=owner["access_token"],
        json_body=valid_request,
    )
    assert former_owner_action.status == 403

    stale_token_acceptance = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=pending["access_token"],
        json_body={"token": pending_invite.json()["token"]},
    )
    assert stale_token_acceptance.status == 409
    assert _error_code(stale_token_acceptance) == "INVITATION_STALE"

    # After ownership transfer, the new Owner can make the next normal signed rotation.
    next_owner_member = _membership_member(
        target["account_id"], "owner", target["encryption_public_key"]
    )
    next_former_owner = _membership_member(
        owner["account_id"], "editor", owner["encryption_public_key"]
    )
    next_membership = _signed_rotation_membership(
        vault_id,
        5,
        _membership_digest(vault_id, transfer_membership),
        3,
        [next_former_owner, next_owner_member, pending_member],
        target["device_id"],
        target["signing_key"],
        _display_name_envelope(),
    )
    next_recipients = sorted(
        set(
            _active_device_ids(api, owner)
            + _active_device_ids(api, target)
            + _active_device_ids(api, pending)
        )
    )
    next_rotation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/keys/rotate",
        token=target["access_token"],
        json_body={
            "new_epoch": 3,
            "membership": next_membership,
            "key_envelopes": _rotation_envelopes(
                vault_id, 5, 3, next_recipients, target
            ),
        },
    )
    assert next_rotation.status in (200, 201), (
        f"new Owner rotation failed: {_error_code(next_rotation)}"
    )
    assert _listed_vault(api, target, vault_id)["role"] == "owner"
    assert _listed_vault(api, owner, vault_id)["role"] == "editor"
