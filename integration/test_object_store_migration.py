"""Black-box acceptance for the offline encrypted object-store migration CLI.

The source runs in a private filesystem root and the destination is the shared
strict-loopback S3 fixture. The migration process always runs with the same
unprivileged UID as the isolated service stack.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

import pytest

from object_store_s3_client import LoopbackS3Process
from test_object_references import _change_events, _operation, _push
from test_object_store_filesystem import (
    _db,
    _make_stack,
    _private_dir,
    _physical_path,
    _register_account,
    _run_service_cli,
    _start,
    _stop,
    _upload,
)


S3_BUCKET = "atermius-migration-fixture"
S3_PREFIX = "integration-object-migration"
ADMIN_USERNAME = "atermius-migration-integration-admin@example.test"


def _target_env(stack: dict[str, Any], fixture: LoopbackS3Process) -> dict[str, str]:
    """Add isolated migration-target S3 settings without changing the source."""
    credential_file = stack["base"] / "migration-target-credentials.json"
    credential_file.write_text(
        json.dumps(
            {
                "access_key_id": fixture.access_key_id,
                "secret_access_key": fixture.secret_access_key,
                "session_token": None,
            },
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
    os.chmod(credential_file, 0o600)
    if os.name == "posix" and os.geteuid() == 0:
        os.chown(credential_file, stack["uid"], stack["gid"])
    metadata = credential_file.stat()
    assert metadata.st_mode & 0o777 == 0o600
    assert metadata.st_uid == stack["uid"]

    env = stack["env"].copy()
    assert not any(key.startswith(("AWS_", "AMAZON_")) for key in env)
    env.update(
        {
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND": "s3",
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_BUCKET": S3_BUCKET,
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_REGION": fixture.region,
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_CREDENTIALS_FILE": str(credential_file),
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_ENDPOINT_URL": fixture.endpoint_url,
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX": S3_PREFIX,
        }
    )
    return env


def _run_migration(
    stack: dict[str, Any], env: dict[str, str], migration_id: str
) -> subprocess.CompletedProcess[str]:
    return _run_service_cli(
        stack,
        "migrate-user-objects",
        "--migration-id",
        migration_id,
        "--server-stopped",
        env=env,
        timeout=180,
    )


def _catalogue_snapshot(stack: dict[str, Any]) -> dict[str, list[tuple[Any, ...]]]:
    """Capture all migration-adjacent rows whose identity must survive/fail closed."""
    with _db(stack) as connection:
        queries = {
            "blobs": """SELECT vault_id,object_id,bytes,size,sha256,created_at,gc_after,
                       storage_backend,storage_key,storage_store_id,storage_state
                       FROM blob_objects ORDER BY vault_id,object_id""",
            "references": """SELECT vault_id,revision_id,object_id
                              FROM object_references ORDER BY vault_id,revision_id,object_id""",
            "uploads": """SELECT upload_id,vault_id,user_id,object_id,state,expected_size,expected_sha256,
                            storage_backend,storage_store_id
                            FROM uploads ORDER BY upload_id""",
            "delete_queue": """SELECT queue_id,storage_backend,storage_key,storage_store_id,
                                  expected_size,expected_sha256,state,attempt_count,
                                  next_attempt_at,last_failure_category,created_at
                                  FROM object_delete_queue ORDER BY queue_id""",
            "jobs": """SELECT migration_id,source_backend,source_store_id,target_backend,
                           target_store_id,state,object_count,reference_count,created_at,updated_at,
                           target_s3_prefix
                           FROM object_store_migration_jobs ORDER BY migration_id""",
            "items": """SELECT migration_id,vault_id,object_id,source_backend,source_key,
                            source_store_id,target_backend,target_key,target_store_id,
                            expected_size,expected_sha256,state,created_at,updated_at
                            FROM object_store_migration_items
                            ORDER BY migration_id,vault_id,object_id""",
        }
        return {
            name: [tuple(row) for row in connection.execute(sql).fetchall()]
            for name, sql in queries.items()
        }


def _source_blob(stack: dict[str, Any], vault_id: str, object_id: str) -> tuple[Any, ...]:
    with _db(stack) as connection:
        row = connection.execute(
            """SELECT bytes,size,sha256,created_at,gc_after,storage_backend,
                      storage_key,storage_store_id,storage_state
               FROM blob_objects WHERE vault_id=? AND object_id=?""",
            (vault_id, object_id),
        ).fetchone()
    assert row is not None
    return tuple(row)


def _insert_legacy_sqlite_object(
    stack: dict[str, Any], vault_id: str, object_id: str, payload: bytes
) -> None:
    """Create the supported SQLite + one-external-store legacy catalogue mix."""
    with _db(stack) as connection:
        connection.execute(
            """INSERT INTO blob_objects(
                   vault_id,object_id,bytes,size,sha256,created_at,gc_after,
                   storage_backend,storage_key,storage_store_id,storage_state
               ) VALUES(?,?,?,?,?,'2026-10-04T00:00:00Z',NULL,'sqlite',NULL,NULL,'available')""",
            (
                vault_id,
                object_id,
                payload,
                len(payload),
                hashlib.sha256(payload).hexdigest(),
            ),
        )


def _resume_diagnostics(
    stack: dict[str, Any], fixture: LoopbackS3Process, migration_id: str
) -> dict[str, Any]:
    """Return redacted journal/store state useful only when resume acceptance fails."""
    with _db(stack) as connection:
        job = connection.execute(
            """SELECT source_backend,source_store_id,target_backend,target_store_id,state,
                      object_count,reference_count,target_s3_prefix FROM object_store_migration_jobs
               WHERE migration_id=?""",
            (migration_id,),
        ).fetchone()
        items = connection.execute(
            """SELECT vault_id,object_id,source_backend,source_key,source_store_id,
                      target_backend,target_key,target_store_id,expected_size,expected_sha256,state
               FROM object_store_migration_items WHERE migration_id=?
               ORDER BY vault_id,object_id""",
            (migration_id,),
        ).fetchall()
        blobs = connection.execute(
            """SELECT vault_id,object_id,length(bytes),size,sha256,storage_backend,
                      storage_key,storage_store_id,storage_state FROM blob_objects
               ORDER BY vault_id,object_id"""
        ).fetchall()
    fixture_state = fixture.snapshot()
    return {
        "job": tuple(job) if job else None,
        "items": [tuple(row) for row in items],
        "blobs": [tuple(row) for row in blobs],
        "s3_stats": fixture_state.get("stats"),
        "s3_objects": fixture_state.get("keys"),
        "s3_requests": [
            (row.get("method"), row.get("key"), row.get("status"))
            for row in fixture_state.get("requests", [])
        ],
    }


def _assert_private_diagnostics(
    result: subprocess.CompletedProcess[str],
    stack: dict[str, Any],
    fixture: LoopbackS3Process,
) -> None:
    combined = result.stdout + "\n" + result.stderr
    for private in (
        str(stack["base"]),
        str(stack["filesystem_root"]),
        fixture.secret_access_key,
        fixture.access_key_id,
    ):
        assert private not in combined, "migration CLI diagnostics exposed private path or S3 credentials"


def _s3_runtime_env(source_env: dict[str, str]) -> dict[str, str]:
    env = source_env.copy()
    env["ATERMIUS_OBJECT_STORE_BACKEND"] = "s3"
    env["ATERMIUS_OBJECT_STORE_S3_BUCKET"] = env[
        "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_BUCKET"
    ]
    env["ATERMIUS_OBJECT_STORE_S3_REGION"] = env[
        "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_REGION"
    ]
    env["ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE"] = env[
        "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_CREDENTIALS_FILE"
    ]
    env["ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL"] = env[
        "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_ENDPOINT_URL"
    ]
    env["ATERMIUS_OBJECT_STORE_S3_PREFIX"] = env[
        "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX"
    ]
    env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
    return env


def _filesystem_target_env(
    stack: dict[str, Any], target_root: Path, *, source_env: dict[str, str] | None = None
) -> dict[str, str]:
    _private_dir(target_root, stack["uid"], stack["gid"])
    env = (source_env or stack["env"]).copy()
    env.update(
        {
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND": "filesystem",
            "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_FILESYSTEM_ROOT": str(target_root),
        }
    )
    return env


def _sqlite_source_env(stack: dict[str, Any]) -> dict[str, str]:
    env = stack["env"].copy()
    env["ATERMIUS_OBJECT_STORE_BACKEND"] = "sqlite"
    env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
    return env


def _sqlite_target_env(source_env: dict[str, str]) -> dict[str, str]:
    env = source_env.copy()
    env["ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND"] = "sqlite"
    env.pop("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_FILESYSTEM_ROOT", None)
    return env


def _sqlite_runtime_env(source_env: dict[str, str]) -> dict[str, str]:
    env = source_env.copy()
    env["ATERMIUS_OBJECT_STORE_BACKEND"] = "sqlite"
    env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
    return env


@pytest.mark.skipif(os.name != "posix", reason="isolated filesystem object store requires POSIX")
def test_filesystem_to_loopback_s3_migration_resumes_and_preserves_signed_sync(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    fixture: LoopbackS3Process | None = None
    migration_env: dict[str, str] | None = None
    migration_id = str(uuid.uuid4())
    try:
        fixture = LoopbackS3Process(bucket=S3_BUCKET, temp_dir=stack["base"])
        migration_env = _target_env(stack, fixture)
        api = _start(stack)
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"migration-owner-{uuid.uuid4().hex[:12]}@example.test",
        )

        payload = bytes((index * 73 + 19) % 256 for index in range(48_731))
        object_id, _, source_key = _upload(api, owner, payload)
        legacy_payload = bytes((index * 29 + 61) % 256 for index in range(13_337))
        legacy_object_id = str(uuid.uuid4())
        _insert_legacy_sqlite_object(
            stack, owner["vault_id"], legacy_object_id, legacy_payload
        )
        signed_operation = _operation(
            instance_response.json(),
            owner,
            object_refs=sorted([object_id, legacy_object_id]),
            include_refs=True,
        )
        pushed = _push(api, instance_response.json(), owner, [signed_operation])
        assert pushed.status in (200, 201)

        vault_id = owner["vault_id"]
        references_before = _catalogue_snapshot(stack)["references"]
        signed_events_before = _change_events(api, owner)
        source_row_before = _source_blob(stack, vault_id, object_id)
        legacy_row_before = _source_blob(stack, vault_id, legacy_object_id)
        source_path = _physical_path(stack, source_key)
        assert source_path.is_file() and source_path.read_bytes() == payload
        digest = hashlib.sha256(payload).hexdigest()
        assert source_row_before[1] == len(payload)
        assert source_row_before[2] == digest
        assert source_row_before[5] == "filesystem"
        assert legacy_row_before[0] == legacy_payload
        assert legacy_row_before[5:] == ("sqlite", None, None, "available")

        # A target PUT failure must leave the source catalogue authoritative.
        # The same durable migration ID then resumes after the one-shot fault.
        # The AWS SDK sends three PUT attempts before reconciling with HEAD.
        # Fail all three so this invocation stops, then the same key can resume.
        fixture.inject_fault("put", "before_commit", count=3)
        _stop(stack)
        first = _run_migration(stack, migration_env, migration_id)
        assert first.returncode != 0, "injected S3 destination failure unexpectedly succeeded"
        _assert_private_diagnostics(first, stack, fixture)
        assert _source_blob(stack, vault_id, object_id) == source_row_before
        assert _source_blob(stack, vault_id, legacy_object_id) == legacy_row_before
        assert _catalogue_snapshot(stack)["references"] == references_before
        assert source_path.read_bytes() == payload

        blocked_start = _run_service_cli(
            stack,
            "serve",
            env=_s3_runtime_env(migration_env),
            timeout=20,
        )
        assert blocked_start.returncode != 0, (
            "normal service startup accepted an incomplete object migration journal"
        )

        # Let the conditional PUT commit, then fail every readback retry. This
        # leaves a durable destination object while its SQLite item remains
        # pending, the key crash window that an idempotent resume must repair.
        with _db(stack) as connection:
            pending_target = connection.execute(
                """SELECT target_key,expected_size,expected_sha256
                   FROM object_store_migration_items
                   WHERE migration_id=? ORDER BY vault_id,object_id LIMIT 1""",
                (migration_id,),
            ).fetchone()
        assert pending_target is not None
        target_key = str(pending_target[0])
        fixture.inject_fault("get", "unavailable", key=target_key, count=3)
        post_put = _run_migration(stack, migration_env, migration_id)
        assert post_put.returncode != 0, "injected destination readback failure unexpectedly succeeded"
        _assert_private_diagnostics(post_put, stack, fixture)
        assert _source_blob(stack, vault_id, object_id) == source_row_before
        assert _source_blob(stack, vault_id, legacy_object_id) == legacy_row_before
        assert _catalogue_snapshot(stack)["references"] == references_before
        durable_target = fixture.object_info(target_key)
        assert durable_target["exists"] is True
        assert durable_target["size"] == pending_target[1]
        assert durable_target["sha256"] == pending_target[2]

        resumed = _run_migration(stack, migration_env, migration_id)
        assert resumed.returncode == 0, (
            "offline object migration did not resume after a destination PUT failure: "
            + (resumed.stdout + "\n" + resumed.stderr)[-2200:]
            + f"; state={_resume_diagnostics(stack, fixture, migration_id)!r}"
        )
        _assert_private_diagnostics(resumed, stack, fixture)
        destination_row = _source_blob(stack, vault_id, object_id)
        assert destination_row[0] == b"", "S3 migration retained ciphertext in SQLite catalogue"
        assert destination_row[1] == len(payload)
        assert destination_row[2] == digest
        assert destination_row[3:5] == source_row_before[3:5], "migration changed object lifecycle timestamps"
        assert destination_row[5] == "s3"
        assert destination_row[6] and destination_row[6] != source_key
        assert destination_row[7] and destination_row[8] == "available"
        legacy_destination = _source_blob(stack, vault_id, legacy_object_id)
        legacy_digest = hashlib.sha256(legacy_payload).hexdigest()
        assert legacy_destination[0] == b""
        assert legacy_destination[1] == len(legacy_payload)
        assert legacy_destination[2] == legacy_digest
        assert legacy_destination[5] == "s3"
        assert fixture.object_info(legacy_destination[6])["body_sha256"] == legacy_digest
        info = fixture.object_info(destination_row[6])
        assert info == {
            "exists": True,
            "size": len(payload),
            "sha256": digest,
            "body_sha256": digest,
        }
        assert _catalogue_snapshot(stack)["jobs"][0][-1] == S3_PREFIX
        assert source_path.is_file() and source_path.read_bytes() == payload, (
            "migration must retain the filesystem source copy for rollback/recovery"
        )
        assert _catalogue_snapshot(stack)["references"] == references_before

        # A completed job with the same ID is a successful no-op even though
        # the active source configuration still names the retained old store.
        rerun = _run_migration(stack, migration_env, migration_id)
        assert rerun.returncode == 0, (
            "completed object migration was not idempotent: "
            + (rerun.stdout + "\n" + rerun.stderr)[-1800:]
        )
        _assert_private_diagnostics(rerun, stack, fixture)
        assert _source_blob(stack, vault_id, object_id) == destination_row
        assert fixture.object_info(destination_row[6])["body_sha256"] == digest

        # Normal serving under the target backend must preserve the signed
        # sync event and still return the exact ciphertext bytes.
        target_env = _s3_runtime_env(migration_env)
        api = _start(stack, env=target_env, label="s3-target-server")
        fetched = api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=owner["access_token"],
        )
        assert fetched.status == 200 and fetched.body == payload
        assert fetched.headers.get("ETag") == f'"sha256-{digest}"'
        assert _change_events(api, owner) == signed_events_before
        refs_after = _catalogue_snapshot(stack)["references"]
        assert refs_after == references_before
        _stop(stack)

        # Model process exit after every item transaction committed but before
        # the final job-state checkpoint. Resume must verify the target rows,
        # skip their completed items and publish the completion marker.
        with _db(stack) as connection:
            connection.execute(
                "UPDATE object_store_migration_jobs SET state='copying' WHERE migration_id=?",
                (migration_id,),
            )
        checkpoint_recovery = _run_migration(stack, migration_env, migration_id)
        assert checkpoint_recovery.returncode == 0, (
            "migration did not recover an all-items-switched pending final checkpoint: "
            + (checkpoint_recovery.stdout + "\n" + checkpoint_recovery.stderr)[-1800:]
        )
        assert _catalogue_snapshot(stack)["references"] == references_before
        complete_state = _catalogue_snapshot(stack)["jobs"][0][5]
        assert complete_state == "complete"
        rerun = _run_migration(stack, migration_env, migration_id)
        assert rerun.returncode == 0, "completed object migration did not remain idempotent"
        assert _catalogue_snapshot(stack)["references"] == references_before

    finally:
        _stop(stack)
        if fixture is not None:
            fixture.close()
        shutil.rmtree(stack["base"], ignore_errors=True)


@pytest.mark.skipif(os.name != "posix", reason="isolated filesystem object store requires POSIX")
def test_migration_preflight_refuses_upload_delete_queue_and_deleting_rows_without_mutation(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    fixture: LoopbackS3Process | None = None
    migration_env: dict[str, str] | None = None
    migration_id = str(uuid.uuid4())
    try:
        fixture = LoopbackS3Process(bucket=S3_BUCKET, temp_dir=stack["base"])
        migration_env = _target_env(stack, fixture)
        api = _start(stack)
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"migration-preflight-{uuid.uuid4().hex[:12]}@example.test",
        )
        payload = b"preflight-ciphertext" * 97
        object_id, _, source_key = _upload(api, owner, payload)
        source_row = _source_blob(stack, owner["vault_id"], object_id)
        source_path = _physical_path(stack, source_key)
        store_id = (stack["filesystem_root"] / ".atermius-store-id").read_text(
            encoding="ascii"
        ).strip()

        # Create each unsafe condition through the isolated test database. The
        # command must refuse before it changes object metadata or writes S3.
        active_object_id = str(uuid.uuid4())
        active = api.request(
            "POST",
            f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": active_object_id,
                "size": 1,
                "sha256": hashlib.sha256(b"x").hexdigest(),
            },
        )
        assert active.status in (200, 201)
        active_id = active.json()["upload_id"]
        _stop(stack)

        fixture_puts_before = fixture.request_count("PUT")
        before = _catalogue_snapshot(stack)
        active_attempt = _run_migration(stack, migration_env, migration_id)
        assert active_attempt.returncode != 0, "migration accepted an active upload"
        _assert_private_diagnostics(active_attempt, stack, fixture)
        assert _catalogue_snapshot(stack) == before
        assert _source_blob(stack, owner["vault_id"], object_id) == source_row
        assert fixture.request_count("PUT") == fixture_puts_before
        assert source_path.read_bytes() == payload

        with _db(stack) as connection:
            connection.execute("DELETE FROM uploads WHERE upload_id=?", (active_id,))
            connection.execute(
                "UPDATE blob_objects SET storage_state='deleting' WHERE vault_id=? AND object_id=?",
                (owner["vault_id"], object_id),
            )
        before_deleting = _catalogue_snapshot(stack)
        deleting_attempt = _run_migration(stack, migration_env, migration_id)
        assert deleting_attempt.returncode != 0, "migration accepted an object in deleting state"
        _assert_private_diagnostics(deleting_attempt, stack, fixture)
        assert _catalogue_snapshot(stack) == before_deleting
        assert fixture.request_count("PUT") == fixture_puts_before

        with _db(stack) as connection:
            connection.execute(
                "UPDATE blob_objects SET storage_state='available' WHERE vault_id=? AND object_id=?",
                (owner["vault_id"], object_id),
            )
            connection.execute(
                """INSERT INTO object_delete_queue(
                       queue_id,storage_backend,storage_key,storage_store_id,expected_size,
                       expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at
                   ) VALUES(?,?,?,?,?,?,'pending',0,?,NULL,?)""",
                (
                    str(uuid.uuid4()),
                    "filesystem",
                    f"atermius/objects/v1/{uuid.uuid4()}/{uuid.uuid4()}/{uuid.uuid4()}/{uuid.uuid4()}",
                    store_id,
                    len(payload),
                    hashlib.sha256(payload).hexdigest(),
                    int(time.time()),
                    "2026-10-04T00:00:00Z",
                ),
            )
        before_queue = _catalogue_snapshot(stack)
        queue_attempt = _run_migration(stack, migration_env, migration_id)
        assert queue_attempt.returncode != 0, "migration accepted a non-empty object delete queue"
        _assert_private_diagnostics(queue_attempt, stack, fixture)
        assert _catalogue_snapshot(stack) == before_queue
        assert fixture.request_count("PUT") == fixture_puts_before
        assert source_path.read_bytes() == payload

        # Removing the queue barrier lets the same job ID complete, proving
        # the failed preflights left no blocking partial journal behind.
        with _db(stack) as connection:
            connection.execute("DELETE FROM object_delete_queue")
        final = _run_migration(stack, migration_env, migration_id)
        assert final.returncode == 0, (
            "migration did not start after all preflight barriers were cleared: "
            + (final.stdout + "\n" + final.stderr)[-2200:]
        )
        final_row = _source_blob(stack, owner["vault_id"], object_id)
        assert final_row[5] == "s3" and final_row[1] == len(payload)
        assert fixture.object_info(final_row[6])["body_sha256"] == hashlib.sha256(payload).hexdigest()
        assert source_path.read_bytes() == payload
    finally:
        _stop(stack)
        if fixture is not None:
            fixture.close()
        shutil.rmtree(stack["base"], ignore_errors=True)


@pytest.mark.skipif(os.name != "posix", reason="isolated filesystem object store requires POSIX")
def test_sqlite_to_private_filesystem_migration_preserves_signed_sync_and_serves_ciphertext(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    migration_id = str(uuid.uuid4())
    target_root = stack["base"] / "migration-target-filesystem"
    source_env = _sqlite_source_env(stack)
    stack["env"] = source_env
    target_env = _filesystem_target_env(stack, target_root, source_env=source_env)
    try:
        api = _start(stack, env=source_env, label="sqlite-source-server")
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"sqlite-migration-owner-{uuid.uuid4().hex[:12]}@example.test",
        )

        payload = bytes((index * 41 + 113) % 256 for index in range(37_219))
        object_id, _, _ = _upload(api, owner, payload)
        signed_operation = _operation(
            instance_response.json(),
            owner,
            object_refs=[object_id],
            include_refs=True,
        )
        pushed = _push(api, instance_response.json(), owner, [signed_operation])
        assert pushed.status in (200, 201)

        vault_id = owner["vault_id"]
        digest = hashlib.sha256(payload).hexdigest()
        references_before = _catalogue_snapshot(stack)["references"]
        signed_events_before = _change_events(api, owner)
        source_row_before = _source_blob(stack, vault_id, object_id)
        assert source_row_before[0] == payload
        assert source_row_before[1] == len(payload)
        assert source_row_before[2] == digest
        assert source_row_before[5:] == ("sqlite", None, None, "available")
        _stop(stack)

        migrated = _run_migration(stack, target_env, migration_id)
        assert migrated.returncode == 0, (
            "SQLite-to-filesystem migration failed: "
            + (migrated.stdout + "\n" + migrated.stderr)[-2200:]
        )
        destination_row = _source_blob(stack, vault_id, object_id)
        assert destination_row[0] == b"", "filesystem migration retained ciphertext in SQLite"
        assert destination_row[1] == len(payload)
        assert destination_row[2] == digest
        assert destination_row[3:5] == source_row_before[3:5]
        assert destination_row[5] == "filesystem"
        assert destination_row[6] and destination_row[7]
        assert destination_row[8] == "available"
        destination_path = target_root.joinpath(*destination_row[6].split("/"))
        assert destination_path.is_file()
        assert destination_path.read_bytes() == payload
        assert hashlib.sha256(destination_path.read_bytes()).hexdigest() == digest
        assert _catalogue_snapshot(stack)["references"] == references_before

        # The same ID resumes as a no-op and leaves both the catalogue identity
        # and immutable destination object unchanged.
        rerun = _run_migration(stack, target_env, migration_id)
        assert rerun.returncode == 0, (
            "completed SQLite-to-filesystem migration was not idempotent: "
            + (rerun.stdout + "\n" + rerun.stderr)[-1800:]
        )
        assert _source_blob(stack, vault_id, object_id) == destination_row
        assert destination_path.read_bytes() == payload

        runtime_env = target_env.copy()
        runtime_env["ATERMIUS_OBJECT_STORE_BACKEND"] = "filesystem"
        runtime_env["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] = str(target_root)
        api = _start(stack, env=runtime_env, label="filesystem-target-server")
        fetched = api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=owner["access_token"],
        )
        assert fetched.status == 200 and fetched.body == payload
        assert fetched.headers.get("ETag") == f'"sha256-{digest}"'
        assert _change_events(api, owner) == signed_events_before
        assert _catalogue_snapshot(stack)["references"] == references_before

    finally:
        _stop(stack)
        shutil.rmtree(stack["base"], ignore_errors=True)


@pytest.mark.skipif(os.name != "posix", reason="isolated filesystem object store requires POSIX")
def test_private_filesystem_to_sqlite_migration_preserves_source_and_serves_ciphertext(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    migration_id = str(uuid.uuid4())
    source_env = stack["env"].copy()
    target_env = _sqlite_target_env(source_env)
    try:
        api = _start(stack, env=source_env, label="filesystem-source-server")
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"filesystem-sqlite-owner-{uuid.uuid4().hex[:12]}@example.test",
        )

        payload = bytes((index * 97 + 7) % 256 for index in range(42_613))
        object_id, _, source_key = _upload(api, owner, payload)
        signed_operation = _operation(
            instance_response.json(),
            owner,
            object_refs=[object_id],
            include_refs=True,
        )
        pushed = _push(api, instance_response.json(), owner, [signed_operation])
        assert pushed.status in (200, 201)

        vault_id = owner["vault_id"]
        digest = hashlib.sha256(payload).hexdigest()
        references_before = _catalogue_snapshot(stack)["references"]
        signed_events_before = _change_events(api, owner)
        source_row_before = _source_blob(stack, vault_id, object_id)
        source_path = _physical_path(stack, source_key)
        assert source_row_before[0] == b""
        assert source_row_before[1] == len(payload)
        assert source_row_before[2] == digest
        assert source_row_before[5] == "filesystem"
        assert source_path.is_file() and source_path.read_bytes() == payload
        _stop(stack)

        migrated = _run_migration(stack, target_env, migration_id)
        assert migrated.returncode == 0, (
            "filesystem-to-SQLite migration failed: "
            + (migrated.stdout + "\n" + migrated.stderr)[-2200:]
        )
        destination_row = _source_blob(stack, vault_id, object_id)
        assert destination_row[0] == payload
        assert destination_row[1] == len(payload)
        assert destination_row[2] == digest
        assert destination_row[3:5] == source_row_before[3:5]
        assert destination_row[5:] == ("sqlite", None, None, "available")
        assert source_path.is_file() and source_path.read_bytes() == payload, (
            "migration must retain the filesystem source copy for rollback/recovery"
        )
        assert _catalogue_snapshot(stack)["references"] == references_before

        rerun = _run_migration(stack, target_env, migration_id)
        assert rerun.returncode == 0, (
            "completed filesystem-to-SQLite migration was not idempotent: "
            + (rerun.stdout + "\n" + rerun.stderr)[-1800:]
        )
        assert _source_blob(stack, vault_id, object_id) == destination_row
        assert source_path.read_bytes() == payload

        api = _start(stack, env=_sqlite_runtime_env(source_env), label="sqlite-target-server")
        fetched = api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=owner["access_token"],
        )
        assert fetched.status == 200 and fetched.body == payload
        assert fetched.headers.get("ETag") == f'"sha256-{digest}"'
        assert _change_events(api, owner) == signed_events_before
        assert _catalogue_snapshot(stack)["references"] == references_before

        # The completed migration journal pins the intended runtime backend
        # even when every object has moved into SQLite and catalogue rows alone
        # no longer reveal that the old filesystem backend must stay disabled.
        _stop(stack)
        stale_backend = _run_service_cli(stack, "serve", env=source_env, timeout=15)
        assert stale_backend.returncode != 0, (
            "server startup accepted the old filesystem backend after a completed "
            "filesystem-to-SQLite migration"
        )
    finally:
        _stop(stack)
        shutil.rmtree(stack["base"], ignore_errors=True)


def test_sqlite_to_loopback_s3_migration_preserves_references_and_serves_ciphertext(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    fixture: LoopbackS3Process | None = None
    migration_id = str(uuid.uuid4())
    source_env = _sqlite_source_env(stack)
    stack["env"] = source_env
    try:
        fixture = LoopbackS3Process(bucket=S3_BUCKET, temp_dir=stack["base"])
        target_env = _target_env(stack, fixture)
        api = _start(stack, env=source_env, label="sqlite-s3-source-server")
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"sqlite-s3-owner-{uuid.uuid4().hex[:12]}@example.test",
        )

        payload = bytes((index * 83 + 31) % 256 for index in range(45_829))
        object_id, _, _ = _upload(api, owner, payload)
        signed_operation = _operation(
            instance_response.json(),
            owner,
            object_refs=[object_id],
            include_refs=True,
        )
        pushed = _push(api, instance_response.json(), owner, [signed_operation])
        assert pushed.status in (200, 201)

        vault_id = owner["vault_id"]
        digest = hashlib.sha256(payload).hexdigest()
        references_before = _catalogue_snapshot(stack)["references"]
        signed_events_before = _change_events(api, owner)
        source_row_before = _source_blob(stack, vault_id, object_id)
        assert source_row_before[0] == payload
        assert source_row_before[1:3] == (len(payload), digest)
        assert source_row_before[5:] == ("sqlite", None, None, "available")
        _stop(stack)

        migrated = _run_migration(stack, target_env, migration_id)
        assert migrated.returncode == 0, (
            "SQLite-to-S3 migration failed: "
            + (migrated.stdout + "\n" + migrated.stderr)[-2200:]
        )
        _assert_private_diagnostics(migrated, stack, fixture)

        destination_row = _source_blob(stack, vault_id, object_id)
        assert destination_row[0] == b""
        assert destination_row[1:5] == source_row_before[1:5]
        assert destination_row[5] == "s3"
        assert destination_row[6].startswith(S3_PREFIX + "/")
        assert destination_row[7]
        assert destination_row[8] == "available"
        assert fixture.object_info(destination_row[6]) == {
            "exists": True,
            "size": len(payload),
            "sha256": digest,
            "body_sha256": digest,
        }
        assert _catalogue_snapshot(stack)["references"] == references_before
        assert _catalogue_snapshot(stack)["jobs"][0][-1] == S3_PREFIX

        rerun = _run_migration(stack, target_env, migration_id)
        assert rerun.returncode == 0, (
            "completed SQLite-to-S3 migration was not idempotent: "
            + (rerun.stdout + "\n" + rerun.stderr)[-1800:]
        )
        assert _source_blob(stack, vault_id, object_id) == destination_row

        target_runtime_env = _s3_runtime_env(target_env)
        api = _start(stack, env=target_runtime_env, label="s3-target-server")
        fetched = api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=owner["access_token"],
        )
        assert fetched.status == 200 and fetched.body == payload
        assert fetched.headers.get("ETag") == f'"sha256-{digest}"'
        assert _change_events(api, owner) == signed_events_before
        assert _catalogue_snapshot(stack)["references"] == references_before
        _stop(stack)

        stale_source = _run_service_cli(stack, "serve", env=source_env, timeout=15)
        assert stale_source.returncode != 0, (
            "server startup accepted the old SQLite backend after a completed "
            "SQLite-to-S3 migration"
        )
    finally:
        _stop(stack)
        if fixture is not None:
            fixture.close()
        shutil.rmtree(stack["base"], ignore_errors=True)


@pytest.mark.skipif(os.name != "posix", reason="isolated filesystem object store requires POSIX")
def test_migration_refuses_live_server_before_creating_target_identity_or_journal(
    tmp_path: Path,
) -> None:
    stack = _make_stack(tmp_path)
    api = None
    migration_id = str(uuid.uuid4())
    target_root = stack["base"] / "migration-target-filesystem"
    _private_dir(target_root, stack["uid"], stack["gid"])
    migration_env = _filesystem_target_env(stack, target_root)
    try:
        api = _start(stack, label="live-source-server")
        _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"live-migration-owner-{uuid.uuid4().hex[:12]}@example.test",
        )
        payload = b"live-server-lock-ciphertext" * 113
        object_id, _, source_key = _upload(api, owner, payload)
        source_row = _source_blob(stack, owner["vault_id"], object_id)
        source_path = _physical_path(stack, source_key)
        before = _catalogue_snapshot(stack)
        assert before["jobs"] == [] and before["items"] == []
        assert list(target_root.iterdir()) == []

        attempt = _run_migration(stack, migration_env, migration_id)
        combined = attempt.stdout + "\n" + attempt.stderr
        assert attempt.returncode != 0, "offline migration succeeded while its source server was live"
        assert str(stack["base"]) not in combined
        assert str(target_root) not in combined
        assert _catalogue_snapshot(stack) == before, "lock refusal created a migration journal"
        assert _source_blob(stack, owner["vault_id"], object_id) == source_row
        assert source_path.is_file() and source_path.read_bytes() == payload
        assert list(target_root.iterdir()) == [], (
            "lock refusal created a destination identity or object before owning the data directory"
        )
        ready = api.request("GET", "/health/ready")
        assert ready.status == 200, "migration lock contention interrupted the live server"
    finally:
        _stop(stack)
        shutil.rmtree(stack["base"], ignore_errors=True)
