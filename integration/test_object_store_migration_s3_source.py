"""Black-box acceptance for S3 as the offline object-migration source."""

from __future__ import annotations

import hashlib
import os
import shutil
import uuid
from pathlib import Path

import pytest

from object_store_s3_client import LoopbackS3Process
from test_object_references import _change_events, _operation, _push
from test_object_store_filesystem import (
    _make_stack,
    _physical_path,
    _register_account,
    _run_service_cli,
    _start,
    _stop,
    _upload,
)
from test_object_store_migration import (
    ADMIN_USERNAME,
    S3_BUCKET,
    S3_PREFIX,
    _assert_private_diagnostics,
    _catalogue_snapshot,
    _filesystem_target_env,
    _run_migration,
    _s3_runtime_env,
    _source_blob,
    _target_env,
)


@pytest.mark.skipif(os.name != "posix", reason="isolated object stores require POSIX")
@pytest.mark.parametrize("destination", ["filesystem", "sqlite", "s3-prefix"])
def test_loopback_s3_source_migrates_to_each_supported_target(
    tmp_path: Path, destination: str
) -> None:
    stack = _make_stack(tmp_path)
    fixture: LoopbackS3Process | None = None
    api = None
    migration_id = str(uuid.uuid4())
    target_root = stack["base"] / "migration-s3-source-target"
    destination_prefix = f"{S3_PREFIX}-migrated-{uuid.UUID(migration_id).hex[:12]}"
    try:
        fixture = LoopbackS3Process(bucket=S3_BUCKET, temp_dir=stack["base"])
        configured = _target_env(stack, fixture)
        source_env = _s3_runtime_env(configured)
        stack["env"] = source_env

        if destination == "filesystem":
            migration_env = _filesystem_target_env(
                stack, target_root, source_env=source_env
            )
            for key in tuple(migration_env):
                if key.startswith("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_"):
                    migration_env.pop(key)
        elif destination == "sqlite":
            migration_env = source_env.copy()
            for key in tuple(migration_env):
                if key.startswith("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_"):
                    migration_env.pop(key)
            migration_env["ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND"] = "sqlite"
        else:
            migration_env = source_env.copy()
            migration_env["ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX"] = (
                destination_prefix
            )

        api = _start(stack, env=source_env, label="s3-source-server")
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
            username=f"s3-migration-{destination}-{uuid.uuid4().hex[:12]}@example.test",
        )

        payload = bytes((index * 67 + 23) % 256 for index in range(51_337))
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
        assert source_row_before[0] == b""
        assert source_row_before[1:3] == (len(payload), digest)
        assert source_row_before[5] == "s3"
        assert source_row_before[6].endswith("/" + source_key)
        assert source_row_before[6].startswith(S3_PREFIX + "/")
        source_storage_key = str(source_row_before[6])
        assert fixture.object_info(source_storage_key) == {
            "exists": True,
            "size": len(payload),
            "sha256": digest,
            "body_sha256": digest,
        }
        _stop(stack)

        migrated = _run_migration(stack, migration_env, migration_id)
        assert migrated.returncode == 0, (
            f"S3-to-{destination} migration failed: "
            + (migrated.stdout + "\n" + migrated.stderr)[-2200:]
        )
        _assert_private_diagnostics(migrated, stack, fixture)

        destination_row = _source_blob(stack, vault_id, object_id)
        assert destination_row[1:5] == source_row_before[1:5], (
            "migration changed exact object metadata or lifecycle timestamps"
        )
        assert destination_row[8] == "available"
        assert fixture.object_info(source_storage_key)["body_sha256"] == digest, (
            "migration removed or changed its retained S3 source copy"
        )
        if destination == "filesystem":
            assert destination_row[0] == b""
            assert destination_row[5] == "filesystem"
            assert destination_row[6] and destination_row[7]
            target_path = _physical_path(
                {**stack, "filesystem_root": target_root}, destination_row[6]
            )
            assert target_path.is_file()
            target_bytes = target_path.read_bytes()
            assert hashlib.sha256(target_bytes).hexdigest() == digest
        elif destination == "sqlite":
            assert destination_row[0] == payload
            assert destination_row[5:] == ("sqlite", None, None, "available")
        else:
            assert destination_row[0] == b""
            assert destination_row[5] == "s3"
            assert destination_row[6] != source_storage_key
            assert destination_row[6].startswith(destination_prefix + "/")
            assert destination_row[7] == source_row_before[7], (
                "same-bucket prefix migration should preserve the S3 store identity"
            )
            assert fixture.object_info(destination_row[6]) == {
                "exists": True,
                "size": len(payload),
                "sha256": digest,
                "body_sha256": digest,
            }

        assert _catalogue_snapshot(stack)["references"] == references_before
        expected_journal_prefix = destination_prefix if destination == "s3-prefix" else None
        assert _catalogue_snapshot(stack)["jobs"][0][-1] == expected_journal_prefix
        after_first_run = _catalogue_snapshot(stack)

        rerun = _run_migration(stack, migration_env, migration_id)
        assert rerun.returncode == 0, (
            f"completed S3-to-{destination} migration was not idempotent: "
            + (rerun.stdout + "\n" + rerun.stderr)[-1800:]
        )
        _assert_private_diagnostics(rerun, stack, fixture)
        assert _source_blob(stack, vault_id, object_id) == destination_row
        assert _catalogue_snapshot(stack) == after_first_run

        if destination == "filesystem":
            target_runtime_env = migration_env.copy()
            target_runtime_env["ATERMIUS_OBJECT_STORE_BACKEND"] = "filesystem"
            target_runtime_env["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] = str(target_root)
        elif destination == "sqlite":
            target_runtime_env = migration_env.copy()
            target_runtime_env["ATERMIUS_OBJECT_STORE_BACKEND"] = "sqlite"
            target_runtime_env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
        else:
            target_runtime_env = _s3_runtime_env(migration_env)
        for key in tuple(target_runtime_env):
            if key.startswith("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_"):
                target_runtime_env.pop(key)
            elif key.startswith("ATERMIUS_OBJECT_STORE_S3_") and destination != "s3-prefix":
                target_runtime_env.pop(key)

        api = _start(stack, env=target_runtime_env, label=f"{destination}-target-server")
        fetched = api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=owner["access_token"],
        )
        assert fetched.status == 200 and fetched.body == payload
        assert hashlib.sha256(fetched.body).hexdigest() == digest
        assert fetched.headers.get("ETag") == f'"sha256-{digest}"'
        assert _change_events(api, owner) == signed_events_before
        assert _catalogue_snapshot(stack)["references"] == references_before
        if destination == "s3-prefix":
            # S3 store identity is bucket/endpoint scoped and deliberately omits
            # the prefix, so the completed journal must pin the exact namespace
            # even when a stale prefix points at an otherwise valid same bucket.
            _stop(stack)
            stale_prefix = _run_service_cli(stack, "serve", env=source_env, timeout=15)
            assert stale_prefix.returncode != 0, (
                "server startup accepted the pre-migration S3 prefix after cutover"
            )
    finally:
        _stop(stack)
        if fixture is not None:
            fixture.close()
        shutil.rmtree(stack["base"], ignore_errors=True)
