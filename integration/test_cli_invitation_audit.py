"""Black-box checks for privacy-safe audit of operator-issued invitations."""

from __future__ import annotations

import hashlib
import re
import sqlite3
import uuid

import pytest

from conftest import ApiClient
from test_acceptance import _issue_account_invitation
from test_account_deletion import _db_path


def test_cli_account_invitation_is_instance_scoped_and_keeps_identifiers_private(
    api: ApiClient,
    account: dict,
    writable_server: None,
) -> None:
    username = f"cli-audit-{uuid.uuid4().hex}@example.test"
    with sqlite3.connect(_db_path(api)) as database:
        before_count = database.execute(
            "SELECT COUNT(*) FROM audit_events "
            "WHERE action='instance.account_invitation_issued'"
        ).fetchone()[0]

    token = _issue_account_invitation(api, username)
    token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()

    with sqlite3.connect(_db_path(api)) as database:
        invitation = database.execute(
            "SELECT invitation_id, token_hash FROM account_invitations "
            "WHERE username=? AND token_hash=?",
            (username, token_hash),
        ).fetchone()
        assert invitation is not None, "CLI invitation was not persisted"
        invitation_id, persisted_token_hash = invitation
        after_count = database.execute(
            "SELECT COUNT(*) FROM audit_events "
            "WHERE action='instance.account_invitation_issued'"
        ).fetchone()[0]
        events = database.execute(
            "SELECT scope_type,scope_id,actor_user_id,actor_device_id,action,"
            "resource_type,resource_id,result,source FROM audit_events "
            "WHERE action='instance.account_invitation_issued' ORDER BY event_id DESC LIMIT 1"
        ).fetchall()

    assert after_count == before_count + 1, "successful CLI issuance must create one scoped audit event"
    assert len(events) == 1, "latest CLI issuance event was not stored"
    (
        scope_type,
        scope_id,
        actor_user_id,
        actor_device_id,
        action,
        resource_type,
        resource_id,
        result,
        source,
    ) = events[0]
    assert scope_type == "instance"
    assert len(scope_id) == 64 and scope_id != account["account_id"]
    assert actor_user_id is None and actor_device_id is None
    assert action == "instance.account_invitation_issued"
    assert resource_type == "account_invitation"
    assert re.fullmatch(r"[0-9a-f]{64}", resource_id) and resource_id != invitation_id
    assert result == "success" and source == "maintenance"

    audit_fields = " ".join(str(value) for value in events[0])
    if any(value in audit_fields for value in (username, token, token_hash, persisted_token_hash)):
        pytest.fail("audit metadata contains invitation-sensitive material")

    # Instance events must not become visible through the account/vault audit
    # feed until an administrator-only reader is implemented.
    page = api.request("GET", "/api/v1/audit?limit=200", token=account["access_token"])
    assert page.status == 200, "account audit query failed"
    visible_events = page.json().get("events", [])
    assert all(
        event.get("action") != action and event.get("resource_id") != resource_id
        for event in visible_events
    ), "instance audit event leaked into an account audit feed"
