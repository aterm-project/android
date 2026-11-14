"""Black-box acceptance for bounded per-account Vault and per-Vault member counts."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

import pytest

from conftest import ApiClient, SigningKey, b64url, initial_vault
from test_acceptance import (
    _issue_account_invitation,
    _membership_digest,
    _membership_member,
    _new_account_registration,
    _signed_key_envelope,
    _signed_membership,
)


USER_VAULT_LIMIT = 50
VAULT_MEMBER_LIMIT = 100


@pytest.fixture(scope="module", autouse=True)
def _bootstrap_suite_owned_server(api: ApiClient, request: pytest.FixtureRequest) -> None:
    # Operator-issued invitations are unavailable until the suite-owned
    # server's one-time bootstrap registration has completed. Leave externally
    # supplied servers alone; each test's SQLite ownership check will skip.
    if api.started_by_suite:
        request.getfixturevalue("account")


def _error_code(response) -> str | None:
    body = response.json()
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def _database_path(api: ApiClient) -> Path:
    if not api.started_by_suite or not api.admin_env:
        pytest.skip("Vault count limits require the suite-owned disposable SQLite server")
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    if not database_url.startswith("sqlite://"):
        pytest.skip("Vault count limit acceptance requires the suite-owned SQLite database")
    return Path(unquote(database_url[len("sqlite://") :].split("?", 1)[0]))


def _assert_default_limits(api: ApiClient) -> None:
    """These black-box cases exercise the documented default 50/100 limits."""
    env = getattr(api, "server_env", None) or {}
    for key, default, maximum in (
        ("ATERMIUS_MAX_VAULTS_PER_USER", USER_VAULT_LIMIT, 4096),
        ("ATERMIUS_MAX_MEMBERS_PER_VAULT", VAULT_MEMBER_LIMIT, 1000),
    ):
        value = env.get(key)
        try:
            parsed = int(value) if value is not None else default
        except (TypeError, ValueError):
            continue  # invalid values fall back to the default at startup
        if 1 <= parsed <= maximum and parsed != default:
            pytest.skip(f"{key} overrides the default used by this boundary test")


def _register_account(api: ApiClient, tmp_path: Path, label: str) -> dict:
    _database_path(api)
    username = f"it-vault-count-{label}-{uuid.uuid4().hex[:10]}@example.test"
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    encryption_public_key = b64url(os.urandom(32))
    signer = SigningKey(tmp_path, f"vault-count-{label}-{uuid.uuid4().hex[:6]}")
    registration = _new_account_registration(
        account_id,
        username,
        device_id,
        encryption_public_key,
        signer,
    )
    response = api.request(
        "POST",
        "/api/v1/auth/register",
        json_body={
            **registration,
            "instance_invitation_token": _issue_account_invitation(api, username),
        },
    )
    assert response.status in (200, 201), (
        f"{label} account enrollment failed with HTTP {response.status}: {_error_code(response)}"
    )
    body = response.json()
    assert isinstance(body, dict) and isinstance(body.get("access_token"), str)
    return {
        "account_id": account_id,
        "device_id": device_id,
        "username": username,
        "access_token": body["access_token"],
        "encryption_public_key": encryption_public_key,
        "signing_key": signer,
        "initial_vault": registration["initial_vault"],
    }


def _create_vault(api: ApiClient, owner: dict, label: str) -> dict:
    vault = initial_vault(
        account_id=owner["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=owner["device_id"],
        encryption_public_key=owner["encryption_public_key"],
        signer=owner["signing_key"],
    )
    response = api.request(
        "POST",
        "/api/v1/vaults",
        token=owner["access_token"],
        json_body={
            "vault_id": vault["vault_id"],
            "name_envelope": vault["name_envelope"],
            "key_envelope": vault["key_envelope"],
            "membership": vault["membership"],
        },
    )
    assert response.status in (200, 201), (
        f"{label} Vault creation failed with HTTP {response.status}: {_error_code(response)}"
    )
    return vault


def _make_invitation_request(
    owner: dict,
    vault_id: str,
    recipient: dict,
    version: int,
    previous_digest: str | None,
    manifest_members: list[dict],
) -> tuple[dict, dict]:
    recipient_member = _membership_member(
        recipient["account_id"], "editor", recipient["encryption_public_key"]
    )
    membership = _signed_membership(
        vault_id,
        version,
        previous_digest,
        1,
        [*manifest_members, recipient_member],
        owner["device_id"],
        owner["signing_key"],
    )
    key_envelope = _signed_key_envelope(
        vault_id,
        recipient["device_id"],
        1,
        version,
        owner["signing_key"],
    )
    return (
        {
            "role": "editor",
            "recipient_device_id": recipient["device_id"],
            "recipient_encryption_public_key": recipient["encryption_public_key"],
            "key_envelope": key_envelope,
            "membership": membership,
        },
        membership,
    )


def _create_invitation(api: ApiClient, owner: dict, recipient: dict, label: str) -> dict:
    vault = _create_vault(api, owner, f"{label} invitation target")
    owner_member = _membership_member(
        owner["account_id"], "owner", owner["encryption_public_key"]
    )
    body, membership = _make_invitation_request(
        owner,
        vault["vault_id"],
        recipient,
        2,
        _membership_digest(vault["vault_id"], vault["membership"]),
        [owner_member],
    )
    issued = api.request(
        "POST",
        f"/api/v1/vaults/{vault['vault_id']}/invitations",
        token=owner["access_token"],
        json_body=body,
    )
    assert issued.status in (200, 201), (
        f"{label} invitation failed with HTTP {issued.status}: {_error_code(issued)}"
    )
    return {
        "vault_id": vault["vault_id"],
        "token": issued.json()["token"],
        "invitation_id": issued.json()["invitation_id"],
        "membership": membership,
    }


def _accept_invitation(api: ApiClient, recipient: dict, invitation: dict):
    return api.request(
        "POST",
        "/api/v1/invitations/accept",
        token=recipient["access_token"],
        json_body={"token": invitation["token"]},
    )


def _listed_vault_ids(api: ApiClient, account: dict) -> set[str]:
    response = api.request("GET", "/api/v1/vaults", token=account["access_token"])
    assert response.status == 200, f"Vault list failed: {_error_code(response)}"
    return {item["vault_id"] for item in response.json()["vaults"]}


def _active_membership_count(api: ApiClient, user_id: str) -> int:
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        return connection.execute(
            "SELECT COUNT(DISTINCT vm.vault_id) FROM vault_members vm "
            "JOIN vaults v ON v.vault_id=vm.vault_id "
            "WHERE vm.user_id=? AND vm.state='active' AND v.state IN ('active','deleting')",
            (user_id,),
        ).fetchone()[0]


def _vault_creation_rows(api: ApiClient, vault_id: str) -> tuple[int, ...]:
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        return (
            connection.execute("SELECT COUNT(*) FROM vaults WHERE vault_id=?", (vault_id,)).fetchone()[0],
            connection.execute("SELECT COUNT(*) FROM vault_members WHERE vault_id=?", (vault_id,)).fetchone()[0],
            connection.execute("SELECT COUNT(*) FROM vault_counters WHERE vault_id=?", (vault_id,)).fetchone()[0],
            connection.execute("SELECT COUNT(*) FROM membership_manifests WHERE vault_id=?", (vault_id,)).fetchone()[0],
            connection.execute("SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=?", (vault_id,)).fetchone()[0],
            connection.execute(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=?", (vault_id,)
            ).fetchone()[0],
        )


def test_user_vault_limit_serializes_concurrent_create_at_fifty(
    api: ApiClient, tmp_path: Path
) -> None:
    _assert_default_limits(api)
    owner = _register_account(api, tmp_path, "create-race")
    created_vault_ids = {owner["initial_vault"]["vault_id"]}

    # The account starts with its personal Vault; add 48 more to reach 49.
    for index in range(USER_VAULT_LIMIT - 2):
        vault = _create_vault(api, owner, f"fill-{index}")
        created_vault_ids.add(vault["vault_id"])

    # Deletion grace keeps the active membership visible and consumes a slot.
    deleting_vault_id = sorted(created_vault_ids)[1]
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        connection.execute(
            "UPDATE vaults SET state='deleting' WHERE vault_id=?", (deleting_vault_id,)
        )
    listed_before = _listed_vault_ids(api, owner)
    assert len(listed_before) == USER_VAULT_LIMIT - 1
    assert deleting_vault_id in listed_before
    assert _active_membership_count(api, owner["account_id"]) == USER_VAULT_LIMIT - 1

    contenders = [
        initial_vault(
            account_id=owner["account_id"],
            vault_id=str(uuid.uuid4()),
            device_id=owner["device_id"],
            encryption_public_key=owner["encryption_public_key"],
            signer=owner["signing_key"],
        )
        for _ in range(2)
    ]
    start = threading.Barrier(2)

    def submit(vault: dict):
        start.wait(timeout=10)
        return api.request(
            "POST",
            "/api/v1/vaults",
            token=owner["access_token"],
            json_body={
                "vault_id": vault["vault_id"],
                "name_envelope": vault["name_envelope"],
                "key_envelope": vault["key_envelope"],
                "membership": vault["membership"],
            },
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(submit, contenders))

    accepted = [
        index for index, response in enumerate(responses) if response.status in (200, 201)
    ]
    rejected = [index for index, response in enumerate(responses) if response.status not in (200, 201)]
    assert len(accepted) == 1, [
        (response.status, _error_code(response)) for response in responses
    ]
    assert len(rejected) == 1
    rejected_index = rejected[0]
    rejected_response = responses[rejected_index]
    assert rejected_response.status == 409
    assert _error_code(rejected_response) == "USER_VAULT_LIMIT_REACHED"

    listed_after = _listed_vault_ids(api, owner)
    assert len(listed_after) == USER_VAULT_LIMIT
    assert contenders[accepted[0]]["vault_id"] in listed_after
    assert contenders[rejected_index]["vault_id"] not in listed_after
    assert _active_membership_count(api, owner["account_id"]) == USER_VAULT_LIMIT
    assert _vault_creation_rows(api, contenders[rejected_index]["vault_id"]) == (0, 0, 0, 0, 0, 0)


def _seed_member_limit_vault(api: ApiClient, owner: dict, tmp_path: Path) -> tuple[list[dict], str]:
    """Seed a signed 99-count chain plus revoked history, without 100 account enrollments."""
    vault_id = owner["initial_vault"]["vault_id"]
    genesis = owner["initial_vault"]["membership"]
    now = datetime.now(timezone.utc).isoformat()
    live_members = [
        _membership_member(owner["account_id"], "owner", owner["encryption_public_key"])
    ]
    revoked_members: list[dict] = []
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        for index in range(98 + 5):
            user_id = str(uuid.uuid4())
            public_key = b64url(os.urandom(32))
            username = f"synthetic-vault-member-{uuid.uuid4().hex}@example.test"
            connection.execute(
                "INSERT INTO users(user_id,username,status,created_at) VALUES(?,?,'active',?)",
                (user_id, username, now),
            )
            state = "active" if index < 98 else "revoked"
            connection.execute(
                "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor',?,?)",
                (vault_id, user_id, state, now),
            )
            member = _membership_member(user_id, "editor", public_key)
            if state == "active":
                live_members.append(member)
            else:
                member["state"] = "revoked"
                revoked_members.append(member)

        previous_digest = _membership_digest(vault_id, genesis)
        membership_v2 = _signed_membership(
            vault_id,
            2,
            previous_digest,
            1,
            [*live_members, *revoked_members],
            owner["device_id"],
            owner["signing_key"],
        )
        digest_v2 = _membership_digest(vault_id, membership_v2)
        stored_record = {
            "vault_id": vault_id,
            "membership_version": membership_v2["membership_version"],
            "previous_digest": membership_v2["previous_digest"],
            "manifest": membership_v2["manifest"],
            "signature": membership_v2["signature"],
        }
        connection.execute(
            "UPDATE vaults SET membership_version=2 WHERE vault_id=?", (vault_id,)
        )
        connection.execute(
            "INSERT INTO membership_manifests(vault_id,membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at) "
            "VALUES(?,2,?,?,?,?,?,?)",
            (
                vault_id,
                previous_digest,
                json.dumps(stored_record, separators=(",", ":")),
                digest_v2,
                owner["device_id"],
                membership_v2["signature"],
                now,
            ),
        )
    return [*live_members, *revoked_members], digest_v2


def _invite_snapshot(api: ApiClient, vault_id: str, recipient: dict) -> tuple:
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        return (
            connection.execute(
                "SELECT membership_version FROM vaults WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            connection.execute(
                "SELECT COUNT(*) FROM membership_manifests WHERE vault_id=?", (vault_id,)
            ).fetchone()[0],
            connection.execute(
                "SELECT state,role FROM vault_members WHERE vault_id=? AND user_id=?",
                (vault_id, recipient["account_id"]),
            ).fetchone(),
            connection.execute(
                "SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=? AND recipient_device_id=?",
                (vault_id, recipient["device_id"]),
            ).fetchone()[0],
            connection.execute(
                "SELECT COUNT(*) FROM invitations WHERE vault_id=? AND recipient_user_id=?",
                (vault_id, recipient["account_id"]),
            ).fetchone()[0],
            connection.execute(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=? AND action='vault.invitation_created'",
                (vault_id,),
            ).fetchone()[0],
        )


def test_vault_member_limit_counts_active_and_invited_not_revoked_and_serializes(
    api: ApiClient, tmp_path: Path
) -> None:
    _assert_default_limits(api)
    owner = _register_account(api, tmp_path, "member-limit-owner")
    current_members, digest_v2 = _seed_member_limit_vault(api, owner, tmp_path)
    assert len([member for member in current_members if member["state"] == "active"]) == 99
    assert len(current_members) == 104  # 99 counted memberships plus five revoked rows.

    recipients = [
        _register_account(api, tmp_path, f"member-limit-{index}") for index in range(3)
    ]
    vault_id = owner["initial_vault"]["vault_id"]
    first_version_bodies = [
        _make_invitation_request(
            owner,
            vault_id,
            recipient,
            3,
            digest_v2,
            current_members,
        )
        for recipient in recipients[:2]
    ]
    start = threading.Barrier(2)

    def issue(recipient: dict, body: dict):
        start.wait(timeout=10)
        return api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/invitations",
            token=owner["access_token"],
            json_body=body,
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        race_responses = list(
            pool.map(
                lambda pair: issue(pair[0], pair[1][0]),
                zip(recipients[:2], first_version_bodies),
            )
        )

    accepted = [index for index, response in enumerate(race_responses) if response.status in (200, 201)]
    rejected = [index for index, response in enumerate(race_responses) if response.status not in (200, 201)]
    assert len(accepted) == 1, [
        (response.status, _error_code(response)) for response in race_responses
    ]
    assert len(rejected) == 1
    assert race_responses[rejected[0]].status == 409
    assert _error_code(race_responses[rejected[0]]) == "MEMBERSHIP_VERSION_CONFLICT"
    winner = recipients[accepted[0]]
    loser = recipients[rejected[0]]
    winning_invitation = race_responses[accepted[0]].json()

    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        state = connection.execute(
            "SELECT state FROM vault_members WHERE vault_id=? AND user_id=?",
            (vault_id, winner["account_id"]),
        ).fetchone()
        assert state == ("invited",)
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_members WHERE vault_id=? AND state IN ('active','invited')",
            (vault_id,),
        ).fetchone()[0] == VAULT_MEMBER_LIMIT
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_members WHERE vault_id=? AND user_id=?",
            (vault_id, loser["account_id"]),
        ).fetchone()[0] == 0

    # Both concurrent 101st invitations use the now-current signed version.
    # They must fail before manifest, ACL, envelope, invitation or audit writes.
    winning_membership = first_version_bodies[accepted[0]][1]
    digest_v3 = _membership_digest(vault_id, winning_membership)
    committed_members = [
        *current_members,
        _membership_member(winner["account_id"], "editor", winner["encryption_public_key"]),
    ]
    rejected_bodies = [
        _make_invitation_request(
            owner,
            vault_id,
            recipient,
            4,
            digest_v3,
            committed_members,
        )[0]
        for recipient in (loser, recipients[2])
    ]
    before = {
        recipient["account_id"]: _invite_snapshot(api, vault_id, recipient)
        for recipient in (loser, recipients[2])
    }
    start = threading.Barrier(2)
    with ThreadPoolExecutor(max_workers=2) as pool:
        full_responses = list(
            pool.map(
                lambda pair: issue(pair[0], pair[1]),
                zip((loser, recipients[2]), rejected_bodies),
            )
        )
    for response in full_responses:
        assert response.status == 409
        assert _error_code(response) == "VAULT_MEMBER_LIMIT_REACHED"
    after = {
        recipient["account_id"]: _invite_snapshot(api, vault_id, recipient)
        for recipient in (loser, recipients[2])
    }
    assert after == before
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        assert connection.execute(
            "SELECT membership_version FROM vaults WHERE vault_id=?", (vault_id,)
        ).fetchone()[0] == 3
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_members WHERE vault_id=? AND state IN ('active','invited')",
            (vault_id,),
        ).fetchone()[0] == VAULT_MEMBER_LIMIT
        assert connection.execute(
            "SELECT COUNT(*) FROM vault_members WHERE vault_id=? AND state='revoked'",
            (vault_id,),
        ).fetchone()[0] == 5
    assert winning_invitation["invitation_id"]


def _seed_user_vaults(api: ApiClient, account: dict, count: int) -> list[str]:
    now = datetime.now(timezone.utc).isoformat()
    ids: list[str] = []
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        for index in range(count):
            vault_id = str(uuid.uuid4())
            owner_id = str(uuid.uuid4())
            username = f"synthetic-vault-owner-{uuid.uuid4().hex}@example.test"
            state = "deleting" if index == 0 else "active"
            connection.execute(
                "INSERT INTO users(user_id,username,status,created_at) VALUES(?,?,'active',?)",
                (owner_id, username, now),
            )
            connection.execute(
                "INSERT INTO vaults(vault_id,owner_user_id,state,membership_version,created_at) VALUES(?,?,?,1,?)",
                (vault_id, owner_id, state, now),
            )
            connection.execute(
                "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)",
                (vault_id, owner_id, now),
            )
            connection.execute(
                "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)",
                (vault_id, account["account_id"], now),
            )
            ids.append(vault_id)
    return ids


def _accept_snapshot(api: ApiClient, invitation: dict, recipient: dict) -> tuple:
    with sqlite3.connect(_database_path(api), timeout=30) as connection:
        return (
            connection.execute(
                "SELECT state,role FROM vault_members WHERE vault_id=? AND user_id=?",
                (invitation["vault_id"], recipient["account_id"]),
            ).fetchone(),
            connection.execute(
                "SELECT accepted_at,accepted_by FROM invitations WHERE invitation_id=?",
                (invitation["invitation_id"],),
            ).fetchone(),
            connection.execute(
                "SELECT envelope,envelope_signature,signer_device_id,membership_version FROM vault_key_envelopes "
                "WHERE vault_id=? AND recipient_device_id=? ORDER BY epoch",
                (invitation["vault_id"], recipient["device_id"]),
            ).fetchall(),
            connection.execute(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=? "
                "AND action='vault.invitation_accepted' AND resource_id=?",
                (invitation["vault_id"], invitation["invitation_id"]),
            ).fetchone()[0],
        )


def test_user_vault_limit_counts_deleting_memberships_and_pending_invites_only_on_accept(
    api: ApiClient, tmp_path: Path
) -> None:
    _assert_default_limits(api)
    recipient = _register_account(api, tmp_path, "accept-limit-recipient")
    _seed_user_vaults(api, recipient, USER_VAULT_LIMIT - 2)
    assert _active_membership_count(api, recipient["account_id"]) == USER_VAULT_LIMIT - 1
    assert len(_listed_vault_ids(api, recipient)) == USER_VAULT_LIMIT - 1

    owner = _register_account(api, tmp_path, "accept-limit-owner")
    invitations = [
        _create_invitation(api, owner, recipient, f"accept-limit-{index}")
        for index in range(2)
    ]
    before_accept = _listed_vault_ids(api, recipient)
    assert len(before_accept) == USER_VAULT_LIMIT - 1
    assert all(invitation["vault_id"] not in before_accept for invitation in invitations)
    assert _active_membership_count(api, recipient["account_id"]) == USER_VAULT_LIMIT - 1

    before_rejected = {
        index: _accept_snapshot(api, invitation, recipient)
        for index, invitation in enumerate(invitations)
    }
    start = threading.Barrier(2)

    def accept(invitation: dict):
        start.wait(timeout=10)
        return _accept_invitation(api, recipient, invitation)

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(accept, invitations))

    accepted = [index for index, response in enumerate(responses) if response.status in (200, 201)]
    rejected = [index for index, response in enumerate(responses) if response.status not in (200, 201)]
    assert len(accepted) == 1, [(response.status, _error_code(response)) for response in responses]
    assert len(rejected) == 1
    rejected_index = rejected[0]
    assert responses[rejected_index].status == 409
    assert _error_code(responses[rejected_index]) == "USER_VAULT_LIMIT_REACHED"
    assert _accept_snapshot(api, invitations[rejected_index], recipient) == before_rejected[rejected_index]
    assert _active_membership_count(api, recipient["account_id"]) == USER_VAULT_LIMIT
    assert len(_listed_vault_ids(api, recipient)) == USER_VAULT_LIMIT
    assert invitations[accepted[0]]["vault_id"] in _listed_vault_ids(api, recipient)
    assert invitations[rejected_index]["vault_id"] not in _listed_vault_ids(api, recipient)
