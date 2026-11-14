"""IT-24: conflict branch upload retries stay idempotent after a lost response."""

from __future__ import annotations

import copy
import hashlib
import json
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from conftest import ApiClient, Response, jcs, b64url


def _error_code(response: Response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _all_conflicts(
    api: ApiClient, account: dict, snapshot_id: str
) -> list[dict]:
    cursor: str | None = None
    rows: list[dict] = []
    for _ in range(500):
        query = {"snapshot_id": snapshot_id, "limit": "500"}
        if cursor:
            query["cursor"] = cursor
        path = (
            f"/api/v1/vaults/{account['vault_id']}/conflicts?"
            f"{urllib.parse.urlencode(query)}"
        )
        response = api.request("GET", path, token=account["access_token"])
        assert response.status == 200, f"conflict history failed: {_error_code(response)}"
        body = response.json()
        rows.extend(body["conflicts"])
        if not body["has_more"]:
            return rows
        cursor = body["next_cursor"]
    raise AssertionError("conflict history exceeded the 500-page guard")


def _request_with_v2_marker(
    api: ApiClient,
    method: str,
    path: str,
    *,
    token: str | None = None,
    json_body: dict | None = None,
    raw_body: bytes | None = None,
    content_type: str | None = None,
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
        headers["X-Atermius-Capability-Marker"] = "v2"
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


def _database_path(api: ApiClient) -> Path:
    if not api.admin_env:
        pytest.skip("conflict rollback side-effect checks require the suite-owned SQLite server")
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        pytest.skip("conflict rollback side-effect checks require SQLite")
    return Path(urllib.parse.unquote(database_url.removeprefix("sqlite://").split("?", 1)[0]))


def _conflict_upload_side_effects(
    connection: sqlite3.Connection,
    *,
    vault_id: str,
    conflict_op_id: str,
    revision_id: str,
    object_id: str,
) -> tuple[int, int, int, int | None, int]:
    counter = connection.execute(
        "SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?",
        (vault_id,),
    ).fetchone()
    assert counter is not None
    conflict_count = connection.execute(
        "SELECT COUNT(*) FROM conflicts WHERE vault_id=? AND op_id=?",
        (vault_id, conflict_op_id),
    ).fetchone()[0]
    object_ref_count = connection.execute(
        "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=? AND object_id=?",
        (vault_id, revision_id, object_id),
    ).fetchone()[0]
    blob = connection.execute(
        "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
        (vault_id, object_id),
    ).fetchone()
    assert blob is not None
    required_schema = connection.execute(
        "SELECT required_record_schema FROM vaults WHERE vault_id=?",
        (vault_id,),
    ).fetchone()
    assert required_schema is not None
    return (
        int(counter[0]),
        int(conflict_count),
        int(object_ref_count),
        blob[0],
        int(required_schema[0]),
    )


def test_conflict_upload_failure_rolls_back_sequence_references_gc_and_schema(
    api: ApiClient,
    account: dict,
    make_envelope,
    push,
) -> None:
    """A conflict insert failure rolls back all earlier transaction writes."""
    database_path = _database_path(api)

    # Schema 2 is needed to exercise its transactional vault capability upgrade.
    # The module's disposable account starts at schema 1 and has one active device.
    def marked_request(method: str, path: str, **kwargs) -> Response:
        return _request_with_v2_marker(api, method, path, **kwargs)

    api.request = marked_request  # type: ignore[method-assign]
    report = {
        "account_id": account["account_id"],
        "device_id": account["device_id"],
        "revision": 1,
        "max_record_schema": 2,
        "host_attachment_manifest_versions": [1, 2],
        "max_attachment_bytes": 1024 * 1024 * 1024,
    }
    report["signature"] = b64url(account["signing_key"].sign(jcs(report)))
    capability = api.request(
        "PUT",
        "/api/v1/devices/capabilities",
        token=account["access_token"],
        json_body=report,
    )
    assert capability.status == 200, f"v2 capability report failed: {_error_code(capability)}"

    record_id = str(uuid.uuid4())
    main = push(make_envelope(record_id=record_id, operation="create"))
    assert main.status in (200, 201), f"base record push failed: {_error_code(main)}"
    base_revision = main.json()["results"][0]["revision_id"]

    opaque = b"conflict-branch-object"
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/uploads/init",
        token=account["access_token"],
        json_body={
            "object_id": object_id,
            "size": len(opaque),
            "sha256": hashlib.sha256(opaque).hexdigest(),
        },
    )
    assert initialized.status in (200, 201), f"object init failed: {_error_code(initialized)}"
    upload_id = initialized.json()["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=account["access_token"],
        raw_body=opaque,
        content_type="application/octet-stream",
    )
    assert chunk.status in (200, 201), f"object chunk upload failed: {_error_code(chunk)}"
    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=account["access_token"],
        json_body={},
    )
    assert completed.status in (200, 201), f"object completion failed: {_error_code(completed)}"

    branch = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=base_revision,
    )
    branch["header"]["record_schema"] = 2
    branch["header"]["object_refs"] = [object_id]
    signed = {
        "header": branch["header"],
        "nonce": branch["nonce"],
        "ciphertext": branch["ciphertext"],
    }
    branch["signature"] = b64url(account["signing_key"].sign(jcs(signed)))
    branch_path = f"/api/v1/vaults/{account['vault_id']}/conflicts"
    branch_op_id = branch["header"]["op_id"]
    revision_id = branch["header"]["revision_id"]

    with sqlite3.connect(database_path, timeout=5) as connection:
        initial_schema = connection.execute(
            "SELECT required_record_schema FROM vaults WHERE vault_id=?",
            (account["vault_id"],),
        ).fetchone()[0]
        assert initial_schema == 1, "test requires an unupgraded disposable Vault"
        gc_after_before = connection.execute(
            "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
            (account["vault_id"], object_id),
        ).fetchone()[0]
        assert gc_after_before is not None
        before = _conflict_upload_side_effects(
            connection,
            vault_id=account["vault_id"],
            conflict_op_id=branch_op_id,
            revision_id=revision_id,
            object_id=object_id,
        )
        connection.executescript(
            "CREATE TRIGGER reject_conflict_upload_for_atomicity "
            "BEFORE INSERT ON conflicts "
            f"WHEN NEW.vault_id='{account['vault_id']}' "
            f"AND NEW.op_id='{branch_op_id}' "
            "BEGIN SELECT RAISE(ABORT,'synthetic conflict insert failure'); END;"
        )

    try:
        failed = api.request(
            "POST",
            branch_path,
            token=account["access_token"],
            json_body={"envelope": branch},
        )
    finally:
        with sqlite3.connect(database_path, timeout=5) as connection:
            connection.execute("DROP TRIGGER IF EXISTS reject_conflict_upload_for_atomicity")
            connection.commit()

    assert failed.status == 500 and _error_code(failed) == "INTERNAL", (
        f"triggered conflict insertion failure returned HTTP {failed.status}: {_error_code(failed)}"
    )
    assert b"synthetic conflict insert failure" not in failed.body
    with sqlite3.connect(database_path, timeout=5) as connection:
        after = _conflict_upload_side_effects(
            connection,
            vault_id=account["vault_id"],
            conflict_op_id=branch_op_id,
            revision_id=revision_id,
            object_id=object_id,
        )
    assert after == before, (
        "conflict sequence, conflict row, object reference, blob gc_after, and "
        "required_record_schema must all roll back together"
    )

    # Removing the trigger and replaying the exact signed request proves the
    # failed attempt left no idempotency row and that the tested writes occur.
    retry = api.request(
        "POST",
        branch_path,
        token=account["access_token"],
        json_body={"envelope": branch},
    )
    assert retry.status in (200, 201), f"conflict retry failed: {_error_code(retry)}"
    with sqlite3.connect(database_path, timeout=5) as connection:
        after_retry = _conflict_upload_side_effects(
            connection,
            vault_id=account["vault_id"],
            conflict_op_id=branch_op_id,
            revision_id=revision_id,
            object_id=object_id,
        )
    assert after_retry == (before[0] + 1, 1, 1, None, 2)


def test_conflict_upload_retry_returns_original_branch_and_rejects_changed_content(
    api: ApiClient,
    account: dict,
    make_envelope,
    push,
) -> None:
    record_id = str(uuid.uuid4())
    created = push(make_envelope(record_id=record_id, operation="create"))
    assert created.status in (200, 201)
    base_revision = created.json()["results"][0]["revision_id"]

    branch = make_envelope(
        record_id=record_id,
        operation="update",
        base_revision_id=base_revision,
    )
    branch_op_id = branch["header"]["op_id"]
    branch_path = f"/api/v1/vaults/{account['vault_id']}/conflicts"

    def upload(envelope: dict) -> Response:
        return api.request(
            "POST",
            branch_path,
            token=account["access_token"],
            json_body={"envelope": envelope},
        )

    first = upload(branch)
    assert first.status in (200, 201), f"first branch upload failed: {_error_code(first)}"
    original_conflict_id = first.json()["conflict_id"]

    # This is the request a client sends after the server committed a branch
    # but its upload receipt was lost. It has the same signed envelope bytes.
    retry = upload(branch)
    assert retry.status in (200, 201), f"branch retry failed: {_error_code(retry)}"
    assert retry.json()["conflict_id"] == original_conflict_id

    snapshot = api.request(
        "POST",
        f"/api/v1/vaults/{account['vault_id']}/snapshots",
        token=account["access_token"],
    )
    assert snapshot.status in (200, 201)
    rows = _all_conflicts(api, account, snapshot.json()["snapshot_id"])
    matching = [
        row
        for row in rows
        if row["envelope"]["header"]["op_id"] == branch_op_id
    ]
    assert [row["conflict_id"] for row in matching] == [original_conflict_id]

    # Reusing an idempotency identity for altered signed content must fail
    # without adding a second history branch.
    changed = copy.deepcopy(branch)
    changed["ciphertext"] = b64url(b"different signed ciphertext payload")
    signed = {
        "header": changed["header"],
        "nonce": changed["nonce"],
        "ciphertext": changed["ciphertext"],
    }
    changed["signature"] = b64url(account["signing_key"].sign(jcs(signed)))
    rejected = upload(changed)
    assert rejected.status == 409, f"changed retry returned {rejected.status}"
    assert _error_code(rejected) == "IDEMPOTENCY_KEY_REUSED"

    rows_after_rejection = _all_conflicts(api, account, snapshot.json()["snapshot_id"])
    matching_after_rejection = [
        row
        for row in rows_after_rejection
        if row["envelope"]["header"]["op_id"] == branch_op_id
    ]
    assert [row["conflict_id"] for row in matching_after_rejection] == [
        original_conflict_id
    ]
