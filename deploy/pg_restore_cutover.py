#!/usr/bin/env python3
"""Offline PostgreSQL restore-stage cutover for the single Compose server.

The coordinator accepts only a canonical restore job UUID. Deployment paths,
database URLs, and the health endpoint come from this checkout and its private
deploy/.env file. It never starts or stops ingress services and never deletes
databases, volumes, stages, or archives.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterator
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deploy"
ENV_FILE = DEPLOY / ".env"
JOURNAL_DIR = DEPLOY / ".pg-restore-cutover"
COMPOSE_FILES = (
    DEPLOY / "compose.yaml",
    DEPLOY / "compose.backup.yaml",
    DEPLOY / "compose.object-store-filesystem.yaml",
    DEPLOY / "compose.postgres.yaml",
)
SERVICE = "server"
ARCHIVE_HOST_KEY = "ATERMIUS_BACKUP_ARCHIVE_HOST_DIR"
BACKEND_KEY = "ATERMIUS_SYNC_BACKEND"
PG_URL_KEY = "ATERMIUS_SYNC_PG_URL"
PG_SCHEMA_KEY = "ATERMIUS_SYNC_PG_SCHEMA"
RESTORE_TARGET_KEY = "ATERMIUS_PG_RESTORE_TARGET_URL"
NEXT_TARGET_KEY = "ATERMIUS_PG_RESTORE_NEXT_TARGET_URL"
SIGNING_KEY_FILE_KEY = "ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE"
RATE_KEY_FILE_KEY = "ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE"
SIGNING_KEY_HOST_FILE_KEY = "ATERMIUS_PG_INSTANCE_SIGNING_KEY_HOST_FILE"
RATE_KEY_HOST_FILE_KEY = "ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_HOST_FILE"
OBJECT_BACKEND_KEY = "ATERMIUS_OBJECT_STORE_BACKEND"
OBJECT_ROOT_KEY = "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"
BACKUP_ARCHIVE_DIR_KEY = "ATERMIUS_BACKUP_ARCHIVE_DIR"
SOURCE_SIGNING_KEY_CONTAINER_PATH = "/run/secrets/atermius-pg-instance-ed25519.key"
SOURCE_RATE_KEY_CONTAINER_PATH = "/run/secrets/atermius-pg-auth-rate-limit.key"
SERVICE_UID = 10001
HTTP_TIMEOUT_SECONDS = 4
DEFAULT_HEALTH_TIMEOUT_SECONDS = 180
MAX_HEALTH_TIMEOUT_SECONDS = 900
JOURNAL_VERSION = 1
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX_256_RE = re.compile(r"^[0-9a-f]{64}$")
SCHEMA_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
URL_RE = re.compile(r"^postgres(?:ql)?://[^\s'\"$#]+$")
CONTAINER_ID_RE = re.compile(r"^[0-9a-f]{12,64}$")
DOCKER_CONTEXT_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
PHASES = {
    "prepared",
    "stopping_source",
    "source_stopped",
    "config_staged",
    "starting_stage",
    "stage_verified",
    "activating",
    "activation_uncertain",
    "committed",
    "rolling_back",
    "rollback_pending",
    "rolled_back",
}
JOURNAL_FIELDS = {
    "version",
    "job_id",
    "phase",
    "created_at",
    "updated_at",
    "original_env_sha256",
    "backup_env_sha256",
    "staged_env_sha256",
    "rollback_env_sha256",
    "compose_sha256",
    "receipt",
    "source_identity",
    "last_error_code",
}
RECEIPT_FIELDS = {
    "format_version",
    "job_id",
    "archive_id",
    "archive_sha256",
    "generation",
    "schema",
    "object_store_id",
    "restored_objects",
    "binding_id",
    "target_fingerprint",
    "target_database_oid",
    "target_database_name",
}
IDENTITY_FIELDS = {
    "instance_id",
    "server_space_id",
    "generation",
    "signing_public_key",
}
RUNTIME_MOUNT_TARGETS = {
    "/data",
    "/backups",
    "/backup-key",
    "/object-store",
    SOURCE_SIGNING_KEY_CONTAINER_PATH,
    SOURCE_RATE_KEY_CONTAINER_PATH,
}


class CutoverError(Exception):
    """Fixed safe error code suitable for operator display."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class EnvDocument:
    raw: bytes
    text: str
    lines: tuple[str, ...]
    values: dict[str, str]
    st_dev: int
    st_ino: int


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_uuid(value: str) -> bool:
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _fail(code: str) -> None:
    raise CutoverError(code)


def _safe_path_components(path: Path, *, allow_missing_leaf: bool = False) -> None:
    if not path.is_absolute():
        _fail("PATH_NOT_ABSOLUTE")
    current = Path(path.anchor)
    parts = path.parts[1:]
    for index, part in enumerate(parts):
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if allow_missing_leaf and index == len(parts) - 1:
                return
            _fail("PATH_MISSING")
        except OSError:
            _fail("PATH_UNAVAILABLE")
        if stat.S_ISLNK(metadata.st_mode):
            _fail("SYMLINK_REJECTED")


def _read_private_regular(path: Path, *, mode: int, owner_uid: int | None = None,
                          max_bytes: int = 1_048_576) -> bytes:
    _safe_path_components(path)
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail("UNSAFE_FILE")
        if stat.S_IMODE(before.st_mode) != mode:
            _fail("UNSAFE_FILE_MODE")
        if owner_uid is not None and before.st_uid != owner_uid:
            _fail("UNSAFE_FILE_OWNER")
        if before.st_size > max_bytes:
            _fail("FILE_TOO_LARGE")
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            after = os.fstat(fd)
            if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                _fail("FILE_CHANGED")
            if not stat.S_ISREG(after.st_mode) or after.st_nlink != 1:
                _fail("UNSAFE_FILE")
            chunks: list[bytes] = []
            remaining = max_bytes + 1
            while remaining > 0:
                chunk = os.read(fd, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > max_bytes:
                _fail("FILE_TOO_LARGE")
            return data
        finally:
            os.close(fd)
    except CutoverError:
        raise
    except OSError:
        _fail("FILE_UNAVAILABLE")


def _parse_env(raw: bytes) -> tuple[str, tuple[str, ...], dict[str, str]]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        _fail("ENV_ENCODING_INVALID")
    if "\x00" in text or "\r" in text:
        _fail("ENV_ENCODING_INVALID")
    values: dict[str, str] = {}
    lines = tuple(text.splitlines())
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            stripped = stripped[7:].lstrip()
        if "=" not in stripped:
            _fail("ENV_FORMAT_INVALID")
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not ENV_KEY_RE.fullmatch(key) or key in values:
            _fail("ENV_DUPLICATE_OR_INVALID_KEY")
        value = value.strip()
        if value.startswith("'") or value.startswith('"'):
            quote = value[0]
            end = value.find(quote, 1)
            if end < 0 or value[end + 1:].strip() not in ("",) and not value[end + 1:].lstrip().startswith("#"):
                _fail("ENV_FORMAT_INVALID")
            value = value[1:end]
        else:
            # Compose treats whitespace-prefixed # as an inline comment.
            value = re.sub(r"\s+#.*$", "", value).strip()
        values[key] = value
    return text, lines, values


def _read_env(path: Path) -> EnvDocument:
    raw = _read_private_regular(path, mode=0o600, owner_uid=os.geteuid())
    metadata = path.lstat()
    text, lines, values = _parse_env(raw)
    return EnvDocument(raw, text, lines, values, metadata.st_dev, metadata.st_ino)


def _require_env(values: dict[str, str], key: str) -> str:
    value = values.get(key)
    if not isinstance(value, str) or not value:
        _fail("ENV_REQUIRED_VALUE_MISSING")
    return value


def _parse_pg_url(value: str) -> tuple[str, int | None, str]:
    if not URL_RE.fullmatch(value):
        _fail("PG_URL_INVALID")
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
        database = unquote(parts.path[1:])
    except ValueError:
        _fail("PG_URL_INVALID")
    if parts.scheme not in ("postgres", "postgresql") or not host or not database or "/" in database:
        _fail("PG_URL_INVALID")
    if parts.fragment or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}", database):
        _fail("PG_URL_INVALID")
    return host.lower(), port or 5432, database


def _validate_pg_settings(values: dict[str, str]) -> tuple[str, str, str, str]:
    if _require_env(values, BACKEND_KEY) != "postgres":
        _fail("PG_BACKEND_REQUIRED")
    source = _require_env(values, PG_URL_KEY)
    stage = _require_env(values, RESTORE_TARGET_KEY)
    next_target = _require_env(values, NEXT_TARGET_KEY)
    schema = _require_env(values, PG_SCHEMA_KEY)
    if not SCHEMA_RE.fullmatch(schema) or schema.lower() in {"public", "information_schema", "atermius_restore_control"} or schema.lower().startswith("pg_"):
        _fail("PG_SCHEMA_INVALID")
    source_key = _parse_pg_url(source)
    stage_key = _parse_pg_url(stage)
    next_key = _parse_pg_url(next_target)
    if len({source_key, stage_key, next_key}) != 3 or len({source, stage, next_target}) != 3:
        _fail("PG_TARGETS_NOT_DISTINCT")
    signing = _require_env(values, SIGNING_KEY_FILE_KEY)
    rate = _require_env(values, RATE_KEY_FILE_KEY)
    for value in (signing, rate):
        if not value.startswith("/") or "\x00" in value or ".." in PurePosixPath(value).parts:
            _fail("PG_KEY_PATH_INVALID")
    if signing == rate:
        _fail("PG_KEY_PATH_INVALID")
    return source, stage, next_target, schema


def _validate_source_key_files(values: dict[str, str], *, source_paths_are_active: bool) -> tuple[Path, Path]:
    if source_paths_are_active and (
        values.get(SIGNING_KEY_FILE_KEY) != SOURCE_SIGNING_KEY_CONTAINER_PATH
        or values.get(RATE_KEY_FILE_KEY) != SOURCE_RATE_KEY_CONTAINER_PATH
    ):
        _fail("PG_SOURCE_KEY_PATH_INVALID")
    paths: list[Path] = []
    for key in (SIGNING_KEY_HOST_FILE_KEY, RATE_KEY_HOST_FILE_KEY):
        raw_path = _require_env(values, key)
        path = Path(raw_path)
        if not path.is_absolute():
            _fail("PG_HOST_KEY_PATH_INVALID")
        data = _read_private_regular(path, mode=0o600, owner_uid=SERVICE_UID, max_bytes=64)
        if len(data) != 32:
            _fail("PG_HOST_KEY_INVALID")
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != SERVICE_UID or stat.S_IMODE(parent.st_mode) != 0o700:
            _fail("PG_HOST_KEY_DIR_UNSAFE")
        paths.append(path.resolve(strict=True))
    if paths[0] == paths[1]:
        _fail("PG_HOST_KEY_PATH_INVALID")
    return paths[0], paths[1]


def _quote_env_value(value: str) -> str:
    if "\n" in value or "\r" in value or "\x00" in value or "'" in value:
        _fail("ENV_VALUE_UNSAFE")
    # Single quotes make Compose's .env value literal (not interpolated).
    return f"'{value}'"


def _rewrite_env(raw: bytes, updates: dict[str, str]) -> bytes:
    text, lines, values = _parse_env(raw)
    result: list[str] = []
    seen: set[str] = set()
    for line in lines:
        stripped = line.strip()
        candidate = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
        if not stripped or stripped.startswith("#") or "=" not in candidate:
            result.append(line)
            continue
        key = candidate.split("=", 1)[0].strip()
        if key in updates:
            indent = line[:len(line) - len(line.lstrip())]
            result.append(f"{indent}{key}={_quote_env_value(updates[key])}")
            seen.add(key)
        else:
            result.append(line)
    for key, value in updates.items():
        if key not in seen:
            result.append(f"{key}={_quote_env_value(value)}")
    ending = "\n" if text.endswith("\n") or not result else ""
    return ("\n".join(result) + ending).encode("utf-8")


def _ensure_private_directory(path: Path) -> None:
    _safe_path_components(path, allow_missing_leaf=True)
    if not path.exists():
        try:
            path.mkdir(mode=0o700)
            _fsync_dir(path.parent)
        except FileExistsError:
            pass
        except OSError:
            _fail("STATE_DIR_UNAVAILABLE")
    try:
        metadata = path.lstat()
    except OSError:
        _fail("STATE_DIR_UNAVAILABLE")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        _fail("STATE_DIR_UNSAFE")
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        _fail("STATE_DIR_UNSAFE")


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_create(path: Path, data: bytes, *, mode: int) -> None:
    _safe_path_components(path.parent)
    if path.exists() or path.is_symlink():
        _fail("STATE_FILE_EXISTS")
    fd = -1
    temp_path: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temp_path = Path(name)
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temp_path, path, follow_symlinks=False)
        temp_path.unlink()
        _fsync_dir(path.parent)
    except CutoverError:
        raise
    except OSError:
        _fail("STATE_FILE_WRITE_FAILED")
    finally:
        if fd >= 0:
            os.close(fd)
        if temp_path is not None:
            with contextlib.suppress(OSError):
                temp_path.unlink()


def _atomic_replace(path: Path, data: bytes, *, mode: int, owner_uid: int | None,
                    expected_sha256: str | None = None) -> None:
    existing = _read_private_regular(path, mode=mode, owner_uid=owner_uid)
    if expected_sha256 is not None and _sha256(existing) != expected_sha256:
        _fail("ENV_CHANGED")
    before = path.lstat()
    fd = -1
    temp_path: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temp_path = Path(name)
        os.fchmod(fd, mode)
        if owner_uid is not None:
            os.fchown(fd, owner_uid, -1)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        current = path.lstat()
        if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino) or not stat.S_ISREG(current.st_mode):
            _fail("ENV_CHANGED")
        os.replace(temp_path, path)
        temp_path = None
        _fsync_dir(path.parent)
    except CutoverError:
        raise
    except OSError:
        _fail("ATOMIC_WRITE_FAILED")
    finally:
        if fd >= 0:
            os.close(fd)
        if temp_path is not None:
            with contextlib.suppress(OSError):
                temp_path.unlink()


def _read_journal(path: Path, job_id: str) -> dict[str, Any]:
    raw = _read_private_regular(path, mode=0o600, owner_uid=os.geteuid(), max_bytes=65536)
    try:
        journal = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        _fail("JOURNAL_INVALID")
    if not isinstance(journal, dict) or set(journal) != JOURNAL_FIELDS:
        _fail("JOURNAL_INVALID")
    if journal.get("version") != JOURNAL_VERSION or journal.get("job_id") != job_id or journal.get("phase") not in PHASES:
        _fail("JOURNAL_INVALID")
    if not isinstance(journal.get("receipt"), dict) or set(journal["receipt"]) != RECEIPT_FIELDS:
        _fail("JOURNAL_INVALID")
    if not isinstance(journal.get("source_identity"), dict) or set(journal["source_identity"]) != IDENTITY_FIELDS:
        _fail("JOURNAL_INVALID")
    for field in ("original_env_sha256", "backup_env_sha256", "staged_env_sha256", "rollback_env_sha256", "compose_sha256"):
        if not isinstance(journal.get(field), str) or not HEX_256_RE.fullmatch(journal[field]):
            _fail("JOURNAL_INVALID")
    return journal


def _write_journal(path: Path, journal: dict[str, Any]) -> None:
    if set(journal) != JOURNAL_FIELDS or journal.get("phase") not in PHASES:
        _fail("JOURNAL_INVALID")
    journal["updated_at"] = _now()
    encoded = json.dumps(journal, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    if path.exists():
        _atomic_replace(path, encoded, mode=0o600, owner_uid=os.geteuid())
    else:
        _atomic_create(path, encoded, mode=0o600)


@contextlib.contextmanager
def _locked_state(job_id: str) -> Iterator[tuple[Path, Path, Path]]:
    _ensure_private_directory(JOURNAL_DIR)
    journal_path = JOURNAL_DIR / f"{job_id}.json"
    backup_path = JOURNAL_DIR / f"{job_id}.env.original"
    lock_path = JOURNAL_DIR / f"{job_id}.lock"
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError:
        _fail("LOCK_UNAVAILABLE")
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
            _fail("LOCK_UNSAFE")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            _fail("CUTOVER_BUSY")
        yield journal_path, backup_path, lock_path
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _compose_environment() -> dict[str, str]:
    allowed = {
        "PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST", "DOCKER_CONTEXT",
        "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "XDG_RUNTIME_DIR", "SSH_AUTH_SOCK",
        "LANG", "LC_ALL", "TERM",
    }
    return {key: value for key, value in os.environ.items() if key in allowed}


def _local_docker_context() -> str:
    # The coordinator validates receipt/key/object files on this host. A
    # remote daemon with identically named paths would bind unrelated remote
    # files, so require a local Unix-socket endpoint and pin every Docker call
    # to the context inspected here.
    configured_host = os.environ.get("DOCKER_HOST")
    if configured_host:
        parsed_host = urlsplit(configured_host)
        if (
            parsed_host.scheme != "unix"
            or parsed_host.netloc
            or not parsed_host.path.startswith("/")
            or parsed_host.query
            or parsed_host.fragment
        ):
            _fail("COMPOSE_REMOTE_CONTEXT_UNSUPPORTED")
    env = _compose_environment()
    try:
        shown = subprocess.run(
            ["docker", "context", "show"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _fail("COMPOSE_CONTEXT_TIMEOUT")
    except OSError:
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    context = shown.stdout.strip()
    if shown.returncode != 0 or not DOCKER_CONTEXT_RE.fullmatch(context):
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    try:
        inspected = subprocess.run(
            ["docker", "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}", context],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _fail("COMPOSE_CONTEXT_TIMEOUT")
    except OSError:
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    if inspected.returncode != 0 or len(inspected.stdout) > 4096:
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    try:
        endpoint = json.loads(inspected.stdout)
    except json.JSONDecodeError:
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    if not isinstance(endpoint, str):
        _fail("COMPOSE_CONTEXT_UNAVAILABLE")
    parsed_endpoint = urlsplit(endpoint)
    if (
        parsed_endpoint.scheme != "unix"
        or parsed_endpoint.netloc
        or not parsed_endpoint.path.startswith("/")
        or parsed_endpoint.query
        or parsed_endpoint.fragment
    ):
        _fail("COMPOSE_REMOTE_CONTEXT_UNSUPPORTED")
    if configured_host and configured_host != endpoint:
        _fail("COMPOSE_CONTEXT_MISMATCH")
    return context


def _compose_base() -> list[str]:
    command = ["docker", "--context", _local_docker_context(), "compose", "--env-file", str(ENV_FILE)]
    for compose_file in COMPOSE_FILES:
        if not compose_file.is_file() or compose_file.is_symlink():
            _fail("COMPOSE_FILE_UNAVAILABLE")
        command.extend(("--file", str(compose_file)))
    return command


def _run_compose(args: list[str], *, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    command = _compose_base() + args
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=_compose_environment(),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _fail("COMPOSE_TIMEOUT")
    except OSError:
        _fail("COMPOSE_UNAVAILABLE")
    if result.returncode != 0:
        _fail("COMPOSE_COMMAND_FAILED")
    return result


def _compose_hash() -> str:
    digest = hashlib.sha256()
    for path in COMPOSE_FILES:
        try:
            data = path.read_bytes()
        except OSError:
            _fail("COMPOSE_FILE_UNAVAILABLE")
        digest.update(path.name.encode("utf-8") + b"\0" + data + b"\0")
    return digest.hexdigest()


def _archive_host_dir(values: dict[str, str]) -> Path:
    raw = _require_env(values, ARCHIVE_HOST_KEY)
    path = Path(raw)
    if not path.is_absolute():
        _fail("ARCHIVE_PATH_INVALID")
    _safe_path_components(path)
    try:
        resolved = path.resolve(strict=True)
        metadata = resolved.stat()
    except OSError:
        _fail("ARCHIVE_PATH_UNAVAILABLE")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(path.lstat().st_mode):
        _fail("ARCHIVE_PATH_UNSAFE")
    if metadata.st_uid != SERVICE_UID or stat.S_IMODE(metadata.st_mode) & 0o077:
        _fail("ARCHIVE_PATH_UNSAFE")
    return resolved


def _validate_compose(values: dict[str, str], *, expected_pg_url: str,
                      expected_restore_url: str, expected_object_root: str,
                      expected_signing_file: str, expected_rate_file: str,
                      source_key_paths_active: bool = False) -> dict[str, Any]:
    archive_host = _archive_host_dir(values)
    config = _compose_config_document()
    services = config.get("services") if isinstance(config, dict) else None
    service = services.get(SERVICE) if isinstance(services, dict) else None
    if not isinstance(service, dict):
        _fail("COMPOSE_SERVER_REQUIRED")
    deploy = service.get("deploy")
    replicas = deploy.get("replicas") if isinstance(deploy, dict) else None
    if replicas is not None and replicas != 1:
        _fail("COMPOSE_SINGLE_SERVER_REQUIRED")
    scale = service.get("scale")
    if scale is not None and scale != 1:
        _fail("COMPOSE_SINGLE_SERVER_REQUIRED")
    configured_env = service.get("environment")
    if not isinstance(configured_env, dict):
        _fail("COMPOSE_ENV_INVALID")
    expected_env = {
        BACKEND_KEY: "postgres",
        PG_URL_KEY: expected_pg_url,
        PG_SCHEMA_KEY: _require_env(values, PG_SCHEMA_KEY),
        RESTORE_TARGET_KEY: expected_restore_url,
        SIGNING_KEY_FILE_KEY: expected_signing_file,
        RATE_KEY_FILE_KEY: expected_rate_file,
        OBJECT_BACKEND_KEY: "filesystem",
        OBJECT_ROOT_KEY: expected_object_root,
        BACKUP_ARCHIVE_DIR_KEY: "/backups",
    }
    for key, expected in expected_env.items():
        if configured_env.get(key) != expected:
            _fail("COMPOSE_ENV_MISMATCH")
    if NEXT_TARGET_KEY in configured_env:
        _fail("NEXT_TARGET_MUST_STAY_OPERATOR_ONLY")
    host_signing, host_rate = _validate_source_key_files(values, source_paths_are_active=source_key_paths_active)
    volumes = service.get("volumes")
    if not isinstance(volumes, list):
        _fail("COMPOSE_VOLUME_INVALID")
    archive_mounts = []
    key_mounts: dict[str, dict[str, Any]] = {}
    for mount in volumes:
        if not isinstance(mount, dict):
            _fail("COMPOSE_VOLUME_INVALID")
        target = mount.get("target")
        if isinstance(target, str) and (target == "/backups" or target.startswith("/backups/")):
            if target != "/backups":
                _fail("COMPOSE_BACKUP_MOUNT_SHADOWED")
            archive_mounts.append(mount)
        if target in (SOURCE_SIGNING_KEY_CONTAINER_PATH, SOURCE_RATE_KEY_CONTAINER_PATH):
            if target in key_mounts:
                _fail("COMPOSE_KEY_MOUNT_INVALID")
            key_mounts[target] = mount
    if len(archive_mounts) != 1:
        _fail("COMPOSE_BACKUP_MOUNT_REQUIRED")
    mount = archive_mounts[0]
    mount_source = mount.get("source")
    if mount.get("type") != "bind" or not isinstance(mount_source, str) or not Path(mount_source).is_absolute():
        _fail("COMPOSE_BACKUP_MOUNT_INVALID")
    try:
        source = Path(mount_source).resolve(strict=True)
    except OSError:
        _fail("COMPOSE_BACKUP_MOUNT_INVALID")
    if source != archive_host or mount.get("read_only") is True:
        _fail("COMPOSE_BACKUP_MOUNT_MISMATCH")
    if set(key_mounts) != {SOURCE_SIGNING_KEY_CONTAINER_PATH, SOURCE_RATE_KEY_CONTAINER_PATH}:
        _fail("COMPOSE_KEY_MOUNT_REQUIRED")
    for target, expected_source in (
        (SOURCE_SIGNING_KEY_CONTAINER_PATH, host_signing),
        (SOURCE_RATE_KEY_CONTAINER_PATH, host_rate),
    ):
        key_mount = key_mounts[target]
        key_source = key_mount.get("source")
        bind_options = key_mount.get("bind")
        if (
            key_mount.get("type") != "bind"
            or not isinstance(key_source, str)
            or Path(key_source).resolve(strict=True) != expected_source
            or key_mount.get("read_only") is not True
            or not isinstance(bind_options, dict)
            or bind_options.get("create_host_path") is not False
        ):
            _fail("COMPOSE_KEY_MOUNT_MISMATCH")
    return config


def _read_receipt(job_id: str, values: dict[str, str]) -> tuple[dict[str, Any], Path, str]:
    _, stage_url, _, _ = _validate_pg_settings(values)
    archive_host = _archive_host_dir(values)
    container_stage = f"/backups/restore-staging/atermius-pg-restore-{job_id}"
    host_stage = archive_host / "restore-staging" / f"atermius-pg-restore-{job_id}"
    _safe_path_components(host_stage)
    try:
        stage_meta = host_stage.lstat()
    except OSError:
        _fail("RESTORE_STAGE_UNAVAILABLE")
    if not stat.S_ISDIR(stage_meta.st_mode) or stat.S_IMODE(stage_meta.st_mode) != 0o700 or stage_meta.st_uid != SERVICE_UID:
        _fail("RESTORE_STAGE_UNSAFE")
    receipt_path = host_stage / "postgres-restore-receipt.json"
    raw = _read_private_regular(receipt_path, mode=0o600, owner_uid=SERVICE_UID, max_bytes=4096)
    try:
        receipt = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        _fail("RESTORE_RECEIPT_INVALID")
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_FIELDS:
        _fail("RESTORE_RECEIPT_INVALID")
    if isinstance(receipt.get("format_version"), bool) or receipt.get("format_version") != 1 or receipt.get("job_id") != job_id:
        _fail("RESTORE_RECEIPT_MISMATCH")
    for field in ("archive_id", "generation", "object_store_id", "binding_id"):
        if not _canonical_uuid(receipt.get(field)):
            _fail("RESTORE_RECEIPT_INVALID")
    if not HEX_256_RE.fullmatch(str(receipt.get("archive_sha256", ""))) or not HEX_256_RE.fullmatch(str(receipt.get("target_fingerprint", ""))):
        _fail("RESTORE_RECEIPT_INVALID")
    if not isinstance(receipt.get("schema"), str) or not SCHEMA_RE.fullmatch(receipt["schema"]):
        _fail("RESTORE_RECEIPT_INVALID")
    if isinstance(receipt.get("restored_objects"), bool) or not isinstance(receipt.get("restored_objects"), int) or receipt["restored_objects"] < 0:
        _fail("RESTORE_RECEIPT_INVALID")
    if isinstance(receipt.get("target_database_oid"), bool) or not isinstance(receipt.get("target_database_oid"), int) or receipt["target_database_oid"] <= 0:
        _fail("RESTORE_RECEIPT_INVALID")
    if not isinstance(receipt.get("target_database_name"), str) or len(receipt["target_database_name"]) > 63:
        _fail("RESTORE_RECEIPT_INVALID")
    stage_database = _parse_pg_url(stage_url)[2]
    if receipt["target_database_name"] != stage_database or receipt["target_fingerprint"] != _sha256(stage_url.encode("utf-8")):
        _fail("RESTORE_TARGET_RECEIPT_MISMATCH")
    object_root = host_stage / "object-store"
    _validate_stage_tree(host_stage, object_root)
    for name in ("instance-ed25519.key", "auth-rate-limit.key"):
        key_bytes = _read_private_regular(host_stage / name, mode=0o600, owner_uid=SERVICE_UID, max_bytes=64)
        if len(key_bytes) != 32:
            _fail("RESTORE_STAGE_KEY_INVALID")
    return receipt, host_stage, container_stage


def _validate_stage_tree(stage_dir: Path, object_root: Path) -> None:
    allowed_root = {
        "postgres-restore-receipt.json",
        "instance-ed25519.key",
        "auth-rate-limit.key",
        "object-store",
    }
    try:
        entries = list(stage_dir.iterdir())
    except OSError:
        _fail("RESTORE_STAGE_UNAVAILABLE")
    if {entry.name for entry in entries} != allowed_root:
        _fail("RESTORE_STAGE_CONTENTS_INVALID")
    for entry in entries:
        try:
            item = entry.lstat()
        except OSError:
            _fail("RESTORE_STAGE_CONTENTS_INVALID")
        if stat.S_ISLNK(item.st_mode):
            _fail("SYMLINK_REJECTED")
        if entry.name == "object-store":
            if not stat.S_ISDIR(item.st_mode):
                _fail("RESTORE_STAGE_CONTENTS_INVALID")
        elif not stat.S_ISREG(item.st_mode):
            _fail("RESTORE_STAGE_CONTENTS_INVALID")
    try:
        metadata = object_root.lstat()
    except OSError:
        _fail("RESTORE_OBJECT_STORE_UNAVAILABLE")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != SERVICE_UID or stat.S_IMODE(metadata.st_mode) != 0o700:
        _fail("RESTORE_OBJECT_STORE_UNSAFE")
    for root, dirs, files in os.walk(object_root, topdown=True, followlinks=False):
        root_path = Path(root)
        for name in dirs:
            path = root_path / name
            try:
                item = path.lstat()
            except OSError:
                _fail("RESTORE_OBJECT_STORE_UNSAFE")
            if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid != SERVICE_UID or stat.S_IMODE(item.st_mode) != 0o700:
                _fail("RESTORE_OBJECT_STORE_UNSAFE")
        for name in files:
            path = root_path / name
            try:
                item = path.lstat()
            except OSError:
                _fail("RESTORE_OBJECT_STORE_UNSAFE")
            if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid != SERVICE_UID or stat.S_IMODE(item.st_mode) != 0o600 or item.st_nlink != 1:
                _fail("RESTORE_OBJECT_STORE_UNSAFE")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _health_base(values: dict[str, str]) -> str:
    raw = values.get("ATERMIUS_HOST_PORT", "8080")
    if not re.fullmatch(r"[0-9]{1,5}", raw):
        _fail("HEALTH_PORT_INVALID")
    port = int(raw)
    if port < 1 or port > 65535:
        _fail("HEALTH_PORT_INVALID")
    return f"http://127.0.0.1:{port}"


def _http_json(base: str, path: str) -> dict[str, Any]:
    opener = urllib.request.build_opener(_NoRedirect())
    request = urllib.request.Request(base + path, headers={"Accept": "application/json"}, method="GET")
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                _fail("HEALTH_RESPONSE_INVALID")
            payload = response.read(65537)
    except CutoverError:
        raise
    except (OSError, urllib.error.URLError, urllib.error.HTTPError):
        _fail("HEALTH_UNAVAILABLE")
    if len(payload) > 65536:
        _fail("HEALTH_RESPONSE_INVALID")
    try:
        result = json.loads(payload)
    except (json.JSONDecodeError, UnicodeDecodeError):
        _fail("HEALTH_RESPONSE_INVALID")
    if not isinstance(result, dict):
        _fail("HEALTH_RESPONSE_INVALID")
    return result


def _instance_identity(base: str) -> dict[str, str]:
    payload = _http_json(base, "/api/v1/instance")
    identity = {key: payload.get(key) for key in IDENTITY_FIELDS}
    if any(not isinstance(value, str) or not value for value in identity.values()):
        _fail("INSTANCE_IDENTITY_INVALID")
    if not _canonical_uuid(identity["instance_id"]) or not _canonical_uuid(identity["server_space_id"]) or not _canonical_uuid(identity["generation"]):
        _fail("INSTANCE_IDENTITY_INVALID")
    # The instance signing key is a 32-byte base64url public key.
    signing = identity["signing_public_key"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", signing):
        _fail("INSTANCE_IDENTITY_INVALID")
    return identity


def _wait_ready(base: str, timeout_seconds: int) -> dict[str, str]:
    deadline = time.monotonic() + timeout_seconds
    last = "HEALTH_UNAVAILABLE"
    while time.monotonic() < deadline:
        try:
            health = _http_json(base, "/health/ready")
            if health.get("status") == "ready":
                return _instance_identity(base)
            last = "HEALTH_NOT_READY"
        except CutoverError as error:
            last = error.code
        time.sleep(0.5)
    _fail(last)


def _running_server_count() -> int:
    result = _run_compose(["ps", "--status", "running", "-q", SERVICE], timeout=30)
    return len([line for line in result.stdout.splitlines() if line.strip()])


def _compose_config_document() -> dict[str, Any]:
    result = _run_compose(["config", "--format", "json"], timeout=30)
    if len(result.stdout) > 2_000_000:
        _fail("COMPOSE_CONFIG_INVALID")
    try:
        config = json.loads(result.stdout)
    except json.JSONDecodeError:
        _fail("COMPOSE_CONFIG_INVALID")
    if not isinstance(config, dict):
        _fail("COMPOSE_CONFIG_INVALID")
    return config


def _runtime_env_from_values(values: dict[str, str]) -> dict[str, str]:
    return {
        BACKEND_KEY: "postgres",
        PG_URL_KEY: _require_env(values, PG_URL_KEY),
        PG_SCHEMA_KEY: _require_env(values, PG_SCHEMA_KEY),
        RESTORE_TARGET_KEY: _require_env(values, RESTORE_TARGET_KEY),
        SIGNING_KEY_FILE_KEY: _require_env(values, SIGNING_KEY_FILE_KEY),
        RATE_KEY_FILE_KEY: _require_env(values, RATE_KEY_FILE_KEY),
        OBJECT_BACKEND_KEY: "filesystem",
        OBJECT_ROOT_KEY: values.get(OBJECT_ROOT_KEY, "/object-store"),
        BACKUP_ARCHIVE_DIR_KEY: "/backups",
        "ATERMIUS_BACKUP_KEY_FILE": "/backup-key/atermius-backup.key",
    }


def _expected_runtime_mounts(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    services = config.get("services")
    service = services.get(SERVICE) if isinstance(services, dict) else None
    volumes = service.get("volumes") if isinstance(service, dict) else None
    declared_volumes = config.get("volumes")
    if not isinstance(volumes, list) or not isinstance(declared_volumes, dict):
        _fail("COMPOSE_VOLUME_INVALID")
    expected: dict[str, dict[str, Any]] = {}
    for mount in volumes:
        if not isinstance(mount, dict) or mount.get("target") not in RUNTIME_MOUNT_TARGETS:
            continue
        target = mount["target"]
        mount_type = mount.get("type")
        source = mount.get("source")
        readonly = mount.get("read_only") is True
        if target in expected or not isinstance(source, str):
            _fail("COMPOSE_VOLUME_INVALID")
        if mount_type == "bind":
            try:
                resolved_source = str(Path(source).resolve(strict=True))
            except OSError:
                _fail("COMPOSE_VOLUME_INVALID")
            expected[target] = {"type": "bind", "source": resolved_source, "read_only": readonly}
        elif mount_type == "volume":
            definition = declared_volumes.get(source)
            name = definition.get("name") if isinstance(definition, dict) else None
            if not isinstance(name, str) or not name:
                _fail("COMPOSE_VOLUME_INVALID")
            expected[target] = {"type": "volume", "name": name, "read_only": readonly}
        else:
            _fail("COMPOSE_VOLUME_INVALID")
    if set(expected) != RUNTIME_MOUNT_TARGETS:
        _fail("COMPOSE_VOLUME_INVALID")
    return expected


def _validate_current_server_config(
    *,
    allow_absent: bool = False,
    expected_runtime_envs: list[dict[str, str]] | None = None,
) -> None:
    # `up --force-recreate server` applies the current invocation's complete
    # config to the replacement. Refuse to mutate a service originally created
    # with extra overlays (for example Caddy networking or MFA mounts), or a
    # different file order, since this coordinator deliberately supports only
    # its fixed base + backup + filesystem + PostgreSQL stack.
    result = _run_compose(["ps", "--all", "-q", SERVICE], timeout=30)
    container_ids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not container_ids and allow_absent:
        return
    if len(container_ids) != 1 or not CONTAINER_ID_RE.fullmatch(container_ids[0]):
        _fail("COMPOSE_SINGLE_SERVER_REQUIRED")
    command = [
        "docker", "--context", _local_docker_context(), "inspect",
        "--format", "{{json .}}", container_ids[0],
    ]
    try:
        inspected = subprocess.run(
            command,
            cwd=ROOT,
            env=_compose_environment(),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _fail("COMPOSE_INSPECT_TIMEOUT")
    except OSError:
        _fail("COMPOSE_INSPECT_UNAVAILABLE")
    if inspected.returncode != 0 or len(inspected.stdout) > 1_000_000:
        _fail("COMPOSE_INSPECT_FAILED")
    expected = ",".join(str(path) for path in COMPOSE_FILES)
    try:
        container = json.loads(inspected.stdout)
    except json.JSONDecodeError:
        _fail("COMPOSE_INSPECT_FAILED")
    config = container.get("Config") if isinstance(container, dict) else None
    labels = config.get("Labels") if isinstance(config, dict) else None
    if not isinstance(labels, dict) or labels.get("com.docker.compose.project.config_files") != expected:
        _fail("COMPOSE_CONFIG_FILES_MISMATCH")
    container_env = config.get("Env") if isinstance(config, dict) else None
    if not isinstance(container_env, list):
        _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
    actual_env: dict[str, str] = {}
    for entry in container_env:
        if not isinstance(entry, str) or "=" not in entry:
            _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
        key, value = entry.split("=", 1)
        if key in actual_env:
            _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
        actual_env[key] = value
    if expected_runtime_envs is None:
        expected_runtime_envs = [_runtime_env_from_values(_read_env(ENV_FILE).values)]
    if not any(
        all(actual_env.get(key) == value for key, value in expected_env.items())
        for expected_env in expected_runtime_envs
    ):
        _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")

    expected_mounts = _expected_runtime_mounts(_compose_config_document())
    actual_mounts = container.get("Mounts") if isinstance(container, dict) else None
    if not isinstance(actual_mounts, list):
        _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
    actual_by_target = {
        mount.get("Destination"): mount
        for mount in actual_mounts
        if isinstance(mount, dict) and mount.get("Destination") in RUNTIME_MOUNT_TARGETS
    }
    if set(actual_by_target) != RUNTIME_MOUNT_TARGETS:
        _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
    for target, wanted in expected_mounts.items():
        actual = actual_by_target[target]
        if actual.get("Type") != wanted["type"] or actual.get("RW") is not (not wanted["read_only"]):
            _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
        if wanted["type"] == "bind":
            source = actual.get("Source")
            if not isinstance(source, str):
                _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
            try:
                source = str(Path(source).resolve(strict=True))
            except OSError:
                _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
            if source != wanted["source"]:
                _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")
        elif actual.get("Name") != wanted["name"]:
            _fail("COMPOSE_RUNTIME_CONFIG_MISMATCH")


def _stage_values(original: dict[str, str], receipt: dict[str, Any], stage_dir: str) -> tuple[dict[str, str], dict[str, str]]:
    source, stage_url, next_url, _ = _validate_pg_settings(original)
    stage_root = f"{stage_dir}/object-store"
    signing = f"{stage_dir}/instance-ed25519.key"
    rate = f"{stage_dir}/auth-rate-limit.key"
    updates = {
        PG_URL_KEY: stage_url,
        RESTORE_TARGET_KEY: next_url,
        OBJECT_BACKEND_KEY: "filesystem",
        OBJECT_ROOT_KEY: stage_root,
        SIGNING_KEY_FILE_KEY: signing,
        RATE_KEY_FILE_KEY: rate,
    }
    # Keep source in memory only; equality is checked before any mutation.
    return updates, {"source": source, "stage": stage_url, "next": next_url}


def _rollback_values(original_raw: bytes, next_url: str) -> bytes:
    return _rewrite_env(original_raw, {RESTORE_TARGET_KEY: next_url})


def _stage_env_bytes(original_raw: bytes, updates: dict[str, str]) -> bytes:
    return _rewrite_env(original_raw, updates)


def _ensure_confirmations(confirm_ingress: bool, confirm_writers: bool) -> None:
    if not confirm_ingress or not confirm_writers:
        _fail("OPERATOR_CONFIRMATION_REQUIRED")


def _read_source_identity(base: str) -> dict[str, str]:
    health = _http_json(base, "/health/ready")
    if health.get("status") != "ready":
        _fail("SOURCE_NOT_READY")
    return _instance_identity(base)


def _verify_identity(actual: dict[str, str], expected_source: dict[str, str], expected_generation: str) -> None:
    for field in ("instance_id", "server_space_id", "signing_public_key"):
        if actual.get(field) != expected_source.get(field):
            _fail("INSTANCE_IDENTITY_MISMATCH")
    if actual.get("generation") != expected_generation:
        _fail("INSTANCE_GENERATION_MISMATCH")


def _backup_original_env(backup_path: Path, env_doc: EnvDocument) -> None:
    if backup_path.exists() or backup_path.is_symlink():
        existing = _read_private_regular(backup_path, mode=0o600, owner_uid=os.geteuid())
        if existing != env_doc.raw:
            _fail("ENV_BACKUP_CONFLICT")
        return
    _atomic_create(backup_path, env_doc.raw, mode=0o600)


def _load_original_backup(backup_path: Path, expected_hash: str) -> bytes:
    raw = _read_private_regular(backup_path, mode=0o600, owner_uid=os.geteuid())
    if _sha256(raw) != expected_hash:
        _fail("ENV_BACKUP_INVALID")
    _parse_env(raw)
    return raw


def _journal_new(job_id: str, receipt: dict[str, Any], source: dict[str, str],
                 original_env: bytes, staged_env: bytes, rollback_env: bytes,
                 compose_sha: str) -> dict[str, Any]:
    return {
        "version": JOURNAL_VERSION,
        "job_id": job_id,
        "phase": "prepared",
        "created_at": _now(),
        "updated_at": _now(),
        "original_env_sha256": _sha256(original_env),
        "backup_env_sha256": _sha256(original_env),
        "staged_env_sha256": _sha256(staged_env),
        "rollback_env_sha256": _sha256(rollback_env),
        "compose_sha256": compose_sha,
        "receipt": {key: receipt[key] for key in RECEIPT_FIELDS},
        "source_identity": dict(source),
        "last_error_code": "",
    }


def _set_phase(journal_path: Path, journal: dict[str, Any], phase: str,
               error_code: str = "") -> None:
    if phase not in PHASES:
        _fail("JOURNAL_INVALID")
    journal["phase"] = phase
    journal["last_error_code"] = error_code
    _write_journal(journal_path, journal)


def _run_start_server() -> None:
    _run_compose(["up", "-d", "--no-deps", "--force-recreate", SERVICE], timeout=180)


def _stop_server() -> None:
    _run_compose(["stop", "--timeout", "30", SERVICE], timeout=60)


def _activate_stage(job_id: str, receipt: dict[str, Any]) -> None:
    result = _run_compose(
        ["run", "--rm", "--no-deps", "-T", SERVICE,
         "activate-pg-restore-stage", "--job-id", job_id],
        timeout=120,
    )
    # The CLI must give an explicit safe JSON commit receipt. Never echo it.
    try:
        payload = json.loads(result.stdout.strip())
    except (json.JSONDecodeError, UnicodeDecodeError):
        _fail("ACTIVATION_RECEIPT_INVALID")
    expected_fields = {
        "status", "job_id", "target_database_name", "target_database_oid", "schema",
        "generation", "object_store_id", "restored_objects", "activation_timestamp",
    }
    if not isinstance(payload, dict) or set(payload) != expected_fields:
        _fail("ACTIVATION_RECEIPT_INVALID")
    if (
        payload.get("job_id") != job_id
        or payload.get("status") not in ("activated", "already_activated")
        or not isinstance(payload.get("target_database_name"), str)
        or isinstance(payload.get("target_database_oid"), bool)
        or not isinstance(payload.get("target_database_oid"), int)
        or not isinstance(payload.get("schema"), str)
        or not isinstance(payload.get("generation"), str)
        or not isinstance(payload.get("object_store_id"), str)
        or isinstance(payload.get("restored_objects"), bool)
        or not isinstance(payload.get("restored_objects"), int)
        or payload.get("target_database_name") != receipt["target_database_name"]
        or payload.get("target_database_oid") != receipt["target_database_oid"]
        or payload.get("schema") != receipt["schema"]
        or payload.get("generation") != receipt["generation"]
        or payload.get("object_store_id") != receipt["object_store_id"]
        or payload.get("restored_objects") != receipt["restored_objects"]
        or not isinstance(payload.get("activation_timestamp"), str)
        or not payload["activation_timestamp"]
    ):
        _fail("ACTIVATION_RECEIPT_INVALID")


def _fence_stage_rollback(job_id: str, receipt: dict[str, Any]) -> None:
    result = _run_compose(
        ["run", "--rm", "--no-deps", "-T", SERVICE,
         "fence-pg-restore-stage-rollback", "--job-id", job_id],
        timeout=120,
    )
    try:
        payload = json.loads(result.stdout.strip())
    except (json.JSONDecodeError, UnicodeDecodeError):
        _fail("ROLLBACK_FENCE_RECEIPT_INVALID")
    expected_fields = {
        "status", "job_id", "target_database_name", "target_database_oid", "schema",
        "generation", "object_store_id", "restored_objects", "rollback_timestamp",
    }
    if not isinstance(payload, dict) or set(payload) != expected_fields:
        _fail("ROLLBACK_FENCE_RECEIPT_INVALID")
    status = payload.get("status")
    timestamp = payload.get("rollback_timestamp")
    timestamp_valid = timestamp is None
    if isinstance(timestamp, str) and timestamp.endswith("Z"):
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            timestamp_valid = True
        except ValueError:
            timestamp_valid = False
    if (
        payload.get("job_id") != job_id
        or status not in ("fenced", "already_fenced", "activated")
        or not isinstance(payload.get("target_database_name"), str)
        or isinstance(payload.get("target_database_oid"), bool)
        or not isinstance(payload.get("target_database_oid"), int)
        or not isinstance(payload.get("schema"), str)
        or not isinstance(payload.get("generation"), str)
        or not isinstance(payload.get("object_store_id"), str)
        or isinstance(payload.get("restored_objects"), bool)
        or not isinstance(payload.get("restored_objects"), int)
        or payload.get("target_database_name") != receipt["target_database_name"]
        or payload.get("target_database_oid") != receipt["target_database_oid"]
        or payload.get("schema") != receipt["schema"]
        or payload.get("generation") != receipt["generation"]
        or payload.get("object_store_id") != receipt["object_store_id"]
        or payload.get("restored_objects") != receipt["restored_objects"]
        or not timestamp_valid
        or (status == "activated" and timestamp is not None)
        or (status != "activated" and not isinstance(timestamp, str))
    ):
        _fail("ROLLBACK_FENCE_RECEIPT_INVALID")
    if status == "activated":
        _fail("RESTORE_STAGE_ACTIVATED")


def _verify_source_after_rollback(base: str, source: dict[str, str]) -> None:
    if _running_server_count() != 1:
        _fail("SOURCE_RESTART_UNVERIFIED")
    actual = _wait_ready(base, DEFAULT_HEALTH_TIMEOUT_SECONDS)
    for field in IDENTITY_FIELDS:
        if actual[field] != source[field]:
            _fail("SOURCE_IDENTITY_UNVERIFIED")


def _rollback_before_activation(journal_path: Path, backup_path: Path,
                                journal: dict[str, Any], base: str) -> dict[str, Any]:
    if journal["phase"] in {"activating", "activation_uncertain", "committed"}:
        _fail("ACTIVATION_STATE_UNCERTAIN")
    if _compose_hash() != journal["compose_sha256"]:
        _fail("COMPOSE_CHANGED")
    original = _load_original_backup(backup_path, journal["backup_env_sha256"])
    original_values = _parse_env(original)[2]
    stage_dir = f"/backups/restore-staging/atermius-pg-restore-{journal['job_id']}"
    stage_updates, urls = _stage_values(original_values, journal["receipt"], stage_dir)
    staged_env = _stage_env_bytes(original, stage_updates)
    next_url = _require_env(original_values, NEXT_TARGET_KEY)
    rollback = _rollback_values(original, next_url)
    if _sha256(rollback) != journal["rollback_env_sha256"]:
        _fail("ENV_BACKUP_INVALID")
    staged_values = _parse_env(staged_env)[2]
    rollback_values = _parse_env(rollback)[2]
    runtime_envs = [
        _runtime_env_from_values(original_values),
        _runtime_env_from_values(staged_values),
        _runtime_env_from_values(rollback_values),
    ]
    _set_phase(journal_path, journal, "rolling_back")
    try:
        current = _read_env(ENV_FILE)
        current_hash = _sha256(current.raw)
        if current_hash not in {
            journal["original_env_sha256"],
            journal["staged_env_sha256"],
            journal["rollback_env_sha256"],
        }:
            _fail("ENV_CHANGED")
        _validate_current_server_config(allow_absent=True, expected_runtime_envs=runtime_envs)
        if _running_server_count() > 0:
            _stop_server()
        # Fence the stage database before switching back. Reapply the staged
        # settings after a crash during rollback so the fence command always
        # targets the receipt-bound database, regardless of the current .env.
        current = _read_env(ENV_FILE)
        current_hash = _sha256(current.raw)
        if current_hash != journal["staged_env_sha256"]:
            _atomic_replace(
                ENV_FILE,
                staged_env,
                mode=0o600,
                owner_uid=os.geteuid(),
                expected_sha256=current_hash,
            )
        _validate_compose(
            staged_values,
            expected_pg_url=urls["stage"],
            expected_restore_url=urls["next"],
            expected_object_root=f"{stage_dir}/object-store",
            expected_signing_file=f"{stage_dir}/instance-ed25519.key",
            expected_rate_file=f"{stage_dir}/auth-rate-limit.key",
        )
        _fence_stage_rollback(journal["job_id"], journal["receipt"])
        current = _read_env(ENV_FILE)
        current_hash = _sha256(current.raw)
        if current_hash != journal["rollback_env_sha256"]:
            _atomic_replace(
                ENV_FILE,
                rollback,
                mode=0o600,
                owner_uid=os.geteuid(),
                expected_sha256=current_hash,
            )
        _validate_compose(
            rollback_values,
            expected_pg_url=_require_env(original_values, PG_URL_KEY),
            expected_restore_url=next_url,
            expected_object_root=rollback_values.get(OBJECT_ROOT_KEY, "/object-store"),
            expected_signing_file=_require_env(rollback_values, SIGNING_KEY_FILE_KEY),
            expected_rate_file=_require_env(rollback_values, RATE_KEY_FILE_KEY),
            source_key_paths_active=True,
        )
        _validate_current_server_config(allow_absent=True, expected_runtime_envs=runtime_envs)
        _run_start_server()
        _verify_source_after_rollback(base, journal["source_identity"])
    except CutoverError as error:
        if error.code == "RESTORE_STAGE_ACTIVATED":
            _set_phase(journal_path, journal, "activation_uncertain", error.code)
            with contextlib.suppress(CutoverError):
                if _running_server_count() == 0:
                    _run_start_server()
                actual = _wait_ready(base, DEFAULT_HEALTH_TIMEOUT_SECONDS)
                _verify_identity(actual, journal["source_identity"], journal["receipt"]["generation"])
            _fail("ACTIVATION_STATE_UNCERTAIN")
        _set_phase(journal_path, journal, "rollback_pending", error.code)
        raise
    _set_phase(journal_path, journal, "rolled_back")
    return {"state": "rolled_back", "job_id": journal["job_id"]}


def _resume_apply(journal_path: Path, backup_path: Path, journal: dict[str, Any],
                  base: str, timeout_seconds: int) -> dict[str, Any]:
    if _compose_hash() != journal["compose_sha256"]:
        _fail("COMPOSE_CHANGED")
    job_id = journal["job_id"]
    original = _load_original_backup(backup_path, journal["backup_env_sha256"])
    original_values = _parse_env(original)[2]
    stage_dir = f"/backups/restore-staging/atermius-pg-restore-{job_id}"
    updates, urls = _stage_values(original_values, journal["receipt"], stage_dir)
    staged_env = _stage_env_bytes(original, updates)
    staged_values = _parse_env(staged_env)[2]
    rollback_env = _rollback_values(original, urls["next"])
    if _sha256(staged_env) != journal["staged_env_sha256"] or _sha256(rollback_env) != journal["rollback_env_sha256"]:
        _fail("JOURNAL_CONFIG_MISMATCH")
    phase = journal["phase"]
    if phase in {"prepared", "stopping_source"}:
        current = _read_env(ENV_FILE)
        if _sha256(current.raw) != journal["original_env_sha256"]:
            _fail("ENV_CHANGED")
        _set_phase(journal_path, journal, "stopping_source")
        if _running_server_count() > 1:
            _fail("COMPOSE_SINGLE_SERVER_REQUIRED")
        _validate_current_server_config()
        _stop_server()
        _set_phase(journal_path, journal, "source_stopped")
        phase = "source_stopped"
    if phase == "source_stopped":
        current = _read_env(ENV_FILE)
        if _sha256(current.raw) == journal["original_env_sha256"]:
            _atomic_replace(ENV_FILE, staged_env, mode=0o600, owner_uid=os.geteuid(), expected_sha256=journal["original_env_sha256"])
        elif _sha256(current.raw) != journal["staged_env_sha256"]:
            _fail("ENV_CHANGED")
        _set_phase(journal_path, journal, "config_staged")
        phase = "config_staged"
    if phase in {"config_staged", "starting_stage"}:
        current = _read_env(ENV_FILE)
        if _sha256(current.raw) != journal["staged_env_sha256"]:
            _fail("ENV_CHANGED")
        _set_phase(journal_path, journal, "starting_stage")
        _validate_compose(staged_values, expected_pg_url=urls["stage"], expected_restore_url=urls["next"],
                          expected_object_root=f"{stage_dir}/object-store",
                          expected_signing_file=f"{stage_dir}/instance-ed25519.key",
                          expected_rate_file=f"{stage_dir}/auth-rate-limit.key")
        _validate_current_server_config(
            allow_absent=True,
            expected_runtime_envs=[
                _runtime_env_from_values(original_values),
                _runtime_env_from_values(staged_values),
            ],
        )
        if _running_server_count() == 0:
            _run_start_server()
        actual = _wait_ready(base, timeout_seconds)
        _verify_identity(actual, journal["source_identity"], journal["receipt"]["generation"])
        _set_phase(journal_path, journal, "stage_verified")
        phase = "stage_verified"
    if phase == "stage_verified":
        current = _read_env(ENV_FILE)
        if _sha256(current.raw) != journal["staged_env_sha256"]:
            _fail("ENV_CHANGED")
        _set_phase(journal_path, journal, "activating")
        phase = "activating"
    if phase in {"activating", "activation_uncertain"}:
        # Once the activation CLI may have committed, rollback is forbidden.
        try:
            current = _read_env(ENV_FILE)
            if _sha256(current.raw) != journal["staged_env_sha256"]:
                _fail("ENV_CHANGED")
            _validate_current_server_config(
                allow_absent=True,
                expected_runtime_envs=[_runtime_env_from_values(staged_values)],
            )
            if _running_server_count() == 0:
                _run_start_server()
            actual = _wait_ready(base, timeout_seconds)
            _verify_identity(actual, journal["source_identity"], journal["receipt"]["generation"])
            _activate_stage(job_id, journal["receipt"])
        except CutoverError as error:
            _set_phase(journal_path, journal, "activation_uncertain", error.code)
            _fail("ACTIVATION_UNCERTAIN")
        _set_phase(journal_path, journal, "committed")
    if journal["phase"] == "committed":
        return {
            "state": "committed",
            "job_id": job_id,
            "generation": journal["receipt"]["generation"],
            "ingress_action": "untouched",
        }
    if journal["phase"] in {"rolled_back", "rollback_pending", "rolling_back"}:
        _fail("CUTOVER_NOT_COMMITTED")
    return {"state": journal["phase"], "job_id": job_id, "ingress_action": "untouched"}


def apply(job_id: str, *, confirm_ingress_drained: bool, confirm_writers_stopped: bool,
          timeout_seconds: int = DEFAULT_HEALTH_TIMEOUT_SECONDS) -> dict[str, Any]:
    _ensure_confirmations(confirm_ingress_drained, confirm_writers_stopped)
    if not _canonical_uuid(job_id):
        _fail("JOB_ID_INVALID")
    if timeout_seconds < 1 or timeout_seconds > MAX_HEALTH_TIMEOUT_SECONDS:
        _fail("HEALTH_TIMEOUT_INVALID")
    _local_docker_context()
    with _locked_state(job_id) as (journal_path, backup_path, _):
        if journal_path.exists():
            journal = _read_journal(journal_path, job_id)
            if journal["phase"] == "committed":
                return {"state": "committed", "job_id": job_id, "generation": journal["receipt"]["generation"], "ingress_action": "untouched"}
            _fail("CUTOVER_ALREADY_STARTED")
        env_doc = _read_env(ENV_FILE)
        source_url, stage_url, next_url, schema = _validate_pg_settings(env_doc.values)
        receipt, _host_stage, container_stage = _read_receipt(job_id, env_doc.values)
        if receipt["schema"] != schema:
            _fail("RESTORE_SCHEMA_MISMATCH")
        source_db = _parse_pg_url(source_url)[2]
        if receipt["target_database_name"] == source_db:
            _fail("RESTORE_TARGET_IS_SOURCE")
        base = _health_base(env_doc.values)
        source_identity = _read_source_identity(base)
        if receipt["generation"] == source_identity["generation"]:
            _fail("RESTORE_GENERATION_NOT_ROTATED")
        archive_stage = f"/backups/restore-staging/atermius-pg-restore-{job_id}"
        updates, _urls = _stage_values(env_doc.values, receipt, archive_stage)
        staged_env = _stage_env_bytes(env_doc.raw, updates)
        rollback_env = _rollback_values(env_doc.raw, next_url)
        _validate_compose(
            env_doc.values,
            expected_pg_url=source_url,
            expected_restore_url=stage_url,
            expected_object_root=env_doc.values.get(OBJECT_ROOT_KEY, "/object-store"),
            expected_signing_file=env_doc.values[SIGNING_KEY_FILE_KEY],
            expected_rate_file=env_doc.values[RATE_KEY_FILE_KEY],
            source_key_paths_active=True,
        )
        if _running_server_count() != 1:
            _fail("COMPOSE_SINGLE_SERVER_REQUIRED")
        _validate_current_server_config(
            expected_runtime_envs=[_runtime_env_from_values(env_doc.values)],
        )
        compose_sha = _compose_hash()
        _backup_original_env(backup_path, env_doc)
        journal = _journal_new(job_id, receipt, source_identity, env_doc.raw, staged_env, rollback_env, compose_sha)
        _write_journal(journal_path, journal)
        try:
            return _resume_apply(journal_path, backup_path, journal, base, timeout_seconds)
        except CutoverError as error:
            if journal.get("phase") in {"prepared", "stopping_source", "source_stopped", "config_staged", "starting_stage", "stage_verified"}:
                with contextlib.suppress(CutoverError):
                    _rollback_before_activation(journal_path, backup_path, journal, base)
            elif journal.get("phase") == "activating":
                _set_phase(journal_path, journal, "activation_uncertain", error.code)
            raise


def status(job_id: str) -> dict[str, Any]:
    if not _canonical_uuid(job_id):
        _fail("JOB_ID_INVALID")
    with _locked_state(job_id) as (journal_path, _backup_path, _):
        journal = _read_journal(journal_path, job_id)
        return {
            "state": journal["phase"],
            "job_id": job_id,
            "generation": journal["receipt"]["generation"],
            "last_error_code": journal["last_error_code"] or None,
            "ingress_action": "untouched",
            "requires_operator_recovery": journal["phase"] in {"activation_uncertain", "rollback_pending", "rolling_back"},
        }


def rollback(job_id: str, *, confirm_ingress_drained: bool, confirm_writers_stopped: bool) -> dict[str, Any]:
    _ensure_confirmations(confirm_ingress_drained, confirm_writers_stopped)
    if not _canonical_uuid(job_id):
        _fail("JOB_ID_INVALID")
    _local_docker_context()
    with _locked_state(job_id) as (journal_path, backup_path, _):
        journal = _read_journal(journal_path, job_id)
        if journal["phase"] in {"activating", "activation_uncertain", "committed"}:
            _fail("ACTIVATION_STATE_UNCERTAIN")
        original = _load_original_backup(backup_path, journal["backup_env_sha256"])
        base = _health_base(_parse_env(original)[2])
        return _rollback_before_activation(journal_path, backup_path, journal, base)


def recover(job_id: str, *, confirm_ingress_drained: bool, confirm_writers_stopped: bool,
            timeout_seconds: int = DEFAULT_HEALTH_TIMEOUT_SECONDS) -> dict[str, Any]:
    _ensure_confirmations(confirm_ingress_drained, confirm_writers_stopped)
    if not _canonical_uuid(job_id):
        _fail("JOB_ID_INVALID")
    if timeout_seconds < 1 or timeout_seconds > MAX_HEALTH_TIMEOUT_SECONDS:
        _fail("HEALTH_TIMEOUT_INVALID")
    _local_docker_context()
    with _locked_state(job_id) as (journal_path, backup_path, _):
        journal = _read_journal(journal_path, job_id)
        if _compose_hash() != journal["compose_sha256"]:
            _fail("COMPOSE_CHANGED")
        original = _load_original_backup(backup_path, journal["backup_env_sha256"])
        original_values = _parse_env(original)[2]
        base = _health_base(original_values)
        if journal["phase"] == "committed":
            return {"state": "committed", "job_id": job_id, "generation": journal["receipt"]["generation"], "ingress_action": "untouched"}
        if journal["phase"] == "rolled_back":
            return {"state": "rolled_back", "job_id": job_id}
        if journal["phase"] in {"rollback_pending", "rolling_back"}:
            return _rollback_before_activation(journal_path, backup_path, journal, base)
        if journal["phase"] in {"activating", "activation_uncertain"}:
            # It is unsafe to restore the source when the activation marker may exist.
            result = _resume_apply(journal_path, backup_path, journal, base, timeout_seconds)
            return result
        try:
            result = _resume_apply(journal_path, backup_path, journal, base, timeout_seconds)
            return result
        except CutoverError:
            if journal.get("phase") not in {"activating", "activation_uncertain", "committed"}:
                with contextlib.suppress(CutoverError):
                    _rollback_before_activation(journal_path, backup_path, journal, base)
            raise


def _emit(result: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("apply", "status", "rollback", "recover"):
        child = subparsers.add_parser(command)
        child.add_argument("--job-id", required=True)
        if command in {"apply", "rollback", "recover"}:
            child.add_argument("--confirm-ingress-drained", action="store_true")
            child.add_argument("--confirm-all-pg-writers-stopped", action="store_true")
        if command in {"apply", "recover"}:
            child.add_argument("--health-timeout-seconds", type=int, default=DEFAULT_HEALTH_TIMEOUT_SECONDS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "apply":
            result = apply(args.job_id, confirm_ingress_drained=args.confirm_ingress_drained,
                           confirm_writers_stopped=args.confirm_all_pg_writers_stopped,
                           timeout_seconds=args.health_timeout_seconds)
        elif args.command == "status":
            result = status(args.job_id)
        elif args.command == "rollback":
            result = rollback(args.job_id, confirm_ingress_drained=args.confirm_ingress_drained,
                              confirm_writers_stopped=args.confirm_all_pg_writers_stopped)
        else:
            result = recover(args.job_id, confirm_ingress_drained=args.confirm_ingress_drained,
                             confirm_writers_stopped=args.confirm_all_pg_writers_stopped,
                             timeout_seconds=args.health_timeout_seconds)
        _emit(result)
        return 0
    except CutoverError as error:
        sys.stderr.write(f"PG_CUTOVER_ERROR {error.code}\n")
        return 2
    except BaseException:
        # Do not let URLs, credentials, subprocess diagnostics, or receipt bytes
        # enter a traceback/log path. Durable state remains available to recover.
        sys.stderr.write("PG_CUTOVER_ERROR INTERNAL_FAILURE\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
