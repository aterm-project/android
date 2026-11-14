"""Real Linux Flutter + Chromium synchronization over the two-node PG fixture.

Opt in with ATERMIUS_RUN_PG_NATIVE_WEB_SYNC_ACCEPTANCE=1 and the same
disposable PG URL/server binary inputs used by test_pg_sync_http_acceptance.py.
The runner uses a private HOME, XDG state, D-Bus session, keyring, Chromium
profile, and Xvfb display. Its output contract contains identifiers and hashes
only; credentials, envelopes, and OCR text are never emitted.
"""

from __future__ import annotations

import json
import hashlib
import os
import signal
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

import pytest

from conftest import ROOT
from test_pg_sync_http_acceptance import _require, pg_http_world


RUNNER = ROOT / "integration" / "web" / "pg_native_web_sync.cjs"
NATIVE_BUNDLE = ROOT / "apps" / "client" / "build" / "linux" / "x64" / "release" / "bundle"
NATIVE_APP = NATIVE_BUNDLE / "aterm_client"
WEB_ROOT = ROOT / "apps" / "client" / "build" / "web"
FLUTTER = Path(os.environ.get("ATERMIUS_FLUTTER", "/root/.cache/atermius/flutter/bin/flutter"))


def _private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


@pytest.mark.parametrize("pg_http_world", ["pg_native_web_sync"], indirect=True)
def test_real_linux_flutter_and_chromium_bidirectional_sync(
    pg_http_world: Any,
    tmp_path: Path,
    request: pytest.FixtureRequest,
) -> None:
    if os.environ.get("ATERMIUS_RUN_PG_NATIVE_WEB_SYNC_ACCEPTANCE") != "1":
        pytest.skip("set ATERMIUS_RUN_PG_NATIVE_WEB_SYNC_ACCEPTANCE=1 for Linux + Chromium PG acceptance")

    _require(sys.platform.startswith("linux"), "native/Web acceptance is Linux-only")
    for path, label in (
        (RUNNER, "native/Web runner"),
        (NATIVE_APP, "Linux Flutter release bundle"),
        (WEB_ROOT / "index.html", "Flutter Web release bundle"),
    ):
        _require(path.is_file(), f"{label} is missing; build the Linux and Web Flutter release bundles first")
    for utility in ("node", "xvfb-run", "dbus-run-session", "xdotool", "xwd", "tesseract", "xclip", "gnome-keyring-daemon"):
        _require(shutil.which(utility) is not None, f"Linux UI acceptance requires {utility}")
    _require(FLUTTER.is_file(), "Flutter SDK binary is unavailable for acceptance provenance")
    chromium_executable = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    if not chromium_executable:
        try:
            chromium_probe = subprocess.run(
                [
                    "node",
                    "-e",
                    "process.stdout.write(require('./integration/web/node_modules/playwright').chromium.executablePath())",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pytest.fail("could not locate the installed Playwright Chromium executable", pytrace=False)
        _require(
            chromium_probe.returncode == 0 and chromium_probe.stdout.strip(),
            "could not locate the installed Playwright Chromium executable",
        )
        chromium_executable = chromium_probe.stdout.strip()
    _require(Path(chromium_executable).is_file(), "Playwright Chromium executable is missing")

    bootstrap = pg_http_world.bootstrap_token()
    run_id = uuid.uuid4().hex
    username = f"native-web-sync-{run_id[:12]}@example.test"
    password = f"Native-Web-Sync-{run_id[:14]}!"
    markers = {
        "native": f"NativeHost-{run_id[:12]}",
        "web": f"WebHost-{run_id[12:24]}",
        "address": f"host-{run_id[:12]}.example.test",
        "ssh_username": f"ssh-{run_id[:10]}",
        "credential_name": f"PrivateKey-{run_id[:12]}",
        "snippet_title": f"PGSnippet-{run_id[:12]}",
        "snippet_body": f"atermius_snippet_body_{run_id[:16]}",
        "snippet_tag": f"pg-sync-{run_id[:12]}",
        "snippet_updated_title": f"PGSnippetEdit-{run_id[:12]}",
        "snippet_updated_body": f"atermius_snippet_update_body_{run_id[:16]}",
        "snippet_updated_tag": f"pg-sync-edit-{run_id[:12]}",
        "snippet_native_updated_title": f"PGSnippetLinuxEdit-{run_id[:12]}",
        "snippet_native_updated_body": f"atermius_snippet_linux_update_body_{run_id[:16]}",
        "snippet_native_updated_tag": f"pg-sync-linux-edit-{run_id[:12]}",
        "sftp_binary_marker": f"atermius_sftp_binary_{run_id[:16]}",
        "sftp_text_source_marker": f"atermius_sftp_text_source_{run_id[:16]}",
        "sftp_text_edited_marker": f"atermius_sftp_text_edited_{run_id[:16]}",
    }
    for secret in (bootstrap, username, password, *markers.values()):
        pg_http_world.remember_secret(secret)

    work = tmp_path / "native-web-sync"
    _private_dir(work)
    # pytest retains a bounded number of tmp_path directories by default. This
    # acceptance stores a test account password, native keyring, IndexedDB and
    # SQLite state below work, so remove it promptly even when an assertion
    # fails rather than relying on pytest's later retention cleanup.
    request.addfinalizer(lambda: shutil.rmtree(work, ignore_errors=True))
    sftp_fixture_dir = work / "sftp-fixtures"
    sftp_collision_fixture_dir = work / "sftp-collision-fixture"
    sftp_download_dir = work / "sftp-downloads"
    _private_dir(sftp_fixture_dir)
    _private_dir(sftp_collision_fixture_dir)
    _private_dir(sftp_download_dir)
    sftp_binary_upload = sftp_fixture_dir / f"atermius-sftp-binary-{run_id}.bin"
    sftp_binary_collision = sftp_collision_fixture_dir / sftp_binary_upload.name
    sftp_text_upload = sftp_fixture_dir / f"atermius-sftp-text-{run_id}.txt"
    sftp_binary_download = sftp_download_dir / f"atermius-sftp-binary-{run_id}.bin"
    sftp_text_download = sftp_download_dir / f"atermius-sftp-text-{run_id}.txt"
    sftp_binary_payload = (
        b"\x00\xffAtermius SFTP binary fixture\n"
        + markers["sftp_binary_marker"].encode("ascii")
        + b"\x00\x80\xfe\x7f"
        + bytes(range(256)) * 4
        + b"\xff\x00"
    )
    sftp_binary_collision_payload = (
        b"different collision source\n"
        + markers["sftp_binary_marker"].encode("ascii")
        + b"\xfe\x01"
        + bytes(reversed(range(256))) * 3
    )
    sftp_text_payload = (
        "Atermius account-mode SFTP UTF-8 fixture\n"
        "Unicode: 中文 / 日本語 / 한국어 / 🔐🧪\n"
        f"source-marker={markers['sftp_text_source_marker']}\n"
    ).encode("utf-8")
    sftp_text_edited_payload = sftp_text_payload + (
        f"edited-marker={markers['sftp_text_edited_marker']}\n"
    ).encode("utf-8")
    _require(
        sftp_binary_collision.name == sftp_binary_upload.name
        and hashlib.sha256(sftp_binary_collision_payload).digest()
        != hashlib.sha256(sftp_binary_payload).digest(),
        "SFTP collision source must share the remote basename but have different bytes",
    )
    for fixture_path, payload in (
        (sftp_binary_upload, sftp_binary_payload),
        (sftp_binary_collision, sftp_binary_collision_payload),
        (sftp_text_upload, sftp_text_payload),
    ):
        fixture_path.write_bytes(payload)
        os.chmod(fixture_path, 0o600)
    _require(
        not sftp_binary_download.exists() and not sftp_text_download.exists(),
        "SFTP download paths must start absent so the native save dialogs create them",
    )
    home = work / "home"
    xdg_data = work / "xdg-data"
    xdg_config = work / "xdg-config"
    xdg_cache = work / "xdg-cache"
    xdg_state = work / "xdg-state"
    xdg_runtime = work / "xdg-runtime"
    for directory in (home, xdg_data, xdg_config, xdg_cache, xdg_state, xdg_runtime):
        _private_dir(directory)
    ready_file = work / "runner-result.json"
    environment = os.environ.copy()
    # The Node runner invokes the same Python interpreter for read-only SQLite
    # and PostgreSQL privacy scans. Keep psycopg available even when the
    # machine's system Python has only pytest's base dependencies.
    environment["PATH"] = f"{Path(sys.executable).parent}{os.pathsep}{environment.get('PATH', '')}"
    environment.update(
        {
            "HOME": str(home),
            "XDG_DATA_HOME": str(xdg_data),
            "XDG_CONFIG_HOME": str(xdg_config),
            "XDG_CACHE_HOME": str(xdg_cache),
            "XDG_STATE_HOME": str(xdg_state),
            "XDG_RUNTIME_DIR": str(xdg_runtime),
            "GSETTINGS_BACKEND": "memory",
            "ATERMIUS_NATIVE_WEB_SYNC_NODE_A_URL": pg_http_world.clients[0].base_url,
            "ATERMIUS_NATIVE_WEB_SYNC_NODE_B_URL": pg_http_world.clients[1].base_url,
            "ATERMIUS_SYNC_PG_URL": pg_http_world.pg_url,
            "ATERMIUS_SYNC_PG_SCHEMA": pg_http_world.schema,
            "ATERMIUS_NATIVE_WEB_SYNC_USERNAME": username,
            "ATERMIUS_NATIVE_WEB_SYNC_PASSWORD": password,
            "ATERMIUS_NATIVE_WEB_SYNC_BOOTSTRAP_TOKEN": bootstrap,
            "ATERMIUS_NATIVE_WEB_SYNC_NATIVE_HOST": markers["native"],
            "ATERMIUS_NATIVE_WEB_SYNC_WEB_HOST": markers["web"],
            "ATERMIUS_NATIVE_WEB_SYNC_HOST_ADDRESS": markers["address"],
            "ATERMIUS_NATIVE_WEB_SYNC_SSH_USERNAME": markers["ssh_username"],
            "ATERMIUS_NATIVE_WEB_SYNC_CREDENTIAL_NAME": markers["credential_name"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_TITLE": markers["snippet_title"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_BODY_MARKER": markers["snippet_body"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_TAG": markers["snippet_tag"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_UPDATED_TITLE": markers["snippet_updated_title"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_UPDATED_BODY_MARKER": markers["snippet_updated_body"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_UPDATED_TAG": markers["snippet_updated_tag"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_NATIVE_UPDATED_TITLE": markers["snippet_native_updated_title"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_NATIVE_UPDATED_BODY_MARKER": markers["snippet_native_updated_body"],
            "ATERMIUS_NATIVE_WEB_SYNC_SNIPPET_NATIVE_UPDATED_TAG": markers["snippet_native_updated_tag"],
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_BINARY_UPLOAD_PATH": str(sftp_binary_upload),
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_BINARY_COLLISION_PATH": str(sftp_binary_collision),
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_TEXT_UPLOAD_PATH": str(sftp_text_upload),
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_BINARY_DOWNLOAD_PATH": str(sftp_binary_download),
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_TEXT_DOWNLOAD_PATH": str(sftp_text_download),
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_BINARY_MARKER": markers["sftp_binary_marker"],
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_TEXT_MARKER": markers["sftp_text_source_marker"],
            "ATERMIUS_NATIVE_WEB_SYNC_SFTP_TEXT_EDITED_MARKER": markers["sftp_text_edited_marker"],
            "ATERMIUS_NATIVE_WEB_SYNC_HOME": str(home),
            "ATERMIUS_NATIVE_WEB_SYNC_RESULT_FILE": str(ready_file),
            "ATERMIUS_NATIVE_WEB_SYNC_NATIVE_APP": str(NATIVE_APP),
            "ATERMIUS_NATIVE_WEB_SYNC_WEB_ROOT": str(WEB_ROOT),
            "PLAYWRIGHT_CHROMIUM_EXECUTABLE": chromium_executable,
            "ATERMIUS_NATIVE_WEB_SYNC_FLUTTER_VERSION": "3.47.5",
        }
    )
    command = [
        "xvfb-run", "-a", "-s", "-screen 0 1600x1000x24",
        "dbus-run-session", "--", "node", str(RUNNER),
    ]
    runner = subprocess.Popen(
        command,
        cwd=ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    runner_output = ""
    try:
        try:
            runner_output, _ = runner.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(runner.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                runner.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(runner.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                runner.communicate(timeout=5)
            pytest.fail(
                "Linux native + Chromium PostgreSQL acceptance timed out; process group was stopped",
                pytrace=False,
            )
    finally:
        if runner.poll() is None:
            try:
                os.killpg(runner.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            runner.communicate(timeout=5)
    if runner.returncode != 0:
        # The Node runner emits stage-only diagnostics and sanitizes its own
        # caught errors. Keep only those lines and scrub fixture secrets again
        # before exposing a focused failure message to pytest output.
        safe_stages = "\n".join(
            line[:1400]
            for line in runner_output.splitlines()
            if line.startswith("stage: ")
        )
        for secret in sorted(pg_http_world.secrets, key=len, reverse=True):
            if secret:
                safe_stages = safe_stages.replace(secret, "[redacted]")
        pytest.fail(
            f"Linux native + Chromium runner failed with exit {runner.returncode}; stages:\n{safe_stages[-2800:]}",
            pytrace=False,
        )
    _require(ready_file.is_file(), "Linux native + Chromium runner returned without its result record")
    try:
        evidence = json.loads(ready_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pytest.fail("Linux native + Chromium runner result was invalid", pytrace=False)

    required = {
        "schema": 5,
        "durable_outbox_matched_at_held_push": True,
        "native_process_killed_and_relaunched": True,
        "pending_operation_identity_stable": True,
        "native_retry_committed_once": True,
        "native_record_decrypted_in_web": True,
        "web_record_pulled_and_decrypted_by_native": True,
        "pulled_web_record_not_republished": True,
        "native_db_plaintext_scan_clear": True,
        "web_indexeddb_plaintext_scan_clear": True,
        "web_local_storage_plaintext_scan_clear": True,
        "web_cache_plaintext_scan_clear": True,
        "server_plaintext_scan_clear": True,
        "ssh_fixture_cleanup_verified": True,
        "private_key_form_roundtrip_verified": True,
        "private_key_decrypted_and_used_by_native_ssh": True,
        "ssh_host_key_fingerprint_verified": True,
        "ssh_marker_file_verified": True,
        "web_private_key_persistence_scan_clear": True,
        "native_private_key_persistence_scan_clear": True,
        "server_private_key_persistence_scan_clear": True,
        "privacy_marker_ocr_match": True,
        "snippet_created_and_decrypted_in_web": True,
        "native_cached_snippet_display_decrypted": True,
        "native_snippet_title_field_verified": True,
        "native_snippet_body_field_verified": True,
        "native_snippet_tag_field_verified": True,
        "native_updated_snippet_title_field_verified": True,
        "native_updated_snippet_body_field_verified": True,
        "native_updated_snippet_tag_field_verified": True,
        "native_snippet_second_update_title_field_verified": True,
        "native_snippet_second_update_body_field_verified": True,
        "native_snippet_second_update_tag_field_verified": True,
        "web_pulled_native_snippet_verified": True,
        "web_native_snippet_update_fields_verified": True,
        "web_republished_native_snippet_update": False,
        "snippet_execution_requested": False,
        "linux_only_scope": True,
        "android_ios_windows_verified": False,
    }
    _require(isinstance(evidence, dict), "native/Web result was not an object")
    for field, expected in required.items():
        _require(evidence.get(field) == expected, f"native/Web evidence did not satisfy {field}")
    for field in (
        "sftp_collision_upload_rejected",
        "sftp_collision_original_unchanged",
        "sftp_text_editor_saved",
        "sftp_remote_files_deleted",
        "sftp_remote_directory_deleted",
        "sftp_vault_ledger_unchanged",
    ):
        _require(
            type(evidence.get(field)) is bool and evidence[field] is True,
            f"native/Web SFTP evidence did not report successful {field}",
        )
    sftp_expected_hashes = {
        "sftp_binary_upload_sha256": hashlib.sha256(sftp_binary_payload).hexdigest(),
        "sftp_binary_remote_sha256": hashlib.sha256(sftp_binary_payload).hexdigest(),
        "sftp_binary_download_sha256": hashlib.sha256(sftp_binary_payload).hexdigest(),
        "sftp_text_upload_sha256": hashlib.sha256(sftp_text_payload).hexdigest(),
        "sftp_text_edited_sha256": hashlib.sha256(sftp_text_edited_payload).hexdigest(),
        "sftp_text_remote_sha256": hashlib.sha256(sftp_text_edited_payload).hexdigest(),
        "sftp_text_download_sha256": hashlib.sha256(sftp_text_edited_payload).hexdigest(),
    }
    for field, expected_hash in sftp_expected_hashes.items():
        actual_hash = evidence.get(field)
        _require(
            type(actual_hash) is str and len(actual_hash) == 64 and actual_hash == expected_hash,
            f"native/Web SFTP evidence did not match the fixture bytes for {field}",
        )
    for path, expected_hash, label in (
        (
            sftp_binary_download,
            sftp_expected_hashes["sftp_binary_download_sha256"],
            "binary",
        ),
        (
            sftp_text_download,
            sftp_expected_hashes["sftp_text_download_sha256"],
            "edited UTF-8 text",
        ),
    ):
        _require(path.is_file(), f"native SFTP did not save the {label} download")
        _require(
            hashlib.sha256(path.read_bytes()).hexdigest() == expected_hash,
            f"saved {label} download did not match its expected bytes",
        )
    _require(
        type(evidence.get("ssh_sftp_session_count")) is int
        and evidence["ssh_sftp_session_count"] >= 1,
        "SSH fixture did not observe an SFTP subsystem session",
    )
    for field in ("pageErrors", "consoleErrors", "unexpectedRequestErrors"):
        _require(evidence.get(field) == 0, f"native/Web runner reported {field}")
    _require(
        isinstance(evidence.get("nativeSuccessfulPushAttempts"), int)
        and evidence["nativeSuccessfulPushAttempts"] >= 1
        and isinstance(evidence.get("webSuccessfulPushAttempts"), int)
        and evidence["webSuccessfulPushAttempts"] >= 1
        and isinstance(evidence.get("heldNativePushAttempts"), int)
        and evidence["heldNativePushAttempts"] >= 1,
        "native and Web must each commit one signed operation, after at least one held pre-commit attempt",
    )
    _require(
        evidence.get("pendingNativeBeforeKill") == 1
        and evidence.get("pendingNativeAfterCommit") == 0,
        "native operation must survive SIGKILL in the outbox and clear after commit acknowledgement",
    )
    for field in (
        "account_id",
        "vault_id",
        "record_id",
        "native_device_id",
        "web_device_id",
        "native_op_id",
        "web_op_id",
        "native_batch_id",
        "web_batch_id",
        "credential_record_id",
        "credential_op_id",
        "credential_batch_id",
        "credential_revision_id",
        "ssh_host_op_id",
        "ssh_host_batch_id",
        "ssh_host_revision_id",
        "known_host_record_id",
        "known_host_op_id",
        "known_host_batch_id",
        "known_host_revision_id",
        "snippet_record_id",
        "snippet_op_id",
        "snippet_batch_id",
        "snippet_revision_id",
        "snippet_update_op_id",
        "snippet_update_batch_id",
        "snippet_update_revision_id",
        "native_snippet_update_op_id",
        "native_snippet_update_batch_id",
        "native_snippet_update_revision_id",
    ):
        value = evidence.get(field)
        _require(isinstance(value, str) and value, f"native/Web evidence omitted {field}")
    _require(
        evidence["native_device_id"] != evidence["web_device_id"],
        "native and Web synchronization must use distinct enrolled devices",
    )
    _require(
        evidence.get("native_cached_web_revision_id") == evidence.get("web_revision_id")
        and evidence.get("native_cached_web_commit_seq") == "2"
        and isinstance(evidence.get("native_cached_web_envelope_sha256"), str)
        and len(evidence["native_cached_web_envelope_sha256"]) == 64,
        "native encrypted cache must retain the exact Web-signed revision and commit sequence",
    )
    _require(
        evidence.get("native_cached_credential_revision_id") == evidence.get("credential_revision_id")
        and evidence.get("native_cached_credential_commit_seq") == "3"
        and evidence.get("native_cached_ssh_host_revision_id") == evidence.get("ssh_host_revision_id")
        and evidence.get("native_cached_ssh_host_commit_seq") == "4"
        and all(
            isinstance(evidence.get(field), str) and len(evidence[field]) == 64
            for field in (
                "native_cached_credential_envelope_sha256",
                "native_cached_ssh_host_envelope_sha256",
            )
        ),
        "native encrypted cache must retain the exact Web Credential and Host revisions",
    )
    _require(
        evidence.get("credential_commit_seq") == "3"
        and evidence.get("ssh_host_commit_seq") == "4"
        and evidence.get("known_host_commit_seq") == "5"
        and evidence.get("known_host_device_seq") == "2"
        and evidence.get("snippet_commit_seq") == "6"
        and evidence.get("snippet_device_seq") == "4"
        and evidence.get("snippet_successful_push_attempts") == 1
        and evidence.get("native_cached_snippet_revision_id") == evidence.get("snippet_revision_id")
        and evidence.get("native_cached_snippet_commit_seq") == "6"
        and evidence.get("snippet_envelope_sha256") == evidence.get(
            "native_cached_snippet_canonical_envelope_sha256"
        )
        and isinstance(evidence.get("snippet_envelope_sha256"), str)
        and len(evidence["snippet_envelope_sha256"]) == 64
        and evidence.get("snippet_update_commit_seq") == "7"
        and evidence.get("snippet_update_device_seq") == "5"
        and evidence.get("snippet_update_successful_push_attempts") == 1
        and evidence.get("snippet_update_revision_id") != evidence.get("snippet_revision_id")
        and evidence.get("snippet_update_op_id") != evidence.get("snippet_op_id")
        and evidence.get("native_cached_snippet_update_revision_id") ==
            evidence.get("snippet_update_revision_id")
        and evidence.get("native_cached_snippet_update_commit_seq") == "7"
        and evidence.get("snippet_update_envelope_sha256") ==
            evidence.get("native_cached_snippet_update_canonical_envelope_sha256")
        and isinstance(evidence.get("snippet_update_envelope_sha256"), str)
        and len(evidence["snippet_update_envelope_sha256"]) == 64
        and evidence.get("native_snippet_update_commit_seq") == "8"
        and evidence.get("native_snippet_update_device_seq") == "3"
        and evidence.get("native_snippet_update_successful_push_attempts") == 1
        and evidence.get("native_snippet_update_revision_id") != evidence.get("snippet_update_revision_id")
        and evidence.get("native_snippet_update_op_id") != evidence.get("snippet_update_op_id")
        and evidence.get("native_cached_snippet_native_update_revision_id") ==
            evidence.get("native_snippet_update_revision_id")
        and evidence.get("native_cached_snippet_native_update_commit_seq") == "8"
        and evidence.get("native_snippet_update_envelope_sha256") ==
            evidence.get("native_cached_snippet_native_update_canonical_envelope_sha256")
        and evidence.get("native_snippet_update_envelope_sha256") ==
            evidence.get("web_pulled_native_snippet_envelope_sha256")
        and evidence.get("web_pulled_native_snippet_revision_id") ==
            evidence.get("native_snippet_update_revision_id")
        and evidence.get("web_pulled_native_snippet_commit_seq") == "8"
        and isinstance(evidence.get("native_snippet_update_envelope_sha256"), str)
        and len(evidence["native_snippet_update_envelope_sha256"]) == 64
        and evidence.get("native_cached_known_host_revision_id") == evidence.get("known_host_revision_id")
        and evidence.get("native_cached_known_host_commit_seq") == "5"
        and evidence.get("known_host_envelope_sha256") == evidence.get(
            "native_cached_known_host_canonical_envelope_sha256"
        )
        and isinstance(evidence.get("known_host_envelope_sha256"), str)
        and len(evidence["known_host_envelope_sha256"]) == 64
        and evidence.get("ssh_publickey_accepted_count", 0) >= 1
        and evidence.get("ssh_interactive_shell_count", 0) >= 1
        and evidence.get("private_key_persistence_marker_count") == 3,
        "SSH Credential receipts, public-key login, shell session, or private-key privacy markers were incomplete",
    )
    _require(
        all(
            isinstance(evidence.get(field), int) and evidence[field] > 0
            for field in (
                "web_persistent_database_count",
                "web_persistent_store_count",
                "web_persistent_row_count",
            )
        ),
        "Chromium persistence scan did not inspect populated Web storage",
    )

    vault_id = evidence["vault_id"]
    record_id = evidence["record_id"]
    native_op_id = evidence["native_op_id"]
    web_op_id = evidence["web_op_id"]
    native_batch_id = evidence["native_batch_id"]
    web_batch_id = evidence["web_batch_id"]
    connection = pg_http_world.database_connection
    rows = connection.execute(
        "SELECT commit_seq, revision_id, operation, envelope, device_id FROM record_versions "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, record_id),
    ).fetchall()
    _require(len(rows) == 3, "server must store the native create and both Web Host updates")
    _require([int(row[0]) for row in rows] == [1, 2, 4], "Host revisions must occupy commit sequences 1, 2, and 4")
    _require([row[2] for row in rows] == ["create", "update", "update"], "Host version operations must be create followed by two updates")
    _require(
        rows[0][4] == evidence["native_device_id"]
        and rows[1][4] == evidence["web_device_id"],
        "PostgreSQL first two Host version signers must be the enrolled native and Web devices",
    )
    for row in rows:
        stored_envelope = str(row[3])
        _require(all(marker not in stored_envelope for marker in markers.values()), "server record envelope exposed a plaintext Host marker")

    head = connection.execute(
        "SELECT revision_id, commit_seq, deleted FROM record_heads WHERE vault_id=%s AND record_id=%s",
        (vault_id, record_id),
    ).fetchone()
    _require(head is not None and head[0] == rows[2][1] and int(head[1]) == 4 and not head[2], "server Host head did not point to the latest SSH Credential link revision")
    counter = connection.execute(
        "SELECT last_committed_seq FROM vault_counters WHERE vault_id=%s", (vault_id,)
    ).fetchone()
    _require(counter is not None and int(counter[0]) == 8, "server Vault cursor did not end at the exact Linux Snippet update commit")
    total_versions, total_heads, total_events = connection.execute(
        "SELECT (SELECT count(*) FROM record_versions WHERE vault_id=%s), "
        "(SELECT count(*) FROM record_heads WHERE vault_id=%s), "
        "(SELECT count(*) FROM change_events WHERE vault_id=%s)",
        (vault_id, vault_id, vault_id),
    ).fetchone()
    _require(
        (int(total_versions), int(total_heads), int(total_events)) == (8, 4, 8),
        "server Vault must contain exactly eight committed revisions/events and four current record heads",
    )
    versions, events = connection.execute(
        "SELECT (SELECT count(*) FROM record_versions WHERE vault_id=%s AND record_id=%s), "
        "(SELECT count(*) FROM change_events WHERE vault_id=%s AND record_id=%s)",
        (vault_id, record_id, vault_id, record_id),
    ).fetchone()
    _require(int(versions) == 3 and int(events) == 3, "server Host version/event ledger must contain exactly three commits")
    event_rows = connection.execute(
        "SELECT commit_seq, event_type, record_id, revision_id, envelope FROM change_events "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, record_id),
    ).fetchall()
    _require(
        len(event_rows) == 3
        and [
            (int(row[0]), row[1], row[2], row[3], row[4])
            for row in event_rows
        ]
        == [
            (int(row[0]), row[2], record_id, row[1], row[3])
            for row in rows
        ],
        "change events must preserve each exact committed revision envelope in order",
    )

    credential_record_id = evidence["credential_record_id"]
    _require(credential_record_id != record_id, "private-key Credential must be a distinct encrypted record from its Host")
    credential_rows = connection.execute(
        "SELECT commit_seq, revision_id, operation, envelope, device_id FROM record_versions "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, credential_record_id),
    ).fetchall()
    _require(
        len(credential_rows) == 1
        and int(credential_rows[0][0]) == 3
        and credential_rows[0][1] == evidence["credential_revision_id"]
        and credential_rows[0][2] == "create"
        and credential_rows[0][4] == evidence["web_device_id"],
        "PostgreSQL must store the Web-signed encrypted Credential create at commit 3",
    )
    credential_head = connection.execute(
        "SELECT revision_id, commit_seq, deleted FROM record_heads WHERE vault_id=%s AND record_id=%s",
        (vault_id, credential_record_id),
    ).fetchone()
    _require(
        credential_head is not None and credential_head[0] == credential_rows[0][1]
        and int(credential_head[1]) == 3 and not credential_head[2],
        "server Credential head did not point to the encrypted commit-3 revision",
    )
    credential_events = connection.execute(
        "SELECT commit_seq, event_type, record_id, revision_id, envelope FROM change_events "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, credential_record_id),
    ).fetchall()
    _require(
        len(credential_events) == 1
        and int(credential_events[0][0]) == 3
        and credential_events[0][1] == "create"
        and credential_events[0][2] == credential_record_id
        and credential_events[0][3] == credential_rows[0][1]
        and credential_events[0][4] == credential_rows[0][3],
        "Credential change event must preserve its exact encrypted revision envelope",
    )

    known_host_record_id = evidence["known_host_record_id"]
    _require(
        known_host_record_id not in {record_id, credential_record_id},
        "SSH KnownHost must be a distinct encrypted record",
    )
    known_host_rows = connection.execute(
        "SELECT commit_seq, revision_id, operation, envelope, device_id FROM record_versions "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, known_host_record_id),
    ).fetchall()
    _require(
        len(known_host_rows) == 1
        and int(known_host_rows[0][0]) == 5
        and known_host_rows[0][1] == evidence["known_host_revision_id"]
        and known_host_rows[0][2] == "create"
        and known_host_rows[0][4] == evidence["native_device_id"],
        "PostgreSQL must store the native-signed encrypted SSH KnownHost create at commit 5",
    )
    known_host_envelope = (
        json.loads(known_host_rows[0][3]) if isinstance(known_host_rows[0][3], str) else known_host_rows[0][3]
    )
    _require(
        hashlib.sha256(json.dumps(
            known_host_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")).hexdigest() == evidence["known_host_envelope_sha256"],
        "PostgreSQL KnownHost envelope hash differs from the signed native push",
    )
    known_host_head = connection.execute(
        "SELECT revision_id, commit_seq, deleted FROM record_heads WHERE vault_id=%s AND record_id=%s",
        (vault_id, known_host_record_id),
    ).fetchone()
    _require(
        known_host_head is not None and known_host_head[0] == evidence["known_host_revision_id"]
        and int(known_host_head[1]) == 5 and not known_host_head[2],
        "server KnownHost head did not point to the exact encrypted commit-5 revision",
    )
    known_host_events = connection.execute(
        "SELECT commit_seq, event_type, record_id, revision_id, envelope FROM change_events "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, known_host_record_id),
    ).fetchall()
    _require(
        len(known_host_events) == 1
        and int(known_host_events[0][0]) == 5
        and known_host_events[0][1] == "create"
        and known_host_events[0][2] == known_host_record_id
        and known_host_events[0][3] == evidence["known_host_revision_id"]
        and known_host_events[0][4] == known_host_rows[0][3],
        "KnownHost change event must preserve its exact encrypted revision envelope",
    )

    snippet_record_id = evidence["snippet_record_id"]
    _require(snippet_record_id not in {record_id, credential_record_id, known_host_record_id},
             "Snippet must be stored as a distinct encrypted record")
    snippet_rows = connection.execute(
        "SELECT commit_seq, revision_id, operation, envelope, device_id FROM record_versions "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, snippet_record_id),
    ).fetchall()
    _require(
        len(snippet_rows) == 3
        and int(snippet_rows[0][0]) == 6
        and snippet_rows[0][1] == evidence["snippet_revision_id"]
        and snippet_rows[0][2] == "create"
        and snippet_rows[0][4] == evidence["web_device_id"]
        and int(snippet_rows[1][0]) == 7
        and snippet_rows[1][1] == evidence["snippet_update_revision_id"]
        and snippet_rows[1][2] == "update"
        and snippet_rows[1][4] == evidence["web_device_id"]
        and int(snippet_rows[2][0]) == 8
        and snippet_rows[2][1] == evidence["native_snippet_update_revision_id"]
        and snippet_rows[2][2] == "update"
        and snippet_rows[2][4] == evidence["native_device_id"],
        "PostgreSQL must store the Web Snippet create/update and Linux-signed update at commits 6/7/8",
    )
    snippet_envelope = json.loads(snippet_rows[0][3]) if isinstance(snippet_rows[0][3], str) else snippet_rows[0][3]
    snippet_canonical = json.dumps(
        snippet_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    _require(
        hashlib.sha256(snippet_canonical).hexdigest() == evidence["snippet_envelope_sha256"],
        "PostgreSQL Snippet envelope hash differs from the signed Web push",
    )
    snippet_update_envelope = json.loads(snippet_rows[1][3]) if isinstance(snippet_rows[1][3], str) else snippet_rows[1][3]
    snippet_update_canonical = json.dumps(
        snippet_update_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    _require(
        hashlib.sha256(snippet_update_canonical).hexdigest() == evidence["snippet_update_envelope_sha256"],
        "PostgreSQL Snippet update envelope hash differs from the signed Web push",
    )
    snippet_native_update_envelope = json.loads(snippet_rows[2][3]) if isinstance(snippet_rows[2][3], str) else snippet_rows[2][3]
    snippet_native_update_canonical = json.dumps(
        snippet_native_update_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    _require(
        hashlib.sha256(snippet_native_update_canonical).hexdigest() == evidence["native_snippet_update_envelope_sha256"],
        "PostgreSQL Linux Snippet update envelope hash differs from the signed native push",
    )
    snippet_head = connection.execute(
        "SELECT revision_id, commit_seq, deleted FROM record_heads WHERE vault_id=%s AND record_id=%s",
        (vault_id, snippet_record_id),
    ).fetchone()
    _require(
        snippet_head is not None and snippet_head[0] == evidence["native_snippet_update_revision_id"]
        and int(snippet_head[1]) == 8 and not snippet_head[2],
        "server Snippet head did not point to the exact encrypted Linux commit-8 revision",
    )
    snippet_events = connection.execute(
        "SELECT commit_seq, event_type, record_id, revision_id, envelope FROM change_events "
        "WHERE vault_id=%s AND record_id=%s ORDER BY commit_seq",
        (vault_id, snippet_record_id),
    ).fetchall()
    _require(
        len(snippet_events) == 3
        and int(snippet_events[0][0]) == 6
        and snippet_events[0][1] == "create"
        and snippet_events[0][2] == snippet_record_id
        and snippet_events[0][3] == evidence["snippet_revision_id"]
        and snippet_events[0][4] == snippet_rows[0][3]
        and int(snippet_events[1][0]) == 7
        and snippet_events[1][1] == "update"
        and snippet_events[1][2] == snippet_record_id
        and snippet_events[1][3] == evidence["snippet_update_revision_id"]
        and snippet_events[1][4] == snippet_rows[1][3]
        and int(snippet_events[2][0]) == 8
        and snippet_events[2][1] == "update"
        and snippet_events[2][2] == snippet_record_id
        and snippet_events[2][3] == evidence["native_snippet_update_revision_id"]
        and snippet_events[2][4] == snippet_rows[2][3],
        "Snippet create/update events must preserve all three exact encrypted revision envelopes",
    )
    snippet_event_envelope = (
        json.loads(snippet_events[0][4]) if isinstance(snippet_events[0][4], str) else snippet_events[0][4]
    )
    _require(
        hashlib.sha256(json.dumps(
            snippet_event_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")).hexdigest() == evidence["snippet_envelope_sha256"],
        "PostgreSQL Snippet create event hash differs from the signed Web push",
    )
    snippet_update_event_envelope = (
        json.loads(snippet_events[1][4]) if isinstance(snippet_events[1][4], str) else snippet_events[1][4]
    )
    _require(
        hashlib.sha256(json.dumps(
            snippet_update_event_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")).hexdigest() == evidence["snippet_update_envelope_sha256"],
        "PostgreSQL Snippet update event hash differs from the signed Web push",
    )
    snippet_native_update_event_envelope = (
        json.loads(snippet_events[2][4]) if isinstance(snippet_events[2][4], str) else snippet_events[2][4]
    )
    _require(
        hashlib.sha256(json.dumps(
            snippet_native_update_event_envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")).hexdigest() == evidence["native_snippet_update_envelope_sha256"],
        "PostgreSQL Linux Snippet change event hash differs from the signed native push",
    )

    all_envelopes = [str(row[3]) for row in rows] + [
        str(credential_rows[0][3]), str(known_host_rows[0][3]),
        *(str(row[3]) for row in snippet_rows),
    ]
    _require(
        not any(marker in envelope for marker in markers.values() for envelope in all_envelopes),
        "PostgreSQL Host, Credential, or Snippet envelope exposed a synthetic plaintext marker",
    )

    receipts = connection.execute(
        "SELECT op_id, device_id, device_seq, record_id, revision_id, commit_seq "
        "FROM op_receipts WHERE vault_id=%s AND op_id=ANY(%s::text[])",
        (vault_id, [native_op_id, web_op_id, evidence["credential_op_id"], evidence["ssh_host_op_id"], evidence["known_host_op_id"], evidence["snippet_op_id"], evidence["snippet_update_op_id"], evidence["native_snippet_update_op_id"]]),
    ).fetchall()
    expected_ops = {native_op_id, web_op_id, evidence["credential_op_id"], evidence["ssh_host_op_id"], evidence["known_host_op_id"], evidence["snippet_op_id"], evidence["snippet_update_op_id"], evidence["native_snippet_update_op_id"]}
    _require(len(receipts) == 8 and {row[0] for row in receipts} == expected_ops, "server operation ledger must contain one receipt per tested native/Web operation")
    _require(
        connection.execute(
            "SELECT count(*) FROM op_receipts WHERE vault_id=%s", (vault_id,)
        ).fetchone()[0] == 8,
        "server operation receipt ledger contains an unexpected extra operation",
    )
    receipt_by_id = {row[0]: row for row in receipts}
    native_receipt = receipt_by_id[native_op_id]
    web_receipt = receipt_by_id[web_op_id]
    credential_receipt = receipt_by_id[evidence["credential_op_id"]]
    ssh_host_receipt = receipt_by_id[evidence["ssh_host_op_id"]]
    known_host_receipt = receipt_by_id[evidence["known_host_op_id"]]
    snippet_receipt = receipt_by_id[evidence["snippet_op_id"]]
    snippet_update_receipt = receipt_by_id[evidence["snippet_update_op_id"]]
    native_snippet_update_receipt = receipt_by_id[evidence["native_snippet_update_op_id"]]
    _require(
        native_receipt[1:] == (
            evidence["native_device_id"],
            "1",
            record_id,
            rows[0][1],
            1,
        )
        and web_receipt[1:] == (
            evidence["web_device_id"],
            "1",
            record_id,
            rows[1][1],
            2,
        )
        and credential_receipt[1:] == (
            evidence["web_device_id"], "2", credential_record_id, credential_rows[0][1], 3,
        )
        and ssh_host_receipt[1:] == (
            evidence["web_device_id"], "3", record_id, rows[2][1], 4,
        )
        and known_host_receipt[1:] == (
            evidence["native_device_id"], "2", known_host_record_id, evidence["known_host_revision_id"], 5,
        )
        and snippet_receipt[1:] == (
            evidence["web_device_id"], "4", snippet_record_id, evidence["snippet_revision_id"], 6,
        )
        and snippet_update_receipt[1:] == (
            evidence["web_device_id"], "5", snippet_record_id,
            evidence["snippet_update_revision_id"], 7,
        )
        and native_snippet_update_receipt[1:] == (
            evidence["native_device_id"], "3", snippet_record_id,
            evidence["native_snippet_update_revision_id"], 8,
        ),
        "operation receipts must bind each enrolled device sequence to its exact signed revision",
    )
    batches = connection.execute(
        "SELECT device_id, batch_id FROM batch_receipts WHERE vault_id=%s AND batch_id=ANY(%s::text[])",
        (vault_id, [native_batch_id, web_batch_id, evidence["credential_batch_id"], evidence["ssh_host_batch_id"], evidence["known_host_batch_id"], evidence["snippet_batch_id"], evidence["snippet_update_batch_id"], evidence["native_snippet_update_batch_id"]]),
    ).fetchall()
    _require(
        len(batches) == 8
        and set(batches)
        == {
            (evidence["native_device_id"], native_batch_id),
            (evidence["web_device_id"], web_batch_id),
            (evidence["web_device_id"], evidence["credential_batch_id"]),
            (evidence["web_device_id"], evidence["ssh_host_batch_id"]),
            (evidence["native_device_id"], evidence["known_host_batch_id"]),
            (evidence["web_device_id"], evidence["snippet_batch_id"]),
            (evidence["web_device_id"], evidence["snippet_update_batch_id"]),
            (evidence["native_device_id"], evidence["native_snippet_update_batch_id"]),
        },
        "server batch ledger must contain each tested native/Web batch exactly once under its device",
    )
    _require(
        connection.execute(
            "SELECT count(*) FROM batch_receipts WHERE vault_id=%s", (vault_id,)
        ).fetchone()[0] == 8,
        "server batch ledger contains an unexpected extra batch receipt",
    )
    sync_audits = connection.execute(
        "SELECT actor_device_id, count(*) FROM audit_events "
        "WHERE scope_type='vault' AND scope_id=%s AND action='vault.sync_batch_committed' "
        "GROUP BY actor_device_id",
        (vault_id,),
    ).fetchall()
    _require(
        {row[0]: int(row[1]) for row in sync_audits}.get(evidence["native_device_id"], 0) >= 3
        and {row[0]: int(row[1]) for row in sync_audits}.get(evidence["web_device_id"], 0) >= 5,
        "server audit ledger omitted a tested native or Web sync batch commit",
    )
    _require(
        sum(int(row[1]) for row in sync_audits) == 8,
        "server sync audit ledger must contain exactly the eight tested batch commits",
    )

    ledger_documents: list[str] = []
    for table, predicate in (
        ("record_versions", "vault_id=%s"),
        ("record_heads", "vault_id=%s"),
        ("change_events", "vault_id=%s"),
        ("op_receipts", "vault_id=%s"),
        ("batch_receipts", "vault_id=%s"),
        ("audit_events", "scope_type='vault' AND scope_id=%s"),
    ):
        ledger_documents.extend(
            row[0]
            for row in connection.execute(
                f"SELECT to_jsonb(row_data)::text FROM {table} AS row_data WHERE {predicate}",
                (vault_id,),
            ).fetchall()
        )
    _require(
        not any(marker in "\n".join(ledger_documents) for marker in markers.values()),
        "a synthetic Host marker appeared in PostgreSQL Vault ledger storage",
    )

    pg_http_world.assert_secrets_not_in_local_files()
