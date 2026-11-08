"""Response-loss retry coverage for encrypted object upload initialization."""

from __future__ import annotations

import hashlib
import os
import uuid
from typing import Any

from conftest import ApiClient, b64url, jcs


def test_upload_init_retry_reuses_ticket_and_completed_object_can_be_referenced(
    api: ApiClient,
    account: dict[str, Any],
    make_envelope,
    push,
    changes,
) -> None:
    """A lost init response is retried, then the same ticket completes and syncs."""
    vault_id = account["vault_id"]
    token = account["access_token"]
    opaque = os.urandom(8192)
    object_id = str(uuid.uuid4())
    init_request = {
        "object_id": object_id,
        "size": len(opaque),
        "sha256": hashlib.sha256(opaque).hexdigest(),
    }
    path = f"/api/v1/vaults/{vault_id}/uploads/init"

    first = api.request("POST", path, token=token, json_body=init_request)
    assert first.status == 200, f"initial upload reservation returned HTTP {first.status}"
    first_body = first.json()
    assert isinstance(first_body, dict)

    # Simulate the first response being lost by issuing the exact same request
    # again before uploading any chunks.
    retry = api.request("POST", path, token=token, json_body=init_request)
    assert retry.status == 200, f"retried upload reservation returned HTTP {retry.status}"
    retry_body = retry.json()
    assert isinstance(retry_body, dict)
    assert retry_body["upload_id"] == first_body["upload_id"]
    assert retry_body["expires_at"] == first_body["expires_at"]
    assert retry_body["chunk_size"] == first_body["chunk_size"]

    upload_id = retry_body["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=token,
        raw_body=opaque,
        content_type="application/octet-stream",
    )
    assert chunk.status == 200, f"chunk upload after init retry returned HTTP {chunk.status}"
    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=token,
        json_body={},
    )
    assert completed.status == 200, f"completion after init retry returned HTTP {completed.status}"
    downloaded = api.request(
        "GET",
        f"/api/v1/vaults/{vault_id}/objects/{object_id}",
        token=token,
    )
    assert downloaded.status == 200 and downloaded.body == opaque

    # Establish a current pull cursor before the new commit. This remains
    # valid even if earlier suite steps pruned the default zero cursor.
    base_snapshot = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/snapshots",
        token=token,
    )
    assert base_snapshot.status == 200, f"snapshot before reference returned HTTP {base_snapshot.status}"
    base_cursor = base_snapshot.json()["next_cursor"]

    envelope = make_envelope()
    envelope["header"]["object_refs"] = [object_id]
    signed_payload = {
        "header": envelope["header"],
        "nonce": envelope["nonce"],
        "ciphertext": envelope["ciphertext"],
    }
    envelope["signature"] = b64url(account["signing_key"].sign(jcs(signed_payload)))
    committed = push(envelope)
    assert committed.status == 200, f"record reference after upload retry returned HTTP {committed.status}"
    revision_id = committed.json()["results"][0]["revision_id"]

    pulled = changes(cursor=base_cursor)
    assert pulled.status == 200, f"changes pull after upload retry returned HTTP {pulled.status}"
    event = next(item for item in pulled.json()["events"] if item["revision_id"] == revision_id)
    assert event["envelope"]["header"]["object_refs"] == [object_id]
