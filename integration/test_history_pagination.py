"""IT-23: snapshot-bound, cross-collection encrypted history reads."""

from __future__ import annotations

import sqlite3
import subprocess
import urllib.parse
import uuid
from pathlib import Path

import pytest

from conftest import ROOT, ApiClient, initial_vault, server_binary_path


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _get_history(
    api: ApiClient,
    account: dict,
    collection: str,
    snapshot_id: str,
    *,
    cursor: str | None = None,
    limit: int = 500,
    vault_id: str | None = None,
):
    query = {"snapshot_id": snapshot_id, "limit": str(limit)}
    if cursor is not None:
        query["cursor"] = cursor
    path = (
        f"/api/v1/vaults/{vault_id or account['vault_id']}/{collection}?"
        f"{urllib.parse.urlencode(query)}"
    )
    return api.request("GET", path, token=account["access_token"])


def _create_snapshot(api: ApiClient, account: dict, vault_id: str | None = None) -> dict:
    response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id or account['vault_id']}/snapshots",
        token=account["access_token"],
    )
    assert response.status in (200, 201), f"snapshot create failed: {_error_code(response)}"
    body = response.json()
    assert body.get("snapshot_id")
    assert isinstance(body.get("high_watermark"), str)
    assert isinstance(body.get("conflict_high_watermark"), str)
    return body


def _server_maintenance(api: ApiClient) -> subprocess.CompletedProcess[str]:
    assert api.admin_env, "IT-23 purge path requires its suite-owned SQLite server"
    executable = server_binary_path()
    command = (
        [str(executable), "maintenance"]
        if executable.is_file()
        else [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            "maintenance",
        ]
    )
    return subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env.copy(),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def test_history_pages_share_snapshot_boundaries_and_resolution_state(
    api: ApiClient, account: dict, make_envelope, push
) -> None:
    """A paired H/Hc keeps late revisions, branches, and resolutions out of an export."""
    vault_id = account["vault_id"]
    token = account["access_token"]
    record_a = str(uuid.uuid4())
    record_b = str(uuid.uuid4())
    late_record = str(uuid.uuid4())

    create_a = make_envelope(record_id=record_a, operation="create")
    response = push(create_a)
    assert response.status in (200, 201), f"create A failed: {_error_code(response)}"
    revision_a1 = response.json()["results"][0]["revision_id"]

    update_a = make_envelope(
        record_id=record_a, operation="update", base_revision_id=revision_a1
    )
    response = push(update_a)
    assert response.status in (200, 201), f"update A failed: {_error_code(response)}"
    revision_a2 = response.json()["results"][0]["revision_id"]

    create_b = make_envelope(record_id=record_b, operation="create")
    response = push(create_b)
    assert response.status in (200, 201), f"create B failed: {_error_code(response)}"
    revision_b1 = response.json()["results"][0]["revision_id"]

    branch_a = make_envelope(
        record_id=record_a, operation="update", base_revision_id=revision_a1
    )
    branch_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts",
        token=token,
        json_body={"envelope": branch_a},
    )
    assert branch_response.status in (200, 201), f"branch A failed: {_error_code(branch_response)}"
    branch_a_id = branch_response.json()["conflict_id"]

    snapshot = _create_snapshot(api, account)
    snapshot_id = snapshot["snapshot_id"]
    old_snapshot_response = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=token
    )
    assert old_snapshot_response.status == 200
    assert old_snapshot_response.json()["conflict_high_watermark"] == snapshot[
        "conflict_high_watermark"
    ]

    create_late = make_envelope(record_id=late_record, operation="create")
    late_response = push(create_late)
    assert late_response.status in (200, 201), f"late create failed: {_error_code(late_response)}"

    branch_b = make_envelope(
        record_id=record_b, operation="update", base_revision_id=revision_b1
    )
    late_branch_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts",
        token=token,
        json_body={"envelope": branch_b},
    )
    assert late_branch_response.status in (200, 201)
    branch_b_id = late_branch_response.json()["conflict_id"]

    resolve_path = f"/api/v1/vaults/{vault_id}/conflicts/{branch_a_id}/resolve"
    resolved = api.request(
        "POST",
        resolve_path,
        token=token,
        json_body={"resolved_revision_id": revision_a2},
    )
    assert resolved.status in (200, 201), f"resolve failed: {_error_code(resolved)}"
    resolution_seq = resolved.json()["resolution_seq"]
    assert resolved.json()["already_resolved"] is False

    # Page through the immutable history at H, with a deliberately small page.
    # The session fixture may already contain other acceptance records, so only
    # assert the records created by this case while consuming the whole cursor.
    seen_revisions: list[dict] = []
    cursor = None
    first_cursor = None
    for _ in range(500):
        page = _get_history(
            api, account, "revisions", snapshot_id, cursor=cursor, limit=1
        )
        assert page.status == 200, f"revision page failed: {_error_code(page)}"
        body = page.json()
        assert body["snapshot_id"] == snapshot_id
        assert body["high_watermark"] == snapshot["high_watermark"]
        assert body["conflict_high_watermark"] == snapshot["conflict_high_watermark"]
        assert len(body["revisions"]) <= 1
        seen_revisions.extend(body["revisions"])
        if first_cursor is None:
            first_cursor = body["next_cursor"]
        assert body["has_more"] == (body["next_cursor"] is not None)
        if not body["has_more"]:
            break
        cursor = body["next_cursor"]
    else:
        pytest.fail("revision pagination exceeded the 500-page guard")

    target_revisions = {
        revision["revision_id"]
        for revision in seen_revisions
        if revision["record_id"] in {record_a, record_b, late_record}
    }
    assert target_revisions == {revision_a1, revision_a2, revision_b1}
    assert late_record not in {revision["record_id"] for revision in seen_revisions}
    assert len({revision["revision_id"] for revision in seen_revisions}) == len(seen_revisions)

    if first_cursor:
        wrong_kind = _get_history(
            api,
            account,
            "conflicts",
            snapshot_id,
            cursor=first_cursor,
            limit=1,
        )
        assert wrong_kind.status == 400 and _error_code(wrong_kind) == "INVALID_CURSOR"

    pinned_conflicts: list[dict] = []
    cursor = None
    for _ in range(500):
        conflict_page = _get_history(
            api, account, "conflicts", snapshot_id, cursor=cursor, limit=1
        )
        assert conflict_page.status == 200, f"conflict page failed: {_error_code(conflict_page)}"
        conflict_body = conflict_page.json()
        assert conflict_body["high_watermark"] == snapshot["high_watermark"]
        assert conflict_body["conflict_high_watermark"] == snapshot["conflict_high_watermark"]
        assert len(conflict_body["conflicts"]) <= 1
        pinned_conflicts.extend(conflict_body["conflicts"])
        assert conflict_body["has_more"] == (conflict_body["next_cursor"] is not None)
        if not conflict_body["has_more"]:
            break
        cursor = conflict_body["next_cursor"]
    else:
        pytest.fail("conflict pagination exceeded the 500-page guard")
    assert len({item["conflict_id"] for item in pinned_conflicts}) == len(pinned_conflicts)
    pinned_branch = next(
        item for item in pinned_conflicts if item["conflict_id"] == branch_a_id
    )
    assert pinned_branch["envelope"] == branch_a
    assert pinned_branch["resolved_revision_id"] is None
    assert branch_b_id not in {item["conflict_id"] for item in pinned_conflicts}

    later_snapshot = _create_snapshot(api, account)
    later_conflicts: list[dict] = []
    cursor = None
    for _ in range(500):
        later_conflict_page = _get_history(
            api,
            account,
            "conflicts",
            later_snapshot["snapshot_id"],
            cursor=cursor,
            limit=1,
        )
        assert later_conflict_page.status == 200
        later_conflict_body = later_conflict_page.json()
        later_conflicts.extend(later_conflict_body["conflicts"])
        assert later_conflict_body["has_more"] == (
            later_conflict_body["next_cursor"] is not None
        )
        if not later_conflict_body["has_more"]:
            break
        cursor = later_conflict_body["next_cursor"]
    else:
        pytest.fail("later conflict pagination exceeded the 500-page guard")
    resolved_branch = next(
        item for item in later_conflicts if item["conflict_id"] == branch_a_id
    )
    assert resolved_branch["resolved_revision_id"] == revision_a2
    assert resolved_branch["resolution_seq"] == resolution_seq
    late_branch = next(
        item for item in later_conflicts if item["conflict_id"] == branch_b_id
    )
    assert late_branch["resolved_revision_id"] is None

    # Move the main head after the branch's original resolution. A retry of the
    # same binding must remain confirmable; a different binding must not win.
    newer_main = make_envelope(
        record_id=record_a, operation="update", base_revision_id=revision_a2
    )
    newer_main_response = push(newer_main)
    assert newer_main_response.status in (200, 201)
    newer_revision = newer_main_response.json()["results"][0]["revision_id"]
    retry = api.request(
        "POST",
        resolve_path,
        token=token,
        json_body={"resolved_revision_id": revision_a2},
    )
    assert retry.status == 200, f"same-resolution retry failed: {_error_code(retry)}"
    assert retry.json()["already_resolved"] is True
    assert retry.json()["resolution_seq"] == resolution_seq
    different = api.request(
        "POST",
        resolve_path,
        token=token,
        json_body={"resolved_revision_id": newer_revision},
    )
    assert different.status == 409
    assert _error_code(different) == "CONFLICT_ALREADY_RESOLVED"


def test_history_routes_validate_snapshot_scope_and_deletion_lifecycle(
    api: ApiClient, account: dict
) -> None:
    """History pages keep snapshot IDORs opaque and remain available only through grace."""
    spec = initial_vault(
        account_id=account["account_id"],
        vault_id=str(uuid.uuid4()),
        device_id=account["device_id"],
        encryption_public_key=account["encryption_public_key"],
        signer=account["signing_key"],
    )
    created = api.request(
        "POST",
        "/api/v1/vaults",
        token=account["access_token"],
        json_body={
            "vault_id": spec["vault_id"],
            "name_envelope": spec["name_envelope"],
            "key_envelope": spec["key_envelope"],
            "membership": spec["membership"],
        },
    )
    assert created.status in (200, 201), f"secondary vault create failed: {_error_code(created)}"
    other_vault_id = spec["vault_id"]
    snapshot = _create_snapshot(api, account, other_vault_id)
    snapshot_id = snapshot["snapshot_id"]

    missing = api.request(
        "GET",
        f"/api/v1/vaults/{other_vault_id}/revisions?limit=1",
        token=account["access_token"],
    )
    assert missing.status == 400 and _error_code(missing) == "INVALID_SNAPSHOT_ID"
    malformed = _get_history(api, account, "revisions", "not-a-uuid", vault_id=other_vault_id)
    assert malformed.status == 400 and _error_code(malformed) == "INVALID_SNAPSHOT_ID"
    for collection in ("revisions", "conflicts"):
        low_limit = _get_history(
            api, account, collection, snapshot_id, limit=0, vault_id=other_vault_id
        )
        high_limit = _get_history(
            api, account, collection, snapshot_id, limit=501, vault_id=other_vault_id
        )
        assert low_limit.status == high_limit.status == 400
        assert _error_code(low_limit) == _error_code(high_limit) == "INVALID_LIMIT"
        ok = _get_history(api, account, collection, snapshot_id, vault_id=other_vault_id)
        assert ok.status == 200, f"empty {collection} page failed: {_error_code(ok)}"
        assert ok.json()[collection] == [] and ok.json()["has_more"] is False

    # A real snapshot from another accessible vault is still foreign to this
    # route's vault scope, and must look like an unavailable snapshot.
    foreign = _get_history(api, account, "revisions", snapshot_id)
    assert foreign.status == 404

    if api.admin_env:
        database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
        assert database_url.startswith("sqlite://")
        database_path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
        with sqlite3.connect(database_path) as database:
            database.execute(
                "UPDATE snapshots SET conflict_high_watermark=NULL WHERE snapshot_id=?",
                (snapshot_id,),
            )
            database.commit()
        legacy = api.request(
            "GET", f"/api/v1/snapshots/{snapshot_id}", token=account["access_token"]
        )
        assert legacy.status == 200 and legacy.json()["conflict_high_watermark"] is None
        for collection in ("revisions", "conflicts"):
            incomplete = _get_history(
                api, account, collection, snapshot_id, vault_id=other_vault_id
            )
            assert incomplete.status == 409
            assert _error_code(incomplete) == "HISTORY_SNAPSHOT_INCOMPLETE"
            details = (incomplete.json().get("error") or {}).get("details") or {}
            assert details.get("recovery") == "create_new_snapshot"

    # Use a fresh paired snapshot for the deletion-grace read check.
    snapshot = _create_snapshot(api, account, other_vault_id)
    snapshot_id = snapshot["snapshot_id"]
    if api.admin_env:
        # This suite shares one disposable server across modules. Earlier tests
        # may already have consumed the account's finite Login step-up window;
        # reset only this ephemeral server's Login counters so this case checks
        # deletion-grace semantics rather than module ordering.
        database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
        assert database_url.startswith("sqlite://")
        database_path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
        with sqlite3.connect(database_path) as database:
            database.execute("DELETE FROM auth_rate_limits WHERE endpoint='login'")
            database.commit()
    deleting = api.request(
        "DELETE",
        f"/api/v1/vaults/{other_vault_id}",
        token=account["access_token"],
        json_body={"login_verifier": account["login_verifier"]},
    )
    assert deleting.status in (200, 202) and deleting.json()["status"] == "deleting"
    for collection in ("revisions", "conflicts"):
        during_grace = _get_history(
            api, account, collection, snapshot_id, vault_id=other_vault_id
        )
        assert during_grace.status == 200, f"grace read failed: {_error_code(during_grace)}"

    if not api.admin_env:
        return
    database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
    assert database_url.startswith("sqlite://")
    database_path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
    with sqlite3.connect(database_path) as database:
        updated = database.execute(
            "UPDATE vault_deletion_requests "
            "SET requested_at=CAST(strftime('%s','now') AS INTEGER)-400*86400, "
            "purge_after=CAST(strftime('%s','now') AS INTEGER)-1 "
            "WHERE vault_id=? AND purged_at IS NULL AND cancelled_at IS NULL",
            (other_vault_id,),
        )
        assert updated.rowcount == 1
        database.commit()
    maintenance = _server_maintenance(api)
    assert maintenance.returncode == 0, maintenance.stdout + maintenance.stderr
    for collection in ("revisions", "conflicts"):
        purged = _get_history(api, account, collection, snapshot_id, vault_id=other_vault_id)
        assert purged.status == 404
