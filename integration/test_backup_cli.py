"""CLI backup/restore smoke against isolated, throwaway SQLite instances."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import IO, Any

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url, jcs, redact_secrets, server_binary_path
from test_acceptance import _new_account_registration


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _server_binary() -> Path:
    executable = server_binary_path()
    if executable.is_file() and not shutil.which("cargo"):
        return executable
    cargo = shutil.which("cargo")
    if not cargo:
        pytest.skip("CLI backup acceptance requires cargo to build the server binary")
    result = subprocess.run(
        [cargo, "build", "--locked", "--manifest-path", str(ROOT / "server" / "Cargo.toml")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    assert result.returncode == 0, "server debug build failed: " + (result.stderr[-4000:])
    assert executable.is_file(), "cargo build did not produce the server CLI binary"
    return executable


def _isolated_env(data_dir: Path, port: int) -> dict[str, str]:
    # Do not inherit a developer's Atermius paths or credentials. Every CLI
    # command in this test is pinned to this test's private temporary SQLite DB.
    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    base_url = f"http://127.0.0.1:{port}"
    env.update(
        {
            "ATERMIUS_BIND": urllib.parse.urlparse(base_url).netloc,
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{data_dir / 'atermius.db'}?mode=rwc",
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "false",
            "ATERMIUS_PUBLIC_ORIGIN": base_url,
        }
    )
    return env


def _stop_server(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (AttributeError, ProcessLookupError):
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def _start_server(
    executable: Path,
    env: dict[str, str],
    base_url: str,
    log_path: Path,
    *secrets: str,
) -> tuple[subprocess.Popen[bytes], IO[bytes], ApiClient]:
    log_handle = log_path.open("wb")
    process = subprocess.Popen(
        [str(executable), "serve"],
        cwd=ROOT,
        env=env,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    api = ApiClient(base_url)
    deadline = time.monotonic() + 45
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError(f"temporary server exited with status {process.returncode}")
            try:
                ready = api.request("GET", "/health/ready")
                if ready.status == 200:
                    return process, log_handle, api
            except OSError:
                pass
            time.sleep(0.2)
        raise AssertionError("temporary server did not become ready within 45 seconds")
    except Exception as error:
        _stop_server(process)
        log_handle.close()
        detail = redact_secrets(log_path.read_text(errors="replace"), *secrets)[-4000:]
        raise AssertionError(f"temporary server startup failed: {error}\n{detail}") from error


def _run_cli(
    executable: Path, env: dict[str, str], *args: str
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(executable), *args],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _cli_error(result: subprocess.CompletedProcess[str], *secrets: str) -> str:
    return redact_secrets(result.stdout + "\n" + result.stderr, *secrets)[-4000:]


def _tree_snapshot(root: Path) -> dict[str, tuple[str, int]]:
    snapshot: dict[str, tuple[str, int]] = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            snapshot[relative] = ("symlink:" + os.readlink(path), path.lstat().st_mode)
        elif path.is_file():
            snapshot[relative] = (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode)
        elif path.is_dir():
            snapshot[relative] = ("directory", path.stat().st_mode)
    return snapshot


def _verify_cli(
    executable: Path,
    env: dict[str, str],
    data_dir: Path,
    archive: Path,
    key_file: Path,
    key_b64: str,
) -> subprocess.CompletedProcess[str]:
    before_tree = _tree_snapshot(data_dir)
    before_archive = hashlib.sha256(archive.read_bytes()).digest()
    temp_root = Path(tempfile.gettempdir())
    before_staging = set(temp_root.glob(".atermius-backup-verify-*"))
    result = _run_cli(
        executable,
        env,
        "verify-backup",
        "--archive",
        str(archive),
        "--key-file",
        str(key_file),
    )
    output = result.stdout + "\n" + result.stderr
    assert key_b64 not in output, "backup verifier leaked the operator key"
    assert _tree_snapshot(data_dir) == before_tree, "backup verifier changed the active instance"
    assert hashlib.sha256(archive.read_bytes()).digest() == before_archive, (
        "backup verifier changed its archive"
    )
    assert set(temp_root.glob(".atermius-backup-verify-*")) == before_staging, (
        "backup verifier left temporary plaintext staging behind"
    )
    return result


def _error_code(response: Any) -> str | None:
    body = response.json()
    if not isinstance(body, dict):
        return None
    error = body.get("error")
    return error.get("code") if isinstance(error, dict) else None


def _upload_opaque_object(
    api: ApiClient, vault_id: str, token: str, content: bytes
) -> str:
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=token,
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    assert initialized.status in (200, 201), (
        f"opaque object reservation failed: HTTP {initialized.status} "
        f"{_error_code(initialized)}"
    )
    upload_id = initialized.json()["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=token,
        raw_body=content,
        content_type="application/octet-stream",
    )
    assert chunk.status in (200, 201), (
        f"opaque object chunk upload failed: HTTP {chunk.status} {_error_code(chunk)}"
    )
    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=token,
        json_body={},
    )
    assert completed.status in (200, 201), (
        f"opaque object completion failed: HTTP {completed.status} "
        f"{_error_code(completed)}"
    )
    return object_id


def _signed_opaque_record(
    *,
    instance: dict[str, Any],
    vault_id: str,
    device_id: str,
    signer: SigningKey,
    object_id: str,
    device_seq: str = "1",
    key_epoch: str = "1",
    membership_version: str = "1",
) -> tuple[dict[str, Any], str, str]:
    record_id = str(uuid.uuid4())
    revision_id = str(uuid.uuid4())
    header = {
        "wire_version": 1,
        "server_space_id": instance["server_space_id"],
        "vault_id": vault_id,
        "record_id": record_id,
        "revision_id": revision_id,
        "base_revision_id": None,
        "op_id": str(uuid.uuid4()),
        "device_id": device_id,
        "device_seq": device_seq,
        "key_epoch": key_epoch,
        "membership_version": membership_version,
        "record_schema": 1,
        "operation": "create",
        "crypto_suite": "atermius-vault-v1",
        "kdf_salt": b64url(os.urandom(32)),
        "object_refs": [object_id],
    }
    signed = {
        "header": header,
        "nonce": b64url(os.urandom(24)),
        # Synthetic opaque ciphertext; the test intentionally has no key to
        # decrypt or interpret it.
        "ciphertext": b64url(os.urandom(96)),
    }
    envelope = {**signed, "signature": b64url(signer.sign(jcs(signed)))}
    return envelope, record_id, revision_id


def _envelope_digest(envelope: Any) -> bytes:
    return hashlib.sha256(jcs(envelope)).digest()


def test_online_backup_fail_closed_restore_rotates_generation_and_revokes_old_sessions(
    tmp_path: Path,
) -> None:
    """BACKUP-CLI: online backup, rejected restores, then isolated restore/startup."""
    executable = _server_binary()
    active_data = tmp_path / "active-data"
    active_data.mkdir(mode=0o700)
    os.chmod(active_data, 0o700)
    active_port = _free_port()
    active_url = f"http://127.0.0.1:{active_port}"
    active_env = _isolated_env(active_data, active_port)

    # Both operator secrets and the archive live beside, never inside, the
    # active instance directory. The external backup key is exactly 32 bytes.
    key_path = tmp_path / "operator-backup.key"
    key_bytes = os.urandom(32)
    key_path.write_bytes(key_bytes)
    os.chmod(key_path, 0o600)
    key_b64 = b64url(key_bytes)
    wrong_key_path = tmp_path / "wrong-backup.key"
    wrong_key_path.write_bytes(os.urandom(32))
    os.chmod(wrong_key_path, 0o600)
    archive = tmp_path / "online-instance.atb"

    bootstrap = _run_cli(executable, active_env, "bootstrap")
    assert bootstrap.returncode == 0, "isolated bootstrap CLI failed: " + _cli_error(bootstrap)
    match = re.search(
        r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
        bootstrap.stdout,
    )
    assert match, "bootstrap CLI did not print its one-time token"
    bootstrap_token = match.group(0)
    del bootstrap, match

    active_process: subprocess.Popen[bytes] | None = None
    restored_process: subprocess.Popen[bytes] | None = None
    log_handles: list[IO[bytes]] = []
    try:
        active_process, active_log, api = _start_server(
            executable, active_env, active_url, tmp_path / "active-server.log", bootstrap_token
        )
        log_handles.append(active_log)
        signing_key = SigningKey(tmp_path, "backup-owner")
        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        username = f"backup-{account_id[:8]}@example.test"
        encryption_public_key = b64url(os.urandom(32))
        registration = _new_account_registration(
            account_id,
            username,
            device_id,
            encryption_public_key,
            signing_key,
        )
        registration["bootstrap_token"] = bootstrap_token
        created = api.request("POST", "/api/v1/auth/register", json_body=registration)
        assert created.status in (200, 201), (
            f"isolated account registration failed with HTTP {created.status}: "
            f"{_error_code(created)}"
        )
        created_body = created.json()
        assert isinstance(created_body, dict) and created_body.get("access_token")
        old_access = created_body["access_token"]
        old_refresh = created_body["refresh_token"]
        before_instance_response = api.request("GET", "/api/v1/instance")
        assert before_instance_response.status == 200
        before_instance = before_instance_response.json()
        assert api.request("GET", "/api/v1/me", token=old_access).status == 200

        vault_id = registration["initial_vault"]["vault_id"]
        opaque_object = os.urandom(8193)
        object_sha256 = hashlib.sha256(opaque_object).hexdigest()
        object_id = _upload_opaque_object(api, vault_id, old_access, opaque_object)
        record_envelope, record_id, revision_id = _signed_opaque_record(
            instance=before_instance,
            vault_id=vault_id,
            device_id=device_id,
            signer=signing_key,
            object_id=object_id,
        )
        record_digest = _envelope_digest(record_envelope)
        push = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/sync/push",
            token=old_access,
            json_body={
                "protocol_version": before_instance.get("protocol_version", 1),
                "server_generation": before_instance["generation"],
                "vault_id": vault_id,
                "device_id": device_id,
                "batch_id": str(uuid.uuid4()),
                "operations": [record_envelope],
            },
        )
        assert push.status in (200, 201), (
            f"opaque record push failed: HTTP {push.status} {_error_code(push)}"
        )
        push_result = push.json().get("results", [])[0]
        assert push_result.get("revision_id") == revision_id, (
            "opaque record push did not commit the expected revision"
        )

        backup = _run_cli(
            executable,
            active_env,
            "backup",
            "--archive",
            str(archive),
            "--key-file",
            str(key_path),
        )
        assert backup.returncode == 0, "online backup CLI failed: " + _cli_error(backup, key_b64)
        assert archive.is_file() and archive.stat().st_size > 128
        if os.name == "posix":
            assert archive.stat().st_mode & 0o777 == 0o600
        online_verify = _run_cli(
            executable,
            active_env,
            "verify-backup",
            "--archive",
            str(archive),
            "--key-file",
            str(key_path),
        )
        assert online_verify.returncode == 0, (
            "online backup verification failed: " + _cli_error(online_verify, key_b64)
        )
        assert "Backup verified" in online_verify.stdout
        assert key_b64 not in online_verify.stdout + online_verify.stderr
        assert api.request("GET", "/health/ready").status == 200, (
            "online backup must leave the serving source healthy"
        )

        _stop_server(active_process)
        active_process = None
        source_db = active_data / "atermius.db"
        assert source_db.is_file()
        source_db_digest_before_source_restart = hashlib.sha256(source_db.read_bytes()).hexdigest()

        verify_env = dict(active_env)
        verify_env["ATERMIUS_ADMIN_USERNAMES"] = "verify-policy-sentinel@example.test"
        verified = _verify_cli(
            executable, verify_env, active_data, archive, key_path, key_b64
        )
        assert verified.returncode == 0, "valid backup verification failed: " + _cli_error(
            verified, key_b64
        )
        assert "Backup verified" in verified.stdout
        assert "migration version" in verified.stdout
        assert "verify-policy-sentinel@example.test" not in (
            verified.stdout + verified.stderr
        ), "backup verifier leaked effective runtime policy"

        if hasattr(os, "mkfifo"):
            fifo_archive = tmp_path / "archive-input.fifo"
            fifo_key = tmp_path / "key-input.fifo"
            os.mkfifo(fifo_archive, 0o600)
            os.mkfifo(fifo_key, 0o600)
            for description, archive_arg, key_arg in [
                ("FIFO archive", fifo_archive, key_path),
                ("FIFO key", archive, fifo_key),
            ]:
                try:
                    fifo_result = subprocess.run(
                        [
                            str(executable),
                            "verify-backup",
                            "--archive",
                            str(archive_arg),
                            "--key-file",
                            str(key_arg),
                        ],
                        cwd=ROOT,
                        env=active_env,
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False,
                    )
                except subprocess.TimeoutExpired as error:
                    raise AssertionError(
                        f"verify-backup blocked while opening a {description}"
                    ) from error
                assert fifo_result.returncode != 0, (
                    f"verify-backup must reject a {description}"
                )

        malformed_args = [
            (["--key-file", str(key_path)], "requires --archive"),
            (["--archive", str(archive), "--archive", str(archive), "--key-file", str(key_path)], "may only be provided once"),
            (["--archive", str(archive), "--key-file", str(key_path), "--unexpected"], "unknown verify-backup option"),
        ]
        for args, expected_error in malformed_args:
            malformed = _run_cli(executable, active_env, "verify-backup", *args)
            assert malformed.returncode != 0, f"malformed CLI args unexpectedly passed: {args}"
            assert expected_error in _cli_error(malformed, key_b64)

        damaged_archive = tmp_path / "damaged-instance.atb"
        damaged_bytes = bytearray(archive.read_bytes())
        damaged_bytes[-1] ^= 0x01
        damaged_archive.write_bytes(damaged_bytes)
        os.chmod(damaged_archive, 0o600)
        truncated_archive = tmp_path / "truncated-instance.atb"
        truncated_archive.write_bytes(archive.read_bytes()[:-1])
        os.chmod(truncated_archive, 0o600)
        trailing_archive = tmp_path / "trailing-instance.atb"
        trailing_archive.write_bytes(archive.read_bytes() + b"unexpected trailing byte")
        os.chmod(trailing_archive, 0o600)

        invalid_verifications = [
            (
                "wrong backup key",
                _verify_cli(
                    executable, active_env, active_data, archive, wrong_key_path, key_b64
                ),
            ),
            (
                "tampered archive",
                _verify_cli(
                    executable, active_env, active_data, damaged_archive, key_path, key_b64
                ),
            ),
            (
                "truncated archive",
                _verify_cli(
                    executable, active_env, active_data, truncated_archive, key_path, key_b64
                ),
            ),
            (
                "archive with trailing bytes",
                _verify_cli(
                    executable, active_env, active_data, trailing_archive, key_path, key_b64
                ),
            ),
        ]
        for case, result in invalid_verifications:
            assert result.returncode != 0, f"{case} unexpectedly passed verification"

        nested_temp_dir = active_data / "operator-temp"
        nested_temp_dir.mkdir(mode=0o700)
        if os.name == "posix":
            os.chmod(nested_temp_dir, 0o700)
        nested_temp_env = dict(active_env)
        nested_temp_env["TMPDIR"] = str(nested_temp_dir)
        nested_temp = _verify_cli(
            executable,
            nested_temp_env,
            active_data,
            archive,
            key_path,
            key_b64,
        )
        assert nested_temp.returncode != 0, (
            "verifier must refuse to stage decrypted files inside the instance data directory"
        )
        in_data_archive = _verify_cli(
            executable,
            active_env,
            active_data,
            active_data / "atermius.db",
            key_path,
            key_b64,
        )
        assert in_data_archive.returncode != 0, (
            "verifier must reject an archive path inside the instance data directory"
        )
        in_data_key = _verify_cli(
            executable,
            active_env,
            active_data,
            archive,
            active_data / "instance-ed25519.key",
            key_b64,
        )
        assert in_data_key.returncode != 0, (
            "verifier must reject a key path inside the instance data directory"
        )

        wrong_target = tmp_path / "restore-wrong-key"
        wrong = _run_cli(
            executable,
            active_env,
            "restore",
            "--archive",
            str(archive),
            "--key-file",
            str(wrong_key_path),
            "--target-data-dir",
            str(wrong_target),
            "--server-stopped",
        )
        assert wrong.returncode != 0, "wrong backup key unexpectedly restored an instance"
        assert not wrong_target.exists(), "wrong key must not publish a target directory"
        assert (
            hashlib.sha256(source_db.read_bytes()).hexdigest()
            == source_db_digest_before_source_restart
        )

        damaged_target = tmp_path / "restore-damaged-archive"
        damaged = _run_cli(
            executable,
            active_env,
            "restore",
            "--archive",
            str(damaged_archive),
            "--key-file",
            str(key_path),
            "--target-data-dir",
            str(damaged_target),
            "--server-stopped",
        )
        assert damaged.returncode != 0, "damaged encrypted archive unexpectedly restored"
        assert not damaged_target.exists(), "damaged archive must not publish a target directory"
        assert (
            hashlib.sha256(source_db.read_bytes()).hexdigest()
            == source_db_digest_before_source_restart
        )

        # Prove rejected restores left the source identity/database usable.
        active_process, active_log, api = _start_server(
            executable,
            active_env,
            active_url,
            tmp_path / "active-server-restart.log",
            bootstrap_token,
        )
        log_handles.append(active_log)
        unchanged_instance = api.request("GET", "/api/v1/instance")
        assert unchanged_instance.status == 200
        assert unchanged_instance.json()["generation"] == before_instance["generation"]
        assert api.request("GET", "/api/v1/me", token=old_access).status == 200
        _stop_server(active_process)
        active_process = None

        # Opening the source server performs legacy Relay-ticket cleanup and a
        # SQLite WAL checkpoint. Rebaseline after that lifecycle boundary so
        # the following digest checks isolate the offline restore commands.
        source_db_digest_before_restore_commands = hashlib.sha256(
            source_db.read_bytes()
        ).hexdigest()

        policy_drift_env = dict(active_env)
        policy_drift_env["ATERMIUS_ADMIN_USERNAMES"] = "restore-policy-sentinel@example.test"
        drift_target = tmp_path / "restore-policy-drift-rejected"
        drift_rejected = _run_cli(
            executable,
            policy_drift_env,
            "restore",
            "--archive",
            str(archive),
            "--key-file",
            str(key_path),
            "--target-data-dir",
            str(drift_target),
            "--server-stopped",
        )
        drift_error = _cli_error(drift_rejected, key_b64)
        assert drift_rejected.returncode != 0, "runtime policy drift unexpectedly restored"
        assert "RUNTIME_POLICY_DRIFT" in drift_error
        assert "admin_usernames" in drift_error
        assert "restore-policy-sentinel@example.test" not in drift_error
        assert not drift_target.exists(), "rejected policy drift must not publish a target"
        assert (
            hashlib.sha256(source_db.read_bytes()).hexdigest()
            == source_db_digest_before_restore_commands
        ), (
            "policy-drift rejection must not mutate the stopped source instance database"
        )

        restored_data = tmp_path / "restored-data"
        restore = _run_cli(
            executable,
            policy_drift_env,
            "restore",
            "--archive",
            str(archive),
            "--key-file",
            str(key_path),
            "--target-data-dir",
            str(restored_data),
            "--server-stopped",
            "--accept-runtime-policy-drift",
        )
        assert restore.returncode == 0, "valid restore CLI failed: " + _cli_error(restore, key_b64)
        restore_output = _cli_error(restore, key_b64)
        assert "explicitly accepted runtime policy drift" in restore_output
        assert "admin_usernames" in restore_output
        assert "restore-policy-sentinel@example.test" not in restore_output
        assert (restored_data / "atermius.db").is_file()
        assert (
            hashlib.sha256(source_db.read_bytes()).hexdigest()
            == source_db_digest_before_restore_commands
        ), (
            "valid restore must not mutate the stopped source instance database"
        )

        restored_port = _free_port()
        restored_url = f"http://127.0.0.1:{restored_port}"
        restored_env = _isolated_env(restored_data, restored_port)
        restored_env["ATERMIUS_ADMIN_USERNAMES"] = "restore-policy-sentinel@example.test"
        restored_process, restored_log, restored_api = _start_server(
            executable,
            restored_env,
            restored_url,
            tmp_path / "restored-server.log",
            bootstrap_token,
            key_b64,
        )
        log_handles.append(restored_log)
        assert restored_api.request("GET", "/health/live").status == 200
        assert restored_api.request("GET", "/health/ready").status == 200
        restored_instance_response = restored_api.request("GET", "/api/v1/instance")
        assert restored_instance_response.status == 200
        restored_instance = restored_instance_response.json()
        assert restored_instance["instance_id"] == before_instance["instance_id"]
        assert restored_instance["server_space_id"] == before_instance["server_space_id"]
        assert restored_instance["generation"] != before_instance["generation"]

        old_access_response = restored_api.request("GET", "/api/v1/me", token=old_access)
        assert old_access_response.status == 401, (
            "restore must invalidate pre-backup access sessions"
        )
        old_refresh_response = restored_api.request(
            "POST", "/api/v1/auth/refresh", json_body={"refresh_token": old_refresh}
        )
        assert old_refresh_response.status == 401, (
            "restore must invalidate pre-backup refresh sessions"
        )

        fresh_login = restored_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": username,
                "login_verifier": registration["login_verifier"],
                "device_id": device_id,
            },
        )
        assert fresh_login.status == 200, "restored credentials must still permit a new session"
        fresh_access = fresh_login.json()["access_token"]
        assert restored_api.request(
            "GET", "/api/v1/me", token=fresh_access
        ).status == 200
        restored_vaults = fresh_login.json().get("vaults", [])
        assert any(
            vault.get("vault_id") == vault_id
            for vault in restored_vaults
        )

        changes = restored_api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/changes?limit=100",
            token=fresh_access,
        )
        assert changes.status == 200, (
            f"restored Vault changes failed: HTTP {changes.status} {_error_code(changes)}"
        )
        matching_events = [
            event
            for event in changes.json().get("events", [])
            if event.get("record_id") == record_id
            and event.get("revision_id") == revision_id
        ]
        assert len(matching_events) == 1, (
            "restored changes stream must contain the synthetic opaque record once"
        )
        assert _envelope_digest(matching_events[0].get("envelope")) == record_digest, (
            "restored changes stream altered the signed opaque envelope"
        )
        assert matching_events[0]["envelope"]["header"].get("object_refs") == [object_id], (
            "restored changes stream lost the signed object reference"
        )

        snapshot_created = restored_api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/snapshots",
            token=fresh_access,
            json_body={},
        )
        assert snapshot_created.status in (200, 201), (
            f"restored Vault snapshot creation failed: HTTP {snapshot_created.status} "
            f"{_error_code(snapshot_created)}"
        )
        snapshot_id = snapshot_created.json().get("snapshot_id")
        snapshot = restored_api.request(
            "GET", f"/api/v1/snapshots/{snapshot_id}", token=fresh_access
        )
        assert snapshot.status == 200, (
            f"restored Vault snapshot fetch failed: HTTP {snapshot.status} "
            f"{_error_code(snapshot)}"
        )
        manifest_items = snapshot.json().get("manifest", [])
        matching_heads = [item for item in manifest_items if item.get("record_id") == record_id]
        assert len(matching_heads) == 1, (
            "restored snapshot manifest must contain the synthetic Vault head once"
        )
        assert matching_heads[0].get("revision_id") == revision_id, (
            "restored snapshot manifest has the wrong synthetic Vault revision"
        )
        assert _envelope_digest(matching_heads[0].get("envelope")) == record_digest, (
            "restored snapshot manifest altered the signed opaque envelope"
        )
        assert matching_heads[0]["envelope"]["header"].get("object_refs") == [object_id], (
            "restored snapshot manifest lost the signed object reference"
        )

        restored_object = restored_api.request(
            "GET",
            f"/api/v1/vaults/{vault_id}/objects/{object_id}",
            token=fresh_access,
        )
        assert restored_object.status == 200, (
            f"restored opaque object download failed: HTTP {restored_object.status} "
            f"{_error_code(restored_object)}"
        )
        assert len(restored_object.body) == len(opaque_object), (
            "restored opaque object has the wrong byte length"
        )
        assert hashlib.sha256(restored_object.body).hexdigest() == object_sha256, (
            "restored opaque object has the wrong SHA-256"
        )
        if restored_object.body != opaque_object:
            raise AssertionError("restored opaque object bytes differ from the uploaded bytes")
        assert (
            hashlib.sha256(source_db.read_bytes()).hexdigest()
            == source_db_digest_before_restore_commands
        ), (
            "starting the restored instance must leave the source database digest unchanged"
        )
    finally:
        _stop_server(active_process)
        _stop_server(restored_process)
        for handle in log_handles:
            handle.close()
