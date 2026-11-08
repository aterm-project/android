"""API regression for sync cursors issued before a physical SQLite/key rollback."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path
from uuid import uuid4

import pytest

from conftest import ROOT, ApiClient, b64url, jcs, redact_secrets, unb64url, server_binary_path


def _run_cli(api: ApiClient, *arguments: str) -> subprocess.CompletedProcess[str]:
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), *arguments]
    else:
        cargo = shutil.which("cargo")
        if not cargo:
            pytest.skip("physical restore cursor regression requires Cargo or the debug server binary")
        command = [
            cargo,
            "run",
            "--quiet",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            *arguments,
        ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _sqlite_backup(source: Path, destination: Path) -> None:
    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as source_db:
        with sqlite3.connect(destination) as destination_db:
            source_db.backup(destination_db)
    if os.name == "posix":
        destination.chmod(0o600)


def _replace_physical_state(
    database_path: Path,
    data_dir: Path,
    database_backup: Path,
    signing_key_backup: bytes,
) -> None:
    for suffix in ("-wal", "-shm", "-journal"):
        Path(f"{database_path}{suffix}").unlink(missing_ok=True)
    shutil.copy2(database_backup, database_path)
    (data_dir / "instance-ed25519.key").write_bytes(signing_key_backup)
    if os.name == "posix":
        database_path.chmod(0o600)
        (data_dir / "instance-ed25519.key").chmod(0o600)


def test_physical_sqlite_and_signing_key_rollback_returns_cursor_recovery_410(
    api: ApiClient,
    account: dict,
    tmp_path: Path,
    make_envelope,
    push,
) -> None:
    """A newer-generation cursor gets recovery status after its signing key is rolled back."""
    if not api.started_by_suite or not api.admin_env or not api.temp_root:
        pytest.skip("physical restore cursor regression requires a suite-owned disposable server")

    data_dir = Path(api.admin_env["ATERMIUS_DATA_DIR"])
    database_url = api.admin_env["ATERMIUS_DATABASE_URL"]
    assert database_url.startswith("sqlite://"), "physical restore regression requires SQLite"
    database_path = Path(database_url.removeprefix("sqlite://").split("?", 1)[0])
    key_path = data_dir / "instance-ed25519.key"
    assert database_path.is_file() and key_path.is_file()

    original_database = tmp_path / "before-rotation.sqlite"
    rotated_database = tmp_path / "after-rotation.sqlite"
    _sqlite_backup(database_path, original_database)
    original_key = key_path.read_bytes()
    original_instance_response = api.request("GET", "/api/v1/instance")
    assert original_instance_response.status == 200
    original_instance = original_instance_response.json()

    server_stopped = False
    rotated_snapshot_ready = False
    try:
        api.stop_managed_server()
        server_stopped = True
        rotated = _run_cli(api, "rotate-instance-key", "--server-stopped")
        assert rotated.returncode == 0, redact_secrets(rotated.stdout + "\n" + rotated.stderr)[-2000:]
        api.start_managed_server()
        server_stopped = False

        rotated_instance_response = api.request("GET", "/api/v1/instance")
        assert rotated_instance_response.status == 200
        rotated_instance = rotated_instance_response.json()
        assert rotated_instance["instance_id"] == original_instance["instance_id"]
        assert rotated_instance["server_space_id"] == original_instance["server_space_id"]
        assert rotated_instance["generation"] != original_instance["generation"]
        assert rotated_instance["signing_public_key"] != original_instance["signing_public_key"]

        conflict_feed_first_page = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?limit=1",
            token=account["access_token"],
        )
        assert conflict_feed_first_page.status == 200
        conflict_feed_first_body = conflict_feed_first_page.json()
        assert conflict_feed_first_body["server_generation"] == rotated_instance["generation"]
        conflict_feed_after_seq = conflict_feed_first_body["next_after_seq"]
        assert isinstance(conflict_feed_after_seq, str) and conflict_feed_after_seq.isdecimal()
        conflict_feed_continuation = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?after_seq={conflict_feed_after_seq}&server_generation={rotated_instance['generation']}",
            token=account["access_token"],
        )
        assert conflict_feed_continuation.status == 200
        conflict_feed_checkpoint = conflict_feed_continuation.json()
        assert conflict_feed_checkpoint["after_seq"] == conflict_feed_after_seq
        assert conflict_feed_checkpoint["server_generation"] == rotated_instance["generation"]
        conflict_feed_after_seq = conflict_feed_checkpoint["next_after_seq"]

        # Create real G2 revision and conflict history continuations so the
        # restore path checks both history endpoint kinds, not just a synthetic
        # parser token.
        history_record_id = str(uuid4())
        created_revision = push(make_envelope(record_id=history_record_id, operation="create"))
        assert created_revision.status in (200, 201)
        base_revision_id = created_revision.json()["results"][0]["revision_id"]
        updated_revision = push(
            make_envelope(
                record_id=history_record_id,
                operation="update",
                base_revision_id=base_revision_id,
            )
        )
        assert updated_revision.status in (200, 201)
        for _ in range(2):
            branch = make_envelope(
                record_id=history_record_id,
                operation="update",
                base_revision_id=base_revision_id,
            )
            conflict = api.request(
                "POST",
                f"/api/v1/vaults/{account['vault_id']}/conflicts",
                token=account["access_token"],
                json_body={"envelope": branch},
            )
            assert conflict.status in (200, 201), conflict.json()

        history_snapshot_response = api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/snapshots",
            token=account["access_token"],
        )
        assert history_snapshot_response.status in (200, 201)
        history_snapshot_id = history_snapshot_response.json()["snapshot_id"]
        history_query = f"snapshot_id={history_snapshot_id}&limit=1"

        revision_first_page = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?{history_query}",
            token=account["access_token"],
        )
        assert revision_first_page.status == 200
        revision_first_body = revision_first_page.json()
        assert revision_first_body["server_generation"] == rotated_instance["generation"]
        assert revision_first_body["has_more"] is True
        revision_history_cursor = revision_first_body["next_cursor"]
        assert isinstance(revision_history_cursor, str) and revision_history_cursor
        revision_continuation = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?{history_query}&cursor={revision_history_cursor}",
            token=account["access_token"],
        )
        assert revision_continuation.status == 200
        assert revision_continuation.json()["server_generation"] == rotated_instance["generation"]
        assert len(revision_continuation.json()["revisions"]) == 1

        conflict_first_page = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflicts?{history_query}",
            token=account["access_token"],
        )
        assert conflict_first_page.status == 200
        conflict_first_body = conflict_first_page.json()
        assert conflict_first_body["server_generation"] == rotated_instance["generation"]
        assert conflict_first_body["has_more"] is True
        conflict_history_cursor = conflict_first_body["next_cursor"]
        assert isinstance(conflict_history_cursor, str) and conflict_history_cursor
        conflict_continuation = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflicts?{history_query}&cursor={conflict_history_cursor}",
            token=account["access_token"],
        )
        assert conflict_continuation.status == 200
        assert conflict_continuation.json()["server_generation"] == rotated_instance["generation"]
        assert len(conflict_continuation.json()["conflicts"]) == 1

        # Current-generation history cursors still require their MAC.
        tampered_history_cursor = bytearray(unb64url(revision_history_cursor))
        tampered_history_cursor[-1] ^= 1
        invalid_history_cursor = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?{history_query}&cursor={b64url(bytes(tampered_history_cursor))}",
            token=account["access_token"],
        )
        assert invalid_history_cursor.status == 400
        assert invalid_history_cursor.json()["error"]["code"] == "INVALID_CURSOR"

        later_cursor_response = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?limit=1",
            token=account["access_token"],
        )
        assert later_cursor_response.status == 200
        later_cursor = later_cursor_response.json().get("next_cursor")
        assert isinstance(later_cursor, str) and later_cursor

        # Save the post-rotation live state too, so this isolated integration
        # fixture can return to its expected identity after testing rollback.
        _sqlite_backup(database_path, rotated_database)
        rotated_key = key_path.read_bytes()
        rotated_snapshot_ready = True

        api.stop_managed_server()
        server_stopped = True
        _replace_physical_state(database_path, data_dir, original_database, original_key)
        api.start_managed_server()
        server_stopped = False

        restored_instance_response = api.request("GET", "/api/v1/instance")
        assert restored_instance_response.status == 200
        restored_instance = restored_instance_response.json()
        assert restored_instance["instance_id"] == original_instance["instance_id"]
        assert restored_instance["server_space_id"] == original_instance["server_space_id"]
        assert restored_instance["generation"] == original_instance["generation"]
        assert restored_instance["signing_public_key"] == original_instance["signing_public_key"]

        expired = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?cursor={later_cursor}&limit=1",
            token=account["access_token"],
        )
        assert expired.status == 410
        expired_body = expired.json()["error"]
        assert expired_body["code"] == "CURSOR_EXPIRED"
        assert expired_body["details"] == {
            "recovery": "create_snapshot",
            "preserve_local_outbox": True,
        }

        stale_conflict_feed = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflict-changes?after_seq={conflict_feed_after_seq}&server_generation={rotated_instance['generation']}",
            token=account["access_token"],
        )
        assert stale_conflict_feed.status == 410
        stale_conflict_error = stale_conflict_feed.json()["error"]
        assert stale_conflict_error["code"] == "CONFLICT_FEED_GENERATION_CHANGED"
        assert stale_conflict_error["details"] == {
            "server_generation": rotated_instance["generation"],
            "current_generation": original_instance["generation"],
            "recovery": "restart_from_zero",
        }

        for collection, cursor, row_key in (
            ("revisions", revision_history_cursor, "revisions"),
            ("conflicts", conflict_history_cursor, "conflicts"),
        ):
            stale_history = api.request(
                "GET",
                f"/api/v1/vaults/{account['vault_id']}/{collection}?snapshot_id={history_snapshot_id}&limit=1&cursor={cursor}",
                token=account["access_token"],
            )
            assert stale_history.status == 410
            stale_history_body = stale_history.json()
            assert stale_history_body["error"]["code"] == "HISTORY_CURSOR_EXPIRED"
            assert stale_history_body["error"]["details"] == {
                "recovery": "create_new_snapshot"
            }
            assert row_key not in stale_history_body

        missing_snapshot = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?{history_query}",
            token=account["access_token"],
        )
        assert missing_snapshot.status == 404
        assert missing_snapshot.json()["error"]["code"] == "NOT_FOUND"

        current_generation_claim = b64url(
            jcs(
                {
                    "v": 1,
                    "kind": "revisions",
                    "vault_id": account["vault_id"],
                    "snapshot_id": history_snapshot_id,
                    "generation": restored_instance["generation"],
                    "high_watermark": "1",
                    "conflict_high_watermark": "1",
                    "after": "0",
                }
            )
            + bytes(32)
        )
        current_generation_missing_snapshot = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/revisions?{history_query}&cursor={current_generation_claim}",
            token=account["access_token"],
        )
        assert current_generation_missing_snapshot.status == 404
        assert current_generation_missing_snapshot.json()["error"]["code"] == "NOT_FOUND"

        wrong_kind = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/conflicts?{history_query}&cursor={revision_history_cursor}",
            token=account["access_token"],
        )
        assert wrong_kind.status == 404
        assert wrong_kind.json()["error"]["code"] == "NOT_FOUND"

        wrong_vault = str(uuid4())
        wrong_vault_response = api.request(
            "GET",
            f"/api/v1/vaults/{wrong_vault}/revisions?{history_query}&cursor={revision_history_cursor}",
            token=account["access_token"],
        )
        assert wrong_vault_response.status == 404
        assert wrong_vault_response.json()["error"]["code"] == "NOT_FOUND"

        unauthenticated = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?cursor={later_cursor}&limit=1",
        )
        assert unauthenticated.status == 401
        assert unauthenticated.json()["error"]["code"] == "AUTH_REQUIRED"

        oversized_cursor = "A" * (2112 - len("cursor=") + 1)
        oversized_query = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?cursor={oversized_cursor}",
        )
        assert oversized_query.status == 400
        assert oversized_query.json()["error"]["code"] == "INVALID_CURSOR"

        nonmember_vault = str(uuid4())
        forged_foreign_generation = b64url(
            jcs(
                {
                    "v": 1,
                    "vault_id": nonmember_vault,
                    "seq": 0,
                    "generation": rotated_instance["generation"],
                }
            )
            + bytes(32)
        )
        nonmember = api.request(
            "GET",
            f"/api/v1/vaults/{nonmember_vault}/changes?cursor={forged_foreign_generation}&limit=1",
            token=account["access_token"],
        )
        assert nonmember.status == 404
        assert nonmember.json()["error"]["code"] == "NOT_FOUND"

        current = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?limit=1",
            token=account["access_token"],
        )
        assert current.status == 200
        current_cursor = current.json()["next_cursor"]
        raw = unb64url(current_cursor)
        data, tag = raw[:-32], raw[-32:]
        payload = json.loads(data)
        payload["seq"] += 1
        tampered_same_generation_cursor = b64url(jcs(payload) + tag)
        invalid = api.request(
            "GET",
            f"/api/v1/vaults/{account['vault_id']}/changes?cursor={tampered_same_generation_cursor}&limit=1",
            token=account["access_token"],
        )
        assert invalid.status == 400
        assert invalid.json()["error"]["code"] == "INVALID_CURSOR"
    finally:
        if server_stopped:
            api.start_managed_server()
            server_stopped = False
        if rotated_snapshot_ready:
            api.stop_managed_server()
            server_stopped = True
            _replace_physical_state(database_path, data_dir, rotated_database, rotated_key)
            api.start_managed_server()
            server_stopped = False
