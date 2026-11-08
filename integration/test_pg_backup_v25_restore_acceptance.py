"""Opt-in PostgreSQL 17 full restore drill for an encrypted schema-25 archive.

This runner provisions three explicitly disposable databases, then invokes the
Rust acceptance that builds and restores a real marker-25 PostgreSQL archive
through the production admin-job worker. The fixture drops all three databases
even when the Rust test fails.

Example (the supplied URL must name a disposable database on a CREATEDB-capable
PostgreSQL instance):

    ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 \
    ATERMIUS_TEST_PG_URL=postgresql://postgres@127.0.0.1:5432/atermius_test_control \
    pytest -q integration/test_pg_backup_v25_restore_acceptance.py
"""

from __future__ import annotations

import os
import subprocess
import urllib.parse
import uuid
from pathlib import Path
from typing import Iterator

import pytest

from conftest import ROOT


def _require(condition: bool, message: str) -> None:
    if not condition:
        pytest.fail(message, pytrace=False)


def _database_name(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    _require(parsed.scheme in {"postgres", "postgresql"}, "expected a PostgreSQL URL")
    name = urllib.parse.unquote(parsed.path.lstrip("/").split("/", 1)[0]).lower()
    _require(bool(name), "PostgreSQL URL must name a database")
    return name


def _url_for_database(base_url: str, name: str) -> str:
    parsed = urllib.parse.urlsplit(base_url)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/" + urllib.parse.quote(name, safe=""), parsed.query, parsed.fragment)
    )


def _write_private(path: Path, value: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(value)
    os.chmod(path, 0o600)


@pytest.fixture
def pg_v25_restore_world(tmp_path: Path) -> Iterator[dict[str, str]]:
    if os.environ.get("ATERMIUS_RUN_PG_HTTP_ACCEPTANCE") != "1":
        pytest.skip("set ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 to run PostgreSQL restore acceptance")
    control_url = os.environ.get("ATERMIUS_TEST_PG_URL", "")
    control_name = _database_name(control_url)
    prefixes = ("atermius_test", "atermius_pg_test")
    _require(
        control_name.startswith(prefixes),
        "PostgreSQL control URL must name an explicitly disposable database",
    )
    try:
        import psycopg
    except ImportError:
        pytest.fail("PG restore acceptance requires psycopg 3", pytrace=False)

    root = tmp_path / "pg-v25-restore"
    root.mkdir(mode=0o700)
    os.chmod(root, 0o700)
    suffix = uuid.uuid4().hex
    names = [
        f"atermius_test_v25_live_{suffix}",
        f"atermius_test_v25_archive_{suffix}",
        f"atermius_test_v25_restore_{suffix}",
    ]
    connection = None
    created: list[str] = []
    try:
        connection = psycopg.connect(control_url, autocommit=True, connect_timeout=10)
        can_create = connection.execute(
            "SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname=current_user"
        ).fetchone()[0]
        _require(
            can_create,
            "PG marker-25 restore acceptance requires a disposable PostgreSQL role with CREATEDB",
        )
        for name in names:
            connection.execute(
                psycopg.sql.SQL("CREATE DATABASE {}").format(psycopg.sql.Identifier(name))
            )
            created.append(name)

        runtime_root = root / "runtime"
        runtime_root.mkdir(mode=0o700)
        archive_root = root / "archives"
        archive_root.mkdir(mode=0o700)
        object_root = root / "objects"
        object_root.mkdir(mode=0o700)
        key_paths = {
            "signing": runtime_root / "instance-signing.key",
            "rate": runtime_root / "auth-rate-limit.key",
            "backup": runtime_root / "backup.key",
        }
        _write_private(key_paths["signing"], os.urandom(32))
        _write_private(key_paths["rate"], os.urandom(32))
        _write_private(key_paths["backup"], os.urandom(32))

        schema = "atermius_pg_v25_restore_acceptance"
        env = os.environ.copy()
        env.update(
            {
                "ATERMIUS_TEST_PG_URL": _url_for_database(control_url, names[0]),
                "ATERMIUS_TEST_PG_V25_ARCHIVE_URL": _url_for_database(control_url, names[1]),
                "ATERMIUS_TEST_PG_SCHEMA": schema,
                "ATERMIUS_SYNC_BACKEND": "postgres",
                "ATERMIUS_SYNC_PG_URL": _url_for_database(control_url, names[0]),
                "ATERMIUS_SYNC_PG_SCHEMA": schema,
                "ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE": str(key_paths["signing"]),
                "ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE": str(key_paths["rate"]),
                "ATERMIUS_BACKUP_ARCHIVE_DIR": str(archive_root),
                "ATERMIUS_BACKUP_KEY_FILE": str(key_paths["backup"]),
                "ATERMIUS_PG_RESTORE_TARGET_URL": _url_for_database(control_url, names[2]),
                "ATERMIUS_OBJECT_STORE_BACKEND": "filesystem",
                "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT": str(object_root),
            }
        )
        build_root = ROOT / ".codex-build" / "pg-v25-restore-target"
        temp_root = ROOT / ".codex-build" / "pg-v25-restore-tmp"
        build_root.mkdir(parents=True, exist_ok=True)
        temp_root.mkdir(parents=True, exist_ok=True)
        env.setdefault("CARGO_TARGET_DIR", str(build_root))
        env.setdefault("TMPDIR", str(temp_root))
        env.setdefault("CARGO_INCREMENTAL", "0")
        yield env
    finally:
        cleanup_failures: list[str] = []
        if connection is not None:
            for name in reversed(created):
                try:
                    connection.execute(
                        psycopg.sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
                            psycopg.sql.Identifier(name)
                        )
                    )
                except Exception:
                    cleanup_failures.append(name)
            connection.close()
        _require(
            not cleanup_failures,
            "could not drop disposable PG restore databases: " + ", ".join(cleanup_failures),
        )


def test_pg_marker25_encrypted_archive_full_restore_acceptance(
    pg_v25_restore_world: dict[str, str],
) -> None:
    command = [
        "cargo",
        "test",
        "--locked",
        "--manifest-path",
        str(ROOT / "server" / "Cargo.toml"),
        "--lib",
        "backup::tests::postgres_restore_full_encrypted_schema_25_archive",
        "--",
        "--ignored",
        "--exact",
        "--nocapture",
        "--test-threads=1",
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=pg_v25_restore_world,
        capture_output=True,
        text=True,
        timeout=900,
        check=False,
    )
    output = result.stdout + result.stderr
    for secret in (
        pg_v25_restore_world["ATERMIUS_TEST_PG_URL"],
        pg_v25_restore_world["ATERMIUS_TEST_PG_V25_ARCHIVE_URL"],
        pg_v25_restore_world["ATERMIUS_PG_RESTORE_TARGET_URL"],
    ):
        output = output.replace(secret, "[DATABASE_URL_REDACTED]")
    if result.returncode != 0:
        pytest.fail(f"Rust PG marker-25 restore acceptance failed:\n{output[-24000:]}", pytrace=False)
    _require(
        "PG-V25-RESTORE-01 passed" in output,
        "Rust PG acceptance exited successfully without its completion marker",
    )
