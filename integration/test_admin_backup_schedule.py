"""Black-box acceptance for durable scheduled encrypted instance backups."""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from test_account_deletion import _db_path, _register_account
from test_admin_backup_jobs import _error_code


def _wait_for_schedule_run(api, token: str) -> dict:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        response = api.request("GET", "/api/v1/admin/backup-schedule", token=token)
        assert response.status == 200
        run = response.json()["last_run"]
        if run is not None and run["status"] in {
            "succeeded",
            "failed",
            "interrupted",
        }:
            return response.json()
        time.sleep(0.05)
    pytest.fail("due scheduled backup did not reach a terminal state")


def _set_schedule_due(api) -> None:
    due = int((datetime.now(timezone.utc) - timedelta(minutes=5)).timestamp())
    with sqlite3.connect(_db_path(api), timeout=10) as connection:
        changed = connection.execute(
            "UPDATE instance_backup_schedule SET next_run_at=? WHERE schedule_id=1",
            (due,),
        ).rowcount
        assert changed == 1, "schedule update did not persist a singleton row"


def test_admin_backup_schedule_is_durable_and_creates_one_private_archive(
    api, account, tmp_path: Path
) -> None:
    if not api.server_env or not api.admin_env or not api.temp_root:
        pytest.skip("scheduled backup acceptance needs the suite-owned disposable server")
    if not api.backup_archive_dir or not api.backup_key_file:
        pytest.fail("managed integration server has no private backup configuration")

    archive_dir = Path(api.backup_archive_dir)
    key_file = Path(api.backup_key_file)
    original_archives = {path.name for path in archive_dir.iterdir()}
    unauthenticated = api.request("GET", "/api/v1/admin/backup-schedule")
    assert unauthenticated.status == 401

    outsider = _register_account(
        api,
        f"backup-schedule-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "backup-schedule-outsider",
    )
    denied = api.request(
        "GET", "/api/v1/admin/backup-schedule", token=outsider["access_token"]
    )
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"

    initial = api.request(
        "GET", "/api/v1/admin/backup-schedule", token=account["access_token"]
    )
    assert initial.status == 200
    assert initial.json() == {
        "operation": "backup_schedule",
        "backup_configured": True,
        "interval_hours": None,
        "next_run_at": None,
        "last_run": None,
    }

    for invalid in [
        {},
        {"interval_hours": 0},
        {"interval_hours": 721},
        {"interval_hours": 1.5},
        {"interval_hours": "24"},
        {"interval_hours": True},
        {"interval_hours": None, "archive_path": "/tmp/attacker.atb"},
    ]:
        response = api.request(
            "PUT",
            "/api/v1/admin/backup-schedule",
            token=account["access_token"],
            json_body=invalid,
        )
        assert response.status == 400, f"unexpected schedule acceptance: {invalid!r}"
        assert _error_code(response) in {
            "INVALID_BACKUP_SCHEDULE_REQUEST",
            "INVALID_BACKUP_INTERVAL",
        }

    enabled = api.request(
        "PUT",
        "/api/v1/admin/backup-schedule",
        token=account["access_token"],
        json_body={"interval_hours": 1},
    )
    assert enabled.status == 200
    schedule = enabled.json()
    assert schedule["interval_hours"] == 1
    assert schedule["backup_configured"] is True
    next_run = datetime.fromisoformat(schedule["next_run_at"].replace("Z", "+00:00"))
    assert next_run > datetime.now(timezone.utc)
    assert schedule["last_run"] is None

    # Force only the persisted due time forward in this disposable DB, then
    # restart to prove the scheduler reads durable state rather than relying
    # on process-local timers.
    api.stop_managed_server()
    try:
        _set_schedule_due(api)
        api.start_managed_server()
        completed = _wait_for_schedule_run(api, account["access_token"])
        run = completed["last_run"]
        assert run["status"] == "succeeded"
        assert run["result_code"] == "completed"
        assert run["archive_bytes"] > 0
        assert run["migration_version"] >= 0
        assert str(uuid.UUID(run["run_id"])) == run["run_id"]
        generated = list(archive_dir.glob(f"*{run['run_id']}*.atb"))
        assert len(generated) == 1
        archive = generated[0]
        assert archive.stat().st_size == run["archive_bytes"]

        safe_response = json.dumps(completed)
        key_bytes = key_file.read_bytes()
        assert str(archive_dir) not in safe_response
        assert str(key_file) not in safe_response
        assert key_bytes.hex() not in safe_response

        # The next occurrence is in the future. A restart must retain the
        # durable last run and must not create another archive immediately.
        api.stop_managed_server()
        before_restart = {path.name for path in archive_dir.iterdir()}
        api.start_managed_server()
        stable = api.request(
            "GET", "/api/v1/admin/backup-schedule", token=account["access_token"]
        )
        assert stable.status == 200
        assert stable.json()["last_run"]["run_id"] == run["run_id"]
        assert {path.name for path in archive_dir.iterdir()} == before_restart

        disabled = api.request(
            "PUT",
            "/api/v1/admin/backup-schedule",
            token=account["access_token"],
            json_body={"interval_hours": None},
        )
        assert disabled.status == 200
        assert disabled.json()["interval_hours"] is None
        assert disabled.json()["next_run_at"] is None
        assert disabled.json()["last_run"]["run_id"] == run["run_id"]
    finally:
        api.stop_managed_server()
        api.start_managed_server()

    new_archives = {path.name for path in archive_dir.iterdir()} - original_archives
    assert len(new_archives) == 1
    assert run["run_id"] in next(iter(new_archives))

    with sqlite3.connect(_db_path(api)) as connection:
        audit = connection.execute(
            "SELECT action,actor_user_id,actor_device_id,resource_type,resource_id,result "
            "FROM audit_events WHERE scope_type='instance' "
            "AND action='admin.backup_schedule_updated' AND actor_user_id=?",
            (account["account_id"],),
        ).fetchall()
    assert len(audit) == 2  # enable and disable
    assert all(row[1] == account["account_id"] for row in audit)
    assert all(row[2] == account["device_id"] for row in audit)
    assert all(row[3] == "backup_schedule" for row in audit)
    assert all(row[4] is None for row in audit)
    assert all(row[5] == "success" for row in audit)
