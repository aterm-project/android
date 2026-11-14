"""Black-box negative security checks for account recovery."""

from __future__ import annotations

import os
import uuid
from pathlib import Path

from conftest import ApiClient, SigningKey, b64url, jcs, unb64url
from test_account_deletion import _register_account
from test_account_recovery import _configure_recovery, _error_code


def test_inspect_rejects_context_changed_after_valid_recovery_signature(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    user = _register_account(
        api,
        f"recovery-context-{uuid.uuid4().hex[:12]}@example.test",
        tmp_path,
        "recovery-context",
    )
    recovery_signer = SigningKey(tmp_path, "recovery-context-identity")
    _configure_recovery(
        api, user, instance, recovery_signer, b64url(os.urandom(32))
    )

    started = api.request(
        "POST",
        "/api/v1/auth/recovery/start",
        json_body={"username": user["username"]},
    )
    assert started.status == 200
    start_body = started.json()
    signed_context = {
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
        for key, value in signed_context.items()
        if key not in {"protocol", "recovery_descriptor_hash"}
    }
    inspect_request["recovery_signature"] = b64url(
        recovery_signer.sign(jcs(signed_context))
    )

    # Keep the valid signature for the server-issued context, then change the
    # challenge in transit. Both challenge values are correctly encoded and
    # have the required length, so rejection must come from context binding.
    altered_challenge = bytearray(unb64url(inspect_request["challenge"]))
    altered_challenge[0] ^= 1
    tampered_request = {
        **inspect_request,
        "challenge": b64url(bytes(altered_challenge)),
    }
    rejected = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=tampered_request
    )
    assert rejected.status == 401
    assert _error_code(rejected) == "RECOVERY_FAILED"

    # The same signed request succeeds unchanged, proving the test's signature
    # was valid and the challenge remains usable after the rejected attempt.
    accepted = api.request(
        "POST", "/api/v1/auth/recovery/inspect", json_body=inspect_request
    )
    assert accepted.status == 200
    assert accepted.json()["recovery_generation"] == start_body["recovery_generation"]
