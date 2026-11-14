"""Black-box checks for ticket-authenticated sync notification sockets."""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import socket
import sqlite3
import ssl
import struct
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, Response, initial_vault
from test_acceptance import (
    _issue_account_invitation,
    _membership_digest,
    _membership_member,
    _new_account_registration,
    _signed_key_envelope,
    _signed_membership,
)


def _error_code(response: Response) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _database_path(api: ApiClient) -> Path:
    admin_env = getattr(api, "admin_env", None)
    assert admin_env is not None, "notification ticket hash check requires the disposable database"
    database_url = admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://"), "acceptance fixture must use SQLite"
    database_path = database_url[len("sqlite://") :].split("?", 1)[0]
    return Path(urllib.parse.unquote(database_path))


def _read_exact(reader: Any, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = reader.read(size - len(chunks))
        if not chunk:
            raise EOFError("WebSocket closed while reading a frame")
        chunks.extend(chunk)
    return bytes(chunks)


def _connect_websocket(
    base_url: str,
    origin: str,
    *,
    additional_origins: tuple[str, ...] = (),
) -> tuple[int, dict[str, str], socket.socket, Any, bytes]:
    parsed = urllib.parse.urlsplit(base_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    connection = socket.create_connection((host, port), timeout=6)
    if parsed.scheme == "https":
        connection = ssl.create_default_context().wrap_socket(connection, server_hostname=host)
    connection.settimeout(6)
    reader = connection.makefile("rb")
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    target = urllib.parse.urlunsplit(("", "", "/api/v1/notifications", "", ""))
    host_header = parsed.netloc
    origin_headers = "".join(f"Origin: {value}\r\n" for value in (origin, *additional_origins))
    request = (
        f"GET {target} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"{origin_headers}"
        "\r\n"
    )
    connection.sendall(request.encode("ascii"))
    status_line = reader.readline().decode("latin-1").strip()
    try:
        status = int(status_line.split(" ", 2)[1])
    except (IndexError, ValueError):
        connection.close()
        raise AssertionError("invalid WebSocket upgrade response status") from None
    headers: dict[str, str] = {}
    while True:
        line = reader.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        name, separator, value = line.decode("latin-1").partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    body = b""
    if status != 101:
        if headers.get("transfer-encoding", "").lower() == "chunked":
            chunks = bytearray()
            while True:
                length_line = reader.readline().split(b";", 1)[0].strip()
                length = int(length_line, 16)
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
        expected_accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        assert headers.get("sec-websocket-accept") == expected_accept
    return status, headers, connection, reader, body


def _send_client_frame(connection: socket.socket, opcode: int, payload: bytes) -> None:
    mask = secrets.token_bytes(4)
    size = len(payload)
    first = bytes((0x80 | opcode,))
    if size < 126:
        header = first + bytes((0x80 | size,))
    elif size <= 0xFFFF:
        header = first + bytes((0x80 | 126,)) + struct.pack("!H", size)
    else:
        header = first + bytes((0x80 | 127,)) + struct.pack("!Q", size)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    connection.sendall(header + mask + masked)


def _receive_ws_frame(connection: socket.socket, reader: Any) -> tuple[int, bytes]:
    first, second = _read_exact(reader, 2)
    opcode = first & 0x0F
    size = second & 0x7F
    if size == 126:
        size = struct.unpack("!H", _read_exact(reader, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", _read_exact(reader, 8))[0]
    mask = _read_exact(reader, 4) if second & 0x80 else None
    payload = _read_exact(reader, size)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    if opcode == 0x9:
        _send_client_frame(connection, 0xA, payload)
        return _receive_ws_frame(connection, reader)
    return opcode, payload


def _send_json_frame(connection: socket.socket, value: dict[str, Any]) -> None:
    _send_client_frame(
        connection,
        0x1,
        json.dumps(value, separators=(",", ":")).encode("utf-8"),
    )


def _receive_json_frame(connection: socket.socket, reader: Any) -> tuple[int, dict[str, Any]]:
    opcode, payload = _receive_ws_frame(connection, reader)
    if opcode != 0x1:
        return opcode, {}
    decoded = json.loads(payload.decode("utf-8"))
    assert isinstance(decoded, dict)
    return opcode, decoded


def _wait_for_sync_hint(
    connection: socket.socket,
    reader: Any,
    predicate,
    *,
    message: str,
    timeout_seconds: float = 10,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        connection.settimeout(max(0.2, deadline - time.monotonic()))
        opcode, frame = _receive_json_frame(connection, reader)
        if opcode == 0x8:
            break
        if opcode == 0x1 and frame.get("type") == "sync_required" and predicate(frame):
            return frame
    pytest.fail(message)


def _close_code(connection: socket.socket, reader: Any) -> int | None:
    opcode, payload = _receive_ws_frame(connection, reader)
    if opcode != 0x8 or len(payload) < 2:
        return None
    return struct.unpack("!H", payload[:2])[0]


def test_notification_ticket_and_websocket_protocol(api, account, make_envelope, push, writable_server):
    if not api.started_by_suite:
        pytest.skip("notification tests require a disposable server configured with ATERMIUS_PUBLIC_ORIGIN")

    unauthenticated = api.request("POST", "/api/v1/notifications/tickets")
    assert unauthenticated.status == 401
    assert _error_code(unauthenticated) == "AUTH_REQUIRED"

    ticket_response = api.request(
        "POST", "/api/v1/notifications/tickets", token=account["access_token"]
    )
    assert ticket_response.status == 200, f"ticket request returned HTTP {ticket_response.status}"
    ticket_body = ticket_response.json()
    assert isinstance(ticket_body, dict)
    ticket = ticket_body.get("ticket")
    assert isinstance(ticket, str), "ticket endpoint omitted its one-time bearer value"
    raw_ticket = base64.urlsafe_b64decode(ticket + "=" * ((4 - len(ticket) % 4) % 4))
    assert len(raw_ticket) == 32
    assert 0 < ticket_body.get("expires_in_seconds", 0) <= 30
    assert isinstance(ticket_body.get("expires_at"), str)
    live_instance_response = api.request("GET", "/api/v1/instance")
    assert live_instance_response.status == 200
    live_instance = live_instance_response.json()

    database_path = _database_path(api)
    with sqlite3.connect(database_path, timeout=5) as database:
        stored_hashes = [row[0] for row in database.execute("SELECT ticket_hash FROM notification_tickets")]
        expected_hash = hashlib.sha256(ticket.encode("ascii")).hexdigest()
        assert expected_hash in stored_hashes
        assert ticket not in stored_hashes

    # Origin is checked before the server upgrades the connection.
    bad_status, _, bad_socket, bad_reader, bad_body = _connect_websocket(
        api.base_url, api.base_url + ".attacker"
    )
    try:
        assert bad_status == 403
        assert json.loads(bad_body.decode("utf-8"))["error"]["code"] == "ORIGIN_DENIED"
    finally:
        bad_reader.close()
        bad_socket.close()

    duplicate_origin_status, _, duplicate_socket, duplicate_reader, duplicate_body = _connect_websocket(
        api.base_url,
        api.base_url,
        additional_origins=(api.base_url,),
    )
    try:
        assert duplicate_origin_status == 403
        assert json.loads(duplicate_body.decode("utf-8"))["error"]["code"] == "ORIGIN_DENIED"
    finally:
        duplicate_reader.close()
        duplicate_socket.close()

    # A syntactically invalid first frame is rejected after upgrade without
    # consuming or revealing any valid ticket.
    bad_frame_status, _, bad_frame_socket, bad_frame_reader, _ = _connect_websocket(
        api.base_url, api.base_url
    )
    try:
        assert bad_frame_status == 101
        _send_json_frame(bad_frame_socket, {"type": "unexpected"})
        opcode, error_frame = _receive_json_frame(bad_frame_socket, bad_frame_reader)
        assert opcode == 0x1
        assert set(error_frame) == {"type", "code"}
        assert error_frame.get("type") == "error"
        assert error_frame.get("code") == "AUTH_REQUIRED"
        assert _close_code(bad_frame_socket, bad_frame_reader) == 4001
    finally:
        bad_frame_reader.close()
        bad_frame_socket.close()

    status, _, connection, reader, _ = _connect_websocket(api.base_url, api.base_url)
    try:
        assert status == 101
        _send_json_frame(connection, {"type": "authenticate", "ticket": ticket})
        opcode, ready = _receive_json_frame(connection, reader)
        assert opcode == 0x1
        assert ready.get("type") == "ready"
        assert set(ready) == {
            "type", "server_generation", "sync_required", "heartbeat_seconds", "poll_interval_seconds"
        }
        assert ready.get("server_generation") == live_instance["generation"]
        assert ready.get("sync_required") is True
        assert ready.get("heartbeat_seconds") == 30
        assert ready.get("poll_interval_seconds") == 2

        operation = make_envelope(
            record_id=str(uuid.uuid4()),
            op_id=str(uuid.uuid4()),
            operation="create",
        )
        pushed = push(operation)
        assert pushed.status == 200, f"sync push returned HTTP {pushed.status}"
        first_result = pushed.json()["results"][0]
        hint = _wait_for_sync_hint(
            connection,
            reader,
            lambda frame: frame.get("commit_seq") == first_result["commit_seq"],
            message="no record sync_required frame followed the committed push",
        )
        assert hint == {
            "type": "sync_required",
            "vault_id": account["vault_id"],
            "commit_seq": first_result["commit_seq"],
        }

        record_id = operation["header"]["record_id"]
        revision_one = first_result["revision_id"]
        main_update = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=revision_one,
        )
        update_response = push(main_update)
        assert update_response.status == 200, f"main update failed: {_error_code(update_response)}"
        second_result = update_response.json()["results"][0]
        hint = _wait_for_sync_hint(
            connection,
            reader,
            lambda frame: frame.get("commit_seq") == second_result["commit_seq"],
            message="no record sync_required frame followed the main update",
        )
        assert hint == {
            "type": "sync_required",
            "vault_id": account["vault_id"],
            "commit_seq": second_result["commit_seq"],
        }

        baseline_response = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?limit=1",
            token=account["access_token"],
        )
        assert baseline_response.status == 200
        conflict_baseline = baseline_response.json()["high_watermark"]
        branch = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=revision_one,
        )
        branch_response = api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/conflicts",
            token=account["access_token"],
            json_body={"envelope": branch},
        )
        assert branch_response.status in (200, 201)
        conflict_page = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?after_seq={conflict_baseline}&server_generation={live_instance['generation']}",
            token=account["access_token"],
        )
        assert conflict_page.status == 200
        created_event = conflict_page.json()["events"][0]
        assert created_event["type"] == "created"
        assert created_event["conflict_id"] == branch_response.json()["conflict_id"]
        conflict_hint = _wait_for_sync_hint(
            connection,
            reader,
            lambda frame: frame.get("conflict_seq") == created_event["seq"],
            message="no conflict sync_required frame followed the conflict create",
        )
        assert conflict_hint == {
            "type": "sync_required",
            "vault_id": account["vault_id"],
            "conflict_seq": created_event["seq"],
        }
        assert "commit_seq" not in conflict_hint

        resolved = api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/conflicts/{branch_response.json()['conflict_id']}/resolve",
            token=account["access_token"],
            json_body={"resolved_revision_id": second_result["revision_id"]},
        )
        assert resolved.status == 200, f"conflict resolve failed: {_error_code(resolved)}"
        resolved_hint = _wait_for_sync_hint(
            connection,
            reader,
            lambda frame: frame.get("conflict_seq") == resolved.json()["resolution_seq"],
            message="no conflict sync_required frame followed conflict resolution",
        )
        assert resolved_hint == {
            "type": "sync_required",
            "vault_id": account["vault_id"],
            "conflict_seq": resolved.json()["resolution_seq"],
        }
        assert "commit_seq" not in resolved_hint
        with sqlite3.connect(database_path, timeout=5) as database:
            consumed = database.execute(
                "SELECT consumed_at FROM notification_tickets WHERE ticket_hash=?",
                (expected_hash,),
            ).fetchone()
        assert consumed is not None and consumed[0] is not None
    finally:
        try:
            _send_client_frame(connection, 0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        reader.close()
        connection.close()


    # Ticket replay must fail closed, with no token or session data in the URL.
    replay_status, _, replay_socket, replay_reader, _ = _connect_websocket(api.base_url, api.base_url)
    try:
        assert replay_status == 101
        _send_json_frame(replay_socket, {"type": "authenticate", "ticket": ticket})
        opcode, replay_error = _receive_json_frame(replay_socket, replay_reader)
        assert opcode == 0x1
        assert set(replay_error) == {"type", "code"}
        assert replay_error.get("type") == "error"
        assert replay_error.get("code") == "AUTH_REQUIRED"
        assert _close_code(replay_socket, replay_reader) == 4001
    finally:
        replay_reader.close()
        replay_socket.close()

    # The tenth outstanding issue succeeds; the next issue is rate limited.
    for _ in range(9):
        additional = api.request(
            "POST", "/api/v1/notifications/tickets", token=account["access_token"]
        )
        assert additional.status == 200
    limited = api.request(
        "POST", "/api/v1/notifications/tickets", token=account["access_token"]
    )
    assert limited.status == 429
    assert _error_code(limited) == "NOTIFICATION_TICKET_RATE_LIMITED"
    assert int(limited.headers.get("Retry-After", "0")) > 0


def test_mobile_push_registration_is_disabled_without_provider_and_stores_no_token(
    api: ApiClient,
    account: dict[str, Any],
) -> None:
    database_path = _database_path(api)
    marker = "fcm-blackbox-token-abcdefghijklmnop"
    unauthenticated = api.request(
        "PUT",
        f"/api/v1/notifications/push-endpoints/{account['device_id']}",
        json_body={"provider": "fcm_v1", "token": marker},
    )
    assert unauthenticated.status == 401
    assert _error_code(unauthenticated) == "AUTH_REQUIRED"

    wrong_device = api.request(
        "PUT",
        f"/api/v1/notifications/push-endpoints/{uuid.uuid4()}",
        token=account["access_token"],
        json_body={"provider": "fcm_v1", "token": marker},
    )
    assert wrong_device.status == 403
    assert _error_code(wrong_device) == "DEVICE_MISMATCH"

    response = api.request(
        "PUT",
        f"/api/v1/notifications/push-endpoints/{account['device_id']}",
        token=account["access_token"],
        json_body={"provider": "fcm_v1", "token": marker},
    )
    assert response.status == 503
    assert _error_code(response) == "PUSH_DELIVERY_DISABLED"
    assert marker.encode() not in response.body
    with sqlite3.connect(database_path) as connection:
        row_count = connection.execute(
            "SELECT COUNT(*) FROM notification_push_endpoints WHERE device_id = ?",
            (account["device_id"],),
        ).fetchone()[0]
    assert row_count == 0, "disabled provider registration must not retain a device token"

    invalid_provider = api.request(
        "DELETE",
        f"/api/v1/notifications/push-endpoints/{account['device_id']}/future_provider",
        token=account["access_token"],
    )
    assert invalid_provider.status == 400
    assert _error_code(invalid_provider) == "INVALID_PUSH_PROVIDER"


def test_notification_membership_change_hint(api, account, tmp_path, writable_server):
    """An accepted cross-account invite wakes a socket without exposing records."""
    if not api.started_by_suite:
        pytest.skip("notification membership acceptance requires the suite-owned disposable server")

    from conftest import SigningKey, b64url

    username = f"notify-member-{uuid.uuid4().hex[:12]}@example.test"
    enrollment_token = _issue_account_invitation(api, username)
    second_account_id = str(uuid.uuid4())
    second_device_id = str(uuid.uuid4())
    second_encryption_key = b64url(secrets.token_bytes(32))
    second_signer = SigningKey(tmp_path, "notification-member")
    registration = _new_account_registration(
        second_account_id,
        username,
        second_device_id,
        second_encryption_key,
        second_signer,
    )
    registered = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={**registration, "instance_invitation_token": enrollment_token},
    )
    assert registered.status in (200, 201), "second notification test account could not register"
    second_access_token = registered.json()["access_token"]

    ticket_response = api.request(
        "POST", "/api/v1/notifications/tickets", token=second_access_token
    )
    assert ticket_response.status == 200
    ticket = ticket_response.json()["ticket"]
    status, _, connection, reader, _ = _connect_websocket(api.base_url, api.base_url)
    try:
        assert status == 101
        _send_json_frame(connection, {"type": "authenticate", "ticket": ticket})
        opcode, ready = _receive_json_frame(connection, reader)
        assert opcode == 0x1 and ready.get("type") == "ready"

        owner_vault = initial_vault(
            account_id=account["account_id"],
            vault_id=str(uuid.uuid4()),
            device_id=account["device_id"],
            encryption_public_key=account["encryption_public_key"],
            signer=account["signing_key"],
        )
        created_vault = api.request(
            "POST",
            "/api/v1/vaults",
            token=account["access_token"],
            json_body={
                "vault_id": owner_vault["vault_id"],
                "name_envelope": owner_vault["name_envelope"],
                "key_envelope": owner_vault["key_envelope"],
                "membership": owner_vault["membership"],
            },
        )
        assert created_vault.status in (200, 201)

        owner_member = _membership_member(
            account["account_id"], "owner", account["encryption_public_key"]
        )
        invitee_member = _membership_member(
            second_account_id, "editor", second_encryption_key
        )
        next_membership = _signed_membership(
            owner_vault["vault_id"],
            2,
            _membership_digest(owner_vault["vault_id"], owner_vault["membership"]),
            1,
            [owner_member, invitee_member],
            account["device_id"],
            account["signing_key"],
        )
        key_envelope = _signed_key_envelope(
            owner_vault["vault_id"],
            second_device_id,
            1,
            2,
            account["signing_key"],
        )
        issued = api.request(
            "POST",
            f"/api/v1/vaults/{owner_vault['vault_id']}/invitations",
            token=account["access_token"],
            json_body={
                "role": "editor",
                "recipient_device_id": second_device_id,
                "recipient_encryption_public_key": second_encryption_key,
                "key_envelope": key_envelope,
                "membership": next_membership,
            },
        )
        assert issued.status in (200, 201)
        accepted = api.request(
            "POST",
            "/api/v1/invitations/accept",
            token=second_access_token,
            json_body={"token": issued.json()["token"]},
        )
        assert accepted.status in (200, 201)

        deadline = time.monotonic() + 8
        membership_hint = None
        while time.monotonic() < deadline:
            connection.settimeout(max(0.2, deadline - time.monotonic()))
            try:
                opcode, frame = _receive_json_frame(connection, reader)
            except (TimeoutError, socket.timeout):
                continue
            if opcode == 0x1 and frame.get("type") == "sync_required":
                membership_hint = frame
                break
        assert membership_hint is not None, "membership change did not wake the new member's socket"
        assert membership_hint == {"type": "sync_required", "vault_id": None, "commit_seq": None}

        logout = api.request("POST", "/api/v1/auth/logout", token=second_access_token)
        assert logout.status == 200
        opcode, revoked = _receive_json_frame(connection, reader)
        assert opcode == 0x1
        assert revoked == {"type": "error", "code": "AUTH_REQUIRED"}
        assert _close_code(connection, reader) == 4001
    finally:
        try:
            _send_client_frame(connection, 0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        reader.close()
        connection.close()
