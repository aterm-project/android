"""Signed device capability reports and schema-2 reader gates."""

from __future__ import annotations

import os
import json
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from conftest import ApiClient, Response, SigningKey, b64url, jcs, verify_ed25519
from test_acceptance import (
    _issue_account_invitation,
    _membership_digest,
    _membership_member,
    _new_account_registration,
    _signed_key_envelope,
    _signed_membership,
)
from test_object_references import (
    _assert_no_commit,
    _db,
    _last_sequence,
    _operation,
    _upload_object,
)


def _error_code(response) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _request_with_marker(
    api: ApiClient,
    method: str,
    path: str,
    *,
    token: str | None = None,
    json_body: Any = None,
    raw_body: bytes | None = None,
    content_type: str | None = None,
    marker: str | None,
    redaction_marker: str | None = None,
) -> Response:
    headers = {"Accept": "application/json"}
    body = raw_body
    if json_body is not None:
        body = json.dumps(json_body, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif content_type:
        headers["Content-Type"] = content_type
    if token:
        headers["Authorization"] = f"Bearer {token}"
        if marker is not None:
            headers["X-Atermius-Capability-Marker"] = marker
        if redaction_marker is not None:
            headers["X-Atermius-Redaction-Marker"] = redaction_marker
    request = urllib.request.Request(
        api.base_url + path,
        data=body,
        headers=headers,
        method=method.upper(),
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as result:
            return Response(result.status, result.headers, result.read())
    except urllib.error.HTTPError as error:
        return Response(error.code, error.headers, error.read())


def _use_v2_client_marker(api: ApiClient) -> None:
    def marked_request(method: str, path: str, **kwargs: Any) -> Response:
        return _request_with_marker(api, method, path, marker="v2", **kwargs)

    # Keep this test-local so the shared integration harness can still issue
    # explicit legacy requests to exercise downgrade behavior.
    api.request = marked_request  # type: ignore[method-assign]


def _report(account: dict[str, Any], *, revision: int, schema: int, versions: list[int], max_bytes: int) -> dict[str, Any]:
    payload = {
        "account_id": account["account_id"],
        "device_id": account["device_id"],
        "revision": revision,
        "max_record_schema": schema,
        "host_attachment_manifest_versions": versions,
        "max_attachment_bytes": max_bytes,
    }
    return {
        **payload,
        "signature": b64url(account["signing_key"].sign(jcs(payload))),
    }


def _redaction_report(account: dict[str, Any], *, revision: int) -> dict[str, Any]:
    payload = {
        "format": "atermius-sync-redaction-capability-v1",
        "account_id": account["account_id"],
        "device_id": account["device_id"],
        "revision": revision,
        "sync_redaction_version": 1,
    }
    return {**payload, "signature": b64url(account["signing_key"].sign(jcs(payload)))}


def test_redaction_capability_is_separate_signed_monotonic_and_marker_gated(
    api: ApiClient,
    instance: dict[str, Any],
    account: dict[str, Any],
) -> None:
    assert "device_redaction_capability_reports" in instance["capabilities"]
    path = "/api/v1/devices/redaction-capabilities"
    report = _redaction_report(account, revision=1)

    missing_marker = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=report,
        marker=None,
    )
    assert missing_marker.status == 400
    assert _error_code(missing_marker) == "INVALID_REDACTION_MARKER"

    bad_signature = {**report, "signature": b64url(b"x" * 64)}
    rejected = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=bad_signature,
        marker=None,
        redaction_marker="v1",
    )
    assert rejected.status == 400
    assert _error_code(rejected) == "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT"

    stored = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=report,
        marker=None,
        redaction_marker="v1",
    )
    assert stored.status == 200, f"redaction report save failed: {_error_code(stored)}"
    assert stored.json()["already_applied"] is False
    assert stored.json()["redaction_capability_report"] == report
    assert verify_ed25519(
        account["signing_public_key"],
        jcs({key: value for key, value in report.items() if key != "signature"}),
        stored.json()["redaction_capability_report"]["signature"],
    )

    repeated = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=report,
        marker=None,
        redaction_marker="v1",
    )
    assert repeated.status == 200
    assert repeated.json()["already_applied"] is True

    newer = _redaction_report(account, revision=2)
    saved_newer = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=newer,
        marker=None,
        redaction_marker="v1",
    )
    assert saved_newer.status == 200
    stale = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=report,
        marker=None,
        redaction_marker="v1",
    )
    assert stale.status == 409
    assert _error_code(stale) == "DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT"

    legacy_request = api.request("GET", "/api/v1/me", token=account["access_token"])
    assert legacy_request.status == 200
    database_url = (api.admin_env or {}).get("ATERMIUS_DATABASE_URL", "")
    if database_url.startswith("sqlite://"):
        with _db(api) as connection:
            stored_row = connection.execute(
                "SELECT revision,invalidated_at FROM device_redaction_capability_reports WHERE device_id=?",
                (account["device_id"],),
            ).fetchone()
        assert stored_row is not None
        assert stored_row["revision"] == 2
        assert stored_row["invalidated_at"] is not None

    replay_invalidated = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=newer,
        marker=None,
        redaction_marker="v1",
    )
    assert replay_invalidated.status == 409
    assert _error_code(replay_invalidated) == "DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT"
    restored = _request_with_marker(
        api,
        "PUT",
        path,
        token=account["access_token"],
        json_body=_redaction_report(account, revision=3),
        marker=None,
        redaction_marker="v1",
    )
    assert restored.status == 200


def _schema2(envelope: dict[str, Any], account: dict[str, Any]) -> dict[str, Any]:
    envelope["header"]["record_schema"] = 2
    payload = {key: envelope[key] for key in ("header", "nonce", "ciphertext")}
    envelope["signature"] = b64url(account["signing_key"].sign(jcs(payload)))
    return envelope


def _register_v1_recipient(
    api: ApiClient, tmp_path: Path, *, label: str = "v1-recipient"
) -> dict[str, Any]:
    username = f"it-device-capability-{uuid.uuid4().hex[:12]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    signer = SigningKey(tmp_path, label)
    encryption_public_key = b64url(os.urandom(32))
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
    assert response.status in (200, 201), f"recipient registration failed: {_error_code(response)}"
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "login_verifier": registration["login_verifier"],
        "access_token": response.json()["access_token"],
        "signing_key": signer,
        "signing_public_key": b64url(signer.public_key),
        "encryption_public_key": encryption_public_key,
        "vault_id": registration["initial_vault"]["vault_id"],
        "initial_vault": registration["initial_vault"],
        "device_seq": 0,
    }


def _enroll_sibling_device(
    api: ApiClient, owner: dict[str, Any], tmp_path: Path
) -> dict[str, Any]:
    signer = SigningKey(tmp_path, "capability-sibling")
    device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    device_fields = {
        "device_id": device_id,
        "signing_public_key": b64url(signer.public_key),
        "encryption_public_key": encryption_public_key,
    }
    device = {
        **device_fields,
        "name": "Capability gate sibling",
        "signature": b64url(
            signer.sign(jcs({"account_id": owner["account_id"], **device_fields}))
        ),
    }

    vaults = api.request("GET", "/api/v1/vaults", token=owner["access_token"])
    assert vaults.status == 200, f"vault lookup failed: {_error_code(vaults)}"
    envelopes = []
    for vault in vaults.json()["vaults"]:
        for source in vault["key_envelopes"]:
            unsigned = {
                "vault_id": vault["vault_id"],
                "recipient_device_id": device_id,
                "key_epoch": source["key_epoch"],
                "membership_version": source["membership_version"],
                "envelope": {
                    "version": 1,
                    "suite": "crypto_box_seal",
                    "ciphertext": b64url(os.urandom(48)),
                },
            }
            envelopes.append(
                {
                    **unsigned,
                    "signature": b64url(owner["signing_key"].sign(jcs(unsigned))),
                }
            )
    assert envelopes, "owner has no vault key envelopes for sibling enrollment"

    enrollment_unsigned = {
        "account_id": owner["account_id"],
        "approver_device_id": owner["device_id"],
        "device": device,
    }
    enrolled = api.request(
        "POST",
        "/api/v1/devices",
        token=owner["access_token"],
        json_body={
            "device": device,
            "approver_device_id": owner["device_id"],
            "certificate_signature": b64url(
                owner["signing_key"].sign(jcs(enrollment_unsigned))
            ),
            "vault_key_envelopes": envelopes,
        },
    )
    assert enrolled.status in (200, 201), f"sibling enrollment failed: {_error_code(enrolled)}"
    login = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": owner["username"],
            "login_verifier": owner["login_verifier"],
            "device_id": device_id,
        },
    )
    assert login.status == 200, f"sibling login failed: {_error_code(login)}"
    return {
        "account_id": owner["account_id"],
        "device_id": device_id,
        "access_token": login.json()["access_token"],
        "signing_key": signer,
    }


def test_device_reports_are_signed_monotonic_and_gate_schema_two(
    api: ApiClient,
    instance: dict[str, Any],
    account: dict[str, Any],
    make_envelope,
    push,
    tmp_path: Path,
) -> None:
    _use_v2_client_marker(api)
    assert "device_capability_reports" in instance["capabilities"]
    assert instance["limits"] == {
        "max_object_bytes": 64 * 1024 * 1024,
        "max_upload_chunk_bytes": 1024 * 1024,
        "max_record_object_refs": 1024,
    }

    devices_path = "/api/v1/devices"
    initial_devices = api.request("GET", devices_path, token=account["access_token"])
    assert initial_devices.status == 200
    device = next(
        item
        for item in initial_devices.json()["devices"]
        if item["device_id"] == account["device_id"]
    )
    assert device["capability_report"] is None

    blocked = push(_schema2(make_envelope(), account))
    assert blocked.status == 409
    assert _error_code(blocked) == "VAULT_CLIENT_CAPABILITY_REQUIRED"

    base_report = _report(
        account,
        revision=1,
        schema=1,
        versions=[1],
        max_bytes=256 * 1024 * 1024,
    )
    invalid_signature = {**base_report, "signature": b64url(b"x" * 64)}
    rejected = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=invalid_signature,
    )
    assert rejected.status == 422
    assert _error_code(rejected) == "INVALID_ENVELOPE"

    unsorted = _report(
        account,
        revision=1,
        schema=2,
        versions=[2, 1],
        max_bytes=1024 * 1024 * 1024,
    )
    rejected = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=unsorted,
    )
    assert rejected.status == 400
    assert _error_code(rejected) == "INVALID_DEVICE_CAPABILITY_REPORT"

    stored = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=base_report,
    )
    assert stored.status == 200, f"report save failed: {_error_code(stored)}"
    assert stored.json()["already_applied"] is False
    assert verify_ed25519(
        account["signing_public_key"],
        jcs({key: value for key, value in base_report.items() if key != "signature"}),
        stored.json()["capability_report"]["signature"],
    )

    same_revision_changed = _report(
        account,
        revision=1,
        schema=1,
        versions=[1],
        max_bytes=1,
    )
    rejected = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=same_revision_changed,
    )
    assert rejected.status == 409
    assert _error_code(rejected) == "DEVICE_CAPABILITY_REVISION_CONFLICT"

    compatible = _report(
        account,
        revision=2,
        schema=2,
        versions=[1, 2],
        max_bytes=1024 * 1024 * 1024,
    )
    saved = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=compatible,
    )
    assert saved.status == 200

    own_devices = api.request("GET", devices_path, token=account["access_token"])
    self_report = next(
        item
        for item in own_devices.json()["devices"]
        if item["device_id"] == account["device_id"]
    )["capability_report"]
    assert self_report == compatible

    vault_directory = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/devices",
        token=account["access_token"],
    )
    assert vault_directory.status == 200
    directory_device = next(
        item
        for item in vault_directory.json()["devices"]
        if item["device_id"] == account["device_id"]
    )
    assert directory_device["membership_status"] == "active"
    assert directory_device["capability_report"] == compatible

    committed = push(_schema2(make_envelope(), account))
    assert committed.status == 200, f"schema-2 push failed: {_error_code(committed)}"
    vaults = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert vaults.status == 200
    vault = next(item for item in vaults.json()["vaults"] if item["vault_id"] == account["vault_id"])
    assert vault["required_record_schema"] == 2

    # A new legacy client cannot join an account whose active vault has
    # committed schema 2. The rejected transaction must leave no device row.
    candidate_signer = SigningKey(tmp_path, "schema1-candidate")
    candidate_id = str(uuid.uuid4())
    candidate_fields = {
        "device_id": candidate_id,
        "encryption_public_key": b64url(os.urandom(32)),
        "signing_public_key": b64url(candidate_signer.public_key),
    }
    candidate_device = {
        **candidate_fields,
        "name": "schema1-candidate",
        "signature": b64url(
            candidate_signer.sign(
                jcs({"account_id": account["account_id"], **candidate_fields})
            )
        ),
    }
    candidate_enrollment = {
        "device": candidate_device,
        "approver_device_id": account["device_id"],
        "certificate_signature": b64url(
            account["signing_key"].sign(
                jcs(
                    {
                        "account_id": account["account_id"],
                        "approver_device_id": account["device_id"],
                        "device": candidate_device,
                    }
                )
            )
        ),
        "vault_key_envelopes": [],
    }
    blocked_enrollment = api.request(
        "POST",
        "/api/v1/devices",
        token=account["access_token"],
        json_body=candidate_enrollment,
    )
    assert blocked_enrollment.status == 409
    assert _error_code(blocked_enrollment) == "DEVICE_CAPABILITY_REQUIRED"
    after_rejected_enrollment = api.request(
        "GET", devices_path, token=account["access_token"]
    )
    assert all(
        item["device_id"] != candidate_id
        for item in after_rejected_enrollment.json()["devices"]
    )

    # A registered recipient with an explicit v1 report cannot accept a
    # schema-2 vault invitation. The pending invitation remains usable after
    # that recipient later publishes a compatible report.
    recipient = _register_v1_recipient(api, tmp_path)
    recipient_v1 = _report(
        recipient,
        revision=1,
        schema=1,
        versions=[1],
        max_bytes=256 * 1024 * 1024,
    )
    saved_recipient_v1 = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=recipient["access_token"],
        json_body=recipient_v1,
    )
    assert saved_recipient_v1.status == 200
    previous_membership = account["initial_vault"]["membership"]
    membership_v2 = _signed_membership(
        account["vault_id"],
        2,
        _membership_digest(account["vault_id"], previous_membership),
        1,
        [
            _membership_member(
                account["account_id"], "owner", account["encryption_public_key"]
            ),
            _membership_member(
                recipient["account_id"], "editor", recipient["encryption_public_key"]
            ),
        ],
        account["device_id"],
        account["signing_key"],
    )
    invitation_key = _signed_key_envelope(
        account["vault_id"], recipient["device_id"], 1, 2, account["signing_key"]
    )
    issued = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/invitations",
        token=account["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": recipient["device_id"],
            "recipient_encryption_public_key": recipient["encryption_public_key"],
            "key_envelope": invitation_key,
            "membership": membership_v2,
        },
    )
    assert issued.status in (200, 201), f"invite issue failed: {_error_code(issued)}"
    pending_invitation = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=recipient["access_token"],
        json_body={"token": issued.json()["token"]},
    )
    assert pending_invitation.status == 409
    assert _error_code(pending_invitation) == "VAULT_CLIENT_CAPABILITY_REQUIRED"
    member_page = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/members",
        token=account["access_token"],
    )
    invited_member = next(
        item
        for item in member_page.json()["members"]
        if item["user_id"] == recipient["account_id"]
    )
    assert invited_member["state"] == "invited"
    assert invited_member["invitation"]["status"] == "pending"

    vault_directory = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/devices",
        token=account["access_token"],
    )
    pending_device = next(
        item
        for item in vault_directory.json()["devices"]
        if item["device_id"] == recipient["device_id"]
    )
    assert pending_device["membership_status"] == "invited"
    assert pending_device["capability_report"] is None

    recipient_v2 = _report(
        recipient,
        revision=2,
        schema=2,
        versions=[1, 2],
        max_bytes=1024 * 1024 * 1024,
    )
    upgraded_recipient = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=recipient["access_token"],
        json_body=recipient_v2,
    )
    assert upgraded_recipient.status == 200
    accepted_invitation = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=recipient["access_token"],
        json_body={"token": issued.json()["token"]},
    )
    assert accepted_invitation.status in (200, 201)
    accepted_directory = api.request(
        "GET",
        f"/api/v1/vaults/{account['vault_id']}/devices",
        token=account["access_token"],
    )
    accepted_device = next(
        item
        for item in accepted_directory.json()["devices"]
        if item["device_id"] == recipient["device_id"]
    )
    assert accepted_device["membership_status"] == "active"
    assert accepted_device["capability_report"] == recipient_v2

    downgrade = _report(
        account,
        revision=3,
        schema=1,
        versions=[1],
        max_bytes=256 * 1024 * 1024,
    )
    rejected = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=downgrade,
    )
    assert rejected.status == 409
    assert _error_code(rejected) == "DEVICE_CAPABILITY_REQUIRED"

    duplicate = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=compatible,
    )
    assert duplicate.status == 200
    assert duplicate.json()["already_applied"] is True

    # A current-head and conflict snapshot are created by a v2 client before
    # an old client contacts the same account. The marker is deliberately
    # unsigned: it can revoke a prior strong report, but cannot recreate one.
    conflict_branch = _schema2(make_envelope(), account)
    stored_conflict = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/conflicts",
        token=account["access_token"],
        json_body={"envelope": conflict_branch},
    )
    assert stored_conflict.status == 200, f"schema-2 conflict failed: {_error_code(stored_conflict)}"
    stored_conflict_id = stored_conflict.json()["conflict_id"]
    v2_snapshot = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/snapshots",
        token=account["access_token"],
    )
    assert v2_snapshot.status == 200, f"v2 snapshot failed: {_error_code(v2_snapshot)}"
    snapshot_id = v2_snapshot.json()["snapshot_id"]

    old_request = _request_with_marker(
        api,
        "GET",
        "/api/v1/vaults",
        token=account["access_token"],
        marker=None,
    )
    assert old_request.status == 200
    devices_after_rollback = api.request(
        "GET", devices_path, token=account["access_token"]
    )
    current_report = next(
        item
        for item in devices_after_rollback.json()["devices"]
        if item["device_id"] == account["device_id"]
    )["capability_report"]
    assert current_report is None, "v1 marker did not revoke the stored strong report"

    # A lost conflict-upload receipt may be retried after the device's strong
    # capability report has been revoked. The exact same signed request has
    # no new write effect, so it must return the original conflict before the
    # schema-v2 capability gate is evaluated.
    conflict_retry = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/conflicts",
        token=account["access_token"],
        json_body={"envelope": conflict_branch},
    )
    assert conflict_retry.status == 200, (
        "exact schema-v2 conflict retry after capability revocation should be idempotent; "
        f"got {_error_code(conflict_retry)}"
    )
    assert conflict_retry.json()["conflict_id"] == stored_conflict_id

    attempted_report_restore = _request_with_marker(
        api,
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=_report(
            account,
            revision=4,
            schema=2,
            versions=[1, 2],
            max_bytes=1024 * 1024 * 1024,
        ),
        marker="v1",
    )
    assert attempted_report_restore.status == 409
    assert _error_code(attempted_report_restore) == "VAULT_CLIENT_CAPABILITY_REQUIRED"

    # A v2 marker alone is not a signed write capability. The next v2 write is
    # blocked, and every old-reader endpoint that would expose schema-2
    # envelopes fails closed before returning ciphertext.
    rejected_writer = push(_schema2(make_envelope(), account))
    assert rejected_writer.status == 409
    assert _error_code(rejected_writer) == "VAULT_CLIENT_CAPABILITY_REQUIRED"

    old_reads = [
        _request_with_marker(
            api,
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes",
            token=account["access_token"],
            marker=None,
        ),
        _request_with_marker(
            api,
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/snapshots",
            token=account["access_token"],
            marker="v1",
        ),
        _request_with_marker(
            api,
            "GET",
            f"/api/v1/snapshots/{snapshot_id}",
            token=account["access_token"],
            marker=None,
        ),
    ]
    history_query = urllib.parse.urlencode({"snapshot_id": snapshot_id})
    old_reads.extend(
        _request_with_marker(
            api,
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/{collection}?{history_query}",
            token=account["access_token"],
            marker=None,
        )
        for collection in ("revisions", "conflicts")
    )
    old_reads.append(
        _request_with_marker(
            api,
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?after_seq=0&server_generation={instance['generation']}",
            token=account["access_token"],
            marker=None,
        )
    )
    old_reads.append(
        _request_with_marker(
            api,
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions/{committed.json()['results'][0]['revision_id']}",
            token=account["access_token"],
            marker=None,
        )
    )
    assert all(
        response.status == 409
        and _error_code(response) == "VAULT_CLIENT_CAPABILITY_REQUIRED"
        for response in old_reads
    ), [(response.status, _error_code(response)) for response in old_reads]


def test_schema_two_push_waits_for_every_active_reader_atomically(
    api: ApiClient,
    account: dict[str, Any],
    tmp_path: Path,
) -> None:
    """A writer may commit schema 2 only after each active vault reader reports support."""
    _use_v2_client_marker(api)
    # The module account fixture consumes the one-time bootstrap so this test
    # can issue ordinary account invitations for its isolated writer/readers.
    assert account["account_id"]
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200
    instance = live_instance.json()

    owner = _register_v1_recipient(api, tmp_path, label="capability-gate-owner")
    sibling = _enroll_sibling_device(api, owner, tmp_path)
    editor = _register_v1_recipient(api, tmp_path, label="capability-gate-editor")

    # The owner adds an editor while the vault is still at schema floor 1.
    membership = _signed_membership(
        owner["vault_id"],
        2,
        _membership_digest(owner["vault_id"], owner["initial_vault"]["membership"]),
        1,
        [
            _membership_member(
                owner["account_id"], "owner", owner["encryption_public_key"]
            ),
            _membership_member(
                editor["account_id"], "editor", editor["encryption_public_key"]
            ),
        ],
        owner["device_id"],
        owner["signing_key"],
    )
    invitation_key = _signed_key_envelope(
        owner["vault_id"], editor["device_id"], 1, 2, owner["signing_key"]
    )
    issued = api.request(
        "POST",
        f"/api/v1/vaults/{owner['vault_id']}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "editor",
            "recipient_device_id": editor["device_id"],
            "recipient_encryption_public_key": editor["encryption_public_key"],
            "key_envelope": invitation_key,
            "membership": membership,
        },
    )
    assert issued.status in (200, 201), f"editor invitation failed: {_error_code(issued)}"

    editor_v1 = _report(
        editor,
        revision=1,
        schema=1,
        versions=[1],
        max_bytes=256 * 1024 * 1024,
    )
    saved_editor_v1 = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=editor["access_token"],
        json_body=editor_v1,
    )
    assert saved_editor_v1.status == 200
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=editor["access_token"],
        json_body={"token": issued.json()["token"]},
    )
    assert accepted.status in (200, 201), f"editor acceptance failed: {_error_code(accepted)}"

    sibling_v1 = _report(
        {**sibling, "account_id": owner["account_id"]},
        revision=1,
        schema=1,
        versions=[1],
        max_bytes=256 * 1024 * 1024,
    )
    saved_sibling_v1 = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=sibling["access_token"],
        json_body=sibling_v1,
    )
    assert saved_sibling_v1.status == 200
    owner_v2 = _report(
        owner,
        revision=1,
        schema=2,
        versions=[1, 2],
        max_bytes=1024 * 1024 * 1024,
    )
    saved_owner_v2 = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=owner["access_token"],
        json_body=owner_v2,
    )
    assert saved_owner_v2.status == 200

    directory = api.request(
        "GET",
        f"/api/v1/vaults/{owner['vault_id']}/devices",
        token=owner["access_token"],
    )
    assert directory.status == 200
    active_reader_ids = {
        device["device_id"]
        for device in directory.json()["devices"]
        if device["membership_status"] == "active"
    }
    assert {
        owner["device_id"],
        sibling["device_id"],
        editor["device_id"],
    } <= active_reader_ids

    # A completed object is available to reference, but failed schema gates
    # must not create a reference or any sync commit/receipt side effects.
    object_id, _upload_id = _upload_object(
        api,
        owner["vault_id"],
        owner["access_token"],
        b"encrypted-v2-directory-and-chunks",
    )
    operation = _operation(
        instance,
        owner,
        object_refs=[object_id],
        include_refs=True,
    )
    operation["header"]["membership_version"] = str(membership["membership_version"])
    operation = _schema2(operation, owner)
    batch_id = str(uuid.uuid4())
    request_body = {
        "protocol_version": instance.get("protocol_version", 1),
        "server_generation": str(instance["generation"]),
        "vault_id": owner["vault_id"],
        "device_id": owner["device_id"],
        "batch_id": batch_id,
        "operations": [operation],
    }
    previous_sequence = _last_sequence(api, owner["vault_id"])

    def submit_exact_request():
        return api.request(
            "POST",
            f"/api/v1/vaults/{owner['vault_id']}/sync/push",
            token=owner["access_token"],
            json_body=request_body,
        )

    def assert_floor_one() -> None:
        vaults_response = api.request(
            "GET", "/api/v1/vaults", token=owner["access_token"]
        )
        assert vaults_response.status == 200
        vault = next(
            item
            for item in vaults_response.json()["vaults"]
            if item["vault_id"] == owner["vault_id"]
        )
        assert vault["required_record_schema"] == 1

    blocked_by_sibling = submit_exact_request()
    assert blocked_by_sibling.status == 409
    assert _error_code(blocked_by_sibling) == "VAULT_CLIENT_CAPABILITY_REQUIRED"
    _assert_no_commit(api, owner, [operation], batch_id, previous_sequence)
    assert_floor_one()

    # Raising only the sibling report still leaves the active editor as a
    # schema-1 reader, so the exact same signed batch remains safely blocked.
    sibling_v2 = _report(
        {**sibling, "account_id": owner["account_id"]},
        revision=2,
        schema=2,
        versions=[1, 2],
        max_bytes=1024 * 1024 * 1024,
    )
    upgraded_sibling = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=sibling["access_token"],
        json_body=sibling_v2,
    )
    assert upgraded_sibling.status == 200

    blocked_by_editor = submit_exact_request()
    assert blocked_by_editor.status == 409
    assert _error_code(blocked_by_editor) == "VAULT_CLIENT_CAPABILITY_REQUIRED"
    _assert_no_commit(api, owner, [operation], batch_id, previous_sequence)
    assert_floor_one()

    editor_v2 = _report(
        editor,
        revision=2,
        schema=2,
        versions=[1, 2],
        max_bytes=1024 * 1024 * 1024,
    )
    upgraded_editor = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=editor["access_token"],
        json_body=editor_v2,
    )
    assert upgraded_editor.status == 200

    committed = submit_exact_request()
    assert committed.status in (200, 201), f"schema-2 push failed: {_error_code(committed)}"
    commit = committed.json()["results"][0]
    assert commit["revision_id"] == operation["header"]["revision_id"]
    assert int(commit["commit_seq"]) == previous_sequence + 1

    # A byte-for-byte request replay returns the original commit and keeps
    # each visible row, object ref, sequence, and receipt singular.
    retry = submit_exact_request()
    assert retry.status in (200, 201)
    assert retry.json()["results"][0]["already_committed"] is True
    assert retry.json()["results"][0]["commit_seq"] == commit["commit_seq"]

    with _db(api) as connection:
        vault_id = owner["vault_id"]
        record_id = operation["header"]["record_id"]
        revision_id = operation["header"]["revision_id"]
        assert connection.execute(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
            (vault_id, record_id),
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND revision_id=?",
            (vault_id, revision_id),
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND revision_id=?",
            (vault_id, revision_id),
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?",
            (vault_id, operation["header"]["op_id"]),
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
            (vault_id, owner["device_id"], batch_id),
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=? AND object_id=?",
            (vault_id, revision_id, object_id),
        ).fetchone()[0] == 1

    assert _last_sequence(api, owner["vault_id"]) == previous_sequence + 1
    vaults_response = api.request("GET", "/api/v1/vaults", token=owner["access_token"])
    assert vaults_response.status == 200
    upgraded_vault = next(
        item
        for item in vaults_response.json()["vaults"]
        if item["vault_id"] == owner["vault_id"]
    )
    assert upgraded_vault["required_record_schema"] == 2
