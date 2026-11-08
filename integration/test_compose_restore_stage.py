"""Web-created restore-stage handoff through Compose cutover and rollback."""

from __future__ import annotations

import hashlib
import http.server
import json
import os
import re
import signal
import shutil
import stat
import subprocess
import threading
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url
from test_acceptance import _new_account_registration
from test_admin_restore_stage import (
    _archive_for,
    _catalog,
    _wait_for_backup,
    _wait_for_job,
)
from test_backup_cli import (
    _envelope_digest,
    _error_code,
    _signed_opaque_record,
    _upload_opaque_object,
)
from test_compose_backup_restore import (
    SERVICE_UID,
    _compose,
    _compose_available,
    _diagnostic,
    _exact_volume_names,
    _free_port,
    _prepare_private_mount,
    _wait_ready,
)


def _web_settings_restore_stage(
    tmp_path: Path,
    *,
    base_url: str,
    username: str,
    password: str,
    invitation_token: str,
    archive_id: str,
) -> str:
    """Create a stage through Web Settings and return only its opaque UUID."""
    input_path = tmp_path / "web-restore-stage-input.json"
    result_path = tmp_path / "web-restore-stage-result.json"
    request = {
        "base_url": base_url,
        "username": username,
        "password": password,
        "invitation_token": invitation_token,
        "archive_id": archive_id,
    }
    input_path.write_text(json.dumps(request, separators=(",", ":")), encoding="utf-8")
    os.chmod(input_path, 0o600)
    private_env = {
        key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")
    }
    private_env.update(
        {
            "WEB_RESTORE_STAGE_HANDOFF_INPUT": str(input_path),
            "WEB_RESTORE_STAGE_HANDOFF_OUTPUT": str(result_path),
        }
    )
    command = [
        "npm",
        "run",
        "test:admin-restore-cutover-handoff",
        "--prefix",
        str(ROOT / "integration" / "web"),
    ]
    try:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=private_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
                process.communicate()
            raise AssertionError("Web Settings restore-stage handoff exceeded its timeout")
        returncode = process.returncode
        safe_lines = [
            line
            for line in (stdout + "\n" + stderr).splitlines()
            if line.startswith(("stage:", "assert:", "failure:", "WEB-RESTORE-COMPOSE-HANDOFF-01"))
        ]
        assert returncode == 0, (
            "Web Settings restore-stage handoff failed with exit "
            f"{returncode}: " + "\n".join(safe_lines[-80:])
        )
        result_metadata = result_path.lstat()
        assert stat.S_ISREG(result_metadata.st_mode) and stat.S_IMODE(result_metadata.st_mode) == 0o600
        output = json.loads(result_path.read_text(encoding="utf-8"))
        assert isinstance(output, dict) and set(output) == {"restore_job_id"}
        restore_job_id = output["restore_job_id"]
        assert isinstance(restore_job_id, str) and re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            restore_job_id,
        )
        assert "WEB-RESTORE-COMPOSE-HANDOFF-01 passed" in stdout
        print("WEB-RESTORE-COMPOSE-HANDOFF-01 passed; private Stage ID handoff verified")
        return restore_job_id
    finally:
        input_path.unlink(missing_ok=True)
        result_path.unlink(missing_ok=True)


class _SourceGenerationHealthGate:
    """Expose readiness only while the original source generation is active."""

    def __init__(self, origin: str, generation: str) -> None:
        self.origin = origin
        self.generation = generation
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                if self.path not in ("/health/ready", "/api/v1/instance"):
                    self.send_error(404)
                    return
                try:
                    with urllib.request.urlopen(
                        owner.origin + "/api/v1/instance", timeout=0.5
                    ) as response:
                        identity = json.loads(response.read(64 * 1024))
                    if identity.get("generation") != owner.generation:
                        raise ValueError("source generation is no longer active")
                except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError):
                    self.send_response(503)
                    self.end_headers()
                    return

                body = (
                    json.dumps({"status": "ready"}).encode()
                    if self.path == "/health/ready"
                    else json.dumps(identity).encode()
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: object) -> None:
                return

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "_SourceGenerationHealthGate":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def _compose_yaml_string(value: str) -> str:
    """Quote a scalar as a JSON string, which is also valid YAML."""
    return json.dumps(value)


def _container_shell(
    project: str,
    env_file: Path,
    env: dict[str, str],
    script: str,
    *,
    extra_files: tuple[Path, ...],
) -> subprocess.CompletedProcess[str]:
    return _compose(
        project,
        env_file,
        env,
        "run",
        "--rm",
        "--no-deps",
        "--entrypoint",
        "/bin/sh",
        "server",
        "-ec",
        script,
        extra_files=extra_files,
    )


def _assert_opaque_data(
    api: ApiClient,
    token: str,
    *,
    vault_id: str,
    record_id: str,
    revision_id: str,
    envelope: dict,
    object_id: str,
    object_bytes: bytes,
    expected_digest: bytes,
    stage: str,
) -> None:
    changes = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/changes?limit=100", token=token
    )
    assert changes.status == 200, f"{stage} Vault changes failed: HTTP {changes.status}"
    matching = [
        event
        for event in changes.json().get("events", [])
        if event.get("record_id") == record_id
        and event.get("revision_id") == revision_id
    ]
    assert len(matching) == 1, f"{stage} lost or duplicated the opaque Vault envelope"
    restored_envelope = matching[0].get("envelope")
    assert restored_envelope == envelope, f"{stage} changed the opaque Vault envelope"
    assert _envelope_digest(restored_envelope) == expected_digest
    assert restored_envelope["header"].get("object_refs") == [object_id]

    downloaded = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/objects/{object_id}", token=token
    )
    assert downloaded.status == 200, f"{stage} opaque object download failed"
    assert downloaded.body == object_bytes, f"{stage} changed opaque object bytes"
    assert (
        hashlib.sha256(downloaded.body).hexdigest()
        == hashlib.sha256(object_bytes).hexdigest()
    )


def test_compose_admin_restore_stage_installs_new_volume_and_rolls_back_to_source(
    tmp_path: Path,
) -> None:
    """Exercise API staging, journaled Compose cutover and source rollback."""
    _compose_available()
    if (
        os.name == "posix"
        and hasattr(os, "geteuid")
        and os.geteuid() not in (0, SERVICE_UID)
    ):
        pytest.skip(
            "private restore-stage mounts must be writable by the image's UID 10001"
        )

    run_id = uuid.uuid4().hex
    project = f"atermius-stage-{run_id[:20]}"
    source_volume = f"{project}-source"
    target_volume = f"{project}-target"
    failed_target_volume = f"{project}-failed-target"
    preexisting_volumes = _exact_volume_names()
    assert source_volume not in preexisting_volumes
    assert target_volume not in preexisting_volumes
    assert failed_target_volume not in preexisting_volumes

    env_file = tmp_path / "compose.env"
    archive_dir = tmp_path / "external-archive"
    key_dir = tmp_path / "external-operator-key"
    _prepare_private_mount(archive_dir)
    _prepare_private_mount(key_dir)
    key_path = key_dir / "operator-backup.key"
    key_bytes = os.urandom(32)
    key_path.write_bytes(key_bytes)
    os.chmod(key_path, 0o600)
    os.chown(key_path, SERVICE_UID, SERVICE_UID)
    key_b64 = b64url(key_bytes)

    account_id = str(uuid.uuid4())
    username = f"compose-stage-{account_id[:8]}@example.test"
    web_admin_username = f"compose-web-stage-{account_id[:8]}@example.test"
    web_admin_password = "Compose-Web-" + os.urandom(32).hex()
    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    env_file.write_text(
        f"ATERMIUS_HOST_PORT={port}\n"
        f"ATERMIUS_DATA_VOLUME_NAME={source_volume}\n"
        "ATERMIUS_DATA_DIR=/data\n"
        "ATERMIUS_DATABASE_URL=sqlite:///data/atermius.db?mode=rwc\n"
        f"ATERMIUS_PUBLIC_ORIGIN={base_url}\n"
        f"ATERMIUS_ADMIN_USERNAMES={username},{web_admin_username}\n",
        encoding="utf-8",
    )
    os.chmod(env_file, 0o600)
    base_env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("ATERMIUS_")
    }
    source_env = {
        **base_env,
        "ATERMIUS_HOST_PORT": str(port),
        "ATERMIUS_DATA_VOLUME_NAME": source_volume,
        "ATERMIUS_PUBLIC_ORIGIN": base_url,
        "ATERMIUS_ADMIN_USERNAMES": f"{username},{web_admin_username}",
    }

    backup_override = tmp_path / "backup-settings.compose.yaml"
    backup_override.write_text(
        "services:\n"
        "  server:\n"
        "    environment:\n"
        '      ATERMIUS_BACKUP_ARCHIVE_DIR: "/backups"\n'
        '      ATERMIUS_BACKUP_KEY_FILE: "/backup-key/operator-backup.key"\n'
        "    volumes:\n"
        f"      - {_compose_yaml_string(str(archive_dir) + ':/backups')}\n"
        f"      - {_compose_yaml_string(str(key_dir) + ':/backup-key:ro')}\n",
        encoding="utf-8",
    )
    os.chmod(backup_override, 0o600)
    backup_files = (backup_override,)

    prebuilt_image = os.environ.get("ATERMIUS_COMPOSE_TEST_IMAGE")
    image_files: tuple[Path, ...] = ()
    cutover_env = dict(base_env)
    if prebuilt_image:
        source_env["ATERMIUS_IMAGE"] = prebuilt_image
        cutover_env["ATERMIUS_IMAGE"] = prebuilt_image
        image_override = tmp_path / "test-image.compose.yaml"
        image_override.write_text(
            "services:\n" "  server:\n" '    image: "${ATERMIUS_IMAGE}"\n',
            encoding="utf-8",
        )
        os.chmod(image_override, 0o600)
        image_files = (image_override,)

    target_env = {
        **source_env,
        "ATERMIUS_DATA_VOLUME_NAME": target_volume,
        "ATERMIUS_DATA_DIR": "/data/restored",
        "ATERMIUS_DATABASE_URL": "sqlite:///data/restored/atermius.db?mode=rwc",
    }
    failed_target_env = {
        **source_env,
        "ATERMIUS_DATA_VOLUME_NAME": failed_target_volume,
    }
    source_files = (*image_files, *backup_files)
    restored_files = source_files
    secrets = [key_b64]

    def compose(
        env: dict[str, str],
        *args: str,
        extra_files: tuple[Path, ...] = source_files,
        timeout: int = 180,
    ) -> subprocess.CompletedProcess[str]:
        return _compose(
            project,
            env_file,
            env,
            *args,
            extra_files=extra_files,
            timeout=timeout,
        )

    cutover_script = ROOT / "deploy" / "restore_cutover.py"

    def cutover(
        action: str,
        journal: Path,
        *,
        target: str | None = None,
        health_url: str | None = None,
        health_timeout: int | None = None,
        timeout: int = 900,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            "python3",
            str(cutover_script),
            action,
            "--journal",
            str(journal),
        ]
        if action == "apply":
            assert target is not None and health_url is not None
            command.extend(
                [
                    "--project-name",
                    project,
                    "--env-file",
                    str(env_file),
                    "--compose-file",
                    str(ROOT / "deploy" / "compose.yaml"),
                    "--restore-job-id",
                    accepted_restore_job_id,
                    "--target-volume",
                    target,
                    "--health-url",
                    health_url,
                ]
            )
            for compose_file in backup_files:
                command.extend(("--compose-file", str(compose_file)))
            for compose_file in image_files:
                command.extend(("--compose-file", str(compose_file)))
            if health_timeout is not None:
                command.extend(("--health-timeout-seconds", str(health_timeout)))
        return subprocess.run(
            command,
            cwd=ROOT,
            env=cutover_env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def wait_ready(
        api: ApiClient, env: dict[str, str], *, restored: bool = False
    ) -> None:
        _wait_ready(
            api,
            project,
            env_file,
            env,
            extra_files=restored_files if restored else source_files,
        )

    source_api = ApiClient(base_url)
    try:
        build_flag = "--no-build" if prebuilt_image else "--build"
        start = compose(
            source_env,
            "up",
            "--detach",
            build_flag,
            "server",
            timeout=1800,
        )
        assert start.returncode == 0, "Compose source startup failed: " + _diagnostic(
            start, *secrets
        )
        wait_ready(source_api, source_env)

        bootstrap = compose(
            source_env,
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "bootstrap",
        )
        assert bootstrap.returncode == 0, "Compose bootstrap failed: " + _diagnostic(
            bootstrap, *secrets
        )
        match = re.search(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            bootstrap.stdout,
        )
        assert match, "bootstrap command did not print its one-time token"
        bootstrap_token = match.group(0)
        secrets.append(bootstrap_token)

        signer = SigningKey(tmp_path, "compose-stage-owner")
        device_id = str(uuid.uuid4())
        registration = _new_account_registration(
            account_id,
            username,
            device_id,
            b64url(os.urandom(32)),
            signer,
        )
        registration["bootstrap_token"] = bootstrap_token
        registered = source_api.request(
            "POST", "/api/v1/auth/register", json_body=registration
        )
        assert registered.status in (
            200,
            201,
        ), f"Compose registration failed: HTTP {registered.status} {_error_code(registered)}"
        credentials = registered.json()
        old_access = credentials["access_token"]
        old_refresh = credentials["refresh_token"]
        secrets.extend((old_access, old_refresh, registration["login_verifier"]))

        original_instance_response = source_api.request("GET", "/api/v1/instance")
        assert original_instance_response.status == 200
        original_instance = original_instance_response.json()
        original_generation = original_instance["generation"]
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200

        vault_id = registration["initial_vault"]["vault_id"]
        object_bytes = os.urandom(11_137)
        object_id = _upload_opaque_object(
            source_api, vault_id, old_access, object_bytes
        )
        envelope, record_id, revision_id = _signed_opaque_record(
            instance=original_instance,
            vault_id=vault_id,
            device_id=device_id,
            signer=signer,
            object_id=object_id,
        )
        pushed = source_api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/sync/push",
            token=old_access,
            json_body={
                "protocol_version": original_instance.get("protocol_version", 1),
                "server_generation": original_generation,
                "vault_id": vault_id,
                "device_id": device_id,
                "batch_id": str(uuid.uuid4()),
                "operations": [envelope],
            },
        )
        assert pushed.status in (
            200,
            201,
        ), f"Compose opaque record push failed: HTTP {pushed.status} {_error_code(pushed)}"
        assert pushed.json().get("results", [])[0].get("revision_id") == revision_id
        envelope_digest = _envelope_digest(envelope)

        backup = _wait_for_backup(source_api, old_access, str(uuid.uuid4()))
        archive = _archive_for(archive_dir, backup["job_id"])
        assert archive.is_file() and archive.stat().st_size > 128
        sources = _catalog(source_api, old_access)
        assert any(
            item["archive_id"] == backup["job_id"] for item in sources["sources"]
        )

        # Issue the temporary browser-admin invite after the backup snapshot so
        # cutover cannot restore it as a pending, reusable invitation.
        invite = compose(
            source_env,
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "create-account-invite",
            "--username",
            web_admin_username,
        )
        assert invite.returncode == 0, "Compose Web admin invitation failed"
        invite_tokens = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            invite.stdout,
        )
        assert len(invite_tokens) == 1, "Compose Web admin invitation token was unavailable"
        web_admin_invitation = invite_tokens[0]
        secrets.extend((web_admin_invitation, web_admin_password))

        accepted_restore_job_id = _web_settings_restore_stage(
            tmp_path,
            base_url=base_url,
            username=web_admin_username,
            password=web_admin_password,
            invitation_token=web_admin_invitation,
            archive_id=backup["job_id"],
        )
        terminal = _wait_for_job(source_api, old_access, accepted_restore_job_id)
        assert (
            terminal["status"] == "succeeded" and terminal["result_code"] == "completed"
        )
        assert terminal["restore_stage_status"] is None, (
            "an administrator other than the restore requester saw its owner-only stage status"
        )
        stage_path = archive_dir / "restore-staging" / f"atermius-restore-{accepted_restore_job_id}"
        assert stage_path.is_dir() and not stage_path.is_symlink()
        assert (
            source_api.request("GET", "/api/v1/instance").json()["generation"]
            == original_generation
        )
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200

        # Seed both destinations with unrelated data. The installer must create
        # only /restored, and neither rollback path may erase either volume.
        canary = f"restore-stage-rollback-control-{uuid.uuid4().hex}"
        for volume_env, label in (
            (target_env, "successful target"),
            (failed_target_env, "failed target"),
        ):
            seeded = _container_shell(
                project,
                env_file,
                volume_env,
                "mkdir -p /data/rollback-control && "
                f"printf '%s' '{canary}' > /data/rollback-control/canary && "
                "chmod 600 /data/rollback-control/canary && "
                "test ! -e /data/restored && "
                "cat /data/rollback-control/canary",
                extra_files=source_files,
            )
            assert seeded.returncode == 0, (
                f"could not initialize {label} volume: "
                + _diagnostic(seeded, *secrets)
            )
            assert seeded.stdout.strip().endswith(canary)

        failed_journal = tmp_path / "failed-restore-cutover.json"
        with _SourceGenerationHealthGate(base_url, original_generation) as health_gate:
            failed_cutover = cutover(
                "apply",
                failed_journal,
                target=failed_target_volume,
                health_url=health_gate.url,
                health_timeout=3,
                timeout=240,
            )
        assert failed_cutover.returncode != 0, (
            "restore cutover unexpectedly accepted a target without a health endpoint"
        )
        failed_status = cutover("status", failed_journal)
        assert failed_status.returncode == 0, (
            "failure-path apply did not leave a readable journal: "
            + _diagnostic(failed_cutover, *secrets)
            + "; status: "
            + _diagnostic(failed_status, *secrets)
        )
        failed_record = json.loads(failed_status.stdout)
        assert failed_record["state"] == "rolled_back"
        assert "health" in str(failed_record["last_error_code"]).lower()
        assert failed_record["source_volume"] == source_volume
        assert failed_record["target_volume"] == failed_target_volume
        assert stat.S_IMODE(failed_journal.stat().st_mode) == 0o600
        env_values = {
            line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in env_file.read_text(encoding="utf-8").splitlines()
            if "=" in line and not line.lstrip().startswith("#")
        }
        assert env_values["ATERMIUS_DATA_VOLUME_NAME"] == source_volume
        assert env_values["ATERMIUS_DATA_DIR"] == "/data"
        assert env_values["ATERMIUS_DATABASE_URL"] == "sqlite:///data/atermius.db?mode=rwc"

        wait_ready(source_api, source_env)
        source_after_failed_cutover = source_api.request("GET", "/api/v1/instance")
        assert source_after_failed_cutover.status == 200
        assert source_after_failed_cutover.json()["generation"] == original_generation
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200
        _assert_opaque_data(
            source_api,
            old_access,
            vault_id=vault_id,
            record_id=record_id,
            revision_id=revision_id,
            envelope=envelope,
            object_id=object_id,
            object_bytes=object_bytes,
            expected_digest=envelope_digest,
            stage="source after automatic rollback",
        )
        failed_target_layout = _container_shell(
            project,
            env_file,
            failed_target_env,
            "test -d /data/restored && "
            f"test \"$(cat /data/rollback-control/canary)\" = '{canary}' && "
            "printf '%s\n' failed-target-volume-retained",
            extra_files=source_files,
        )
        assert failed_target_layout.returncode == 0, (
            "automatic rollback removed or changed target volume data: "
            + _diagnostic(failed_target_layout, *secrets)
        )

        journal = tmp_path / "successful-restore-cutover.json"
        applied = cutover(
            "apply",
            journal,
            target=target_volume,
            health_url=base_url,
            timeout=900,
        )
        assert applied.returncode == 0, (
            "journaled Compose restore cutover failed: " + _diagnostic(applied, *secrets)
        )
        applied_record = json.loads(applied.stdout)
        assert applied_record["state"] == "committed"
        installed_generation = applied_record["installed_generation"]
        assert str(uuid.UUID(installed_generation)) == installed_generation
        status = cutover("status", journal)
        assert status.returncode == 0, _diagnostic(status, *secrets)
        assert json.loads(status.stdout)["state"] == "committed"
        assert stat.S_IMODE(journal.stat().st_mode) == 0o600
        env_values = {
            line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in env_file.read_text(encoding="utf-8").splitlines()
            if "=" in line and not line.lstrip().startswith("#")
        }
        assert env_values["ATERMIUS_DATA_VOLUME_NAME"] == target_volume
        assert env_values["ATERMIUS_DATA_DIR"] == "/data/restored"
        assert env_values["ATERMIUS_DATABASE_URL"] == (
            "sqlite:///data/restored/atermius.db?mode=rwc"
        )

        target_layout = _container_shell(
            project,
            env_file,
            target_env,
            "test -d /data/restored && "
            "test \"$(stat -c '%u:%a' /data/restored)\" = '10001:700' && "
            "test \"$(stat -c '%u:%a' /data/restored/atermius.db)\" = '10001:600' && "
            f"test \"$(cat /data/rollback-control/canary)\" = '{canary}' && "
            'test "$(ls -A /data | LC_ALL=C sort)" = '
            "\"$(printf 'restored\\nrollback-control')\" && "
            "printf '%s\\n' target-install-layout-preserved",
            extra_files=restored_files,
        )
        assert target_layout.returncode == 0, (
            "installation changed target-volume rollback control: "
            + _diagnostic(target_layout, *secrets)
        )

        target_api = ApiClient(base_url)
        wait_ready(target_api, target_env, restored=True)
        restored_instance_response = target_api.request("GET", "/api/v1/instance")
        assert restored_instance_response.status == 200
        restored_instance = restored_instance_response.json()
        assert restored_instance["instance_id"] == original_instance["instance_id"]
        assert restored_instance["server_space_id"] == original_instance["server_space_id"]
        assert restored_instance["generation"] != original_generation
        assert restored_instance["generation"] == installed_generation
        assert target_api.request("GET", "/api/v1/me", token=old_access).status == 401
        old_refresh_response = target_api.request(
            "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old_refresh}
        )
        assert old_refresh_response.status == 401, "target accepted the source refresh credential"

        fresh_login = target_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": username,
                "login_verifier": registration["login_verifier"],
                "device_id": device_id,
            },
        )
        assert fresh_login.status == 200, (
            f"target rejected a fresh login: HTTP {fresh_login.status} {_error_code(fresh_login)}"
        )
        fresh_access = fresh_login.json()["access_token"]
        secrets.append(fresh_access)
        assert target_api.request("GET", "/api/v1/me", token=fresh_access).status == 200
        _assert_opaque_data(
            target_api,
            fresh_access,
            vault_id=vault_id,
            record_id=record_id,
            revision_id=revision_id,
            envelope=envelope,
            object_id=object_id,
            object_bytes=object_bytes,
            expected_digest=envelope_digest,
            stage="installed target",
        )

        rolled_back = cutover("rollback", journal)
        assert rolled_back.returncode == 0, (
            "explicit Compose restore rollback failed: " + _diagnostic(rolled_back, *secrets)
        )
        assert json.loads(rolled_back.stdout)["state"] == "rolled_back"
        env_values = {
            line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in env_file.read_text(encoding="utf-8").splitlines()
            if "=" in line and not line.lstrip().startswith("#")
        }
        assert env_values["ATERMIUS_DATA_VOLUME_NAME"] == source_volume
        assert env_values["ATERMIUS_DATA_DIR"] == "/data"
        assert env_values["ATERMIUS_DATABASE_URL"] == "sqlite:///data/atermius.db?mode=rwc"
        wait_ready(source_api, source_env)
        rollback_instance_response = source_api.request("GET", "/api/v1/instance")
        assert rollback_instance_response.status == 200
        assert rollback_instance_response.json()["generation"] == original_generation
        assert source_api.request("GET", "/api/v1/me", token=old_access).status == 200
        _assert_opaque_data(
            source_api,
            old_access,
            vault_id=vault_id,
            record_id=record_id,
            revision_id=revision_id,
            envelope=envelope,
            object_id=object_id,
            object_bytes=object_bytes,
            expected_digest=envelope_digest,
            stage="rolled-back source",
        )

    finally:
        cleanup_errors: list[str] = []
        try:
            down = compose(
                target_env,
                "down",
                "--volumes",
                "--remove-orphans",
                "--timeout",
                "15",
                extra_files=restored_files,
                timeout=90,
            )
            if down.returncode != 0:
                cleanup_errors.append(
                    "Compose down failed: " + _diagnostic(down, *secrets)
                )
        except (OSError, subprocess.TimeoutExpired) as error:
            cleanup_errors.append(f"Compose down could not complete: {error}")

        try:
            remaining_volumes = _exact_volume_names()
        except (
            Exception
        ) as error:  # noqa: BLE001 - cleanup must surface Docker failures
            cleanup_errors.append(
                f"could not inspect Docker volumes during cleanup: {error}"
            )
            remaining_volumes = set()
        for volume in (source_volume, target_volume, failed_target_volume):
            if volume not in remaining_volumes:
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
                cleanup_errors.append(f"could not remove test volume {volume}: {error}")
                continue
            if removed.returncode != 0:
                cleanup_errors.append(
                    f"could not remove test volume {volume}: {removed.stderr[-2000:]}"
                )

        try:
            leftovers = {
                source_volume,
                target_volume,
                failed_target_volume,
            } & _exact_volume_names()
            if leftovers:
                cleanup_errors.append(
                    "test volumes remain: " + ", ".join(sorted(leftovers))
                )
        except (
            Exception
        ) as error:  # noqa: BLE001 - cleanup must surface Docker failures
            cleanup_errors.append(f"could not verify volume cleanup: {error}")

        try:
            shutil.rmtree(tmp_path)
        except FileNotFoundError:
            pass
        except OSError as error:
            cleanup_errors.append(
                f"could not remove private test directory {tmp_path}: {error}"
            )

        if cleanup_errors:
            raise AssertionError(
                "Compose restore-stage cleanup failed:\n" + "\n".join(cleanup_errors)
            )
