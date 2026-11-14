"""Black-box restore acceptance for scheduled encrypted server backups."""

from __future__ import annotations

import hashlib
import os
import sqlite3
import time
from pathlib import Path

import pytest

from conftest import ApiClient
from test_account_deletion import _admin_cli, _db_path, _error_code
from test_admin_backup_schedule import _set_schedule_due, _wait_for_schedule_run
from test_backup_cli import _server_binary, _start_server, _stop_server, _tree_snapshot


def _free_port() -> int:
    import socket

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _schedule_epoch(value: str) -> int:
    from datetime import datetime

    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def test_scheduled_backup_restore_marks_snapshot_run_interrupted_without_replay(
    api, account, tmp_path: Path
) -> None:
    """A due-run archive contains the durable claim, not its later result."""
    if not api.server_env or not api.admin_env or not api.temp_root:
        pytest.skip("scheduled restore acceptance needs the suite-owned disposable server")
    if not api.backup_archive_dir or not api.backup_key_file:
        pytest.fail("managed integration server has no private backup configuration")

    archive_dir = Path(api.backup_archive_dir)
    key_file = Path(api.backup_key_file)
    source_data_dir = Path(api.server_env["ATERMIUS_DATA_DIR"])
    source_db = _db_path(api)
    restored_data_dir = tmp_path / "restored-data"
    original_archives = {path.name for path in archive_dir.iterdir()}
    run_id: str | None = None
    schedule_enabled = False
    source_stopped = False
    restored_process = None
    restored_log = None

    try:
        enabled = api.request(
            "PUT",
            "/api/v1/admin/backup-schedule",
            token=account["access_token"],
            json_body={"interval_hours": 1},
        )
        assert enabled.status == 200, (
            f"could not enable backup schedule: HTTP {enabled.status} {_error_code(enabled)}"
        )
        schedule_enabled = True
        assert enabled.json()["next_run_at"] is not None

        # Restart after making only the persisted due time old. The worker must
        # create an ordinary archive from the real durable schedule claim.
        api.stop_managed_server()
        source_stopped = True
        _set_schedule_due(api)
        api.start_managed_server()
        source_stopped = False
        completed = _wait_for_schedule_run(api, account["access_token"])
        completed_run = completed["last_run"]
        assert completed_run["status"] == "succeeded"
        assert completed_run["result_code"] == "completed"
        run_id = completed_run["run_id"]
        assert completed["interval_hours"] == 1
        assert completed["next_run_at"] is not None
        assert _schedule_epoch(completed["next_run_at"]) > int(time.time())

        archives = list(archive_dir.glob(f"*{run_id}*.atb"))
        assert len(archives) == 1, "successful due run did not publish one identifiable archive"
        archive = archives[0]
        assert archive.is_file() and archive.stat().st_size == completed_run["archive_bytes"]
        archive_digest = hashlib.sha256(archive.read_bytes()).digest()

        # Stop the active source before restore. The restore CLI is configured
        # against this source directory but must only publish to the new target.
        api.stop_managed_server()
        source_stopped = True
        source_before_restore = _tree_snapshot(source_data_dir)
        restore = _admin_cli(
            api,
            "restore",
            "--archive",
            str(archive),
            "--key-file",
            str(key_file),
            "--target-data-dir",
            str(restored_data_dir),
            "--server-stopped",
        )
        assert restore.returncode == 0, (
            "scheduled archive restore failed: "
            + (restore.stdout + "\n" + restore.stderr)[-4000:]
        )
        assert restored_data_dir.is_dir()
        assert (restored_data_dir / "atermius.db").is_file()
        assert _tree_snapshot(source_data_dir) == source_before_restore, (
            "restoring a scheduled archive changed the stopped source data directory"
        )
        assert hashlib.sha256(archive.read_bytes()).digest() == archive_digest, (
            "restore changed the source scheduled archive"
        )

        # Inspect the staged restore before startup recovery changes the run's
        # state. These are the values that the scheduled archive captured.
        with sqlite3.connect(f"file:{restored_data_dir / 'atermius.db'}?mode=ro", uri=True) as connection:
            schedule_row = connection.execute(
                "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1"
            ).fetchone()
            run_row = connection.execute(
                "SELECT run_id,scheduled_for,started_at,finished_at,status,result_code,"
                "migration_version,archive_bytes FROM instance_scheduled_backup_runs "
                "WHERE run_id=?",
                (run_id,),
            ).fetchone()
        assert schedule_row is not None
        assert schedule_row[0] == 1
        assert schedule_row[1] == _schedule_epoch(completed["next_run_at"])
        assert run_row is not None
        assert run_row[0] == run_id
        assert run_row[1] == _schedule_epoch(completed_run["scheduled_for"])
        assert run_row[2] == _schedule_epoch(completed_run["started_at"])
        assert run_row[3:] == (None, "running", None, None, None), (
            "the archive must contain the in-flight durable run snapshot"
        )

        # This integration session reuses one admin identity across many tests.
        # Its archived login throttling bucket may be exhausted by earlier
        # tests, which is unrelated to restoring the schedule. Model a window
        # rollover in this isolated restore copy so the post-restore admin
        # session can be established with the production limiter unchanged.
        with sqlite3.connect(restored_data_dir / "atermius.db") as connection:
            connection.execute("DELETE FROM auth_rate_limits WHERE endpoint='login'")
            connection.commit()

        # Reuse the exact private archive/key settings and effective admin
        # allowlist while binding the restored copy to a different local port.
        executable = _server_binary()
        restored_port = _free_port()
        restored_url = f"http://127.0.0.1:{restored_port}"
        restored_env = dict(api.server_env)
        restored_env["ATERMIUS_BIND"] = f"127.0.0.1:{restored_port}"
        restored_env["ATERMIUS_PUBLIC_ORIGIN"] = restored_url
        restored_env["ATERMIUS_DATA_DIR"] = str(restored_data_dir)
        restored_env["ATERMIUS_DATABASE_URL"] = (
            f"sqlite://{restored_data_dir / 'atermius.db'}?mode=rwc"
        )
        restored_process, restored_log, restored_api = _start_server(
            executable,
            restored_env,
            restored_url,
            tmp_path / "restored-server.log",
            account["access_token"],
        )

        # Restore rotates the server generation, so obtain a fresh admin
        # session before reading the private schedule status endpoint.
        fresh_login = restored_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": account["username"],
                "login_verifier": account["login_verifier"],
                "device_id": account["device_id"],
            },
        )
        assert fresh_login.status == 200, (
            f"restored admin could not log in: HTTP {fresh_login.status} {_error_code(fresh_login)}"
        )
        fresh_token = fresh_login.json()["access_token"]
        restored_status = restored_api.request(
            "GET", "/api/v1/admin/backup-schedule", token=fresh_token
        )
        assert restored_status.status == 200
        recovered = restored_status.json()
        assert recovered["interval_hours"] == 1
        assert recovered["next_run_at"] == completed["next_run_at"], (
            "startup recovery changed or consumed the next scheduled occurrence"
        )
        assert recovered["last_run"]["run_id"] == run_id
        assert recovered["last_run"]["status"] == "interrupted"
        assert recovered["last_run"]["result_code"] == "interrupted"
        assert recovered["last_run"]["finished_at"] is not None
        assert recovered["last_run"]["archive_bytes"] is None
        assert recovered["last_run"]["migration_version"] is None

        # The worker's first startup tick has run by now. It must not make a
        # second archive for the already-claimed slot; the archived next due
        # is still in the future, so the same ID remains terminal.
        time.sleep(2)
        stable = restored_api.request(
            "GET", "/api/v1/admin/backup-schedule", token=fresh_token
        )
        assert stable.status == 200
        assert stable.json()["last_run"]["run_id"] == run_id
        assert stable.json()["last_run"]["status"] == "interrupted"
        assert stable.json()["next_run_at"] == completed["next_run_at"]
        assert {path.name for path in archive_dir.iterdir()} == original_archives | {
            archive.name
        }, "restored startup unexpectedly replayed the claimed schedule occurrence"
        assert _tree_snapshot(source_data_dir) == source_before_restore, (
            "running the restored copy changed the stopped source data directory"
        )
    finally:
        _stop_server(restored_process)
        if restored_log is not None:
            restored_log.close()

        if source_stopped:
            api.start_managed_server()
            source_stopped = False
        elif schedule_enabled:
            api.stop_managed_server()
            api.start_managed_server()

        if schedule_enabled:
            disabled = api.request(
                "PUT",
                "/api/v1/admin/backup-schedule",
                token=account["access_token"],
                json_body={"interval_hours": None},
            )
            assert disabled.status == 200, (
                "cleanup could not disable source backup schedule: "
                f"HTTP {disabled.status} {_error_code(disabled)}"
            )
