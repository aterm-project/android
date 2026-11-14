"""Black-box SSH relay acceptance against an isolated relay-enabled instance.

All relay destinations are local to the test container.  The only TCP target is
an echo listener bound to the container's non-loopback eth0 address.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, ROOT, SigningKey
from test_acceptance import _new_account_registration


def _error_code(response: Any) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _eth0_ipv4() -> str:
    ip = shutil.which("ip")
    if not ip:
        pytest.skip("Relay acceptance requires `ip` to discover a local eth0 IPv4 address")
    result = subprocess.run(
        [ip, "-o", "-4", "addr", "show", "dev", "eth0", "scope", "global"],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    match = re.search(r"\binet\s+(\d{1,3}(?:\.\d{1,3}){3})/", result.stdout)
    if result.returncode != 0 or not match:
        pytest.skip("Relay acceptance needs a non-loopback eth0 IPv4 address for the local echo target")
    address = match.group(1)
    try:
        parsed = socket.inet_aton(address)
    except OSError:
        pytest.skip("eth0 did not expose a valid IPv4 address")
    if parsed[0] in (0, 127, 169):
        pytest.skip("eth0 address is loopback/link-local and cannot be used for the relay target")
    return address


class _LocalEcho:
    def __init__(self, address: str):
        self.address = address
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.listener.bind((address, 0))
        except OSError as error:
            self.listener.close()
            pytest.skip(f"Cannot bind an isolated echo listener to local eth0 address: {error}")
        self.listener.listen(16)
        self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.stopping = threading.Event()
        self.condition = threading.Condition()
        self.accepted = 0
        self.closed = 0
        self.sockets: set[socket.socket] = set()
        self.threads: list[threading.Thread] = []
        self.thread = threading.Thread(target=self._accept_loop, name="relay-test-echo", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _accept_loop(self) -> None:
        while not self.stopping.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            conn.settimeout(5)
            with self.condition:
                self.accepted += 1
                self.sockets.add(conn)
                self.condition.notify_all()
            thread = threading.Thread(target=self._echo, args=(conn,), daemon=True)
            self.threads.append(thread)
            thread.start()

    def _echo(self, conn: socket.socket) -> None:
        try:
            with conn:
                while True:
                    chunk = conn.recv(16 * 1024)
                    if not chunk:
                        return
                    conn.sendall(chunk)
        except OSError:
            return
        finally:
            with self.condition:
                self.sockets.discard(conn)
                self.closed += 1
                self.condition.notify_all()

    def wait_accepted(self, count: int, timeout: float = 5) -> bool:
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.accepted < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(remaining)
            return True

    def wait_closed(self, count: int, timeout: float = 5) -> bool:
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.closed < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(remaining)
            return True

    def stop(self) -> None:
        self.stopping.set()
        try:
            self.listener.close()
        except OSError:
            pass
        with self.condition:
            sockets = list(self.sockets)
        for conn in sockets:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        self.thread.join(timeout=2)
        for thread in self.threads:
            thread.join(timeout=2)


@dataclass
class _RelayWorld:
    api: ApiClient
    echo: _LocalEcho
    database: Path
    data_dir: Path
    account_id: str
    device_id: str
    access_token: str
    signer: SigningKey
    base_url: str


def _database_path(database_url: str) -> Path:
    assert database_url.startswith("sqlite://")
    return Path(urllib.parse.unquote(database_url[len("sqlite://") :].split("?", 1)[0]))


def _kill_process_group(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (AttributeError, ProcessLookupError):
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (AttributeError, ProcessLookupError):
            process.kill()
        process.wait(timeout=5)


@pytest.fixture
def relay_world(tmp_path: Path, request: pytest.FixtureRequest):
    """Start a fresh server with relay enabled and one strictly local target."""
    cargo = shutil.which("cargo")
    if not cargo:
        pytest.skip("Cargo is required to launch the isolated Relay acceptance server")
    target_address = _eth0_ipv4()
    echo = _LocalEcho(target_address)
    echo.start()
    request.addfinalizer(echo.stop)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_reservation:
        port_reservation.bind(("127.0.0.1", 0))
        http_port = port_reservation.getsockname()[1]
    base_url = f"http://127.0.0.1:{http_port}"
    data_dir = tmp_path / "data"
    data_dir.mkdir(mode=0o700)
    os.chmod(data_dir, 0o700)
    database_url = f"sqlite://{data_dir / 'atermius.db'}?mode=rwc"
    env = os.environ.copy()
    env.update(
        {
            "ATERMIUS_BIND": f"127.0.0.1:{http_port}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": database_url,
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "true",
            # Include the metadata /32 in the disposable server policy to
            # verify its explicit denylist, without ever dialing it.
            "ATERMIUS_RELAY_ALLOW_CIDRS": f"{target_address}/32,100.100.100.200/32",
            "ATERMIUS_RELAY_ALLOW_PORTS": str(echo.port),
            "ATERMIUS_PUBLIC_ORIGIN": base_url,
            "CARGO_TERM_COLOR": "never",
        }
    )
    manifest = ROOT / "server" / "Cargo.toml"
    bootstrap = subprocess.run(
        [cargo, "run", "--quiet", "--locked", "--manifest-path", str(manifest), "--", "bootstrap"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    if bootstrap.returncode != 0:
        echo.stop()
        pytest.fail(f"isolated Relay bootstrap failed (exit {bootstrap.returncode})")
    token_matches = re.findall(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap.stdout)
    if not token_matches:
        echo.stop()
        pytest.fail("isolated Relay bootstrap omitted its one-time token")
    bootstrap_token = token_matches[-1]

    server_log = (tmp_path / "server.log").open("wb")
    process = subprocess.Popen(
        [cargo, "run", "--quiet", "--locked", "--manifest-path", str(manifest), "--", "serve"],
        cwd=ROOT,
        env=env,
        stdout=server_log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    request.addfinalizer(lambda: _kill_process_group(process))
    request.addfinalizer(server_log.close)
    api = ApiClient(base_url)
    deadline = time.monotonic() + 90
    ready = False
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        try:
            live = api.request("GET", "/health/live")
            is_ready = api.request("GET", "/health/ready")
            if live.status == 200 and is_ready.status == 200:
                ready = True
                break
        except OSError:
            pass
        time.sleep(0.2)
    if not ready:
        _kill_process_group(process)
        server_log.close()
        echo.stop()
        pytest.fail("isolated Relay server did not reach readiness")

    signer_dir = tmp_path / "keys"
    signer_dir.mkdir(mode=0o700)
    signer = SigningKey(signer_dir, "relay-owner")
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_public_key = base64.urlsafe_b64encode(os.urandom(32)).decode("ascii").rstrip("=")
    registration = _new_account_registration(
        account_id,
        f"relay-{uuid.uuid4().hex[:12]}@example.test",
        device_id,
        encryption_public_key,
        signer,
    )
    registration["bootstrap_token"] = bootstrap_token
    registered = api.request("POST", "/api/v1/auth/register", json_body=registration)
    if registered.status not in (200, 201) or not isinstance(registered.json(), dict):
        _kill_process_group(process)
        server_log.close()
        echo.stop()
        pytest.fail(f"isolated Relay registration failed (HTTP {registered.status})")
    body = registered.json()
    access_token = body.get("access_token")
    if not isinstance(access_token, str):
        _kill_process_group(process)
        server_log.close()
        echo.stop()
        pytest.fail("isolated Relay registration response omitted its access session")

    world = _RelayWorld(
        api=api,
        echo=echo,
        database=_database_path(database_url),
        data_dir=data_dir,
        account_id=account_id,
        device_id=device_id,
        access_token=access_token,
        signer=signer,
        base_url=base_url,
    )
    try:
        yield world
    finally:
        _kill_process_group(process)
        server_log.close()
        echo.stop()


def _issue_ticket(world: _RelayWorld, host: str | None = None, port: int | None = None):
    response = world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.access_token,
        json_body={
            "device_id": world.device_id,
            "target_host": host or world.echo.address,
            "target_port": world.echo.port if port is None else port,
        },
    )
    return response


class _WebSocket:
    def __init__(self, conn: socket.socket, reader: Any):
        self.conn = conn
        self.reader = reader

    def send(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        size = len(payload)
        first = bytes((0x80 | opcode,))
        if size < 126:
            header = first + bytes((0x80 | size,))
        elif size <= 0xFFFF:
            header = first + bytes((0x80 | 126,)) + struct.pack("!H", size)
        else:
            header = first + bytes((0x80 | 127,)) + struct.pack("!Q", size)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.conn.sendall(header + mask + masked)

    def receive(self) -> tuple[int, bytes]:
        first, second = _read_exact(self.reader, 2)
        opcode = first & 0x0F
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", _read_exact(self.reader, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", _read_exact(self.reader, 8))[0]
        mask = _read_exact(self.reader, 4) if second & 0x80 else None
        payload = _read_exact(self.reader, size)
        if mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        if opcode == 0x9:
            self.send(0xA, payload)
            return self.receive()
        return opcode, payload

    def close(self) -> None:
        try:
            self.send(0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.reader.close()
        except OSError:
            pass
        self.conn.close()


def _read_exact(reader: Any, size: int) -> bytes:
    payload = bytearray()
    while len(payload) < size:
        chunk = reader.read(size - len(payload))
        if not chunk:
            raise EOFError("WebSocket closed before a complete frame arrived")
        payload.extend(chunk)
    return bytes(payload)


def _websocket_handshake(
    base_url: str,
    origin: str,
    *,
    additional_origins: tuple[str, ...] = (),
    path: str = "/relay/v1/connect",
) -> tuple[int, bytes, _WebSocket | None]:
    parsed = urllib.parse.urlsplit(base_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    conn = socket.create_connection((host, port), timeout=5)
    conn.settimeout(5)
    reader = conn.makefile("rb")
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    origin_lines = "".join(f"Origin: {value}\r\n" for value in (origin, *additional_origins))
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parsed.netloc}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"{origin_lines}\r\n"
    )
    conn.sendall(request.encode("ascii"))
    status_line = reader.readline().decode("latin-1", errors="replace").strip()
    try:
        status = int(status_line.split(" ", 2)[1])
    except (IndexError, ValueError):
        reader.close()
        conn.close()
        raise AssertionError("Relay WebSocket returned an invalid HTTP status line") from None
    headers: dict[str, str] = {}
    while True:
        line = reader.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        name, separator, value = line.decode("latin-1", errors="replace").partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    if status == 101:
        expected_accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        assert headers.get("sec-websocket-accept") == expected_accept
        return status, b"", _WebSocket(conn, reader)
    body = b""
    if headers.get("transfer-encoding", "").lower() == "chunked":
        chunks = bytearray()
        while True:
            length = int(reader.readline().split(b";", 1)[0].strip(), 16)
            if length == 0:
                while reader.readline() not in (b"\r\n", b"\n", b""):
                    pass
                break
            chunks.extend(_read_exact(reader, length))
            _read_exact(reader, 2)
        body = bytes(chunks)
    else:
        length = int(headers.get("content-length", "0") or "0")
        if length:
            body = _read_exact(reader, length)
        else:
            body = reader.read()
    reader.close()
    conn.close()
    return status, body, None


def _send_ticket(ws: _WebSocket, ticket: str) -> None:
    ws.send(0x1, ticket.encode("ascii"))


def _assert_closed(ws: _WebSocket) -> None:
    try:
        opcode, _ = ws.receive()
    except (EOFError, OSError, TimeoutError, socket.timeout):
        return
    assert opcode == 0x8, f"rejected Relay ticket left an unexpected websocket frame ({opcode})"


def _echo_bytes(ws: _WebSocket, expected: bytes) -> None:
    ws.send(0x2, expected)
    received = bytearray()
    deadline = time.monotonic() + 5
    while len(received) < len(expected) and time.monotonic() < deadline:
        ws.conn.settimeout(max(0.1, deadline - time.monotonic()))
        opcode, chunk = ws.receive()
        assert opcode == 0x2, "Relay must return target TCP bytes as WebSocket binary frames"
        received.extend(chunk)
    assert bytes(received) == expected, "Relay changed, truncated, or duplicated binary TCP bytes"


def test_relay_ticket_target_origin_binary_replay_revoke_and_disconnect(relay_world: _RelayWorld) -> None:
    world = relay_world
    api = world.api

    no_auth = api.request(
        "POST",
        "/api/v1/relay/tickets",
        json_body={
            "device_id": world.device_id,
            "target_host": world.echo.address,
            "target_port": world.echo.port,
        },
    )
    assert no_auth.status == 401 and _error_code(no_auth) in {"AUTH_REQUIRED", "UNAUTHENTICATED"}

    # The owner device is the only authenticated device; use a valid UUID so
    # the policy reaches the session/device binding check.
    wrong_device = api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.access_token,
        json_body={
            "device_id": str(uuid.uuid4()),
            "target_host": world.echo.address,
            "target_port": world.echo.port,
        },
    )
    assert wrong_device.status == 403 and _error_code(wrong_device) == "DEVICE_REVOKED"

    loopback = _issue_ticket(world, host="127.0.0.1")
    assert loopback.status == 403 and _error_code(loopback) == "TARGET_DENIED"
    out_of_allowlist = _issue_ticket(world, host="192.0.2.17", port=22)
    assert out_of_allowlist.status == 403 and _error_code(out_of_allowlist) == "TARGET_DENIED"
    out_of_port_allowlist = _issue_ticket(world, port=1 if world.echo.port != 1 else 2)
    assert out_of_port_allowlist.status == 403 and _error_code(out_of_port_allowlist) == "TARGET_DENIED"
    cloud_metadata = _issue_ticket(world, host="100.100.100.200", port=80)
    assert cloud_metadata.status == 403 and _error_code(cloud_metadata) == "TARGET_DENIED"
    zero_port = _issue_ticket(world, port=0)
    assert zero_port.status == 400 and _error_code(zero_port) == "INVALID_TARGET"
    loopback_dns_host = _issue_ticket(world, host="localhost", port=22)
    assert loopback_dns_host.status == 403 and _error_code(loopback_dns_host) == "TARGET_DENIED"
    normalized_loopback_dns_host = _issue_ticket(world, host="LOCALHOST", port=22)
    assert normalized_loopback_dns_host.status == 403
    assert _error_code(normalized_loopback_dns_host) == "TARGET_DENIED"
    invalid_dns_host = _issue_ticket(world, host="bad..hostname", port=22)
    assert invalid_dns_host.status == 400 and _error_code(invalid_dns_host) == "INVALID_TARGET"
    unicode_dns_host = _issue_ticket(world, host="bücher.example", port=22)
    assert unicode_dns_host.status == 400 and _error_code(unicode_dns_host) == "INVALID_TARGET"
    overlong_dns_host = _issue_ticket(world, host="a" * 254, port=22)
    assert overlong_dns_host.status == 400 and _error_code(overlong_dns_host) == "INVALID_TARGET"
    untrusted_dns_name = f"atermius-no-such-host-{uuid.uuid4().hex}.invalid"
    untrusted_dns_target = _issue_ticket(world, host=untrusted_dns_name, port=22)
    # Some test-container resolvers synthesize an address for .invalid names.
    # Either resolver failure or a resolved-but-disallowed candidate is safe;
    # deterministic resolver unit tests pin the exact 502 cases.
    assert (
        untrusted_dns_target.status == 502
        and _error_code(untrusted_dns_target) == "TARGET_RESOLUTION_FAILED"
    ) or (
        untrusted_dns_target.status == 403
        and _error_code(untrusted_dns_target) == "TARGET_DENIED"
    )
    assert untrusted_dns_name.encode("ascii") not in untrusted_dns_target.body, (
        "DNS errors must not echo the submitted hostname"
    )

    issued = _issue_ticket(world)
    assert issued.status == 200, f"valid local Relay ticket returned HTTP {issued.status}"
    issued_body = issued.json()
    assert isinstance(issued_body, dict)
    assert issued_body.get("connect_path") == "/relay/v1/connect"
    ticket = issued_body.get("ticket")
    assert isinstance(ticket, str) and len(ticket) == 43
    ticket_raw = base64.urlsafe_b64decode(ticket + "=")
    assert len(ticket_raw) == 32
    expires_at = datetime.fromisoformat(issued_body["expires_at"].replace("Z", "+00:00"))
    remaining_ttl = (expires_at - datetime.now(timezone.utc)).total_seconds()
    assert 0 < remaining_ttl <= 30, "Relay ticket must expire no later than 30 seconds after issue"

    expected_hash = hashlib.sha256(ticket.encode("ascii")).hexdigest()
    with sqlite3.connect(world.database, timeout=5) as database:
        row = database.execute(
            "SELECT ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at,consumed_at "
            "FROM relay_tickets WHERE ticket_hash=?",
            (expected_hash,),
        ).fetchone()
    assert row is not None, "Relay must persist a one-way ticket hash"
    assert row[0] == expected_hash and row[0] != ticket
    assert row[1] == world.account_id and row[2] == world.device_id
    assert isinstance(row[3], str) and row[3].startswith("rtd1:")
    assert world.echo.address not in row[3] and row[4] == 0
    assert row[6] and row[7] and isinstance(row[8], int) and row[9] is None
    address_bytes = world.echo.address.encode("ascii")
    sqlite_files = [
        world.database,
        Path(f"{world.database}-wal"),
        Path(f"{world.database}-shm"),
    ]
    address_leaks = [
        database_file.name
        for database_file in sqlite_files
        if database_file.exists() and address_bytes in database_file.read_bytes()
    ]
    assert not address_leaks, (
        "Relay target address appeared in persistent SQLite files: "
        f"{address_leaks}"
    )

    # The configured origin is a single exact header. Rejection happens before
    # upgrade, leaving the valid ticket untouched for the subsequent dial.
    wrong_origin_status, wrong_origin_body, no_socket = _websocket_handshake(
        world.base_url, world.base_url + ".invalid"
    )
    assert no_socket is None and wrong_origin_status == 403
    assert json.loads(wrong_origin_body)["error"]["code"] == "ORIGIN_DENIED"
    duplicate_origin_status, duplicate_body, no_socket = _websocket_handshake(
        world.base_url, world.base_url, additional_origins=(world.base_url,)
    )
    assert no_socket is None and duplicate_origin_status == 403
    assert json.loads(duplicate_body)["error"]["code"] == "ORIGIN_DENIED"
    with sqlite3.connect(world.database, timeout=5) as database:
        assert database.execute(
            "SELECT consumed_at FROM relay_tickets WHERE ticket_hash=?", (expected_hash,)
        ).fetchone()[0] is None

    status, _, ws = _websocket_handshake(world.base_url, world.base_url)
    assert status == 101 and ws is not None
    active: list[_WebSocket] = [ws]
    _send_ticket(ws, ticket)
    assert world.echo.wait_accepted(1), "valid Relay ticket did not connect to the local echo listener"
    payload = bytes([0, 255, 128, 1, 254, 0, 65, 200]) * 97
    _echo_bytes(ws, payload)
    with sqlite3.connect(world.database, timeout=5) as database:
        consumed_at = database.execute(
            "SELECT consumed_at FROM relay_tickets WHERE ticket_hash=?", (expected_hash,)
        ).fetchone()[0]
        target_after_use = database.execute(
            "SELECT target_ip,target_port FROM relay_tickets WHERE ticket_hash=?", (expected_hash,)
        ).fetchone()
    assert consumed_at is not None and target_after_use == ("", 0)

    replay_status, _, replay_ws = _websocket_handshake(world.base_url, world.base_url)
    assert replay_status == 101 and replay_ws is not None
    _send_ticket(replay_ws, ticket)
    _assert_closed(replay_ws)
    replay_ws.close()
    assert world.echo.accepted == 1, "replayed ticket must not open another target connection"

    # An expired ticket is rejected without waiting 30 real seconds.
    expired = _issue_ticket(world)
    assert expired.status == 200
    expired_ticket = expired.json()["ticket"]
    expired_hash = hashlib.sha256(expired_ticket.encode("ascii")).hexdigest()
    with sqlite3.connect(world.database, timeout=5) as database:
        database.execute(
            "UPDATE relay_tickets SET expires_at='2000-01-01T00:00:00+00:00' WHERE ticket_hash=?",
            (expired_hash,),
        )
        database.commit()
    expired_status, _, expired_ws = _websocket_handshake(world.base_url, world.base_url)
    assert expired_status == 101 and expired_ws is not None
    _send_ticket(expired_ws, expired_ticket)
    _assert_closed(expired_ws)
    expired_ws.close()
    with sqlite3.connect(world.database, timeout=5) as database:
        expired_consumed = database.execute(
            "SELECT consumed_at FROM relay_tickets WHERE ticket_hash=?", (expired_hash,)
        ).fetchone()[0]
    assert expired_consumed is None
    assert world.echo.accepted == 1

    # Fill all four configured per-user connection permits. A fifth valid
    # ticket must be consumed and rejected without reaching the target. Once a
    # connection closes, a fresh ticket can reuse its released permit.
    for expected_accepts in (2, 3, 4):
        additional = _issue_ticket(world)
        assert additional.status == 200
        status, _, extra_ws = _websocket_handshake(world.base_url, world.base_url)
        assert status == 101 and extra_ws is not None
        active.append(extra_ws)
        _send_ticket(extra_ws, additional.json()["ticket"])
        assert world.echo.wait_accepted(expected_accepts), "Relay did not establish an available connection slot"

    over_limit = _issue_ticket(world)
    assert over_limit.status == 200
    status, _, over_limit_ws = _websocket_handshake(world.base_url, world.base_url)
    assert status == 101 and over_limit_ws is not None
    _send_ticket(over_limit_ws, over_limit.json()["ticket"])
    _assert_closed(over_limit_ws)
    over_limit_ws.close()
    assert world.echo.accepted == 4, "over-limit Relay connection must not reach the target"

    active[0].close()
    assert world.echo.wait_closed(1), "closing WebSocket did not close its TCP echo handler"
    replacement = _issue_ticket(world)
    assert replacement.status == 200
    status, _, replacement_ws = _websocket_handshake(world.base_url, world.base_url)
    assert status == 101 and replacement_ws is not None
    active.append(replacement_ws)
    _send_ticket(replacement_ws, replacement.json()["ticket"])
    assert world.echo.wait_accepted(5), "Relay did not release the connection slot after disconnect"
    _echo_bytes(replacement_ws, b"slot-reused\x00\xff")

    for current in active:
        current.close()
    assert world.echo.wait_closed(5), "disconnect did not release all active local echo handlers"

    # Revocation invalidates an already-issued, unconsumed ticket. It does not
    # disturb established streams (all are closed above).
    pending = _issue_ticket(world)
    assert pending.status == 200
    pending_ticket = pending.json()["ticket"]
    pending_hash = hashlib.sha256(pending_ticket.encode("ascii")).hexdigest()
    revoked = api.request(
        "POST",
        f"/api/v1/devices/{world.device_id}/revoke",
        token=world.access_token,
        json_body={},
    )
    assert revoked.status in (200, 204), f"device revoke returned HTTP {revoked.status}"
    status, _, revoked_ws = _websocket_handshake(world.base_url, world.base_url)
    assert status == 101 and revoked_ws is not None
    _send_ticket(revoked_ws, pending_ticket)
    _assert_closed(revoked_ws)
    revoked_ws.close()
    with sqlite3.connect(world.database, timeout=5) as database:
        pending_consumed = database.execute(
            "SELECT consumed_at FROM relay_tickets WHERE ticket_hash=?", (pending_hash,)
        ).fetchone()[0]
    assert pending_consumed is None, "revoked-session ticket must remain unconsumed and undialable"
    assert world.echo.accepted == 5, "revoked ticket must not open a new target TCP connection"
