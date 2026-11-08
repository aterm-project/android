"""Raw query bounds for paginated sync routes, before extraction/auth."""

from __future__ import annotations

from uuid import uuid4

import pytest

from conftest import ApiClient


MAX_SYNC_QUERY_BYTES = 2112
MAX_SYNC_CURSOR_BYTES = 2048


def _pad_query_to_limit(base_query: str, limit: int) -> str:
    padding = limit - len(base_query) - len("&pad=")
    assert padding >= 0
    return f"{base_query}&pad={'x' * padding}"


@pytest.mark.parametrize(
    ("route", "base_query"),
    [
        (
            "changes",
            f"cursor={'A' * MAX_SYNC_CURSOR_BYTES}&limit=500",
        ),
        (
            "revisions",
            f"snapshot_id={uuid4()}&limit=1&cursor=",
        ),
        (
            "conflicts",
            f"snapshot_id={uuid4()}&limit=1&cursor=",
        ),
        (
            "conflict-changes",
            f"after_seq=0&server_generation={uuid4()}&limit=1",
        ),
    ],
    ids=("changes", "revisions", "conflicts", "conflict-changes"),
)
def test_sync_page_queries_accept_2112_and_reject_2113_before_auth(
    api: ApiClient, route: str, base_query: str
) -> None:
    vault_id = str(uuid4())
    exact_query = _pad_query_to_limit(base_query, MAX_SYNC_QUERY_BYTES)
    assert len(exact_query) == MAX_SYNC_QUERY_BYTES

    at_limit = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/{route}?{exact_query}"
    )
    assert at_limit.status == 401
    assert at_limit.json()["error"]["code"] == "AUTH_REQUIRED"

    oversized_query = f"{exact_query}x"
    assert len(oversized_query) == MAX_SYNC_QUERY_BYTES + 1
    over_limit = api.request(
        "GET", f"/api/v1/vaults/{vault_id}/{route}?{oversized_query}"
    )
    assert over_limit.status == 400
    assert over_limit.json()["error"]["code"] == "INVALID_CURSOR"
    assert b"x" * 256 not in over_limit.body
