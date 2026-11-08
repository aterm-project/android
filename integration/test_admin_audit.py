"""Black-box acceptance for the instance-admin audit review feed."""

from __future__ import annotations

from datetime import datetime, timezone
import re
import sqlite3
import uuid

import pytest

from test_account_deletion import _db_path, _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _insert_event(
    connection: sqlite3.Connection,
    *,
    scope_type: str,
    scope_id: str,
    action: str,
) -> int:
    cursor = connection.execute(
        "INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) "
        "VALUES(?,?,?,'test_resource','success',?,'api')",
        (scope_type, scope_id, action, int(datetime.now(timezone.utc).timestamp())),
    )
    return int(cursor.lastrowid)


def test_instance_admin_audit_feed_is_scoped_private_and_cursor_stable(
    api, account, tmp_path, request
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin audit acceptance needs the suite-owned disposable server")

    db_path = _db_path(api)
    outsider = _register_account(
        api,
        f"audit-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "audit-outsider",
    )
    marker = f"it_admin_audit_{uuid.uuid4().hex}"
    actions = {
        f"{marker}.instance_a",
        f"{marker}.instance_b",
        f"{marker}.late_instance",
        f"{marker}.account_sentinel",
        f"{marker}.vault_sentinel",
    }

    def cleanup() -> None:
        with sqlite3.connect(db_path) as connection:
            connection.executemany(
                "DELETE FROM audit_events WHERE action=?",
                [(action,) for action in actions],
            )

    request.addfinalizer(cleanup)

    missing = api.request("GET", "/api/v1/admin/audit")
    assert missing.status == 401

    denied = api.request(
        "GET", "/api/v1/admin/audit", token=outsider["access_token"]
    )
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"

    for limit in ("0", "201", "not-a-number"):
        invalid = api.request(
            "GET",
            f"/api/v1/admin/audit?limit={limit}",
            token=account["access_token"],
        )
        assert invalid.status == 400
        assert _error_code(invalid) == "INVALID_LIMIT"

    # A successful production quota write creates the real instance event;
    # same-value writes are audited because the action was still performed.
    with sqlite3.connect(db_path) as connection:
        quota_bytes = connection.execute(
            "SELECT quota_bytes FROM vaults WHERE vault_id=?", (account["vault_id"],)
        ).fetchone()[0]
        _insert_event(
            connection,
            scope_type="instance",
            scope_id="test-instance-scope",
            action=f"{marker}.instance_a",
        )
        _insert_event(
            connection,
            scope_type="instance",
            scope_id="test-instance-scope",
            action=f"{marker}.instance_b",
        )
        _insert_event(
            connection,
            scope_type="account",
            scope_id="test-account-scope",
            action=f"{marker}.account_sentinel",
        )
        _insert_event(
            connection,
            scope_type="vault",
            scope_id=str(uuid.uuid4()),
            action=f"{marker}.vault_sentinel",
        )

    quota_write = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{account['vault_id']}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": quota_bytes},
    )
    assert quota_write.status == 200, _error_code(quota_write)

    first_response = api.request(
        "GET", "/api/v1/admin/audit?limit=1", token=account["access_token"]
    )
    assert first_response.status == 200
    first = first_response.json()
    assert set(first) == {"events", "next_cursor", "has_more"}
    assert first["has_more"] is True
    assert len(first["events"]) == 1
    cursor = first["next_cursor"]
    assert isinstance(cursor, str) and cursor

    tampered = api.request(
        "GET",
        f"/api/v1/admin/audit?limit=1&cursor={cursor}x",
        token=account["access_token"],
    )
    assert tampered.status == 400
    assert _error_code(tampered) == "INVALID_AUDIT_CURSOR"

    # This row is committed after the page's captured high-water mark. The
    # following traversal must keep its original boundary and omit this row.
    with sqlite3.connect(db_path) as connection:
        _insert_event(
            connection,
            scope_type="instance",
            scope_id="test-instance-scope",
            action=f"{marker}.late_instance",
        )

    events = list(first["events"])
    while True:
        page_response = api.request(
            "GET",
            f"/api/v1/admin/audit?limit=1&cursor={cursor}",
            token=account["access_token"],
        )
        assert page_response.status == 200
        page = page_response.json()
        events.extend(page["events"])
        if not page["has_more"]:
            assert page["next_cursor"] is None
            break
        cursor = page["next_cursor"]

    assert all(event["scope"] == "instance" for event in events)
    assert all(
        set(event)
        == {
            "event_id",
            "scope",
            "actor_user_id",
            "actor_device_id",
            "action",
            "resource_type",
            "resource_id",
            "result",
            "occurred_at",
            "source",
        }
        for event in events
    )
    assert all(re.fullmatch(r"[0-9]+", event["event_id"]) for event in events)
    assert all(event["action"] != f"{marker}.late_instance" for event in events)
    assert all(event["action"] != f"{marker}.account_sentinel" for event in events)
    assert all(event["action"] != f"{marker}.vault_sentinel" for event in events)

    quota_events = [
        event
        for event in events
        if event["action"] == "admin.vault_quota_set"
        and event["actor_user_id"] == account["account_id"]
    ]
    assert quota_events
    for event in quota_events:
        assert event["actor_device_id"] == account["device_id"]
        assert event["resource_type"] == "vault"
        assert re.fullmatch(r"[0-9a-f]{64}", event["resource_id"])
        assert event["resource_id"] != account["vault_id"]
        assert event["result"] == "success"
        assert event["source"] == "api"

    response_text = str(events)
    assert account["vault_id"] not in response_text
    assert "account_sentinel" not in response_text
    assert "vault_sentinel" not in response_text
