"""Acceptance coverage for the per-account active-device ceiling."""

from __future__ import annotations

import os
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from conftest import ApiClient, SigningKey, b64url, jcs


DEVICE_LIMIT = 20


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _enrollment(
    account: dict[str, Any], directory: Path, label: str
) -> tuple[str, dict[str, Any]]:
    signer = SigningKey(directory, label)
    device_id = str(uuid.uuid4())
    device_fields = {
        "device_id": device_id,
        "signing_public_key": b64url(signer.public_key),
        "encryption_public_key": b64url(os.urandom(32)),
    }
    device = {
        **device_fields,
        "name": f"Device limit {label}",
        "signature": b64url(
            signer.sign(jcs({"account_id": account["account_id"], **device_fields}))
        ),
    }
    key_fields = {
        "vault_id": account["vault_id"],
        "recipient_device_id": device_id,
        "key_epoch": 1,
        "membership_version": 1,
        "envelope": {
            "version": 1,
            "suite": "crypto_box_seal",
            "ciphertext": b64url(os.urandom(48)),
        },
    }
    enrollment_unsigned = {
        "account_id": account["account_id"],
        "approver_device_id": account["device_id"],
        "device": device,
    }
    request = {
        "device": device,
        "approver_device_id": account["device_id"],
        "certificate_signature": b64url(
            account["signing_key"].sign(jcs(enrollment_unsigned))
        ),
        "vault_key_envelopes": [
            {
                **key_fields,
                "signature": b64url(account["signing_key"].sign(jcs(key_fields))),
            }
        ],
    }
    return device_id, request


def _devices(api: ApiClient, account: dict[str, Any]) -> list[dict[str, Any]]:
    response = api.request("GET", "/api/v1/devices", token=account["access_token"])
    assert response.status == 200, f"device list failed: {_error_code(response)}"
    return response.json()["devices"]


def _assert_absent_from_database(api: ApiClient, device_id: str) -> None:
    admin_env = getattr(api, "admin_env", None)
    database_url = (admin_env or {}).get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        # External API runs can still verify the public device directory. The
        # suite-owned SQLite path additionally checks that no envelope row was
        # committed for a rejected candidate.
        return
    path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
    with sqlite3.connect(path, timeout=30) as connection:
        device_count = connection.execute(
            "SELECT COUNT(*) FROM devices WHERE device_id=?", (device_id,)
        ).fetchone()[0]
        envelope_count = connection.execute(
            "SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_device_id=?",
            (device_id,),
        ).fetchone()[0]
    assert device_count == 0, "rejected enrollment left a device row behind"
    assert envelope_count == 0, "rejected enrollment left a key envelope behind"


def test_active_device_limit_is_atomic_and_revoked_devices_do_not_count(
    api: ApiClient, account: dict[str, Any], tmp_path: Path
) -> None:
    # Registration creates the first active device. Fill to 19, then race two
    # valid signed approvals for the final slot using the same live approver.
    assert sum(device["status"] == "active" for device in _devices(api, account)) == 1
    for index in range(1, DEVICE_LIMIT - 1):
        device_id, request = _enrollment(account, tmp_path, f"fill-{index}")
        enrolled = api.request(
            "POST", "/api/v1/devices", token=account["access_token"], json_body=request
        )
        assert enrolled.status == 200, (
            f"enrollment {index} failed with HTTP {enrolled.status}: {_error_code(enrolled)}"
        )
        assert enrolled.json()["device_id"] == device_id

    contenders = [
        _enrollment(account, tmp_path, "race-a"),
        _enrollment(account, tmp_path, "race-b"),
    ]
    start = threading.Barrier(2)

    def submit(request: dict[str, Any]):
        start.wait(timeout=10)
        return api.request(
            "POST", "/api/v1/devices", token=account["access_token"], json_body=request
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda item: submit(item[1]), contenders))

    accepted = [
        (contenders[index][0], response)
        for index, response in enumerate(responses)
        if response.status == 200
    ]
    rejected = [
        (contenders[index][0], response)
        for index, response in enumerate(responses)
        if response.status != 200
    ]
    assert len(accepted) == 1, [
        (response.status, _error_code(response)) for response in responses
    ]
    assert len(rejected) == 1
    rejected_id, rejection = rejected[0]
    assert rejection.status == 409
    assert _error_code(rejection) == "ACTIVE_DEVICE_LIMIT_REACHED"

    devices = _devices(api, account)
    active_ids = {item["device_id"] for item in devices if item["status"] == "active"}
    assert len(active_ids) == DEVICE_LIMIT
    assert accepted[0][0] in active_ids
    assert rejected_id not in {item["device_id"] for item in devices}
    _assert_absent_from_database(api, rejected_id)

    # Revoking one active sibling frees exactly one slot. The rejected request
    # is still absent, and a fresh signed enrollment can consume the slot.
    revoked_id = accepted[0][0]
    revoked = api.request(
        "POST",
        f"/api/v1/devices/{revoked_id}/revoke",
        token=account["access_token"],
    )
    assert revoked.status == 200, f"device revoke failed: {_error_code(revoked)}"
    replacement_id, replacement = _enrollment(account, tmp_path, "reuse-revoked-slot")
    replacement_response = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body=replacement,
    )
    assert replacement_response.status == 200, (
        "a revoked device must not consume an active-device slot: "
        f"{_error_code(replacement_response)}"
    )
    assert replacement_response.json()["device_id"] == replacement_id
    active_ids = {
        item["device_id"] for item in _devices(api, account) if item["status"] == "active"
    }
    assert len(active_ids) == DEVICE_LIMIT
    assert replacement_id in active_ids
    assert revoked_id not in active_ids

    # A sequential 21st active device receives the same stable error and has
    # neither a device row nor a recipient key envelope committed.
    excess_id, excess = _enrollment(account, tmp_path, "sequential-21st")
    excess_response = api.request(
        "POST", "/api/v1/devices", token=account["access_token"], json_body=excess
    )
    assert excess_response.status == 409
    assert _error_code(excess_response) == "ACTIVE_DEVICE_LIMIT_REACHED"
    assert excess_id not in {item["device_id"] for item in _devices(api, account)}
    _assert_absent_from_database(api, excess_id)
