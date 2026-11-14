"""Black-box checks for the scoped, paged audit metadata API."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import urllib.parse
import uuid
from pathlib import Path

import pytest

from conftest import ApiClient, b64url, initial_vault, jcs
from test_account_deletion import (
    _admin_cli,
    _db_path,
    _enroll_device,
    _key_envelope,
    _login,
    _member,
    _membership,
    _membership_digest,
    _register_account,
)


EVENT_KEYS = {
    "event_id",
    "scope",
    "vault_id",
    "actor_user_id",
    "actor_device_id",
    "action",
    "resource_type",
    "resource_id",
    "result",
    "occurred_at",
    "source",
}


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _audit_page(api: ApiClient, token: str, *, cursor: str | None = None, limit: int | None = None):
    query: dict[str, str] = {}
    if cursor is not None:
        query["cursor"] = cursor
    if limit is not None:
        query["limit"] = str(limit)
    path = "/api/v1/audit"
    if query:
        path += "?" + urllib.parse.urlencode(query)
    return api.request("GET", path, token=token)


def _read_all_audit(api: ApiClient, token: str) -> list[dict]:
    response = _audit_page(api, token)
    assert response.status == 200, f"audit endpoint returned HTTP {response.status}: {_error_code(response)}"
    body = response.json()
    events = list(body["events"])
    cursor = body["next_cursor"]
    page_count = 1
    while cursor is not None:
        response = _audit_page(api, token, cursor=cursor, limit=200)
        assert response.status == 200, f"audit cursor returned HTTP {response.status}: {_error_code(response)}"
        body = response.json()
        events.extend(body["events"])
        cursor = body["next_cursor"]
        page_count += 1
        assert page_count <= 100, "audit pagination did not terminate"
    event_ids = [int(event["event_id"]) for event in events]
    assert event_ids == sorted(set(event_ids)), "audit traversal duplicated or reordered events"
    return events


def _signed_sync_create(
    owner: dict,
    instance: dict,
    vault_id: str,
    *,
    membership_version: int,
) -> dict:
    owner["device_seq"] += 1
    unsigned = {
        "header": {
            "wire_version": 1,
            "server_space_id": instance["server_space_id"],
            "vault_id": vault_id,
            "record_id": str(uuid.uuid4()),
            "revision_id": str(uuid.uuid4()),
            "base_revision_id": None,
            "op_id": str(uuid.uuid4()),
            "device_id": owner["device_id"],
            "device_seq": str(owner["device_seq"]),
            "key_epoch": "1",
            "membership_version": str(membership_version),
            "record_schema": 1,
            "operation": "create",
            "crypto_suite": "atermius-vault-v1",
            "kdf_salt": b64url(os.urandom(32)),
        },
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(64)),
    }
    return {**unsigned, "signature": b64url(owner["signing_key"].sign(jcs(unsigned)))}


def _sync_push_body(
    api: ApiClient,
    owner: dict,
    vault_id: str,
    operations: list[dict],
) -> dict:
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200, "sync audit fixture could not read the live server generation"
    current = live_instance.json()
    return {
        "protocol_version": current.get("protocol_version", 1),
        "server_generation": str(current["generation"]),
        "vault_id": vault_id,
        "device_id": owner["device_id"],
        "batch_id": str(uuid.uuid4()),
        "operations": operations,
    }


def _create_and_invite(api: ApiClient, owner: dict, member: dict, role: str) -> tuple[str, dict]:
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
    assert created.status in (200, 201), f"audit fixture vault create failed: {_error_code(created)}"
    signed_membership = _membership(
        vault_id,
        2,
        _membership_digest(vault_id, initial["membership"]),
        [_member(owner, "owner"), _member(member, role)],
        owner,
    )
    invitation = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": role,
            "recipient_device_id": member["device_id"],
            "recipient_encryption_public_key": member["encryption_public_key"],
            "key_envelope": _key_envelope(vault_id, member, 2, owner),
            "membership": signed_membership,
        },
    )
    assert invitation.status in (200, 201), f"audit fixture invitation failed: {_error_code(invitation)}"
    accepted = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=member["access_token"],
        json_body={"token": invitation.json()["token"]},
    )
    assert accepted.status in (200, 201), f"audit fixture invite acceptance failed: {_error_code(accepted)}"
    return vault_id, signed_membership


def test_audit_scope_pagination_and_purge_anonymization(
    api: ApiClient,
    account: dict,
    instance: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """IT-26: scope authorization, fixed cursors, and purge privacy stay intact."""
    unauthenticated = api.request("GET", "/api/v1/audit")
    assert unauthenticated.status == 401
    assert _error_code(unauthenticated) == "AUTH_REQUIRED"

    # Use the bootstrap Owner for the audit scope assertions. The shared
    # disposable server's accumulated Login budget is reset immediately before
    # the independent sibling-device login below.
    owner = account

    editor = _register_account(
        api,
        f"audit-editor-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "audit-editor",
    )
    viewer = _register_account(
        api,
        f"audit-viewer-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "audit-viewer",
    )
    nonmember = _register_account(
        api,
        f"audit-nonmember-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "audit-nonmember",
    )
    shared_vault_id, editor_membership = _create_and_invite(api, owner, editor, "editor")

    # Add a viewer as a second recipient with the next signed membership version.
    # The viewer grant keeps the editor grant active in the signed manifest.
    next_membership = _membership(
        shared_vault_id,
        3,
        _membership_digest(shared_vault_id, editor_membership),
        [
            _member(owner, "owner"),
            _member(editor, "editor"),
            _member(viewer, "viewer"),
        ],
        owner,
    )
    invite_viewer = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/invitations",
        token=owner["access_token"],
        json_body={
            "role": "viewer",
            "recipient_device_id": viewer["device_id"],
            "recipient_encryption_public_key": viewer["encryption_public_key"],
            "key_envelope": _key_envelope(shared_vault_id, viewer, 3, owner),
            "membership": next_membership,
        },
    )
    assert invite_viewer.status in (200, 201), f"audit viewer invite failed: {_error_code(invite_viewer)}"
    viewer_accept = api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=viewer["access_token"],
        json_body={"token": invite_viewer.json()["token"]},
    )
    assert viewer_accept.status in (200, 201), f"audit viewer acceptance failed: {_error_code(viewer_accept)}"

    sibling_device = _enroll_device(api, owner, tmp_path, "audit-sibling")
    if api.admin_env:
        with sqlite3.connect(_db_path(api)) as connection:
            connection.execute("DELETE FROM auth_rate_limits WHERE endpoint='login'")
            connection.commit()
    sibling_session = _login(api, owner, sibling_device["device_id"])

    # Emit sync audit rows through the real push handler. A committed batch
    # gets one opaque Vault event; retries and failed transactions do not.
    sync_operation = _signed_sync_create(
        owner, instance, shared_vault_id, membership_version=3
    )
    sync_body = _sync_push_body(api, owner, shared_vault_id, [sync_operation])
    sync_response = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=sync_body,
    )
    assert sync_response.status == 200, "real sync push for audit event failed"
    assert sync_response.json()["results"][0]["already_committed"] is False

    exact_retry = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=sync_body,
    )
    assert exact_retry.status == 200
    assert exact_retry.json()["results"][0]["already_committed"] is True

    operation_retry_body = {**sync_body, "batch_id": str(uuid.uuid4())}
    operation_retry = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=operation_retry_body,
    )
    assert operation_retry.status == 200
    assert operation_retry.json()["results"][0]["already_committed"] is True

    second_operation = _signed_sync_create(
        owner, instance, shared_vault_id, membership_version=3
    )
    mixed_body = _sync_push_body(
        api, owner, shared_vault_id, [sync_operation, second_operation]
    )
    mixed_response = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=mixed_body,
    )
    assert mixed_response.status == 200
    assert [result["already_committed"] for result in mixed_response.json()["results"]] == [
        True,
        False,
    ], "mixed batch should distinguish existing and newly committed operations"

    failed_first = _signed_sync_create(
        owner, instance, shared_vault_id, membership_version=3
    )
    stale_second = _signed_sync_create(
        owner, instance, shared_vault_id, membership_version=2
    )
    failed_body = _sync_push_body(
        api, owner, shared_vault_id, [failed_first, stale_second]
    )
    failed_push = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=failed_body,
    )
    assert failed_push.status == 409
    assert _error_code(failed_push) == "MEMBERSHIP_VERSION_CONFLICT"
    empty_body = _sync_push_body(api, owner, shared_vault_id, [])
    empty_push = api.request(
        "POST",
        f"/api/v1/vaults/{shared_vault_id}/sync/push",
        token=owner["access_token"],
        json_body=empty_body,
    )
    assert empty_push.status == 400 and _error_code(empty_push) == "INVALID_BATCH"
    with sqlite3.connect(_db_path(api)) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
            (shared_vault_id, failed_first["header"]["record_id"]),
        ).fetchone()[0] == 0, "failed batch partially committed its earlier operation"

    # This opaque, synthetic conflict marker exercises scope authorization
    # independently of the conflict-resolution write path.
    conflict_id = str(uuid.uuid4())
    with sqlite3.connect(_db_path(api)) as connection:
        connection.execute(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,"
            "action,resource_type,resource_id,result,occurred_at,source) "
            "VALUES('vault',?,?,?,'vault.conflict_resolved','conflict',?,'success',"
            "CAST(strftime('%s','now') AS INTEGER),'api')",
            (
                shared_vault_id,
                owner["account_id"],
                owner["device_id"],
                conflict_id,
            ),
        )
        connection.commit()

    owner_events = _read_all_audit(api, owner["access_token"])
    sibling_events = _read_all_audit(api, sibling_session["access_token"])
    editor_events = _read_all_audit(api, editor["access_token"])
    viewer_events = _read_all_audit(api, viewer["access_token"])
    nonmember_events = _read_all_audit(api, nonmember["access_token"])
    assert any(event["scope"] == "account" and event["action"] == "account.created" for event in owner_events)
    assert any(event["scope"] == "account" and event["action"] == "account.created" for event in editor_events)
    sync_batch_events = lambda events: [
        event
        for event in events
        if event["scope"] == "vault"
        and event["vault_id"] == shared_vault_id
        and event["action"] == "vault.sync_batch_committed"
    ]
    for identity, events in (
        ("primary Owner device", owner_events),
        ("separately approved Owner sibling device", sibling_events),
        ("active Editor", editor_events),
    ):
        visible_sync = sync_batch_events(events)
        assert len(visible_sync) == 2, f"{identity} must read one audit row per newly committed batch"
        for event in visible_sync:
            assert set(event) == EVENT_KEYS
            assert event["actor_user_id"] == owner["account_id"]
            assert event["actor_device_id"] == owner["device_id"]
            assert event["resource_type"] == "sync_batch"
            assert event["resource_id"] is None
            assert event["result"] == "success" and event["source"] == "api"
            assert not any(
                forbidden in str(event)
                for forbidden in ("record_id", "op_id", "revision_id", "ciphertext", "operation_count")
            ), "sync batch audit must not expose record or payload metadata"
    assert sync_batch_events(viewer_events) == [], "Viewer must not read Vault sync audit events"
    assert sync_batch_events(nonmember_events) == [], "nonmember must not read Vault sync audit events"
    assert any(
        event["scope"] == "vault" and event["vault_id"] == shared_vault_id
        for event in owner_events
    )
    conflict_event = lambda events: [
        event
        for event in events
        if event["action"] == "vault.conflict_resolved" and event["resource_id"] == conflict_id
    ]
    for identity, events in (
        ("primary Owner device", owner_events),
        ("separately approved Owner sibling device", sibling_events),
        ("active Editor", editor_events),
    ):
        visible_conflict = conflict_event(events)
        assert len(visible_conflict) == 1, f"{identity} must read the Vault conflict audit event"
        assert visible_conflict[0]["scope"] == "vault"
        assert visible_conflict[0]["vault_id"] == shared_vault_id
        assert visible_conflict[0]["resource_type"] == "conflict"
        assert visible_conflict[0]["result"] == "success"
        assert visible_conflict[0]["source"] == "api"
    assert any(
        event["scope"] == "vault" and event["vault_id"] == shared_vault_id
        for event in editor_events
    ), "active Editor must read the vault audit scope"
    assert all(event["vault_id"] != shared_vault_id for event in viewer_events), (
        "Viewer must not receive Owner/Editor vault audit events"
    )
    assert conflict_event(viewer_events) == [], "Viewer must not receive the Vault conflict audit event"
    assert conflict_event(nonmember_events) == [], "nonmember must not receive the Vault conflict audit event"
    audited_identities = owner_events + sibling_events + editor_events + viewer_events + nonmember_events
    assert all(set(event) == EVENT_KEYS for event in audited_identities)
    assert all(event["source"] in {"api", "maintenance"} for event in audited_identities)
    assert all(event["result"] in {"success", "failure"} for event in audited_identities)
    assert all(
        event["result"] == "success"
        or event["action"] in {"auth.login_failed", "auth.refresh_reuse_detected"}
        for event in audited_identities
    ), "audit failures must use a fixed authentication failure action"

    first = _audit_page(api, owner["access_token"], limit=1)
    assert first.status == 200
    first_body = first.json()
    assert len(first_body["events"]) == 1 and first_body["has_more"] is True
    cursor = first_body["next_cursor"]
    assert isinstance(cursor, str) and cursor
    crossed_account_cursor = _audit_page(api, editor["access_token"], cursor=cursor, limit=1)
    assert crossed_account_cursor.status == 400
    assert _error_code(crossed_account_cursor) == "INVALID_AUDIT_CURSOR"
    tampered = _audit_page(api, owner["access_token"], cursor=cursor + "x", limit=1)
    assert tampered.status == 400 and _error_code(tampered) == "INVALID_AUDIT_CURSOR"
    for invalid_limit in (0, 201, "nan"):
        invalid = _audit_page(api, owner["access_token"], limit=invalid_limit)
        assert invalid.status == 400 and _error_code(invalid) == "INVALID_LIMIT"

    # The first page fixes the high-water mark. A later committed vault must
    # appear in a fresh traversal but never in the continuation cursor.
    later_vault = initial_vault(
        account_id=owner["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    late_create = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": later_vault["vault_id"],
            "name_envelope": later_vault["name_envelope"],
            "key_envelope": later_vault["key_envelope"],
            "membership": later_vault["membership"],
        },
    )
    assert late_create.status in (200, 201)
    traversed = list(first_body["events"])
    next_cursor = cursor
    for _ in range(100):
        if next_cursor is None:
            break
        page = _audit_page(api, owner["access_token"], cursor=next_cursor, limit=1)
        assert page.status == 200, f"audit continuation returned HTTP {page.status}: {_error_code(page)}"
        page_body = page.json()
        traversed.extend(page_body["events"])
        next_cursor = page_body["next_cursor"]
    else:
        pytest.fail("audit fixed-watermark traversal did not terminate")
    traversed_ids = [int(event["event_id"]) for event in traversed]
    assert traversed_ids == sorted(set(traversed_ids))
    assert all(
        event["vault_id"] != later_vault["vault_id"]
        and event["resource_id"] != later_vault["vault_id"]
        for event in traversed
    ), "audit cursor included an event committed after its fixed high-water mark"
    assert any(
        event["vault_id"] == later_vault["vault_id"]
        for event in _read_all_audit(api, owner["access_token"])
    ), "fresh audit traversal omitted the post-cursor vault event"

    replay_session = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": editor["username"],
            "login_verifier": editor["login_verifier"],
            "device_id": editor["device_id"],
        },
    )
    assert replay_session.status == 200, "could not create a session for refresh-replay audit"
    replay_tokens = replay_session.json()
    replay_token = replay_tokens["refresh_token"]
    rotation = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": replay_token}
    )
    assert rotation.status == 200, "could not consume refresh token before replay"
    replay_family_id = None
    database = _db_path(api)
    with sqlite3.connect(database) as connection:
        replay_family_id = connection.execute(
            "SELECT family_id FROM refresh_history WHERE refresh_hash=?",
            (hashlib.sha256(replay_token.encode()).hexdigest(),),
        ).fetchone()[0]
    replay = api.request(
        "POST", "/api/v1/auth/refresh", json_body={"refresh_token": replay_token}
    )
    assert replay.status == 401, "replayed refresh credential must retain the AUTH_REQUIRED response"
    replay_event = next(
        event
        for event in _read_all_audit(api, editor["access_token"])
        if event["action"] == "auth.refresh_reuse_detected"
        and event["resource_id"] == replay_family_id
    )
    replay_event_id = replay_event["event_id"]
    assert replay_event["scope"] == "account" and replay_event["vault_id"] is None
    assert replay_event["actor_user_id"] is None
    assert replay_event["actor_device_id"] is None
    assert replay_event["resource_type"] == "session_family"
    assert replay_event["result"] == "failure" and replay_event["source"] == "api"
    assert replay_event["resource_id"] not in {
        editor["account_id"],
        editor["device_id"],
        replay_token,
        rotation.json()["refresh_token"],
    }
    assert editor["username"] not in str(replay_event)

    logout_session = api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": editor["username"],
            "login_verifier": editor["login_verifier"],
            "device_id": editor["device_id"],
        },
    )
    assert logout_session.status == 200, "could not create a second editor session for logout audit"
    logout_tokens = logout_session.json()
    logout_token = logout_tokens["access_token"]
    database = _db_path(api)
    with sqlite3.connect(database) as connection:
        logout_session_id = connection.execute(
            "SELECT session_id FROM sessions WHERE access_hash=?",
            (hashlib.sha256(logout_token.encode()).hexdigest(),),
        ).fetchone()[0]
    logout = api.request("POST", "/api/v1/auth/logout", token=logout_token)
    assert logout.status == 200, "successful logout was rejected"
    logout_event = next(
        event
        for event in _read_all_audit(api, editor["access_token"])
        if event["action"] == "auth.logout_succeeded"
        and event["resource_id"] == logout_session_id
    )
    logout_event_id = logout_event["event_id"]
    assert logout_event["scope"] == "account" and logout_event["vault_id"] is None
    assert logout_event["actor_user_id"] == editor["account_id"]
    assert logout_event["actor_device_id"] == editor["device_id"]
    assert logout_event["resource_type"] == "session"
    assert logout_event["result"] == "success" and logout_event["source"] == "api"
    for private_value in (editor["username"], logout_token, logout_tokens["refresh_token"]):
        assert private_value not in str(logout_event), "logout audit leaked a private value"

    with sqlite3.connect(database) as connection:
        owner_scope = connection.execute(
            "SELECT scope_id FROM audit_events WHERE scope_type='account' AND actor_user_id=? AND action='account.created'",
            (editor["account_id"],),
        ).fetchone()[0]
        assert owner_scope != editor["account_id"] and re.fullmatch(r"[0-9a-f]{64}", owner_scope)
        # Membership-target resources must be anonymized when that account is
        # permanently purged, while the surviving Vault audit event remains.
        recovery_event_id = connection.execute(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,"
            "action,resource_type,resource_id,result,occurred_at,source) "
            "VALUES('account',?,?,?,'auth.account_recovery_enabled','account_recovery',?,'success',"
            "CAST(strftime('%s','now') AS INTEGER),'api')",
            (
                owner_scope,
                editor["account_id"],
                editor["device_id"],
                editor["account_id"],
            ),
        ).lastrowid
        connection.execute(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,"
            "action,resource_type,resource_id,result,occurred_at,source) "
            "VALUES('vault',?,?,?,'vault.member_revoked','membership',?,'success',"
            "CAST(strftime('%s','now') AS INTEGER),'api')",
            (
                shared_vault_id,
                owner["account_id"],
                owner["device_id"],
                editor["account_id"],
            ),
        )
        connection.commit()

    # A non-owner member may delete their account. Purge anonymizes prior actor
    # fields while retaining the public Vault event for its surviving owner.
    deletion = api.request(
        "POST",
        "/api/v1/account/delete",
        token=editor["access_token"],
        json_body={"login_verifier": editor["login_verifier"]},
    )
    assert deletion.status == 200, f"audit member deletion failed: {_error_code(deletion)}"
    with sqlite3.connect(database) as connection:
        request_id = connection.execute(
            "SELECT request_id FROM account_deletion_requests WHERE user_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
            (editor["account_id"],),
        ).fetchone()[0]
        connection.execute(
            "UPDATE account_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-3600,"
            "purge_after=CAST(strftime('%s','now') AS INTEGER)-1 WHERE request_id=?",
            (request_id,),
        )
        connection.commit()
    maintenance = _admin_cli(api, "maintenance")
    assert maintenance.returncode == 0, "audit anonymization maintenance did not complete"

    surviving_events = _read_all_audit(api, owner["access_token"])
    accepted_event = next(
        event
        for event in surviving_events
        if event["scope"] == "vault"
        and event["vault_id"] == shared_vault_id
        and event["action"] == "vault.invitation_accepted"
        and event["actor_device_id"] is None
    )
    assert accepted_event["actor_user_id"] is None, "purge did not anonymize the surviving vault audit actor"
    revoked_event = next(
        event
        for event in surviving_events
        if event["scope"] == "vault"
        and event["vault_id"] == shared_vault_id
        and event["action"] == "vault.member_revoked"
    )
    assert revoked_event["resource_type"] == "membership"
    assert revoked_event["resource_id"] is None, (
        "purge did not anonymize the membership target identifier"
    )
    assert revoked_event["actor_user_id"] == owner["account_id"]
    assert all(event["action"] != "account.purged" for event in surviving_events), (
        "another account's private audit scope leaked to the vault owner"
    )
    with sqlite3.connect(database) as connection:
        private_audit = connection.execute(
            "SELECT actor_user_id,actor_device_id,resource_type,resource_id FROM audit_events "
            "WHERE scope_type='account' AND scope_id=?",
            (owner_scope,),
        ).fetchall()
        assert private_audit and all(row[0] is None and row[1] is None for row in private_audit)
        assert all(row[3] not in {editor["account_id"], editor["device_id"]} for row in private_audit)
        purged_logout = connection.execute(
            "SELECT action,resource_type,resource_id,actor_user_id,actor_device_id "
            "FROM audit_events WHERE event_id=?",
            (int(logout_event_id),),
        ).fetchone()
        assert purged_logout is not None
        assert purged_logout == (
            "auth.logout_succeeded",
            "session",
            None,
            None,
            None,
        ), "account purge must anonymize the session resource ID and actor fields"
        purged_replay = connection.execute(
            "SELECT action,resource_type,resource_id,actor_user_id,actor_device_id "
            "FROM audit_events WHERE event_id=?",
            (int(replay_event_id),),
        ).fetchone()
        assert purged_replay == (
            "auth.refresh_reuse_detected",
            "session_family",
            None,
            None,
            None,
        ), "account purge must anonymize the session-family resource ID and actor fields"
        purged_recovery = connection.execute(
            "SELECT action,resource_type,resource_id,actor_user_id,actor_device_id "
            "FROM audit_events WHERE event_id=?",
            (recovery_event_id,),
        ).fetchone()
        assert purged_recovery == (
            "auth.account_recovery_enabled",
            "account_recovery",
            None,
            None,
            None,
        ), "account purge must anonymize recovery resource IDs and actor fields"
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []

    # Purged vault events must stop being visible even though audit rows are
    # retained for the configured metadata retention period.
    purge_vault = initial_vault(
        account_id=owner["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    purge_create = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": purge_vault["vault_id"],
            "name_envelope": purge_vault["name_envelope"],
            "key_envelope": purge_vault["key_envelope"],
            "membership": purge_vault["membership"],
        },
    )
    assert purge_create.status in (200, 201)
    requested_purge = api.request(
        "DELETE",
        f"/api/v1/vaults/{purge_vault['vault_id']}",
        token=owner["access_token"],
        json_body={"login_verifier": owner["login_verifier"]},
    )
    assert requested_purge.status == 200, f"audit vault deletion failed: {_error_code(requested_purge)}"
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE vault_deletion_requests SET requested_at=CAST(strftime('%s','now') AS INTEGER)-3600,"
            "purge_after=CAST(strftime('%s','now') AS INTEGER)-1 "
            "WHERE vault_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
            (purge_vault["vault_id"],),
        )
        connection.commit()
    vault_maintenance = _admin_cli(api, "maintenance")
    assert vault_maintenance.returncode == 0
    after_vault_purge = _read_all_audit(api, owner["access_token"])
    assert all(event["vault_id"] != purge_vault["vault_id"] for event in after_vault_purge)

    print("IT-26 passed: account/vault scopes, role filtering, fixed cursors and purge anonymization.")
