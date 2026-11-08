"""IT-22: signed object references, atomic sync writes, and object GC."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import pytest

from conftest import ROOT, ApiClient, SigningKey, b64url, initial_vault, jcs, server_binary_path


GC_GRACE_SECONDS = 7 * 24 * 60 * 60


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _database_path(api: ApiClient) -> Path:
    if not api.admin_env:
        pytest.skip("IT-22 needs the suite-owned disposable SQLite database")
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        pytest.skip("IT-22 GC timestamp and side-effect checks require SQLite")
    return Path(database_url.removeprefix("sqlite://").split("?", 1)[0])


def _db(api: ApiClient) -> sqlite3.Connection:
    connection = sqlite3.connect(_database_path(api), timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def _scalar(api: ApiClient, sql: str, parameters: tuple[Any, ...] = ()) -> Any:
    with _db(api) as connection:
        row = connection.execute(sql, parameters).fetchone()
        return row[0] if row else None


def _server_cli(api: ApiClient, *args: str) -> subprocess.CompletedProcess[str]:
    if not api.admin_env:
        pytest.skip("IT-22 maintenance tests require a suite-owned server")
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), *args]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            *args,
        ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env.copy(),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _maintenance(api: ApiClient) -> None:
    result = _server_cli(api, "maintenance")
    assert result.returncode == 0, (
        "IT-22 maintenance command failed: "
        + (result.stdout + "\n" + result.stderr)[-2500:]
    )


def _issue_account_invitation(api: ApiClient, username: str) -> str:
    assert api.admin_env
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), "create-account-invite", "--username", username]
    else:
        command = [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            "create-account-invite",
            "--username",
            username,
        ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env.copy(),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode:
        pytest.fail("IT-22 account invitation CLI failed: " + (result.stdout + result.stderr)[-2000:])
    match = re.search(r"(?m)^([A-Za-z0-9_-]{40,})\s*$", result.stdout)
    assert match, "IT-22 account invitation CLI did not print its one-time token"
    return match.group(1)


def _new_owner(api: ApiClient, tmp_path: Path) -> dict[str, Any]:
    username = f"it22-owner-{uuid.uuid4().hex[:12]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    vault_id = str(uuid.uuid4())
    signer = SigningKey(tmp_path, f"it22-owner-{account_id[:8]}")
    signing_public_key = b64url(signer.public_key)
    encryption_public_key = b64url(os.urandom(32))
    login_verifier = b64url(os.urandom(32))
    registration = {
        "account_id": account_id,
        "username": username,
        "instance_invitation_token": _issue_account_invitation(api, username),
        "kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": login_verifier,
        "account_key_envelope": {
            "version": 1,
            "nonce": b64url(os.urandom(24)),
            "ciphertext": b64url(os.urandom(48)),
        },
        "device": {
            "device_id": device_id,
            "name": "IT-22 object reference owner",
            "signing_public_key": signing_public_key,
            "encryption_public_key": encryption_public_key,
            "signature": b64url(
                signer.sign(
                    jcs(
                        {
                            "account_id": account_id,
                            "device_id": device_id,
                            "signing_public_key": signing_public_key,
                            "encryption_public_key": encryption_public_key,
                        }
                    )
                )
            ),
        },
    }
    registration["initial_vault"] = initial_vault(
        account_id=account_id,
        vault_id=vault_id,
        device_id=device_id,
        encryption_public_key=encryption_public_key,
        signer=signer,
    )
    created = api.request("POST", "/api/v1/auth/register", json_body=registration)
    assert created.status in (200, 201), (
        f"IT-22 owner enrollment failed: HTTP {created.status} {_error_code(created)}"
    )
    body = created.json()
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "login_verifier": login_verifier,
        "access_token": body["access_token"],
        "vault_id": vault_id,
        "signing_key": signer,
        "signing_public_key": signing_public_key,
        "device_seq": 0,
    }


def _operation(
    instance: dict[str, Any],
    owner: dict[str, Any],
    *,
    operation: str = "create",
    record_id: str | None = None,
    base_revision_id: str | None = None,
    object_refs: Any = None,
    include_refs: bool = False,
) -> dict[str, Any]:
    owner["device_seq"] += 1
    header: dict[str, Any] = {
        "wire_version": 1,
        "server_space_id": instance["server_space_id"],
        "vault_id": owner["vault_id"],
        "record_id": record_id or str(uuid.uuid4()),
        "revision_id": str(uuid.uuid4()),
        "base_revision_id": base_revision_id,
        "op_id": str(uuid.uuid4()),
        "device_id": owner["device_id"],
        "device_seq": str(owner["device_seq"]),
        "key_epoch": "1",
        "membership_version": "1",
        "record_schema": 1,
        "operation": operation,
        "crypto_suite": "atermius-vault-v1",
        "kdf_salt": b64url(os.urandom(32)),
    }
    if include_refs:
        header["object_refs"] = object_refs
    signed = {
        "header": header,
        "nonce": b64url(os.urandom(24)),
        "ciphertext": b64url(os.urandom(64)),
    }
    return {**signed, "signature": b64url(owner["signing_key"].sign(jcs(signed)))}


def _push(
    api: ApiClient,
    instance: dict[str, Any],
    owner: dict[str, Any],
    operations: list[dict[str, Any]],
    *,
    batch_id: str | None = None,
):
    body = {
        "protocol_version": instance.get("protocol_version", 1),
        "server_generation": str(instance["generation"]),
        "vault_id": owner["vault_id"],
        "device_id": owner["device_id"],
        "batch_id": batch_id or str(uuid.uuid4()),
        "operations": operations,
    }
    response = api.request(
        "POST",
        f"/api/v1/vaults/{owner['vault_id']}/sync/push",
        token=owner["access_token"],
        json_body=body,
    )
    response._request_body = body  # type: ignore[attr-defined]
    return response


def _upload_object(api: ApiClient, vault_id: str, token: str, content: bytes) -> tuple[str, str]:
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=token,
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    assert initialized.status in (200, 201), (
        f"IT-22 upload init failed: HTTP {initialized.status} {_error_code(initialized)}"
    )
    upload_id = initialized.json()["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=token,
        raw_body=content,
        content_type="application/octet-stream",
    )
    assert chunk.status in (200, 201), f"IT-22 chunk upload failed: {_error_code(chunk)}"
    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=token,
        json_body={},
    )
    assert completed.status in (200, 201), f"IT-22 object completion failed: {_error_code(completed)}"
    with _db(api) as connection:
        retained_chunks = connection.execute(
            "SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?", (upload_id,)
        ).fetchone()[0]
    assert retained_chunks == 0, "successful completion must release assembled chunk BLOB rows"
    fetched = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/objects/{object_id}",
        token=token,
    )
    assert fetched.status == 200 and fetched.body == content
    return object_id, upload_id


def _last_sequence(api: ApiClient, vault_id: str) -> int:
    value = _scalar(
        api,
        "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
        (vault_id,),
    )
    assert value is not None
    return int(value)


def _assert_no_commit(
    api: ApiClient,
    owner: dict[str, Any],
    operations: list[dict[str, Any]],
    batch_id: str,
    previous_sequence: int,
) -> None:
    assert _last_sequence(api, owner["vault_id"]) == previous_sequence
    with _db(api) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
            (owner["vault_id"], owner["device_id"], batch_id),
        ).fetchone()[0] == 0
        for operation in operations:
            header = operation["header"]
            assert connection.execute(
                "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
                (owner["vault_id"], header["record_id"]),
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND revision_id=?",
                (owner["vault_id"], header["revision_id"]),
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND revision_id=?",
                (owner["vault_id"], header["revision_id"]),
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?",
                (owner["vault_id"], header["op_id"]),
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND device_id=? AND device_seq=?",
                (owner["vault_id"], owner["device_id"], header["device_seq"]),
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=?",
                (owner["vault_id"], header["revision_id"]),
            ).fetchone()[0] == 0


def _assert_rejected_without_effects(
    api: ApiClient,
    instance: dict[str, Any],
    owner: dict[str, Any],
    operation: dict[str, Any],
    *,
    status: int,
    code: str,
) -> None:
    batch_id = str(uuid.uuid4())
    before = _last_sequence(api, owner["vault_id"])
    response = _push(api, instance, owner, [operation], batch_id=batch_id)
    assert response.status == status and _error_code(response) == code, (
        f"reference validation returned HTTP {response.status} {_error_code(response)}; expected {status} {code}"
    )
    _assert_no_commit(api, owner, [operation], batch_id, before)


def _change_events(api: ApiClient, owner: dict[str, Any]) -> list[dict[str, Any]]:
    response = api.request(
        "GET",
        f"/api/v1/vaults/{owner['vault_id']}/changes?limit=500",
        token=owner["access_token"],
    )
    assert response.status == 200, f"IT-22 pull failed: {_error_code(response)}"
    return response.json().get("events", [])


def _get_object(api: ApiClient, owner: dict[str, Any], object_id: str):
    return api.request(
        "GET",
        f"/api/v1/vaults/{owner['vault_id']}/objects/{object_id}",
        token=owner["access_token"],
    )


def test_signed_object_references_are_atomic_and_gc_is_serialized(
    api: ApiClient,
    account: dict[str, Any],
    tmp_path: Path,
) -> None:
    """IT-22 checks signed refs, no-op failures, cleanup/quota, and the writer race."""
    live = api.request("GET", "/api/v1/instance")
    assert live.status == 200
    instance = live.json()  # IT-19 may have rotated generation earlier in the suite.
    owner = _new_owner(api, tmp_path)
    vault_id = owner["vault_id"]

    # Keep the quota small enough to prove that a collected object's bytes
    # become reservable again, while leaving headroom for one deliberately
    # open upload and one post-GC replacement object.
    with _db(api) as connection:
        connection.execute("UPDATE vaults SET quota_bytes=48 WHERE vault_id=?", (vault_id,))

    base_record = str(uuid.uuid4())
    legacy = _operation(instance, owner, record_id=base_record)
    explicit_empty = _operation(instance, owner, object_refs=[], include_refs=True)
    initial_batch = str(uuid.uuid4())
    initial = _push(api, instance, owner, [legacy, explicit_empty], batch_id=initial_batch)
    assert initial.status in (200, 201), f"legacy no-ref push failed: {_error_code(initial)}"
    legacy_revision = initial.json()["results"][0]["revision_id"]
    empty_revision = initial.json()["results"][1]["revision_id"]

    objects: dict[str, tuple[str, str, bytes]] = {}
    for label in ("a", "b", "c", "d", "e"):
        content = f"object-{label}".encode("ascii")  # exactly eight bytes
        object_id, upload_id = _upload_object(api, vault_id, owner["access_token"], content)
        objects[label] = (object_id, upload_id, content)

    assert _scalar(
        api,
        "SELECT COUNT(*) FROM blob_objects WHERE vault_id=?",
        (vault_id,),
    ) == 5
    now = int(time.time())
    for object_id, _, _ in objects.values():
        deadline = _scalar(
            api,
            "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, object_id),
        )
        assert deadline is not None
        assert now + GC_GRACE_SECONDS - 15 <= int(deadline) <= now + GC_GRACE_SECONDS + 15, (
            "new completed objects must receive the default seven-day GC grace"
        )

    foreign_object, _ = _upload_object(
        api,
        account["vault_id"],
        account["access_token"],
        b"foreign!",
    )
    open_object = str(uuid.uuid4())
    open_init = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": open_object,
            "size": 1,
            "sha256": hashlib.sha256(b"x").hexdigest(),
        },
    )
    assert open_init.status in (200, 201)
    open_upload_id = open_init.json()["upload_id"]
    open_chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{open_upload_id}/chunks/0",
        token=owner["access_token"],
        raw_body=b"x",
        content_type="application/octet-stream",
    )
    assert open_chunk.status in (200, 201)

    # Same-vault but absent, foreign-vault completed, and same-vault incomplete
    # references all use one indistinguishable conflict response and roll back
    # every visible/receipt/sequence side effect.
    missing_object = str(uuid.uuid4())
    for reference in (missing_object, foreign_object, open_object):
        operation = _operation(
            instance,
            owner,
            object_refs=[reference],
            include_refs=True,
        )
        _assert_rejected_without_effects(
            api,
            instance,
            owner,
            operation,
            status=409,
            code="OBJECT_REFERENCE_UNAVAILABLE",
        )

    # The envelope extension itself is authenticated and normalized strictly.
    first_id, _, _ = objects["a"]
    second_id, _, _ = objects["c"]
    for invalid_refs in (
        sorted([first_id, second_id], reverse=True),
        [first_id, first_id],
        ["00000000-0000-4000-8000-00000000000A"],
        [str(uuid.uuid4()) for _ in range(1025)],
    ):
        malformed = _operation(
            instance,
            owner,
            object_refs=invalid_refs,
            include_refs=True,
        )
        _assert_rejected_without_effects(
            api,
            instance,
            owner,
            malformed,
            status=422,
            code="INVALID_ENVELOPE",
        )

    # A failed reference in the second operation must roll back the first
    # otherwise-valid operation and leave no batch or per-operation receipt.
    batch_first = _operation(instance, owner)
    batch_second = _operation(
        instance,
        owner,
        object_refs=[missing_object],
        include_refs=True,
    )
    failed_batch_id = str(uuid.uuid4())
    before_batch = _last_sequence(api, vault_id)
    failed_batch = _push(
        api,
        instance,
        owner,
        [batch_first, batch_second],
        batch_id=failed_batch_id,
    )
    assert failed_batch.status == 409 and _error_code(failed_batch) == "OBJECT_REFERENCE_UNAVAILABLE"
    _assert_no_commit(api, owner, [batch_first, batch_second], failed_batch_id, before_batch)

    # A sweep before any object's deadline is a no-op. Then A, B, and D become
    # due; A is referenced by the main revision, D by the conflict-only
    # branch, B remains unreferenced, and E emulates a legacy NULL deadline.
    _maintenance(api)
    for object_id, _, content in objects.values():
        fetched = _get_object(api, owner, object_id)
        assert fetched.status == 200 and fetched.body == content
    past = int(time.time()) - 1
    with _db(api) as connection:
        for label in ("a", "b", "d"):
            connection.execute(
                "UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id=?",
                (past, vault_id, objects[label][0]),
            )
        connection.execute(
            "UPDATE blob_objects SET gc_after=NULL WHERE vault_id=? AND object_id=?",
            (vault_id, objects["e"][0]),
        )

    ordered_refs = sorted([objects["a"][0], objects["c"][0]])
    assert ordered_refs == [objects[label][0] for label in sorted(("a", "c"), key=lambda label: objects[label][0])]
    update = _operation(
        instance,
        owner,
        operation="update",
        record_id=base_record,
        base_revision_id=legacy_revision,
        object_refs=ordered_refs,
        include_refs=True,
    )
    updated = _push(api, instance, owner, [update])
    assert updated.status in (200, 201), f"same-vault completed refs failed: {_error_code(updated)}"
    update_revision = updated.json()["results"][0]["revision_id"]

    # Both the pull event and the fixed-high-water snapshot manifest carry the
    # exact signed envelope, including the sorted reference extension.
    events = _change_events(api, owner)
    by_revision = {
        event["revision_id"]: event["envelope"]
        for event in events
    }
    assert "object_refs" not in by_revision[legacy_revision]["header"]
    assert by_revision[empty_revision]["header"]["object_refs"] == []
    assert by_revision[update_revision]["header"]["object_refs"] == ordered_refs
    snapshot_created = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/snapshots",
        token=owner["access_token"],
    )
    assert snapshot_created.status in (200, 201)
    snapshot = api.request(
        "GET",
        f"/api/v1/snapshots/{snapshot_created.json()['snapshot_id']}",
        token=owner["access_token"],
    )
    assert snapshot.status == 200
    manifest_entry = next(
        entry for entry in snapshot.json()["manifest"] if entry["record_id"] == base_record
    )
    assert manifest_entry["revision_id"] == update_revision
    assert manifest_entry["envelope"]["header"]["object_refs"] == ordered_refs

    # A non-head branch carries a reference to D, which the main revision does
    # not reference. This proves conflict references alone keep a due object
    # alive across maintenance.
    branch = _operation(
        instance,
        owner,
        operation="update",
        record_id=base_record,
        base_revision_id=legacy_revision,
        object_refs=[objects["d"][0]],
        include_refs=True,
    )
    conflict = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts",
        token=owner["access_token"],
        json_body={"envelope": branch},
    )
    assert conflict.status in (200, 201), f"conflict reference failed: {_error_code(conflict)}"
    branch_revision = branch["header"]["revision_id"]
    with _db(api) as connection:
        main_refs = connection.execute(
            "SELECT object_id FROM object_references WHERE vault_id=? AND revision_id=? ORDER BY object_id",
            (vault_id, update_revision),
        ).fetchall()
        conflict_refs = connection.execute(
            "SELECT object_id FROM object_references WHERE vault_id=? AND revision_id=? ORDER BY object_id",
            (vault_id, branch_revision),
        ).fetchall()
    assert [row[0] for row in main_refs] == ordered_refs
    assert [row[0] for row in conflict_refs] == [objects["d"][0]]
    for label in ("a", "c", "d"):
        assert _scalar(
            api,
            "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, objects[label][0]),
        ) is None, "adding a reference must clear a prior or future GC deadline"

    # There is 40 B of completed object data plus a 1 B open upload under a
    # 48 B quota. An additional 8 B reservation cannot fit until B is swept.
    replacement_object = str(uuid.uuid4())
    blocked_quota = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": replacement_object,
            "size": 8,
            "sha256": hashlib.sha256(b"object-f").hexdigest(),
        },
    )
    assert blocked_quota.status == 507 and _error_code(blocked_quota) == "QUOTA_EXCEEDED"

    _maintenance(api)
    assert _get_object(api, owner, objects["a"][0]).body == objects["a"][2]
    assert _get_object(api, owner, objects["c"][0]).body == objects["c"][2]
    assert _get_object(api, owner, objects["d"][0]).body == objects["d"][2]
    assert _get_object(api, owner, objects["e"][0]).body == objects["e"][2]
    assert _get_object(api, owner, objects["b"][0]).status == 404
    assert _scalar(
        api,
        "SELECT state FROM uploads WHERE upload_id=?",
        (objects["b"][1],),
    ) == "collected"
    collected_complete = api.request(
        "POST",
        f"/api/v1/uploads/{objects['b'][1]}/complete",
        token=owner["access_token"],
        json_body={},
    )
    assert collected_complete.status == 410 and _error_code(collected_complete) == "OBJECT_COLLECTED"
    assert _scalar(
        api,
        "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
        (vault_id, objects["e"][0]),
    ) is None, "legacy completed objects with NULL gc_after must be retained"

    # Freed quota can be reserved and completed. The previously failed init
    # used an immutable object ID but left no upload, so the same ID can retry.
    reinitialized = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": replacement_object,
            "size": 8,
            "sha256": hashlib.sha256(b"object-f").hexdigest(),
        },
    )
    assert reinitialized.status in (200, 201), f"GC did not release quota: {_error_code(reinitialized)}"
    replacement_upload = reinitialized.json()["upload_id"]
    replacement_chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{replacement_upload}/chunks/0",
        token=owner["access_token"],
        raw_body=b"object-f",
        content_type="application/octet-stream",
    )
    assert replacement_chunk.status in (200, 201)
    replacement_complete = api.request(
        "POST",
        f"/api/v1/uploads/{replacement_upload}/complete",
        token=owner["access_token"],
        json_body={},
    )
    assert replacement_complete.status in (200, 201)
    assert _scalar(
        api,
        "SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?",
        (replacement_upload,),
    ) == 0

    # Once collected, a new revision cannot name the old object and still has
    # no head, event, sequence allocation, operation receipt, batch receipt,
    # or object-reference row.
    after_gc_op = _operation(
        instance,
        owner,
        object_refs=[objects["b"][0]],
        include_refs=True,
    )
    _assert_rejected_without_effects(
        api,
        instance,
        owner,
        after_gc_op,
        status=409,
        code="OBJECT_REFERENCE_UNAVAILABLE",
    )

    # Race a genuine signed HTTP push with maintenance against one due object.
    # The only safe outcomes are push-first (reference commits and the object
    # remains) or maintenance-first (object is gone and push commits nothing).
    with _db(api) as connection:
        connection.execute("UPDATE vaults SET quota_bytes=64 WHERE vault_id=?", (vault_id,))
    race_object, _ = _upload_object(
        api,
        vault_id,
        owner["access_token"],
        b"race-obj",
    )
    with _db(api) as connection:
        connection.execute(
            "UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id=?",
            (int(time.time()) - 1, vault_id, race_object),
        )
    race_operation = _operation(
        instance,
        owner,
        object_refs=[race_object],
        include_refs=True,
    )
    race_batch_id = str(uuid.uuid4())
    race_sequence = _last_sequence(api, vault_id)
    barrier = threading.Barrier(3)

    def submit_reference():
        barrier.wait(timeout=15)
        return _push(api, instance, owner, [race_operation], batch_id=race_batch_id)

    def sweep_due_objects():
        barrier.wait(timeout=15)
        return _server_cli(api, "maintenance")

    with ThreadPoolExecutor(max_workers=2) as pool:
        push_future = pool.submit(submit_reference)
        maintenance_future = pool.submit(sweep_due_objects)
        barrier.wait(timeout=15)
        raced_push = push_future.result(timeout=120)
        raced_maintenance = maintenance_future.result(timeout=120)
    assert raced_maintenance.returncode == 0, (
        "concurrent maintenance failed: "
        + (raced_maintenance.stdout + raced_maintenance.stderr)[-2500:]
    )
    race_revision = race_operation["header"]["revision_id"]
    with _db(api) as connection:
        race_ref_count = connection.execute(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=? AND object_id=?",
            (vault_id, race_revision, race_object),
        ).fetchone()[0]
    raced_object = _get_object(api, owner, race_object)
    if raced_push.status in (200, 201):
        assert raced_object.status == 200 and raced_object.body == b"race-obj"
        assert race_ref_count == 1
        assert _scalar(
            api,
            "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, race_object),
        ) is None
    else:
        assert raced_push.status == 409 and _error_code(raced_push) == "OBJECT_REFERENCE_UNAVAILABLE", (
            f"race had unsafe/non-contract result: HTTP {raced_push.status} {_error_code(raced_push)}"
        )
        assert raced_object.status == 404 and race_ref_count == 0
        _assert_no_commit(api, owner, [race_operation], race_batch_id, race_sequence)
