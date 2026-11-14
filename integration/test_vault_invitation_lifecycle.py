"""Black-box lifecycle tests for vault invitations on a disposable instance."""

from __future__ import annotations

import json
import os
import sqlite3
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from urllib.parse import unquote

import pytest

from conftest import ApiClient, SigningKey, b64url, initial_vault, jcs
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


def _register_account(api: ApiClient, tmp_path: Path, label: str) -> dict:
    username = f"it-invite-lifecycle-{label}-{uuid.uuid4().hex[:8]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    signer = SigningKey(tmp_path, f"invite-lifecycle-{label}")
    registration = _new_account_registration(
        account_id,
        username,
        device_id,
        encryption_public_key,
        signer,
    )
    response = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "instance_invitation_token": _issue_account_invitation(api, username),
        },
    )
    assert response.status in (200, 201), (
        f"{label} enrollment failed with HTTP {response.status}: {_error_code(response)}"
    )
    body = response.json()
    assert isinstance(body, dict) and isinstance(body.get("access_token"), str)
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "access_token": body["access_token"],
        "encryption_public_key": encryption_public_key,
        "signing_key": signer,
        "signing_public_key": b64url(signer.public_key),
    }


def _create_invitation(
    api: ApiClient,
    owner: dict,
    recipient: dict,
    *,
    expires_in_seconds: int = 604800,
) -> dict:
    vault = initial_vault(
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
            "vault_id": vault["vault_id"],
            "name_envelope": vault["name_envelope"],
            "key_envelope": vault["key_envelope"],
            "membership": vault["membership"],
        },
    )
    assert created.status in (200, 201), f"vault create failed: {_error_code(created)}"

    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    recipient_member = _membership_member(
        recipient["account_id"], "editor", recipient["encryption_public_key"]
    )
    membership = _signed_membership(
        vault["vault_id"],
        2,
        _membership_digest(vault["vault_id"], vault["membership"]),
        1,
        [owner_member, recipient_member],
        owner["device_id"],
        owner["signing_key"],
    )
    key_envelope = _signed_key_envelope(
        vault["vault_id"], recipient["device_id"], 1, 2, owner["signing_key"]
    )
    issued = api.request(
        "POST",
        f"/api/v1/vaults/{vault['vault_id']}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": recipient["device_id"],
            "recipient_encryption_public_key": recipient["encryption_public_key"],
            "key_envelope": key_envelope,
            "membership": membership,
            "expires_in_seconds": expires_in_seconds,
        },
    )
    assert issued.status in (200, 201), f"invite create failed: {_error_code(issued)}"
    return {
        "vault_id": vault["vault_id"],
        "token": issued.json()["token"],
        "invitation_id": issued.json()["invitation_id"],
        "expires_at": issued.json()["expires_at"],
        "membership": membership,
    }


def _expire_invitation(api: ApiClient, invitation_id: str) -> None:
    admin_env = getattr(api, "admin_env", None)
    assert admin_env is not None, "expiry case requires the suite-owned temporary SQLite database"
    database_url = admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://"), "expiry case requires a temporary SQLite database"
    database_path = Path(unquote(database_url[len("sqlite://") :].split("?", 1)[0]))
    with sqlite3.connect(database_path) as connection:
        result = connection.execute(
            "UPDATE invitations SET expires_at='2000-01-01T00:00:00+00:00' WHERE invitation_id=?",
            (invitation_id,),
        )
        assert result.rowcount == 1, "temporary invitation expiry fixture was not found"
        connection.commit()


def _rotation_envelopes(api: ApiClient, owner: dict, vault_id: str, version: int) -> list[dict]:
    devices = api.request("GET", "/api/v1/devices", token=owner["access_token"])
    assert devices.status == 200, "owner device listing failed"
    active = sorted(
        item["device_id"]
        for item in devices.json().get("devices", [])
        if item.get("status") == "active"
    )
    return [
        {
            **_signed_key_envelope(vault_id, device_id, 2, version, owner["signing_key"]),
            "signer_device_id": owner["device_id"],
        }
        for device_id in active
    ]


def _signed_revocation_membership(invite: dict, owner: dict, recipient: dict) -> dict:
    members = [
        _membership_member(owner["account_id"], "owner", owner["encryption_public_key"]),
        {
            **_membership_member(
                recipient["account_id"], "editor", recipient["encryption_public_key"]
            ),
            "state": "revoked",
        },
    ]
    membership = _signed_membership(
        invite["vault_id"],
        3,
        _membership_digest(invite["vault_id"], invite["membership"]),
        2,
        members,
        owner["device_id"],
        owner["signing_key"],
    )
    display_name_envelope = {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(48)),
    }
    manifest = {
        **membership["manifest"],
        "display_name_envelope": display_name_envelope,
    }
    unsigned = {
        "membership_version": membership["membership_version"],
        "previous_digest": membership["previous_digest"],
        "manifest": manifest,
    }
    return {
        **unsigned,
        "signature": b64url(
            owner["signing_key"].sign(jcs({"vault_id": invite["vault_id"], **unsigned}))
        ),
    }


def _accept(api: ApiClient, token: str, credential: str):
    return api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=credential,
        json_body={"token": token},
    )


def test_vault_invitation_expiry_binding_concurrency_and_revocation(
    api: ApiClient, account: dict, tmp_path: Path
) -> None:
    """Expired, misbound, duplicate, concurrent, and revoked invitations fail safely."""
    if not api.started_by_suite or not api.admin_env:
        pytest.skip("invitation lifecycle cases require the suite-owned disposable SQLite instance")

    owner = _register_account(api, tmp_path, "owner")
    first_recipient = _register_account(api, tmp_path, "first-recipient")
    expired_recipient = _register_account(api, tmp_path, "expired-recipient")
    concurrent_recipient = _register_account(api, tmp_path, "concurrent-recipient")
    revoked_device_recipient = _register_account(api, tmp_path, "revoked-device-recipient")

    # A wrong account cannot consume the invitation; the addressed account can
    # still accept it once. The second accept is rejected as already used.
    bound_invite = _create_invitation(api, owner, first_recipient)
    pending_members = api.request(
        "GET", f"/api/v1/vaults/{bound_invite['vault_id']}/members", token=owner["access_token"]
    )
    pending_row = next(
        item for item in pending_members.json()["members"]
        if item["user_id"] == first_recipient["account_id"]
    )
    assert pending_row["invitation"] == {
        "status": "pending",
        "expires_at": bound_invite["expires_at"],
    }
    assert set(pending_row["invitation"]) == {"status", "expires_at"}
    assert bound_invite["token"] not in json.dumps(pending_members.json())
    assert "token_hash" not in json.dumps(pending_members.json())
    assert "key_envelope" not in json.dumps(pending_members.json())
    wrong_account = _accept(api, bound_invite["token"], account["access_token"])
    assert wrong_account.status == 403
    assert _error_code(wrong_account) == "INVITATION_RECIPIENT_MISMATCH"
    accepted = _accept(api, bound_invite["token"], first_recipient["access_token"])
    assert accepted.status in (200, 201), f"recipient acceptance failed: {_error_code(accepted)}"
    accepted_members = api.request(
        "GET", f"/api/v1/vaults/{bound_invite['vault_id']}/members", token=owner["access_token"]
    )
    accepted_row = next(
        item for item in accepted_members.json()["members"]
        if item["user_id"] == first_recipient["account_id"]
    )
    assert accepted_row["state"] == "active" and accepted_row["invitation"] is None
    repeated = _accept(api, bound_invite["token"], first_recipient["access_token"])
    assert repeated.status == 409 and _error_code(repeated) == "INVITATION_USED"

    # Set the disposable DB row into the past rather than sleeping for the
    # minimum 60-second TTL. The HTTP path still checks the real bearer token.
    expired_invite = _create_invitation(
        api, owner, expired_recipient, expires_in_seconds=60
    )
    _expire_invitation(api, expired_invite["invitation_id"])
    expired_members = api.request(
        "GET", f"/api/v1/vaults/{expired_invite['vault_id']}/members", token=owner["access_token"]
    )
    expired_row = next(
        item for item in expired_members.json()["members"]
        if item["user_id"] == expired_recipient["account_id"]
    )
    assert expired_row["invitation"] == {
        "status": "expired",
        "expires_at": "2000-01-01T00:00:00+00:00",
    }
    expired = _accept(api, expired_invite["token"], expired_recipient["access_token"])
    assert expired.status == 410 and _error_code(expired) == "INVITATION_EXPIRED"
    expired_vaults = api.request(
        "GET", "/api/v1/vaults", token=expired_recipient["access_token"]
    )
    assert expired_vaults.status == 200
    assert expired_invite["vault_id"] not in {
        item["vault_id"] for item in expired_vaults.json()["vaults"]
    }, "an expired invite must not grant vault access"

    # The migration deliberately leaves historical issuance order unknown.
    # Multiple legacy rows cannot be ordered, and their stored expiries must
    # not leak into the status DTO.
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://")
    database_path = Path(unquote(database_url[len("sqlite://") :].split("?", 1)[0]))
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            "UPDATE invitations SET created_at=NULL,issuance_order=NULL WHERE invitation_id=?",
            (expired_invite["invitation_id"],),
        )
        connection.execute(
            "INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,recipient_device_id,signer_device_id,created_by,expires_at,created_at,issuance_order) "
            "SELECT ?,vault_id,?,role,key_envelope,recipient_user_id,recipient_device_id,signer_device_id,created_by,'2099-01-01T00:00:00+00:00',NULL,NULL "
            "FROM invitations WHERE invitation_id=?",
            (str(uuid.uuid4()), f"legacy-{uuid.uuid4().hex}", expired_invite["invitation_id"]),
        )
        connection.commit()
    legacy_members = api.request(
        "GET", f"/api/v1/vaults/{expired_invite['vault_id']}/members", token=owner["access_token"]
    )
    legacy_row = next(
        item for item in legacy_members.json()["members"]
        if item["user_id"] == expired_recipient["account_id"]
    )
    assert legacy_row["invitation"] == {
        "status": "reissue_required",
        "expires_at": None,
    }
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            "DELETE FROM invitations WHERE vault_id=? AND recipient_user_id=?",
            (expired_invite["vault_id"], expired_recipient["account_id"]),
        )
        connection.commit()
    missing_members = api.request(
        "GET", f"/api/v1/vaults/{expired_invite['vault_id']}/members", token=owner["access_token"]
    )
    missing_row = next(
        item for item in missing_members.json()["members"]
        if item["user_id"] == expired_recipient["account_id"]
    )
    assert missing_row["invitation"] == {
        "status": "reissue_required",
        "expires_at": None,
    }

    # A device-bound token cannot be accepted after its target device is
    # revoked, so directory state asks the owner to issue a replacement.
    revoked_device_invite = _create_invitation(api, owner, revoked_device_recipient)
    revoked_device = api.request(
        "POST",
        f"/api/v1/devices/{revoked_device_recipient['device_id']}/revoke",
        token=revoked_device_recipient["access_token"],
        json_body={},
    )
    assert revoked_device.status in (200, 204), (
        f"recipient device revoke failed: {_error_code(revoked_device)}"
    )
    revoked_device_members = api.request(
        "GET",
        f"/api/v1/vaults/{revoked_device_invite['vault_id']}/members",
        token=owner["access_token"],
    )
    assert revoked_device_members.status == 200
    revoked_device_row = next(
        item
        for item in revoked_device_members.json()["members"]
        if item["user_id"] == revoked_device_recipient["account_id"]
    )
    assert revoked_device_row["invitation"] == {
        "status": "reissue_required",
        "expires_at": None,
    }

    # Simultaneous requests are serialized: exactly one consumes the token,
    # while the other observes INVITATION_USED.
    concurrent_invite = _create_invitation(api, owner, concurrent_recipient)
    barrier = Barrier(2)

    def accept_together():
        barrier.wait(timeout=10)
        return _accept(
            api,
            concurrent_invite["token"],
            concurrent_recipient["access_token"],
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: accept_together(), range(2)))
    assert sorted(response.status for response in results) == [200, 409]
    used = next(response for response in results if response.status == 409)
    assert _error_code(used) == "INVITATION_USED"

    # An owner-signed rotation revokes a pending invite before it is accepted.
    # The old token becomes stale and the DB ACL stays revoked.
    revoked_invite = _create_invitation(api, owner, first_recipient)
    membership = _signed_revocation_membership(
        revoked_invite, owner, first_recipient
    )
    rotation = api.request(
        "POST",
        f"/api/v1/vaults/{revoked_invite['vault_id']}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": membership,
            "key_envelopes": _rotation_envelopes(
                api, owner, revoked_invite["vault_id"], version=3
            ),
        },
    )
    assert rotation.status in (200, 201), (
        f"pending invite revocation failed: {_error_code(rotation)}"
    )
    stale_accept = _accept(
        api, revoked_invite["token"], first_recipient["access_token"]
    )
    assert stale_accept.status == 409 and _error_code(stale_accept) == "INVITATION_STALE"
    members = api.request(
        "GET",
        f"/api/v1/vaults/{revoked_invite['vault_id']}/members",
        token=owner["access_token"],
    )
    assert members.status == 200
    revoked_row = next(
        item
        for item in members.json()["members"]
        if item["user_id"] == first_recipient["account_id"]
    )
    assert revoked_row["state"] == "revoked"
    first_vaults = api.request("GET", "/api/v1/vaults", token=first_recipient["access_token"])
    assert revoked_invite["vault_id"] not in {
        item["vault_id"] for item in first_vaults.json()["vaults"]
    }, "a revoked pending invite must not grant access after failed acceptance"


def test_vault_invitation_expiring_during_accept_is_not_consumed(
    api: ApiClient, account: dict, tmp_path: Path
) -> None:
    """Expiry is checked again at token consumption, and failed accept rolls back."""
    if not api.started_by_suite or not api.admin_env:
        pytest.skip("expiry-race case requires the suite-owned disposable SQLite instance")

    owner = _register_account(api, tmp_path, "expiry-race-owner")
    recipient = _register_account(api, tmp_path, "expiry-race-recipient")
    invitation = _create_invitation(api, owner, recipient, expires_in_seconds=60)
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://"), "expiry-race case requires temporary SQLite"
    database_path = Path(unquote(database_url[len("sqlite://") :].split("?", 1)[0]))
    with sqlite3.connect(database_path) as connection:
        original_expiry = connection.execute(
            "SELECT expires_at FROM invitations WHERE invitation_id=?",
            (invitation["invitation_id"],),
        ).fetchone()[0]

    # This trigger moves the expiry past the deadline after the handler's
    # initial expiry check, during its ACL activation transaction.
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            """
            CREATE TRIGGER expire_invitation_during_accept
            AFTER UPDATE OF state ON vault_members
            WHEN OLD.state='invited' AND NEW.state='active'
            BEGIN
                UPDATE invitations
                SET expires_at='2000-01-01T00:00:00+00:00'
                WHERE vault_id=NEW.vault_id AND accepted_at IS NULL;
            END
            """
        )

    try:
        result = _accept(api, invitation["token"], recipient["access_token"])
    finally:
        with sqlite3.connect(database_path) as connection:
            connection.execute("DROP TRIGGER IF EXISTS expire_invitation_during_accept")

    assert result.status == 410 and _error_code(result) == "INVITATION_EXPIRED"
    with sqlite3.connect(database_path) as connection:
        accepted_at, persisted_expiry = connection.execute(
            "SELECT accepted_at,expires_at FROM invitations WHERE invitation_id=?",
            (invitation["invitation_id"],),
        ).fetchone()
        member_state = connection.execute(
            "SELECT state FROM vault_members WHERE vault_id=? AND user_id=?",
            (invitation["vault_id"], recipient["account_id"]),
        ).fetchone()[0]
    assert accepted_at is None, "expired invite must remain unconsumed"
    assert persisted_expiry == original_expiry, "failed acceptance must roll back expiry mutation"
    assert member_state == "invited", "failed acceptance must roll back the ACL activation"
