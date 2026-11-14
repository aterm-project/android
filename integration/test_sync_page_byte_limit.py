"""Black-box bounds and cursor-prefix checks for encrypted sync pages."""

from __future__ import annotations

import urllib.parse
import uuid

from conftest import ApiClient, Response


MAX_PAGE_BYTES = 4 * 1024 * 1024
LARGE_CIPHERTEXT = b"x" * (480 * 1024)


def _error(response: Response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _collect_changes(api: ApiClient, account: dict, first: Response) -> list[dict]:
    response = first
    events: list[dict] = []
    while True:
        assert response.status == 200, f"changes page failed: {_error(response)}"
        assert len(response.body) <= MAX_PAGE_BYTES
        body = response.json()
        events.extend(body["events"])
        if not body["has_more"]:
            return events
        cursor = body["next_cursor"]
        assert cursor
        query = urllib.parse.urlencode({"cursor": cursor, "limit": "500"})
        response = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?{query}",
            token=account["access_token"],
        )


def _collect_history(
    api: ApiClient,
    account: dict,
    collection: str,
    snapshot_id: str,
) -> list[dict]:
    cursor: str | None = None
    events: list[dict] = []
    while True:
        query = {"snapshot_id": snapshot_id, "limit": "500"}
        if cursor:
            query["cursor"] = cursor
        response = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/{collection}?{urllib.parse.urlencode(query)}",
            token=account["access_token"],
        )
        assert response.status == 200, f"{collection} page failed: {_error(response)}"
        assert len(response.body) <= MAX_PAGE_BYTES
        body = response.json()
        key = "revisions" if collection == "revisions" else "conflicts"
        events.extend(body[key])
        if cursor is None:
            assert body["has_more"] is True, "large fixture must be split by the byte budget"
        if body["next_cursor"] is None:
            assert body["has_more"] is False
            return events
        assert body["has_more"] is True
        cursor = body["next_cursor"]


def _collect_conflict_feed(
    api: ApiClient,
    account: dict,
    after_seq: str,
    generation: str,
) -> list[dict]:
    events: list[dict] = []
    first_page = True
    while True:
        query = urllib.parse.urlencode(
            {"after_seq": after_seq, "limit": "500", "server_generation": generation}
        )
        response = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?{query}",
            token=account["access_token"],
        )
        assert response.status == 200, f"conflict feed page failed: {_error(response)}"
        assert len(response.body) <= MAX_PAGE_BYTES
        body = response.json()
        if first_page:
            assert body["has_more"] is True, "large fixture must be split by the byte budget"
            first_page = False
        if body["events"]:
            assert body["next_after_seq"] == body["events"][-1]["seq"]
        else:
            assert body["next_after_seq"] == after_seq
        events.extend(body["events"])
        if not body["has_more"]:
            return events
        next_after = body["next_after_seq"]
        assert int(next_after) > int(after_seq)
        after_seq = next_after


def test_sync_pages_enforce_byte_budget_and_advance_only_returned_prefix(
    api: ApiClient, account: dict, make_envelope, push
) -> None:
    """Large but valid envelopes split all four paged APIs without skipped rows."""
    vault_id = account["vault_id"]
    token = account["access_token"]

    before = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=token
    )
    assert before.status == 200, f"baseline snapshot failed: {_error(before)}"
    baseline_cursor = before.json()["next_cursor"]

    feed_before = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/conflict-changes", token=token
    )
    assert feed_before.status == 200, f"baseline conflict feed failed: {_error(feed_before)}"
    feed_start = feed_before.json()["high_watermark"]
    generation = feed_before.json()["server_generation"]

    records: list[tuple[str, str]] = []
    commit_sequences: list[str] = []
    for _ in range(7):
        record_id = str(uuid.uuid4())
        envelope = make_envelope(
            record_id=record_id,
            operation="create",
            ciphertext=LARGE_CIPHERTEXT,
        )
        created = push(envelope)
        assert created.status in (200, 201), f"large record create failed: {_error(created)}"
        revision_id = created.json()["results"][0]["revision_id"]
        commit_sequences.append(created.json()["results"][0]["commit_seq"])
        records.append((record_id, revision_id))

    first_changes_query = urllib.parse.urlencode(
        {"cursor": baseline_cursor, "limit": "500"}
    )
    first_changes = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/changes?{first_changes_query}",
        token=token,
    )
    assert first_changes.status == 200, f"large changes page failed: {_error(first_changes)}"
    assert len(first_changes.body) <= MAX_PAGE_BYTES
    assert first_changes.json()["has_more"] is True
    returned_changes = _collect_changes(api, account, first_changes)
    assert [event["commit_seq"] for event in returned_changes] == commit_sequences

    main_revisions: list[tuple[str, str, str]] = []
    for record_id, base_revision_id in records:
        update = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=base_revision_id,
        )
        changed = push(update)
        assert changed.status in (200, 201), f"record update failed: {_error(changed)}"
        main_revisions.append(
            (
                record_id,
                base_revision_id,
                changed.json()["results"][0]["revision_id"],
            )
        )
        commit_sequences.append(changed.json()["results"][0]["commit_seq"])

    conflict_ids: list[str] = []
    for record_id, original_revision, _main_revision in main_revisions:
        branch = make_envelope(
            record_id=record_id,
            operation="update",
            base_revision_id=original_revision,
            ciphertext=LARGE_CIPHERTEXT,
        )
        stored = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/conflicts",
            token=token,
            json_body={"envelope": branch},
        )
        assert stored.status in (200, 201), f"large conflict create failed: {_error(stored)}"
        conflict_ids.append(stored.json()["conflict_id"])

    history_snapshot = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=token
    )
    assert history_snapshot.status == 200, f"history snapshot failed: {_error(history_snapshot)}"
    snapshot_id = history_snapshot.json()["snapshot_id"]

    resolution_sequences: list[str] = []
    for conflict_id, (_record_id, _base_revision, main_revision) in zip(
        conflict_ids, main_revisions, strict=True
    ):
        resolved = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/conflicts/{conflict_id}/resolve",
            token=token,
            json_body={"resolved_revision_id": main_revision},
        )
        assert resolved.status == 200, f"conflict resolution failed: {_error(resolved)}"
        resolution_sequences.append(resolved.json()["resolution_seq"])

    revisions = _collect_history(api, account, "revisions", snapshot_id)
    record_ids = {record_id for record_id, _revision_id in records}
    created_revision_history = [
        item for item in revisions if item["record_id"] in record_ids
    ]
    assert [item["commit_seq"] for item in created_revision_history] == commit_sequences
    conflicts = _collect_history(api, account, "conflicts", snapshot_id)
    conflicts = [item for item in conflicts if item["record_id"] in record_ids]
    conflict_sequences = [item["conflict_seq"] for item in conflicts]
    assert [item["conflict_id"] for item in conflicts] == conflict_ids
    assert [int(item["conflict_seq"]) for item in conflicts] == sorted(
        int(item["conflict_seq"]) for item in conflicts
    )
    assert all(item["resolved_revision_id"] is None for item in conflicts)

    conflict_events = _collect_conflict_feed(
        api, account, feed_start, generation
    )
    created_events = [event for event in conflict_events if event["type"] == "created"]
    resolved_events = [event for event in conflict_events if event["type"] == "resolved"]
    assert [event["conflict_id"] for event in created_events] == conflict_ids
    assert [event["seq"] for event in created_events] == conflict_sequences
    assert [event["seq"] for event in resolved_events] == resolution_sequences
    assert [event["seq"] for event in conflict_events] == sorted(
        conflict_sequences + resolution_sequences, key=int
    )
    assert len(created_events) == len(records)
    assert len(resolved_events) == len(records)
