"""Real Compose named-volume backup/restore drill for the deployable image."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import socket
import subprocess
import time
import uuid
from pathlib import Path

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url, redact_secrets
from test_acceptance import _new_account_registration
from test_backup_cli import (
    _envelope_digest,
    _error_code,
    _signed_opaque_record,
    _upload_opaque_object,
)


COMPOSE_FILE = ROOT / "deploy" / "compose.yaml"
SERVICE_UID = 10001


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _compose(
    project: str,
    env_file: Path,
    env: dict[str, str],
    *args: str,
    extra_files: tuple[Path, ...] = (),
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    command = [
        "docker",
        "compose",
        "--project-name",
        project,
        "--env-file",
        str(env_file),
        "--file",
        str(COMPOSE_FILE),
    ]
    for path in extra_files:
        command.extend(("--file", str(path)))
    command.extend(args)
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _diagnostic(result: subprocess.CompletedProcess[str], *secrets: str) -> str:
    return redact_secrets(result.stdout + "\n" + result.stderr, *secrets)[-5000:]


def _prepare_private_mount(path: Path) -> None:
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    try:
        os.chown(path, SERVICE_UID, SERVICE_UID)
    except PermissionError:
        pytest.skip(
            "Compose backup acceptance needs permission to provision private host mounts "
            "for the image's UID 10001"
        )


def _wait_ready(api: ApiClient, project: str, env_file: Path, env: dict[str, str], *, extra_files: tuple[Path, ...] = ()) -> None:
    deadline = time.monotonic() + 180
    last_status: int | None = None
    while time.monotonic() < deadline:
        try:
            response = api.request("GET", "/health/ready")
            last_status = response.status
            if last_status == 200:
                return
        except OSError:
            pass
        time.sleep(0.25)
    logs = _compose(project, env_file, env, "logs", "--no-color", "server", extra_files=extra_files)
    raise AssertionError(
        "Compose server did not become ready within 180 seconds; "
        f"last HTTP status={last_status}\n{_diagnostic(logs)}"
    )


def _compose_available() -> None:
    if not shutil.which("docker"):
        pytest.skip("Docker Compose backup acceptance requires the docker CLI")
    try:
        info = subprocess.run(
            ["docker", "info", "--format", "{{.ServerVersion}}"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        compose = subprocess.run(
            ["docker", "compose", "version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pytest.skip("Docker Engine or Compose is unavailable")
    if info.returncode != 0 or compose.returncode != 0:
        pytest.skip("Docker Engine or Compose is unavailable")


def _exact_volume_names() -> set[str]:
    result = subprocess.run(
        ["docker", "volume", "ls", "--quiet"],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, "could not inspect Docker named volumes: " + result.stderr[-2000:]
    return set(result.stdout.splitlines())


def test_compose_named_volume_backup_restores_opaque_data_and_revokes_old_sessions(
    tmp_path: Path,
) -> None:
    """BACKUP-COMPOSE: exercise source and restored data through real named volumes."""
    _compose_available()
    if os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() not in (0, SERVICE_UID):
        pytest.skip("private backup mounts must be readable by the image's UID 10001")

    instance_tag = uuid.uuid4().hex
    project = f"atermius-backup-{instance_tag[:20]}"
    source_volume = f"{project}-source"
    target_volume = f"{project}-restore"
    preexisting = _exact_volume_names()
    assert source_volume not in preexisting and target_volume not in preexisting

    env_file = tmp_path / "compose.env"
    env_file.write_text("", encoding="utf-8")
    os.chmod(env_file, 0o600)
    archive_dir = tmp_path / "external-archive"
    key_dir = tmp_path / "external-operator-key"
    _prepare_private_mount(archive_dir)
    _prepare_private_mount(key_dir)
    key_path = key_dir / "operator-backup.key"
    key_bytes = os.urandom(32)
    key_path.write_bytes(key_bytes)
    os.chmod(key_path, 0o600)
    os.chown(key_path, SERVICE_UID, SERVICE_UID)
    archive_path = archive_dir / "instance.atb"
    key_b64 = b64url(key_bytes)
    corrupted_archive_path = archive_dir / "instance-corrupted.atb"
    failure_marker = f"compose-rollback-control-{uuid.uuid4().hex}"

    prebuilt_image = os.environ.get("ATERMIUS_COMPOSE_TEST_IMAGE")
    base_env = {
        key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")
    }
    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    source_env = {
        **base_env,
        "ATERMIUS_HOST_PORT": str(port),
        "ATERMIUS_DATA_VOLUME_NAME": source_volume,
        "ATERMIUS_PUBLIC_ORIGIN": base_url,
    }
    image_files: tuple[Path, ...] = ()
    if prebuilt_image:
        source_env["ATERMIUS_IMAGE"] = prebuilt_image
        image_override = tmp_path / "test-image.compose.yaml"
        image_override.write_text(
            "services:\n"
            "  server:\n"
            '    image: "${ATERMIUS_IMAGE}"\n',
            encoding="utf-8",
        )
        os.chmod(image_override, 0o600)
        image_files = (image_override,)
    target_env = {**source_env, "ATERMIUS_DATA_VOLUME_NAME": target_volume}
    target_override = tmp_path / "restore-service.compose.yaml"
    target_override.write_text(
        "services:\n"
        "  server:\n"
        "    environment:\n"
        '      ATERMIUS_DATA_DIR: "/data/restored"\n'
        '      ATERMIUS_DATABASE_URL: "sqlite:///data/restored/atermius.db?mode=rwc"\n',
        encoding="utf-8",
    )
    os.chmod(target_override, 0o600)
    target_files = (target_override,)

    def compose(
        env: dict[str, str],
        *args: str,
        extra_files: tuple[Path, ...] = (),
        timeout: int = 180,
    ) -> subprocess.CompletedProcess[str]:
        return _compose(
            project,
            env_file,
            env,
            *args,
            extra_files=(*image_files, *extra_files),
            timeout=timeout,
        )

    def wait_ready(api: ApiClient, env: dict[str, str], *, restored: bool = False) -> None:
        additional = target_files if restored else ()
        _wait_ready(
            api,
            project,
            env_file,
            env,
            extra_files=(*image_files, *additional),
        )

    def restore_archive(filename: str) -> subprocess.CompletedProcess[str]:
        return compose(
            target_env,
            "run",
            "--rm",
            "--no-deps",
            "--env",
            "ATERMIUS_DATA_DIR=/source",
            "--env",
            "ATERMIUS_DATABASE_URL=sqlite:///source/atermius.db?mode=rwc",
            "--volume",
            f"{source_volume}:/source",
            "--volume",
            f"{archive_dir}:/backups:ro",
            "--volume",
            f"{key_dir}:/backup-key:ro",
            "server",
            "restore",
            "--archive",
            f"/backups/{filename}",
            "--key-file",
            "/backup-key/operator-backup.key",
            "--target-data-dir",
            "/data/restored",
            "--server-stopped",
        )

    def target_volume_shell(script: str) -> subprocess.CompletedProcess[str]:
        return compose(
            target_env,
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "/bin/sh",
            "server",
            "-ec",
            script,
        )

    def assert_original_source_intact(stage: str) -> None:
        assert source_api.request("GET", "/health/ready").status == 200, (
            f"source service was not ready {stage}"
        )
        instance_response = source_api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200, f"source instance could not be read {stage}"
        instance = instance_response.json()
        assert instance["instance_id"] == before_instance["instance_id"]
        assert instance["server_space_id"] == before_instance["server_space_id"]
        assert instance["generation"] == before_instance["generation"], (
            f"source generation changed {stage}"
        )
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200, (
            f"source session was not preserved {stage}"
        )
        changes = source_api.request(
            "GET", f"/api/v1/vaults/{vault_id}/changes?limit=100", token=old_access
        )
        assert changes.status == 200, f"source Vault was not readable {stage}"
        matching = [
            event
            for event in changes.json().get("events", [])
            if event.get("record_id") == record_id
            and event.get("revision_id") == revision_id
        ]
        assert len(matching) == 1, f"source Vault envelope was lost or duplicated {stage}"
        assert matching[0].get("envelope") == envelope, (
            f"source opaque Host envelope changed {stage}"
        )
        downloaded = source_api.request(
            "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=old_access
        )
        assert downloaded.status == 200 and downloaded.body == object_bytes, (
            f"source opaque object bytes changed {stage}"
        )

    secrets: list[str] = [key_b64]
    try:
        build_flag = "--no-build" if prebuilt_image else "--build"
        build = compose(
            source_env,
            "up",
            "--detach",
            build_flag,
            "server",
            timeout=1800,
        )
        startup_action = "start prebuilt image" if prebuilt_image else "build and start image"
        assert build.returncode == 0, f"Compose {startup_action} failed: " + _diagnostic(
            build, *secrets
        )

        source_api = ApiClient(base_url)
        wait_ready(source_api, source_env)
        bootstrap = compose(
            source_env,
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "bootstrap",
        )
        assert bootstrap.returncode == 0, "Compose bootstrap failed: " + _diagnostic(bootstrap, *secrets)
        match = re.search(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            bootstrap.stdout,
        )
        assert match, "bootstrap command did not print its one-time token"
        bootstrap_token = match.group(0)
        secrets.append(bootstrap_token)
        del bootstrap, match

        signer = SigningKey(tmp_path, "compose-backup-owner")
        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        username = f"compose-backup-{account_id[:8]}@example.test"
        registration = _new_account_registration(
            account_id,
            username,
            device_id,
            b64url(os.urandom(32)),
            signer,
        )
        registration["bootstrap_token"] = bootstrap_token
        registered = source_api.request("POST", "/api/v1/auth/register", json_body=registration)
        assert registered.status in (200, 201), (
            f"Compose registration failed: HTTP {registered.status} {_error_code(registered)}"
        )
        registered_body = registered.json()
        old_access = registered_body["access_token"]
        old_refresh = registered_body["refresh_token"]
        secrets.extend((old_access, old_refresh))
        before = source_api.request("GET", "/api/v1/instance")
        assert before.status == 200
        before_instance = before.json()
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200

        vault_id = registration["initial_vault"]["vault_id"]
        object_bytes = os.urandom(11_137)
        object_digest = hashlib.sha256(object_bytes).hexdigest()
        object_id = _upload_opaque_object(source_api, vault_id, old_access, object_bytes)
        envelope, record_id, revision_id = _signed_opaque_record(
            instance=before_instance,
            vault_id=vault_id,
            device_id=device_id,
            signer=signer,
            object_id=object_id,
        )
        envelope_digest = _envelope_digest(envelope)
        pushed = source_api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/sync/push",
            token=old_access,
            json_body={
                "protocol_version": before_instance.get("protocol_version", 1),
                "server_generation": before_instance["generation"],
                "vault_id": vault_id,
                "device_id": device_id,
                "batch_id": str(uuid.uuid4()),
                "operations": [envelope],
            },
        )
        assert pushed.status in (200, 201), (
            f"Compose opaque record push failed: HTTP {pushed.status} {_error_code(pushed)}"
        )
        assert pushed.json().get("results", [])[0].get("revision_id") == revision_id

        backup = compose(
            source_env,
            "run",
            "--rm",
            "--no-deps",
            "--volume",
            f"{archive_dir}:/backups",
            "--volume",
            f"{key_dir}:/backup-key:ro",
            "server",
            "backup",
            "--archive",
            "/backups/instance.atb",
            "--key-file",
            "/backup-key/operator-backup.key",
        )
        assert backup.returncode == 0, "Compose online backup failed: " + _diagnostic(backup, *secrets)
        assert archive_path.is_file() and archive_path.stat().st_size > 128
        assert archive_path.stat().st_mode & 0o777 == 0o600
        assert source_api.request("GET", "/health/ready").status == 200

        source_recreated = compose(
            source_env,
            "up",
            "--detach",
            "--no-build",
            "--force-recreate",
            "server",
        )
        assert source_recreated.returncode == 0, (
            "could not recreate source service on its original named volume: "
            + _diagnostic(source_recreated, *secrets)
        )
        wait_ready(source_api, source_env)
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200, (
            "source named volume did not preserve the pre-backup session after container recreation"
        )
        source_object = source_api.request(
            "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=old_access
        )
        assert source_object.status == 200 and source_object.body == object_bytes, (
            "source named volume did not preserve opaque object bytes after container recreation"
        )
        assert_original_source_intact("after source container recreation")

        # Keep a canary beside the not-yet-published restore target. A failed
        # offline restore must leave both that named volume and the source
        # volume usable before the operator changes the running service.
        seeded_target = target_volume_shell(
            "mkdir -p /data/rollback-control && "
            f"printf '%s' '{failure_marker}' > /data/rollback-control/canary && "
            "chmod 600 /data/rollback-control/canary && "
            "test ! -e /data/restored && "
            "cat /data/rollback-control/canary"
        )
        assert seeded_target.returncode == 0, (
            "could not seed target-volume rollback control: "
            + _diagnostic(seeded_target, *secrets)
        )
        assert seeded_target.stdout.strip().endswith(failure_marker)

        original_archive_digest = hashlib.sha256(archive_path.read_bytes()).digest()
        corrupted_bytes = bytearray(archive_path.read_bytes())
        assert len(corrupted_bytes) > 128
        corrupted_bytes[-1] ^= 0x80
        corrupted_archive_path.write_bytes(corrupted_bytes)
        os.chmod(corrupted_archive_path, 0o600)
        os.chown(corrupted_archive_path, SERVICE_UID, SERVICE_UID)
        assert hashlib.sha256(archive_path.read_bytes()).digest() == original_archive_digest

        stopped = compose(source_env, "stop", "--timeout", "15", "server")
        assert stopped.returncode == 0, "could not stop source service before restore: " + _diagnostic(
            stopped, *secrets
        )

        failed_restore = restore_archive(corrupted_archive_path.name)
        assert failed_restore.returncode != 0, "restore accepted a corrupted archive"
        assert hashlib.sha256(archive_path.read_bytes()).digest() == original_archive_digest, (
            "failed restore changed the valid source archive"
        )
        failed_target_check = target_volume_shell(
            f"test \"$(cat /data/rollback-control/canary)\" = '{failure_marker}' && "
            "test ! -e /data/restored && "
            "test \"$(ls -A /data)\" = rollback-control && "
            "printf '%s\\n' rollback-control-preserved"
        )
        assert failed_target_check.returncode == 0, (
            "failed restore changed the target named volume: "
            + _diagnostic(failed_target_check, *secrets)
        )

        source_restarted_after_failure = compose(
            source_env,
            "up",
            "--detach",
            "--no-build",
            "--force-recreate",
            "server",
        )
        assert source_restarted_after_failure.returncode == 0, (
            "source service could not be restarted after failed restore: "
            + _diagnostic(source_restarted_after_failure, *secrets)
        )
        wait_ready(source_api, source_env)
        assert_original_source_intact("after failed restore, before switching")

        stopped_again = compose(source_env, "stop", "--timeout", "15", "server")
        assert stopped_again.returncode == 0, (
            "could not stop source service before successful restore: "
            + _diagnostic(stopped_again, *secrets)
        )

        restore = restore_archive(archive_path.name)
        assert restore.returncode == 0, "Compose restore into target volume failed: " + _diagnostic(
            restore, *secrets
        )
        assert "new server generation" in restore.stdout.lower()

        restored_start = compose(
            target_env,
            "up",
            "--detach",
            "--no-build",
            "server",
            extra_files=target_files,
        )
        assert restored_start.returncode == 0, "restored Compose service failed to start: " + _diagnostic(
            restored_start, *secrets
        )

        restored_api = ApiClient(base_url)
        wait_ready(restored_api, target_env, restored=True)
        restored_instance_response = restored_api.request("GET", "/api/v1/instance")
        assert restored_instance_response.status == 200
        restored_instance = restored_instance_response.json()
        assert restored_instance["instance_id"] == before_instance["instance_id"]
        assert restored_instance["server_space_id"] == before_instance["server_space_id"]
        assert restored_instance["generation"] != before_instance["generation"]

        assert restored_api.request("GET", "/api/v1/me", token=old_access).status == 401
        old_refresh_result = restored_api.request(
            "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old_refresh}
        )
        assert old_refresh_result.status == 401, "restored target accepted a pre-backup refresh token"

        login = restored_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": username,
                "login_verifier": registration["login_verifier"],
                "device_id": device_id,
            },
        )
        assert login.status == 200, "restored Compose instance rejected a fresh account login"
        fresh_access = login.json()["access_token"]
        secrets.append(fresh_access)
        assert restored_api.request("GET", "/api/v1/me", token=fresh_access).status == 200
        assert any(vault.get("vault_id") == vault_id for vault in login.json().get("vaults", []))

        changes = restored_api.request(
            "GET", f"/api/v1/vaults/{vault_id}/changes?limit=100", token=fresh_access
        )
        assert changes.status == 200, (
            f"restored opaque record query failed: HTTP {changes.status} {_error_code(changes)}"
        )
        matching = [
            event
            for event in changes.json().get("events", [])
            if event.get("record_id") == record_id and event.get("revision_id") == revision_id
        ]
        assert len(matching) == 1, "restored Compose volume lost or duplicated the opaque record"
        restored_envelope = matching[0].get("envelope")
        assert _envelope_digest(restored_envelope) == envelope_digest, (
            "restored signed record envelope changed"
        )
        assert restored_envelope == envelope, "restored opaque Host envelope is not byte-for-byte equal"
        assert restored_envelope["header"].get("object_refs") == [object_id]

        downloaded = restored_api.request(
            "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=fresh_access
        )
        assert downloaded.status == 200, (
            f"restored opaque object download failed: HTTP {downloaded.status} {_error_code(downloaded)}"
        )
        assert downloaded.body == object_bytes, "restored opaque object bytes differ from source"
        assert hashlib.sha256(downloaded.body).hexdigest() == object_digest
        target_layout = target_volume_shell(
            "test -d /data/restored && "
            f"test \"$(cat /data/rollback-control/canary)\" = '{failure_marker}' && "
            "test \"$(ls -A /data | LC_ALL=C sort)\" = \"$(printf 'restored\\nrollback-control')\" && "
            "printf '%s\\n' target-restore-layout-preserved"
        )
        assert target_layout.returncode == 0, (
            "successful restore did not preserve the target-volume control data: "
            + _diagnostic(target_layout, *secrets)
        )

        stop_restored = compose(target_env, "stop", "--timeout", "15", "server", extra_files=target_files)
        assert stop_restored.returncode == 0, (
            "could not stop restored target before rollback: "
            + _diagnostic(stop_restored, *secrets)
        )
        source_rollback = compose(
            source_env,
            "up",
            "--detach",
            "--no-build",
            "--force-recreate",
            "server",
        )
        assert source_rollback.returncode == 0, (
            "could not switch Compose service back to the untouched source volume: "
            + _diagnostic(source_rollback, *secrets)
        )
        wait_ready(source_api, source_env)
        assert_original_source_intact("after rollback from the restored target")
    finally:
        cleanup_errors: list[str] = []
        try:
            down = compose(
                target_env,
                "down",
                "--remove-orphans",
                "--timeout",
                "15",
                extra_files=target_files,
                timeout=90,
            )
            if down.returncode != 0:
                cleanup_errors.append("Compose down failed: " + _diagnostic(down, *secrets))
        except (OSError, subprocess.TimeoutExpired) as error:
            cleanup_errors.append(f"Compose down could not complete: {error}")
        try:
            remaining = _exact_volume_names()
        except Exception as error:  # noqa: BLE001 - cleanup must report Docker failures
            cleanup_errors.append(f"could not inspect named volumes during cleanup: {error}")
            remaining = set()
        for volume in (source_volume, target_volume):
            if volume not in remaining:
                continue
            try:
                removed = subprocess.run(
                    ["docker", "volume", "rm", volume],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_errors.append(f"timed out removing test-owned volume {volume}: {error}")
                continue
            if removed.returncode != 0:
                cleanup_errors.append(
                    f"could not remove test-owned volume {volume}: {removed.stderr[-2000:]}"
                )
        if not cleanup_errors:
            remaining_after_cleanup = _exact_volume_names()
            leftovers = {source_volume, target_volume} & remaining_after_cleanup
            if leftovers:
                cleanup_errors.append(
                    "test-owned named volumes remain after cleanup: " + ", ".join(sorted(leftovers))
                )
        if not cleanup_errors:
            try:
                shutil.rmtree(tmp_path)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_errors.append(f"could not remove private test directory {tmp_path}: {error}")
        if cleanup_errors:
            raise AssertionError("Compose backup cleanup failed:\n" + "\n".join(cleanup_errors))
