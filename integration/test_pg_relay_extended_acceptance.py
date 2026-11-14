"""PostgreSQL SSH Relay concurrency, revocation and crash-recovery acceptance.

This module reuses the isolated two-node PG fixture and drives real WebSocket
Relay connections into a disposable OpenSSH target. It is opt-in through the
same ``ATERMIUS_RUN_PG_HTTP_ACCEPTANCE`` and disposable database settings as
``test_pg_sync_http_acceptance.py``.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest

from conftest import ROOT, redact_secrets
from test_pg_sync_http_acceptance import PgHttpWorld, _require, pg_http_world


WEB_RUNNERS = ROOT / "integration" / "web"


def _require_openssh_worker() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        pytest.skip("isolated PostgreSQL Relay acceptance requires a Linux root worker")
    required = (
        "node",
        "useradd",
        "userdel",
        "groupdel",
        "getent",
        "chpasswd",
        "openssl",
        "ldd",
        "id",
        "mknod",
    )
    if any(shutil.which(tool) is None for tool in required):
        pytest.skip("isolated OpenSSH Relay prerequisites are unavailable")
    sshd = Path(os.environ.get("SSHD_PATH", "/usr/sbin/sshd"))
    keygen = Path(os.environ.get("SSH_KEYGEN_PATH", "/usr/bin/ssh-keygen"))
    if (
        not sshd.is_file()
        or not os.access(sshd, os.X_OK)
        or not keygen.is_file()
        or not os.access(keygen, os.X_OK)
        or not Path("/run/sshd").is_dir()
    ):
        pytest.skip("isolated OpenSSH Relay prerequisites are unavailable")


def _runner_env(world: PgHttpWorld, actor: Any, *, crash_node_a: bool = False) -> dict[str, str]:
    env = {
        key: os.environ[key]
        for key in (
            "PATH",
            "HOME",
            "TMPDIR",
            "TMP",
            "TEMP",
            "XDG_CACHE_HOME",
            "CI",
            "SSHD_PATH",
            "SSH_KEYGEN_PATH",
        )
        if key in os.environ
    }
    env.update(
        {
            "ATERMIUS_PG_RELAY_NODE_A_URL": world.clients[0].base_url,
            "ATERMIUS_PG_RELAY_NODE_B_URL": world.clients[1].base_url,
            "ATERMIUS_PG_RELAY_PUBLIC_ORIGIN": world.relay_public_origin,
            "ATERMIUS_PG_RELAY_ACCESS_TOKEN": actor.access_token,
            "ATERMIUS_PG_RELAY_DEVICE_ID": actor.device_id,
            "ATERMIUS_PG_RELAY_TARGET_HOST": world.relay_target_host,
            "ATERMIUS_PG_RELAY_TARGET_PORT": str(world.relay_target_port),
        }
    )
    if crash_node_a:
        env["ATERMIUS_PG_RELAY_NODE_A_PID"] = str(world.processes[0].pid)
    return env


def _run_runner(
    world: PgHttpWorld,
    actor: Any,
    script: str,
    required_markers: tuple[str, ...],
    *,
    timeout: int = 90,
    crash_node_a: bool = False,
) -> str:
    _require_openssh_worker()
    env = _runner_env(world, actor, crash_node_a=crash_node_a)
    try:
        result = subprocess.run(
            ["node", script],
            cwd=WEB_RUNNERS,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        pytest.fail(f"PostgreSQL Relay runner timed out: {script}", pytrace=False)
    except OSError:
        pytest.fail(f"PostgreSQL Relay runner could not start: {script}", pytrace=False)
    output = redact_secrets(
        result.stdout + "\n" + result.stderr,
        world.pg_url,
        *world.secrets,
        actor.access_token,
    )[-5000:]
    relay_events = "\n".join(
        line
        for log_path in world.log_paths
        if log_path.exists()
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        if "relay_" in line.lower()
    )
    relay_events = redact_secrets(
        relay_events, world.pg_url, *world.secrets, actor.access_token
    )[-2500:]
    _require(
        result.returncode == 0 and all(marker in result.stdout for marker in required_markers),
        f"PostgreSQL Relay runner {script} failed; redacted output: {output}; "
        f"redacted Relay service events: {relay_events}",
    )
    for log_path in world.log_paths:
        if log_path.exists():
            _require(
                actor.access_token not in log_path.read_text(encoding="utf-8", errors="replace"),
                "PostgreSQL Relay access credential appeared in a node log",
            )
    return result.stdout


def _ticket_rows_since(
    world: PgHttpWorld, user_id: str, started_at: datetime
) -> list[tuple[Any, str]]:
    return world.database_connection.execute(
        "SELECT consumed_at,target_envelope FROM relay_tickets "
        "WHERE user_id=%s AND created_at >= %s ORDER BY created_at,ticket_hash",
        (user_id, started_at),
    ).fetchall()


@pytest.mark.parametrize(
    "pg_http_world", ["pg_relay_acceptance"], indirect=True, scope="module"
)
def test_pg_relay_cross_node_ticket_redemption_and_admission_caps(
    pg_http_world: PgHttpWorld, tmp_path: Path
) -> None:
    """Concurrent replay and admission races must respect PG's cluster-wide limits."""
    actor = pg_http_world.seed_tenant(tmp_path / "pg-relay-concurrency").actors[0]
    pg_http_world.remember_secret(actor.access_token)
    started_at = pg_http_world.database_connection.execute(
        "SELECT clock_timestamp()"
    ).fetchone()[0]

    _run_runner(
        pg_http_world,
        actor,
        "pg_relay_concurrency.cjs",
        (
            "assert: pg_relay_cross_node_ticket_race=true",
            "assert: pg_relay_cross_node_admission_cap=true",
            "assert: pg_relay_concurrency_cleanup_complete=true",
        ),
        timeout=120,
    )

    tickets = _ticket_rows_since(pg_http_world, actor.user_id, started_at)
    _require(
        len(tickets) == 6
        and all(consumed_at is not None and envelope == "" for consumed_at, envelope in tickets),
        "concurrent Relay attempts must consume each distinct ticket once and erase every target envelope",
    )


@pytest.mark.parametrize(
    "pg_http_world", ["pg_relay_acceptance"], indirect=True, scope="module"
)
def test_pg_relay_live_socket_closes_after_cross_node_logout(
    pg_http_world: PgHttpWorld, tmp_path: Path
) -> None:
    """A live node-B Relay socket must observe the session logout committed on node A."""
    actor = pg_http_world.seed_tenant(tmp_path / "pg-relay-live-revocation").actors[0]
    pg_http_world.remember_secret(actor.access_token)
    started_at = pg_http_world.database_connection.execute(
        "SELECT clock_timestamp()"
    ).fetchone()[0]

    _run_runner(
        pg_http_world,
        actor,
        "pg_relay_revocation.cjs",
        (
            "assert: pg_relay_live_socket_cross_node_revocation=true",
            "assert: pg_relay_revocation_cleanup_complete=true",
        ),
    )

    tickets = _ticket_rows_since(pg_http_world, actor.user_id, started_at)
    session = pg_http_world.database_connection.execute(
        "SELECT revoked_at FROM sessions WHERE session_id=%s AND user_id=%s",
        (actor.session_id, actor.user_id),
    ).fetchone()
    lease_count = pg_http_world.database_connection.execute(
        "SELECT COUNT(*) FROM relay_connection_leases WHERE user_id=%s "
        "AND lease_expires_at>clock_timestamp()",
        (actor.user_id,),
    ).fetchone()[0]
    _require(
        len(tickets) == 1 and tickets[0][0] is not None and tickets[0][1] == "",
        "cross-node live revocation must consume the one-use ticket and clear its destination envelope",
    )
    _require(
        session is not None and session[0] is not None,
        "node-A logout did not revoke the session shared with node B",
    )
    _require(lease_count == 0, "closed Relay socket left an active PostgreSQL connection lease")


@pytest.mark.parametrize(
    "pg_http_world", ["pg_relay_acceptance"], indirect=True, scope="module"
)
def test_pg_relay_stale_connection_leases_clear_after_node_crash(
    pg_http_world: PgHttpWorld, tmp_path: Path
) -> None:
    """A crashed node's four expired leases must not block admission on its peer."""
    actor = pg_http_world.seed_tenant(tmp_path / "pg-relay-crash-lease").actors[0]
    pg_http_world.remember_secret(actor.access_token)
    started_at = pg_http_world.database_connection.execute(
        "SELECT clock_timestamp()"
    ).fetchone()[0]

    _run_runner(
        pg_http_world,
        actor,
        "pg_relay_crash_lease.cjs",
        (
            "assert: pg_relay_stale_lease_after_node_crash=true",
            "assert: pg_relay_crash_cleanup_complete=true",
        ),
        timeout=90,
        crash_node_a=True,
    )

    tickets = _ticket_rows_since(pg_http_world, actor.user_id, started_at)
    _require(
        len(tickets) == 5
        and all(consumed_at is not None and envelope == "" for consumed_at, envelope in tickets),
        "crash recovery must consume the four crashed-node tickets and the cross-node retry ticket",
    )
    remaining = pg_http_world.database_connection.execute(
        "SELECT COUNT(*) FROM relay_connection_leases WHERE user_id=%s",
        (actor.user_id,),
    ).fetchone()[0]
    _require(
        remaining == 0,
        "admission on node B did not prune expired leases from the crashed node",
    )
    _require(
        pg_http_world.processes[0].poll() is not None,
        "crash acceptance did not terminate node A",
    )
