"""Black-box acceptance for administrator isolated encrypted restore staging."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

from test_account_deletion import _db_path, _register_account
from test_backup_cli import (
    _envelope_digest,
    _free_port,
    _run_cli,
    _server_binary,
    _signed_opaque_record,
    _start_server,
    _stop_server,
    _upload_opaque_object,
)


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _wait_for_job(api, token: str, job_id: str) -> dict:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        page = api.request("GET", "/api/v1/admin/jobs?limit=100", token=token)
        assert page.status == 200
        job = next((item for item in page.json()["jobs"] if item["job_id"] == job_id), None)
        assert job is not None, "accepted restore stage disappeared from the durable jobs page"
        if job["status"] in {"succeeded", "failed", "interrupted"}:
            return job
        time.sleep(0.05)
    pytest.fail("isolated restore job did not reach a terminal state")


def _wait_for_backup(api, token: str, request_id: str) -> dict:
    response = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=token,
        json_body={"request_id": request_id, "action": "backup"},
    )
    assert response.status == 202, f"backup fixture job failed: HTTP {response.status} {_error_code(response)}"
    job = response.json()["job"]
    assert job["action"] == "backup" and job["request_id"] == request_id
    assert job["archive_id"] is None
    terminal = _wait_for_job(api, token, job["job_id"])
    assert terminal["status"] == "succeeded" and terminal["result_code"] == "completed"
    return terminal


def _archive_for(archive_dir: Path, archive_id: str) -> Path:
    matches = [
        item
        for item in archive_dir.glob(f"*{archive_id}*.atb")
        if not item.is_symlink() and item.is_file()
    ]
    assert len(matches) == 1, "successful disposable backup did not have one server archive"
    return matches[0]


def _canonical_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _timestamp(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
        return value.endswith("Z") or "+" in value[19:] or "-" in value[19:]
    except ValueError:
        return False


def _tree_digest(root: Path) -> dict[str, tuple[str, int]]:
    result: dict[str, tuple[str, int]] = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            result[relative] = ("symlink:" + os.readlink(path), path.lstat().st_mode)
        elif path.is_file():
            result[relative] = (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode)
        elif path.is_dir():
            result[relative] = ("directory", path.stat().st_mode)
    return result


def _checkpoint_stopped_source_database(database: Path) -> None:
    # The offline installer deliberately opens the source immutable/read-only.
    # Checkpoint the ready-job row before capturing the source snapshot, just
    # as the operator runbook requires after stopping the service.
    connection = sqlite3.connect(database, timeout=10)
    try:
        checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    finally:
        connection.close()

    assert checkpoint is not None and len(checkpoint) == 3
    busy, log_frames, checkpointed_frames = checkpoint
    assert busy == 0, "offline source WAL checkpoint was busy"
    assert log_frames == checkpointed_frames, "offline source checkpoint left WAL frames uncheckpointed"
    assert log_frames == 0, "TRUNCATE checkpoint did not truncate the source WAL"

    # After a successful closed checkpoint, a regular zero-length WAL and a
    # regular stale SHM are safe to remove, matching the documented operator
    # cleanup and the Rust installer fixture. Never remove a nonempty WAL or
    # any rollback journal.
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = Path(f"{database}{suffix}")
        try:
            metadata = sidecar.lstat()
        except FileNotFoundError:
            continue
        assert stat.S_ISREG(metadata.st_mode), "offline source checkpoint left an unsafe SQLite sidecar"
        if suffix == "-wal":
            assert metadata.st_size == 0, "offline source checkpoint left a nonempty WAL"
        elif suffix == "-journal":
            pytest.fail("offline source checkpoint left a rollback journal")
        sidecar.unlink()

    assert not any(
        os.path.lexists(Path(f"{database}{suffix}"))
        for suffix in ("-wal", "-shm", "-journal")
    ), "offline source checkpoint cleanup left a SQLite sidecar"


def _live_payload_tree_digest(root: Path) -> dict[str, tuple[str, int]]:
    # Admin job/audit processing necessarily writes the live SQLite file. Its
    # business rows are compared separately by _live_business_snapshot; this
    # tree assertion covers persistent keys and any opaque object files beside
    # the database without mistaking SQLite WAL/checkpoint churn for payload
    # mutation.
    excluded = {"atermius.db", "atermius.db-wal", "atermius.db-shm"}
    snapshot = _tree_digest(root)
    return {
        relative: value
        for relative, value in snapshot.items()
        if Path(relative).name not in excluded
    }


def _stable_value(value: object) -> object:
    if isinstance(value, bytes):
        return {"bytes_sha256": hashlib.sha256(value).hexdigest(), "bytes_length": len(value)}
    return value


def _live_business_snapshot(db_path: Path) -> dict[str, list[tuple[object, ...]]]:
    """Capture the live identity, sessions, Vault state and opaque synced data.

    Restore-job and audit rows are deliberately excluded: those are the only
    expected active-database writes caused by accepting and recording the job.
    """
    tables = (
        "instance_meta",
        "users",
        "auth_credentials",
        "devices",
        "sessions",
        "refresh_history",
        "vaults",
        "vault_members",
        "vault_key_envelopes",
        "vault_counters",
        "record_heads",
        "record_versions",
        "change_events",
        "op_receipts",
        "batch_receipts",
        "record_graveyard",
        "snapshots",
        "conflicts",
        "uploads",
        "upload_chunks",
        "blob_objects",
        "object_references",
        "invitations",
        "membership_manifests",
    )
    result: dict[str, list[tuple[object, ...]]] = {}
    with sqlite3.connect(db_path, timeout=10) as connection:
        for table in tables:
            rows = connection.execute(f'SELECT * FROM "{table}"').fetchall()
            stable = [tuple(_stable_value(value) for value in row) for row in rows]
            result[table] = sorted(stable, key=lambda row: repr(row))
    return result


def _catalog(api, token: str, *, limit: int = 100, offset: int = 0) -> dict:
    response = api.request(
        "GET",
        f"/api/v1/admin/restore-sources?limit={limit}&offset={offset}",
        token=token,
    )
    assert response.status == 200, f"restore catalog failed: HTTP {response.status} {_error_code(response)}"
    payload = response.json()
    assert isinstance(payload, dict) and set(payload) == {"sources", "total"}
    assert isinstance(payload["sources"], list) and isinstance(payload["total"], int)
    for item in payload["sources"]:
        assert set(item) == {"archive_id", "created_at", "archive_bytes", "origin", "source"}
        assert _canonical_uuid(item["archive_id"])
        assert _timestamp(item["created_at"])
        assert isinstance(item["archive_bytes"], int) and item["archive_bytes"] > 0
        assert item["origin"] in {"manual", "scheduled"}
        assert item["source"] in {"local", "replica"}
    return payload


def _submit_restore(api, token: str, request_id: str, archive_id: str):
    return api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=token,
        json_body={
            "request_id": request_id,
            "action": "restore",
            "archive_id": archive_id,
            "archive_source": "local",
        },
    )


def _validate_restore_job(job: dict, archive_id: str) -> dict:
    assert set(job) == {
        "job_id", "request_id", "action", "archive_id", "archive_source", "status",
        "requested_at", "started_at", "finished_at", "result_code", "restore_stage_status",
    }
    assert _canonical_uuid(job["job_id"]) and _canonical_uuid(job["request_id"])
    assert job["action"] == "restore" and job["archive_id"] == archive_id
    assert job["archive_source"] == "local"
    assert job["status"] in {"queued", "running", "succeeded", "failed", "interrupted"}
    assert job["restore_stage_status"] in {
        None, "ready", "discarding", "discarded", "unverified",
    }
    if job["status"] == "succeeded":
        assert job["restore_stage_status"] in {
            "ready", "discarding", "discarded", "unverified",
        }
    else:
        assert job["restore_stage_status"] is None

    def valid_time(value: object) -> bool:
        if not isinstance(value, str):
            return False
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
            return True
        except ValueError:
            return False

    assert valid_time(job["requested_at"])
    assert job["started_at"] is None or valid_time(job["started_at"])
    assert job["finished_at"] is None or valid_time(job["finished_at"])
    assert job["result_code"] in {None, "completed", "restore_failed", "interrupted"}
    if job["status"] == "queued":
        assert job["started_at"] is None and job["finished_at"] is None and job["result_code"] is None
    elif job["status"] == "running":
        assert job["started_at"] is not None and job["finished_at"] is None and job["result_code"] is None
    elif job["status"] == "succeeded":
        assert job["started_at"] is not None and job["finished_at"] is not None
        assert job["result_code"] == "completed"
    elif job["status"] == "failed":
        assert job["started_at"] is not None and job["finished_at"] is not None
        assert job["result_code"] == "restore_failed"
    else:
        assert job["finished_at"] is not None and job["result_code"] == "interrupted"
    return job


def _assert_no_private_source_metadata(payload: object, *private_values: str) -> None:
    rendered = json.dumps(payload, sort_keys=True)
    for value in private_values:
        assert value not in rendered, "restore catalog/job API exposed a private path, key, or filename"


def test_admin_restore_stage_lists_only_safe_sources_and_publishes_isolated_copy(
    api, account, tmp_path: Path
) -> None:
    if not api.admin_env or not api.server_env or not api.temp_root:
        pytest.skip("admin restore acceptance needs the suite-owned disposable server")
    if not api.backup_archive_dir or not api.backup_key_file:
        pytest.fail("managed integration server has no private backup configuration")

    archive_dir = Path(api.backup_archive_dir)
    key_file = Path(api.backup_key_file)
    data_dir = Path(api.admin_env["ATERMIUS_DATA_DIR"])
    db_path = _db_path(api)
    key_bytes = key_file.read_bytes()
    private_sentinels = (
        str(data_dir),
        str(archive_dir),
        str(key_file),
        key_bytes.hex(),
        key_bytes.hex().upper(),
        base64.urlsafe_b64encode(key_bytes).decode("ascii"),
    )
    owned_files: set[Path] = set()
    created_archive_ids: set[str] = set()
    stage_root = archive_dir / "restore-staging"
    stage_path: Path | None = None
    installed_data_dir = tmp_path / "restore-stage-installed-data"
    source_stopped = False
    installed_process = None
    installed_log = None
    installed_log_path = tmp_path / "restore-installed-server.log"
    status_file = data_dir / "backup-status.json"
    status_existed_before = os.path.lexists(status_file)
    saved_status = (
        (status_file.read_bytes(), stat.S_IMODE(status_file.stat().st_mode))
        if status_file.is_file() and not status_file.is_symlink()
        else None
    )

    try:
        no_auth_list = api.request("GET", "/api/v1/admin/restore-sources?limit=10&offset=0")
        assert no_auth_list.status == 401
        no_auth_submit = api.request(
            "POST",
            "/api/v1/admin/jobs",
            json_body={
                "request_id": str(uuid.uuid4()),
                "action": "restore",
                "archive_id": str(uuid.uuid4()),
            },
        )
        assert no_auth_submit.status == 401

        outsider = _register_account(
            api,
            f"admin-restore-outsider-{uuid.uuid4().hex[:10]}@example.test",
            tmp_path,
            "admin-restore-outsider",
        )
        member_list = api.request(
            "GET",
            "/api/v1/admin/restore-sources?limit=10&offset=0",
            token=outsider["access_token"],
        )
        assert member_list.status == 403 and _error_code(member_list) == "INSTANCE_ADMIN_REQUIRED"
        member_submit = _submit_restore(api, outsider["access_token"], str(uuid.uuid4()), str(uuid.uuid4()))
        assert member_submit.status == 403 and _error_code(member_submit) == "INSTANCE_ADMIN_REQUIRED"

        # Seed an actual signed opaque Vault revision and referenced object so
        # the staged copy is checked for usable business data, not only schema,
        # account rows, and generation metadata.
        source_instance = api.request("GET", "/api/v1/instance")
        assert source_instance.status == 200
        source_vaults = api.request("GET", "/api/v1/vaults", token=account["access_token"])
        assert source_vaults.status == 200
        source_vault = next(
            item
            for item in source_vaults.json()["vaults"]
            if item["vault_id"] == account["vault_id"]
        )
        opaque_object = bytes(range(256)) * 32 + b"restore-stage-object"
        object_sha256 = hashlib.sha256(opaque_object).hexdigest()
        object_id = _upload_opaque_object(
            api, account["vault_id"], account["access_token"], opaque_object
        )
        record_envelope, record_id, revision_id = _signed_opaque_record(
            instance=source_instance.json(),
            vault_id=account["vault_id"],
            device_id=account["device_id"],
            signer=account["signing_key"],
            object_id=object_id,
            device_seq=str(account["device_seq"] + 1),
            key_epoch=str(source_vault["active_key_epoch"]),
            membership_version=str(source_vault["membership_version"]),
        )
        record_digest = _envelope_digest(record_envelope)
        pushed_record = api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/sync/push",
            token=account["access_token"],
            json_body={
                "protocol_version": source_instance.json().get("protocol_version", 1),
                "server_generation": source_instance.json()["generation"],
                "vault_id": account["vault_id"],
                "device_id": account["device_id"],
                "batch_id": str(uuid.uuid4()),
                "operations": [record_envelope],
            },
        )
        assert pushed_record.status in (200, 201), (
            f"restore fixture record push failed: HTTP {pushed_record.status} "
            f"{_error_code(pushed_record)}"
        )
        assert pushed_record.json()["results"][0]["revision_id"] == revision_id
        account["device_seq"] += 1

        first = _wait_for_backup(api, account["access_token"], str(uuid.uuid4()))
        created_archive_ids.add(first["job_id"])
        archive_a = _archive_for(archive_dir, first["job_id"])
        owned_files.add(archive_a)
        archive_a_hash = hashlib.sha256(archive_a.read_bytes()).hexdigest()

        # A durable success whose archive is a symlink or whose file vanished
        # is not a usable restore source. These mutations affect only this
        # disposable instance's private archive directory.
        second = _wait_for_backup(api, account["access_token"], str(uuid.uuid4()))
        created_archive_ids.add(second["job_id"])
        archive_b = _archive_for(archive_dir, second["job_id"])
        owned_files.add(archive_b)
        symlink_created = False
        if os.name == "posix":
            archive_b.unlink()
            archive_b.symlink_to(archive_a)
            symlink_created = True

        third = _wait_for_backup(api, account["access_token"], str(uuid.uuid4()))
        created_archive_ids.add(third["job_id"])
        archive_c = _archive_for(archive_dir, third["job_id"])
        owned_files.add(archive_c)
        archive_c.unlink()

        # A file can remain owner-only and correctly named after its contents
        # are damaged. It may appear in the metadata catalog, but the restore
        # worker must fail closed before publishing any target.
        fourth = _wait_for_backup(api, account["access_token"], str(uuid.uuid4()))
        created_archive_ids.add(fourth["job_id"])
        archive_d = _archive_for(archive_dir, fourth["job_id"])
        owned_files.add(archive_d)
        damaged = bytearray(archive_d.read_bytes())
        damaged[-1] ^= 0x01
        archive_d.write_bytes(damaged)
        damaged_archive_hash = hashlib.sha256(archive_d.read_bytes()).hexdigest()

        # Produce an actual CLI backup while the suite-owned server is
        # stopped. It is valid ciphertext but has no successful admin job row.
        api.stop_managed_server()
        source_stopped = True
        cli_id = str(uuid.uuid4())
        cli_timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%f")[:19] + "Z"
        cli_archive = archive_dir / f"atermius-backup-{cli_timestamp}-{cli_id}.atb"
        owned_files.add(cli_archive)
        cli_result = _run_cli(
            _server_binary(),
            api.admin_env,
            "backup",
            "--archive",
            str(cli_archive),
            "--key-file",
            str(key_file),
        )
        assert cli_result.returncode == 0, "disposable CLI backup fixture creation failed"
        unmanaged_id = str(uuid.uuid4())
        unmanaged = archive_dir / f"atermius-backup-{cli_timestamp}-{unmanaged_id}.atb"
        owned_files.add(unmanaged)
        unmanaged.write_bytes(b"not an Atermius archive")
        api.start_managed_server()
        source_stopped = False

        sources = _catalog(api, account["access_token"])
        by_id = {item["archive_id"]: item for item in sources["sources"]}
        assert first["job_id"] in by_id
        assert by_id[first["job_id"]]["origin"] == "manual"
        assert by_id[first["job_id"]]["archive_bytes"] == archive_a.stat().st_size
        assert second["job_id"] not in by_id
        assert third["job_id"] not in by_id
        assert fourth["job_id"] in by_id
        assert cli_id not in by_id and unmanaged_id not in by_id
        if symlink_created:
            assert archive_b.is_symlink(), "symlink negative fixture was not retained"
        assert not archive_c.exists(), "missing-archive negative fixture was not removed"
        assert all(item["archive_id"] != first["request_id"] for item in sources["sources"])
        _assert_no_private_source_metadata(
            sources,
            *(private_sentinels + (
                archive_a.name,
                archive_b.name,
                archive_c.name,
                archive_d.name,
                cli_archive.name,
                unmanaged.name,
            )),
        )

        # Pagination is stable and returns a server-computed total.
        first_page = _catalog(api, account["access_token"], limit=1, offset=0)
        tail = _catalog(api, account["access_token"], limit=1, offset=max(0, sources["total"] - 1))
        assert first_page["total"] == tail["total"] == sources["total"]
        assert len(first_page["sources"]) <= 1 and len(tail["sources"]) <= 1

        # Strict decoding must reject operator-selected paths, keys, and
        # restore destinations; clients can select only a catalog ID.
        valid_base = {
            "request_id": str(uuid.uuid4()),
            "action": "restore",
            "archive_id": first["job_id"],
            "archive_source": "local",
        }
        invalid_bodies = [
            {"request_id": str(uuid.uuid4()), "action": "restore"},
            {**valid_base, "path": str(archive_a)},
            {**valid_base, "key_file": str(key_file)},
            {**valid_base, "target_data_dir": str(data_dir / "attacker-target")},
            {"request_id": str(uuid.uuid4()), "action": "restore", "archive_id": "../outside"},
            {"request_id": str(uuid.uuid4()), "action": "restore", "archive_id": str(uuid.uuid4()).upper()},
        ]
        for invalid in invalid_bodies:
            rejected = api.request(
                "POST", "/api/v1/admin/jobs", token=account["access_token"], json_body=invalid
            )
            assert rejected.status == 400, f"unsafe restore job body was not rejected: {_error_code(rejected)}"
            _assert_no_private_source_metadata(rejected.json(), *private_sentinels)

        business_before_bad_archive = _live_business_snapshot(db_path)
        instance_before_bad_archive = api.request("GET", "/api/v1/instance")
        assert instance_before_bad_archive.status == 200
        bad_archive_response = _submit_restore(
            api,
            account["access_token"],
            str(uuid.uuid4()),
            fourth["job_id"],
        )
        assert bad_archive_response.status == 202
        bad_archive_job = bad_archive_response.json()["job"]
        _validate_restore_job(bad_archive_job, fourth["job_id"])
        assert bad_archive_job["action"] == "restore"
        assert bad_archive_job["archive_id"] == fourth["job_id"]
        failed_restore = _wait_for_job(
            api, account["access_token"], bad_archive_job["job_id"]
        )
        _validate_restore_job(failed_restore, fourth["job_id"])
        assert failed_restore["status"] == "failed"
        assert failed_restore["result_code"] == "restore_failed"
        assert not (stage_root / f"atermius-restore-{bad_archive_job['job_id']}").exists()
        assert list(stage_root.iterdir()) == [], "failed restore left a staging path behind"
        assert hashlib.sha256(archive_d.read_bytes()).hexdigest() == damaged_archive_hash
        assert _live_business_snapshot(db_path) == business_before_bad_archive
        current_after_bad_archive = api.request("GET", "/api/v1/instance")
        assert current_after_bad_archive.status == 200
        assert current_after_bad_archive.json()["generation"] == (
            instance_before_bad_archive.json()["generation"]
        )
        assert api.request("GET", "/api/v1/me", token=account["access_token"]).status == 200
        _assert_no_private_source_metadata(
            {"accepted": bad_archive_job, "terminal": failed_restore},
            *(private_sentinels + (archive_d.name,)),
        )

        before_instance = api.request("GET", "/api/v1/instance")
        assert before_instance.status == 200
        live_generation = before_instance.json()["generation"]
        assert api.request("GET", "/api/v1/me", token=account["access_token"]).status == 200
        live_snapshot = _live_business_snapshot(db_path)
        source_tree_before = _live_payload_tree_digest(data_dir)
        source_archive_before = hashlib.sha256(archive_a.read_bytes()).hexdigest()
        assert source_archive_before == archive_a_hash

        request_id = str(uuid.uuid4())
        from concurrent.futures import ThreadPoolExecutor

        with ThreadPoolExecutor(max_workers=3) as executor:
            submissions = list(
                executor.map(
                    lambda _: _submit_restore(
                        api, account["access_token"], request_id, first["job_id"]
                    ),
                    range(3),
                )
            )
        assert all(response.status == 202 for response in submissions)
        accepted = submissions[0].json()["job"]
        if _canonical_uuid(accepted.get("job_id")):
            stage_path = stage_root / f"atermius-restore-{accepted['job_id']}"
        assert all(response.json()["job"]["job_id"] == accepted["job_id"] for response in submissions)
        assert accepted["action"] == "restore"
        assert accepted["request_id"] == request_id
        assert accepted["archive_id"] == first["job_id"]
        assert accepted["status"] in {"queued", "running", "succeeded"}
        assert _canonical_uuid(accepted["job_id"])
        _validate_restore_job(accepted, first["job_id"])

        replay = _submit_restore(api, account["access_token"], request_id, first["job_id"])
        assert replay.status == 202
        replay_job = _validate_restore_job(replay.json()["job"], first["job_id"])
        assert replay_job["job_id"] == accepted["job_id"]
        assert replay_job["request_id"] == request_id
        terminal = _wait_for_job(api, account["access_token"], accepted["job_id"])
        _validate_restore_job(terminal, first["job_id"])
        assert terminal["status"] == "succeeded" and terminal["result_code"] == "completed"
        assert terminal["restore_stage_status"] == "ready"
        assert terminal["action"] == "restore" and terminal["archive_id"] == first["job_id"]
        assert terminal["started_at"] is not None and terminal["finished_at"] is not None

        assert stage_path.is_dir() and not stage_path.is_symlink()
        if os.name == "posix":
            assert stat.S_IMODE(stage_path.stat().st_mode) == 0o700
            assert stat.S_IMODE(stage_root.stat().st_mode) == 0o700
        staged_db = stage_path / "atermius.db"
        assert staged_db.is_file() and not staged_db.is_symlink()
        staged_connection = sqlite3.connect(
            f"file:{staged_db}?mode=ro&immutable=1", uri=True
        )
        try:
            staged_meta = staged_connection.execute(
                "SELECT instance_id,server_space_id,generation FROM instance_meta WHERE id=1"
            ).fetchone()
            active_staged_sessions = staged_connection.execute(
                "SELECT COUNT(*) FROM sessions WHERE revoked_at IS NULL"
            ).fetchone()[0]
            staged_identity = staged_connection.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        finally:
            staged_connection.close()
        assert staged_meta is not None
        assert staged_meta[0] == before_instance.json()["instance_id"]
        assert staged_meta[1] == before_instance.json()["server_space_id"]
        assert staged_meta[2] != live_generation, "isolated copy did not receive a new generation"
        assert active_staged_sessions == 0, "restored copy retained an active pre-restore session"
        assert staged_identity >= 1, "isolated copy lost its archived account data"

        # The online Settings job only publishes an isolated stage. The
        # operator-facing installer requires a cleanly stopped source and a
        # separate, absent target directory; it never mutates or switches the
        # source volume.
        assert hashlib.sha256(archive_a.read_bytes()).hexdigest() == source_archive_before
        live_instance_after = api.request("GET", "/api/v1/instance")
        assert live_instance_after.status == 200
        assert live_instance_after.json()["generation"] == live_generation
        assert api.request("GET", "/api/v1/me", token=account["access_token"]).status == 200
        assert _live_business_snapshot(db_path) == live_snapshot
        assert _live_payload_tree_digest(data_dir) == source_tree_before
        assert hashlib.sha256(archive_a.read_bytes()).hexdigest() == archive_a_hash

        stage_snapshot = _tree_digest(stage_path)
        expected_stage_files = {
            ".atermius-restore-receipt.json",
            "atermius.db",
            "auth-rate-limit.key",
            "instance-ed25519.key",
        }
        assert {path.name for path in stage_path.iterdir()} == expected_stage_files

        source_stopped = True
        api.stop_managed_server()
        source_db = data_dir / "atermius.db"
        _checkpoint_stopped_source_database(source_db)
        source_sidecars = [
            Path(f"{source_db}{suffix}")
            for suffix in ("-wal", "-shm", "-journal")
            if Path(f"{source_db}{suffix}").exists()
        ]
        assert not source_sidecars, "source database did not checkpoint and close before install"
        source_offline_snapshot = _tree_digest(data_dir)
        assert not installed_data_dir.exists() and not installed_data_dir.is_symlink()

        install = _run_cli(
            _server_binary(),
            api.admin_env,
            "install-restore-stage",
            "--restore-job-id",
            accepted["job_id"],
            "--target-data-dir",
            str(installed_data_dir),
            "--server-stopped",
        )
        assert install.returncode == 0, "offline restore-stage installer CLI failed"
        assert "source volume was not changed" in install.stdout.lower()
        assert "does not switch" in install.stdout.lower()
        assert _tree_digest(data_dir) == source_offline_snapshot, (
            "offline stage installation modified the stopped source data directory"
        )
        assert _tree_digest(stage_path) == stage_snapshot, (
            "offline stage installation modified or consumed its verified source stage"
        )
        assert hashlib.sha256(archive_a.read_bytes()).hexdigest() == archive_a_hash

        installed_names = {path.name for path in installed_data_dir.iterdir()}
        expected_installed_files = {
            "atermius.db",
            "auth-rate-limit.key",
            "instance-ed25519.key",
        }
        assert installed_names == expected_installed_files
        assert not installed_data_dir.is_symlink()
        if os.name == "posix":
            assert stat.S_IMODE(installed_data_dir.stat().st_mode) == 0o700
        stage_data_digests = {
            name: stage_snapshot[name][0]
            for name in expected_installed_files
        }
        for name in expected_installed_files:
            installed_file = installed_data_dir / name
            metadata = installed_file.lstat()
            assert stat.S_ISREG(metadata.st_mode) and not installed_file.is_symlink()
            if os.name == "posix":
                assert stat.S_IMODE(metadata.st_mode) == 0o600
            assert hashlib.sha256(installed_file.read_bytes()).hexdigest() == stage_data_digests[name]

        installed_db = installed_data_dir / "atermius.db"
        installed_read_connection = sqlite3.connect(
            f"file:{installed_db}?mode=ro&immutable=1", uri=True
        )
        try:
            installed_meta = installed_read_connection.execute(
                "SELECT instance_id,server_space_id,generation FROM instance_meta WHERE id=1"
            ).fetchone()
            installed_active_sessions = installed_read_connection.execute(
                "SELECT COUNT(*) FROM sessions WHERE revoked_at IS NULL"
            ).fetchone()[0]
        finally:
            installed_read_connection.close()
        assert installed_meta == staged_meta
        assert installed_active_sessions == 0

        # The shared suite account may have exhausted its archived login
        # limiter. Reset only this disposable installed target's login bucket;
        # the staged source, archive, and live source volume remain untouched.
        with sqlite3.connect(installed_db, timeout=10) as connection:
            connection.execute("DELETE FROM auth_rate_limits WHERE endpoint='login'")
            connection.commit()

        target_env = dict(api.admin_env)
        target_env["ATERMIUS_DATA_DIR"] = str(installed_data_dir)
        target_env["ATERMIUS_DATABASE_URL"] = f"sqlite://{installed_db}?mode=rwc"
        target_base_url = api.base_url
        installed_process, installed_log, installed_api = _start_server(
            _server_binary(),
            target_env,
            target_base_url,
            installed_log_path,
            account["access_token"],
            account["refresh_token"],
            key_bytes.hex(),
        )
        assert installed_api.request("GET", "/health/live").status == 200
        restored_instance = installed_api.request("GET", "/api/v1/instance")
        assert restored_instance.status == 200
        assert restored_instance.json()["generation"] == staged_meta[2]
        assert restored_instance.json()["generation"] != live_generation
        assert installed_api.request(
            "GET", "/api/v1/me", token=account["access_token"]
        ).status == 401
        old_refresh = installed_api.request(
            "POST", "/api/v1/auth/refresh",
            json_body={"refresh_token": account["refresh_token"]},
        )
        assert old_refresh.status == 401

        staged_login = installed_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": account["username"],
                "login_verifier": account["login_verifier"],
                "device_id": account["device_id"],
            },
        )
        assert staged_login.status == 200, (
            f"installed restore copy could not issue a fresh session: HTTP {staged_login.status} "
            f"{_error_code(staged_login)}"
        )
        staged_token = staged_login.json()["access_token"]
        restored_snapshot = installed_api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/snapshots",
            token=staged_token,
        )
        assert restored_snapshot.status in (200, 201), (
            f"installed restore snapshot failed: HTTP {restored_snapshot.status} "
            f"{_error_code(restored_snapshot)}"
        )
        restored_revisions = installed_api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?"
            f"snapshot_id={restored_snapshot.json()['snapshot_id']}&limit=500",
            token=staged_token,
        )
        assert restored_revisions.status == 200, (
            f"installed Vault revisions failed: HTTP {restored_revisions.status} "
            f"{_error_code(restored_revisions)}"
        )
        restored_events = [
            event
            for event in restored_revisions.json()["revisions"]
            if event.get("record_id") == record_id
            and event.get("revision_id") == revision_id
        ]
        assert len(restored_events) == 1
        assert _envelope_digest(restored_events[0].get("envelope")) == record_digest
        assert restored_events[0]["envelope"] == record_envelope
        assert restored_events[0]["envelope"]["header"]["object_refs"] == [object_id]
        restored_object = installed_api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/objects/{object_id}",
            token=staged_token,
        )
        assert restored_object.status == 200, (
            f"installed opaque object read failed: HTTP {restored_object.status} "
            f"{_error_code(restored_object)}"
        )
        assert restored_object.body == opaque_object
        assert hashlib.sha256(restored_object.body).hexdigest() == object_sha256
        with sqlite3.connect(installed_db, timeout=10) as connection:
            archived_backup_job = connection.execute(
                "SELECT status,result_code FROM instance_admin_jobs WHERE job_id=?",
                (first["job_id"],),
            ).fetchone()
        assert archived_backup_job == ("interrupted", "interrupted"), (
            "installed restore did not reconcile the in-flight backup row"
        )

        # Simulate an operator switching back after testing the new volume.
        # Stop the target first, then restart the untouched source on the same
        # service address and prove its pre-cutover session/data are still live.
        _stop_server(installed_process)
        installed_process = None
        if installed_log is not None:
            installed_log.close()
            installed_log = None
        api.start_managed_server()
        source_stopped = False
        rollback_instance = api.request("GET", "/api/v1/instance")
        assert rollback_instance.status == 200
        assert rollback_instance.json()["generation"] == live_generation
        assert api.request("GET", "/api/v1/me", token=account["access_token"]).status == 200
        assert _live_business_snapshot(db_path) == live_snapshot
        assert _live_payload_tree_digest(data_dir) == source_tree_before
        assert hashlib.sha256(archive_a.read_bytes()).hexdigest() == archive_a_hash

        # Idempotent retries created exactly one stage and no API response
        # reveals its path, archive basename, key path, or key bytes.
        stage_names = sorted(path.name for path in stage_root.iterdir() if path.is_dir())
        assert stage_names == [stage_path.name]
        response_data = {"accepted": accepted, "terminal": terminal, "sources": sources}
        _assert_no_private_source_metadata(
            response_data,
            *(
                private_sentinels
                + (str(stage_path), archive_a.name, archive_b.name, archive_c.name, archive_d.name)
            ),
        )

    finally:
        cleanup_failures: list[str] = []

        def cleanup_step(label: str, action) -> bool:
            try:
                action()
                return True
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit, GeneratorExit)):
                    raise
                # Keep diagnostics useful without echoing paths, file contents,
                # tokens, or exception messages from the private fixture.
                cleanup_failures.append(f"{label} ({type(error).__name__})")
                return False

        installed_stopped = (
            installed_process is None or installed_process.poll() is not None
        )
        if installed_process is not None and not installed_stopped:
            def stop_installed_server() -> None:
                _stop_server(installed_process)
                if installed_process.poll() is None:
                    raise RuntimeError("installed server is still running")

            installed_stopped = cleanup_step(
                "stop installed server", stop_installed_server
            )
        if installed_log is not None:
            cleanup_step("close installed server log", installed_log.close)

        def remove_installed_log() -> None:
            if not os.path.lexists(installed_log_path):
                return
            if installed_log_path.is_symlink() or installed_log_path.is_file():
                installed_log_path.unlink()
                return
            raise RuntimeError("installed server log path is not a regular file")

        cleanup_step("remove installed server log", remove_installed_log)

        if source_stopped and cleanup_step(
            "restart source server", api.start_managed_server
        ):
            source_stopped = False

        def remove_installed_copy() -> None:
            if not installed_stopped:
                raise RuntimeError("installed server could not be confirmed stopped")
            if os.path.lexists(installed_data_dir):
                if installed_data_dir.is_symlink() or installed_data_dir.is_file():
                    installed_data_dir.unlink()
                elif installed_data_dir.is_dir():
                    shutil.rmtree(installed_data_dir)
                else:
                    raise RuntimeError("installed target is not a file or directory")
            if os.path.lexists(installed_data_dir):
                raise RuntimeError("disposable installed restore copy remains")

        cleanup_step("remove installed restore copy", remove_installed_copy)

        def remove_owned_stage() -> None:
            if stage_path is None or not os.path.lexists(stage_path):
                return
            if stage_path.is_symlink() or not stage_path.is_dir():
                raise RuntimeError("restore stage path has an unsafe type")
            shutil.rmtree(stage_path)
            if os.path.lexists(stage_path):
                raise RuntimeError("restore stage path remains")

        cleanup_step("remove owned restore stage", remove_owned_stage)

        def remove_owned_file(path: Path) -> None:
            if not os.path.lexists(path):
                return
            if path.is_symlink() or path.is_file():
                path.unlink()
                return
            raise RuntimeError("owned archive path is not a regular file")

        for path in owned_files:
            cleanup_step("remove owned archive fixture", lambda path=path: remove_owned_file(path))

        def restore_backup_status() -> None:
            if saved_status is None and not status_existed_before:
                if not os.path.lexists(status_file):
                    return
                if status_file.is_symlink() or status_file.is_file():
                    status_file.unlink()
                    return
                raise RuntimeError("new backup status path is not a regular file")
            if saved_status is None:
                return
            if os.path.lexists(status_file) and (
                status_file.is_symlink() or not status_file.is_file()
            ):
                raise RuntimeError("original backup status path has an unsafe type")
            status_file.write_bytes(saved_status[0])
            if os.name == "posix":
                status_file.chmod(saved_status[1])

        cleanup_step("restore backup status sidecar", restore_backup_status)

        for archive_id in created_archive_ids:
            for path in archive_dir.glob(f"*{archive_id}*.atb"):
                cleanup_step(
                    "remove created backup output",
                    lambda path=path: remove_owned_file(path),
                )

        def remove_empty_stage_root() -> None:
            if not os.path.lexists(stage_root):
                return
            if stage_root.is_symlink() or not stage_root.is_dir():
                raise RuntimeError("restore staging root has an unsafe type")
            stage_root.rmdir()

        cleanup_step("remove empty restore staging root", remove_empty_stage_root)

        if cleanup_failures:
            raise AssertionError(
                "restore acceptance cleanup failures: " + ", ".join(cleanup_failures)
            )
