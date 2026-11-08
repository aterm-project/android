"""End-to-end acceptance for the optional Caddy HTTPS edge overlay.

The test uses a private Caddy internal CA and a uniquely named Compose project.
It does not request public ACME certificates or contact external SSH targets.
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any

import pytest
import yaml

from conftest import ROOT, SigningKey, b64url
from test_acceptance import _new_account_registration
from test_relay import _WebSocket, _echo_bytes, _send_ticket


COMPOSE_BASE = ROOT / "deploy" / "compose.yaml"
COMPOSE_EDGE = ROOT / "deploy" / "compose.caddy.yaml"
CADDY_DOMAIN = "atermius.test"
RELAY_PORT = 4242
ECHO_SERVER = """\
import socketserver

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Server(("0.0.0.0", 4242), Echo).serve_forever()
"""


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _compose(
    project: str,
    env_file: Path,
    env: dict[str, str],
    override: Path,
    *args: str,
    timeout: int = 120,
) -> subprocess.CompletedProcess[str]:
    command = [
        "docker",
        "compose",
        "--project-name",
        project,
        "--env-file",
        str(env_file),
        "--file",
        str(COMPOSE_BASE),
        "--file",
        str(COMPOSE_EDGE),
        "--file",
        str(override),
        *args,
    ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _redacted_diagnostic(result: subprocess.CompletedProcess[str], *secrets: str) -> str:
    text = result.stdout + "\n" + result.stderr
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[REDACTED]")
    return text[-4000:]


def _compose_available() -> None:
    if not shutil.which("docker"):
        pytest.skip("Caddy edge acceptance requires Docker Compose")
    info = subprocess.run(
        ["docker", "info", "--format", "{{.ServerVersion}}"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    version = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if info.returncode != 0 or version.returncode != 0:
        pytest.skip("Caddy edge acceptance requires an available Docker Compose daemon")
    match = re.search(r"\bv?(\d+)\.(\d+)", version.stdout)
    if not match or (int(match.group(1)), int(match.group(2))) < (2, 24):
        pytest.skip("Caddy edge overlay requires Docker Compose 2.24 or newer")


def _unused_subnet() -> ipaddress.IPv4Network:
    listed = subprocess.run(
        ["docker", "network", "ls", "-q"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if listed.returncode != 0:
        pytest.skip("Docker network inspection is required for an isolated Relay target")
    existing: list[ipaddress.IPv4Network] = []
    if listed.stdout.strip():
        inspected = subprocess.run(
            ["docker", "network", "inspect", *listed.stdout.split()],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        if inspected.returncode == 0:
            for network in json.loads(inspected.stdout):
                ipam = network.get("IPAM") or {}
                for config in ipam.get("Config") or []:
                    cidr = config.get("Subnet")
                    if cidr:
                        try:
                            existing.append(ipaddress.ip_network(cidr, strict=False))
                        except ValueError:
                            continue

    candidates = (
        ipaddress.ip_network(f"172.{octet}.250.0/24")
        for octet in range(24, 32)
    )
    for candidate in candidates:
        if not any(candidate.overlaps(current) for current in existing):
            return candidate
    pytest.skip("No isolated IPv4 subnet is available for the Caddy Relay fixture")


class _PinnedHttpsConnection(http.client.HTTPSConnection):
    """Connect to loopback while retaining the configured TLS SNI and Host."""

    def __init__(self, host: str, port: int, context: ssl.SSLContext):
        super().__init__(host, port=port, timeout=5, context=context)
        self._loopback_host = "127.0.0.1"

    def connect(self) -> None:
        raw = socket.create_connection((self._loopback_host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def _https_request(
    origin: str,
    context: ssl.SSLContext,
    method: str,
    path: str,
    *,
    json_body: Any = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    parsed = urllib.parse.urlsplit(origin)
    assert parsed.hostname == CADDY_DOMAIN and parsed.port is not None
    body = None
    request_headers = dict(headers or {})
    if json_body is not None:
        body = json.dumps(json_body, separators=(",", ":")).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    conn = _PinnedHttpsConnection(parsed.hostname, parsed.port, context)
    try:
        conn.request(method, path, body=body, headers=request_headers)
        response = conn.getresponse()
        return response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()
    finally:
        conn.close()


def _websocket_handshake(
    origin: str,
    context: ssl.SSLContext,
) -> tuple[int, _WebSocket | None]:
    parsed = urllib.parse.urlsplit(origin)
    assert parsed.hostname is not None and parsed.port is not None
    raw = socket.create_connection(("127.0.0.1", parsed.port), timeout=5)
    raw.settimeout(5)
    conn = context.wrap_socket(raw, server_hostname=parsed.hostname)
    reader = conn.makefile("rb")
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    conn.sendall(
        (
            "GET /relay/v1/connect HTTP/1.1\r\n"
            f"Host: {parsed.netloc}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Origin: {origin}\r\n\r\n"
        ).encode("ascii")
    )
    status_line = reader.readline().decode("latin-1", errors="replace").strip()
    try:
        status = int(status_line.split(" ", 2)[1])
    except (IndexError, ValueError):
        reader.close()
        conn.close()
        raise AssertionError("Caddy Relay WebSocket returned an invalid status line") from None
    response_headers: dict[str, str] = {}
    while True:
        line = reader.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        name, separator, value = line.decode("latin-1", errors="replace").partition(":")
        if separator:
            response_headers[name.strip().lower()] = value.strip()
    if status != 101:
        reader.close()
        conn.close()
        return status, None
    expected_accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    assert response_headers.get("sec-websocket-accept") == expected_accept
    return status, _WebSocket(conn, reader)


def _container_state(
    project: str,
    env_file: Path,
    env: dict[str, str],
    override: Path,
    service: str,
) -> tuple[str, str | None]:
    result = _compose(project, env_file, env, override, "ps", "-a", "-q", service)
    assert result.returncode == 0, _redacted_diagnostic(result)
    container_id = result.stdout.strip()
    assert container_id, f"Compose did not return a container for {service}"
    inspected = subprocess.run(
        ["docker", "inspect", "--format", "{{json .State}}", container_id],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert inspected.returncode == 0, inspected.stderr[-1000:]
    state = json.loads(inspected.stdout)
    health = state.get("Health", {}).get("Status") if state.get("Health") else None
    return state.get("Status", "unknown"), health


def _wait_for_state(
    project: str,
    env_file: Path,
    env: dict[str, str],
    override: Path,
    service: str,
    *,
    status: str | None = None,
    health: str | None = None,
    timeout: float = 60,
) -> tuple[str, str | None]:
    deadline = time.monotonic() + timeout
    last = ("unknown", None)
    while time.monotonic() < deadline:
        last = _container_state(project, env_file, env, override, service)
        if (status is None or last[0] == status) and (health is None or last[1] == health):
            return last
        time.sleep(1)
    raise AssertionError(f"{service} did not reach status={status!r}, health={health!r}; got {last!r}")


def test_compose_caddy_internal_tls_https_and_relay_health_boundaries(tmp_path: Path) -> None:
    _compose_available()
    project = f"atermius-caddy-{uuid.uuid4().hex[:12]}"
    subnet = _unused_subnet()
    relay_address = str(subnet.network_address + 10)
    http_port = _free_port()
    https_port = _free_port()
    while https_port == http_port:
        https_port = _free_port()
    origin = f"https://{CADDY_DOMAIN}:{https_port}"

    env_file = tmp_path / "caddy-test.env"
    env_file.write_text(
        "\n".join(
            (
                f"ATERMIUS_DATA_VOLUME_NAME={project}-data",
                f"ATERMIUS_CADDY_DOMAIN={CADDY_DOMAIN}",
                "ATERMIUS_CADDY_ACME_EMAIL=local@example.test",
                "ATERMIUS_CADDY_HTTP_BIND=127.0.0.1",
                f"ATERMIUS_CADDY_HTTP_HOST_PORT={http_port}",
                "ATERMIUS_CADDY_HTTPS_BIND=127.0.0.1",
                f"ATERMIUS_CADDY_HTTPS_HOST_PORT={https_port}",
                f"ATERMIUS_PUBLIC_ORIGIN={origin}",
                "ATERMIUS_RELAY_ENABLED=true",
                f"ATERMIUS_RELAY_ALLOW_CIDRS={subnet}",
                f"ATERMIUS_RELAY_ALLOW_PORTS={RELAY_PORT}",
                "ATERMIUS_REGISTRATION_OPEN=false",
                "",
            )
        ),
        encoding="utf-8",
    )
    os.chmod(env_file, 0o600)

    override_file = tmp_path / "compose.caddy.internal.yaml"
    override = {
        "services": {
            "edge": {
                "volumes": [
                    {
                        "type": "bind",
                        "source": str(ROOT / "deploy" / "Caddyfile.internal"),
                        "target": "/etc/caddy/Caddyfile",
                        "read_only": True,
                        "bind": {"create_host_path": False},
                    }
                ]
            },
            "relay-echo": {
                "image": "python:3.13-alpine",
                "command": ["python", "-u", "-c", ECHO_SERVER],
                "networks": {"caddy-backend": {"ipv4_address": relay_address}},
                "healthcheck": {
                    "test": [
                        "CMD",
                        "python",
                        "-c",
                        "import socket; s=socket.create_connection(('127.0.0.1', 4242), 2); s.close()",
                    ],
                    "interval": "2s",
                    "timeout": "3s",
                    "retries": 10,
                },
            },
        },
        "networks": {
            "caddy-backend": {
                "ipam": {"config": [{"subnet": str(subnet)}]},
            }
        },
    }
    override_file.write_text(yaml.safe_dump(override, sort_keys=False), encoding="utf-8")
    os.chmod(override_file, 0o600)

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    caddy_root_file = tmp_path / "caddy-local-root.crt"
    web_socket: _WebSocket | None = None
    compose_started = False
    try:
        config = _compose(project, env_file, env, override_file, "config", "--format", "json")
        assert config.returncode == 0, _redacted_diagnostic(config)
        rendered = json.loads(config.stdout)
        server_ports = rendered["services"]["server"].get("ports", [])
        assert server_ports == [], "edge mode must not publish the server origin port"
        edge_ports = rendered["services"]["edge"]["ports"]
        assert {entry["target"] for entry in edge_ports} == {80, 443}
        assert all(entry["host_ip"] == "127.0.0.1" for entry in edge_ports)
        assert set(rendered["services"]["edge"]["networks"]) == {"caddy-backend"}

        compose_started = True
        started = _compose(
            project,
            env_file,
            env,
            override_file,
            "up",
            "-d",
            "--build",
            "server",
            "edge",
            "relay-echo",
            timeout=1800,
        )
        assert started.returncode == 0, _redacted_diagnostic(started)
        _wait_for_state(project, env_file, env, override_file, "server", status="running", health="healthy", timeout=180)
        _wait_for_state(project, env_file, env, override_file, "relay-echo", status="running", health="healthy", timeout=60)
        _wait_for_state(project, env_file, env, override_file, "edge", status="running", health="healthy", timeout=120)

        read_ca = _compose(project, env_file, env, override_file, "exec", "-T", "edge", "cat", "/data/caddy/pki/authorities/local/root.crt")
        assert read_ca.returncode == 0, _redacted_diagnostic(read_ca)
        caddy_root_file.write_text(read_ca.stdout, encoding="utf-8")
        os.chmod(caddy_root_file, 0o600)
        tls = ssl.create_default_context(cafile=str(caddy_root_file))

        status, _, body = _https_request(origin, tls, "GET", "/health/ready")
        assert status == 200 and json.loads(body) == {"status": "ready"}

        bootstrap = _compose(
            project,
            env_file,
            env,
            override_file,
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "bootstrap",
        )
        assert bootstrap.returncode == 0, _redacted_diagnostic(bootstrap)
        bootstrap_token = bootstrap.stdout.strip().splitlines()[-1]
        signer_dir = tmp_path / "signing"
        signer_dir.mkdir(mode=0o700)
        signer = SigningKey(signer_dir, "caddy-relay-owner")
        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        registration = _new_account_registration(
            account_id,
            f"caddy-{uuid.uuid4().hex[:12]}@example.test",
            device_id,
            b64url(os.urandom(32)),
            signer,
        )
        registration["bootstrap_token"] = bootstrap_token
        status, _, body = _https_request(
            origin,
            tls,
            "POST",
            "/api/v1/auth/register",
            json_body=registration,
        )
        assert status in (200, 201), f"registration through Caddy failed with HTTP {status}"
        session = json.loads(body)
        access_token = session.get("access_token")
        assert isinstance(access_token, str)

        status, _, body = _https_request(
            origin,
            tls,
            "POST",
            "/api/v1/relay/tickets",
            json_body={
                "device_id": device_id,
                "target_host": "relay-echo",
                "target_port": RELAY_PORT,
            },
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert status == 200, f"Relay ticket through Caddy failed with HTTP {status}"
        ticket = json.loads(body).get("ticket")
        assert isinstance(ticket, str) and len(ticket) == 43

        ws_status, web_socket = _websocket_handshake(origin, tls)
        assert ws_status == 101 and web_socket is not None, "Caddy did not forward the Relay WebSocket upgrade"
        _send_ticket(web_socket, ticket)
        _echo_bytes(web_socket, b"caddy-edge-relay\x00\xff")
        web_socket.close()
        web_socket = None

        # The origin and edge readiness signals are intentionally distinct:
        # while Caddy is stopped, the server stays healthy but the public TLS
        # route is unavailable.
        stopped_edge = _compose(project, env_file, env, override_file, "stop", "edge")
        assert stopped_edge.returncode == 0, _redacted_diagnostic(stopped_edge)
        assert _container_state(project, env_file, env, override_file, "server") == ("running", "healthy")
        edge_state, _ = _container_state(project, env_file, env, override_file, "edge")
        # Docker can retain the last health value for a stopped container; the
        # process state and external TLS request are the authoritative signals
        # for this stopped-proxy case.
        assert edge_state == "exited"
        with pytest.raises((OSError, ssl.SSLError, http.client.HTTPException)):
            _https_request(origin, tls, "GET", "/health/ready")

        # Restore the route, then prove that an unavailable origin makes the
        # edge healthcheck fail instead of continuing to report ready.
        restarted_edge = _compose(project, env_file, env, override_file, "start", "edge")
        assert restarted_edge.returncode == 0, _redacted_diagnostic(restarted_edge)
        _wait_for_state(project, env_file, env, override_file, "edge", status="running", health="healthy", timeout=90)
        stopped_server = _compose(project, env_file, env, override_file, "stop", "server")
        assert stopped_server.returncode == 0, _redacted_diagnostic(stopped_server)
        _wait_for_state(project, env_file, env, override_file, "edge", status="running", health="unhealthy", timeout=45)
        status, _, _ = _https_request(origin, tls, "GET", "/health/ready")
        assert status != 200, "edge readiness returned success while its origin was stopped"
    finally:
        if web_socket is not None:
            web_socket.close()
        if compose_started:
            cleanup = _compose(
                project,
                env_file,
                env,
                override_file,
                "down",
                "--volumes",
                "--remove-orphans",
                timeout=120,
            )
            assert cleanup.returncode == 0, _redacted_diagnostic(cleanup)
