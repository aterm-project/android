#!/usr/bin/env python3
"""Offline, host-side coordinator for activating an installed restore stage.

This program only operates Docker Compose and the local environment file. It
does not expose an online endpoint and it never removes either data volume.
The durable journal is intentionally small and contains no API credentials or
Compose output.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import urlsplit


SERVICE = "server"
DATA_VOLUME_KEY = "ATERMIUS_DATA_VOLUME_NAME"
DATA_DIR_KEY = "ATERMIUS_DATA_DIR"
DATABASE_URL_KEY = "ATERMIUS_DATABASE_URL"
TARGET_SETTINGS = {
    DATA_DIR_KEY: "/data/restored",
    DATABASE_URL_KEY: "sqlite:///data/restored/atermius.db?mode=rwc",
}
SOURCE_SETTINGS = {
    DATA_DIR_KEY: "/data",
    DATABASE_URL_KEY: "sqlite:///data/atermius.db?mode=rwc",
}
JOURNAL_VERSION = 1
HEALTH_TIMEOUT_DEFAULT = 120
HEALTH_TIMEOUT_MIN = 1
HEALTH_TIMEOUT_MAX = 600
HTTP_TIMEOUT_SECONDS = 5
SERVICE_DATA_UID = 10001
INSTALL_OUTPUT_RE = re.compile(r"\bwith generation ([0-9a-f-]{36})\b")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
VOLUME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
PROJECT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
ENV_KEYS = (DATA_VOLUME_KEY, DATA_DIR_KEY, DATABASE_URL_KEY)
JOURNAL_KEYS = {
    "version",
    "operation",
    "project_name",
    "compose_files",
    "compose_sha256",
    "env_file",
    "env_sha256_initial",
    "journal_path",
    "source_volume",
    "target_volume",
    "restore_job_id",
    "health_url",
    "original_instance_id",
    "original_server_space_id",
    "original_generation",
    "original_settings",
    "installed_generation",
    "target_instance_id",
    "target_server_space_id",
    "target_generation",
    "state",
    "created_at",
    "updated_at",
    "last_error_code",
    "health_timeout_seconds",
    "source_checkpointed_at",
}
JOURNAL_STATES = {
    "prepared", "stopping_source", "source_stopped", "source_quiescent", "installing",
    "installed", "target_starting", "target_verified", "committing", "committed",
    "rolling_back", "rollback_pending", "rolled_back",
}


class CutoverError(Exception):
    """A safe, fixed-category failure suitable for operator display."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _canonical_uuid(value: str) -> bool:
    if not UUID_RE.fullmatch(value):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _safe_directory(path: Path, *, owner_required: bool = True) -> Path:
    """Resolve a path without accepting symlinked path components."""
    absolute = Path(os.path.abspath(path))
    cursor = Path(absolute.anchor)
    for component in absolute.parts[1:-1]:
        cursor = cursor / component
        try:
            metadata = cursor.lstat()
        except OSError as exc:
            raise CutoverError("unsafe_path") from exc
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise CutoverError("unsafe_path")
    parent = absolute.parent
    try:
        metadata = parent.lstat()
    except OSError as exc:
        raise CutoverError("unsafe_path") from exc
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise CutoverError("unsafe_path")
    if owner_required and metadata.st_uid != os.getuid():
        raise CutoverError("unsafe_path_owner")
    if metadata.st_mode & 0o022:
        raise CutoverError("unsafe_path_permissions")
    return absolute


def _safe_regular_file(path: Path, *, private: bool = False, owner_required: bool = False) -> tuple[Path, os.stat_result]:
    absolute = Path(os.path.abspath(path))
    _safe_directory(absolute, owner_required=owner_required)
    try:
        metadata = absolute.lstat()
    except OSError as exc:
        raise CutoverError("unsafe_file") from exc
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_nlink != 1:
        raise CutoverError("unsafe_file")
    if owner_required and metadata.st_uid != os.getuid():
        raise CutoverError("unsafe_file_owner")
    if private and (stat.S_IMODE(metadata.st_mode) != 0o600):
        raise CutoverError("journal_permissions")
    return absolute, metadata


@contextlib.contextmanager
def _journal_lock(path: Path) -> Iterator[None]:
    lock_path = path.with_name(path.name + ".lock")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as exc:
        raise CutoverError("journal_lock_unsafe") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise CutoverError("journal_lock_unsafe")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        raise CutoverError("journal_locked") from exc
    try:
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _atomic_bytes(path: Path, content: bytes, mode: int, *, uid: int | None = None, gid: int | None = None,
                  expected_stat: os.stat_result | None = None) -> None:
    parent = path.parent
    descriptor = -1
    temp_path: Path | None = None
    try:
        descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=parent)
        temp_path = Path(name)
        os.fchmod(descriptor, mode)
        if uid is not None and gid is not None and (os.geteuid() == 0):
            os.fchown(descriptor, uid, gid)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if expected_stat is not None:
            current = path.lstat()
            if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                expected_stat.st_dev, expected_stat.st_ino, expected_stat.st_mtime_ns, expected_stat.st_size
            ):
                raise CutoverError("file_changed_concurrently")
        os.replace(temp_path, path)
        temp_path = None
        dirfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    except OSError as exc:
        raise CutoverError("atomic_write_failed") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temp_path is not None:
            with contextlib.suppress(OSError):
                temp_path.unlink()


def _load_journal(path: Path, *, required: bool = True) -> dict[str, Any] | None:
    try:
        _, metadata = _safe_regular_file(path, private=True, owner_required=True)
    except CutoverError:
        if not required and not path.exists() and not path.is_symlink():
            return None
        raise
    try:
        raw = path.read_bytes()
        if len(raw) > 64 * 1024:
            raise CutoverError("journal_invalid")
        def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, value in pairs:
                if key in result:
                    raise CutoverError("journal_duplicate_key")
                result[key] = value
            return result

        record = json.loads(raw, object_pairs_hook=unique_object)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CutoverError("journal_invalid") from exc
    if not isinstance(record, dict) or set(record) != JOURNAL_KEYS or record.get("version") != JOURNAL_VERSION:
        raise CutoverError("journal_invalid")
    if metadata.st_mode & 0o077 or metadata.st_nlink != 1 or metadata.st_uid != os.getuid():
        raise CutoverError("journal_permissions")
    _validate_journal_record(record, path)
    return record


def _validate_journal_record(record: dict[str, Any], path: Path) -> None:
    if record.get("journal_path") != str(path) or record.get("operation") != "restore_stage_cutover":
        raise CutoverError("journal_mismatch")
    if record.get("state") not in JOURNAL_STATES:
        raise CutoverError("journal_invalid")
    if type(record.get("version")) is not int or record["version"] != JOURNAL_VERSION:
        raise CutoverError("journal_invalid")
    if not isinstance(record.get("project_name"), str) or not PROJECT_RE.fullmatch(record["project_name"]):
        raise CutoverError("journal_invalid")
    for field in ("source_volume", "target_volume"):
        if not isinstance(record.get(field), str) or not VOLUME_RE.fullmatch(record[field]):
            raise CutoverError("journal_invalid")
    if record["source_volume"] == record["target_volume"]:
        raise CutoverError("journal_invalid")
    if not isinstance(record.get("restore_job_id"), str) or not _canonical_uuid(record["restore_job_id"]):
        raise CutoverError("journal_invalid")
    for field in ("original_instance_id", "original_server_space_id", "original_generation"):
        if not isinstance(record.get(field), str) or not _canonical_uuid(record[field]):
            raise CutoverError("journal_invalid")
    for field in ("installed_generation", "target_instance_id", "target_server_space_id", "target_generation"):
        value = record.get(field)
        if value is not None and (not isinstance(value, str) or not _canonical_uuid(value)):
            raise CutoverError("journal_invalid")
    if not isinstance(record.get("compose_files"), list) or not record["compose_files"]:
        raise CutoverError("journal_invalid")
    if any(not isinstance(item, str) or not Path(item).is_absolute() for item in record["compose_files"]):
        raise CutoverError("journal_invalid")
    if not isinstance(record.get("env_file"), str) or not Path(record["env_file"]).is_absolute():
        raise CutoverError("journal_invalid")
    for field in ("compose_sha256", "env_sha256_initial"):
        if not isinstance(record.get(field), str) or not re.fullmatch(r"[0-9a-f]{64}", record[field]):
            raise CutoverError("journal_invalid")
    settings = record.get("original_settings")
    if not isinstance(settings, dict) or settings != {DATA_VOLUME_KEY: record["source_volume"], **SOURCE_SETTINGS}:
        raise CutoverError("journal_invalid")
    if type(record.get("health_timeout_seconds")) is not int or not HEALTH_TIMEOUT_MIN <= record["health_timeout_seconds"] <= HEALTH_TIMEOUT_MAX:
        raise CutoverError("journal_invalid")
    health_url = record.get("health_url")
    if not isinstance(health_url, str) or _validate_health_url(health_url) != health_url:
        raise CutoverError("journal_invalid")
    for field in ("created_at", "updated_at"):
        timestamp = record.get(field)
        if not isinstance(timestamp, str):
            raise CutoverError("journal_invalid")
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError as exc:
            raise CutoverError("journal_invalid") from exc
    checkpointed_at = record.get("source_checkpointed_at")
    if checkpointed_at is not None and not isinstance(checkpointed_at, str):
        raise CutoverError("journal_invalid")
    if checkpointed_at is not None:
        try:
            datetime.fromisoformat(checkpointed_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise CutoverError("journal_invalid") from exc
    if record["state"] in {"source_quiescent", "installing", "installed", "target_starting", "target_verified", "committing", "committed"} and checkpointed_at is None:
        raise CutoverError("journal_invalid")
    if record["state"] in {"installed", "target_starting", "target_verified", "committing", "committed"} and record.get("installed_generation") is None:
        raise CutoverError("journal_invalid")
    if record.get("target_instance_id") is not None and record["target_instance_id"] != record["original_instance_id"]:
        raise CutoverError("journal_invalid")
    if record.get("target_server_space_id") is not None and record["target_server_space_id"] != record["original_server_space_id"]:
        raise CutoverError("journal_invalid")
    if record.get("target_generation") is not None and record["target_generation"] != record.get("installed_generation"):
        raise CutoverError("journal_invalid")
    if record.get("target_generation") is not None and record["target_generation"] == record["original_generation"]:
        raise CutoverError("journal_invalid")
    if record["state"] in {"target_verified", "committing", "committed"} and any(
        record.get(field) is None for field in ("target_instance_id", "target_server_space_id", "target_generation")
    ):
        raise CutoverError("journal_invalid")
    error_code = record.get("last_error_code")
    if error_code is not None and (not isinstance(error_code, str) or not re.fullmatch(r"[a-z0-9_]{1,80}", error_code)):
        raise CutoverError("journal_invalid")


def _save_journal(path: Path, record: dict[str, Any]) -> None:
    if set(record) != JOURNAL_KEYS:
        raise CutoverError("journal_invalid")
    _validate_journal_record(record, path)
    record["updated_at"] = _utc_now()
    raw = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    try:
        _, metadata = _safe_regular_file(path, private=True, owner_required=True)
    except CutoverError as exc:
        if exc.code not in ("unsafe_file",):
            raise
        if path.exists() or path.is_symlink():
            raise
        _atomic_bytes(path, raw, 0o600, uid=os.getuid(), gid=os.getgid())
        return
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise CutoverError("journal_permissions")
    _atomic_bytes(path, raw, 0o600, uid=metadata.st_uid, gid=metadata.st_gid, expected_stat=metadata)


def _run(command: list[str], *, env: dict[str, str], timeout: int = 120) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CutoverError("compose_command_failed") from exc


def _base_env(overrides: dict[str, str] | None = None) -> dict[str, str]:
    env = os.environ.copy()
    for key in ENV_KEYS:
        env.pop(key, None)
    if overrides:
        env.update(overrides)
    return env


def _compose_prefix(project: str, env_file: Path, compose_files: tuple[Path, ...]) -> list[str]:
    command = ["docker", "compose", "--project-name", project, "--env-file", str(env_file)]
    for compose_file in compose_files:
        command.extend(("--file", str(compose_file)))
    return command


def _compose_config(
    project: str,
    env_file: Path,
    compose_files: tuple[Path, ...],
    overrides: dict[str, str] | None = None,
) -> tuple[dict[str, Any], str]:
    completed = _run(
        [*_compose_prefix(project, env_file, compose_files), "config", "--format", "json"],
        env=_base_env(overrides),
    )
    if completed.returncode != 0:
        raise CutoverError("compose_config_failed")
    try:
        config = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise CutoverError("compose_config_invalid") from exc
    if not isinstance(config, dict):
        raise CutoverError("compose_config_invalid")
    # Only a digest leaves this function; Compose output can contain credentials.
    canonical = json.dumps(config, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return config, hashlib.sha256(canonical).hexdigest()


def _source_volume(config: dict[str, Any]) -> str:
    services = config.get("services")
    service = services.get(SERVICE) if isinstance(services, dict) else None
    if not isinstance(service, dict) or not isinstance(service.get("volumes"), list):
        raise CutoverError("compose_data_mount_missing")
    data_mounts = [mount for mount in service["volumes"] if isinstance(mount, dict) and mount.get("target") == "/data"]
    if len(data_mounts) != 1:
        raise CutoverError("compose_data_mount_ambiguous")
    mount = data_mounts[0]
    if mount.get("type") != "volume" or not isinstance(mount.get("source"), str):
        raise CutoverError("compose_data_mount_not_named")
    volume = mount["source"]
    if not VOLUME_RE.fullmatch(volume):
        raise CutoverError("compose_data_volume_invalid")
    definitions = config.get("volumes")
    if not isinstance(definitions, dict) or volume not in definitions or not isinstance(definitions[volume], dict):
        raise CutoverError("compose_data_volume_definition_missing")
    definition = definitions[volume]
    actual_name = definition.get("name")
    if actual_name is None:
        if definition.get("external") is True:
            actual_name = volume
        else:
            project_name = config.get("name")
            if not isinstance(project_name, str):
                raise CutoverError("compose_project_name_missing")
            actual_name = f"{project_name}_{volume}"
    if not isinstance(actual_name, str) or not VOLUME_RE.fullmatch(actual_name):
        raise CutoverError("compose_data_volume_invalid")
    return actual_name


def _source_layout(config: dict[str, Any]) -> dict[str, str]:
    service = config.get("services", {}).get(SERVICE, {})
    environment = service.get("environment") if isinstance(service, dict) else None
    if not isinstance(environment, dict):
        raise CutoverError("compose_data_environment_missing")
    values = {key: environment.get(key) for key in (DATA_DIR_KEY, DATABASE_URL_KEY)}
    if values != SOURCE_SETTINGS:
        raise CutoverError("compose_source_layout_unsupported")
    return values


def _resolve_files(project: str, env_file_arg: str, compose_args: list[str], journal_arg: str) -> tuple[Path, tuple[Path, ...], Path]:
    if not PROJECT_RE.fullmatch(project):
        raise CutoverError("project_name_invalid")
    env_file, _ = _safe_regular_file(Path(env_file_arg), owner_required=True)
    compose_files = tuple(_safe_regular_file(Path(item))[0] for item in compose_args)
    if not compose_files:
        raise CutoverError("compose_file_required")
    journal = Path(os.path.abspath(journal_arg))
    _safe_directory(journal)
    if journal.exists() or journal.is_symlink():
        _safe_regular_file(journal, private=True)
    return env_file, compose_files, journal


def _http_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise CutoverError("health_http_failed")
            raw = response.read(64 * 1024 + 1)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError) as exc:
        raise CutoverError("health_unavailable") from exc
    if len(raw) > 64 * 1024:
        raise CutoverError("health_response_too_large")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CutoverError("health_response_invalid") from exc
    if not isinstance(value, dict):
        raise CutoverError("health_response_invalid")
    return value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def _validate_health_url(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise CutoverError("health_url_invalid")
    if parts.scheme == "http" and parts.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise CutoverError("health_url_requires_https")
    return value.rstrip("/")


def _get_instance(base_url: str) -> dict[str, str]:
    ready = _http_json(base_url + "/health/ready")
    if ready.get("status") != "ready":
        raise CutoverError("health_not_ready")
    instance = _http_json(base_url + "/api/v1/instance")
    keys = ("instance_id", "server_space_id", "generation")
    if any(not isinstance(instance.get(key), str) or not _canonical_uuid(instance[key]) for key in keys):
        raise CutoverError("instance_identity_invalid")
    return {key: instance[key] for key in keys}


def _volume_names(project: str, env_file: Path, compose_files: tuple[Path, ...]) -> set[str]:
    result = _run(["docker", "volume", "ls", "--format", "{{.Name}}"], env=_base_env(), timeout=60)
    if result.returncode != 0:
        raise CutoverError("volume_list_failed")
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def _ensure_volume(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    existing = _volume_names(record["project_name"], env_file, compose_files)
    target = record["target_volume"]
    if target not in existing:
        result = _run(["docker", "volume", "create", "--name", target], env=_base_env(), timeout=60)
        if result.returncode != 0 or result.stdout.strip() != target:
            raise CutoverError("target_volume_create_failed")
    # Read-only inspection deliberately preserves any unrelated target-volume entries.
    command = [
        *_compose_prefix(record["project_name"], env_file, compose_files),
        "run", "--rm", "--no-deps", "--volume", f"{target}:/target:ro",
        "--entrypoint", "/bin/sh", SERVICE, "-ec", "test ! -e /target/restored",
    ]
    checked = _run(command, env=_base_env({DATA_VOLUME_KEY: record["source_volume"]}), timeout=120)
    if checked.returncode != 0:
        raise CutoverError("target_restored_path_exists")


def _compose_call(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...], *args: str,
                  overrides: dict[str, str] | None = None, extra_files: tuple[Path, ...] = (), timeout: int = 180) -> subprocess.CompletedProcess[str]:
    command = _compose_prefix(record["project_name"], env_file, compose_files)
    for extra in extra_files:
        command.extend(("--file", str(extra)))
    return _run([*command, *args], env=_base_env(overrides), timeout=timeout)


def _new_record(project: str, compose_files: tuple[Path, ...], compose_sha: str, env_file: Path,
                env_sha: str, journal: Path, source: str, target: str, job: str,
                health_url: str, instance: dict[str, str], settings: dict[str, str]) -> dict[str, Any]:
    now = _utc_now()
    record: dict[str, Any] = {
        "version": JOURNAL_VERSION,
        "operation": "restore_stage_cutover",
        "project_name": project,
        "compose_files": [str(path) for path in compose_files],
        "compose_sha256": compose_sha,
        "env_file": str(env_file),
        "env_sha256_initial": env_sha,
        "journal_path": str(journal),
        "source_volume": source,
        "target_volume": target,
        "restore_job_id": job,
        "health_url": health_url,
        "original_instance_id": instance["instance_id"],
        "original_server_space_id": instance["server_space_id"],
        "original_generation": instance["generation"],
        "original_settings": {DATA_VOLUME_KEY: source, **settings},
        "installed_generation": None,
        "target_instance_id": None,
        "target_server_space_id": None,
        "target_generation": None,
        "state": "prepared",
        "created_at": now,
        "updated_at": now,
        "last_error_code": None,
        "health_timeout_seconds": HEALTH_TIMEOUT_DEFAULT,
        "source_checkpointed_at": None,
    }
    return record


def _record_matches(record: dict[str, Any], project: str, compose_files: tuple[Path, ...], env_file: Path,
                    journal: Path, target: str, job: str, health_url: str) -> None:
    expected = {
        "project_name": project,
        "compose_files": [str(path) for path in compose_files],
        "env_file": str(env_file),
        "journal_path": str(journal),
        "target_volume": target,
        "restore_job_id": job,
        "health_url": health_url,
        "operation": "restore_stage_cutover",
    }
    if any(record.get(key) != value for key, value in expected.items()):
        raise CutoverError("journal_operation_mismatch")


def _normalized_config_hash(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> str:
    settings = record["original_settings"]
    config, digest = _compose_config(record["project_name"], env_file, compose_files, {
        DATA_VOLUME_KEY: record["source_volume"],
        DATA_DIR_KEY: settings[DATA_DIR_KEY],
        DATABASE_URL_KEY: settings[DATABASE_URL_KEY],
    })
    if _source_volume(config) != record["source_volume"]:
        raise CutoverError("compose_source_volume_changed")
    return digest


def _validate_current_compose(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    if _normalized_config_hash(record, env_file, compose_files) != record["compose_sha256"]:
        raise CutoverError("compose_configuration_changed")
    config, _ = _compose_config(record["project_name"], env_file, compose_files)
    service = config.get("services", {}).get(SERVICE, {})
    target_state = record["state"] in ("committing", "committed")
    expected_volume = record["target_volume"] if target_state else record["source_volume"]
    expected_settings = TARGET_SETTINGS if target_state else record["original_settings"]
    if _source_volume(config) != expected_volume:
        raise CutoverError("environment_volume_mismatch")
    environment = service.get("environment", {})
    if any(environment.get(key) != expected_settings[key] for key in (DATA_DIR_KEY, DATABASE_URL_KEY)):
        raise CutoverError("environment_data_path_mismatch")


def _validate_rollback_compose(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    if _normalized_config_hash(record, env_file, compose_files) != record["compose_sha256"]:
        raise CutoverError("compose_configuration_changed")
    config, _ = _compose_config(record["project_name"], env_file, compose_files)
    service = config.get("services", {}).get(SERVICE, {})
    environment = service.get("environment", {}) if isinstance(service, dict) else {}
    volume = _source_volume(config)
    values = {key: environment.get(key) for key in (DATA_DIR_KEY, DATABASE_URL_KEY)}
    original_paths = {key: record["original_settings"][key] for key in (DATA_DIR_KEY, DATABASE_URL_KEY)}
    if volume == record["source_volume"] and values == original_paths:
        return
    if volume == record["target_volume"] and values == TARGET_SETTINGS:
        return
    raise CutoverError("environment_rollback_state_unknown")


def _atomic_update_env(record: dict[str, Any], env_file: Path, values: dict[str, str]) -> None:
    env_file, metadata = _safe_regular_file(env_file, owner_required=True)
    if metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
        raise CutoverError("env_file_unsafe")
    if set(values) != set(ENV_KEYS) or any("\n" in value or "\r" in value for value in values.values()):
        raise CutoverError("env_values_invalid")
    try:
        original = env_file.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise CutoverError("env_file_invalid") from exc
    lines = original.splitlines(keepends=True)
    counts = {key: 0 for key in ENV_KEYS}
    updated: list[str] = []
    for line in lines:
        match = re.match(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=", line.rstrip("\r\n"))
        if match and match.group(1) in counts:
            key = match.group(1)
            counts[key] += 1
            ending = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
            updated.append(f"{key}={values[key]}{ending}")
        else:
            updated.append(line)
    if any(count > 1 for count in counts.values()):
        raise CutoverError("env_duplicate_data_setting")
    if updated and updated[-1] and not updated[-1].endswith(("\n", "\r")):
        updated[-1] += "\n"
    for key in ENV_KEYS:
        if counts[key] == 0:
            updated.append(f"{key}={values[key]}\n")
    _atomic_bytes(env_file, "".join(updated).encode("utf-8"), stat.S_IMODE(metadata.st_mode),
                  uid=metadata.st_uid, gid=metadata.st_gid, expected_stat=metadata)


def _compose_stop(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    result = _compose_call(record, env_file, compose_files, "stop", "--timeout", "30", SERVICE, timeout=90)
    if result.returncode != 0:
        raise CutoverError("compose_stop_failed")


def _compose_start_source(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    overrides = {DATA_VOLUME_KEY: record["source_volume"], **record["original_settings"]}
    result = _compose_call(record, env_file, compose_files, "up", "--detach", "--no-build", SERVICE,
                           overrides=overrides, timeout=180)
    if result.returncode != 0:
        raise CutoverError("source_restart_failed")


def _check_source_quiescence(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    # Clean shutdown can leave empty SQLite WAL sidecars. Checkpoint through
    # SQLite's API on a host-visible local volume while holding the same
    # advisory server.lock used by the runtime. Unknown drivers/metadata fail
    # closed; the source is never deleted or otherwise rewritten.
    result = _run(
        ["docker", "volume", "inspect", "--format", "{{.Name}}|{{.Driver}}|{{.Mountpoint}}", record["source_volume"]],
        env=_base_env(), timeout=60,
    )
    if result.returncode != 0:
        raise CutoverError("source_volume_inspect_failed")
    fields = result.stdout.rstrip("\r\n").split("|")
    if len(fields) != 3 or fields[0] != record["source_volume"] or fields[1] != "local":
        raise CutoverError("source_volume_not_local")
    mountpoint = Path(fields[2])
    if not mountpoint.is_absolute():
        raise CutoverError("source_mountpoint_invalid")
    mountpoint = Path(os.path.abspath(mountpoint))
    cursor = Path(mountpoint.anchor)
    for component in mountpoint.parts[1:]:
        cursor = cursor / component
        try:
            component_metadata = cursor.lstat()
        except OSError as exc:
            raise CutoverError("source_mountpoint_unavailable") from exc
        if stat.S_ISLNK(component_metadata.st_mode):
            raise CutoverError("source_mountpoint_unsafe")
        if cursor != mountpoint and not stat.S_ISDIR(component_metadata.st_mode):
            raise CutoverError("source_mountpoint_unsafe")
    directory_metadata = mountpoint.lstat()
    if (not stat.S_ISDIR(directory_metadata.st_mode) or directory_metadata.st_uid != SERVICE_DATA_UID
            or stat.S_IMODE(directory_metadata.st_mode) != 0o700):
        raise CutoverError("source_directory_unsafe")

    lock_path = mountpoint / "server.lock"
    database_path = mountpoint / "atermius.db"
    lock_fd = -1
    try:
        lock_metadata = lock_path.lstat()
        database_metadata = database_path.lstat()
        if (not stat.S_ISREG(lock_metadata.st_mode) or lock_metadata.st_uid != SERVICE_DATA_UID
                or lock_metadata.st_nlink != 1 or stat.S_IMODE(lock_metadata.st_mode) != 0o600):
            raise CutoverError("source_lock_unsafe")
        if (not stat.S_ISREG(database_metadata.st_mode) or database_metadata.st_uid != SERVICE_DATA_UID
                or database_metadata.st_nlink != 1):
            raise CutoverError("source_database_unsafe")
        lock_fd = os.open(lock_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        opened_lock = os.fstat(lock_fd)
        if (opened_lock.st_dev, opened_lock.st_ino) != (lock_metadata.st_dev, lock_metadata.st_ino):
            raise CutoverError("source_lock_changed")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise CutoverError("source_still_running") from exc
        for suffix in ("-wal", "-shm", "-journal"):
            sidecar = Path(str(database_path) + suffix)
            try:
                sidecar_metadata = sidecar.lstat()
            except FileNotFoundError:
                continue
            if (not stat.S_ISREG(sidecar_metadata.st_mode) or sidecar_metadata.st_uid != SERVICE_DATA_UID
                    or sidecar_metadata.st_nlink != 1):
                raise CutoverError("source_sidecar_unsafe")
        try:
            connection = sqlite3.connect(f"{database_path.as_uri()}?mode=rw", uri=True, timeout=10, isolation_level=None)
            try:
                checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
                if not checkpoint or checkpoint[0] != 0 or (checkpoint[1] >= 0 and checkpoint[2] < checkpoint[1]):
                    raise CutoverError("source_checkpoint_incomplete")
                if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise CutoverError("source_database_integrity_failed")
            finally:
                connection.close()
        except CutoverError:
            raise
        except sqlite3.Error as exc:
            raise CutoverError("source_checkpoint_failed") from exc
        for suffix in ("-wal", "-shm", "-journal"):
            try:
                Path(str(database_path) + suffix).lstat()
            except FileNotFoundError:
                continue
            raise CutoverError("source_sidecar_remains")
        final_database = database_path.lstat()
        if (not stat.S_ISREG(final_database.st_mode) or final_database.st_uid != SERVICE_DATA_UID
                or final_database.st_nlink != 1):
            raise CutoverError("source_database_unsafe")
        record["source_checkpointed_at"] = _utc_now()
    except CutoverError:
        raise
    except OSError as exc:
        raise CutoverError("source_quiescence_failed") from exc
    finally:
        if lock_fd >= 0:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)


def _verify_source(record: dict[str, Any]) -> None:
    instance = _get_instance(record["health_url"])
    if instance != {
        "instance_id": record["original_instance_id"],
        "server_space_id": record["original_server_space_id"],
        "generation": record["original_generation"],
    }:
        raise CutoverError("source_identity_mismatch")


def _rollback_internal(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...], journal: Path,
                       *, automatic: bool) -> None:
    record["state"] = "rolling_back"
    _save_journal(journal, record)
    try:
        _compose_stop(record, env_file, compose_files)
        _atomic_update_env(record, env_file, record["original_settings"])
        _compose_start_source(record, env_file, compose_files)
        deadline = time.monotonic() + min(
            HEALTH_TIMEOUT_MAX,
            max(HEALTH_TIMEOUT_DEFAULT, int(record.get("health_timeout_seconds", HEALTH_TIMEOUT_DEFAULT))),
        )
        last_code = "source_restart_unhealthy"
        while time.monotonic() < deadline:
            try:
                _verify_source(record)
                record["state"] = "rolled_back"
                record["last_error_code"] = record.get("last_error_code") or ("health_gate_failed" if automatic else None)
                _save_journal(journal, record)
                return
            except CutoverError as exc:
                last_code = exc.code
                time.sleep(1)
        raise CutoverError(last_code)
    except CutoverError as exc:
        record["state"] = "rollback_pending"
        record["last_error_code"] = exc.code
        _save_journal(journal, record)
        raise


def _run_install(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> str:
    script = "test ! -e /target/restored && /usr/local/bin/atermius-server install-restore-stage " \
             f"--restore-job-id {record['restore_job_id']} --target-data-dir /target/restored --server-stopped"
    result = _compose_call(record, env_file, compose_files, "run", "--rm", "--no-deps", "--volume",
                           f"{record['target_volume']}:/target", "--entrypoint", "/bin/sh", SERVICE,
                           "-ec", script, overrides={DATA_VOLUME_KEY: record["source_volume"]}, timeout=600)
    if result.returncode != 0:
        raise CutoverError("restore_install_failed")
    match = INSTALL_OUTPUT_RE.search(result.stdout)
    if not match or not _canonical_uuid(match.group(1)):
        raise CutoverError("restore_install_receipt_invalid")
    return match.group(1)


def _target_override() -> tuple[tempfile.TemporaryDirectory[str], Path]:
    try:
        temporary = tempfile.TemporaryDirectory(prefix="atermius-cutover-")
        directory = Path(temporary.name)
        os.chmod(directory, 0o700)
        path = directory / "target.compose.yaml"
        body = (
            "services:\n  server:\n    environment:\n"
            '      ATERMIUS_DATA_DIR: "/data/restored"\n'
            '      ATERMIUS_DATABASE_URL: "sqlite:///data/restored/atermius.db?mode=rwc"\n'
        )
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        return temporary, path
    except OSError as exc:
        raise CutoverError("temporary_override_failed") from exc


def _start_target(record: dict[str, Any], env_file: Path, compose_files: tuple[Path, ...]) -> None:
    temporary, override = _target_override()
    try:
        result = _compose_call(
            record, env_file, compose_files, "up", "--detach", "--no-build", SERVICE,
            overrides={DATA_VOLUME_KEY: record["target_volume"], **TARGET_SETTINGS},
            extra_files=(override,), timeout=180,
        )
        if result.returncode != 0:
            raise CutoverError("target_start_failed")
    finally:
        temporary.cleanup()


def _verify_target(record: dict[str, Any], timeout_seconds: int) -> dict[str, str]:
    deadline = time.monotonic() + timeout_seconds
    last: dict[str, str] | None = None
    stable = 0
    while time.monotonic() < deadline:
        try:
            instance = _get_instance(record["health_url"])
            if instance["instance_id"] != record["original_instance_id"] or instance["server_space_id"] != record["original_server_space_id"]:
                raise CutoverError("target_identity_mismatch")
            if instance["generation"] == record["original_generation"]:
                raise CutoverError("target_generation_unchanged")
            if record.get("installed_generation") and instance["generation"] != record["installed_generation"]:
                raise CutoverError("target_generation_mismatch")
            if instance == last:
                stable += 1
            else:
                last = instance
                stable = 1
            if stable >= 2:
                return instance
        except CutoverError as exc:
            # A wrong, ready identity is a hard failure. Transient availability
            # and readiness are allowed until the bounded health deadline.
            if exc.code in ("target_identity_mismatch", "target_generation_unchanged", "target_generation_mismatch"):
                raise
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    raise CutoverError("target_health_timeout")


def _apply(project: str, env_file_arg: str, compose_args: list[str], job: str, target: str,
           health_url_arg: str, journal_arg: str, health_timeout: int) -> dict[str, Any]:
    if not _canonical_uuid(job):
        raise CutoverError("restore_job_id_invalid")
    if not VOLUME_RE.fullmatch(target):
        raise CutoverError("target_volume_invalid")
    if not HEALTH_TIMEOUT_MIN <= health_timeout <= HEALTH_TIMEOUT_MAX:
        raise CutoverError("health_timeout_out_of_range")
    env_file, compose_files, journal = _resolve_files(project, env_file_arg, compose_args, journal_arg)
    health_url = _validate_health_url(health_url_arg)
    with _journal_lock(journal):
        existing = _load_journal(journal, required=False)
        if existing:
            _record_matches(existing, project, compose_files, env_file, journal, target, job, health_url)
            record = existing
            if int(record.get("health_timeout_seconds", health_timeout)) != health_timeout:
                raise CutoverError("journal_operation_mismatch")
            if record["state"] == "committed":
                _validate_current_compose(record, env_file, compose_files)
                target_identity = _verify_target(record, health_timeout)
                if target_identity["generation"] != record["installed_generation"]:
                    raise CutoverError("target_generation_mismatch")
                return record
            if record["state"] == "rolled_back":
                return record
        else:
            config, digest = _compose_config(project, env_file, compose_files)
            source = _source_volume(config)
            if source == target:
                raise CutoverError("source_target_volume_same")
            original_settings = _source_layout(config)
            source_identity = _get_instance(health_url)
            if source_identity["generation"] is None:
                raise CutoverError("source_identity_invalid")
            env_bytes = env_file.read_bytes()
            record = _new_record(
                project, compose_files, digest, env_file,
                hashlib.sha256(env_bytes).hexdigest(), journal, source, target, job,
                health_url, source_identity, original_settings,
            )
            record["health_timeout_seconds"] = health_timeout
            _save_journal(journal, record)
        try:
            if record["state"] not in {
                "prepared", "stopping_source", "source_stopped", "source_quiescent",
                "installing", "installed", "target_starting", "target_verified", "committing", "rolling_back",
            }:
                raise CutoverError("journal_state_unsupported")
            _validate_rollback_compose(record, env_file, compose_files)
            if record["state"] == "rolling_back":
                _rollback_internal(record, env_file, compose_files, journal, automatic=True)
                return record
            if record["state"] == "prepared":
                _validate_current_compose(record, env_file, compose_files)
                _ensure_volume(record, env_file, compose_files)
                record["state"] = "stopping_source"
                _save_journal(journal, record)
            if record["state"] == "stopping_source":
                result = _compose_call(record, env_file, compose_files, "stop", "--timeout", "30", SERVICE, timeout=90)
                if result.returncode != 0:
                    raise CutoverError("compose_stop_failed")
                record["state"] = "source_stopped"
                _save_journal(journal, record)
            if record["state"] == "source_stopped":
                _check_source_quiescence(record, env_file, compose_files)
                record["state"] = "source_quiescent"
                _save_journal(journal, record)
            if record["state"] in ("source_quiescent", "installing"):
                if record["state"] == "installing":
                    # The installer publishes atomically. A visible directory
                    # without a journaled generation cannot be safely adopted.
                    check = _compose_call(record, env_file, compose_files, "run", "--rm", "--no-deps", "--volume",
                                          f"{target}:/target:ro", "--entrypoint", "/bin/sh", SERVICE,
                                          "-ec", "test ! -e /target/restored", overrides={DATA_VOLUME_KEY: record["source_volume"]})
                    if check.returncode != 0:
                        raise CutoverError("install_interrupted_ambiguous")
                record["state"] = "installing"
                _save_journal(journal, record)
                record["installed_generation"] = _run_install(record, env_file, compose_files)
                record["state"] = "installed"
                _save_journal(journal, record)
            if record["state"] in ("installed", "target_starting"):
                if record["state"] == "installed":
                    record["state"] = "target_starting"
                    _save_journal(journal, record)
                # `up` is idempotent and repairs an interrupted target_starting
                # state if the prior process stopped before the container ran.
                _start_target(record, env_file, compose_files)
                target_identity = _verify_target(record, health_timeout)
                record["target_instance_id"] = target_identity["instance_id"]
                record["target_server_space_id"] = target_identity["server_space_id"]
                record["target_generation"] = target_identity["generation"]
                record["state"] = "target_verified"
                _save_journal(journal, record)
            if record["state"] in ("target_verified", "committing"):
                target_identity = _verify_target(record, health_timeout)
                record["target_instance_id"] = target_identity["instance_id"]
                record["target_server_space_id"] = target_identity["server_space_id"]
                record["target_generation"] = target_identity["generation"]
                if record["state"] == "target_verified":
                    record["state"] = "committing"
                    _save_journal(journal, record)
                actual_config, _ = _compose_config(project, env_file, compose_files)
                actual_service = actual_config.get("services", {}).get(SERVICE, {})
                actual_environment = actual_service.get("environment", {})
                current_volume = _source_volume(actual_config)
                if current_volume == record["source_volume"] and all(
                    actual_environment.get(key) == record["original_settings"][key]
                    for key in (DATA_DIR_KEY, DATABASE_URL_KEY)
                ):
                    _atomic_update_env(record, env_file, {DATA_VOLUME_KEY: target, **TARGET_SETTINGS})
                elif current_volume != target or any(
                    actual_environment.get(key) != TARGET_SETTINGS[key]
                    for key in (DATA_DIR_KEY, DATABASE_URL_KEY)
                ):
                    raise CutoverError("environment_commit_state_unknown")
                record["state"] = "committed"
                record["last_error_code"] = None
                _save_journal(journal, record)
            return record
        except CutoverError as exc:
            if record["state"] == "prepared":
                record["last_error_code"] = exc.code
                with contextlib.suppress(CutoverError):
                    _save_journal(journal, record)
                raise
            if record["state"] not in ("committed", "rolled_back", "rollback_pending"):
                record["last_error_code"] = exc.code
                with contextlib.suppress(CutoverError):
                    _save_journal(journal, record)
                try:
                    _rollback_internal(record, env_file, compose_files, journal, automatic=True)
                except CutoverError:
                    raise CutoverError("automatic_rollback_pending") from exc
            raise


def _status(journal_arg: str) -> dict[str, Any]:
    journal = Path(os.path.abspath(journal_arg))
    _safe_directory(journal)
    with _journal_lock(journal):
        record = _load_journal(journal)
    assert record is not None
    return _safe_summary(record)


def _safe_summary(record: dict[str, Any]) -> dict[str, Any]:
    # CLI output contains operation identifiers and state only, never Compose
    # configuration, host paths, environment values, or subprocess diagnostics.
    return {key: record[key] for key in (
        "operation", "project_name", "source_volume", "target_volume", "restore_job_id",
        "state", "original_instance_id", "original_server_space_id", "original_generation",
        "installed_generation", "target_instance_id", "target_server_space_id", "target_generation",
        "source_checkpointed_at", "created_at", "updated_at", "last_error_code",
    )}


def _rollback(journal_arg: str) -> dict[str, Any]:
    journal = Path(os.path.abspath(journal_arg))
    _safe_directory(journal)
    with _journal_lock(journal):
        record = _load_journal(journal)
        assert record is not None
        if record["state"] == "rolled_back":
            return record
        env_file, compose_files, resolved_journal = _resolve_files(
            record["project_name"], record["env_file"], record["compose_files"], str(journal)
        )
        if resolved_journal != journal:
            raise CutoverError("journal_mismatch")
        _record_matches(record, record["project_name"], compose_files, env_file, journal,
                        record["target_volume"], record["restore_job_id"], record["health_url"])
        _validate_rollback_compose(record, env_file, compose_files)
        _rollback_internal(record, env_file, compose_files, journal, automatic=False)
        return record


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Offline Compose restore-stage cutover coordinator")
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply", help="install and health-gate a restore stage on a target volume")
    apply_parser.add_argument("--project-name", required=True)
    apply_parser.add_argument("--env-file", required=True)
    apply_parser.add_argument("--compose-file", action="append", required=True)
    apply_parser.add_argument("--restore-job-id", required=True)
    apply_parser.add_argument("--target-volume", required=True)
    apply_parser.add_argument("--health-url", required=True)
    apply_parser.add_argument("--journal", required=True)
    apply_parser.add_argument("--health-timeout-seconds", type=int, default=HEALTH_TIMEOUT_DEFAULT)
    status_parser = subparsers.add_parser("status", help="show safe state from a private cutover journal")
    status_parser.add_argument("--journal", required=True)
    rollback_parser = subparsers.add_parser("rollback", help="stop target and restart the retained source volume")
    rollback_parser.add_argument("--journal", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "apply":
            record = _apply(args.project_name, args.env_file, args.compose_file, args.restore_job_id,
                            args.target_volume, args.health_url, args.journal, args.health_timeout_seconds)
        elif args.command == "status":
            record = _status(args.journal)
        else:
            record = _rollback(args.journal)
        print(json.dumps(_safe_summary(record), sort_keys=True, separators=(",", ":")))
        return 0
    except CutoverError as exc:
        print(f"error: {exc.code}", file=sys.stderr)
        return 2
    except Exception:
        # Never surface raw subprocess, HTTP, filesystem or parser diagnostics.
        print("error: internal_failure", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
