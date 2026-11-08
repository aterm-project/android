"""Black-box acceptance for client-encrypted online account recovery."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from conftest import ApiClient, SigningKey, b64url, initial_vault, jcs, unb64url
from test_acceptance import (
    _membership_digest,
    _membership_member,
    _signed_key_envelope,
    _signed_membership,
)
from test_account_deletion import _db_path, _register_account
from test_vault_membership_rotation import (
    _active_device_ids,
    _display_name_envelope,
    _register_account as _register_membership_account,
    _rotation_envelopes,
    _signed_rotation_membership,
)


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _opaque_envelope(ciphertext_size: int = 64) -> dict:
    return {
        "version": 1,
        "suite": "xchacha20-poly1305-ietf",
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(ciphertext_size)),
    }


def _account_key_envelope() -> dict:
    return {
        "version": 1,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(96)),
    }


def _identity_proof(
    *, account_id: str, instance: dict, generation: int,
    signing_public_key: str, encryption_public_key: str,
    recovery_envelope: dict, identity_envelope: dict, signer: SigningKey,
) -> str:
    descriptor = {
        "protocol": "atermius-account-recovery-descriptor-v1",
        "account_id": account_id,
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": generation,
        "recovery_public_signing_key": signing_public_key,
        "recovery_public_encryption_key": encryption_public_key,
    }
    descriptor_hash = hashlib.sha256(jcs(descriptor)).hexdigest()
    payload = {
        "protocol": "atermius-account-recovery-identity-v1",
        "account_id": account_id,
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": generation,
        "recovery_descriptor_hash": descriptor_hash,
        "recovery_envelope_sha256": hashlib.sha256(jcs(recovery_envelope)).hexdigest(),
        "recovery_identity_envelope_sha256": hashlib.sha256(jcs(identity_envelope)).hexdigest(),
    }
    return b64url(signer.sign(jcs(payload)))


def _recovery_box(
    *, account_id: str, instance: dict, generation: int,
    signing_public_key: str, encryption_public_key: str,
    vault_id: str, key_epoch: int, uploader_device_id: str,
    signer: SigningKey, ciphertext: bytes | None = None,
) -> dict:
    ciphertext = ciphertext or os.urandom(48)
    envelope = {
        "version": 1,
        "suite": "crypto_box_seal",
        "ciphertext": b64url(ciphertext),
    }
    descriptor = {
        "protocol": "atermius-account-recovery-descriptor-v1",
        "account_id": account_id,
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": generation,
        "recovery_public_signing_key": signing_public_key,
        "recovery_public_encryption_key": encryption_public_key,
    }
    descriptor_hash = hashlib.sha256(jcs(descriptor)).hexdigest()
    digest = hashlib.sha256(ciphertext).hexdigest()
    payload = {
        "protocol": "atermius-account-recovery-v1",
        "account_id": account_id,
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": generation,
        "recovery_descriptor_hash": descriptor_hash,
        "vault_id": vault_id,
        "key_epoch": key_epoch,
        "uploader_device_id": uploader_device_id,
        "envelope_sha256": digest,
    }
    return {
        "vault_id": vault_id,
        "key_epoch": key_epoch,
        "uploader_device_id": uploader_device_id,
        "envelope": envelope,
        "envelope_sha256": digest,
        "recovery_signature": b64url(signer.sign(jcs(payload))),
    }


def _enroll_second_device(
    api: ApiClient,
    account: dict,
    context: dict,
    directory: Path,
    *,
    label: str = "recovery-sync-device",
    login_after_registration: bool = True,
) -> dict:
    signer = SigningKey(directory, label)
    device_id = str(uuid.uuid4())
    device = {
        "device_id": device_id,
        "name": "Second recovery sync device",
        "signing_public_key": b64url(signer.public_key),
        "encryption_public_key": b64url(os.urandom(32)),
    }
    device["signature"] = b64url(signer.sign(jcs({
        "account_id": account["account_id"],
        "device_id": device_id,
        "signing_public_key": device["signing_public_key"],
        "encryption_public_key": device["encryption_public_key"],
    })))
    vault_envelope = {
        "version": 1,
        "suite": "crypto_box_seal",
        "ciphertext": b64url(os.urandom(48)),
    }
    vault_payload = {
        "vault_id": context["vault_id"],
        "recipient_device_id": device_id,
        "key_epoch": context["key_epoch"],
        "membership_version": context["membership_version"],
        "envelope": vault_envelope,
    }
    certificate_payload = {
        "account_id": account["account_id"],
        "approver_device_id": account["device_id"],
        "device": device,
    }
    registered = api.request(
        "POST", "/api/v1/devices", token=account["access_token"], json_body={
            "device": device,
            "approver_device_id": account["device_id"],
            "certificate_signature": b64url(account["signing_key"].sign(jcs(certificate_payload))),
            "vault_key_envelopes": [{
                **vault_payload,
                "signature": b64url(account["signing_key"].sign(jcs(vault_payload))),
            }],
        },
    )
    assert registered.status == 200, f"second device enrollment failed: {_error_code(registered)}"
    if not login_after_registration:
        return {"device_id": device_id}
    login = api.request("POST", "/api/v1/auth/login", json_body={
        "username": account["username"],
        "login_verifier": account["login_verifier"],
        "device_id": device_id,
    })
    assert login.status == 200, f"second device login failed: {_error_code(login)}"
    return {
        "device_id": device_id,
        "signing_key": signer,
        "access_token": login.json()["access_token"],
        "refresh_token": login.json()["refresh_token"],
    }


def _configure_recovery(
    api: ApiClient, account: dict, instance: dict, recovery_signer: SigningKey,
    recovery_encryption_public_key: str, *, generation: int = 1,
    key_envelopes: list[dict] | None = None,
    previous_recovery_signature: str | None = None,
) -> dict:
    signing_public_key = b64url(recovery_signer.public_key)
    recovery_envelope = _opaque_envelope(528)
    identity_envelope = _opaque_envelope(96)
    request = {
        "operation_id": str(uuid.uuid4()),
        "current_login_verifier": account["login_verifier"],
        "recovery_generation": generation,
        "recovery_public_signing_key": signing_public_key,
        "recovery_public_encryption_key": recovery_encryption_public_key,
        "recovery_envelope": recovery_envelope,
        "recovery_identity_envelope": identity_envelope,
        "key_envelopes": key_envelopes or [],
        "recovery_identity_proof_signature": _identity_proof(
            account_id=account["account_id"], instance=instance,
            generation=generation, signing_public_key=signing_public_key,
            encryption_public_key=recovery_encryption_public_key,
            recovery_envelope=recovery_envelope, identity_envelope=identity_envelope,
            signer=recovery_signer,
        ),
    }
    if previous_recovery_signature is not None:
        request["previous_recovery_signature"] = previous_recovery_signature
    request["proof_signature"] = b64url(account["signing_key"].sign(jcs(request)))
    response = api.request(
        "PUT", "/api/v1/auth/recovery", token=account["access_token"], json_body=request
    )
    assert response.status == 200, f"recovery setup failed: HTTP {response.status} {_error_code(response)}"
    return request


def _completion_side_effect_snapshot(
    connection: sqlite3.Connection,
    *,
    account_id: str,
    new_device_id: str,
    operation_id: str,
    challenge_id_hash: str,
    fingerprint_key: bytes,
) -> dict:
    credentials = connection.execute(
        "SELECT login_verifier_hash,verifier_salt,kdf_json,account_key_envelope,credential_version "
        "FROM auth_credentials WHERE user_id=?",
        (account_id,),
    ).fetchone()
    assert credentials is not None
    credential_fingerprint = hmac.new(
        fingerprint_key,
        json.dumps(credentials, separators=(",", ":")).encode(),
        hashlib.sha256,
    ).digest()
    recovery = connection.execute(
        "SELECT recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,"
        "recovery_envelope,recovery_identity_envelope,created_at,updated_at "
        "FROM account_recovery WHERE user_id=?",
        (account_id,),
    ).fetchone()
    assert recovery is not None
    recovery_fingerprint = hmac.new(
        fingerprint_key,
        json.dumps(recovery, separators=(",", ":")).encode(),
        hashlib.sha256,
    ).digest()
    return {
        "credential_fingerprint": credential_fingerprint,
        "recovery_fingerprint": recovery_fingerprint,
        "device_counts": connection.execute(
            "SELECT COUNT(*),SUM(status='active'),SUM(status='revoked') FROM devices WHERE user_id=?",
            (account_id,),
        ).fetchone(),
        "new_device_count": connection.execute(
            "SELECT COUNT(*) FROM devices WHERE user_id=? AND device_id=?",
            (account_id, new_device_id),
        ).fetchone()[0],
        "new_device_keybox_count": connection.execute(
            "SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_user_id=? AND recipient_device_id=?",
            (account_id, new_device_id),
        ).fetchone()[0],
        "session_counts": connection.execute(
            "SELECT SUM(revoked_at IS NULL),SUM(revoked_at IS NOT NULL) FROM sessions WHERE user_id=?",
            (account_id,),
        ).fetchone(),
        "recovery_generation": connection.execute(
            "SELECT recovery_generation FROM account_recovery WHERE user_id=?",
            (account_id,),
        ).fetchone()[0],
        "next_generation_keybox_count": connection.execute(
            "SELECT COUNT(*) FROM account_recovery_key_envelopes WHERE user_id=? AND recovery_generation=(SELECT recovery_generation+1 FROM account_recovery WHERE user_id=?)",
            (account_id, account_id),
        ).fetchone()[0],
        "recovery_keybox_count": connection.execute(
            "SELECT COUNT(*) FROM account_recovery_key_envelopes WHERE user_id=?",
            (account_id,),
        ).fetchone()[0],
        "receipt_count": connection.execute(
            "SELECT COUNT(*) FROM account_recovery_receipts WHERE user_id=? AND operation_id=?",
            (account_id, operation_id),
        ).fetchone()[0],
        "recovered_audit_count": connection.execute(
            "SELECT COUNT(*) FROM audit_events WHERE scope_type='account' AND scope_id=? AND action='auth.account_recovered'",
            (account_id,),
        ).fetchone()[0],
        "relay_ticket_count": connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE user_id=?",
            (account_id,),
        ).fetchone()[0],
        "notification_ticket_count": connection.execute(
            "SELECT COUNT(*) FROM notification_tickets WHERE user_id=?",
            (account_id,),
        ).fetchone()[0],
        "mfa_state": connection.execute(
            "SELECT "
            "(SELECT COUNT(*) FROM auth_mfa WHERE user_id=?),"
            "(SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=?),"
            "(SELECT COUNT(*) FROM auth_mfa_login_challenges WHERE user_id=?)",
            (account_id, account_id, account_id),
        ).fetchone(),
        "mfa_reset_audit_count": connection.execute(
            "SELECT COUNT(*) FROM audit_events "
            "WHERE scope_type='account' AND scope_id=? AND action='auth.mfa_reset_by_recovery'",
            (account_id,),
        ).fetchone()[0],
        "challenge_consumed_at": connection.execute(
            "SELECT consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=?",
            (challenge_id_hash,),
        ).fetchone()[0],
    }


def _seed_recovery_challenge_rows(
    connection: sqlite3.Connection,
    *,
    count: int,
    expires_at: int,
    real_user_id: str | None = None,
) -> list[str]:
    rows = []
    for index in range(count):
        challenge_id_hash = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
        challenge_hash = hashlib.sha256(f"recovery-cap-{index}-{uuid.uuid4()}".encode()).hexdigest()
        owner = real_user_id if index == 0 and real_user_id is not None else None
        rows.append((challenge_id_hash, challenge_hash, owner, 1, expires_at, None))
    connection.executemany(
        "INSERT INTO account_recovery_challenges(" 
        "challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at" 
        ") VALUES(?,?,?,?,?,?)",
        rows,
    )
    return [row[0] for row in rows]


def test_recovery_start_response_parity_across_account_states(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Keep anonymous start schema/sizes stable and omit coverage/Vault metadata."""
    assert account.get("account_id")
    suffix = uuid.uuid4().hex[:12]
    disabled = _register_account(
        api, f"recovery-disabled-{suffix}@example.test", tmp_path, "start-parity-disabled"
    )
    stale = _register_account(
        api, f"recovery-stale-{suffix}@example.test", tmp_path, "start-parity-stale"
    )
    current = _register_account(
        api, f"recovery-current-{suffix}@example.test", tmp_path, "start-parity-current"
    )
    inactive = _register_account(
        api, f"recovery-inactive-{suffix}@example.test", tmp_path, "start-parity-inactive"
    )

    disabled_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=disabled["access_token"]
    )
    stale_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=stale["access_token"]
    )
    current_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=current["access_token"]
    )
    assert disabled_contexts.status == stale_contexts.status == current_contexts.status == 200
    assert disabled_contexts.json()["recovery_status"] == "disabled"

    stale_signer = SigningKey(tmp_path, "start-parity-stale-recovery")
    stale_setup = _configure_recovery(
        api, stale, instance, stale_signer, b64url(os.urandom(32))
    )
    assert stale_setup["key_envelopes"] == []
    stale_after_setup = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=stale["access_token"]
    )
    assert stale_after_setup.status == 200
    assert stale_after_setup.json()["recovery_status"] == "stale"
    assert stale_after_setup.json()["required_contexts"]

    current_signer = SigningKey(tmp_path, "start-parity-current-recovery")
    current_encryption_public_key = b64url(os.urandom(32))
    current_required = current_contexts.json()["required_contexts"]
    assert current_required
    current_boxes = [
        _recovery_box(
            account_id=current["account_id"],
            instance=instance,
            generation=1,
            signing_public_key=b64url(current_signer.public_key),
            encryption_public_key=current_encryption_public_key,
            vault_id=context["vault_id"],
            key_epoch=context["key_epoch"],
            uploader_device_id=current["device_id"],
            signer=current_signer,
        )
        for context in current_required
    ]
    _configure_recovery(
        api,
        current,
        instance,
        current_signer,
        current_encryption_public_key,
        key_envelopes=current_boxes,
    )
    current_after_setup = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=current["access_token"]
    )
    assert current_after_setup.status == 200
    assert current_after_setup.json()["recovery_status"] == "current"

    inactive_signer = SigningKey(tmp_path, "start-parity-inactive-recovery")
    _configure_recovery(
        api, inactive, instance, inactive_signer, b64url(os.urandom(32))
    )
    with sqlite3.connect(_db_path(api)) as connection:
        connection.execute(
            "UPDATE users SET status='disabled' WHERE user_id=?",
            (inactive["account_id"],),
        )

    cases = [
        ("unknown", f"recovery-absent-{suffix}@example.test"),
        ("disabled", disabled["username"]),
        ("inactive", inactive["username"]),
        ("configured_stale", stale["username"]),
        ("configured_current", current["username"]),
    ]
    responses = {
        name: api.request(
            "POST", "/api/v1/auth/recovery/start", json_body={"username": username}
        )
        for name, username in cases
    }

    statuses = {response.status for response in responses.values()}
    assert statuses == {200}, f"recovery start status mismatch across states: {statuses}"

    # Every anonymous start writes one short-lived, hash-only challenge row.
    # Account starts bind it to the owner; decoys deliberately have no owner.
    expected_owners = {
        "unknown": None,
        "disabled": None,
        "inactive": None,
        "configured_stale": stale["account_id"],
        "configured_current": current["account_id"],
    }
    with sqlite3.connect(_db_path(api)) as connection:
        for name, response in responses.items():
            body = response.json()
            challenge_id_hash = hashlib.sha256(body["challenge_id"].encode()).hexdigest()
            challenge_hash = hashlib.sha256(unb64url(body["challenge"])).hexdigest()
            assert len(challenge_id_hash) == len(challenge_hash) == 64
            assert challenge_id_hash == challenge_id_hash.lower()
            assert challenge_hash == challenge_hash.lower()
            rows = connection.execute(
                "SELECT challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at "
                "FROM account_recovery_challenges WHERE challenge_id_hash=?",
                (challenge_id_hash,),
            ).fetchall()
            assert len(rows) == 1, f"{name} start must persist exactly one challenge row"
            stored_id_hash, stored_challenge_hash, owner_id, generation, expires_at, consumed_at = rows[0]
            assert stored_id_hash == challenge_id_hash
            assert stored_challenge_hash == challenge_hash
            assert owner_id == expected_owners[name]
            assert generation == body["recovery_generation"]
            assert expires_at > 0 and consumed_at is None
            persisted_values = " ".join(str(value) for value in rows[0])
            assert body["challenge_id"] not in persisted_values
            assert body["challenge"] not in persisted_values

    # A decoy challenge cannot be replayed against a real account, even when
    # the caller supplies a valid signature for that account's descriptor.
    configured_body = responses["configured_current"].json()
    decoy_body = responses["unknown"].json()
    decoy_inspect_unsigned = {
        "protocol": "atermius-account-recovery-inspect-v1",
        "account_id": configured_body["account_id"],
        "instance_id": configured_body["instance_id"],
        "server_space_id": configured_body["server_space_id"],
        "recovery_generation": configured_body["recovery_generation"],
        "challenge_id": decoy_body["challenge_id"],
        "challenge": decoy_body["challenge"],
        "recovery_descriptor_hash": configured_body["recovery_descriptor_hash"],
    }
    decoy_inspect_request = {
        key: value
        for key, value in decoy_inspect_unsigned.items()
        if key not in {"protocol", "recovery_descriptor_hash"}
    }
    decoy_inspect_request["recovery_signature"] = b64url(
        current_signer.sign(jcs(decoy_inspect_unsigned))
    )
    rejected_decoy_inspect = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=decoy_inspect_request
    )
    assert rejected_decoy_inspect.status == 401
    assert _error_code(rejected_decoy_inspect) == "RECOVERY_FAILED"

    expected_keys = {
        "account_id",
        "instance_id",
        "server_space_id",
        "recovery_generation",
        "challenge_id",
        "challenge",
        "expires_at",
        "recovery_public_signing_key",
        "recovery_public_encryption_key",
        "recovery_descriptor_hash",
        "recovery_envelope",
    }
    expected_types = {
        "account_id": str,
        "instance_id": str,
        "server_space_id": str,
        "recovery_generation": int,
        "challenge_id": str,
        "challenge": str,
        "expires_at": str,
        "recovery_public_signing_key": str,
        "recovery_public_encryption_key": str,
        "recovery_descriptor_hash": str,
        "recovery_envelope": dict,
    }
    forbidden_metadata_keys = {
        "recovery_status",
        "present_contexts",
        "required_contexts",
        "vault",
        "vaults",
        "vault_id",
        "key_epoch",
        "uploader_device_id",
        "credential",
        "host",
        "hosts",
        "record",
        "records",
    }
    for name, response in responses.items():
        body = response.json()
        assert isinstance(body, dict), f"{name} recovery start response was not an object"
        assert set(body) == expected_keys, f"{name} recovery start response key set changed"
        assert {key: type(value) for key, value in body.items()} == expected_types
        assert type(body["recovery_generation"]) is int and body["recovery_generation"] > 0
        assert len(unb64url(body["challenge"])) == 32
        assert len(unb64url(body["recovery_public_signing_key"])) == 32
        assert len(unb64url(body["recovery_public_encryption_key"])) == 32
        assert len(body["recovery_descriptor_hash"]) == 64
        int(body["recovery_descriptor_hash"], 16)

        envelope = body["recovery_envelope"]
        assert set(envelope) == {"version", "suite", "nonce", "ciphertext"}
        assert type(envelope["version"]) is int and envelope["version"] == 1
        assert envelope["suite"] == "xchacha20-poly1305-ietf"
        assert len(unb64url(envelope["nonce"])) == 24
        assert len(unb64url(envelope["ciphertext"])) == 528
        assert not (set(body) | set(envelope)) & forbidden_metadata_keys

    serialized_lengths = {len(response.body) for response in responses.values()}
    assert len(serialized_lengths) == 1, (
        "recovery start response byte length differed across account states"
    )

    for field in expected_keys:
        observed_types = {type(response.json()[field]) for response in responses.values()}
        assert len(observed_types) == 1, f"{field} type differed across account states"


def test_recovery_setup_sync_inspect_and_full_loss_completion(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    assert account.get("account_id")
    account = _register_account(
        api, f"account-recovery-{uuid.uuid4().hex[:12]}@example.test", tmp_path, "recovery"
    )

    before = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=account["access_token"]
    )
    assert before.status == 200
    assert before.json()["recovery_generation"] == 0
    assert before.json()["recovery_status"] == "disabled"
    assert before.json()["present_contexts"] == []
    disabled_start = api.request(
        "POST", "/api/v1/auth/recovery/start", json_body={"username": account["username"]}
    )
    unknown_start = api.request(
        "POST", "/api/v1/auth/recovery/start",
        json_body={"username": f"absent-{uuid.uuid4().hex}@example.test"},
    )
    assert disabled_start.status == unknown_start.status == 200
    assert set(disabled_start.json()) == set(unknown_start.json())
    assert len(unb64url(disabled_start.json()["recovery_envelope"]["ciphertext"])) == 528
    assert len(unb64url(unknown_start.json()["recovery_envelope"]["ciphertext"])) == 528

    second_device = _enroll_second_device(
        api, account, before.json()["required_contexts"][0], tmp_path
    )

    recovery_signer = SigningKey(tmp_path, "recovery-identity-v1")
    recovery_encryption_public_key = b64url(os.urandom(32))
    setup = _configure_recovery(
        api, account, instance, recovery_signer, recovery_encryption_public_key
    )
    setup_retry = api.request(
        "PUT", "/api/v1/auth/recovery", token=account["access_token"], json_body=setup
    )
    assert setup_retry.status == 200 and setup_retry.json()["already_applied"] is True
    partial = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=account["access_token"]
    )
    assert partial.status == 200
    assert partial.json()["recovery_status"] == "stale"
    assert len(partial.json()["required_contexts"]) == 1

    # A device uploads only the key contexts it currently holds. The immutable
    # context row makes exact retries safe while status remains stale until all
    # required contexts have arrived.
    required = partial.json()["required_contexts"]
    box = _recovery_box(
        account_id=account["account_id"], instance=instance, generation=1,
        signing_public_key=setup["recovery_public_signing_key"],
        encryption_public_key=recovery_encryption_public_key,
        vault_id=required[0]["vault_id"], key_epoch=required[0]["key_epoch"],
        uploader_device_id=second_device["device_id"], signer=recovery_signer,
    )
    upload = {
        "operation_id": str(uuid.uuid4()),
        "recovery_generation": 1,
        "recovery_descriptor_hash": partial.json()["recovery_descriptor_hash"],
        "key_envelopes": [box],
    }
    uploaded = api.request(
        "PUT", "/api/v1/auth/recovery/key-envelopes",
        token=second_device["access_token"], json_body=upload,
    )
    assert uploaded.status == 200, f"keybox upload failed: {_error_code(uploaded)}"
    assert uploaded.json()["recovery_status"] == "current"
    synchronized = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=account["access_token"]
    )
    assert synchronized.status == 200
    assert synchronized.json()["present_contexts"][0]["uploader_device_id"] == second_device["device_id"]
    exact_upload_retry = api.request(
        "PUT", "/api/v1/auth/recovery/key-envelopes",
        token=second_device["access_token"], json_body=upload,
    )
    assert exact_upload_retry.status == 200
    assert exact_upload_retry.json()["already_applied"] is True

    rotated_signer = SigningKey(tmp_path, "recovery-identity-v2")
    rotated_encryption_public_key = b64url(os.urandom(32))
    old_descriptor = {
        "protocol": "atermius-account-recovery-descriptor-v1",
        "account_id": account["account_id"],
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": 1,
        "recovery_public_signing_key": b64url(recovery_signer.public_key),
        "recovery_public_encryption_key": recovery_encryption_public_key,
    }
    new_descriptor = {
        **old_descriptor,
        "recovery_generation": 2,
        "recovery_public_signing_key": b64url(rotated_signer.public_key),
        "recovery_public_encryption_key": rotated_encryption_public_key,
    }
    rotation_payload = {
        "protocol": "atermius-account-recovery-rotate-v1",
        "account_id": account["account_id"],
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "old_recovery_generation": 1,
        "new_recovery_generation": 2,
        "old_recovery_descriptor_hash": hashlib.sha256(jcs(old_descriptor)).hexdigest(),
        "new_recovery_descriptor_hash": hashlib.sha256(jcs(new_descriptor)).hexdigest(),
    }
    rotated_box = _recovery_box(
        account_id=account["account_id"], instance=instance, generation=2,
        signing_public_key=new_descriptor["recovery_public_signing_key"],
        encryption_public_key=rotated_encryption_public_key,
        vault_id=required[0]["vault_id"], key_epoch=required[0]["key_epoch"],
        uploader_device_id=account["device_id"], signer=rotated_signer,
    )
    rotation_request = _configure_recovery(
        api, account, instance, rotated_signer, rotated_encryption_public_key,
        generation=2, key_envelopes=[rotated_box],
        previous_recovery_signature=b64url(recovery_signer.sign(jcs(rotation_payload))),
    )
    assert rotation_request["recovery_generation"] == 2
    after_rotation = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=account["access_token"]
    )
    assert after_rotation.status == 200
    assert after_rotation.json()["recovery_generation"] == 2
    assert after_rotation.json()["recovery_status"] == "current"
    recovery_signer = rotated_signer
    recovery_encryption_public_key = rotated_encryption_public_key
    active_generation = 2

    start = api.request(
        "POST", "/api/v1/auth/recovery/start", json_body={"username": account["username"]}
    )
    decoy = api.request(
        "POST", "/api/v1/auth/recovery/start",
        json_body={"username": f"absent-{uuid.uuid4().hex}@example.test"},
    )
    assert start.status == decoy.status == 200
    started, decoy_body = start.json(), decoy.json()
    assert set(started) == set(decoy_body)
    assert started["recovery_generation"] == active_generation
    assert len(unb64url(started["recovery_envelope"]["ciphertext"])) == 528
    assert len(unb64url(decoy_body["recovery_envelope"]["ciphertext"])) == 528

    inspect_unsigned = {
        "protocol": "atermius-account-recovery-inspect-v1",
        "account_id": started["account_id"],
        "instance_id": started["instance_id"],
        "server_space_id": started["server_space_id"],
        "recovery_generation": started["recovery_generation"],
        "challenge_id": started["challenge_id"],
        "challenge": started["challenge"],
        "recovery_descriptor_hash": started["recovery_descriptor_hash"],
    }
    inspect_request = {
        **{
            key: value
            for key, value in inspect_unsigned.items()
            if key not in {"protocol", "recovery_descriptor_hash"}
        },
        "recovery_signature": b64url(recovery_signer.sign(jcs(inspect_unsigned))),
    }
    inspected = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=inspect_request
    )
    assert inspected.status == 200, (
        f"recovery inspect failed: HTTP {inspected.status} {_error_code(inspected)}; "
        f"sent fields={sorted(inspect_request)} body={inspected.body.decode(errors='replace')}"
    )
    assert inspected.json()["recovery_status"] == "current"
    assert len(inspected.json()["present_contexts"]) == 1

    wrong_inspect = {**inspect_request, "recovery_signature": b64url(os.urandom(64))}
    rejected_inspect = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=wrong_inspect
    )
    assert rejected_inspect.status == 401
    assert _error_code(rejected_inspect) == "RECOVERY_FAILED"

    # Simulate total local credential loss: recovery supplies a new device,
    # new login credentials and freshly sealed Vault and Recovery keyboxes.
    new_device_signer = SigningKey(tmp_path, "recovery-device-v2")
    new_device_id = str(uuid.uuid4())
    new_device = {
        "device_id": new_device_id,
        "name": "Recovered test device",
        "signing_public_key": b64url(new_device_signer.public_key),
        "encryption_public_key": b64url(os.urandom(32)),
    }
    new_device["signature"] = b64url(new_device_signer.sign(jcs({
        "account_id": account["account_id"],
        "device_id": new_device_id,
        "signing_public_key": new_device["signing_public_key"],
        "encryption_public_key": new_device["encryption_public_key"],
    })))
    required = inspected.json()["required_contexts"]
    vault_key_envelopes = []
    next_boxes = []
    next_recovery_signer = SigningKey(tmp_path, "recovery-identity-v3")
    next_recovery_encryption_public_key = b64url(os.urandom(32))
    next_recovery_public_key = b64url(next_recovery_signer.public_key)
    for context in required:
        vault_envelope = {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        }
        vault_payload = {
            "vault_id": context["vault_id"],
            "recipient_device_id": new_device_id,
            "key_epoch": context["key_epoch"],
            "membership_version": context["membership_version"],
            "envelope": vault_envelope,
        }
        vault_key_envelopes.append({**vault_payload, "signature": b64url(
            new_device_signer.sign(jcs(vault_payload))
        )})
        next_boxes.append(_recovery_box(
            account_id=account["account_id"], instance=instance,
            generation=active_generation + 1,
            signing_public_key=next_recovery_public_key,
            encryption_public_key=next_recovery_encryption_public_key,
            vault_id=context["vault_id"], key_epoch=context["key_epoch"],
            uploader_device_id=new_device_id, signer=next_recovery_signer,
        ))

    next_code_envelope = _opaque_envelope(528)
    next_identity_envelope = _opaque_envelope(96)
    next_recovery = {
        "recovery_public_signing_key": next_recovery_public_key,
        "recovery_public_encryption_key": next_recovery_encryption_public_key,
        "recovery_envelope": next_code_envelope,
        "recovery_identity_envelope": next_identity_envelope,
        "key_envelopes": next_boxes,
        "recovery_identity_proof_signature": _identity_proof(
            account_id=account["account_id"], instance=instance,
            generation=active_generation + 1,
            signing_public_key=next_recovery_public_key,
            encryption_public_key=next_recovery_encryption_public_key,
            recovery_envelope=next_code_envelope,
            identity_envelope=next_identity_envelope,
            signer=next_recovery_signer,
        ),
    }
    new_verifier = b64url(os.urandom(32))
    complete = {
        "operation_id": str(uuid.uuid4()),
        "account_id": account["account_id"],
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": active_generation,
        "challenge_id": started["challenge_id"],
        "challenge": started["challenge"],
        "new_kdf": {
            "id": "argon2id13", "salt": b64url(os.urandom(16)),
            "mem_kib": 65536, "iterations": 3, "parallelism": 1, "version": 1,
        },
        "new_login_verifier": new_verifier,
        "account_key_envelope": _account_key_envelope(),
        "device": new_device,
        "vault_key_envelopes": vault_key_envelopes,
        "next_recovery": next_recovery,
    }
    complete["recovery_signature"] = b64url(recovery_signer.sign(jcs({
        "protocol": "atermius-account-recovery-complete-v1",
        "request": complete,
    })))
    database = _db_path(api)
    challenge_id_hash = hashlib.sha256(started["challenge_id"].encode()).hexdigest()
    fingerprint_key = os.urandom(32)
    source_columns = (
        "vault_id,epoch,recipient_user_id,recipient_device_id,envelope,"
        "envelope_signature,signer_device_id,membership_version"
    )
    with sqlite3.connect(database) as connection:
        active_context = None
        for context in required:
            active_epoch = connection.execute(
                "SELECT active_epoch FROM vaults WHERE vault_id=?",
                (context["vault_id"],),
            ).fetchone()
            if active_epoch is not None and active_epoch[0] == context["key_epoch"]:
                active_context = context
                break
        assert active_context is not None
        source_rows = connection.execute(
            f"SELECT {source_columns} FROM vault_key_envelopes "
            "WHERE recipient_user_id=? AND vault_id=? AND epoch=?",
            (account["account_id"], active_context["vault_id"], active_context["key_epoch"]),
        ).fetchall()
        assert source_rows
        active_session = connection.execute(
            "SELECT session_id,access_expires_at FROM sessions "
            "WHERE user_id=? AND revoked_at IS NULL ORDER BY created_at LIMIT 1",
            (account["account_id"],),
        ).fetchone()
        assert active_session is not None
        relay_ticket_hash = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
        notification_ticket_hash = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
        connection.execute(
            "INSERT INTO relay_tickets "
            "(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,"
            "session_id,session_access_expires_at,created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (
                relay_ticket_hash, account["account_id"], account["device_id"],
                "127.0.0.1", 22, "2099-01-01T00:00:00Z", active_session[0],
                active_session[1], 1_800_000_000,
            ),
        )
        connection.execute(
            "INSERT INTO notification_tickets "
            "(ticket_hash,user_id,device_id,session_id,server_generation,"
            "session_access_expires_at,created_at,expires_at,consumed_at) "
            "VALUES(?,?,?,?,?,?,?,?,NULL)",
            (
                notification_ticket_hash, account["account_id"],
                account["device_id"], active_session[0], "fault-injection",
                active_session[1], 1_800_000_000, 1_800_000_030,
            ),
        )
        side_effects_before = _completion_side_effect_snapshot(
            connection,
            account_id=account["account_id"],
            new_device_id=new_device_id,
            operation_id=complete["operation_id"],
            challenge_id_hash=challenge_id_hash,
            fingerprint_key=fingerprint_key,
        )
        removed = connection.execute(
            "DELETE FROM vault_key_envelopes WHERE recipient_user_id=? AND vault_id=? AND epoch=?",
            (account["account_id"], active_context["vault_id"], active_context["key_epoch"]),
        ).rowcount

    try:
        assert removed == len(source_rows)
        missing_source = api.request(
            "POST", "/api/v1/auth/recovery/complete", json_body=complete
        )
        assert missing_source.status == 409
        assert _error_code(missing_source) == "RECOVERY_STALE"
        with sqlite3.connect(database) as connection:
            remaining_source = connection.execute(
                "SELECT COUNT(*) FROM vault_key_envelopes "
                "WHERE recipient_user_id=? AND vault_id=? AND epoch=?",
                (account["account_id"], active_context["vault_id"], active_context["key_epoch"]),
            ).fetchone()[0]
            assert remaining_source == 0
            side_effects_after = _completion_side_effect_snapshot(
                connection,
                account_id=account["account_id"],
                new_device_id=new_device_id,
                operation_id=complete["operation_id"],
                challenge_id_hash=challenge_id_hash,
                fingerprint_key=fingerprint_key,
            )
            assert side_effects_after == side_effects_before
    finally:
        with sqlite3.connect(database) as connection:
            connection.executemany(
                "INSERT OR REPLACE INTO vault_key_envelopes "
                f"({source_columns}) VALUES(?,?,?,?,?,?,?,?)",
                source_rows,
            )

    with sqlite3.connect(database) as connection:
        restored_count = connection.execute(
            "SELECT COUNT(*) FROM vault_key_envelopes "
            "WHERE recipient_user_id=? AND vault_id=? AND epoch=?",
            (account["account_id"], active_context["vault_id"], active_context["key_epoch"]),
        ).fetchone()[0]
    assert restored_count == len(source_rows)

    # Full-loss Recovery must remain available even when the account has
    # reached the plan's maximum of 20 active trusted devices. Each approval
    # follows the ordinary signed device-enrollment API.
    for index in range(18):
        _enroll_second_device(
            api,
            account,
            required[0],
            tmp_path,
            label=f"recovery-limit-{index}",
            login_after_registration=False,
        )
    at_device_limit = api.request(
        "GET", "/api/v1/devices", token=account["access_token"]
    )
    assert at_device_limit.status == 200
    assert sum(item["status"] == "active" for item in at_device_limit.json()["devices"]) == 20

    # Seed an enrolled MFA factor plus an outstanding login challenge. A full
    # signed account Recovery must invalidate all three categories atomically.
    mfa_envelope = json.dumps({"version": 1, "nonce": "opaque", "ciphertext": "encrypted-seed"})
    mfa_salt = b64url(os.urandom(16))
    mfa_code_hash = hashlib.sha256(os.urandom(32)).hexdigest()
    mfa_challenge_hash = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
    with sqlite3.connect(database) as connection:
        credential_version = connection.execute(
            "SELECT credential_version FROM auth_credentials WHERE user_id=?",
            (account["account_id"],),
        ).fetchone()[0]
        connection.execute(
            "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step) "
            "VALUES(?,?,?,?)",
            (account["account_id"], mfa_envelope, int(time.time()), 1),
        )
        connection.execute(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at) "
            "VALUES(?,?,?,?,?)",
            (str(uuid.uuid4()), account["account_id"], mfa_salt, mfa_code_hash, int(time.time())),
        )
        connection.execute(
            "INSERT INTO auth_mfa_login_challenges "
            "(challenge_id_hash,user_id,device_id,credential_version,expires_at) VALUES(?,?,?,?,?)",
            (mfa_challenge_hash, account["account_id"], account["device_id"], credential_version, int(time.time()) + 300),
        )

    # Expire the Recovery challenge from a trigger after complete() has
    # validated it inside its writer transaction, while the replacement
    # generation's keyboxes are being inserted. This deterministically covers
    # the boundary where a long completion crosses the challenge deadline.
    with sqlite3.connect(database) as connection:
        before_late_expiry = _completion_side_effect_snapshot(
            connection,
            account_id=account["account_id"],
            new_device_id=new_device_id,
            operation_id=complete["operation_id"],
            challenge_id_hash=challenge_id_hash,
            fingerprint_key=fingerprint_key,
        )
        connection.executescript(
            "CREATE TRIGGER expire_recovery_challenge_during_completion "
            "AFTER INSERT ON account_recovery_key_envelopes "
            f"WHEN NEW.user_id='{account['account_id']}' "
            f"AND NEW.recovery_generation={active_generation + 1} "
            "BEGIN "
            "UPDATE account_recovery_challenges SET expires_at=0 "
            f"WHERE challenge_id_hash='{challenge_id_hash}'; "
            "END;"
        )

    late_expiry = api.request(
        "POST", "/api/v1/auth/recovery/complete", json_body=complete
    )
    assert late_expiry.status == 401
    assert _error_code(late_expiry) == "RECOVERY_FAILED"
    with sqlite3.connect(database) as connection:
        connection.execute("DROP TRIGGER expire_recovery_challenge_during_completion")
        after_late_expiry = _completion_side_effect_snapshot(
            connection,
            account_id=account["account_id"],
            new_device_id=new_device_id,
            operation_id=complete["operation_id"],
            challenge_id_hash=challenge_id_hash,
            fingerprint_key=fingerprint_key,
        )
        assert after_late_expiry == before_late_expiry

    completed = api.request(
        "POST", "/api/v1/auth/recovery/complete", json_body=complete
    )
    assert completed.status == 200, f"recovery completion failed: HTTP {completed.status} {_error_code(completed)}"
    result = completed.json()
    assert result["status"] == "recovered"
    assert result["recovery_generation"] == active_generation + 1
    assert "access_token" not in result and "refresh_token" not in result
    retried = api.request(
        "POST", "/api/v1/auth/recovery/complete", json_body=complete
    )
    assert retried.status == 200 and retried.json()["already_applied"] is True
    with sqlite3.connect(database) as connection:
        device_rows = connection.execute(
            "SELECT device_id,status FROM devices WHERE user_id=? ORDER BY device_id",
            (account["account_id"],),
        ).fetchall()
        mfa_rows = connection.execute(
            "SELECT "
            "(SELECT COUNT(*) FROM auth_mfa WHERE user_id=?),"
            "(SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=?),"
            "(SELECT COUNT(*) FROM auth_mfa_login_challenges WHERE user_id=?),"
            "(SELECT COUNT(*) FROM audit_events WHERE action='auth.mfa_reset_by_recovery' AND resource_id=?)",
            (account["account_id"], account["account_id"], account["account_id"], account["account_id"]),
        ).fetchone()
    assert mfa_rows == (0, 0, 0, 1)
    active_after_recovery = [row[0] for row in device_rows if row[1] == "active"]
    assert active_after_recovery == [new_device_id]
    assert len(device_rows) == 21, "Recovery should retain revoked history while replacing active devices"

    old_session = api.request("GET", "/api/v1/me", token=account["access_token"])
    assert old_session.status == 401
    old_second_device_session = api.request(
        "GET", "/api/v1/me", token=second_device["access_token"]
    )
    assert old_second_device_session.status == 401
    new_login = api.request("POST", "/api/v1/auth/login", json_body={
        "username": account["username"],
        "login_verifier": new_verifier,
        "device_id": new_device_id,
    })
    assert new_login.status == 200, f"recovered login failed: {_error_code(new_login)}"
    new_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts",
        token=new_login.json()["access_token"],
    )
    assert new_contexts.status == 200
    assert new_contexts.json()["recovery_generation"] == active_generation + 1
    assert new_contexts.json()["recovery_status"] == "current"

    audit = api.request("GET", "/api/v1/audit?limit=200", token=new_login.json()["access_token"])
    assert audit.status == 200
    recovered = [event for event in audit.json()["events"] if event["action"] == "auth.account_recovered"]
    assert len(recovered) == 1
    audit_json = json.dumps(audit.json(), sort_keys=True)
    for secret in (setup["current_login_verifier"], started["challenge"], new_verifier):
        assert secret not in audit_json

    # Consumed challenges remain as hashes while Recovery is enabled, but
    # disabling Recovery deliberately removes them to invalidate all pending
    # challenge material. Check the at-rest privacy contract before that
    # cleanup runs.
    with sqlite3.connect(_db_path(api)) as connection:
        challenge_rows = connection.execute(
            "SELECT challenge_id_hash,challenge_hash FROM account_recovery_challenges WHERE user_id=?",
            (account["account_id"],),
        ).fetchall()
        receipts = connection.execute(
            "SELECT request_digest,response_json FROM account_recovery_receipts WHERE user_id=?",
            (account["account_id"],),
        ).fetchall()
    assert challenge_rows
    assert all(len(row[0]) == len(row[1]) == 64 for row in challenge_rows)
    assert receipts
    receipt_text = json.dumps(receipts, sort_keys=True)
    for secret in (
        started["challenge"], started["challenge_id"],
        setup["current_login_verifier"], new_verifier,
    ):
        assert secret not in receipt_text

    disable = {
        "operation_id": str(uuid.uuid4()),
        "current_login_verifier": new_verifier,
    }
    disabled = api.request(
        "DELETE", "/api/v1/auth/recovery",
        token=new_login.json()["access_token"], json_body=disable,
    )
    assert disabled.status == 200
    assert disabled.json()["status"] == "disabled"
    disable_retry = api.request(
        "DELETE", "/api/v1/auth/recovery",
        token=new_login.json()["access_token"], json_body=disable,
    )
    assert disable_retry.status == 200 and disable_retry.json()["already_applied"] is True
    after_disable = api.request(
        "GET", "/api/v1/auth/recovery/contexts",
        token=new_login.json()["access_token"],
    )
    assert after_disable.status == 200
    assert after_disable.json()["recovery_status"] == "disabled"
    assert after_disable.json()["recovery_generation"] == active_generation + 1
    assert after_disable.json()["present_contexts"] == []
    with sqlite3.connect(_db_path(api)) as connection:
        disabled_challenges = connection.execute(
            "SELECT COUNT(*) FROM account_recovery_challenges WHERE user_id=?",
            (account["account_id"],),
        ).fetchone()[0]
    assert disabled_challenges == 0

    reenabled_signer = SigningKey(tmp_path, "recovery-identity-v4")
    recovered_account = {
        **account,
        "device_id": new_device_id,
        "signing_key": new_device_signer,
        "access_token": new_login.json()["access_token"],
        "login_verifier": new_verifier,
    }
    reenabled = _configure_recovery(
        api, recovered_account, instance, reenabled_signer, b64url(os.urandom(32)),
        generation=after_disable.json()["recovery_generation"] + 1,
    )
    assert reenabled["recovery_generation"] == active_generation + 2
    reenabled_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts",
        token=new_login.json()["access_token"],
    )
    assert reenabled_contexts.status == 200
    assert reenabled_contexts.json()["recovery_generation"] == active_generation + 2
    assert reenabled_contexts.json()["recovery_status"] == "stale"
    final_contexts = reenabled_contexts

def test_full_loss_completion_restores_exact_multi_vault_context_set(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    assert account.get("account_id")
    account = _register_account(
        api, f"recovery-multivault-{uuid.uuid4().hex[:12]}@example.test", tmp_path,
        "recovery-multivault-owner",
    )
    second_vault = initial_vault(
        account_id=account["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=account["device_id"],
        encryption_public_key=account["encryption_public_key"],
        signer=account["signing_key"],
    )
    created = api.request(
        "POST", "/api/v1/vaults", token=account["access_token"], json_body={
            "vault_id": second_vault["vault_id"],
            "name_envelope": second_vault["name_envelope"],
            "key_envelope": second_vault["key_envelope"],
            "membership": second_vault["membership"],
        },
    )
    assert created.status in (200, 201), f"second Vault creation failed: {_error_code(created)}"

    expected_contexts = sorted(
        [
            {
                "vault_id": account["vault_id"],
                "key_epoch": 1,
                "membership_version": 1,
            },
            {
                "vault_id": second_vault["vault_id"],
                "key_epoch": 1,
                "membership_version": 1,
            },
        ],
        key=lambda context: (context["vault_id"], context["key_epoch"]),
    )
    assert len({context["vault_id"] for context in expected_contexts}) == 2

    recovery_signer = SigningKey(tmp_path, "recovery-multivault-v1")
    recovery_encryption_public_key = b64url(os.urandom(32))
    initial_boxes = [
        _recovery_box(
            account_id=account["account_id"],
            instance=instance,
            generation=1,
            signing_public_key=b64url(recovery_signer.public_key),
            encryption_public_key=recovery_encryption_public_key,
            vault_id=context["vault_id"],
            key_epoch=context["key_epoch"],
            uploader_device_id=account["device_id"],
            signer=recovery_signer,
        )
        for context in expected_contexts
    ]
    _configure_recovery(
        api,
        account,
        instance,
        recovery_signer,
        recovery_encryption_public_key,
        key_envelopes=initial_boxes,
    )

    started = api.request(
        "POST", "/api/v1/auth/recovery/start",
        json_body={"username": account["username"]},
    )
    assert started.status == 200
    start_body = started.json()
    inspect_unsigned = {
        "protocol": "atermius-account-recovery-inspect-v1",
        "account_id": start_body["account_id"],
        "instance_id": start_body["instance_id"],
        "server_space_id": start_body["server_space_id"],
        "recovery_generation": start_body["recovery_generation"],
        "challenge_id": start_body["challenge_id"],
        "challenge": start_body["challenge"],
        "recovery_descriptor_hash": start_body["recovery_descriptor_hash"],
    }
    inspect_request = {
        key: value
        for key, value in inspect_unsigned.items()
        if key not in {"protocol", "recovery_descriptor_hash"}
    }
    inspect_request["recovery_signature"] = b64url(
        recovery_signer.sign(jcs(inspect_unsigned))
    )
    inspected = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=inspect_request
    )
    assert inspected.status == 200, f"Recovery inspect failed: {_error_code(inspected)}"
    inspected_body = inspected.json()
    assert inspected_body["required_contexts"] == expected_contexts
    assert inspected_body["recovery_status"] == "current"
    assert [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in inspected_body["present_contexts"]
    ] == [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in expected_contexts
    ]

    new_device_signer = SigningKey(tmp_path, "recovery-multivault-device")
    new_device_id = str(uuid.uuid4())
    new_device = {
        "device_id": new_device_id,
        "name": "Recovered multi-Vault test device",
        "signing_public_key": b64url(new_device_signer.public_key),
        "encryption_public_key": b64url(os.urandom(32)),
    }
    new_device["signature"] = b64url(new_device_signer.sign(jcs({
        "account_id": account["account_id"],
        "device_id": new_device_id,
        "signing_public_key": new_device["signing_public_key"],
        "encryption_public_key": new_device["encryption_public_key"],
    })))

    target_vault_envelopes = []
    next_recovery_signer = SigningKey(tmp_path, "recovery-multivault-v2")
    next_recovery_encryption_public_key = b64url(os.urandom(32))
    next_recovery_boxes = []
    for context in expected_contexts:
        envelope = {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        }
        target_payload = {
            "vault_id": context["vault_id"],
            "recipient_device_id": new_device_id,
            "key_epoch": context["key_epoch"],
            "membership_version": context["membership_version"],
            "envelope": envelope,
        }
        target_vault_envelopes.append({
            **target_payload,
            "signature": b64url(new_device_signer.sign(jcs(target_payload))),
        })
        next_recovery_boxes.append(_recovery_box(
            account_id=account["account_id"],
            instance=instance,
            generation=2,
            signing_public_key=b64url(next_recovery_signer.public_key),
            encryption_public_key=next_recovery_encryption_public_key,
            vault_id=context["vault_id"],
            key_epoch=context["key_epoch"],
            uploader_device_id=new_device_id,
            signer=next_recovery_signer,
        ))

    next_code_envelope = _opaque_envelope(528)
    next_identity_envelope = _opaque_envelope(96)
    next_recovery = {
        "recovery_public_signing_key": b64url(next_recovery_signer.public_key),
        "recovery_public_encryption_key": next_recovery_encryption_public_key,
        "recovery_envelope": next_code_envelope,
        "recovery_identity_envelope": next_identity_envelope,
        "key_envelopes": next_recovery_boxes,
        "recovery_identity_proof_signature": _identity_proof(
            account_id=account["account_id"],
            instance=instance,
            generation=2,
            signing_public_key=b64url(next_recovery_signer.public_key),
            encryption_public_key=next_recovery_encryption_public_key,
            recovery_envelope=next_code_envelope,
            identity_envelope=next_identity_envelope,
            signer=next_recovery_signer,
        ),
    }
    new_verifier = b64url(os.urandom(32))
    completion_template = {
        "operation_id": "",
        "account_id": account["account_id"],
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": start_body["recovery_generation"],
        "challenge_id": start_body["challenge_id"],
        "challenge": start_body["challenge"],
        "new_kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "new_login_verifier": new_verifier,
        "account_key_envelope": _account_key_envelope(),
        "device": new_device,
        "vault_key_envelopes": target_vault_envelopes,
        "next_recovery": next_recovery,
    }

    def signed_completion(*, omit_context: bool = False, wrong_membership_version: bool = False) -> dict:
        request = json.loads(json.dumps(completion_template))
        request["operation_id"] = str(uuid.uuid4())
        if omit_context:
            request["vault_key_envelopes"].pop()
        if wrong_membership_version:
            target = request["vault_key_envelopes"][0]
            target["membership_version"] += 1
            payload = {
                key: target[key]
                for key in (
                    "vault_id", "recipient_device_id", "key_epoch",
                    "membership_version", "envelope",
                )
            }
            target["signature"] = b64url(new_device_signer.sign(jcs(payload)))
        request["recovery_signature"] = b64url(recovery_signer.sign(jcs({
            "protocol": "atermius-account-recovery-complete-v1",
            "request": request,
        })))
        return request

    database = _db_path(api)
    challenge_id_hash = hashlib.sha256(start_body["challenge_id"].encode()).hexdigest()
    fingerprint_key = os.urandom(32)

    def completion_state(operation_id: str) -> dict:
        with sqlite3.connect(database) as connection:
            return _completion_side_effect_snapshot(
                connection,
                account_id=account["account_id"],
                new_device_id=new_device_id,
                operation_id=operation_id,
                challenge_id_hash=challenge_id_hash,
                fingerprint_key=fingerprint_key,
            )

    for request in (
        signed_completion(omit_context=True),
        signed_completion(wrong_membership_version=True),
    ):
        before_failure = completion_state(request["operation_id"])
        assert before_failure["challenge_consumed_at"] is None
        rejected = api.request(
            "POST", "/api/v1/auth/recovery/complete", json_body=request
        )
        assert rejected.status == 409
        assert _error_code(rejected) == "RECOVERY_STALE"
        assert completion_state(request["operation_id"]) == before_failure

    valid_completion = signed_completion()
    completed = api.request(
        "POST", "/api/v1/auth/recovery/complete", json_body=valid_completion
    )
    assert completed.status == 200, f"full Recovery failed: {_error_code(completed)}"
    assert completed.json()["status"] == "recovered"
    assert completed.json()["recovery_generation"] == 2

    with sqlite3.connect(database) as connection:
        target_rows = connection.execute(
            "SELECT vault_id,epoch,membership_version FROM vault_key_envelopes "
            "WHERE recipient_user_id=? AND recipient_device_id=? ORDER BY vault_id,epoch",
            (account["account_id"], new_device_id),
        ).fetchall()
        recovery_rows = connection.execute(
            "SELECT vault_id,key_epoch FROM account_recovery_key_envelopes "
            "WHERE user_id=? AND recovery_generation=2 ORDER BY vault_id,key_epoch",
            (account["account_id"],),
        ).fetchall()
    assert target_rows == [
        (context["vault_id"], context["key_epoch"], context["membership_version"])
        for context in expected_contexts
    ]
    assert recovery_rows == [
        (context["vault_id"], context["key_epoch"])
        for context in expected_contexts
    ]

    new_login = api.request("POST", "/api/v1/auth/login", json_body={
        "username": account["username"],
        "login_verifier": new_verifier,
        "device_id": new_device_id,
    })
    assert new_login.status == 200, f"recovered device login failed: {_error_code(new_login)}"
    restored_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=new_login.json()["access_token"]
    )
    assert restored_contexts.status == 200
    assert restored_contexts.json()["recovery_status"] == "current"
    assert restored_contexts.json()["required_contexts"] == expected_contexts
    assert [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in restored_contexts.json()["present_contexts"]
    ] == [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in expected_contexts
    ]


def test_full_loss_completion_restores_multimember_historical_epoch_contexts(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Full-loss Recovery binds each retained epoch to active signed history."""
    assert account.get("account_id")
    owner = _register_account(
        api,
        f"recovery-history-owner-{uuid.uuid4().hex[:12]}@example.test",
        tmp_path,
        "recovery-history-owner",
    )
    member = _register_membership_account(api, tmp_path, "recovery-history-member")

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
    assert created.status in (200, 201), f"shared Vault creation failed: {_error_code(created)}"
    shared_vault_id = shared["vault_id"]
    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    editor_member = _membership_member(
        member["account_id"], "editor", member["encryption_public_key"]
    )
    genesis_digest = _membership_digest(shared_vault_id, shared["membership"])

    membership_v2 = _signed_membership(
        shared_vault_id,
        2,
        genesis_digest,
        1,
        [owner_member, editor_member],
        owner["device_id"],
        owner["signing_key"],
    )
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": _signed_key_envelope(
                shared_vault_id, member["device_id"], 1, 2, owner["signing_key"]
            ),
            "membership": membership_v2,
        },
    )
    assert invitation.status in (200, 201), f"member invitation failed: {_error_code(invitation)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=member["access_token"],
        json_body={"token": invitation.json()["token"]},
    )
    assert accepted.status in (200, 201), f"member acceptance failed: {_error_code(accepted)}"

    viewer_member = _membership_member(
        member["account_id"], "viewer", member["encryption_public_key"]
    )
    membership_v3 = _signed_rotation_membership(
        shared_vault_id,
        3,
        _membership_digest(shared_vault_id, membership_v2),
        2,
        [owner_member, viewer_member],
        owner["device_id"],
        owner["signing_key"],
        _display_name_envelope(),
    )
    rotated_v3 = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 2,
            "membership": membership_v3,
            "key_envelopes": _rotation_envelopes(
                shared_vault_id,
                3,
                2,
                sorted(set(_active_device_ids(api, owner) + _active_device_ids(api, member))),
                owner,
            ),
        },
    )
    assert rotated_v3.status in (200, 201), f"epoch 2 rotation failed: {_error_code(rotated_v3)}"

    revoked_member = {
        **_membership_member(
            member["account_id"], "editor", member["encryption_public_key"]
        ),
        "state": "revoked",
    }
    membership_v4 = _signed_rotation_membership(
        shared_vault_id,
        4,
        _membership_digest(shared_vault_id, membership_v3),
        3,
        [owner_member, revoked_member],
        owner["device_id"],
        owner["signing_key"],
        _display_name_envelope(),
    )
    rotated_v4 = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/keys/rotate",
        token=owner["access_token"],
        json_body={
            "new_epoch": 3,
            "membership": membership_v4,
            "key_envelopes": _rotation_envelopes(
                shared_vault_id, 4, 3, _active_device_ids(api, owner), owner
            ),
        },
    )
    assert rotated_v4.status in (200, 201), f"epoch 3 rotation failed: {_error_code(rotated_v4)}"

    expected_contexts = sorted(
        [
            {
                "vault_id": owner["vault_id"],
                "key_epoch": 1,
                "membership_version": 1,
            },
            {
                "vault_id": shared_vault_id,
                "key_epoch": 1,
                "membership_version": 2,
            },
            {
                "vault_id": shared_vault_id,
                "key_epoch": 2,
                "membership_version": 3,
            },
            {
                "vault_id": shared_vault_id,
                "key_epoch": 3,
                "membership_version": 4,
            },
        ],
        key=lambda context: (context["vault_id"], context["key_epoch"]),
    )
    recovery_signer = SigningKey(tmp_path, "recovery-history-v1")
    recovery_encryption_public_key = b64url(os.urandom(32))
    _configure_recovery(
        api,
        owner,
        instance,
        recovery_signer,
        recovery_encryption_public_key,
        key_envelopes=[
            _recovery_box(
                account_id=owner["account_id"],
                instance=instance,
                generation=1,
                signing_public_key=b64url(recovery_signer.public_key),
                encryption_public_key=recovery_encryption_public_key,
                vault_id=context["vault_id"],
                key_epoch=context["key_epoch"],
                uploader_device_id=owner["device_id"],
                signer=recovery_signer,
            )
            for context in expected_contexts
        ],
    )

    started = api.request(
        "POST",
        "/api/v1/auth/recovery/start",
        json_body={"username": owner["username"]},
    )
    assert started.status == 200
    start_body = started.json()
    inspect_unsigned = {
        "protocol": "atermius-account-recovery-inspect-v1",
        "account_id": start_body["account_id"],
        "instance_id": start_body["instance_id"],
        "server_space_id": start_body["server_space_id"],
        "recovery_generation": start_body["recovery_generation"],
        "challenge_id": start_body["challenge_id"],
        "challenge": start_body["challenge"],
        "recovery_descriptor_hash": start_body["recovery_descriptor_hash"],
    }
    inspect_request = {
        key: value
        for key, value in inspect_unsigned.items()
        if key not in {"protocol", "recovery_descriptor_hash"}
    }
    inspect_request["recovery_signature"] = b64url(
        recovery_signer.sign(jcs(inspect_unsigned))
    )
    inspected = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=inspect_request
    )
    assert inspected.status == 200, f"Recovery inspect failed: {_error_code(inspected)}"
    inspected_body = inspected.json()
    assert inspected_body["required_contexts"] == expected_contexts
    assert inspected_body["recovery_status"] == "current"
    assert [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in inspected_body["present_contexts"]
    ] == [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in expected_contexts
    ]

    new_device_signer = SigningKey(tmp_path, "recovery-history-device")
    new_device_id = str(uuid.uuid4())
    new_device = {
        "device_id": new_device_id,
        "name": "Recovered historical-epoch test device",
        "signing_public_key": b64url(new_device_signer.public_key),
        "encryption_public_key": b64url(os.urandom(32)),
    }
    new_device["signature"] = b64url(new_device_signer.sign(jcs({
        "account_id": owner["account_id"],
        "device_id": new_device_id,
        "signing_public_key": new_device["signing_public_key"],
        "encryption_public_key": new_device["encryption_public_key"],
    })))
    next_recovery_signer = SigningKey(tmp_path, "recovery-history-v2")
    next_recovery_encryption_public_key = b64url(os.urandom(32))
    target_vault_envelopes = []
    next_recovery_boxes = []
    for context in expected_contexts:
        envelope = {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        }
        target_payload = {
            "vault_id": context["vault_id"],
            "recipient_device_id": new_device_id,
            "key_epoch": context["key_epoch"],
            "membership_version": context["membership_version"],
            "envelope": envelope,
        }
        target_vault_envelopes.append({
            **target_payload,
            "signature": b64url(new_device_signer.sign(jcs(target_payload))),
        })
        next_recovery_boxes.append(_recovery_box(
            account_id=owner["account_id"],
            instance=instance,
            generation=2,
            signing_public_key=b64url(next_recovery_signer.public_key),
            encryption_public_key=next_recovery_encryption_public_key,
            vault_id=context["vault_id"],
            key_epoch=context["key_epoch"],
            uploader_device_id=new_device_id,
            signer=next_recovery_signer,
        ))

    next_code_envelope = _opaque_envelope(528)
    next_identity_envelope = _opaque_envelope(96)
    next_recovery = {
        "recovery_public_signing_key": b64url(next_recovery_signer.public_key),
        "recovery_public_encryption_key": next_recovery_encryption_public_key,
        "recovery_envelope": next_code_envelope,
        "recovery_identity_envelope": next_identity_envelope,
        "key_envelopes": next_recovery_boxes,
        "recovery_identity_proof_signature": _identity_proof(
            account_id=owner["account_id"],
            instance=instance,
            generation=2,
            signing_public_key=b64url(next_recovery_signer.public_key),
            encryption_public_key=next_recovery_encryption_public_key,
            recovery_envelope=next_code_envelope,
            identity_envelope=next_identity_envelope,
            signer=next_recovery_signer,
        ),
    }
    completion_template = {
        "operation_id": "",
        "account_id": owner["account_id"],
        "instance_id": instance["instance_id"],
        "server_space_id": instance["server_space_id"],
        "recovery_generation": start_body["recovery_generation"],
        "challenge_id": start_body["challenge_id"],
        "challenge": start_body["challenge"],
        "new_kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "new_login_verifier": b64url(os.urandom(32)),
        "account_key_envelope": _account_key_envelope(),
        "device": new_device,
        "vault_key_envelopes": target_vault_envelopes,
        "next_recovery": next_recovery,
    }

    def signed_completion(*, omit_historic_epoch: bool = False, wrong_membership_version: bool = False) -> dict:
        request = json.loads(json.dumps(completion_template))
        request["operation_id"] = str(uuid.uuid4())
        historic_index = next(
            index
            for index, key in enumerate(request["vault_key_envelopes"])
            if key["vault_id"] == shared_vault_id and key["key_epoch"] == 1
        )
        if omit_historic_epoch:
            request["vault_key_envelopes"].pop(historic_index)
        if wrong_membership_version:
            target = request["vault_key_envelopes"][historic_index]
            target["membership_version"] += 1
            payload = {
                key: target[key]
                for key in (
                    "vault_id",
                    "recipient_device_id",
                    "key_epoch",
                    "membership_version",
                    "envelope",
                )
            }
            target["signature"] = b64url(new_device_signer.sign(jcs(payload)))
        request["recovery_signature"] = b64url(recovery_signer.sign(jcs({
            "protocol": "atermius-account-recovery-complete-v1",
            "request": request,
        })))
        return request

    database = _db_path(api)
    challenge_id_hash = hashlib.sha256(start_body["challenge_id"].encode()).hexdigest()
    fingerprint_key = os.urandom(32)

    def completion_state(operation_id: str) -> dict:
        with sqlite3.connect(database) as connection:
            return _completion_side_effect_snapshot(
                connection,
                account_id=owner["account_id"],
                new_device_id=new_device_id,
                operation_id=operation_id,
                challenge_id_hash=challenge_id_hash,
                fingerprint_key=fingerprint_key,
            )

    for request in (
        signed_completion(omit_historic_epoch=True),
        signed_completion(wrong_membership_version=True),
    ):
        before_failure = completion_state(request["operation_id"])
        assert before_failure["challenge_consumed_at"] is None
        rejected = api.request(
            "POST", "/api/v1/auth/recovery/complete", json_body=request
        )
        assert rejected.status == 409
        assert _error_code(rejected) == "RECOVERY_STALE"
        assert completion_state(request["operation_id"]) == before_failure

    valid_completion = signed_completion()
    completed = api.request(
        "POST", "/api/v1/auth/recovery/complete", json_body=valid_completion
    )
    assert completed.status == 200, f"full Recovery failed: {_error_code(completed)}"
    assert completed.json()["status"] == "recovered"
    assert completed.json()["recovery_generation"] == 2

    with sqlite3.connect(database) as connection:
        target_rows = connection.execute(
            "SELECT vault_id,epoch,membership_version FROM vault_key_envelopes "
            "WHERE recipient_user_id=? AND recipient_device_id=? ORDER BY vault_id,epoch",
            (owner["account_id"], new_device_id),
        ).fetchall()
        recovery_rows = connection.execute(
            "SELECT vault_id,key_epoch FROM account_recovery_key_envelopes "
            "WHERE user_id=? AND recovery_generation=2 ORDER BY vault_id,key_epoch",
            (owner["account_id"],),
        ).fetchall()
    assert target_rows == [
        (context["vault_id"], context["key_epoch"], context["membership_version"])
        for context in expected_contexts
    ]
    assert recovery_rows == [
        (context["vault_id"], context["key_epoch"])
        for context in expected_contexts
    ]

    new_login = api.request("POST", "/api/v1/auth/login", json_body={
        "username": owner["username"],
        "login_verifier": completion_template["new_login_verifier"],
        "device_id": new_device_id,
    })
    assert new_login.status == 200, f"recovered device login failed: {_error_code(new_login)}"
    restored_contexts = api.request(
        "GET", "/api/v1/auth/recovery/contexts", token=new_login.json()["access_token"]
    )
    assert restored_contexts.status == 200
    assert restored_contexts.json()["recovery_status"] == "current"
    assert restored_contexts.json()["required_contexts"] == expected_contexts
    assert [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in restored_contexts.json()["present_contexts"]
    ] == [
        {key: context[key] for key in ("vault_id", "key_epoch")}
        for context in expected_contexts
    ]


def test_recovery_start_global_live_challenge_cap_is_atomic_and_bounded(
    api: ApiClient,
    instance: dict,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Cap real and decoy challenges together, including concurrent starts."""
    if (
        not api.started_by_suite
        or not api.server_env
        or not api.admin_env
        or not api.temp_root
        or not hasattr(api, "stop_managed_server")
        or not hasattr(api, "start_managed_server")
    ):
        pytest.skip("Recovery cap acceptance needs a suite-owned restartable SQLite server")
    assert account.get("account_id")

    suffix = uuid.uuid4().hex[:12]
    configured = _register_account(
        api, f"recovery-cap-known-{suffix}@example.test", tmp_path, "cap-known"
    )
    recovery_signer = SigningKey(tmp_path, "recovery-cap-known-recovery")
    _configure_recovery(
        api, configured, instance, recovery_signer, b64url(os.urandom(32))
    )

    env_keys = [
        "ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES",
        "ATERMIUS_AUTH_RECOVERY_START_USER_LIMIT",
        "ATERMIUS_AUTH_RECOVERY_START_PAIR_LIMIT",
        "ATERMIUS_AUTH_RECOVERY_START_IP_LIMIT",
    ]
    missing = object()
    original_env = {key: api.server_env.get(key, missing) for key in env_keys}
    server_stopped = False
    database_path = _db_path(api)

    try:
        api.stop_managed_server()
        server_stopped = True
        api.server_env["ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES"] = "3"
        api.server_env["ATERMIUS_AUTH_RECOVERY_START_USER_LIMIT"] = "100"
        api.server_env["ATERMIUS_AUTH_RECOVERY_START_PAIR_LIMIT"] = "100"
        api.server_env["ATERMIUS_AUTH_RECOVERY_START_IP_LIMIT"] = "1000"
        api.start_managed_server()
        server_stopped = False

        expires_at = int(time.time()) + 180
        with sqlite3.connect(database_path) as connection:
            connection.execute("DELETE FROM account_recovery_challenges")
            seeded_hashes = _seed_recovery_challenge_rows(
                connection,
                count=2,
                expires_at=expires_at,
                real_user_id=configured["account_id"],
            )
            seeded = connection.execute(
                "SELECT challenge_id_hash,user_id FROM account_recovery_challenges "
                "ORDER BY challenge_id_hash"
            ).fetchall()
            assert len(seeded) == 2
            assert {row[1] for row in seeded} == {None, configured["account_id"]}

        unknown_username = f"recovery-cap-unknown-{suffix}@example.test"
        barrier = threading.Barrier(2)

        def start_recovery(username: str):
            barrier.wait(timeout=10)
            return api.request(
                "POST", "/api/v1/auth/recovery/start", json_body={"username": username}
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [
                executor.submit(start_recovery, configured["username"]),
                executor.submit(start_recovery, unknown_username),
            ]
            concurrent_responses = [future.result(timeout=30) for future in futures]

        assert sorted(response.status for response in concurrent_responses) == [200, 429]
        connection = sqlite3.connect(database_path)
        try:
            live_count = connection.execute(
                "SELECT COUNT(*) FROM account_recovery_challenges "
                "WHERE expires_at>? AND consumed_at IS NULL",
                (int(time.time()),),
            ).fetchone()[0]
        finally:
            connection.close()
        assert live_count == 3, "serialized concurrent starts must not exceed the configured cap"

        connection = sqlite3.connect(database_path)
        try:
            before_full_rejections = connection.execute(
                "SELECT challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at "
                "FROM account_recovery_challenges ORDER BY challenge_id_hash"
            ).fetchall()
        finally:
            connection.close()
        full_known = api.request(
            "POST",
            "/api/v1/auth/recovery/start",
            json_body={"username": configured["username"]},
        )
        full_unknown = api.request(
            "POST", "/api/v1/auth/recovery/start", json_body={"username": unknown_username}
        )
        assert full_known.status == full_unknown.status == 429
        assert set(full_known.json()) == set(full_unknown.json())
        assert _error_code(full_known) == _error_code(full_unknown) == "RATE_LIMITED"
        known_error = full_known.json()["error"]
        unknown_error = full_unknown.json()["error"]
        assert set(known_error) == set(unknown_error)
        assert known_error["code"] == unknown_error["code"]
        assert known_error["message"] == unknown_error["message"]
        earliest_expiry = min(row[4] for row in before_full_rejections if row[4] > int(time.time()))
        for response in (full_known, full_unknown):
            retry_after = int(response.headers["Retry-After"])
            assert 1 <= retry_after <= 180
            assert abs(retry_after - (earliest_expiry - int(time.time()))) <= 1
        connection = sqlite3.connect(database_path)
        try:
            after_full_rejections = connection.execute(
                "SELECT challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at "
                "FROM account_recovery_challenges ORDER BY challenge_id_hash"
            ).fetchall()
        finally:
            connection.close()
        assert after_full_rejections == before_full_rejections
        assert set(seeded_hashes).issubset({row[0] for row in after_full_rejections})

        # Expiry is strict: a row at expires_at == now is not live and is
        # removed in the same writer transaction before the replacement insert.
        expired_hash = next(row[0] for row in seeded if row[1] is None)
        with sqlite3.connect(database_path) as connection:
            connection.execute(
                "UPDATE account_recovery_challenges SET expires_at=? WHERE challenge_id_hash=?",
                (int(time.time()), expired_hash),
            )
        expiry_release = api.request(
            "POST",
            "/api/v1/auth/recovery/start",
            json_body={"username": f"recovery-cap-expiry-{suffix}@example.test"},
        )
        assert expiry_release.status == 200
        connection = sqlite3.connect(database_path)
        try:
            rows = connection.execute(
                "SELECT challenge_id_hash FROM account_recovery_challenges "
                "WHERE expires_at>? AND consumed_at IS NULL",
                (int(time.time()),),
            ).fetchall()
        finally:
            connection.close()
        assert len(rows) == 3
        assert expired_hash not in {row[0] for row in rows}

        # An invalid configured limit must fall back to exactly 10,000. Prove
        # both sides of that default after a clean restart with the invalid env.
        api.stop_managed_server()
        server_stopped = True
        api.server_env["ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES"] = "0"
        api.start_managed_server()
        server_stopped = False
        with sqlite3.connect(database_path) as connection:
            connection.execute("DELETE FROM account_recovery_challenges")
            _seed_recovery_challenge_rows(
                connection, count=9_999, expires_at=int(time.time()) + 180
            )
        fallback_username = f"recovery-cap-fallback-{suffix}@example.test"
        fallback_slot = api.request(
            "POST", "/api/v1/auth/recovery/start", json_body={"username": fallback_username}
        )
        assert fallback_slot.status == 200
        connection = sqlite3.connect(database_path)
        try:
            assert connection.execute(
                "SELECT COUNT(*) FROM account_recovery_challenges "
                "WHERE expires_at>? AND consumed_at IS NULL",
                (int(time.time()),),
            ).fetchone()[0] == 10_000
        finally:
            connection.close()
        fallback_full = api.request(
            "POST", "/api/v1/auth/recovery/start", json_body={"username": fallback_username}
        )
        assert fallback_full.status == 429
        assert _error_code(fallback_full) == "RATE_LIMITED"
        connection = sqlite3.connect(database_path)
        try:
            assert connection.execute(
                "SELECT COUNT(*) FROM account_recovery_challenges "
                "WHERE expires_at>? AND consumed_at IS NULL",
                (int(time.time()),),
            ).fetchone()[0] == 10_000
        finally:
            connection.close()
    finally:
        if not server_stopped:
            api.stop_managed_server()
            server_stopped = True
        with sqlite3.connect(database_path) as connection:
            connection.execute("DELETE FROM account_recovery_challenges")
        for key, value in original_env.items():
            if value is missing:
                api.server_env.pop(key, None)
            else:
                api.server_env[key] = value
        api.start_managed_server()
