"""Disposable black-box acceptance for instance-admin Relay policy editing."""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, IO

import pytest

from conftest import ApiClient, SigningKey
from test_acceptance import _new_account_registration
from test_backup_cli import _free_port, _run_cli, _server_binary, _start_server, _stop_server
from test_relay import (
    _LocalEcho,
    _assert_closed,
    _echo_bytes,
    _send_ticket,
    _websocket_handshake,
)


def _error_code(response: Any) -> str | None:
    body = response.json() if hasattr(response, "json") else response
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _private_lan_ipv4() -> str:
    ip = shutil.which("ip")
    if not ip:
        pytest.skip("Relay policy acceptance needs `ip` to discover a local RFC1918 target")
    result = subprocess.run(
        [ip, "-o", "-4", "addr", "show", "dev", "eth0", "scope", "global"],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    match = re.search(r"\binet\s+(\d{1,3}(?:\.\d{1,3}){3})/", result.stdout)
    if result.returncode != 0 or not match:
        pytest.skip("Relay policy acceptance needs a local eth0 IPv4 target")
    address = ipaddress.ip_address(match.group(1))
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_link_local:
        pytest.skip("Relay policy socket checks require a local RFC1918 target")
    return str(address)


@dataclass(repr=False)
class _PolicyWorld:
    api: ApiClient
    base_url: str
    env: dict[str, str]
    process: subprocess.Popen[bytes]
    server_log: IO[bytes]
    server_log_path: Path
    executable: Path
    data_dir: Path
    database: Path
    echo: _LocalEcho
    target_ip: str
    ceiling_network: ipaddress.IPv4Network
    admin: dict[str, Any]
    member_account_id: str
    member_device_id: str
    member_token: str
    member_refresh_token: str
    member_username: str

    def restart(self) -> None:
        _stop_server(self.process)
        self.server_log.close()
        self.process, self.server_log, self.api = _start_server(
            self.executable,
            self.env,
            self.base_url,
            self.server_log_path,
            self.admin["access_token"],
            self.member_token,
        )

    def close(self) -> None:
        try:
            _stop_server(self.process)
        finally:
            if not self.server_log.closed:
                self.server_log.close()
            self.echo.stop()
            shutil.rmtree(self.data_dir.parent, ignore_errors=True)


def _register(
    api: ApiClient,
    *,
    username: str,
    key_dir: Path,
    label: str,
    invitation: str | None = None,
    bootstrap: str | None = None,
) -> dict[str, Any]:
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    key_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    signer = SigningKey(key_dir, f"relay-policy-{label}-{account_id[:8]}")
    encryption_key = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
    registration = _new_account_registration(
        account_id,
        username,
        device_id,
        encryption_key,
        signer,
    )
    if invitation:
        registration["instance_invitation_token"] = invitation
    if bootstrap:
        registration["bootstrap_token"] = bootstrap
    response = api.request("POST", "/api/v1/auth/register", json_body=registration)
    assert response.status in (200, 201), f"disposable Relay policy account registration failed: HTTP {response.status}"
    result = response.json()
    assert isinstance(result, dict) and isinstance(result.get("access_token"), str)
    return {
        "account_id": account_id,
        "device_id": device_id,
        "access_token": result["access_token"],
        "refresh_token": result["refresh_token"],
        "username": username,
    }


def _start_world(tmp_path: Path, *, relay_enabled: bool) -> _PolicyWorld:
    executable = _server_binary()
    port = _free_port()
    target_ip = _private_lan_ipv4()
    echo = _LocalEcho(target_ip)
    echo.start()
    base_url = f"http://127.0.0.1:{port}"
    data_dir = tmp_path / "data"
    data_dir.mkdir(mode=0o700)
    os.chmod(data_dir, 0o700)
    database = data_dir / "atermius.db"
    network = ipaddress.ip_network(f"{target_ip}/24", strict=False)
    second_port = 22 if echo.port != 22 else 23
    admin_username = f"relay-policy-admin-{uuid.uuid4().hex[:10]}@example.test"
    member_username = f"relay-policy-member-{uuid.uuid4().hex[:10]}@example.test"
    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_BIND": f"127.0.0.1:{port}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{database}?mode=rwc",
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "true" if relay_enabled else "false",
            "ATERMIUS_RELAY_ALLOW_CIDRS": str(network),
            "ATERMIUS_RELAY_ALLOW_PORTS": f"{echo.port},{second_port}",
            "ATERMIUS_PUBLIC_ORIGIN": base_url,
            "ATERMIUS_ADMIN_USERNAMES": admin_username,
            "CARGO_TERM_COLOR": "never",
            "RUST_LOG": "off",
        }
    )

    try:
        bootstrap_run = _run_cli(executable, env, "bootstrap")
        assert bootstrap_run.returncode == 0, "disposable Relay policy bootstrap failed"
        tokens = re.findall(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap_run.stdout)
        assert tokens, "disposable Relay policy bootstrap omitted its one-time token"
        bootstrap = tokens[-1]

        log_path = tmp_path / "server.log"
        process, server_log, api = _start_server(executable, env, base_url, log_path, bootstrap)
    except Exception:
        echo.stop()
        shutil.rmtree(tmp_path, ignore_errors=True)
        raise
    try:
        admin = _register(
            api,
            username=admin_username,
            key_dir=tmp_path / "keys",
            label="admin",
            bootstrap=bootstrap,
        )
        invite = _run_cli(executable, env, "create-account-invite", "--username", member_username)
        assert invite.returncode == 0, "disposable Relay policy member invitation failed"
        invitation_tokens = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", invite.stdout
        )
        assert invitation_tokens, "disposable Relay policy invitation omitted its token"
        member = _register(
            api,
            username=member_username,
            key_dir=tmp_path / "keys",
            label="member",
            invitation=invitation_tokens[-1],
        )
        return _PolicyWorld(
            api=api,
            base_url=base_url,
            env=env,
            process=process,
            server_log=server_log,
            server_log_path=log_path,
            executable=executable,
            data_dir=data_dir,
            database=database,
            echo=echo,
            target_ip=target_ip,
            ceiling_network=network,
            admin=admin,
            member_account_id=member["account_id"],
            member_device_id=member["device_id"],
            member_token=member["access_token"],
            member_refresh_token=member["refresh_token"],
            member_username=member_username,
        )
    except Exception:
        _stop_server(process)
        server_log.close()
        echo.stop()
        shutil.rmtree(tmp_path, ignore_errors=True)
        raise


@pytest.fixture
def relay_policy_world(tmp_path: Path, request: pytest.FixtureRequest) -> _PolicyWorld:
    world = _start_world(tmp_path, relay_enabled=True)
    request.addfinalizer(world.close)
    return world


@pytest.fixture
def disabled_relay_policy_world(tmp_path: Path, request: pytest.FixtureRequest) -> _PolicyWorld:
    world = _start_world(tmp_path, relay_enabled=False)
    request.addfinalizer(world.close)
    return world


def _read_policy(world: _PolicyWorld, token: str | None = None):
    return world.api.request("GET", "/api/v1/admin/relay-policy", token=token)


def _write_policy(
    world: _PolicyWorld,
    *,
    revision: int,
    enabled: bool,
    allow_cidrs: list[str],
    allow_ports: list[int],
    token: str | None = None,
):
    return world.api.request(
        "PUT",
        "/api/v1/admin/relay-policy",
        token=token or world.admin["access_token"],
        json_body={
            "expected_revision": revision,
            "enabled": enabled,
            "allow_cidrs": allow_cidrs,
            "allow_ports": allow_ports,
        },
    )


def _read_user_policy(world: _PolicyWorld, user_id: str, token: str | None = None):
    return world.api.request(
        "GET",
        f"/api/v1/admin/relay-policy/users/{user_id}",
        token=token,
    )


def _write_user_policy(
    world: _PolicyWorld,
    user_id: str,
    *,
    revision: int,
    expected_instance_policy_revision: int,
    enabled: bool,
    allow_cidrs: list[str],
    allow_ports: list[int],
    token: str | None = None,
):
    return world.api.request(
        "PUT",
        f"/api/v1/admin/relay-policy/users/{user_id}",
        token=token or world.admin["access_token"],
        json_body={
            "expected_revision": revision,
            "expected_instance_policy_revision": expected_instance_policy_revision,
            "enabled": enabled,
            "allow_cidrs": allow_cidrs,
            "allow_ports": allow_ports,
        },
    )


def _reset_user_policy(
    world: _PolicyWorld,
    user_id: str,
    *,
    revision: int,
    token: str | None = None,
    extra: dict[str, Any] | None = None,
):
    body: dict[str, Any] = {"expected_revision": revision}
    if extra:
        body.update(extra)
    return world.api.request(
        "DELETE",
        f"/api/v1/admin/relay-policy/users/{user_id}",
        token=token or world.admin["access_token"],
        json_body=body,
    )


def _assert_policy_shape(payload: Any) -> None:
    assert isinstance(payload, dict)
    assert set(payload) == {
        "policy",
        "deployment_limits",
        "max_connections_per_user",
        "revision",
        "updated_at",
    }
    assert set(payload["policy"]) == {"enabled", "allow_cidrs", "allow_ports"}
    assert set(payload["deployment_limits"]) == {"relay_available", "allow_cidrs", "allow_ports"}
    assert isinstance(payload["policy"]["enabled"], bool)
    assert isinstance(payload["deployment_limits"]["relay_available"], bool)
    assert all(isinstance(value, str) for value in payload["policy"]["allow_cidrs"])
    assert all(isinstance(value, int) and not isinstance(value, bool) for value in payload["policy"]["allow_ports"])
    assert all(isinstance(value, str) for value in payload["deployment_limits"]["allow_cidrs"])
    assert all(isinstance(value, int) and not isinstance(value, bool) for value in payload["deployment_limits"]["allow_ports"])
    assert isinstance(payload["max_connections_per_user"], int)
    assert isinstance(payload["revision"], int) and not isinstance(payload["revision"], bool)
    if payload["updated_at"] is not None:
        assert isinstance(payload["updated_at"], str)
        datetime.fromisoformat(payload["updated_at"].replace("Z", "+00:00"))


def _audit_relay_events(world: _PolicyWorld) -> list[dict[str, Any]]:
    response = world.api.request(
        "GET", "/api/v1/admin/audit?limit=100", token=world.admin["access_token"]
    )
    assert response.status == 200
    payload = response.json()
    assert isinstance(payload, dict) and isinstance(payload.get("events"), list)
    return [event for event in payload["events"] if "relay" in event.get("action", "").lower()]


def _assert_policy_response_has_no_private_data(world: _PolicyWorld, response: Any) -> None:
    rendered = json.dumps(response.json(), sort_keys=True)
    for secret in (
        world.admin["access_token"],
        world.admin["refresh_token"],
        world.member_token,
        world.member_refresh_token,
        str(world.data_dir),
        str(world.database),
    ):
        assert secret not in rendered, "Relay policy response exposed account credentials or a server path"


def test_admin_relay_policy_strict_edit_authorization_revision_audit_and_restart(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world
    missing_get = _read_policy(world)
    assert missing_get.status == 401
    unauthenticated_put = world.api.request(
        "PUT",
        "/api/v1/admin/relay-policy",
        json_body={
            "expected_revision": 0,
            "enabled": True,
            "allow_cidrs": [str(world.ceiling_network)],
            "allow_ports": [world.echo.port],
        },
    )
    assert unauthenticated_put.status == 401
    assert _error_code(unauthenticated_put) in {"AUTH_REQUIRED", "UNAUTHENTICATED"}

    member_read = _read_policy(world, world.member_token)
    assert member_read.status == 403 and _error_code(member_read) == "INSTANCE_ADMIN_REQUIRED"
    member_write = _write_policy(
        world,
        revision=0,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=[world.echo.port],
        token=world.member_token,
    )
    assert member_write.status == 403 and _error_code(member_write) == "INSTANCE_ADMIN_REQUIRED"

    initial = _read_policy(world, world.admin["access_token"])
    assert initial.status == 200
    _assert_policy_response_has_no_private_data(world, initial)
    initial_payload = initial.json()
    _assert_policy_shape(initial_payload)
    expected_ports = sorted([world.echo.port, 22 if world.echo.port != 22 else 23])
    assert initial_payload["policy"] == {
        "enabled": True,
        "allow_cidrs": [str(world.ceiling_network)],
        "allow_ports": expected_ports,
    }
    assert initial_payload["deployment_limits"] == {
        "relay_available": True,
        "allow_cidrs": [str(world.ceiling_network)],
        "allow_ports": expected_ports,
    }
    assert initial_payload["revision"] == 0 and initial_payload["updated_at"] is None
    assert initial_payload["max_connections_per_user"] > 0

    valid_request = {
        "expected_revision": 0,
        "enabled": True,
        "allow_cidrs": [f"{world.target_ip}/32"],
        "allow_ports": [world.echo.port],
    }
    invalid_requests = [
        ({**valid_request, "unknown": True}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "expected_revision": True}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "enabled": 1}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_cidrs": [f"{world.ceiling_network.network_address + 1}/24"]}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_cidrs": ["FD00::/8"]}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_cidrs": [str(world.ceiling_network)] * 2}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_cidrs": ["8.8.8.0/24"]}, 422, "RELAY_POLICY_OUTSIDE_LIMITS"),
        ({**valid_request, "allow_ports": [world.echo.port, world.echo.port]}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_ports": [0]}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_ports": [65536]}, 400, "INVALID_RELAY_POLICY_REQUEST"),
        ({**valid_request, "allow_ports": [1]}, 422, "RELAY_POLICY_OUTSIDE_LIMITS"),
    ]
    for body, expected_status, expected_code in invalid_requests:
        response = world.api.request(
            "PUT", "/api/v1/admin/relay-policy", token=world.admin["access_token"], json_body=body
        )
        assert response.status == expected_status, f"invalid Relay policy body returned HTTP {response.status}"
        assert _error_code(response) == expected_code
        _assert_policy_response_has_no_private_data(world, response)

    oversized = world.api.request(
        "PUT",
        "/api/v1/admin/relay-policy",
        token=world.admin["access_token"],
        raw_body=b"{" + b" " * (1024 * 1024) + b"}",
        content_type="application/json",
    )
    assert oversized.status == 413
    unchanged = _read_policy(world, world.admin["access_token"]).json()
    assert unchanged["revision"] == 0 and unchanged["policy"] == initial_payload["policy"]
    assert _audit_relay_events(world) == []

    saved = _write_policy(
        world,
        revision=0,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert saved.status == 200, f"valid Relay policy narrowing failed: HTTP {saved.status} {_error_code(saved)}"
    _assert_policy_response_has_no_private_data(world, saved)
    saved_payload = saved.json()
    _assert_policy_shape(saved_payload)
    assert saved_payload["policy"] == {
        "enabled": True,
        "allow_cidrs": [f"{world.target_ip}/32"],
        "allow_ports": [world.echo.port],
    }
    assert saved_payload["revision"] == 1
    assert isinstance(saved_payload["updated_at"], str)
    audit_after_save = _audit_relay_events(world)
    assert len(audit_after_save) == 1
    assert audit_after_save[0]["actor_user_id"] == world.admin["account_id"]

    no_op = _write_policy(
        world,
        revision=1,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert no_op.status == 200
    _assert_policy_response_has_no_private_data(world, no_op)
    assert no_op.json()["revision"] == 1
    assert no_op.json()["updated_at"] == saved_payload["updated_at"]
    assert len(_audit_relay_events(world)) == 1, "no-op Relay update created an audit event"

    expected_ports = sorted([world.echo.port, 22 if world.echo.port != 22 else 23])
    wider = _write_policy(
        world,
        revision=1,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=expected_ports,
    )
    assert wider.status == 200
    _assert_policy_response_has_no_private_data(world, wider)
    wider_payload = wider.json()
    _assert_policy_shape(wider_payload)
    assert wider_payload["policy"] == {
        "enabled": True,
        "allow_cidrs": [str(world.ceiling_network)],
        "allow_ports": expected_ports,
    }
    assert wider_payload["revision"] == 2
    assert len(_audit_relay_events(world)) == 2

    stale = _write_policy(
        world,
        revision=1,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=expected_ports,
    )
    assert stale.status == 409 and _error_code(stale) == "RELAY_POLICY_CONFLICT"
    _assert_policy_response_has_no_private_data(world, stale)
    assert _read_policy(world, world.admin["access_token"]).json()["revision"] == 2

    outside_ip = world.ceiling_network.network_address + 2
    if str(outside_ip) == world.target_ip:
        outside_ip += 1
    pre_restart_allowed = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    pre_restart_outside = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": str(outside_ip),
            "target_port": world.echo.port,
        },
    )
    assert pre_restart_allowed.status == 200 and pre_restart_outside.status == 200

    world.env["ATERMIUS_RELAY_ALLOW_CIDRS"] = f"{world.target_ip}/32"
    world.env["ATERMIUS_RELAY_ALLOW_PORTS"] = str(world.echo.port)
    world.restart()
    after_restart = _read_policy(world, world.admin["access_token"])
    assert after_restart.status == 200
    _assert_policy_response_has_no_private_data(world, after_restart)
    _assert_policy_shape(after_restart.json())
    assert after_restart.json()["policy"] == wider_payload["policy"]
    assert after_restart.json()["deployment_limits"] == {
        "relay_available": True,
        "allow_cidrs": [f"{world.target_ip}/32"],
        "allow_ports": [world.echo.port],
    }
    assert after_restart.json()["revision"] == 2
    assert after_restart.json()["updated_at"] == wider_payload["updated_at"]

    overview = world.api.request("GET", "/api/v1/admin/overview", token=world.admin["access_token"])
    assert overview.status == 200
    assert overview.json()["relay"] == {
        "enabled": True,
        "allow_cidrs": [f"{world.target_ip}/32"],
        "allow_ports": [world.echo.port],
        "max_connections_per_user": after_restart.json()["max_connections_per_user"],
    }

    denied_ticket = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": str(outside_ip),
            "target_port": world.echo.port,
        },
    )
    assert denied_ticket.status == 403 and _error_code(denied_ticket) == "TARGET_DENIED"

    rejected_status, _, rejected_ws = _websocket_handshake(world.base_url, world.base_url)
    assert rejected_status == 101 and rejected_ws is not None
    try:
        _send_ticket(rejected_ws, pre_restart_outside.json()["ticket"])
        _assert_closed(rejected_ws)
    finally:
        rejected_ws.close()
    assert not world.echo.wait_accepted(1, timeout=0.5), "a pre-restart ticket bypassed the new deployment CIDR limit"

    live_status, _, live_ws = _websocket_handshake(world.base_url, world.base_url)
    assert live_status == 101 and live_ws is not None
    try:
        _send_ticket(live_ws, pre_restart_allowed.json()["ticket"])
        assert world.echo.wait_accepted(1), "the intersected in-limit Relay target did not connect"
        _echo_bytes(live_ws, b"deployment-intersection\x00\xff")
    finally:
        live_ws.close()
    assert world.echo.wait_closed(1, timeout=5)
    assert world.api.request("GET", "/health/ready").status == 200


def test_admin_relay_policy_narrowing_revokes_unused_ticket_closes_local_connection_and_keeps_server_healthy(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world
    token_response = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert token_response.status == 200
    unused_ticket = token_response.json()["ticket"]
    unused_hash = hashlib.sha256(unused_ticket.encode("ascii")).hexdigest()

    active_response = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert active_response.status == 200
    active_status, _, active_ws = _websocket_handshake(world.base_url, world.base_url)
    assert active_status == 101 and active_ws is not None
    try:
        _send_ticket(active_ws, active_response.json()["ticket"])
        assert world.echo.wait_accepted(1), "RFC1918 Relay fixture did not accept the local connection"

        replacement_ip = world.ceiling_network.network_address + 2
        if str(replacement_ip) == world.target_ip:
            replacement_ip += 1
        assert replacement_ip in world.ceiling_network and replacement_ip != ipaddress.ip_address(world.target_ip)
        narrowed = _write_policy(
            world,
            revision=0,
            enabled=True,
            allow_cidrs=[f"{replacement_ip}/32"],
            allow_ports=[world.echo.port],
        )
        assert narrowed.status == 200
        assert narrowed.json()["revision"] == 1

        invalidated_status, _, invalidated_ws = _websocket_handshake(world.base_url, world.base_url)
        assert invalidated_status == 101 and invalidated_ws is not None
        try:
            _send_ticket(invalidated_ws, unused_ticket)
            _assert_closed(invalidated_ws)
        finally:
            invalidated_ws.close()
        with sqlite3.connect(world.database, timeout=5) as connection:
            remaining = connection.execute(
                "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
                (unused_hash,),
            ).fetchone()[0]
        assert remaining == 0, "policy narrowing left an unused out-of-policy ticket live"

        assert world.echo.wait_closed(1, timeout=5), "out-of-policy local Relay connection stayed open past the polling window"
        _assert_closed(active_ws)
        assert world.echo.accepted == 1
        assert world.api.request("GET", "/health/ready").status == 200
    finally:
        active_ws.close()


def test_admin_relay_policy_cannot_enable_when_deployment_gate_is_disabled(
    disabled_relay_policy_world: _PolicyWorld,
) -> None:
    world = disabled_relay_policy_world
    response = _read_policy(world, world.admin["access_token"])
    assert response.status == 200
    payload = response.json()
    _assert_policy_shape(payload)
    assert payload["deployment_limits"]["relay_available"] is False
    assert payload["policy"]["enabled"] is False
    assert payload["revision"] == 0
    denied = _write_policy(
        world,
        revision=0,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=[world.echo.port],
    )
    assert denied.status == 422 and _error_code(denied) == "RELAY_POLICY_UNAVAILABLE"
    after = _read_policy(world, world.admin["access_token"])
    assert after.status == 200
    assert after.json()["revision"] == 0
    assert after.json()["policy"]["enabled"] is False
    assert world.api.request("GET", "/health/ready").status == 200


def test_relay_deployment_lists_fail_closed_for_mixed_and_over_limit_values(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world

    world.env["ATERMIUS_RELAY_ALLOW_CIDRS"] = f"{world.ceiling_network},,not-a-cidr"
    world.env["ATERMIUS_RELAY_ALLOW_PORTS"] = f"{world.echo.port},,not-a-port"
    world.restart()
    mixed = _read_policy(world, world.admin["access_token"])
    assert mixed.status == 200
    mixed_payload = mixed.json()
    _assert_policy_shape(mixed_payload)
    assert mixed_payload["deployment_limits"] == {
        "relay_available": False,
        "allow_cidrs": [],
        "allow_ports": [],
    }
    assert mixed_payload["revision"] == 0 and mixed_payload["updated_at"] is None
    assert world.api.request("GET", "/health/ready").status == 200

    cannot_enable = _write_policy(
        world,
        revision=0,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=[world.echo.port],
    )
    assert cannot_enable.status == 422 and _error_code(cannot_enable) == "RELAY_POLICY_UNAVAILABLE"

    world.env["ATERMIUS_RELAY_ALLOW_CIDRS"] = ",".join(
        [str(world.ceiling_network)] * 257
    )
    world.env["ATERMIUS_RELAY_ALLOW_PORTS"] = ",".join(str(port) for port in range(1, 4098))
    world.restart()
    oversized = _read_policy(world, world.admin["access_token"])
    assert oversized.status == 200
    oversized_payload = oversized.json()
    _assert_policy_shape(oversized_payload)
    assert oversized_payload["deployment_limits"] == {
        "relay_available": False,
        "allow_cidrs": [],
        "allow_ports": [],
    }
    assert oversized_payload["revision"] == 0 and oversized_payload["updated_at"] is None
    assert world.api.request("GET", "/health/ready").status == 200


def test_admin_relay_user_policy_inheritance_isolation_cas_and_revocation(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world
    member_id = world.member_account_id
    member_token = world.member_token

    initial = _read_user_policy(world, member_id, world.admin["access_token"])
    assert initial.status == 200
    initial_payload = initial.json()
    assert initial_payload["user_id"] == member_id
    assert initial_payload["inherited"] is True
    assert initial_payload["revision"] == 0
    assert initial_payload["updated_at"] is None
    global_policy = _read_policy(world, world.admin["access_token"]).json()
    assert initial_payload["policy"] == global_policy["policy"]
    assert initial_payload["effective_policy"] == {
        "enabled": global_policy["policy"]["enabled"],
        "allow_cidrs": global_policy["policy"]["allow_cidrs"],
        "allow_ports": global_policy["policy"]["allow_ports"],
    }

    assert _read_user_policy(world, member_id).status == 401
    denied_read = _read_user_policy(world, member_id, member_token)
    assert denied_read.status == 403 and _error_code(denied_read) == "INSTANCE_ADMIN_REQUIRED"
    denied_write = _write_user_policy(
        world,
        member_id,
        revision=0,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
        token=member_token,
    )
    assert denied_write.status == 403 and _error_code(denied_write) == "INSTANCE_ADMIN_REQUIRED"
    denied_reset = _reset_user_policy(
        world,
        member_id,
        revision=0,
        token=member_token,
    )
    assert denied_reset.status == 403 and _error_code(denied_reset) == "INSTANCE_ADMIN_REQUIRED"
    missing = _read_user_policy(world, str(uuid.uuid4()), world.admin["access_token"])
    assert missing.status == 404 and _error_code(missing) == "RELAY_USER_NOT_FOUND"

    other_port = 22 if world.echo.port != 22 else 23
    inherited_ticket = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": other_port,
        },
    )
    assert inherited_ticket.status == 200, "account without an override must inherit instance ports"

    spoofed = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": world.echo.port,
            "user_id": world.admin["account_id"],
        },
    )
    assert spoofed.status == 422, "ticket input must reject caller-selected authorization identity"

    unused = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert unused.status == 200
    unused_ticket = unused.json()["ticket"]
    unused_hash = hashlib.sha256(unused_ticket.encode("ascii")).hexdigest()

    active = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert active.status == 200
    active_status, _, active_ws = _websocket_handshake(world.base_url, world.base_url)
    assert active_status == 101 and active_ws is not None
    _send_ticket(active_ws, active.json()["ticket"])
    assert world.echo.wait_accepted(1), "member Relay fixture did not accept the local connection"
    _echo_bytes(active_ws, b"user-policy-active-socket")

    replacement_ip = world.ceiling_network.network_address + 2
    if str(replacement_ip) == world.target_ip:
        replacement_ip += 1
    invalid = world.api.request(
        "PUT",
        f"/api/v1/admin/relay-policy/users/{member_id}",
        token=world.admin["access_token"],
        json_body={
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": True,
            "allow_cidrs": [f"{world.target_ip}/24", f"{world.target_ip}/24"],
            "allow_ports": [world.echo.port],
        },
    )
    assert invalid.status == 400 and _error_code(invalid) == "INVALID_RELAY_USER_POLICY_REQUEST"
    missing_instance_revision = world.api.request(
        "PUT",
        f"/api/v1/admin/relay-policy/users/{member_id}",
        token=world.admin["access_token"],
        json_body={
            "expected_revision": 0,
            "enabled": True,
            "allow_cidrs": [f"{world.target_ip}/32"],
            "allow_ports": [world.echo.port],
        },
    )
    assert missing_instance_revision.status == 400
    assert _error_code(missing_instance_revision) == "INVALID_RELAY_USER_POLICY_REQUEST"
    negative_instance_revision = world.api.request(
        "PUT",
        f"/api/v1/admin/relay-policy/users/{member_id}",
        token=world.admin["access_token"],
        json_body={
            "expected_revision": 0,
            "expected_instance_policy_revision": -1,
            "enabled": True,
            "allow_cidrs": [f"{world.target_ip}/32"],
            "allow_ports": [world.echo.port],
        },
    )
    assert negative_instance_revision.status == 400
    assert _error_code(negative_instance_revision) == "INVALID_RELAY_USER_POLICY_REQUEST"
    outside_instance = _write_user_policy(
        world,
        member_id,
        revision=0,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network.supernet())],
        allow_ports=[world.echo.port],
    )
    assert outside_instance.status == 422
    assert _error_code(outside_instance) == "RELAY_USER_POLICY_OUTSIDE_LIMITS"

    narrowed = _write_user_policy(
        world,
        member_id,
        revision=0,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[f"{replacement_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert narrowed.status == 200, f"valid user Relay restriction failed: {_error_code(narrowed)}"
    narrowed_payload = narrowed.json()
    assert narrowed_payload["user_id"] == member_id
    assert narrowed_payload["inherited"] is False
    assert narrowed_payload["revision"] == 1
    assert narrowed_payload["policy"] == {
        "enabled": True,
        "allow_cidrs": [f"{replacement_ip}/32"],
        "allow_ports": [world.echo.port],
    }
    assert narrowed_payload["effective_policy"] == narrowed_payload["policy"]

    stale = _write_user_policy(
        world,
        member_id,
        revision=0,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert stale.status == 409 and _error_code(stale) == "RELAY_USER_POLICY_CONFLICT"

    with sqlite3.connect(world.database, timeout=5) as connection:
        remaining = connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
            (unused_hash,),
        ).fetchone()[0]
    assert remaining == 0, "user policy narrowing left an unused out-of-policy ticket live"

    invalidated_status, _, invalidated_ws = _websocket_handshake(world.base_url, world.base_url)
    assert invalidated_status == 101 and invalidated_ws is not None
    try:
        _send_ticket(invalidated_ws, unused_ticket)
        _assert_closed(invalidated_ws)
    finally:
        invalidated_ws.close()

    try:
        _assert_closed(active_ws)
    finally:
        active_ws.close()
    assert world.echo.wait_closed(1, timeout=5), "user policy narrowing left an active socket open"

    member_old_target = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert member_old_target.status == 403 and _error_code(member_old_target) == "TARGET_DENIED"
    member_allowed_target = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": str(replacement_ip),
            "target_port": world.echo.port,
        },
    )
    assert member_allowed_target.status == 200
    member_allowed_hash = hashlib.sha256(member_allowed_target.json()["ticket"].encode("ascii")).hexdigest()
    user_policy_noop = _write_user_policy(
        world,
        member_id,
        revision=1,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[f"{replacement_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert user_policy_noop.status == 200
    assert user_policy_noop.json()["revision"] == 1
    assert user_policy_noop.json()["updated_at"] == narrowed_payload["updated_at"]
    with sqlite3.connect(world.database, timeout=5) as connection:
        retained = connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
            (member_allowed_hash,),
        ).fetchone()[0]
    assert retained == 1, "an unchanged user policy PUT must retain current tickets"
    world.restart()
    persisted_user_policy = _read_user_policy(world, member_id, world.admin["access_token"])
    assert persisted_user_policy.status == 200
    assert persisted_user_policy.json()["revision"] == 1
    assert persisted_user_policy.json()["inherited"] is False
    admin_unrestricted = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.admin["access_token"],
        json_body={
            "device_id": world.admin["device_id"],
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert admin_unrestricted.status == 200, "one account's Relay restriction must not affect another account"

    events = [
        event
        for event in _audit_relay_events(world)
        if event.get("action") == "admin.relay_policy_updated"
    ]
    user_events = [event for event in events if event.get("resource_type") == "relay_user_policy"]
    assert len(user_events) == 1
    assert user_events[0]["actor_user_id"] == world.admin["account_id"]
    assert user_events[0].get("resource_id") != member_id

    before_reset = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": str(replacement_ip),
            "target_port": world.echo.port,
        },
    )
    assert before_reset.status == 200
    before_reset_hash = hashlib.sha256(before_reset.json()["ticket"].encode("ascii")).hexdigest()
    malformed_reset = _reset_user_policy(
        world,
        member_id,
        revision=1,
        extra={"enabled": True},
    )
    assert malformed_reset.status == 400
    negative_reset = _reset_user_policy(world, member_id, revision=-1)
    assert negative_reset.status == 400
    stale_reset = _reset_user_policy(world, member_id, revision=0)
    assert stale_reset.status == 409 and _error_code(stale_reset) == "RELAY_USER_POLICY_CONFLICT"
    reset = _reset_user_policy(world, member_id, revision=1)
    assert reset.status == 200
    reset_payload = reset.json()
    assert reset_payload["inherited"] is True
    assert reset_payload["revision"] == 2
    assert reset_payload["updated_at"] is not None
    assert reset_payload["policy"] == global_policy["policy"]
    stale_after_reset = _write_user_policy(
        world,
        member_id,
        revision=0,
        expected_instance_policy_revision=0,
        enabled=True,
        allow_cidrs=[f"{replacement_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert stale_after_reset.status == 409
    assert _error_code(stale_after_reset) == "RELAY_USER_POLICY_CONFLICT"
    with sqlite3.connect(world.database, timeout=5) as connection:
        override_rows = connection.execute(
            "SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?",
            (member_id,),
        ).fetchone()[0]
    assert override_rows == 0, "reset must restore no-row inheritance"
    inherited_put_noop = _write_user_policy(
        world,
        member_id,
        revision=2,
        expected_instance_policy_revision=0,
        enabled=global_policy["policy"]["enabled"],
        allow_cidrs=global_policy["policy"]["allow_cidrs"],
        allow_ports=global_policy["policy"]["allow_ports"],
    )
    assert inherited_put_noop.status == 200
    assert inherited_put_noop.json()["inherited"] is True
    assert inherited_put_noop.json()["revision"] == 2
    with sqlite3.connect(world.database, timeout=5) as connection:
        override_rows = connection.execute(
            "SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?",
            (member_id,),
        ).fetchone()[0]
    assert override_rows == 0, "PUT equal to the inherited selection must not create an override"
    with sqlite3.connect(world.database, timeout=5) as connection:
        remaining = connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
            (before_reset_hash,),
        ).fetchone()[0]
    assert remaining == 0, "clearing a user override left an unused ticket live"

    clear_again = _reset_user_policy(world, member_id, revision=2)
    assert clear_again.status == 200 and clear_again.json()["inherited"] is True
    user_events_after_reset = [
        event
        for event in _audit_relay_events(world)
        if event.get("resource_type") == "relay_user_policy"
    ]
    assert len(user_events_after_reset) == 2, "a changed reset must be audited; repeated inherited reset is a no-op"
    assert all(event.get("resource_id") != member_id for event in user_events_after_reset)

    instance_changed = _write_policy(
        world,
        revision=0,
        enabled=True,
        allow_cidrs=[str(world.ceiling_network)],
        allow_ports=[other_port],
    )
    assert instance_changed.status == 200
    follows_instance = _read_user_policy(world, member_id, world.admin["access_token"])
    assert follows_instance.status == 200
    follows_payload = follows_instance.json()
    assert follows_payload["inherited"] is True
    assert follows_payload["policy"]["allow_ports"] == [other_port]
    inherited_after_change = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": other_port,
        },
    )
    assert inherited_after_change.status == 200, "cleared account policy did not inherit later instance changes"
    assert world.api.request("GET", "/health/ready").status == 200


def test_user_policy_put_requires_atomic_instance_revision_cas(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world
    member_id = world.member_account_id
    initial_instance = _read_policy(world, world.admin["access_token"]).json()
    initial_user = _read_user_policy(world, member_id, world.admin["access_token"]).json()
    assert initial_instance["revision"] == 0
    assert initial_user["revision"] == 0
    assert initial_user["instance_policy_revision"] == initial_instance["revision"]
    assert initial_user["inherited"] is True

    instance_update = _write_policy(
        world,
        revision=initial_instance["revision"],
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=initial_instance["policy"]["allow_ports"],
    )
    assert instance_update.status == 200
    current_instance_revision = instance_update.json()["revision"]
    assert current_instance_revision == initial_instance["revision"] + 1

    ticket = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": world.target_ip,
            "target_port": world.echo.port,
        },
    )
    assert ticket.status == 200
    ticket_hash = hashlib.sha256(ticket.json()["ticket"].encode("ascii")).hexdigest()

    stale = _write_user_policy(
        world,
        member_id,
        revision=initial_user["revision"],
        expected_instance_policy_revision=initial_user["instance_policy_revision"],
        enabled=False,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=initial_instance["policy"]["allow_ports"],
    )
    assert stale.status == 409
    assert _error_code(stale) == "RELAY_USER_POLICY_CONFLICT"

    with sqlite3.connect(world.database, timeout=5) as connection:
        override_count = connection.execute(
            "SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?",
            (member_id,),
        ).fetchone()[0]
        watermark_count = connection.execute(
            "SELECT COUNT(*) FROM user_relay_policy_revisions WHERE user_id=?",
            (member_id,),
        ).fetchone()[0]
        ticket_count = connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
            (ticket_hash,),
        ).fetchone()[0]
    user_audit_events = [
        event
        for event in _audit_relay_events(world)
        if event.get("action") == "admin.relay_policy_updated"
        and event.get("resource_type") == "relay_user_policy"
    ]
    assert override_count == 0, "stale instance policy CAS wrote an override"
    assert watermark_count == 0, "stale instance policy CAS advanced the user watermark"
    assert ticket_count == 1, "stale instance policy CAS revoked an unused ticket"
    assert user_audit_events == [], "stale instance policy CAS wrote a user policy audit event"

    current_user = _read_user_policy(
        world,
        member_id,
        world.admin["access_token"],
    ).json()
    assert current_user["revision"] == initial_user["revision"]
    assert current_user["instance_policy_revision"] == current_instance_revision
    retry = _write_user_policy(
        world,
        member_id,
        revision=current_user["revision"],
        expected_instance_policy_revision=current_user["instance_policy_revision"],
        enabled=False,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=initial_instance["policy"]["allow_ports"],
    )
    assert retry.status == 200
    assert retry.json()["inherited"] is False
    assert retry.json()["policy"]["enabled"] is False
    assert retry.json()["revision"] == 1
    assert retry.json()["instance_policy_revision"] == current_instance_revision

    with sqlite3.connect(world.database, timeout=5) as connection:
        final_ticket_count = connection.execute(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
            (ticket_hash,),
        ).fetchone()[0]
        final_override_count = connection.execute(
            "SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?",
            (member_id,),
        ).fetchone()[0]
    final_user_audit_events = [
        event
        for event in _audit_relay_events(world)
        if event.get("action") == "admin.relay_policy_updated"
        and event.get("resource_type") == "relay_user_policy"
    ]
    assert final_ticket_count == 0
    assert final_override_count == 1
    assert len(final_user_audit_events) == 1
