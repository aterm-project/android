"""Black-box acceptance for the S3 backend used by opaque Vault attachments.

The tests start a private Atermius process and the same strict-loopback fake
used by the Web Host Attachments runner. No cloud account, endpoint, or
credential from the invoking shell is used.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url, redact_secrets
from object_store_s3_client import LoopbackS3Process
from test_backup_cli import (
    _run_cli,
    _server_binary,
    _start_server,
    _stop_server,
)
from test_object_range import _download, _error_code
from test_acceptance import _new_account_registration
from test_object_references import (
    _db,
    _maintenance,
    _new_owner,
    _operation,
    _push,
    _scalar,
)


BUCKET = "atermius-opaque-fixture"
PREFIX = "integration-object-test"
BACKUP_ADMIN = "atermius-s3-integration-admin@example.test"


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _private_env(
    data_dir: Path, port: int, *, operator_dir: Path | None = None
) -> dict[str, str]:
    """Construct an environment without inherited Atermius/AWS provider state."""
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("ATERMIUS_", "AWS_", "AMAZON_"))
    }
    base_url = f"http://127.0.0.1:{port}"
    data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == "posix":
        os.chmod(data_dir, 0o700)
    operator_dir = operator_dir or data_dir.parent
    operator_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_dir = operator_dir / "backup-archives"
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == "posix":
        os.chmod(backup_dir, 0o700)
    backup_key_file = operator_dir / "operator-backup.key"
    backup_key_file.write_bytes(os.urandom(32))
    mfa_key_file = operator_dir / "operator-mfa.key"
    mfa_key_file.write_bytes(os.urandom(32))
    if os.name == "posix":
        os.chmod(backup_key_file, 0o600)
        os.chmod(mfa_key_file, 0o600)
    env.update(
        {
            "ATERMIUS_BIND": f"127.0.0.1:{port}",
            "ATERMIUS_DATA_DIR": str(data_dir),
            "ATERMIUS_DATABASE_URL": f"sqlite://{data_dir / 'atermius.db'}?mode=rwc",
            "ATERMIUS_REGISTRATION_OPEN": "false",
            "ATERMIUS_RELAY_ENABLED": "false",
            "ATERMIUS_PUBLIC_ORIGIN": base_url,
            "ATERMIUS_ADMIN_USERNAMES": BACKUP_ADMIN,
            "ATERMIUS_BACKUP_ARCHIVE_DIR": str(backup_dir),
            "ATERMIUS_BACKUP_KEY_FILE": str(backup_key_file),
            "ATERMIUS_MFA_ENCRYPTION_KEY_FILE": str(mfa_key_file),
        }
    )
    return env


def _error(response: Any) -> str | None:
    body = response.json() if callable(getattr(response, "json", None)) else None
    if not isinstance(body, dict):
        return None
    error = body.get("error")
    return error.get("code") if isinstance(error, dict) else None


def _credentials_file(
    path: Path,
    access_key_id: str,
    secret_access_key: str,
    session_token: str | None = None,
) -> None:
    path.write_text(
        json.dumps(
            {
                "access_key_id": access_key_id,
                "secret_access_key": secret_access_key,
                "session_token": session_token,
            },
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
    if os.name == "posix":
        os.chmod(path, 0o600)


def _start_s3_stack(tmp_path: Path):
    executable = _server_binary()
    bucket = BUCKET
    fixture = LoopbackS3Process(
        bucket=bucket, temp_dir=tmp_path, session_token=secrets.token_urlsafe(32)
    )
    data_dir = tmp_path / "source-data"
    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    env = _private_env(data_dir, port)
    credential_path = tmp_path / "s3-credentials.json"
    _credentials_file(
        credential_path,
        fixture.access_key_id,
        fixture.secret_access_key,
        fixture.session_token,
    )
    env.update(
        {
            "ATERMIUS_OBJECT_STORE_BACKEND": "s3",
            "ATERMIUS_OBJECT_STORE_S3_BUCKET": bucket,
            "ATERMIUS_OBJECT_STORE_S3_REGION": fixture.region,
            "ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE": str(credential_path),
            "ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL": fixture.endpoint_url,
            "ATERMIUS_OBJECT_STORE_S3_PREFIX": PREFIX,
        }
    )
    bootstrap = _run_cli(executable, env, "bootstrap")
    assert bootstrap.returncode == 0, "isolated S3-mode bootstrap failed"
    token_match = re.search(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap.stdout)
    assert token_match, "S3-mode bootstrap did not return its one-time token"
    bootstrap_token = token_match.group(0)
    process, log_handle, api = _start_server(
        executable,
        env,
        base_url,
        tmp_path / "source-server.log",
        fixture.secret_access_key,
        fixture.access_key_id,
        fixture.endpoint_url,
    )
    api.started_by_suite = True
    api.admin_env = env
    api.temp_root = tmp_path
    api.bootstrap_token = bootstrap_token
    api.backup_archive_dir = Path(env["ATERMIUS_BACKUP_ARCHIVE_DIR"])
    api.backup_key_file = Path(env["ATERMIUS_BACKUP_KEY_FILE"])
    api.s3_credential_path = credential_path
    return {
        "api": api,
        "env": env,
        "executable": executable,
        "process": process,
        "log_handle": log_handle,
        "fixture": fixture,
        "data_dir": data_dir,
        "credential_path": credential_path,
        "log_path": tmp_path / "source-server.log",
        "base_url": base_url,
        "bootstrap_token": bootstrap_token,
    }


def _close_stack(stack: dict[str, Any]) -> None:
    process = stack.get("process")
    if process is not None:
        _stop_server(process)
        stack["process"] = None
    handle = stack.get("log_handle")
    if handle is not None:
        handle.close()
        stack["log_handle"] = None


def _init_upload(api: ApiClient, owner: dict[str, Any], body: bytes, object_id: str | None = None):
    object_id = object_id or str(uuid.uuid4())
    response = api.request(
        "POST",
        f"/api/v1/vaults/{owner['vault_id']}/uploads/init",
        token=owner["access_token"],
        json_body={
            "object_id": object_id,
            "size": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
        },
    )
    return object_id, response


def _put_chunk(api: ApiClient, owner: dict[str, Any], upload_id: str, body: bytes):
    return api.request(
        "PUT",
        f"/api/v1/uploads/{upload_id}/chunks/0",
        token=owner["access_token"],
        raw_body=body,
        content_type="application/octet-stream",
    )


def _complete(api: ApiClient, owner: dict[str, Any], upload_id: str):
    return api.request(
        "POST",
        f"/api/v1/uploads/{upload_id}/complete",
        token=owner["access_token"],
        json_body={},
    )


def _pending_key(
    instance_id: str, vault_id: str, object_id: str, upload_id: str
) -> str:
    return (
        f"{PREFIX}/atermius/objects/v1/{instance_id}/{vault_id}/"
        f"{object_id}/{upload_id}"
    )


def _new_upload_with_chunk(api: ApiClient, owner: dict[str, Any], body: bytes):
    object_id, initialized = _init_upload(api, owner, body)
    assert initialized.status in (200, 201), f"upload init failed: {_error(initialized)}"
    upload_id = initialized.json()["upload_id"]
    chunk = _put_chunk(api, owner, upload_id, body)
    assert chunk.status in (200, 201), f"chunk upload failed: {_error(chunk)}"
    return object_id, upload_id


def _signed_s3_probe(
    endpoint: str,
    bucket: str,
    key: str,
    *,
    access_key_id: str,
    secret_access_key: str,
    session_token: str | None = None,
    request_date: dt.datetime | None = None,
    credential_id: str | None = None,
    tamper_signature: bool = False,
) -> int:
    """Send a correctly signed or intentionally invalid minimal SigV4 HEAD."""
    request_date = request_date or dt.datetime.now(dt.timezone.utc)
    amz_date = request_date.strftime("%Y%m%dT%H%M%SZ")
    scope_date = request_date.strftime("%Y%m%d")
    region = "us-east-1"
    service = "s3"
    payload_hash = hashlib.sha256(b"").hexdigest()
    parsed = urllib.parse.urlsplit(endpoint)
    host = parsed.netloc
    path = f"/{urllib.parse.quote(bucket, safe='-_.~')}/{urllib.parse.quote(key, safe='/-_.~')}"
    header_values = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if session_token is not None:
        header_values["x-amz-security-token"] = session_token
    signed_headers = ";".join(sorted(header_values))
    canonical_headers = "".join(
        f"{name}:{header_values[name]}\n" for name in sorted(header_values)
    )
    canonical_request = "\n".join(
        ["HEAD", path, "", canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{scope_date}/{region}/{service}/aws4_request"
    to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ]
    )

    def sign(key_bytes: bytes, value: str) -> bytes:
        return hmac.new(key_bytes, value.encode(), hashlib.sha256).digest()

    date_key = sign(("AWS4" + secret_access_key).encode(), scope_date)
    region_key = sign(date_key, region)
    service_key = sign(region_key, service)
    signing_key = sign(service_key, "aws4_request")
    signature = hmac.new(signing_key, to_sign.encode(), hashlib.sha256).hexdigest()
    if tamper_signature:
        signature = signature[:-1] + ("0" if signature[-1] != "0" else "1")
    credential = credential_id or access_key_id
    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={credential}/{scope}, SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )
    headers = {
        "Host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "Authorization": authorization,
    }
    if session_token is not None:
        headers["x-amz-security-token"] = session_token
    request = urllib.request.Request(
        endpoint.rstrip("/") + path,
        headers=headers,
        method="HEAD",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as response:
        return response.code


def _assert_provider_material_private(stack: dict[str, Any], *texts: str) -> None:
    forbidden = (
        stack["fixture"].endpoint_url,
        stack["fixture"].bucket,
        stack["fixture"].access_key_id,
        stack["fixture"].secret_access_key,
        stack["fixture"].session_token,
        str(stack["credential_path"]),
    )
    for text in texts:
        assert not any(value in text for value in forbidden if value), (
            "object-storage endpoint or credentials appeared in an API/error/log response"
        )


def test_s3_opaque_object_vertical_acceptance_and_self_contained_backup(
    tmp_path: Path,
) -> None:
    stack = _start_s3_stack(tmp_path)
    fixture: LoopbackS3Process = stack["fixture"]
    api: ApiClient = stack["api"]
    env: dict[str, str] = stack["env"]
    executable: Path = stack["executable"]
    owner: dict[str, Any] | None = None
    outsider: dict[str, Any] | None = None
    try:
        instance_response = api.request("GET", "/api/v1/instance")
        assert instance_response.status == 200
        instance = instance_response.json()
        # Complete the mandatory first-account bootstrap using the token from
        # this isolated server. Later Vault owners are created through the
        # same operator-invite CLI used by the existing reference tests.
        bootstrap_account_id = str(uuid.uuid4())
        bootstrap_device_id = str(uuid.uuid4())
        bootstrap_signer = SigningKey(tmp_path, "s3-bootstrap-admin")
        bootstrap_registration = _new_account_registration(
            bootstrap_account_id,
            BACKUP_ADMIN,
            bootstrap_device_id,
            b64url(os.urandom(32)),
            bootstrap_signer,
        )
        bootstrap_registration["bootstrap_token"] = stack["bootstrap_token"]
        bootstrap_result = api.request(
            "POST", "/api/v1/auth/register", json_body=bootstrap_registration
        )
        assert bootstrap_result.status in (200, 201), (
            f"initial S3 test account enrollment failed: {_error(bootstrap_result)}"
        )
        owner = _new_owner(api, tmp_path)
        outsider = _new_owner(api, tmp_path)
        vault_id = owner["vault_id"]

        # Prove the local provider verifies cryptographic SigV4 fields instead
        # of accepting an access-key marker in Authorization.
        probe_key = "sigv4-probe"
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
            session_token=fixture.session_token,
        ) == 404  # Valid signature, absent key.
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
            session_token=fixture.session_token,
            tamper_signature=True,
        ) == 403
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
            session_token=fixture.session_token,
            credential_id="wrong-fixture-access",
        ) == 403
        stale_date = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=1)
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
            session_token=fixture.session_token,
            request_date=stale_date,
        ) == 403
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
        ) == 403  # Temporary credentials cannot omit their session token.
        assert _signed_s3_probe(
            fixture.endpoint_url,
            fixture.bucket,
            probe_key,
            access_key_id=fixture.access_key_id,
            secret_access_key=fixture.secret_access_key,
            session_token="wrong-session-token",
        ) == 403

        # Same reservation/chunk replay is idempotent, and a failed remote PUT
        # remains retryable without losing its SQLite-held chunks.
        content = bytes((index * 53 + 11) % 256 for index in range(32771))
        object_id, initialized = _init_upload(api, owner, content)
        assert initialized.status in (200, 201), f"upload init failed: {_error(initialized)}"
        upload_id = initialized.json()["upload_id"]
        replay_init = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": object_id,
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            },
        )
        assert replay_init.status in (200, 201)
        assert replay_init.json()["upload_id"] == upload_id
        mismatch_init = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": object_id,
                "size": len(content) + 1,
                "sha256": hashlib.sha256(content + b"x").hexdigest(),
            },
        )
        assert mismatch_init.status == 409 and _error(mismatch_init) == "UPLOAD_RESERVATION_CONFLICT"
        first_chunk = _put_chunk(api, owner, upload_id, content)
        replay_chunk = _put_chunk(api, owner, upload_id, content)
        assert first_chunk.status in (200, 201) and replay_chunk.status in (200, 201)
        assert replay_chunk.json().get("already_uploaded") is True
        object_key = _pending_key(instance["instance_id"], vault_id, object_id, upload_id)
        # AWS SDK retries transient 5xx responses internally, so queue enough
        # deterministic failures to exhaust one API attempt. The next client
        # retry then succeeds after the fake's one-shot fault batch is drained.
        fixture.inject_fault("put", "before_commit", key=object_key, count=3)
        unavailable = _complete(api, owner, upload_id)
        assert unavailable.status == 503 and _error(unavailable) == "OBJECT_STORAGE_UNAVAILABLE", (
            f"provider PUT fault was not reflected by API: HTTP {unavailable.status} "
            f"{_error(unavailable)} fixture={fixture.snapshot()}"
        )
        retry_init = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": object_id,
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            },
        )
        assert retry_init.status in (200, 201) and retry_init.json()["upload_id"] == upload_id
        completed = _complete(api, owner, upload_id)
        assert completed.status in (200, 201), f"upload retry failed: {_error(completed)}"
        completed_replay = _complete(api, owner, upload_id)
        assert completed_replay.status in (200, 201)
        assert completed_replay.json().get("already_completed") is True
        assert _scalar(
            api,
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, object_id),
        ) == "s3"
        assert _scalar(
            api,
            "SELECT length(bytes) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, object_id),
        ) == 0
        assert _scalar(
            api,
            "SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?",
            (upload_id,),
        ) == 0
        stored = fixture.object_info(object_key)
        assert stored.get("exists") is True
        assert stored.get("size") == len(content)
        assert stored.get("sha256") == hashlib.sha256(content).hexdigest()
        assert stored.get("body_sha256") == hashlib.sha256(content).hexdigest()

        # A lost acknowledgement after the provider commits is reconciled by
        # HEAD + full GET and safely publishes the same immutable object.
        lost_ack_bytes = b"commit-then-ack-lost:" + os.urandom(256)
        lost_ack_id, lost_ack_upload = _new_upload_with_chunk(api, owner, lost_ack_bytes)
        lost_ack_key = _pending_key(
            instance["instance_id"], vault_id, lost_ack_id, lost_ack_upload
        )
        fixture.inject_fault("put", "commit_then_error", key=lost_ack_key)
        lost_ack_complete = _complete(api, owner, lost_ack_upload)
        assert lost_ack_complete.status in (200, 201), f"lost-ack reconciliation failed: {_error(lost_ack_complete)}"
        assert fixture.object_info(lost_ack_key).get("body_sha256") == hashlib.sha256(
            lost_ack_bytes
        ).hexdigest()

        # Existing remote bytes with an identical digest are accepted only
        # after provider metadata and a full read are reconciled.
        same_bytes = b"same-immutable-ciphertext" * 29
        same_id, same_upload = _new_upload_with_chunk(api, owner, same_bytes)
        same_key = _pending_key(instance["instance_id"], vault_id, same_id, same_upload)
        fixture.seed_object(same_key, same_bytes)
        same_complete = _complete(api, owner, same_upload)
        assert same_complete.status in (200, 201), f"identical remote replay failed: {_error(same_complete)}"
        assert fixture.object_info(same_key).get("body_sha256") == hashlib.sha256(
            same_bytes
        ).hexdigest()

        # A colliding immutable key with different content cannot be replaced.
        conflicting_bytes = b"expected encrypted bytes" * 31
        conflict_id, conflict_upload = _new_upload_with_chunk(api, owner, conflicting_bytes)
        conflict_key = _pending_key(
            instance["instance_id"], vault_id, conflict_id, conflict_upload
        )
        preexisting = b"different encrypted bytes" * 29
        fixture.seed_object(conflict_key, preexisting)
        conflict_complete = _complete(api, owner, conflict_upload)
        assert conflict_complete.status == 409 and _error(conflict_complete) == "OBJECT_EXISTS"
        assert fixture.object_info(conflict_key).get("body_sha256") == hashlib.sha256(
            preexisting
        ).hexdigest(), "conditional conflict overwrote an existing provider object"
        # Keep the fixture's quota accounting focused on completed catalogue
        # objects; this rejected upload has already served its conflict case.
        with _db(api) as connection:
            connection.execute("UPDATE uploads SET state='expired' WHERE upload_id=?", (conflict_upload,))
            connection.execute("DELETE FROM upload_chunks WHERE upload_id=?", (conflict_upload,))

        stats = fixture.snapshot()["stats"]
        assert stats["conditionalPut"] > 0 and stats["unconditionalPut"] == 0
        assert stats["preconditionConflict"] >= 2
        assert stats["unauthorized"] == 5  # signature, identity, time, and session-token denials

        # Full response, byte range, If-Range, and generic Vault ACL behavior.
        etag = f'"sha256-{hashlib.sha256(content).hexdigest()}"'
        full = _download(api, vault_id, object_id, owner["access_token"])
        assert full.status == 200 and full.body == content
        assert full.headers.get("Content-Length") == str(len(content))
        assert full.headers.get("ETag") == etag
        ranged = _download(
            api,
            vault_id,
            object_id,
            owner["access_token"],
            Range="bytes=13-100",
            **{"If-Range": etag},
        )
        assert ranged.status == 206 and ranged.body == content[13:101]
        assert ranged.headers.get("Content-Range") == f"bytes 13-100/{len(content)}"
        stale_range = _download(
            api,
            vault_id,
            object_id,
            owner["access_token"],
            Range="bytes=13-100",
            **{"If-Range": '"sha256-stale"'},
        )
        assert stale_range.status == 200 and stale_range.body == content
        invalid_range = _download(
            api,
            vault_id,
            object_id,
            owner["access_token"],
            Range="bytes=0-1,4-5",
        )
        assert invalid_range.status == 416
        reads_before_acl = fixture.request_count("GET", key=object_key)
        foreign = _download(api, vault_id, object_id, outsider["access_token"], Range="bytes=0-0")
        assert foreign.status == 404 and _error(foreign) == "NOT_FOUND"
        assert fixture.request_count("GET", key=object_key) == reads_before_acl

        fixture.inject_fault("get", "unavailable", key=object_key, count=3)
        get_unavailable = _download(api, vault_id, object_id, owner["access_token"])
        assert get_unavailable.status == 503 and _error(get_unavailable) == "OBJECT_STORAGE_UNAVAILABLE"
        fixture.corrupt_object(object_key)
        damaged = _download(api, vault_id, object_id, owner["access_token"])
        assert damaged.status == 503 and _error(damaged) == "OBJECT_INTEGRITY_MISMATCH"
        fixture.seed_object(object_key, content)

        for response in (unavailable, get_unavailable, damaged, foreign):
            _assert_provider_material_private(stack, response.body.decode("utf-8", errors="replace"))

        # Main-head and conflict-only signed references both keep an object
        # alive after its deadline. Upload sizes remain counted in the Vault.
        main_bytes = b"main-record-attachment" * 19
        main_object, main_upload_id = _new_upload_with_chunk(api, owner, main_bytes)
        main_key = _pending_key(
            instance["instance_id"], vault_id, main_object, main_upload_id
        )
        conflict_ref_bytes = b"conflict-branch-attachment" * 17
        conflict_ref_object, conflict_ref_upload_id = _new_upload_with_chunk(
            api, owner, conflict_ref_bytes
        )
        conflict_ref_key = _pending_key(
            instance["instance_id"], vault_id, conflict_ref_object, conflict_ref_upload_id
        )
        assert _complete(api, owner, main_upload_id).status in (200, 201)
        assert _complete(api, owner, conflict_ref_upload_id).status in (200, 201)
        past = int(time.time()) - 1
        with _db(api) as connection:
            connection.execute(
                "UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id IN (?,?)",
                (past, vault_id, main_object, conflict_ref_object),
            )
        base_op = _operation(instance, owner)
        base_push = _push(api, instance, owner, [base_op])
        assert base_push.status in (200, 201)
        base_revision = base_push.json()["results"][0]["revision_id"]
        record_id = base_op["header"]["record_id"]
        main_update = _operation(
            instance,
            owner,
            operation="update",
            record_id=record_id,
            base_revision_id=base_revision,
            object_refs=[main_object],
            include_refs=True,
        )
        main_push = _push(api, instance, owner, [main_update])
        assert main_push.status in (200, 201), f"main reference push failed: {_error(main_push)}"
        conflict_branch = _operation(
            instance,
            owner,
            operation="update",
            record_id=record_id,
            base_revision_id=base_revision,
            object_refs=[conflict_ref_object],
            include_refs=True,
        )
        branch_result = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/conflicts",
            token=owner["access_token"],
            json_body={"envelope": conflict_branch},
        )
        assert branch_result.status in (200, 201), f"conflict reference failed: {_error(branch_result)}"
        _maintenance(api)
        for referenced_id, key, expected in (
            (main_object, main_key, main_bytes),
            (conflict_ref_object, conflict_ref_key, conflict_ref_bytes),
        ):
            downloaded = _download(api, vault_id, referenced_id, owner["access_token"])
            assert downloaded.status == 200 and downloaded.body == expected
            assert fixture.object_info(key).get("exists") is True
            assert _scalar(
                api,
                "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
                (vault_id, referenced_id),
            ) is None

        # Durable GC delete failure keeps remote bytes and quota until a later
        # retry succeeds. The retry is made due explicitly in this disposable
        # test DB; production backoff remains time-based.
        garbage_bytes = b"unreferenced-gc-object" * 13
        garbage_id, garbage_upload = _new_upload_with_chunk(api, owner, garbage_bytes)
        garbage_key = _pending_key(
            instance["instance_id"], vault_id, garbage_id, garbage_upload
        )
        assert _complete(api, owner, garbage_upload).status in (200, 201)
        used_before_gc = int(
            _scalar(api, "SELECT COALESCE(SUM(size),0) FROM blob_objects WHERE vault_id=?", (vault_id,))
        )
        with _db(api) as connection:
            connection.execute(
                "UPDATE vaults SET quota_bytes=? WHERE vault_id=?",
                (used_before_gc, vault_id),
            )
            connection.execute(
                "UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id=?",
                (past, vault_id, garbage_id),
            )
        quota_probe = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": str(uuid.uuid4()),
                "size": 1,
                "sha256": hashlib.sha256(b"q").hexdigest(),
            },
        )
        assert quota_probe.status == 507 and _error(quota_probe) == "QUOTA_EXCEEDED"
        fixture.inject_fault("delete", "before_delete", key=garbage_key, count=3)
        _maintenance(api)
        assert fixture.object_info(garbage_key).get("exists") is True
        assert _scalar(
            api,
            "SELECT storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, garbage_id),
        ) == "deleting"
        assert _scalar(
            api,
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_key=?",
            (garbage_key,),
        ) == 1
        assert _download(api, vault_id, garbage_id, owner["access_token"]).status == 404
        with _db(api) as connection:
            connection.execute(
                "UPDATE object_delete_queue SET next_attempt_at=0 WHERE storage_key=?",
                (garbage_key,),
            )
        _maintenance(api)
        assert fixture.object_info(garbage_key).get("exists") is False
        assert _scalar(
            api,
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, garbage_id),
        ) == 0
        assert _scalar(
            api,
            "SELECT state FROM uploads WHERE upload_id=?",
            (garbage_upload,),
        ) == "collected"
        assert fixture.request_count("DELETE", key=garbage_key) == 4
        assert fixture.snapshot()["stats"]["deleteBeforeFailures"] == 3
        after_gc_quota = api.request(
            "POST",
            f"/api/v1/vaults/{vault_id}/uploads/init",
            token=owner["access_token"],
            json_body={
                "object_id": str(uuid.uuid4()),
                "size": 1,
                "sha256": hashlib.sha256(b"q").hexdigest(),
            },
        )
        assert after_gc_quota.status in (200, 201), f"successful GC did not release quota: {_error(after_gc_quota)}"

        # Backup hydration must fail closed for both content corruption and a
        # missing provider object; each failure leaves no published archive
        # and does not rewrite the active S3 catalogue.
        archive_dir = Path(env["ATERMIUS_BACKUP_ARCHIVE_DIR"])
        key_file = Path(env["ATERMIUS_BACKUP_KEY_FILE"])
        damaged_archive = tmp_path / "damaged-remote.atb"
        missing_archive = tmp_path / "missing-remote.atb"
        fixture.corrupt_object(main_key)
        damaged_backup = _run_cli(
            executable,
            env,
            "backup",
            "--archive",
            str(damaged_archive),
            "--key-file",
            str(key_file),
        )
        assert damaged_backup.returncode != 0 and not damaged_archive.exists()
        fixture.seed_object(main_key, main_bytes)
        fixture.remove_object(conflict_ref_key)
        missing_backup = _run_cli(
            executable,
            env,
            "backup",
            "--archive",
            str(missing_archive),
            "--key-file",
            str(key_file),
        )
        assert missing_backup.returncode != 0 and not missing_archive.exists()
        fixture.seed_object(conflict_ref_key, conflict_ref_bytes)
        assert _scalar(
            api,
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, main_object),
        ) == "s3"

        archive = tmp_path / "s3-attachments-self-contained.atb"
        backup = _run_cli(
            executable,
            env,
            "backup",
            "--archive",
            str(archive),
            "--key-file",
            str(key_file),
        )
        assert backup.returncode == 0 and archive.is_file() and archive.stat().st_size > 128, (
            "valid S3-backed instance backup failed: "
            + redact_secrets(
                backup.stdout + "\n" + backup.stderr,
                fixture.secret_access_key,
                fixture.access_key_id,
                fixture.endpoint_url,
                str(stack["credential_path"]),
            )[-2500:]
        )
        verify = _run_cli(
            executable,
            env,
            "verify-backup",
            "--archive",
            str(archive),
            "--key-file",
            str(key_file),
        )
        assert verify.returncode == 0 and "Backup verified" in verify.stdout

        # The restored snapshot owns SQLite bytes and must remain usable with
        # no S3 configuration and with the original loopback provider offline.
        _close_stack(stack)
        fixture.close()
        target_data = tmp_path / "restored-data"
        restore_env = dict(env)
        for name in tuple(restore_env):
            if name.startswith("ATERMIUS_OBJECT_STORE_S3_"):
                restore_env.pop(name)
        restore_env["ATERMIUS_OBJECT_STORE_BACKEND"] = "sqlite"
        restored = _run_cli(
            executable,
            restore_env,
            "restore",
            "--server-stopped",
            "--archive",
            str(archive),
            "--key-file",
            str(key_file),
            "--target-data-dir",
            str(target_data),
        )
        assert restored.returncode == 0, "self-contained S3 attachment restore failed"
        restored_port = _free_port()
        restored_url = f"http://127.0.0.1:{restored_port}"
        restored_env = _private_env(
            target_data, restored_port, operator_dir=tmp_path / "restored-operator"
        )
        # The restored service does not need object-store credentials or an
        # endpoint. Reuse only the operator's external MFA/backup settings.
        restored_env["ATERMIUS_OBJECT_STORE_BACKEND"] = "sqlite"
        restored_env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = env[
            "ATERMIUS_MFA_ENCRYPTION_KEY_FILE"
        ]
        restored_env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = env["ATERMIUS_BACKUP_ARCHIVE_DIR"]
        restored_env["ATERMIUS_BACKUP_KEY_FILE"] = env["ATERMIUS_BACKUP_KEY_FILE"]
        restored_process, restored_log, restored_api = _start_server(
            executable,
            restored_env,
            restored_url,
            tmp_path / "restored-server.log",
            fixture.secret_access_key,
            fixture.access_key_id,
            fixture.endpoint_url,
        )
        try:
            login = restored_api.request(
                "POST",
                "/api/v1/auth/login",
                json_body={
                    "username": owner["username"],
                    "login_verifier": owner["login_verifier"],
                    "device_id": owner["device_id"],
                },
            )
            assert login.status == 200, f"restored account could not log in: {_error(login)}"
            new_access = login.json()["access_token"]
            assert restored_api.request("GET", "/api/v1/me", token=new_access).status == 200
            assert restored_api.request("GET", "/api/v1/me", token=owner["access_token"]).status == 401
            for restored_object, expected in (
                (object_id, content),
                (main_object, main_bytes),
                (conflict_ref_object, conflict_ref_bytes),
                (lost_ack_id, lost_ack_bytes),
                (same_id, same_bytes),
            ):
                download = _download(restored_api, vault_id, restored_object, new_access)
                assert download.status == 200 and download.body == expected, (
                    "restored object depended on the offline S3 provider"
                )
        finally:
            _stop_server(restored_process)
            restored_log.close()

        active_logs = stack["log_path"].read_text(errors="replace")
        restored_logs = (tmp_path / "restored-server.log").read_text(errors="replace")
        _assert_provider_material_private(stack, active_logs, restored_logs)
        for cli_result in (damaged_backup, missing_backup, backup, verify, restored):
            _assert_provider_material_private(
                stack,
                cli_result.stdout + "\n" + cli_result.stderr,
            )
        # Backup code is allowed to hydrate only its private snapshot. The
        # serving catalogue remains remote-backed after successful export.
        assert _scalar(
            api,
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
            (vault_id, main_object),
        ) == "s3"
        assert archive_dir.is_dir()
    finally:
        _close_stack(stack)
        fixture.close()
