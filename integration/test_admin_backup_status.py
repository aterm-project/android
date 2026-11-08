"""Black-box acceptance for the private last-backup-attempt admin status."""

from __future__ import annotations

import base64
import json
import os
import stat
from datetime import datetime
from pathlib import Path

import pytest

from test_backup_cli import _run_cli, _server_binary, _tree_snapshot


def _status(api, token: str | None = None):
    return api.request("GET", "/api/v1/admin/backup-status", token=token)


def test_admin_backup_status_tracks_backup_cli_and_verify_is_read_only(
    api, account, tmp_path: Path
) -> None:
    if not api.admin_env or not api.temp_root:
        pytest.skip("backup status acceptance needs the suite-owned disposable server")

    data_dir = Path(api.admin_env["ATERMIUS_DATA_DIR"])
    status_file = data_dir / "backup-status.json"
    # The session-scoped managed server is shared by acceptance cases. Reset
    # this disposable instance's non-secret local status so the test starts
    # from the documented no-attempt state even if an admin-job case ran first.
    if status_file.exists():
        status_file.unlink()
    key_path = tmp_path / "operator-backup-secret.key"
    archive_path = tmp_path / "operator-archive-secret.atb"
    key = os.urandom(32)
    key_path.write_bytes(key)
    if os.name == "posix":
        os.chmod(key_path, 0o600)
    key_b64 = base64.urlsafe_b64encode(key).decode().rstrip("=")
    key_hex = key.hex()
    policy_sentinel = "backup-policy-secret@example.invalid"

    missing_auth = _status(api)
    assert missing_auth.status == 401
    initial = _status(api, account["access_token"])
    assert initial.status == 200
    assert initial.json() == {"operation": "backup", "last_attempt": None}
    assert not status_file.exists()

    executable = _server_binary()
    cli_env = dict(api.admin_env)
    cli_env["ATERMIUS_ADMIN_USERNAMES"] = policy_sentinel
    success = _run_cli(
        executable,
        cli_env,
        "backup",
        "--archive",
        str(archive_path),
        "--key-file",
        str(key_path),
    )
    assert success.returncode == 0, (
        "backup CLI failed: " + (success.stdout + "\n" + success.stderr)[-3000:]
    )
    assert archive_path.is_file() and archive_path.stat().st_size > 0
    assert status_file.is_file()
    if os.name == "posix":
        sidecar_stat = status_file.stat()
        assert sidecar_stat.st_uid == os.geteuid()
        assert stat.S_IMODE(sidecar_stat.st_mode) == 0o600

    sidecar_bytes = status_file.read_bytes()
    sidecar = json.loads(sidecar_bytes)
    assert set(sidecar) == {
        "schema_version",
        "operation",
        "attempted_at",
        "result",
        "migration_version",
        "archive_bytes",
        "failure_category",
        "last_success_at",
    }
    assert sidecar["schema_version"] == 2
    assert sidecar["operation"] == "backup"
    assert sidecar["result"] == "succeeded"
    assert sidecar["migration_version"] >= 0
    assert sidecar["archive_bytes"] == archive_path.stat().st_size
    assert sidecar["failure_category"] is None
    assert sidecar["last_success_at"] == sidecar["attempted_at"]
    datetime.fromisoformat(sidecar["attempted_at"].replace("Z", "+00:00"))

    exposed = _status(api, account["access_token"])
    assert exposed.status == 200
    expected_attempt = {
        key: value
        for key, value in sidecar.items()
        if key not in {"schema_version", "operation", "last_success_at"}
    }
    assert exposed.json() == {"operation": "backup", "last_attempt": expected_attempt}
    serialized = sidecar_bytes.decode("utf-8") + json.dumps(exposed.json())
    for secret in (str(key_path), str(archive_path), key_b64, key_hex, policy_sentinel):
        assert secret not in serialized

    before_verify = _tree_snapshot(data_dir)
    before_status = status_file.read_bytes()
    verify = _run_cli(
        executable,
        cli_env,
        "verify-backup",
        "--archive",
        str(archive_path),
        "--key-file",
        str(key_path),
    )
    assert verify.returncode == 0, (
        "verify-backup failed: " + (verify.stdout + "\n" + verify.stderr)[-3000:]
    )
    assert _tree_snapshot(data_dir) == before_verify
    assert status_file.read_bytes() == before_status
    assert _status(api, account["access_token"]).json() == exposed.json()

    missing_key_path = tmp_path / "fixed-failure-secret.key"
    failed = _run_cli(
        executable,
        cli_env,
        "backup",
        "--archive",
        str(archive_path),
        "--key-file",
        str(missing_key_path),
    )
    assert failed.returncode != 0
    failed_sidecar_bytes = status_file.read_bytes()
    failed_sidecar = json.loads(failed_sidecar_bytes)
    if os.name == "posix":
        failed_stat = status_file.stat()
        assert failed_stat.st_uid == os.geteuid()
        assert stat.S_IMODE(failed_stat.st_mode) == 0o600
    assert failed_sidecar["operation"] == "backup"
    assert failed_sidecar["result"] == "failed"
    assert failed_sidecar["migration_version"] is None
    assert failed_sidecar["archive_bytes"] is None
    assert failed_sidecar["failure_category"] == "backup_failed"
    assert failed_sidecar["last_success_at"] == sidecar["last_success_at"]
    failure_exposed = _status(api, account["access_token"])
    assert failure_exposed.status == 200
    assert failure_exposed.json() == {
        "operation": "backup",
        "last_attempt": {
            key: value
            for key, value in failed_sidecar.items()
            if key not in {"schema_version", "operation", "last_success_at"}
        },
    }
    failure_serialized = failed_sidecar_bytes.decode("utf-8") + json.dumps(
        failure_exposed.json()
    )
    for secret in (
        str(key_path),
        str(archive_path),
        str(missing_key_path),
        key_b64,
        key_hex,
        policy_sentinel,
        "No such file",
    ):
        assert secret not in failure_serialized

    before_failed_verify = _tree_snapshot(data_dir)
    before_failed_status = status_file.read_bytes()
    verify_after_failure = _run_cli(
        executable,
        cli_env,
        "verify-backup",
        "--archive",
        str(archive_path),
        "--key-file",
        str(key_path),
    )
    assert verify_after_failure.returncode == 0
    assert _tree_snapshot(data_dir) == before_failed_verify
    assert status_file.read_bytes() == before_failed_status
    assert _status(api, account["access_token"]).json() == failure_exposed.json()


def test_backup_status_rejects_authenticated_non_allowlisted_member(api, account, tmp_path):
    if not api.admin_env or not api.temp_root:
        pytest.skip("backup status permission acceptance needs the suite-owned disposable server")

    from test_account_deletion import _register_account

    member = _register_account(
        api,
        f"backup-status-outsider-{os.urandom(4).hex()}@example.test",
        tmp_path,
        "backup-status-outsider",
    )
    denied = _status(api, member["access_token"])
    assert denied.status == 403
    assert (denied.json().get("error") or {}).get("code") == "INSTANCE_ADMIN_REQUIRED"
