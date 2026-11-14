"""Black-box checks for bounded, single-range encrypted object downloads."""

from __future__ import annotations

import hashlib
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from conftest import ApiClient, Response
from test_account_deletion import _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _download(
    api: ApiClient,
    vault_id: str,
    object_id: str,
    token: str,
    **extra_headers: str,
) -> Response:
    headers = {"Accept": "application/octet-stream", "Authorization": f"Bearer {token}"}
    headers.update(extra_headers)
    request = urllib.request.Request(
        f"{api.base_url}/api/v1/vaults/{vault_id}/objects/{object_id}",
        headers=headers,
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return Response(response.status, response.headers, response.read())
    except urllib.error.HTTPError as response:
        return Response(response.code, response.headers, response.read())


def _upload(api: ApiClient, vault_id: str, token: str, content: bytes) -> str:
    object_id = str(uuid.uuid4())
    initialized = api.request(
        "POST",
        f"/api/v1/vaults/{vault_id}/uploads/init",
        token=token,
        json_body={
            "object_id": object_id,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    )
    if initialized.status not in (200, 201):
        raise AssertionError(
            f"object upload init failed: HTTP {initialized.status} {_error_code(initialized)}"
        )
    upload_id = initialized.json()["upload_id"]
    chunk = api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=token,
        raw_body=content,
        content_type="application/octet-stream",
    )
    if chunk.status not in (200, 201):
        raise AssertionError(
            f"object chunk upload failed: HTTP {chunk.status} {_error_code(chunk)}"
        )
    completed = api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=token,
        json_body={},
    )
    if completed.status not in (200, 201):
        raise AssertionError(
            f"object completion failed: HTTP {completed.status} {_error_code(completed)}"
        )
    return object_id


def _assert_body(response: Response, expected: bytes, message: str) -> None:
    if response.body != expected:
        raise AssertionError(message)


def test_object_download_single_byte_ranges_and_acl(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    """Range reads preserve bytes/validators and do not bypass vault ACLs."""
    content = bytes((index * 37) % 256 for index in range(257))
    object_id = _upload(api, account["vault_id"], account["access_token"], content)
    etag = f'"sha256-{hashlib.sha256(content).hexdigest()}"'
    total = len(content)

    full = _download(api, account["vault_id"], object_id, account["access_token"])
    if full.status != 200:
        raise AssertionError(f"unranged download returned HTTP {full.status}")
    if full.headers.get("Content-Type") != "application/octet-stream":
        raise AssertionError("unranged download did not preserve the opaque content type")
    if full.headers.get("Accept-Ranges") != "bytes":
        raise AssertionError("download omitted byte-range support")
    if full.headers.get("ETag") != etag:
        raise AssertionError("unranged download changed the object ETag")
    if full.headers.get("Content-Length") != str(total):
        raise AssertionError("unranged download reported the wrong content length")
    _assert_body(full, content, "unranged download did not preserve the opaque bytes")

    ranges = (
        ("bytes=2-9", 2, 9),
        ("bytes=10-", 10, total - 1),
        ("bytes=-7", total - 7, total - 1),
        ("bytes=250-999", 250, total - 1),
    )
    for value, start, end in ranges:
        response = _download(
            api,
            account["vault_id"],
            object_id,
            account["access_token"],
            Range=value,
        )
        if response.status != 206:
            raise AssertionError(f"valid range returned HTTP {response.status}")
        if response.headers.get("Content-Range") != f"bytes {start}-{end}/{total}":
            raise AssertionError("partial response returned an invalid Content-Range")
        if response.headers.get("Content-Length") != str(end - start + 1):
            raise AssertionError("partial response returned an invalid Content-Length")
        if response.headers.get("Accept-Ranges") != "bytes" or response.headers.get("ETag") != etag:
            raise AssertionError("partial response changed range support or ETag")
        _assert_body(
            response,
            content[start : end + 1],
            "partial response did not preserve the requested bytes",
        )

    for value in ("bytes=257-", "bytes=8-4", "bytes=-0", "bytes=0-1,4-5"):
        response = _download(
            api,
            account["vault_id"],
            object_id,
            account["access_token"],
            Range=value,
        )
        if response.status != 416:
            raise AssertionError("invalid or unsupported range did not return HTTP 416")
        if response.headers.get("Content-Range") != f"bytes */{total}":
            raise AssertionError("416 response omitted the standard unsatisfied Content-Range")
        if response.headers.get("Content-Length") != "0" or response.body:
            raise AssertionError("416 response unexpectedly contained a body")
        if response.headers.get("ETag") != etag:
            raise AssertionError("416 response did not preserve the object validator")

    unknown_unit = _download(
        api,
        account["vault_id"],
        object_id,
        account["access_token"],
        Range="items=0-1",
    )
    if unknown_unit.status != 200:
        raise AssertionError("unknown Range unit was not ignored")
    _assert_body(unknown_unit, content, "unknown Range unit did not return the full object")

    matching_if_range = _download(
        api,
        account["vault_id"],
        object_id,
        account["access_token"],
        Range="bytes=3-5",
        **{"If-Range": etag},
    )
    if matching_if_range.status != 206:
        raise AssertionError("matching If-Range validator was not honored")
    _assert_body(
        matching_if_range,
        content[3:6],
        "matching If-Range returned unexpected bytes",
    )

    for stale_if_range in ('"sha256-stale"', f'W/{etag}', "Sun, 06 Nov 1994 08:49:37 GMT"):
        stale = _download(
            api,
            account["vault_id"],
            object_id,
            account["access_token"],
            Range="bytes=3-5",
            **{"If-Range": stale_if_range},
        )
        if stale.status != 200:
            raise AssertionError(
                "stale or unsupported If-Range did not fall back to the full response"
            )
        _assert_body(stale, content, "stale If-Range did not return the full current object")

    outsider = _register_account(
        api,
        f"object-range-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "object-range-outsider",
    )
    denied = _download(
        api,
        account["vault_id"],
        object_id,
        outsider["access_token"],
        Range="bytes=0-0",
    )
    if denied.status != 404 or _error_code(denied) != "NOT_FOUND":
        raise AssertionError("foreign vault range request bypassed generic object authorization")
    if denied.headers.get("Content-Range") is not None or denied.headers.get("ETag") is not None:
        raise AssertionError("foreign vault range request disclosed object metadata")
