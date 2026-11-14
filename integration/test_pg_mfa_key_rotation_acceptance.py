"""Offline PostgreSQL TOTP seed-key rotation and node-quiescence acceptance."""

from __future__ import annotations

import base64
import json
import os
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import pytest
from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_encrypt,
)

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "server" / "migrations" / "postgres"
RUN_ACCEPTANCE = os.environ.get("ATERMIUS_RUN_PG_MFA_KEY_ROTATION_ACCEPTANCE") == "1"
pytestmark = pytest.mark.skipif(
    not RUN_ACCEPTANCE,
    reason="set ATERMIUS_RUN_PG_MFA_KEY_ROTATION_ACCEPTANCE=1 for disposable PostgreSQL acceptance",
)


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _envelope(key: bytes, user_id: str, seed: bytes) -> str:
    nonce = os.urandom(24)
    aad = b"atermius/mfa-totp-seed/v1\0" + user_id.encode("utf-8")
    ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(seed, aad, nonce, key)
    return json.dumps(
        {"version": 1, "nonce": _b64url(nonce), "ciphertext": _b64url(ciphertext)},
        separators=(",", ":"),
    )


def _decrypt(key: bytes, user_id: str, envelope_text: str) -> bytes:
    envelope = json.loads(envelope_text)
    nonce = base64.urlsafe_b64decode(envelope["nonce"] + "==")
    ciphertext = base64.urlsafe_b64decode(envelope["ciphertext"] + "==")
    aad = b"atermius/mfa-totp-seed/v1\0" + user_id.encode("utf-8")
    return crypto_aead_xchacha20poly1305_ietf_decrypt(ciphertext, aad, nonce, key)


def _with_application_name(database_url: str, application_name: str) -> str:
    parsed = urlsplit(database_url)
    query = [(key, value) for key, value in parse_qsl(parsed.query) if key != "application_name"]
    query.append(("application_name", application_name))
    encoded = urlencode(query)
    if not parsed.netloc:
        # urlunsplit rewrites postgresql:///db into postgresql:/db.
        value = f"{parsed.scheme}:///{parsed.path.lstrip('/')}"
        return f"{value}?{encoded}" if encoded else value
    return urlunsplit(parsed._replace(query=encoded))


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _write_private(path: Path, contents: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(contents)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)


@dataclass
class PgMfaRotationWorld:
    root: Path
    schema: str
    pg_url: str
    binary: Path
    old_key: bytes
    new_key: bytes
    wrong_key: bytes
    old_key_path: Path
    new_key_path: Path
    wrong_key_path: Path
    instance_key_path: Path
    rate_key_path: Path
    data_dir: Path
    control: Any = None
    process: subprocess.Popen[bytes] | None = None
    server_log: Any = None
    server_log_path: Path | None = None

    @property
    def psycopg(self) -> Any:
        import psycopg

        return psycopg

    @property
    def sql(self) -> Any:
        from psycopg import sql

        return sql

    def connect(self, *, application_name: str = "atermius-pg-mfa-rotation-inspect") -> Any:
        connection = self.psycopg.connect(
            _with_application_name(self.pg_url, application_name),
            autocommit=True,
            connect_timeout=10,
        )
        connection.execute(
            self.sql.SQL("SET search_path TO {}").format(self.sql.Identifier(self.schema))
        )
        self.control = connection
        return connection

    def close_control(self) -> None:
        if self.control is not None:
            self.control.close()
            self.control = None

    def runtime_env(self, *, mfa_key_path: Path | None = None, bind: str | None = None) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("ATERMIUS_TEST_PG_URL", None)
        env.update(
            {
                "ATERMIUS_DATA_DIR": str(self.data_dir),
                "ATERMIUS_DATABASE_URL": f"sqlite://{self.data_dir / 'atermius.db'}?mode=rwc",
                "ATERMIUS_SYNC_BACKEND": "postgres",
                "ATERMIUS_SYNC_PG_URL": _with_application_name(
                    self.pg_url, "atermius-pg-mfa-rotation-node"
                ),
                "ATERMIUS_SYNC_PG_SCHEMA": self.schema,
                "ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE": str(self.instance_key_path),
                "ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE": str(self.rate_key_path),
                "ATERMIUS_OBJECT_STORE_BACKEND": "filesystem",
                "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT": str(self.root / "object-store"),
                "ATERMIUS_REGISTRATION_OPEN": "false",
                "ATERMIUS_RELAY_ENABLED": "false",
                "RUST_LOG": "warn",
            }
        )
        if mfa_key_path is not None:
            env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = str(mfa_key_path)
        if bind is not None:
            env["ATERMIUS_BIND"] = bind
        return env

    def run_cli(
        self,
        old_key_path: Path | None = None,
        new_key_path: Path | None = None,
        *,
        close_control: bool = True,
        env_overrides: dict[str, str | None] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if close_control:
            self.close_control()
        env = self.runtime_env()
        if env_overrides:
            for key, value in env_overrides.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
        args = [str(self.binary), "rotate-mfa-key"]
        if old_key_path is not None:
            args.extend(("--old-key-file", str(old_key_path)))
        if new_key_path is not None:
            args.extend(("--new-key-file", str(new_key_path)))
        args.append("--server-stopped")
        return subprocess.run(
            args,
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )

    def snapshot(self) -> tuple[list[tuple[Any, ...]], list[tuple[Any, ...]], list[tuple[Any, ...]]]:
        connection = self.control or self.connect()
        mfa = connection.execute(
            "SELECT user_id,totp_seed_envelope,enabled_at,last_totp_step,"
            "pending_seed_envelope,pending_expires_at,pending_credential_version "
            "FROM auth_mfa ORDER BY user_id"
        ).fetchall()
        recovery = connection.execute(
            "SELECT code_id,user_id,salt,code_hash,created_at,consumed_at "
            "FROM auth_mfa_recovery_codes ORDER BY code_id"
        ).fetchall()
        challenges = connection.execute(
            "SELECT challenge_id_hash,user_id,device_id,credential_version,expires_at,attempt_count,consumed_at "
            "FROM auth_mfa_login_challenges ORDER BY challenge_id_hash"
        ).fetchall()
        return mfa, recovery, challenges

    def seed_state(self) -> dict[tuple[str, str], bytes]:
        connection = self.control or self.connect(application_name="atermius-pg-mfa-rotation-seed")
        seeds = {
            ("a-active-pending", "active"): b"PGACTIVESEEDSECRET01",
            ("a-active-pending", "pending"): b"PGPENDINGSEEDSEC0020",
            ("b-pending-only", "pending"): b"PGPENDONLYSEED003333",
        }
        for user_id in ("a-active-pending", "b-pending-only", "c-no-mfa"):
            connection.execute(
                "INSERT INTO users(user_id,username) VALUES (%s,%s)",
                (user_id, f"{user_id}@example.test"),
            )
        for user_id, device_id in (
            ("a-active-pending", "rotation-device-a"),
            ("b-pending-only", "rotation-device-b"),
        ):
            connection.execute(
                "INSERT INTO devices(device_id,user_id) VALUES (%s,%s)", (device_id, user_id)
            )
        now = int(time.time())
        for user_id in ("a-active-pending", "b-pending-only"):
            active_seed = seeds.get((user_id, "active"))
            pending_seed = seeds.get((user_id, "pending"))
            connection.execute(
                "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step,"
                "pending_seed_envelope,pending_expires_at,pending_credential_version) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (
                    user_id,
                    _envelope(self.old_key, user_id, active_seed) if active_seed else None,
                    now if active_seed else None,
                    1_234_567 if active_seed else None,
                    _envelope(self.old_key, user_id, pending_seed) if pending_seed else None,
                    now + 900 if pending_seed else None,
                    4 if pending_seed else None,
                ),
            )
            connection.execute(
                "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at,consumed_at) "
                "VALUES (%s,%s,%s,%s,%s,%s)",
                (
                    f"rotation-code-{user_id}",
                    user_id,
                    "abcdefghijklmnopqrstuv",
                    ("a" if user_id.startswith("a-") else "b") * 64,
                    now,
                    None if user_id.startswith("a-") else now + 1,
                ),
            )
            challenge_id = f"challenge-marker-{user_id}"
            connection.execute(
                "INSERT INTO auth_mfa_login_challenges(challenge_id_hash,user_id,device_id,"
                "credential_version,expires_at,attempt_count,consumed_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (
                    __import__("hashlib").sha256(challenge_id.encode("ascii")).hexdigest(),
                    user_id,
                    "rotation-device-a" if user_id.startswith("a-") else "rotation-device-b",
                    1,
                    now + 600,
                    2,
                    None,
                ),
            )
        return seeds

    def add_malformed_later_envelope(self) -> None:
        connection = self.control or self.connect(application_name="atermius-pg-mfa-rotation-malformed")
        connection.execute(
            "INSERT INTO users(user_id,username) VALUES ('z-malformed','z-malformed@example.test')"
        )
        connection.execute(
            "INSERT INTO auth_mfa(user_id,pending_seed_envelope,pending_expires_at,pending_credential_version) "
            "VALUES ('z-malformed','not-an-envelope',2000000000,1)"
        )

    def start_server(self, *, mfa_key_path: Path) -> int:
        port = self.spawn_server(mfa_key_path=mfa_key_path)
        self.wait_server_ready(port)
        return port

    def spawn_server(self, *, mfa_key_path: Path) -> int:
        bind = f"127.0.0.1:{_free_port()}"
        port = int(bind.rsplit(":", 1)[1])
        log_number = len(list(self.root.glob("pg-server-*.log"))) + 1
        self.server_log_path = self.root / f"pg-server-{log_number}.log"
        self.server_log = self.server_log_path.open("wb")
        self.process = subprocess.Popen(
            [str(self.binary), "serve"],
            cwd=ROOT,
            env=self.runtime_env(mfa_key_path=mfa_key_path, bind=bind),
            stdout=self.server_log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

        return port

    def wait_server_ready(self, port: int, timeout_seconds: float = 20) -> None:
        if self.process is None:
            raise AssertionError("PG server process was not started")
        client = urllib.request.Request(f"http://127.0.0.1:{port}/health/ready", method="GET")
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError("PG server exited before readiness")
            try:
                with urllib.request.urlopen(client, timeout=1) as response:
                    if response.status == 200:
                        return port
            except (OSError, urllib.error.URLError, TimeoutError):
                pass
            time.sleep(0.1)
        self.stop_server()
        raise AssertionError("PG server did not become ready")

    def stop_server(self) -> None:
        process = self.process
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
        self.process = None
        if self.server_log is not None:
            self.server_log.close()
            self.server_log = None

    def assert_server_logs_private(self, markers: list[bytes]) -> None:
        candidates = [marker.hex().encode("ascii") for marker in markers if marker]
        candidates.extend(marker for marker in markers if marker)
        for path in self.root.glob("pg-server-*.log"):
            contents = path.read_bytes()
            if any(candidate in contents for candidate in candidates):
                raise AssertionError("PG server log leaked MFA key or seed material")


@pytest.fixture
def pg_mfa_rotation_world(tmp_path: Path) -> Any:
    pg_url = os.environ.get("ATERMIUS_TEST_PG_URL")
    if not pg_url:
        pytest.fail("ATERMIUS_TEST_PG_URL must point at a disposable PostgreSQL database", pytrace=False)
    import psycopg
    from psycopg import sql

    binary_text = (
        os.environ.get("ATERMIUS_PG_MFA_KEY_ROTATION_SERVER_BIN")
        or os.environ.get("ATERMIUS_PG_HTTP_SERVER_BIN")
        or str(ROOT.parent / ".atermius-cargo-target" / "debug" / "atermius-server")
    )
    binary = Path(binary_text)
    if not binary.is_file():
        pytest.fail("the PostgreSQL MFA rotation server binary is unavailable", pytrace=False)
    root = tmp_path / "fixture"
    root.mkdir(mode=0o700)
    os.chmod(root, 0o700)
    data_dir = root / "data"
    data_dir.mkdir(mode=0o700)
    object_store_root = root / "object-store"
    object_store_root.mkdir(mode=0o700)
    schema = f"atermius_pg_mfa_key_{uuid.uuid4().hex}"
    old_key = bytes([0x37]) * 32
    new_key = bytes([0x86]) * 32
    wrong_key = bytes([0x29]) * 32
    old_key_path = root / "old.key"
    new_key_path = root / "new.key"
    wrong_key_path = root / "wrong.key"
    instance_key_path = root / "instance.key"
    rate_key_path = root / "rate.key"
    for path, contents in (
        (old_key_path, old_key),
        (new_key_path, new_key),
        (wrong_key_path, wrong_key),
        (instance_key_path, bytes([0x51]) * 32),
        (rate_key_path, bytes([0x62]) * 32),
    ):
        _write_private(path, contents)

    admin = psycopg.connect(pg_url, autocommit=True, connect_timeout=10)
    world: PgMfaRotationWorld | None = None
    schema_created = False
    try:
        admin.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        schema_created = True
        admin.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
        for migration in sorted(MIGRATIONS.glob("[0-9][0-9][0-9][0-9]_*.sql")):
            admin.execute(migration.read_text(encoding="utf-8"), prepare=False)
        world = PgMfaRotationWorld(
            root,
            schema,
            pg_url,
            binary,
            old_key,
            new_key,
            wrong_key,
            old_key_path,
            new_key_path,
            wrong_key_path,
            instance_key_path,
            rate_key_path,
            data_dir,
        )
        world.control = admin
        yield world
    finally:
        if world is not None:
            world.stop_server()
            world.close_control()
        if schema_created:
            cleanup = psycopg.connect(pg_url, autocommit=True, connect_timeout=10)
            cleanup.execute(
                sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(schema))
            )
            cleanup.close()
        if not admin.closed:
            admin.close()


def _assert_cli_output_is_private(world: PgMfaRotationWorld, output: str, markers: list[bytes]) -> None:
    candidates = [marker.hex() for marker in markers if marker]
    candidates.extend(marker.decode("ascii", "ignore") for marker in markers if marker)
    if any(candidate and candidate in output for candidate in candidates):
        raise AssertionError("MFA key rotation CLI output leaked key, seed, or recovery material")


def test_pg_rotation_is_transactional_and_changes_only_seed_envelopes(
    pg_mfa_rotation_world: PgMfaRotationWorld,
) -> None:
    world = pg_mfa_rotation_world
    seeds = world.seed_state()
    before = world.snapshot()
    secret_markers = [world.old_key, world.new_key, world.wrong_key, *seeds.values()]

    invalid_backend = world.run_cli(
        world.old_key_path,
        world.new_key_path,
        env_overrides={"ATERMIUS_SYNC_BACKEND": "postgresql"},
    )
    assert invalid_backend.returncode != 0
    _assert_cli_output_is_private(world, invalid_backend.stdout + invalid_backend.stderr, secret_markers)
    assert not (world.data_dir / "atermius.db").exists()
    assert world.snapshot() == before

    partial_pg = world.run_cli(
        world.old_key_path,
        world.new_key_path,
        env_overrides={"ATERMIUS_SYNC_PG_SCHEMA": None},
    )
    assert partial_pg.returncode != 0
    _assert_cli_output_is_private(world, partial_pg.stdout + partial_pg.stderr, secret_markers)
    assert not (world.data_dir / "atermius.db").exists()
    assert world.snapshot() == before

    same_path = world.run_cli(world.old_key_path, world.old_key_path)
    assert same_path.returncode != 0
    assert world.snapshot() == before

    duplicate_key_path = world.root / "old-copy.key"
    _write_private(duplicate_key_path, world.old_key)
    same_bytes = world.run_cli(world.old_key_path, duplicate_key_path)
    assert same_bytes.returncode != 0
    assert world.snapshot() == before

    symlink_path = world.root / "new-key-link"
    symlink_path.symlink_to(world.new_key_path)
    unsafe_link = world.run_cli(world.old_key_path, symlink_path)
    assert unsafe_link.returncode != 0
    assert world.snapshot() == before

    world.new_key_path.chmod(0o644)
    unsafe_mode = world.run_cli(world.old_key_path, world.new_key_path)
    world.new_key_path.chmod(0o600)
    assert unsafe_mode.returncode != 0
    assert world.snapshot() == before

    wrong_old_key = world.run_cli(world.wrong_key_path, world.new_key_path)
    assert wrong_old_key.returncode != 0
    _assert_cli_output_is_private(world, wrong_old_key.stdout + wrong_old_key.stderr, secret_markers)
    assert world.snapshot() == before

    world.add_malformed_later_envelope()
    malformed_before = world.snapshot()
    malformed = world.run_cli(world.old_key_path, world.new_key_path)
    assert malformed.returncode != 0
    _assert_cli_output_is_private(world, malformed.stdout + malformed.stderr, secret_markers)
    assert world.snapshot() == malformed_before
    connection = world.connect(application_name="atermius-pg-mfa-rotation-repair")
    connection.execute("DELETE FROM users WHERE user_id='z-malformed'")
    world.close_control()

    before = world.snapshot()
    success = world.run_cli(world.old_key_path, world.new_key_path)
    assert success.returncode == 0, "PG rotation command must commit valid envelopes"
    _assert_cli_output_is_private(world, success.stdout + success.stderr, secret_markers)
    if "1 active and 2 pending" not in success.stdout:
        raise AssertionError("PG rotation did not report the expected envelope counts")
    after = world.snapshot()
    before_mfa, before_recovery, before_challenges = before
    after_mfa, after_recovery, after_challenges = after
    assert before_recovery == after_recovery
    assert before_challenges == after_challenges
    before_by_user = {row[0]: row for row in before_mfa}
    after_by_user = {row[0]: row for row in after_mfa}
    assert before_by_user.keys() == after_by_user.keys()
    for user_id, previous in before_by_user.items():
        current = after_by_user[user_id]
        assert previous[2:4] == current[2:4]
        assert previous[5:] == current[5:]
        for envelope_index, seed_name in ((1, "active"), (4, "pending")):
            old_envelope = previous[envelope_index]
            new_envelope = current[envelope_index]
            if old_envelope is None:
                assert new_envelope is None
                continue
            assert new_envelope != old_envelope
            assert _decrypt(world.new_key, user_id, new_envelope) == seeds[(user_id, seed_name)]
            try:
                _decrypt(world.old_key, user_id, new_envelope)
            except Exception:
                pass
            else:
                raise AssertionError("rotated MFA envelope still decrypts with the old key")

    stored = json.dumps(after, sort_keys=True, default=str)
    markers = [world.old_key.hex(), world.new_key.hex(), world.wrong_key.hex()]
    markers.extend(seed.decode("ascii") for seed in seeds.values())
    markers.extend(("challenge-marker-a-active-pending", "challenge-marker-b-pending-only"))
    if any(marker in stored for marker in markers):
        raise AssertionError("PostgreSQL stores plaintext MFA key, seed, or challenge material")


def test_pg_server_holds_shared_lock_and_exits_if_lock_connection_is_lost(
    pg_mfa_rotation_world: PgMfaRotationWorld,
) -> None:
    world = pg_mfa_rotation_world
    seeds = world.seed_state()
    before = world.snapshot()
    world.close_control()
    port = world.start_server(mfa_key_path=world.old_key_path)

    active_node = world.run_cli(world.old_key_path, world.new_key_path)
    assert active_node.returncode != 0
    _assert_cli_output_is_private(
        world,
        active_node.stdout + active_node.stderr,
        [world.old_key, world.new_key, world.wrong_key],
    )
    assert world.snapshot() == before

    connection = world.control or world.connect(application_name="atermius-pg-mfa-rotation-kill-lock")
    lock_key = connection.execute(
        "SELECT (1096041810::bigint << 32) | oid::bigint "
        "FROM pg_database WHERE datname=current_database()"
    ).fetchone()[0]
    lock_pid = connection.execute(
        "SELECT pid FROM pg_locks WHERE locktype='advisory' AND granted "
        "AND mode='ShareLock' AND objsubid=1 "
        "AND classid=((%s::bigint >> 32) & 4294967295)::oid "
        "AND objid=(%s::bigint & 4294967295)::oid",
        (lock_key, lock_key),
    ).fetchone()
    assert lock_pid is not None
    killed = connection.execute("SELECT pg_terminate_backend(%s)", (lock_pid[0],)).fetchone()[0]
    assert killed is True
    assert world.process is not None
    try:
        return_code = world.process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        world.stop_server()
        raise AssertionError("PG server continued serving after its runtime lock connection was lost")
    assert return_code != 0
    world.process = None
    if world.server_log is not None:
        world.server_log.close()
        world.server_log = None

    held_client = world.run_cli(
        world.old_key_path,
        world.new_key_path,
        close_control=False,
    )
    assert held_client.returncode != 0
    assert world.snapshot() == before
    world.close_control()

    rotated = world.run_cli(world.old_key_path, world.new_key_path)
    assert rotated.returncode == 0
    _assert_cli_output_is_private(
        world,
        rotated.stdout + rotated.stderr,
        [world.old_key, world.new_key, world.wrong_key],
    )
    connection = world.connect(application_name="atermius-pg-mfa-rotation-exclusive-probe")
    lock_key = connection.execute(
        "SELECT (1096041810::bigint << 32) | oid::bigint "
        "FROM pg_database WHERE datname=current_database()"
    ).fetchone()[0]
    connection.execute("SELECT pg_advisory_lock(%s)", (lock_key,))
    new_key_server_port = world.spawn_server(mfa_key_path=world.new_key_path)
    assert world.process is not None
    wait_deadline = time.monotonic() + 10
    lock_waiter = None
    while time.monotonic() < wait_deadline:
        lock_waiter = connection.execute(
            "SELECT pid FROM pg_stat_activity WHERE datname=current_database() "
            "AND application_name='atermius-pg-mfa-rotation-node' "
            "AND state='active' AND wait_event_type='Lock' AND wait_event='advisory' "
            "AND query ILIKE '%pg_advisory_lock_shared%' LIMIT 1"
        ).fetchone()
        if lock_waiter is not None:
            break
        if world.process.poll() is not None:
            raise AssertionError("PG server exited instead of waiting for the shared runtime lock")
        time.sleep(0.1)
    assert lock_waiter is not None, "PG server did not wait for the held exclusive advisory lock"
    assert world.process.poll() is None
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        connect_result = probe.connect_ex(("127.0.0.1", new_key_server_port))
    assert connect_result != 0, "PG server bound its HTTP port before acquiring the shared lock"
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{new_key_server_port}/health/ready", timeout=1
        ) as response:
            ready_while_exclusive = response.status == 200
    except (OSError, urllib.error.URLError, TimeoutError):
        ready_while_exclusive = False
    assert not ready_while_exclusive
    connection.execute("SELECT pg_advisory_unlock(%s)", (lock_key,))
    world.wait_server_ready(new_key_server_port)
    world.stop_server()
    world.assert_server_logs_private([world.old_key, world.new_key, world.wrong_key, *seeds.values()])
