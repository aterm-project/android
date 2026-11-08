"""Black-box acceptance for instance-admin Vault inventory and quota writes."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import sqlite3
import uuid

import pytest

from test_account_deletion import _db_path, _register_account


MAX_QUOTA_BYTES = 1 << 40


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def test_admin_vault_inventory_and_quota_write_are_scoped_atomic_and_audited(
    api, account, tmp_path, request
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin Vault quota acceptance needs the suite-owned disposable server")

    admin_vault_id = account["vault_id"]
    db_path = _db_path(api)
    outsider = _register_account(
        api,
        f"quota-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "quota-outsider",
    )
    # Use the just-created Vault so earlier integration cases cannot affect
    # the quota floor we expect in this test.
    vault_id = outsider["vault_id"]
    now = datetime.now(timezone.utc)
    created_at = now.isoformat()
    expires_at = (now + timedelta(hours=1)).isoformat()
    object_id = str(uuid.uuid4())
    upload_id = str(uuid.uuid4())

    def cleanup() -> None:
        with sqlite3.connect(db_path) as connection:
            connection.execute("DELETE FROM uploads WHERE upload_id=?", (upload_id,))
            connection.execute(
                "DELETE FROM blob_objects WHERE vault_id=? AND object_id=?",
                (vault_id, object_id),
            )
            connection.execute(
                "UPDATE vaults SET quota_bytes=1073741824,state='active' WHERE vault_id=?",
                (vault_id,),
            )

    request.addfinalizer(cleanup)

    with sqlite3.connect(db_path) as connection:
        connection.execute(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) "
            "VALUES(?,?,?,64,?,?)",
            (vault_id, object_id, bytes(64), "0" * 64, created_at),
        )
        connection.execute(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,"
            "chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,32,?,?, 'open',?,?)",
            (
                upload_id,
                vault_id,
                outsider["account_id"],
                str(uuid.uuid4()),
                "0" * 64,
                65536,
                expires_at,
                created_at,
            ),
        )

    missing = api.request("GET", "/api/v1/admin/vaults")
    assert missing.status == 401
    missing_write = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{admin_vault_id}/quota",
        json_body={"quota_bytes": 128},
    )
    assert missing_write.status == 401

    denied = api.request("GET", "/api/v1/admin/vaults", token=outsider["access_token"])
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"
    denied_write = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=outsider["access_token"],
        json_body={"quota_bytes": 128},
    )
    assert denied_write.status == 403

    page = api.request("GET", "/api/v1/admin/vaults?limit=1&offset=0", token=account["access_token"])
    assert page.status == 200
    page_body = page.json()
    assert set(page_body) == {"vaults", "total", "limit", "offset"}
    assert page_body["limit"] == 1
    assert page_body["offset"] == 0
    assert page_body["total"] >= 2
    assert len(page_body["vaults"]) == 1

    inventory = api.request("GET", "/api/v1/admin/vaults?limit=100", token=account["access_token"])
    assert inventory.status == 200
    listed = next(v for v in inventory.json()["vaults"] if v["vault_id"] == vault_id)
    assert set(listed) == {
        "vault_id",
        "owner_user_id",
        "owner_username",
        "state",
        "stored_bytes",
        "reserved_upload_bytes",
        "quota_bytes",
        "created_at",
    }
    assert listed["stored_bytes"] == 64
    assert listed["reserved_upload_bytes"] == 32
    assert listed["state"] == "active"
    serialized = str(inventory.json()).lower()
    assert "name_envelope" not in serialized
    assert "ciphertext" not in serialized
    assert "access_token" not in serialized

    below_usage = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 95},
    )
    assert below_usage.status == 409
    assert _error_code(below_usage) == "QUOTA_BELOW_USAGE"
    assert below_usage.json()["error"]["details"] == {
        "stored_bytes": 64,
        "reserved_upload_bytes": 32,
        "used_bytes": 96,
        "requested_quota_bytes": 95,
    }

    changed = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 128},
    )
    assert changed.status == 200
    changed_body = changed.json()
    assert set(changed_body) == {
        "vault_id",
        "quota_bytes",
        "stored_bytes",
        "reserved_upload_bytes",
        "updated_at",
    }
    assert changed_body == {
        "vault_id": vault_id,
        "quota_bytes": 128,
        "stored_bytes": 64,
        "reserved_upload_bytes": 32,
        "updated_at": changed_body["updated_at"],
    }
    with sqlite3.connect(db_path) as connection:
        quota = connection.execute(
            "SELECT quota_bytes FROM vaults WHERE vault_id=?", (vault_id,)
        ).fetchone()[0]
        event = connection.execute(
            "SELECT scope_type,actor_user_id,actor_device_id,action,resource_type,resource_id,source "
            "FROM audit_events WHERE action='admin.vault_quota_set' ORDER BY event_id DESC LIMIT 1"
        ).fetchone()
    assert quota == 128
    assert event == (
        "instance",
        account["account_id"],
        account["device_id"],
        "admin.vault_quota_set",
        "vault",
        event[5],
        "api",
    )
    assert event[5] != vault_id
    assert len(event[5]) == 64

    maximum_quota = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": MAX_QUOTA_BYTES},
    )
    assert maximum_quota.status == 200
    reset_quota = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 128},
    )
    assert reset_quota.status == 200

    for quota_bytes in (0, -1, MAX_QUOTA_BYTES + 1):
        invalid_quota = api.request(
            "PUT",
            f"/api/v1/admin/vaults/{vault_id}/quota",
            token=account["access_token"],
            json_body={"quota_bytes": quota_bytes},
        )
        assert invalid_quota.status == 400
        assert _error_code(invalid_quota) == "INVALID_QUOTA"
    invalid_body = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{vault_id}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 256, "unexpected": True},
    )
    assert invalid_body.status == 400

    invalid_id = api.request(
        "PUT",
        "/api/v1/admin/vaults/not-a-vault/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 256},
    )
    assert invalid_id.status == 400
    noncanonical_id = api.request(
        "PUT",
        "/api/v1/admin/vaults/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 256},
    )
    assert noncanonical_id.status == 400
    missing_vault = api.request(
        "PUT",
        f"/api/v1/admin/vaults/{uuid.uuid4()}/quota",
        token=account["access_token"],
        json_body={"quota_bytes": 256},
    )
    assert missing_vault.status == 404

    for query, code in (("limit=0", "INVALID_LIMIT"), ("limit=101", "INVALID_LIMIT"), ("offset=1000001", "INVALID_OFFSET")):
        invalid_page = api.request(
            "GET", f"/api/v1/admin/vaults?{query}", token=account["access_token"]
        )
        assert invalid_page.status == 400
        assert _error_code(invalid_page) == code

    with sqlite3.connect(db_path) as connection:
        connection.execute("UPDATE vaults SET state='deleting' WHERE vault_id=?", (vault_id,))
    try:
        pending = api.request(
            "PUT",
            f"/api/v1/admin/vaults/{vault_id}/quota",
            token=account["access_token"],
            json_body={"quota_bytes": MAX_QUOTA_BYTES},
        )
        assert pending.status == 409
        assert _error_code(pending) == "VAULT_NOT_ACTIVE"
    finally:
        with sqlite3.connect(db_path) as connection:
            connection.execute("UPDATE vaults SET state='active' WHERE vault_id=?", (vault_id,))
