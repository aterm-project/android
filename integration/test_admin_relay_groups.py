"""Black-box acceptance for server-managed Relay access groups."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import sqlite3
from typing import Any

import pytest

from test_admin_relay_policy import _PolicyWorld, relay_policy_world
from test_relay import _assert_closed, _echo_bytes, _send_ticket, _websocket_handshake


def _error_code(response: Any) -> str | None:
    body = response.json() if hasattr(response, "json") else response
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _group_path(group_id: str) -> str:
    return f"/api/v1/admin/relay-groups/{group_id}"


def _create_group(world: _PolicyWorld, name: str) -> dict[str, Any]:
    response = world.api.request(
        "POST",
        "/api/v1/admin/relay-groups",
        token=world.admin["access_token"],
        json_body={"name": name},
    )
    assert response.status == 201, f"Relay group creation failed with HTTP {response.status}"
    return response.json()


def _replace_members(
    world: _PolicyWorld,
    group_id: str,
    *,
    revision: int,
    user_ids: list[str],
):
    return world.api.request(
        "PUT",
        f"{_group_path(group_id)}/members",
        token=world.admin["access_token"],
        json_body={"expected_revision": revision, "user_ids": user_ids},
    )


def _write_group_policy(
    world: _PolicyWorld,
    group_id: str,
    *,
    revision: int,
    instance_revision: int,
    enabled: bool,
    allow_cidrs: list[str],
    allow_ports: list[int],
):
    return world.api.request(
        "PUT",
        f"{_group_path(group_id)}/relay-policy",
        token=world.admin["access_token"],
        json_body={
            "expected_revision": revision,
            "expected_instance_policy_revision": instance_revision,
            "enabled": enabled,
            "allow_cidrs": allow_cidrs,
            "allow_ports": allow_ports,
        },
    )


def _ticket(world: _PolicyWorld, host: str, port: int):
    return world.api.request(
        "POST",
        "/api/v1/relay/tickets",
        token=world.member_token,
        json_body={
            "device_id": world.member_device_id,
            "target_host": host,
            "target_port": port,
        },
    )


def test_admin_relay_groups_policy_cas_composition_and_immediate_revocation(
    relay_policy_world: _PolicyWorld,
) -> None:
    world = relay_policy_world
    admin_token = world.admin["access_token"]

    assert world.api.request("GET", "/api/v1/admin/relay-groups").status == 401
    assert (
        world.api.request(
            "GET", "/api/v1/admin/relay-groups", token=world.member_token
        ).status
        == 403
    )
    listing = world.api.request(
        "GET", "/api/v1/admin/relay-groups", token=admin_token
    )
    assert listing.status == 200 and listing.json() == {"groups": []}

    # NFKC normalization is also part of the database uniqueness key.
    first = _create_group(world, "  Ｏｐｓ  ")
    first_group = first["group"]
    first_id = first_group["group_id"]
    assert first_group["name"] == "Ops"
    assert first_group["revision"] == 1
    assert first["members"] == {"revision": 0, "items": []}
    assert first["policy"]["inherited"] is True
    assert first["policy"]["revision"] == 0
    duplicate = world.api.request(
        "POST",
        "/api/v1/admin/relay-groups",
        token=admin_token,
        json_body={"name": "ops"},
    )
    assert duplicate.status == 409 and _error_code(duplicate) == "RELAY_GROUP_NAME_TAKEN"
    second = _create_group(world, "SSH 工作组")
    second_id = second["group"]["group_id"]
    assert second["group"]["name"] == "SSH 工作组"

    # Name CAS is independent from membership and group policy CAS.
    stale_rename = world.api.request(
        "PUT",
        _group_path(first_id),
        token=admin_token,
        json_body={"expected_revision": 0, "name": "过期名称"},
    )
    assert stale_rename.status == 409 and _error_code(stale_rename) == "RELAY_GROUP_CONFLICT"
    renamed = world.api.request(
        "PUT",
        _group_path(first_id),
        token=admin_token,
        json_body={"expected_revision": 1, "name": "运维组"},
    )
    assert renamed.status == 200
    assert renamed.json()["group"]["name"] == "运维组"
    assert renamed.json()["group"]["revision"] == 2
    assert renamed.json()["members"]["revision"] == 0
    no_op_rename = world.api.request(
        "PUT",
        _group_path(first_id),
        token=admin_token,
        json_body={"expected_revision": 2, "name": "运维组"},
    )
    assert no_op_rename.status == 200
    assert no_op_rename.json()["group"]["revision"] == 2

    member_id = world.member_account_id
    first_members = _replace_members(
        world, first_id, revision=0, user_ids=[member_id]
    )
    second_members = _replace_members(
        world, second_id, revision=0, user_ids=[member_id]
    )
    assert first_members.status == second_members.status == 200
    assert first_members.json()["members"]["revision"] == 1
    assert first_members.json()["members"]["items"] == [
        {"user_id": member_id, "username": world.member_username}
    ]
    stale_members = _replace_members(
        world, first_id, revision=0, user_ids=[member_id]
    )
    assert (
        stale_members.status == 409
        and _error_code(stale_members) == "RELAY_GROUP_MEMBERSHIP_CONFLICT"
    )
    malformed_members = _replace_members(
        world, first_id, revision=1, user_ids=[member_id, member_id]
    )
    assert (
        malformed_members.status == 400
        and _error_code(malformed_members) == "INVALID_RELAY_GROUP_MEMBERS_REQUEST"
    )

    # Group 1 is narrow (/32 + one exact port); group 2 is broader (/25 + two
    # exact ports). The user's policy is the intersection of both groups.
    target_ip = ipaddress.ip_address(world.target_ip)
    broad_network = next(
        network
        for network in world.ceiling_network.subnets(new_prefix=25)
        if target_ip in network
    )
    first_policy = _write_group_policy(
        world,
        first_id,
        revision=0,
        instance_revision=0,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    second_policy = _write_group_policy(
        world,
        second_id,
        revision=0,
        instance_revision=0,
        enabled=True,
        allow_cidrs=[str(broad_network)],
        allow_ports=sorted(
            [world.echo.port, 22 if world.echo.port != 22 else 23]
        ),
    )
    assert first_policy.status == second_policy.status == 200
    first_policy_body = first_policy.json()["policy"]
    assert first_policy_body["inherited"] is False
    assert first_policy_body["revision"] == 1
    assert first_policy_body["effective_policy"]["allow_ports"] == [world.echo.port]
    stale_group_policy = _write_group_policy(
        world,
        first_id,
        revision=0,
        instance_revision=0,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert (
        stale_group_policy.status == 409
        and _error_code(stale_group_policy) == "RELAY_GROUP_POLICY_CONFLICT"
    )
    stale_instance_policy = _write_group_policy(
        world,
        first_id,
        revision=1,
        instance_revision=999,
        enabled=True,
        allow_cidrs=[f"{world.target_ip}/32"],
        allow_ports=[world.echo.port],
    )
    assert (
        stale_instance_policy.status == 409
        and _error_code(stale_instance_policy) == "RELAY_GROUP_POLICY_CONFLICT"
    )

    user_policy = world.api.request(
        "GET",
        f"/api/v1/admin/relay-policy/users/{member_id}",
        token=admin_token,
    )
    assert user_policy.status == 200
    assert user_policy.json()["effective_policy"] == {
        "enabled": True,
        "allow_cidrs": [f"{world.target_ip}/32"],
        "allow_ports": [world.echo.port],
    }
    allowed = _ticket(world, world.target_ip, world.echo.port)
    assert allowed.status == 200
    denied = _ticket(world, world.target_ip, 22 if world.echo.port != 22 else 23)
    assert denied.status == 403 and _error_code(denied) == "TARGET_DENIED"

    # Bind both an unused ticket and a live socket to the current group
    # authorization revision, then remove the user from only the narrower
    # group. Group 2 still permits the same target, so socket closure proves
    # revision-based immediate revocation rather than only target rechecking.
    pending = _ticket(world, world.target_ip, world.echo.port)
    assert pending.status == 200
    pending_ticket = pending.json()["ticket"]
    pending_hash = hashlib.sha256(pending_ticket.encode("ascii")).hexdigest()
    connected = _ticket(world, world.target_ip, world.echo.port)
    assert connected.status == 200
    status, _, ws = _websocket_handshake(world.base_url, world.base_url)
    assert status == 101 and ws is not None
    _send_ticket(ws, connected.json()["ticket"])
    assert world.echo.wait_accepted(1), "live Relay did not reach the local TCP sink"
    _echo_bytes(ws, b"group-policy-live-connection")

    removed = _replace_members(world, first_id, revision=1, user_ids=[])
    assert removed.status == 200 and removed.json()["members"]["revision"] == 2
    with sqlite3.connect(world.database, timeout=5) as connection:
        pending_exists = connection.execute(
            "SELECT EXISTS(SELECT 1 FROM relay_tickets WHERE ticket_hash=?)",
            (pending_hash,),
        ).fetchone()[0]
    assert pending_exists == 0, "member removal must invalidate unused Relay tickets atomically"
    pending_status, _, pending_ws = _websocket_handshake(world.base_url, world.base_url)
    assert pending_status == 101 and pending_ws is not None
    _send_ticket(pending_ws, pending_ticket)
    _assert_closed(pending_ws)
    pending_ws.conn.close()
    pending_ws.reader.close()
    _assert_closed(ws)
    ws.conn.close()
    ws.reader.close()
    still_allowed = _ticket(world, world.target_ip, world.echo.port)
    assert still_allowed.status == 200, "the remaining group still permits this target"

    disabled = world.api.request(
        "PUT",
        f"/api/v1/admin/accounts/{member_id}/status",
        token=admin_token,
        json_body={"status": "disabled"},
    )
    assert disabled.status == 200
    retain_disabled = _replace_members(
        world, second_id, revision=1, user_ids=[member_id]
    )
    assert retain_disabled.status == 200
    assert retain_disabled.json()["members"]["revision"] == 1
    remove_disabled = _replace_members(
        world, second_id, revision=1, user_ids=[]
    )
    assert remove_disabled.status == 200
    assert remove_disabled.json()["members"]["revision"] == 2

    # Policy reset retains the CAS watermark and is idempotent while inherited.
    reset = world.api.request(
        "DELETE",
        f"{_group_path(second_id)}/relay-policy",
        token=admin_token,
        json_body={"expected_revision": 1},
    )
    assert reset.status == 200
    reset_policy = reset.json()["policy"]
    assert reset_policy["inherited"] is True and reset_policy["revision"] == 2
    stale_reset = world.api.request(
        "DELETE",
        f"{_group_path(second_id)}/relay-policy",
        token=admin_token,
        json_body={"expected_revision": 1},
    )
    assert stale_reset.status == 409 and _error_code(stale_reset) == "RELAY_GROUP_POLICY_CONFLICT"
    no_op_reset = world.api.request(
        "DELETE",
        f"{_group_path(second_id)}/relay-policy",
        token=admin_token,
        json_body={"expected_revision": 2},
    )
    assert no_op_reset.status == 200
    assert no_op_reset.json()["policy"]["revision"] == 2

    stale_delete = world.api.request(
        "DELETE",
        _group_path(first_id),
        token=admin_token,
        json_body={
            "expected_revision": 2,
            "expected_membership_revision": 1,
            "expected_policy_revision": 1,
        },
    )
    assert (
        stale_delete.status == 409
        and _error_code(stale_delete) == "RELAY_GROUP_MEMBERSHIP_CONFLICT"
    )
    deleted_first = world.api.request(
        "DELETE",
        _group_path(first_id),
        token=admin_token,
        json_body={
            "expected_revision": 2,
            "expected_membership_revision": 2,
            "expected_policy_revision": 1,
        },
    )
    assert deleted_first.status == 204 and deleted_first.body == b""
    deleted_second = world.api.request(
        "DELETE",
        _group_path(second_id),
        token=admin_token,
        json_body={
            "expected_revision": 1,
            "expected_membership_revision": 2,
            "expected_policy_revision": 2,
        },
    )
    assert deleted_second.status == 204 and deleted_second.body == b""
    assert world.api.request(
        "GET", _group_path(first_id), token=admin_token
    ).status == 404

    audit = world.api.request("GET", "/api/v1/admin/audit", token=admin_token)
    assert audit.status == 200
    events = audit.json()["events"]
    actions = {
        event["action"]
        for event in events
        if event["action"].startswith("admin.relay_group_")
    }
    assert {
        "admin.relay_group_created",
        "admin.relay_group_renamed",
        "admin.relay_group_membership_updated",
        "admin.relay_group_policy_updated",
        "admin.relay_group_policy_reset",
        "admin.relay_group_deleted",
    } <= actions
    relay_group_events = [
        event for event in events if event["action"].startswith("admin.relay_group_")
    ]
    assert all(event["resource_type"] == "relay_access_group" for event in relay_group_events)
    assert all(event["resource_id"] not in {first_id, second_id} for event in relay_group_events)
    serialized_audit = json.dumps(relay_group_events, ensure_ascii=False)
    for private_value in (
        "Ops",
        "运维组",
        "SSH 工作组",
        world.member_username,
        member_id,
        f"{world.target_ip}/32",
    ):
        assert private_value not in serialized_audit
