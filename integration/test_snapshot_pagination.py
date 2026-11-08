"""Black-box contract for paged reads of snapshots larger than 4 MiB."""

from __future__ import annotations

import urllib.parse
import uuid

from conftest import ApiClient, Response


MAX_SNAPSHOT_RESPONSE_BYTES = 4 * 1024 * 1024
LARGE_CIPHERTEXT = b"x" * (600 * 1024)
SNAPSHOT_PAGE_LIMIT = 2


def _error_code(response: Response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _snapshot_page(
    api: ApiClient,
    snapshot_id: str,
    token: str,
    *,
    page_cursor: str | None,
) -> Response:
    query = {"limit": str(SNAPSHOT_PAGE_LIMIT)}
    if page_cursor is not None:
        query["page_cursor"] = page_cursor
    return api.request(
        "GET",
        f"/api/v1/snapshots/{snapshot_id}?{urllib.parse.urlencode(query)}",
        token=token,
    )


def test_large_snapshot_pages_are_bounded_stable_and_immutable(
    api: ApiClient, account: dict, make_envelope, push
) -> None:
    """A 4 MiB+ manifest can be bootstrapped in bounded, authenticated pages."""
    vault_id = account["vault_id"]
    token = account["access_token"]

    original_revisions: dict[str, str] = {}
    # Each envelope is independently signed and pushed so each commit is a
    # valid Host/record head. Base64 expansion makes this manifest exceed 4 MiB.
    for _ in range(7):
        record_id = str(uuid.uuid4())
        envelope = make_envelope(
            record_id=record_id,
            operation="create",
            ciphertext=LARGE_CIPHERTEXT,
        )
        created = push(envelope)
        assert created.status in (200, 201), (
            f"large snapshot fixture record create failed: HTTP {created.status} "
            f"{_error_code(created)}"
        )
        original_revisions[record_id] = created.json()["results"][0]["revision_id"]

    requested = api.request(
        "POST", f"/api/v1/vaults/{vault_id}/snapshots", token=token
    )
    assert requested.status in (200, 201), (
        f"large snapshot creation failed: HTTP {requested.status} {_error_code(requested)}"
    )
    snapshot_meta = requested.json()
    snapshot_id = snapshot_meta.get("snapshot_id")
    assert snapshot_id, "snapshot creation response omitted snapshot_id"

    # Preserve a later head change to prove every paged item is pinned at the
    # snapshot's original high watermark.
    updated_record_id = next(iter(original_revisions))
    update = make_envelope(
        record_id=updated_record_id,
        operation="update",
        base_revision_id=original_revisions[updated_record_id],
    )
    changed = push(update)
    assert changed.status in (200, 201), (
        f"post-snapshot record update failed: HTTP {changed.status} {_error_code(changed)}"
    )
    later_revision = changed.json()["results"][0]["revision_id"]
    assert later_revision != original_revisions[updated_record_id]

    # The compatibility full-manifest form remains explicitly bounded. If its
    # behavior changes, update the API contract and this expectation together.
    legacy = api.request(
        "GET", f"/api/v1/snapshots/{snapshot_id}", token=token
    )
    assert legacy.status == 413, (
        f"oversized legacy snapshot read must return HTTP 413; got "
        f"HTTP {legacy.status} {_error_code(legacy)}"
    )
    legacy_error = legacy.json()["error"]
    assert legacy_error["code"] == "PAYLOAD_TOO_LARGE"
    assert legacy_error["details"]["max_response_bytes"] == MAX_SNAPSHOT_RESPONSE_BYTES

    expected_metadata = {
        key: snapshot_meta[key]
        for key in (
            "snapshot_id",
            "high_watermark",
            "conflict_high_watermark",
            "next_cursor",
            "expires_at",
        )
    }
    seen_record_ids: list[str] = []
    seen_page_cursors: set[str] = set()
    requested_cursors: set[str] = set()
    previous_record_id: str | None = None
    page_cursor: str | None = None

    for page_number in range(len(original_revisions) + 1):
        page = _snapshot_page(
            api, snapshot_id, token, page_cursor=page_cursor
        )
        assert page.status == 200, (
            f"snapshot page {page_number} failed: HTTP {page.status} {_error_code(page)}"
        )
        assert len(page.body) <= MAX_SNAPSHOT_RESPONSE_BYTES, (
            f"snapshot page {page_number} exceeded the 4 MiB serialized response limit"
        )
        body = page.json()
        assert isinstance(body, dict), f"snapshot page {page_number} was not a JSON object"
        assert {key: body.get(key) for key in expected_metadata} == expected_metadata, (
            f"snapshot page {page_number} changed pinned snapshot metadata"
        )
        manifest = body.get("manifest")
        assert isinstance(manifest, list), f"snapshot page {page_number} omitted manifest"
        assert len(manifest) <= SNAPSHOT_PAGE_LIMIT, (
            f"snapshot page {page_number} exceeded its requested item limit"
        )

        for item in manifest:
            record_id = item.get("record_id")
            assert record_id in original_revisions, "snapshot page returned an unexpected record ID"
            assert previous_record_id is None or record_id > previous_record_id, (
                "snapshot pages did not advance in strict record ID order"
            )
            previous_record_id = record_id
            assert item.get("revision_id") == original_revisions[record_id], (
                "snapshot page moved a record past its fixed high watermark"
            )
            seen_record_ids.append(record_id)

        next_page_cursor = body.get("next_page_cursor")
        has_more = body.get("has_more")
        assert isinstance(has_more, bool), f"snapshot page {page_number} omitted has_more"
        assert has_more == (next_page_cursor is not None), (
            f"snapshot page {page_number} has_more disagreed with its continuation cursor"
        )

        if page_number == 0:
            assert has_more and next_page_cursor, "large snapshot was not split into multiple pages"
            # Repeating the same request must return the same page boundary and
            # continuation token, so a retry after a lost response is safe.
            repeated = _snapshot_page(api, snapshot_id, token, page_cursor=None)
            assert repeated.status == 200, (
                f"repeated first snapshot page failed: HTTP {repeated.status} "
                f"{_error_code(repeated)}"
            )
            assert len(repeated.body) <= MAX_SNAPSHOT_RESPONSE_BYTES
            repeated_body = repeated.json()
            assert repeated_body.get("next_page_cursor") == next_page_cursor, (
                "repeating a snapshot page changed its continuation cursor"
            )
            assert [item.get("record_id") for item in repeated_body.get("manifest", [])] == [
                item.get("record_id") for item in manifest
            ], "repeating a snapshot page changed its record prefix"

            # Any changed byte in the opaque page token must fail closed.
            tampered_cursor = next_page_cursor[:-1] + (
                "A" if next_page_cursor[-1] != "A" else "B"
            )
            tampered = _snapshot_page(
                api, snapshot_id, token, page_cursor=tampered_cursor
            )
            assert tampered.status == 400 and _error_code(tampered) == "INVALID_CURSOR", (
                f"tampered snapshot page cursor was not rejected: HTTP {tampered.status} "
                f"{_error_code(tampered)}"
            )

        if next_page_cursor is None:
            assert has_more is False
            break

        assert next_page_cursor not in seen_page_cursors, "snapshot page cursor repeated"
        assert next_page_cursor != page_cursor, "snapshot page cursor did not advance"
        assert next_page_cursor not in requested_cursors, "snapshot page cursor looped backward"
        seen_page_cursors.add(next_page_cursor)
        if page_cursor is not None:
            requested_cursors.add(page_cursor)
        page_cursor = next_page_cursor
    else:
        raise AssertionError("snapshot pagination exceeded its record-count guard")

    assert sorted(seen_record_ids) == sorted(original_revisions), (
        "paginated snapshot did not return every record ID exactly once"
    )
