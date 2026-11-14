"""Black-box acceptance for the local filesystem opaque-object backend.

The service runs with its deployment UID (10001 when the test runner is root)
against private temporary data and object roots. This makes permission failures
real EACCES failures rather than chmod tests accidentally bypassed by root.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

import pytest

from conftest import ApiClient, SigningKey, b64url
from test_acceptance import _new_account_registration
from test_backup_cli import _server_binary, _stop_server
from test_object_range import _download, _error_code
from test_object_references import _operation, _push


ADMIN_USERNAME = "atermius-filesystem-integration-admin@example.test"
SERVICE_UID = 10001
SERVICE_GID = 10001


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _service_command(stack: dict[str, Any], *args: str) -> list[str]:
    command = [str(stack["executable"]), *args]
    if stack["setpriv"]:
        return [
            stack["setpriv"],
            "--reuid",
            str(stack["uid"]),
            "--regid",
            str(stack["gid"]),
            "--clear-groups",
            "--",
            *command,
        ]
    return command


def _chown(path: Path, uid: int, gid: int) -> None:
    if os.name == "posix" and os.geteuid() == 0:
        os.chown(path, uid, gid, follow_symlinks=False)


def _private_dir(path: Path, uid: int, gid: int, mode: int = 0o700) -> None:
    path.mkdir(mode=mode, parents=True, exist_ok=True)
    if os.name == "posix":
        os.chmod(path, mode)
        _chown(path, uid, gid)


def _make_stack(tmp_path: Path) -> dict[str, Any]:
    del tmp_path  # The service needs a traversable path even when pytest tmp is 0700.
    executable = _server_binary()
    setpriv = shutil.which("setpriv") if os.name == "posix" else None
    if os.name == "posix" and os.geteuid() == 0:
        assert setpriv, "filesystem delete-retry acceptance needs setpriv to drop root"
        uid, gid = SERVICE_UID, SERVICE_GID
    else:
        uid = os.geteuid() if hasattr(os, "geteuid") else 0
        gid = os.getegid() if hasattr(os, "getegid") else uid
        setpriv = None

    base = Path(tempfile.mkdtemp(prefix="atermius-object-filesystem-", dir="/tmp"))
    # The service opens each path component with O_RDONLY|O_DIRECTORY, so the
    # staging parent must be searchable and readable. All payload directories
    # and key files below remain owner-only.
    os.chmod(base, 0o755)
    binary_dir = base / "bin"
    _private_dir(binary_dir, uid, gid, 0o755)
    service_binary = binary_dir / "atermius-server"
    shutil.copy2(executable, service_binary)
    os.chmod(service_binary, 0o755)
    _chown(service_binary, uid, gid)

    data_dir = base / "data"
    filesystem_root = base / "object-store"
    backup_dir = base / "backup-archives"
    web_dir = base / "web"
    for path in (data_dir, filesystem_root, backup_dir):
        _private_dir(path, uid, gid)
    _private_dir(web_dir, uid, gid, 0o755)
    (web_dir / "index.html").write_text("<!doctype html><title>acceptance</title>", encoding="utf-8")
    _chown(web_dir / "index.html", uid, gid)

    backup_key = base / "backup.key"
    backup_key.write_bytes(os.urandom(32))
    os.chmod(backup_key, 0o600)
    _chown(backup_key, uid, gid)
    mfa_key = base / "mfa.key"
    mfa_key.write_bytes(os.urandom(32))
    os.chmod(mfa_key, 0o600)
    _chown(mfa_key, uid, gid)

    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("ATERMIUS_", "AWS_", "AMAZON_"))
    }
    env.update(
        {
            "HOME": str(base),
            "ATERMIUS_BIND": f"127.0.0.1:{port}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{data_dir / 'atermius.db'}?mode=rwc",
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "false",
            "ATERMIUS_PUBLIC_ORIGIN": base_url,
            "ATERMIUS_WEB_DIR": str(web_dir),
            "ATERMIUS_ADMIN_USERNAMES": ADMIN_USERNAME,
            "ATERMIUS_BACKUP_ARCHIVE_DIR": str(backup_dir),
            "ATERMIUS_BACKUP_KEY_FILE": str(backup_key),
            "ATERMIUS_MFA_ENCRYPTION_KEY_FILE": str(mfa_key),
            "ATERMIUS_OBJECT_GC_GRACE_SECONDS": "60",
            "ATERMIUS_OBJECT_STORE_BACKEND": "filesystem",
            "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT": str(filesystem_root),
        }
    )
    try:
        bootstrap = subprocess.run(
            _service_command(
                {"executable": service_binary, "setpriv": setpriv, "uid": uid, "gid": gid},
                "bootstrap",
            ),
            cwd=base,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if bootstrap.returncode != 0:
            detail = (bootstrap.stdout + "\n" + bootstrap.stderr)[-2500:]
            for private_path in (str(base), str(filesystem_root), str(backup_key), str(mfa_key)):
                detail = detail.replace(private_path, "[redacted-path]")
            raise AssertionError(f"filesystem bootstrap failed: {detail}")
        token = re.search(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap.stdout)
        assert token, "filesystem bootstrap did not print its one-time token"
    except Exception:
        shutil.rmtree(base, ignore_errors=True)
        raise

    stack: dict[str, Any] = {
        "base": base,
        "executable": service_binary,
        "setpriv": setpriv,
        "uid": uid,
        "gid": gid,
        "data_dir": data_dir,
        "filesystem_root": filesystem_root,
        "backup_dir": backup_dir,
        "backup_key": backup_key,
        "backup_key_bytes": backup_key.read_bytes(),
        "web_dir": web_dir,
        "port": port,
        "base_url": base_url,
        "env": env,
        "bootstrap_token": token.group(0),
        "process": None,
        "log_handle": None,
        "log_path": base / "server.log",
    }
    return stack


def _run_service_cli(
    stack: dict[str, Any],
    *args: str,
    env: dict[str, str] | None = None,
    timeout: int = 120,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        _service_command(stack, *args),
        cwd=stack["base"],
        env=(env or stack["env"]).copy(),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _start(stack: dict[str, Any], *, env: dict[str, str] | None = None, label: str = "server") -> ApiClient:
    log_path = stack["base"] / f"{label}.log"
    handle = log_path.open("wb")
    process = subprocess.Popen(
        _service_command(stack, "serve"),
        cwd=stack["base"],
        env=(env or stack["env"]).copy(),
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    api = ApiClient(stack["base_url"])
    deadline = time.monotonic() + 45
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError(f"filesystem server exited with status {process.returncode}")
            try:
                ready = api.request("GET", "/health/ready")
                if ready.status == 200:
                    stack["process"] = process
                    stack["log_handle"] = handle
                    stack["log_path"] = log_path
                    api.admin_env = (env or stack["env"]).copy()
                    api.temp_root = stack["base"]
                    api.bootstrap_token = stack["bootstrap_token"]
                    return api
            except OSError:
                pass
            time.sleep(0.2)
        raise AssertionError("filesystem server did not become ready")
    except Exception:
        _stop_server(process)
        handle.close()
        detail = log_path.read_text(errors="replace") if log_path.exists() else ""
        assert str(stack["filesystem_root"]) not in detail, "startup log leaked object-store root"
        raise


def _stop(stack: dict[str, Any]) -> None:
    process = stack.get("process")
    if process is not None:
        _stop_server(process)
        stack["process"] = None
    handle = stack.get("log_handle")
    if handle is not None:
        handle.close()
        stack["log_handle"] = None


@contextmanager
def _db(stack: dict[str, Any]) -> Iterator[sqlite3.Connection]:
    connection = sqlite3.connect(stack["data_dir"] / "atermius.db", timeout=30)
    connection.row_factory = sqlite3.Row
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _scalar(stack: dict[str, Any], sql: str, parameters: tuple[Any, ...] = ()) -> Any:
    with _db(stack) as connection:
        row = connection.execute(sql, parameters).fetchone()
        return row[0] if row else None


def _register_account(
    stack: dict[str, Any],
    api: ApiClient,
    tmp_path: Path,
    *,
    username: str,
    bootstrap: bool = False,
) -> dict[str, Any]:
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    signer = SigningKey(tmp_path, f"fs-{account_id[:8]}")
    registration = _new_account_registration(
        account_id,
        username,
        device_id,
        b64url(os.urandom(32)),
        signer,
    )
    if bootstrap:
        registration["bootstrap_token"] = stack["bootstrap_token"]
    else:
        invite = _run_service_cli(stack, "create-account-invite", "--username", username)
        assert invite.returncode == 0, "filesystem account invite command failed"
        match = re.search(r"(?m)^([A-Za-z0-9_-]{40,})\s*$", invite.stdout)
        assert match, "filesystem account invite command did not return its one-time token"
        registration["instance_invitation_token"] = match.group(1)
    created = api.request("POST", "/api/v1/auth/register", json_body=registration)
    assert created.status in (200, 201), (
        f"filesystem account registration failed: HTTP {created.status} {_error_code(created)}"
    )
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "login_verifier": registration["login_verifier"],
        "access_token": created.json()["access_token"],
        "vault_id": registration["initial_vault"]["vault_id"],
        "signing_key": signer,
        "registration": registration,
        "device_seq": 0,
    }


def _init_upload(api: ApiClient, owner: dict[str, Any], content: bytes, object_id: str | None = None) -> tuple[str, str]:
    object_id = object_id or str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    assert initialized.status in (200, 201), (
        f"filesystem upload init failed: HTTP {initialized.status} {_error_code(initialized)}"
    )
    upload_id = initialized.json()["upload_id"]
    replay = api.request(
        "POST",
        f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    assert replay.status in (200, 201) and replay.json()["upload_id"] == upload_id
    chunk_path = f"/api/v1/uploads/{upload_id}/chunks/0"
    for expected_replay in (False, True):
        chunk = api.request(
            "PUT",
            chunk_path,
            token=owner["access_token"],
            raw_body=content,
            content_type="application/octet-stream",
        )
        assert chunk.status in (200, 201), f"filesystem chunk write failed: {_error_code(chunk)}"
        if expected_replay:
            assert chunk.json().get("already_uploaded") is True
    return object_id, upload_id


def _complete(api: ApiClient, owner: dict[str, Any], upload_id: str):
    return api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=owner["access_token"],
        json_body={},
    )


def _upload(api: ApiClient, owner: dict[str, Any], content: bytes) -> tuple[str, str, str]:
    object_id, upload_id = _init_upload(api, owner, content)
    completed = _complete(api, owner, upload_id)
    assert completed.status in (200, 201), (
        f"filesystem object completion failed: HTTP {completed.status} {_error_code(completed)}"
    )
    replay = _complete(api, owner, upload_id)
    assert replay.status in (200, 201) and replay.json().get("already_completed") is True
    return object_id, upload_id, _object_key(api, owner, object_id, upload_id)


def _object_key(api: ApiClient, owner: dict[str, Any], object_id: str, upload_id: str) -> str:
    instance = api.request("GET", "/api/v1/instance")
    assert instance.status == 200
    return (
        f"atermius/objects/v1/{instance.json()['instance_id']}/{owner['vault_id']}/"
        f"{object_id}/{upload_id}"
    )


def _physical_path(stack: dict[str, Any], key: str) -> Path:
    return stack["filesystem_root"].joinpath(*key.split("/"))


def _ensure_service_parent(stack: dict[str, Any], path: Path) -> None:
    root = stack["filesystem_root"]
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current = current / part
        if current.exists():
            assert current.is_dir() and not current.is_symlink()
            continue
        current.mkdir(mode=0o700)
        os.chmod(current, 0o700)
        _chown(current, stack["uid"], stack["gid"])


def _error(response: Any) -> str | None:
    return _error_code(response)


def _run_invalid_startup(
    stack: dict[str, Any], env: dict[str, str], label: str, *private_paths: str
) -> None:
    process = subprocess.Popen(
        _service_command(stack, "serve"),
        cwd=stack["base"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=12)
    except subprocess.TimeoutExpired:
        _stop_server(process)
        raise AssertionError(f"invalid object-store startup unexpectedly served: {label}")
    text = output.decode("utf-8", errors="replace")
    assert process.returncode != 0, f"invalid object-store startup unexpectedly succeeded: {label}"
    for private_path in (str(stack["filesystem_root"]), *(path for path in private_paths if path)):
        assert private_path not in text, f"invalid startup leaked a filesystem path: {label}"


def test_filesystem_root_configuration_fails_closed(tmp_path: Path) -> None:
    stack = _make_stack(tmp_path)
    try:
        root = stack["filesystem_root"]
        data = stack["data_dir"]
        outside = stack["base"] / "outside"
        _private_dir(outside, stack["uid"], stack["gid"])
        link = stack["base"] / "object-store-link"
        link.symlink_to(root, target_is_directory=True)
        writable = stack["base"] / "world-writable-store"
        _private_dir(writable, stack["uid"], stack["gid"], 0o777)
        nested_data = data / "nested-store"
        _private_dir(nested_data, stack["uid"], stack["gid"])
        marker_link_root = stack["base"] / "marker-link-store"
        _private_dir(marker_link_root, stack["uid"], stack["gid"])
        real_marker = outside / "real-store-id"
        marker_contents = (str(uuid.uuid4()) + "\n").encode("ascii")
        real_marker.write_bytes(marker_contents)
        os.chmod(real_marker, 0o600)
        _chown(real_marker, stack["uid"], stack["gid"])
        (marker_link_root / ".atermius-store-id").symlink_to(real_marker)

        cases: list[tuple[str, str, Path | str | None]] = [
            ("relative-root", "filesystem", Path("relative-store")),
            ("non-normalized-root", "filesystem", Path(str(root / ".." / "object-store"))),
            ("root-symlink", "filesystem", link),
            ("world-writable-root", "filesystem", writable),
            ("root-overlaps-data", "filesystem", nested_data),
            ("symlink-store-marker", "filesystem", marker_link_root),
            ("sqlite-with-filesystem-root", "sqlite", root),
        ]
        for label, backend, configured_root in cases:
            env = stack["env"].copy()
            env["ATERMIUS_OBJECT_STORE_BACKEND"] = backend
            if configured_root is None:
                env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
            else:
                env["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] = str(configured_root)
            _run_invalid_startup(
                stack,
                env,
                label,
                str(configured_root) if configured_root is not None else "",
            )
        assert real_marker.read_bytes() == marker_contents

        if os.name == "posix" and os.geteuid() == 0:
            wrong_owner = stack["base"] / "wrong-owner-store"
            _private_dir(wrong_owner, stack["uid"], stack["gid"], 0o755)
            os.chown(wrong_owner, 0, 0)
            wrong_owner_env = stack["env"].copy()
            wrong_owner_env["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] = str(wrong_owner)
            _run_invalid_startup(stack, wrong_owner_env, "filesystem-root-wrong-owner", str(wrong_owner))

        # S3 and filesystem settings are mutually exclusive before any SDK or
        # credentials are opened; this never contacts a provider.
        mixed = stack["env"].copy()
        mixed.update(
            {
                "ATERMIUS_OBJECT_STORE_BACKEND": "s3",
                "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT": str(root),
                "ATERMIUS_OBJECT_STORE_S3_BUCKET": "filesystem-test-bucket",
                "ATERMIUS_OBJECT_STORE_S3_REGION": "us-east-1",
                "ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE": str(stack["base"] / "absent-creds.json"),
            }
        )
        _run_invalid_startup(stack, mixed, "s3-with-filesystem-root", str(root))
    finally:
        shutil.rmtree(stack["base"], ignore_errors=True)


def test_filesystem_opaque_object_acceptance_backup_gc_and_offline_restore(tmp_path: Path) -> None:
    stack = _make_stack(tmp_path)
    api: ApiClient | None = None
    restored_api: ApiClient | None = None
    try:
        marker = stack["filesystem_root"] / ".atermius-store-id"
        assert marker.is_file() and not marker.is_symlink()
        store_id = marker.read_text(encoding="ascii").strip()
        uuid.UUID(store_id)
        assert marker.stat().st_mode & 0o777 == 0o600
        assert marker.stat().st_uid == stack["uid"]

        api = _start(stack)
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        instance = instance_response.json()
        admin = _register_account(
            stack,
            api,
            tmp_path,
            username=ADMIN_USERNAME,
            bootstrap=True,
        )
        owner = _register_account(
            stack,
            api,
            tmp_path,
            username=f"fs-owner-{uuid.uuid4().hex[:10]}@example.test",
        )
        outsider = _register_account(
            stack,
            api,
            tmp_path,
            username=f"fs-outsider-{uuid.uuid4().hex[:10]}@example.test",
        )
        assert admin["access_token"]

        # Complete/replay a ciphertext upload, and verify both the catalogue
        # and the private on-disk immutable key.
        content = bytes((index * 61 + 7) % 256 for index in range(32771))
        object_id, upload_id, key = _upload(api, owner, content)
        row = _scalar(
            stack,
            "SELECT storage_backend || ':' || storage_key || ':' || storage_store_id FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        )
        assert row == f"filesystem:{key}:{store_id}"
        assert _scalar(
            stack,
            "SELECT length(bytes) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        ) == 0, "filesystem catalogue must not retain object ciphertext bytes"
        assert _scalar(
            stack,
            "SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?",
            (upload_id,),
        ) == 0
        object_path = _physical_path(stack, key)
        assert object_path.is_file() and not object_path.is_symlink()
        assert object_path.read_bytes() == content
        assert object_path.stat().st_mode & 0o777 == 0o600

        full = _download(api, owner["vault_id"], object_id, owner["access_token"])
        digest = hashlib.sha256(content).hexdigest()
        assert full.status == 200 and full.body == content
        assert full.headers.get("ETag") == f'"sha256-{digest}"'
        assert full.headers.get("Accept-Ranges") == "bytes"
        ranged = _download(
            api,
            owner["vault_id"],
            object_id,
            owner["access_token"],
            Range="bytes=17-113",
        )
        assert ranged.status == 206 and ranged.body == content[17:114]
        assert ranged.headers.get("Content-Range") == f"bytes 17-113/{len(content)}"
        matching = _download(
            api,
            owner["vault_id"],
            object_id,
            owner["access_token"],
            Range="bytes=0-9",
            **{"If-Range": f'"sha256-{digest}"'},
        )
        assert matching.status == 206 and matching.body == content[:10]
        stale = _download(
            api,
            owner["vault_id"],
            object_id,
            owner["access_token"],
            Range="bytes=0-9",
            **{"If-Range": '"sha256-stale"'},
        )
        assert stale.status == 200 and stale.body == content
        invalid = _download(
            api,
            owner["vault_id"],
            object_id,
            owner["access_token"],
            Range=f"bytes={len(content)}-",
        )
        assert invalid.status == 416
        assert invalid.headers.get("Content-Range") == f"bytes */{len(content)}"

        denied = _download(api, owner["vault_id"], object_id, outsider["access_token"])
        assert denied.status == 404 and _error(denied) == "NOT_FOUND"
        assert denied.headers.get("ETag") is None and denied.headers.get("Content-Range") is None
        assert stack["filesystem_root"].as_posix() not in denied.body.decode("utf-8", "replace")

        # A symlink in the key's parent is refused without writing through it;
        # the same durable reservation succeeds after the path is repaired.
        retry_bytes = b"filesystem-retry-ciphertext" * 19
        retry_id, retry_upload = _init_upload(api, owner, retry_bytes)
        retry_key = _object_key(api, owner, retry_id, retry_upload)
        retry_path = _physical_path(stack, retry_key)
        _ensure_service_parent(stack, retry_path.parent.parent)
        outside = stack["base"] / "outside-target"
        _private_dir(outside, stack["uid"], stack["gid"])
        sentinel = outside / "sentinel"
        sentinel.write_bytes(b"must-not-be-followed")
        os.chmod(sentinel, 0o600)
        _chown(sentinel, stack["uid"], stack["gid"])
        link_parent = retry_path.parent
        link_parent.symlink_to(outside, target_is_directory=True)
        failed_retry = _complete(api, owner, retry_upload)
        assert failed_retry.status == 503 and _error(failed_retry) == "OBJECT_INTEGRITY_MISMATCH"
        assert sentinel.read_bytes() == b"must-not-be-followed"
        assert not (outside / retry_path.name).exists()
        link_parent.unlink()
        recovered = _complete(api, owner, retry_upload)
        assert recovered.status in (200, 201), f"filesystem retry did not recover: {_error(recovered)}"
        assert retry_path.read_bytes() == retry_bytes

        # An already-present immutable key with the same bytes is idempotent;
        # different bytes conflict and are never replaced.
        same_bytes = b"same-filesystem-ciphertext" * 13
        same_id, same_upload = _init_upload(api, owner, same_bytes)
        same_key = _object_key(api, owner, same_id, same_upload)
        same_path = _physical_path(stack, same_key)
        _ensure_service_parent(stack, same_path.parent)
        same_path.write_bytes(same_bytes)
        os.chmod(same_path, 0o600)
        _chown(same_path, stack["uid"], stack["gid"])
        same_inode = same_path.stat().st_ino
        same_result = _complete(api, owner, same_upload)
        assert same_result.status in (200, 201), f"identical immutable retry failed: {_error(same_result)}"
        assert same_path.stat().st_ino == same_inode and same_path.read_bytes() == same_bytes

        conflict_bytes = b"expected-filesystem-ciphertext" * 11
        competitor = b"different-existing-content"
        conflict_id, conflict_upload = _init_upload(api, owner, conflict_bytes)
        conflict_key = _object_key(api, owner, conflict_id, conflict_upload)
        conflict_path = _physical_path(stack, conflict_key)
        _ensure_service_parent(stack, conflict_path.parent)
        conflict_path.write_bytes(competitor)
        os.chmod(conflict_path, 0o600)
        _chown(conflict_path, stack["uid"], stack["gid"])
        conflict = _complete(api, owner, conflict_upload)
        assert conflict.status == 409 and _error(conflict) == "OBJECT_EXISTS"
        assert conflict_path.read_bytes() == competitor
        assert _scalar(
            stack,
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], conflict_id),
        ) == 0
        # Keep the later archive round-trip focused on published objects; this
        # conflict has already proved immutable no-overwrite semantics.
        with _db(stack) as connection:
            connection.execute("UPDATE uploads SET state='expired' WHERE upload_id=?", (conflict_upload,))
            connection.execute("DELETE FROM upload_chunks WHERE upload_id=?", (conflict_upload,))

        # Signed references on the active head and a retained conflict branch
        # both protect their ciphertext from due object collection.
        main_object_id, _, _ = _upload(api, owner, b"main-ref-object")
        conflict_object_id, _, _ = _upload(api, owner, b"conflict-ref-object")
        main_record = str(uuid.uuid4())
        create = _operation(instance, owner, record_id=main_record)
        created = _push(api, instance, owner, [create])
        assert created.status in (200, 201)
        base_revision = created.json()["results"][0]["revision_id"]
        main_ref_op = _operation(
            instance,
            owner,
            operation="update",
            record_id=main_record,
            base_revision_id=base_revision,
            object_refs=[main_object_id],
            include_refs=True,
        )
        main_ref = _push(api, instance, owner, [main_ref_op])
        assert main_ref.status in (200, 201), f"head object reference failed: {_error(main_ref)}"
        conflict_ref_op = _operation(
            instance,
            owner,
            operation="update",
            record_id=main_record,
            base_revision_id=base_revision,
            object_refs=[conflict_object_id],
            include_refs=True,
        )
        conflict_ref = api.request(
            "POST",
            f"/api/v1/vaults/{owner['vault_id']}/conflicts",
            token=owner["access_token"],
            json_body={"envelope": conflict_ref_op},
        )
        assert conflict_ref.status in (200, 201), (
            f"conflict-branch object reference failed: {_error(conflict_ref)}"
        )
        with _db(stack) as connection:
            connection.execute(
                "UPDATE blob_objects SET gc_after=0 WHERE vault_id=? AND object_id IN (?,?)",
                (owner["vault_id"], main_object_id, conflict_object_id),
            )
        gc = _run_service_cli(stack, "maintenance")
        assert gc.returncode == 0, "filesystem maintenance failed with referenced objects"
        for referenced_id in (main_object_id, conflict_object_id):
            assert _scalar(
                stack,
                "SELECT storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
                (owner["vault_id"], referenced_id),
            ) == "available"
            assert _scalar(
                stack,
                "SELECT COUNT(*) FROM object_delete_queue WHERE storage_key LIKE ?",
                (f"%/{referenced_id}/%",),
            ) == 0

        # Make one unreferenced object due. Its directory stays readable but
        # becomes non-writable to UID 10001, yielding a real unlink EACCES.
        gc_bytes = b"quota-protected-object"
        gc_id, _, gc_key = _upload(api, owner, gc_bytes)
        gc_path = _physical_path(stack, gc_key)
        gc_parent = gc_path.parent
        with _db(stack) as connection:
            used_quota = connection.execute(
                "SELECT COALESCE((SELECT SUM(size) FROM blob_objects WHERE vault_id=?),0) + "
                "COALESCE((SELECT SUM(expected_size) FROM uploads WHERE vault_id=? AND state IN ('open','completing')),0)",
                (owner["vault_id"], owner["vault_id"]),
            ).fetchone()[0]
            connection.execute("UPDATE vaults SET quota_bytes=? WHERE vault_id=?", (used_quota, owner["vault_id"]))
            connection.execute(
                "UPDATE blob_objects SET gc_after=0 WHERE vault_id=? AND object_id=?",
                (owner["vault_id"], gc_id),
            )
        os.chmod(gc_parent, 0o500)
        failed_delete = _run_service_cli(stack, "maintenance")
        assert failed_delete.returncode == 0, "maintenance did not record a retryable unlink failure"
        assert _scalar(
            stack,
            "SELECT state FROM object_delete_queue WHERE storage_key=?",
            (gc_key,),
        ) == "retry_wait"
        assert _scalar(
            stack,
            "SELECT storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], gc_id),
        ) == "deleting"
        assert _scalar(
            stack,
            "SELECT attempt_count FROM object_delete_queue WHERE storage_key=?",
            (gc_key,),
        ) >= 1
        assert gc_path.is_file() and gc_path.read_bytes() == gc_bytes
        hidden_while_deleting = _download(api, owner["vault_id"], gc_id, owner["access_token"])
        assert hidden_while_deleting.status == 404 and _error(hidden_while_deleting) == "NOT_FOUND"
        quota_blocked = api.request(
            "POST",
            f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
            token=owner["access_token"],
            json_body={"object_id": str(uuid.uuid4()), "size": 1, "sha256": hashlib.sha256(b"x").hexdigest()},
        )
        assert quota_blocked.status == 507 and _error(quota_blocked) == "QUOTA_EXCEEDED"

        os.chmod(gc_parent, 0o700)
        with _db(stack) as connection:
            connection.execute(
                "UPDATE object_delete_queue SET next_attempt_at=0 WHERE storage_key=?",
                (gc_key,),
            )
        retry_delete = _run_service_cli(stack, "maintenance")
        assert retry_delete.returncode == 0, "filesystem delete queue retry failed"
        assert _scalar(
            stack,
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_key=?",
            (gc_key,),
        ) == 0
        assert _scalar(
            stack,
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], gc_id),
        ) == 0
        assert not gc_path.exists()
        quota_reopened = api.request(
            "POST",
            f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
            token=owner["access_token"],
            json_body={"object_id": str(uuid.uuid4()), "size": 1, "sha256": hashlib.sha256(b"x").hexdigest()},
        )
        assert quota_reopened.status in (200, 201), "confirmed delete did not release object quota"
        with _db(stack) as connection:
            connection.execute(
                "UPDATE uploads SET state='expired' WHERE upload_id=?",
                (quota_reopened.json()["upload_id"],),
            )

        # Object reads reject an attacker-swapped symlink and never return the
        # symlink target's marker contents.
        moved_object = object_path.with_name(object_path.name + ".saved")
        object_path.rename(moved_object)
        symlink_sentinel = stack["base"] / "symlink-target-secret"
        symlink_sentinel.write_bytes(b"external-path-secret")
        object_path.symlink_to(symlink_sentinel)
        symlink_read = _download(api, owner["vault_id"], object_id, owner["access_token"])
        assert symlink_read.status == 503 and _error(symlink_read) == "OBJECT_INTEGRITY_MISMATCH"
        assert b"external-path-secret" not in symlink_read.body
        object_path.unlink()
        moved_object.rename(object_path)
        damaged_for_read = bytearray(object_path.read_bytes())
        damaged_for_read[-1] ^= 0x40
        object_path.write_bytes(damaged_for_read)
        damaged_read = _download(api, owner["vault_id"], object_id, owner["access_token"])
        assert damaged_read.status == 503 and _error(damaged_read) == "OBJECT_INTEGRITY_MISMATCH"
        object_path.write_bytes(content)
        os.chmod(object_path, 0o600)
        _chown(object_path, stack["uid"], stack["gid"])

        # The normal encrypted archive remains self-contained: hydration reads
        # and verifies FS ciphertext into the VACUUM snapshot before publishing.
        archive = stack["backup_dir"] / "filesystem-objects.atb"
        backup = _run_service_cli(
            stack,
            "backup",
            "--archive",
            str(archive),
            "--key-file",
            str(stack["backup_key"]),
        )
        assert backup.returncode == 0, "filesystem object archive hydration failed"
        assert archive.is_file() and archive.stat().st_size > 128
        assert stack["backup_key_bytes"].hex() not in backup.stdout + backup.stderr

        # A missing or corrupted object prevents archive publication and keeps
        # the source catalogue/file recoverable.
        original_bytes = object_path.read_bytes()
        damaged = bytearray(original_bytes)
        damaged[0] ^= 0x80
        object_path.write_bytes(damaged)
        failed_corrupt_archive = stack["backup_dir"] / "corrupt-source.atb"
        corrupt_backup = _run_service_cli(
            stack,
            "backup",
            "--archive",
            str(failed_corrupt_archive),
            "--key-file",
            str(stack["backup_key"]),
        )
        assert corrupt_backup.returncode != 0 and not failed_corrupt_archive.exists()
        assert _scalar(
            stack,
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        ) == "filesystem"
        object_path.write_bytes(original_bytes)
        object_path.unlink()
        failed_missing_archive = stack["backup_dir"] / "missing-source.atb"
        missing_backup = _run_service_cli(
            stack,
            "backup",
            "--archive",
            str(failed_missing_archive),
            "--key-file",
            str(stack["backup_key"]),
        )
        assert missing_backup.returncode != 0 and not failed_missing_archive.exists()
        assert _scalar(
            stack,
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        ) == "filesystem"
        object_path.write_bytes(original_bytes)
        os.chmod(object_path, 0o600)
        _chown(object_path, stack["uid"], stack["gid"])

        # A new empty volume has a different store UUID and cannot silently
        # satisfy rows tied to the original filesystem root.
        _stop(stack)
        source_log_path = stack["log_path"]
        api = _start(stack, label="source-restarted")
        restarted_download = _download(api, owner["vault_id"], object_id, owner["access_token"])
        assert restarted_download.status == 200 and restarted_download.body == content
        source_restart_log_path = stack["log_path"]
        _stop(stack)
        switched_root = stack["base"] / "empty-replacement-store"
        _private_dir(switched_root, stack["uid"], stack["gid"])
        wrong_root_env = stack["env"].copy()
        wrong_root_env["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] = str(switched_root)
        _run_invalid_startup(
            stack,
            wrong_root_env,
            "filesystem-store-identity-mismatch",
            str(switched_root),
        )

        # Restore the known-good archive with no filesystem backend/root, then
        # read the object from the restored SQLite catalogue while offline from
        # the original filesystem volume.
        restore_env = stack["env"].copy()
        restore_env.pop("ATERMIUS_OBJECT_STORE_BACKEND", None)
        restore_env.pop("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT", None)
        restore_parent = stack["base"] / "restore-output"
        _private_dir(restore_parent, stack["uid"], stack["gid"])
        restored_dir = restore_parent / "restored-data"
        restore = _run_service_cli(
            stack,
            "restore",
            "--archive",
            str(archive),
            "--key-file",
            str(stack["backup_key"]),
            "--target-data-dir",
            str(restored_dir),
            "--server-stopped",
            env=restore_env,
        )
        assert restore.returncode == 0, "offline filesystem-object restore failed"
        assert (restored_dir / "atermius.db").is_file()

        restored_port = _free_port()
        restored_url = f"http://127.0.0.1:{restored_port}"
        restored_env = restore_env.copy()
        restored_env.update(
            {
                "ATERMIUS_BIND": f"127.0.0.1:{restored_port}",
                "ATERMIUS_PUBLIC_ORIGIN": restored_url,
                "ATERMIUS_DATA_DIR": str(restored_dir),
                "ATERMIUS_DATABASE_URL": f"sqlite://{restored_dir / 'atermius.db'}?mode=rwc",
            }
        )
        stack["base_url"] = restored_url
        stack["env"] = restored_env
        restored_api = _start(stack, env=restored_env, label="restored-server")
        login = restored_api.request(
            "POST",
            "/api/v1/auth/login",
            json_body={
                "username": owner["username"],
                "login_verifier": owner["login_verifier"],
                "device_id": owner["device_id"],
            },
        )
        assert login.status == 200, "restored local object account could not log in"
        restored_token = login.json()["access_token"]
        restored_download = _download(restored_api, owner["vault_id"], object_id, restored_token)
        assert restored_download.status == 200 and restored_download.body == content
        assert _scalar(
            {**stack, "data_dir": restored_dir},
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        ) == "sqlite"
        assert _scalar(
            {**stack, "data_dir": restored_dir},
            "SELECT length(bytes) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (owner["vault_id"], object_id),
        ) == len(content)

        # Public API and service logs must not reveal the mounted root, marker,
        # object key, or backup key.
        log_text = source_log_path.read_text(errors="replace") + source_restart_log_path.read_text(errors="replace")
        restored_log_text = stack["log_path"].read_text(errors="replace")
        for private_value in (
            str(stack["filesystem_root"]),
            store_id,
            key,
            stack["backup_key_bytes"].hex(),
            b"external-path-secret".decode(),
        ):
            assert private_value not in log_text + restored_log_text, "filesystem service log leaked private storage material"
        for response in (failed_retry, conflict, denied, symlink_read):
            body_text = response.body.decode("utf-8", "replace")
            assert str(stack["filesystem_root"]) not in body_text
            assert key not in body_text
            assert stack["backup_key_bytes"].hex() not in body_text
        assert str(stack["filesystem_root"]) not in restored_download.body.decode("utf-8", "replace")
    finally:
        _stop(stack)
        shutil.rmtree(stack["base"], ignore_errors=True)
