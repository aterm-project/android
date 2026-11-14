"""Black-box coverage for incremental conflict creation/resolution events."""

from __future__ import annotations

import datetime as dt
import sqlite3
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

from conftest import ApiClient
from test_account_deletion import _db_path, _enroll_device, _login


def _error(response) -> dict:
    body = response.json() or {}
    return body.get("error") or {}


def _feed(api: ApiClient, account: dict, **query):
    path = f"/api/v1/vaults/{account['vault_id']}/conflict-changes"
    if query:
        path += "?" + urllib.parse.urlencode(query)
    return api.request("GET", path, token=account["access_token"])


def _audit_events(api: ApiClient, token: str) -> list[dict]:
    events: list[dict] = []
    cursor: str | None = None
    seen: set[str] = set()
    while True:
        query = {"limit": "200"}
        if cursor is not None:
            query["cursor"] = cursor
        response = api.request(
            "GET", "/api/v1/audit?" + urllib.parse.urlencode(query), token=token
        )
        assert response.status == 200, f"audit request failed: {_error(response)}"
        body = response.json()
        events.extend(body["events"])
        cursor = body.get("next_cursor")
        if cursor is None:
            return events
        assert cursor not in seen, "audit cursor repeated"
        seen.add(cursor)


def _conflict_resolution_audit_events(api: ApiClient, account: dict, conflict_id: str) -> list[dict]:
    return [
        event
        for event in _audit_events(api, account["access_token"])
        if event["action"] == "vault.conflict_resolved"
        and event["resource_type"] == "conflict"
        and event["resource_id"] == conflict_id
    ]


def test_conflict_changes_feed_pages_creation_and_resolution_events(
    api: ApiClient,
    account: dict,
    make_envelope,
    push,
    writable_server: None,
    tmp_path: Path,
) -> None:
    vault_id = account["vault_id"]
    token = account["access_token"]
    live_instance = api.request("GET", "/api/v1/instance")
    assert live_instance.status == 200, "instance lookup before conflict feed failed"
    generation = live_instance.json()["generation"]

    # The current watermark gives the case an independent checkpoint even when
    # other session-scoped acceptance cases already created conflict events.
    baseline = _feed(api, account, limit="1")
    assert baseline.status == 200, f"baseline failed: {_error(baseline)}"
    baseline_body = baseline.json()
    start_after = baseline_body["high_watermark"]
    assert isinstance(start_after, str) and start_after.isdecimal()
    assert baseline_body["server_generation"] == generation
    assert baseline_body["after_seq"] == "0"

    empty = _feed(
        api,
        account,
        after_seq=start_after,
        server_generation=generation,
    )
    assert empty.status == 200, f"empty continuation failed: {_error(empty)}"
    assert empty.json()["events"] == []
    assert empty.json()["after_seq"] == start_after
    assert empty.json()["next_after_seq"] == start_after
    assert empty.json()["has_more"] is False

    record_a = str(uuid.uuid4())
    record_b = str(uuid.uuid4())
    main_revisions: dict[str, tuple[str, str]] = {}
    for record_id in (record_a, record_b):
        create = make_envelope(record_id=record_id, operation="create")
        created = push(create)
        assert created.status in (200, 201), f"record create failed: {_error(created)}"
        revision_one = created.json()["results"][0]["revision_id"]
        update = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=revision_one,
        )
        updated = push(update)
        assert updated.status in (200, 201), f"main update failed: {_error(updated)}"
        revision_two = updated.json()["results"][0]["revision_id"]
        main_revisions[record_id] = (revision_one, revision_two)

    branches = []
    for record_id in (record_a, record_b):
        branch = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=main_revisions[record_id][0],
        )
        stored = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/conflicts",
            token=token,
            json_body={"envelope": branch},
        )
        assert stored.status in (200, 201), f"conflict create failed: {_error(stored)}"
        branches.append((branch, stored.json()["conflict_id"], record_id))

    first = _feed(
        api,
        account,
        after_seq=start_after,
        limit="1",
        server_generation=generation,
    )
    assert first.status == 200, f"first event page failed: {_error(first)}"
    first_body = first.json()
    first_event = first_body["events"][0]
    assert first_body["after_seq"] == start_after
    assert int(first_body["high_watermark"]) >= int(first_event["seq"])
    assert first_body["has_more"] is True
    assert first_body["next_after_seq"] == first_event["seq"]
    assert first_event["type"] == "created"
    assert first_event["conflict_id"] == branches[0][1]
    assert first_event["record_id"] == record_a
    assert first_event["base_revision_id"] == main_revisions[record_a][0]
    assert first_event["resolved_revision_id"] is None
    assert first_event["envelope"] == branches[0][0]
    assert isinstance(first_event["created_at"], str)
    assert all(isinstance(first_event[key], str) for key in ("seq",))

    second = _feed(
        api,
        account,
        after_seq=first_body["next_after_seq"],
        limit="1",
        server_generation=generation,
    )
    assert second.status == 200, f"second event page failed: {_error(second)}"
    second_body = second.json()
    second_event = second_body["events"][0]
    assert second_body["has_more"] is False
    assert second_body["next_after_seq"] == second_event["seq"]
    assert second_event["type"] == "created"
    assert second_event["conflict_id"] == branches[1][1]
    assert second_event["envelope"] == branches[1][0]
    assert int(second_event["seq"]) > int(first_event["seq"])

    unauthenticated_resolution = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
        json_body={"resolved_revision_id": main_revisions[record_a][1]},
    )
    assert unauthenticated_resolution.status == 401
    assert _conflict_resolution_audit_events(api, account, branches[0][1]) == []

    stale_resolution = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
        token=token,
        json_body={"resolved_revision_id": main_revisions[record_a][0]},
    )
    assert stale_resolution.status == 409, (
        f"stale conflict resolution returned {stale_resolution.status}: {_error(stale_resolution)}"
    )
    assert _conflict_resolution_audit_events(api, account, branches[0][1]) == []

    database_path: Path | None = None
    if api.admin_env:
        database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
        assert database_url.startswith("sqlite://")
        database_path = Path(
            urllib.parse.unquote(database_url[len("sqlite://") :].split("?", 1)[0])
        )
        with sqlite3.connect(database_path, timeout=5) as database:
            conflict_seq_before_audit_failure = database.execute(
                "SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?",
                (vault_id,),
            ).fetchone()[0]
            database.execute(
                "CREATE TRIGGER reject_conflict_resolution_audit "
                "BEFORE INSERT ON audit_events "
                "WHEN NEW.action='vault.conflict_resolved' "
                "BEGIN SELECT RAISE(ABORT,'synthetic audit failure'); END"
            )
            database.commit()
        try:
            audit_failure = api.request(
                "POST",
                f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
                token=token,
                json_body={"resolved_revision_id": main_revisions[record_a][1]},
            )
        finally:
            with sqlite3.connect(database_path, timeout=5) as database:
                database.execute("DROP TRIGGER IF EXISTS reject_conflict_resolution_audit")
                database.commit()
        assert audit_failure.status == 500 and _error(audit_failure).get("code") == "INTERNAL"
        assert b"synthetic audit failure" not in audit_failure.body
        with sqlite3.connect(database_path, timeout=5) as database:
            failed_resolution_state = database.execute(
                "SELECT resolved_revision_id,resolution_seq,resolution_at "
                "FROM conflicts WHERE conflict_id=?",
                (branches[0][1],),
            ).fetchone()
            conflict_seq_after_audit_failure = database.execute(
                "SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?",
                (vault_id,),
            ).fetchone()[0]
        assert failed_resolution_state == (None, None, None), (
            "audit insertion failure must roll back the conflict resolution"
        )
        assert conflict_seq_after_audit_failure == conflict_seq_before_audit_failure, (
            "audit insertion failure must not consume a conflict sequence"
        )
        assert _conflict_resolution_audit_events(api, account, branches[0][1]) == []

    resolved_response = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
        token=token,
        json_body={"resolved_revision_id": main_revisions[record_a][1]},
    )
    assert resolved_response.status in (200, 201), (
        f"conflict resolution failed: {_error(resolved_response)}"
    )
    resolution_seq = resolved_response.json()["resolution_seq"]
    assert resolved_response.json()["already_resolved"] is False

    resolution_page = _feed(
        api,
        account,
        after_seq=second_event["seq"],
        limit="1",
        server_generation=generation,
    )
    assert resolution_page.status == 200, f"resolution event failed: {_error(resolution_page)}"
    resolution_body = resolution_page.json()
    resolution_event = resolution_body["events"][0]
    assert resolution_body["has_more"] is False
    assert resolution_event["type"] == "resolved"
    assert resolution_event["seq"] == resolution_seq
    assert resolution_event["conflict_id"] == branches[0][1]
    assert resolution_event["record_id"] == record_a
    assert resolution_event["base_revision_id"] == main_revisions[record_a][0]
    assert resolution_event["resolved_revision_id"] == main_revisions[record_a][1]
    assert "envelope" not in resolution_event
    created_at = dt.datetime.fromisoformat(first_event["created_at"])
    resolved_at = dt.datetime.fromisoformat(resolution_event["created_at"])
    assert resolved_at >= created_at
    resolution_audit_events = _conflict_resolution_audit_events(api, account, branches[0][1])
    assert len(resolution_audit_events) == 1, "one successful resolution must create one audit event"
    resolution_audit_event = resolution_audit_events[0]
    assert resolution_audit_event["event_id"].isdecimal()
    assert resolution_audit_event == {
        "event_id": resolution_audit_event["event_id"],
        "scope": "vault",
        "vault_id": vault_id,
        "actor_user_id": account["account_id"],
        "actor_device_id": account["device_id"],
        "action": "vault.conflict_resolved",
        "resource_type": "conflict",
        "resource_id": branches[0][1],
        "result": "success",
        "occurred_at": resolution_audit_event["occurred_at"],
        "source": "api",
    }
    assert set(resolution_audit_event) == {
        "event_id", "scope", "vault_id", "actor_user_id", "actor_device_id", "action",
        "resource_type", "resource_id", "result", "occurred_at", "source",
    }, "conflict audit rows must not include record contents or arbitrary details"

    # Enroll and authenticate a second Owner device only after the real event
    # has been written. Its independent session must read the exact same safe
    # audit row as the device that resolved the conflict.
    sibling_device = _enroll_device(api, account, tmp_path, "conflict-audit-sibling")
    assert sibling_device["device_id"] != account["device_id"]
    if api.admin_env:
        with sqlite3.connect(_db_path(api)) as database:
            database.execute("DELETE FROM auth_rate_limits WHERE endpoint='login'")
            database.commit()
    sibling_session = _login(api, account, sibling_device["device_id"])
    sibling_resolution_audit_events = [
        event
        for event in _audit_events(api, sibling_session["access_token"])
        if event["action"] == "vault.conflict_resolved"
        and event["resource_type"] == "conflict"
        and event["resource_id"] == branches[0][1]
    ]
    assert sibling_resolution_audit_events == [resolution_audit_event], (
        "a separately approved Owner device must read the same single safe conflict audit row"
    )
    if api.admin_env:
        database_url = api.admin_env.get("ATERMIUS_DATABASE_URL", "")
        assert database_url.startswith("sqlite://")
        database_path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
        with sqlite3.connect(database_path, timeout=5) as database:
            stored_resolution_at = database.execute(
                "SELECT resolution_at FROM conflicts WHERE conflict_id=?",
                (branches[0][1],),
            ).fetchone()
        assert stored_resolution_at is not None
        assert resolution_event["created_at"] == stored_resolution_at[0]

    # Move the main head after resolution. An identical retry must still
    # return the original sequence before checking the now-advanced head.
    advance_head = make_envelope(
        record_id=record_a,
        operation="update",
        base_revision_id=main_revisions[record_a][1],
    )
    advanced = push(advance_head)
    assert advanced.status in (200, 201), f"post-resolution head update failed: {_error(advanced)}"

    retry = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
        token=token,
        json_body={"resolved_revision_id": main_revisions[record_a][1]},
    )
    assert retry.status == 200 and retry.json()["already_resolved"] is True
    assert retry.json()["resolution_seq"] == resolution_seq
    assert len(_conflict_resolution_audit_events(api, account, branches[0][1])) == 1, (
        "an idempotent resolution retry must not duplicate the audit event"
    )
    different_retry = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/conflicts/{branches[0][1]}/resolve",
        token=token,
        json_body={"resolved_revision_id": main_revisions[record_a][0]},
    )
    assert different_retry.status == 409
    assert len(_conflict_resolution_audit_events(api, account, branches[0][1])) == 1
    no_duplicate = _feed(
        api,
        account,
        after_seq=resolution_seq,
        server_generation=generation,
    )
    assert no_duplicate.status == 200
    assert no_duplicate.json()["events"] == []
    assert no_duplicate.json()["high_watermark"] == resolution_seq

    # Concurrent requests for the same conflict/revision serialize behind the
    # Vault writer lock: both callers can confirm the committed resolution,
    # while only the first transaction emits an audit event.
    concurrent_conflict_id = branches[1][1]
    barrier = Barrier(3)

    def resolve_concurrently():
        barrier.wait(timeout=15)
        return api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/conflicts/{concurrent_conflict_id}/resolve",
            token=token,
            json_body={"resolved_revision_id": main_revisions[record_b][1]},
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(resolve_concurrently) for _ in range(2)]
        barrier.wait(timeout=15)
        concurrent_responses = [future.result(timeout=30) for future in futures]
    assert [response.status for response in concurrent_responses] == [200, 200], [
        _error(response) for response in concurrent_responses
    ]
    concurrent_bodies = [response.json() for response in concurrent_responses]
    assert sorted(body["already_resolved"] for body in concurrent_bodies) == [False, True]
    concurrent_sequences = {body["resolution_seq"] for body in concurrent_bodies}
    assert len(concurrent_sequences) == 1
    concurrent_resolution_seq = concurrent_sequences.pop()
    assert int(concurrent_resolution_seq) > int(resolution_seq)
    concurrent_audit_events = _conflict_resolution_audit_events(
        api, account, concurrent_conflict_id
    )
    assert len(concurrent_audit_events) == 1, (
        "concurrent same-revision resolutions must create one audit event"
    )
    assert concurrent_audit_events[0]["actor_user_id"] == account["account_id"]
    assert concurrent_audit_events[0]["actor_device_id"] == account["device_id"]
    concurrent_feed = _feed(
        api,
        account,
        after_seq=resolution_seq,
        server_generation=generation,
    )
    assert concurrent_feed.status == 200
    concurrent_feed_events = concurrent_feed.json()["events"]
    assert len(concurrent_feed_events) == 1
    concurrent_feed_event = concurrent_feed_events[0]
    assert concurrent_feed_event["type"] == "resolved"
    assert concurrent_feed_event["seq"] == concurrent_resolution_seq
    assert concurrent_feed_event["conflict_id"] == concurrent_conflict_id
    assert concurrent_feed_event["record_id"] == record_b
    assert concurrent_feed_event["base_revision_id"] == main_revisions[record_b][0]
    assert concurrent_feed_event["resolved_revision_id"] == main_revisions[record_b][1]
    assert "envelope" not in concurrent_feed_event

    stale_generation = str(uuid.uuid4())
    generation_changed = _feed(
        api,
        account,
        after_seq=concurrent_resolution_seq,
        server_generation=stale_generation,
    )
    assert generation_changed.status == 410
    assert _error(generation_changed).get("code") == "CONFLICT_FEED_GENERATION_CHANGED"
    details = _error(generation_changed).get("details") or {}
    assert details == {
        "server_generation": stale_generation,
        "current_generation": generation,
        "recovery": "restart_from_zero",
    }

    sequence_ahead = _feed(
        api,
        account,
        after_seq=str(int(concurrent_resolution_seq) + 1),
        server_generation=generation,
    )
    assert sequence_ahead.status == 410
    assert _error(sequence_ahead).get("code") == "CONFLICT_FEED_SEQUENCE_AHEAD"
    assert (_error(sequence_ahead).get("details") or {}).get("recovery") == "restart_from_zero"

    missing_checkpoint_generation = _feed(api, account, after_seq="1")
    assert missing_checkpoint_generation.status == 400
    assert _error(missing_checkpoint_generation).get("code") == "SERVER_GENERATION_REQUIRED"
    zero_checkpoint_without_generation = _feed(api, account, after_seq="0")
    assert zero_checkpoint_without_generation.status == 400
    assert _error(zero_checkpoint_without_generation).get("code") == "SERVER_GENERATION_REQUIRED"

    malformed = _feed(api, account, after_seq="01")
    assert malformed.status == 400 and _error(malformed).get("code") == "INVALID_AFTER_SEQ"
    for invalid_limit in ("0", "501"):
        response = _feed(api, account, limit=invalid_limit)
        assert response.status == 400 and _error(response).get("code") == "INVALID_LIMIT"

    invalid_generation = _feed(api, account, server_generation="not-a-uuid")
    assert invalid_generation.status == 400
    assert _error(invalid_generation).get("code") == "INVALID_SERVER_GENERATION"

    unauthenticated = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/conflict-changes"
    )
    assert unauthenticated.status == 401
    foreign = api.request(
        "GET",
        f"/api/v1/vaults/{uuid.uuid4()}/conflict-changes",
        token=token,
    )
    assert foreign.status == 404
