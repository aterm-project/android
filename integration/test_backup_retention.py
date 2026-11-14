"""Black-box acceptance for optional server-generated backup retention."""

from __future__ import annotations

import os
import socket
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

from test_admin_backup_jobs import _wait_for_terminal_job
from test_backup_cli import _run_cli, _server_binary, _start_server, _stop_server


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _private_dir(path: Path) -> None:
    path.mkdir(mode=0o700)
    if os.name == "posix":
        path.chmod(0o700)


@pytest.mark.parametrize(
    ("retention_count", "configure_backup_paths"),
    [
        ("0", True),
        ("1", False),
    ],
    ids=["invalid-count", "missing-backup-paths"],
)
def test_backup_retention_invalid_configuration_fails_server_startup(
    tmp_path: Path,
    retention_count: str,
    configure_backup_paths: bool,
) -> None:
    executable = _server_binary()
    case_root = tmp_path / "startup-validation"
    data_dir = case_root / "data"
    _private_dir(case_root)
    _private_dir(data_dir)

    env = {
        key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")
    }
    env.update(
        {
            "ATERMIUS_BIND": f"127.0.0.1:{_free_port()}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{data_dir / 'atermius.db'}?mode=rwc",
            "ATERMIUS_BACKUP_RETENTION_COUNT": retention_count,
            "ATERMIUS_RELAY_ENABLED": "false",
        }
    )
    if configure_backup_paths:
        archive_dir = case_root / "archives"
        _private_dir(archive_dir)
        key_file = case_root / "operator.key"
        key_file.write_bytes(os.urandom(32))
        if os.name == "posix":
            key_file.chmod(0o600)
        env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(archive_dir)
        env["ATERMIUS_BACKUP_KEY_FILE"] = str(key_file)

    result = subprocess.run(
        [str(executable), "serve"],
        cwd=Path(__file__).resolve().parents[1],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    diagnostic = result.stdout + "\n" + result.stderr
    assert result.returncode != 0, "server started with an invalid retention configuration"
    assert 'code: "INTERNAL"' in diagnostic, "server did not report a startup configuration failure"

    # Server startup intentionally hides internal configuration details.
    # Prove this isolated data dir and all unrelated settings can start by
    # correcting only the retention policy (and its required paths for the
    # missing-path case).
    env["ATERMIUS_BIND"] = f"127.0.0.1:{_free_port()}"
    env["ATERMIUS_BACKUP_RETENTION_COUNT"] = "1"
    if not configure_backup_paths:
        archive_dir = case_root / "archives"
        _private_dir(archive_dir)
        key_file = case_root / "operator.key"
        key_file.write_bytes(os.urandom(32))
        if os.name == "posix":
            key_file.chmod(0o600)
        env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(archive_dir)
        env["ATERMIUS_BACKUP_KEY_FILE"] = str(key_file)

    base_url = f"http://{env['ATERMIUS_BIND']}"
    process, log_handle, client = _start_server(
        executable, env, base_url, case_root / "valid-control.log"
    )
    try:
        assert client.request("GET", "/health/ready").status == 200
    finally:
        _stop_server(process)
        log_handle.close()


def test_admin_maintenance_keeps_newest_configured_server_backups_and_protects_cli_archives(
    api, account, tmp_path: Path
) -> None:
    if not api.server_env or not api.admin_env or not api.temp_root:
        pytest.skip("backup retention acceptance needs the suite-owned disposable server")
    if not api.backup_key_file:
        pytest.fail("managed integration server has no operator backup key")

    setting_names = (
        "ATERMIUS_BACKUP_ARCHIVE_DIR",
        "ATERMIUS_BACKUP_RETENTION_COUNT",
    )
    original_server_settings = {
        name: api.server_env.get(name) for name in setting_names
    }
    original_admin_settings = {name: api.admin_env.get(name) for name in setting_names}
    archive_dir = tmp_path / "retention-archives"
    _private_dir(archive_dir)

    def restore_server_configuration() -> None:
        for environment, settings in (
            (api.server_env, original_server_settings),
            (api.admin_env, original_admin_settings),
        ):
            for name, value in settings.items():
                if value is None:
                    environment.pop(name, None)
                else:
                    environment[name] = value
        api.backup_archive_dir = Path(original_server_settings["ATERMIUS_BACKUP_ARCHIVE_DIR"])

    api.server_env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(archive_dir)
    api.server_env["ATERMIUS_BACKUP_RETENTION_COUNT"] = "2"
    api.admin_env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(archive_dir)
    api.admin_env["ATERMIUS_BACKUP_RETENTION_COUNT"] = "2"
    api.backup_archive_dir = archive_dir

    api.stop_managed_server()
    try:
        api.start_managed_server()

        server_archives: list[Path] = []
        server_job_ids: list[str] = []
        for _ in range(4):
            response = api.request(
                "POST",
                "/api/v1/admin/jobs",
                token=account["access_token"],
                json_body={"request_id": str(uuid.uuid4()), "action": "backup"},
            )
            assert response.status == 202, f"backup job rejected: {response.status} {response.json()}"
            job = response.json()["job"]
            terminal = _wait_for_terminal_job(api, account["access_token"], job["job_id"])
            assert terminal["status"] == "succeeded"
            assert terminal["result_code"] == "completed"
            matches = list(archive_dir.glob(f"*{job['job_id']}*.atb"))
            assert len(matches) == 1, "successful admin backup did not produce one archive"
            assert matches[0].is_file() and matches[0].stat().st_size > 0
            server_archives.append(matches[0])
            server_job_ids.append(job["job_id"])

        # Make a genuine operator CLI archive with a name that otherwise fits
        # the server naming pattern. Its UUID has no durable admin-job row.
        cli_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)
        timestamp = now.strftime("%Y%m%dT%H%M%S.") + f"{now.microsecond // 1000:03d}Z"
        cli_archive = archive_dir / f"atermius-backup-{timestamp}-{cli_id}.atb"
        cli_backup = _run_cli(
            _server_binary(),
            api.admin_env,
            "backup",
            "--archive",
            str(cli_archive),
            "--key-file",
            api.backup_key_file,
        )
        assert cli_backup.returncode == 0, (
            "operator CLI backup failed: " + (cli_backup.stdout + cli_backup.stderr)[-3000:]
        )
        assert cli_archive.is_file() and cli_archive.stat().st_size > 0

        unrelated_archive = archive_dir / "operator-kept.atb"
        unrelated_archive.write_bytes(b"operator-owned fixture archive")
        if os.name == "posix":
            unrelated_archive.chmod(0o600)

        symlink_target = tmp_path / "symlink-target.atb"
        symlink_target.write_bytes(b"leave this target unchanged")
        symlink_archive: Path | None = None
        if hasattr(os, "symlink"):
            symlink_archive = archive_dir / (
                f"atermius-backup-{timestamp}-{server_job_ids[0]}.atb"
            )
            symlink_archive.symlink_to(symlink_target)

        # The timestamp in each server file is fixed-width UTC. Lexical order
        # therefore matches the retention ordering, including same-ms ties.
        expected_retained = {path.name for path in sorted(server_archives, key=lambda p: p.name)[-2:]}
        maintenance = api.request(
            "POST",
            "/api/v1/admin/jobs",
            token=account["access_token"],
            json_body={"request_id": str(uuid.uuid4()), "action": "maintenance"},
        )
        assert maintenance.status == 202, (
            f"maintenance job rejected: {maintenance.status} {maintenance.json()}"
        )
        maintenance_job = maintenance.json()["job"]
        terminal = _wait_for_terminal_job(
            api, account["access_token"], maintenance_job["job_id"]
        )
        assert terminal["status"] == "succeeded"
        assert terminal["result_code"] == "completed"

        remaining_server_archives = {path.name for path in server_archives if path.exists()}
        assert remaining_server_archives == expected_retained
        assert cli_archive.is_file(), "maintenance pruned an operator-created CLI archive"
        assert unrelated_archive.is_file(), "maintenance pruned an unrelated operator archive"
        if symlink_archive is not None:
            assert symlink_archive.is_symlink(), "maintenance replaced or pruned a matching symlink"
            assert symlink_target.read_bytes() == b"leave this target unchanged"
    finally:
        api.stop_managed_server()
        restore_server_configuration()
        api.start_managed_server()
