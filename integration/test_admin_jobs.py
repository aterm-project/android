"""Black-box acceptance for durable instance-admin maintenance jobs."""

from __future__ import annotations

import sqlite3
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from test_account_deletion import _db_path, _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _wait_for_terminal_job(api, token: str, job_id: str) -> dict:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        page = api.request("GET", "/api/v1/admin/jobs?limit=100", token=token)
        assert page.status == 200
        job = next(item for item in page.json()["jobs"] if item["job_id"] == job_id)
        if job["status"] in {"succeeded", "failed", "interrupted"}:
            return job
        time.sleep(0.05)
    pytest.fail("maintenance job did not reach a terminal state")


def _insert_stranded_job(db_path, account: dict, *, status: str) -> tuple[str, str]:
    job_id = str(uuid.uuid4())
    request_id = str(uuid.uuid4())
    requested_at = "2026-09-29T00:00:00Z"
    started_at = requested_at if status == "running" else None
    with sqlite3.connect(db_path) as connection:
        connection.execute(
            "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,"
            "requested_by_device_id,action,status,requested_at,started_at) "
            "VALUES(?,?,?,?, 'maintenance',?,?,?)",
            (
                job_id,
                request_id,
                account["account_id"],
                account["device_id"],
                status,
                requested_at,
                started_at,
            ),
        )
    return job_id, request_id


def _assert_recovered_interrupted(api, token: str, job_id: str) -> None:
    page = api.request("GET", "/api/v1/admin/jobs?limit=100", token=token)
    assert page.status == 200
    job = next(item for item in page.json()["jobs"] if item["job_id"] == job_id)
    assert job["status"] == "interrupted"
    assert job["result_code"] == "interrupted"
    assert job["finished_at"] is not None
    assert job["archive_id"] is None


def test_admin_maintenance_jobs_are_durable_idempotent_and_allowlist_scoped(
    api, account, tmp_path, request
):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin job acceptance needs the suite-owned disposable server")

    outsider = _register_account(
        api,
        f"admin-job-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "admin-job-outsider",
    )
    db_path = _db_path(api)

    missing = api.request("GET", "/api/v1/admin/jobs")
    assert missing.status == 401
    missing_write = api.request(
        "POST",
        "/api/v1/admin/jobs",
        json_body={"request_id": str(uuid.uuid4()), "action": "maintenance"},
    )
    assert missing_write.status == 401

    denied = api.request("GET", "/api/v1/admin/jobs", token=outsider["access_token"])
    assert denied.status == 403
    assert _error_code(denied) == "INSTANCE_ADMIN_REQUIRED"
    denied_write = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=outsider["access_token"],
        json_body={"request_id": str(uuid.uuid4()), "action": "maintenance"},
    )
    assert denied_write.status == 403

    malformed_id = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": str(uuid.uuid4()).upper(), "action": "maintenance"},
    )
    assert malformed_id.status == 400
    assert _error_code(malformed_id) == "INVALID_REQUEST_ID"
    unknown_action = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": str(uuid.uuid4()), "action": "restore"},
    )
    assert unknown_action.status == 400
    unknown_field = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={
            "request_id": str(uuid.uuid4()),
            "action": "maintenance",
            "path": "/tmp/should-not-be-accepted",
        },
    )
    assert unknown_field.status == 400

    request_id = str(uuid.uuid4())
    def submit_same_request(_index: int):
        return api.request(
            "POST",
            "/api/v1/admin/jobs",
            token=account["access_token"],
            json_body={"request_id": request_id, "action": "maintenance"},
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        concurrent_submissions = list(executor.map(submit_same_request, range(2)))
    assert all(response.status == 202 for response in concurrent_submissions)
    assert (
        concurrent_submissions[0].json()["job"]["job_id"]
        == concurrent_submissions[1].json()["job"]["job_id"]
    )
    created = concurrent_submissions[0]
    receipt = created.json()
    assert set(receipt) == {"job"}
    first_job = receipt["job"]
    assert set(first_job) == {
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
    assert first_job["restore_stage_status"] is None
    assert first_job["request_id"] == request_id
    assert first_job["action"] == "maintenance"
    assert first_job["archive_id"] is None
    assert first_job["archive_source"] is None
    assert first_job["status"] in {"queued", "running", "succeeded"}
    assert first_job["result_code"] is None or first_job["result_code"] == "completed"

    # Replaying an idempotency key returns the original durable job even if
    # the background worker already finished it.
    replay = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": request_id, "action": "maintenance"},
    )
    assert replay.status == 202
    assert replay.json()["job"]["job_id"] == first_job["job_id"]
    terminal = _wait_for_terminal_job(api, account["access_token"], first_job["job_id"])
    assert terminal["status"] in {"succeeded", "failed"}
    if terminal["status"] == "succeeded":
        assert terminal["result_code"] == "completed"
    else:
        assert terminal["result_code"] == "maintenance_failed"

    # The request ID is global: another account's prior request cannot be
    # disclosed or adopted by the current administrator.
    reused_request_id = str(uuid.uuid4())
    other_job_id = str(uuid.uuid4())
    stamp = terminal["requested_at"]
    with sqlite3.connect(db_path) as connection:
        connection.execute(
            "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,"
            "requested_by_device_id,action,status,requested_at,started_at,finished_at,result_code) "
            "VALUES(?,?,?,?,'maintenance','succeeded',?,?,?,'completed')",
            (
                other_job_id,
                reused_request_id,
                outsider["account_id"],
                outsider["device_id"],
                stamp,
                stamp,
                stamp,
            ),
        )
    reused = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": reused_request_id, "action": "maintenance"},
    )
    assert reused.status == 409
    assert _error_code(reused) == "JOB_REQUEST_ID_CONFLICT"

    inventory = api.request(
        "GET",
        "/api/v1/admin/jobs?limit=1&offset=0",
        token=account["access_token"],
    )
    assert inventory.status == 200
    assert set(inventory.json()) == {"jobs", "total", "supported_actions"}
    assert inventory.json()["supported_actions"] == [
        "maintenance",
        "backup",
        "restore",
        "backup_status",
        "backup_replication",
        "backup_schedule",
        "restore_stage_discard",
    ]
    assert len(inventory.json()["jobs"]) <= 1
    assert inventory.json()["total"] >= 1
    serialized = str(inventory.json()).lower()
    for forbidden in ("/root/", "traceback", "database_url", "backup_key", "access_token"):
        assert forbidden not in serialized

    with sqlite3.connect(db_path) as connection:
        audit_rows = connection.execute(
            "SELECT action,actor_user_id,actor_device_id,resource_type,resource_id,result "
            "FROM audit_events WHERE scope_type='instance' AND actor_user_id=? "
            "AND action IN ('admin.maintenance_requested','admin.maintenance_started',"
            "'admin.maintenance_completed','admin.maintenance_failed')",
            (account["account_id"],),
        ).fetchall()
    assert {row[0] for row in audit_rows} >= {
        "admin.maintenance_requested",
        "admin.maintenance_started",
    }
    assert all(row[1] == account["account_id"] for row in audit_rows)
    assert all(row[2] == account["device_id"] for row in audit_rows)
    assert all(row[3] == "admin_job" for row in audit_rows)
    assert all(row[4] != first_job["job_id"] for row in audit_rows)
    expected_audit_result = {
        "admin.maintenance_requested": "success",
        "admin.maintenance_started": "success",
        "admin.maintenance_completed": "success",
        "admin.maintenance_failed": "failure",
    }
    assert all(row[5] == expected_audit_result[row[0]] for row in audit_rows)

    # Seed a stranded queued job to prove that serving startup reconciles it.
    queued_id, _ = _insert_stranded_job(db_path, account, status="queued")
    blocked = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": str(uuid.uuid4()), "action": "maintenance"},
    )
    assert blocked.status == 409
    assert _error_code(blocked) == "MAINTENANCE_ALREADY_RUNNING"
    blocked_backup = api.request(
        "POST",
        "/api/v1/admin/jobs",
        token=account["access_token"],
        json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
    )
    assert blocked_backup.status == 409
    assert _error_code(blocked_backup) == "MAINTENANCE_ALREADY_RUNNING"

    api.stop_managed_server()
    api.start_managed_server()
    _assert_recovered_interrupted(api, account["access_token"], queued_id)

    running_id, _ = _insert_stranded_job(db_path, account, status="running")
    api.stop_managed_server()
    api.start_managed_server()
    _assert_recovered_interrupted(api, account["access_token"], running_id)
    with sqlite3.connect(db_path) as connection:
        interrupted_events = connection.execute(
            "SELECT action,actor_user_id,actor_device_id,resource_id,result FROM audit_events "
            "WHERE scope_type='instance' AND action='admin.maintenance_interrupted' "
            "AND actor_user_id=?",
            (account["account_id"],),
        ).fetchall()
    assert len(interrupted_events) >= 2
    assert all(row[1] == account["account_id"] for row in interrupted_events)
    assert all(row[2] == account["device_id"] for row in interrupted_events)
    assert all(row[3] not in {queued_id, running_id} for row in interrupted_events)
    assert all(row[4] == "failure" for row in interrupted_events)
