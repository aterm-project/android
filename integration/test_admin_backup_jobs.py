"""Black-box acceptance for the allowlisted encrypted backup admin job."""

from __future__ import annotations

import base64
import json
import os
import sqlite3
import stat
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from test_account_deletion import _db_path, _register_account
from test_backup_cli import _run_cli, _server_binary


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _wait_for_terminal_job(api, token: str, job_id: str) -> dict:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        page = api.request("GET", "/api/v1/admin/jobs?limit=100", token=token)
        assert page.status == 200
        job = next(item for item in page.json()["jobs"] if item["job_id"] == job_id)
        if job["status"] in {"succeeded", "failed", "interrupted"}:
            return job
        time.sleep(0.05)
    pytest.fail("encrypted backup job did not reach a terminal state")


def test_admin_backup_job_is_private_authorized_idempotent_and_updates_status(
    api, account, tmp_path: Path
) -> None:
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin backup job acceptance needs the suite-owned disposable server")
    if not api.backup_archive_dir or not api.backup_key_file:
        pytest.fail("managed integration server did not configure operator backup settings")

    archive_dir = Path(api.backup_archive_dir)
    key_file = Path(api.backup_key_file)
    data_dir = Path(api.admin_env["ATERMIUS_DATA_DIR"])
    key_bytes = key_file.read_bytes()
    key_b64 = base64.urlsafe_b64encode(key_bytes).decode("ascii").rstrip("=")
    key_hex = key_bytes.hex()
    archive_path_sentinel = str(archive_dir)
    key_path_sentinel = str(key_file)
    db_path = _db_path(api)

    unauthenticated = api.request(
        "POST",
        "/api/v1/admin/jobs",
        json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
    )
    assert unauthenticated.status == 401

    outsider = _register_account(
        api,
        f"admin-backup-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "admin-backup-outsider",
    )
    denied = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=outsider["access_token"],
        json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
    )
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"

    # Invalid owner-only key permissions fail before a durable job is accepted.
    if os.name == "posix":
        original_mode = stat.S_IMODE(key_file.stat().st_mode)
        try:
            key_file.chmod(0o644)
            invalid_config = api.request(
                "POST",
                "/api/v1/admin/jobs",
                token=account["access_token"],
                json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
            )
            assert invalid_config.status == 503
            assert _error_code(invalid_config) == "BACKUP_NOT_CONFIGURED"
            error_body = json.dumps(invalid_config.json())
            assert not any(
                secret in error_body
                for secret in (archive_path_sentinel, key_path_sentinel, key_b64, key_hex)
            ), "configuration error exposed operator-only backup material"
        finally:
            key_file.chmod(original_mode)

    prior_archives = {path.name for path in archive_dir.iterdir()}
    request_id = str(uuid.uuid4())

    def submit_same_backup(_index: int):
        return api.request(
            "POST",
            "/api/v1/admin/jobs",
            token=account["access_token"],
            json_body={"request_id": request_id, "action": "backup"},
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        submissions = list(executor.map(submit_same_backup, range(2)))
    assert all(response.status == 202 for response in submissions)
    accepted = submissions[0].json()["job"]
    assert submissions[1].json()["job"]["job_id"] == accepted["job_id"]
    assert accepted["action"] == "backup"
    assert accepted["request_id"] == request_id
    assert accepted["archive_id"] is None
    assert accepted["archive_source"] is None
    assert set(accepted) == {
        "job_id",
        "request_id",
        "action",
        "archive_id",
        "archive_source",
        "status",
        "requested_at",
        "started_at",
        "finished_at",
        "result_code",
        "restore_stage_status",
    }
    assert accepted["restore_stage_status"] is None

    replay = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": request_id, "action": "backup"},
    )
    assert replay.status == 202
    assert replay.json()["job"]["job_id"] == accepted["job_id"]

    terminal = _wait_for_terminal_job(api, account["access_token"], accepted["job_id"])
    assert terminal["status"] == "succeeded"
    assert terminal["result_code"] == "completed"
    assert terminal["action"] == "backup"

    created_archives = [
        path
        for path in archive_dir.iterdir()
        if path.is_file() and path.name not in prior_archives
    ]
    assert len(created_archives) == 1
    archive_path = created_archives[0]
    assert archive_path.stat().st_size > 0
    assert accepted["job_id"] in archive_path.name

    status_file = data_dir / "backup-status.json"
    status_bytes = status_file.read_bytes()
    status = json.loads(status_bytes)
    assert status["result"] == "succeeded"
    assert status["migration_version"] >= 0
    assert status["archive_bytes"] == archive_path.stat().st_size
    assert status["failure_category"] is None
    if os.name == "posix":
        assert status_file.stat().st_uid == os.geteuid()
        assert stat.S_IMODE(status_file.stat().st_mode) == 0o600

    exposed_status = api.request(
        "GET", "/api/v1/admin/backup-status", token=account["access_token"]
    )
    assert exposed_status.status == 200
    assert exposed_status.json()["last_attempt"]["result"] == "succeeded"

    # The generated archive is valid with the separately stored operator key.
    verify = _run_cli(
        _server_binary(),
        api.admin_env,
        "verify-backup",
        "--archive",
        str(archive_path),
        "--key-file",
        str(key_file),
    )
    assert verify.returncode == 0, "server-generated encrypted archive did not verify"

    with sqlite3.connect(db_path) as connection:
        audit_rows = connection.execute(
            "SELECT action,actor_user_id,actor_device_id,resource_type,resource_id,result "
            "FROM audit_events WHERE scope_type='instance' AND actor_user_id=? "
            "AND action IN ('admin.backup_requested','admin.backup_started',"
            "'admin.backup_completed','admin.backup_failed')",
            (account["account_id"],),
        ).fetchall()
    events = {row[0]: row for row in audit_rows}
    assert {"admin.backup_requested", "admin.backup_started", "admin.backup_completed"} <= set(events)
    assert all(row[1] == account["account_id"] for row in audit_rows)
    assert all(row[2] == account["device_id"] for row in audit_rows)
    assert all(row[3] == "admin_job" for row in audit_rows)
    assert all(row[4] != accepted["job_id"] for row in audit_rows)
    assert events["admin.backup_requested"][5] == "success"
    assert events["admin.backup_started"][5] == "success"
    assert events["admin.backup_completed"][5] == "success"

    safe_serialized = json.dumps(
        {
            "accepted": accepted,
            "terminal": terminal,
            "status": exposed_status.json(),
            "sidecar": status,
            "audit": audit_rows,
        }
    )
    assert not any(
        secret in safe_serialized
        for secret in (
            archive_path_sentinel,
            key_path_sentinel,
            key_b64,
            key_hex,
            archive_path.name,
        )
    ), "public backup job data exposed operator-only paths or key material"


def test_backup_job_rejects_missing_optional_settings_without_blocking_startup(
    api, account
) -> None:
    if not api.server_env or not api.temp_root:
        pytest.skip("missing-setting acceptance needs the suite-owned disposable server")

    settings = {}
    for name in ("ATERMIUS_BACKUP_ARCHIVE_DIR", "ATERMIUS_BACKUP_KEY_FILE"):
        settings[name] = api.server_env.pop(name)
    try:
        api.stop_managed_server()
        api.start_managed_server()
        ready = api.request("GET", "/health/ready")
        assert ready.status == 200
        rejected = api.request(
            "POST",
            "/api/v1/admin/jobs",
            token=account["access_token"],
            json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
        )
        assert rejected.status == 503
        assert _error_code(rejected) == "BACKUP_NOT_CONFIGURED"
    finally:
        api.stop_managed_server()
        api.server_env.update(settings)
        api.start_managed_server()
