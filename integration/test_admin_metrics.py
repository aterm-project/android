"""Black-box checks for the authenticated, aggregate-only Prometheus endpoint."""

from __future__ import annotations

import json
import re
import sqlite3
import uuid
from datetime import datetime
from contextlib import closing

import pytest

from test_account_deletion import _register_account


def test_admin_metrics_requires_allowlisted_session_and_emits_fixed_series(api, account, tmp_path):
    if not api.admin_env or not api.temp_root:
        pytest.skip("admin metrics acceptance needs the suite-owned disposable server")

    member = _register_account(
        api,
        f"instance-metrics-outsider-{uuid.uuid4().hex[:10]}@example.test",
        tmp_path,
        "instance-metrics-outsider",
    )

    assert api.request("GET", "/api/v1/admin/metrics").status == 401
    denied = api.request(
        "GET", "/api/v1/admin/metrics", token=member["access_token"]
    )
    assert denied.status == 403
    assert (denied.json().get("error") or {}).get("code") == "INSTANCE_ADMIN_REQUIRED"

    queue_fixtures = [
        (
            str(uuid.uuid4()),
            "pending",
            None,
            0,
            "metrics-object-key-pending-one",
            str(uuid.uuid4()),
        ),
        (
            str(uuid.uuid4()),
            "pending",
            None,
            0,
            "metrics-object-key-pending-two",
            str(uuid.uuid4()),
        ),
        (
            str(uuid.uuid4()),
            "retry_wait",
            "remote_unavailable",
            1,
            "metrics-object-key-retry",
            str(uuid.uuid4()),
        ),
        (
            str(uuid.uuid4()),
            "quarantined",
            "integrity_mismatch",
            2,
            "metrics-object-key-quarantined",
            str(uuid.uuid4()),
        ),
    ]
    # Keep due times in the future so the live maintenance worker cannot
    # consume synthetic rows while this black-box request is in progress.
    with closing(sqlite3.connect(api.temp_root / "data" / "atermius.db", timeout=15)) as db:
        with db:
            db.executemany(
                "INSERT INTO object_delete_queue(\
                 queue_id,storage_backend,storage_key,storage_store_id,expected_size,\
                 expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at\
                 ) VALUES(?,'filesystem',?,?,1,?,?,?,4102444800,?,'2099-01-01T00:00:00Z')",
                [
                    (
                        queue_id,
                        marker,
                        store_id,
                        "b" * 64,
                        queue_state,
                        attempt_count,
                        failure_category,
                    )
                    for queue_id, queue_state, failure_category, attempt_count, marker, store_id
                    in queue_fixtures
                ],
            )

    empty_backup_metrics = api.request(
        "GET", "/api/v1/admin/metrics", token=account["access_token"]
    )
    assert empty_backup_metrics.status == 200
    assert (
        "atermius_backup_last_success_timestamp_seconds 0\n"
        in empty_backup_metrics.body.decode("utf-8")
    )

    last_success_at = "2026-10-08T00:00:00.000Z"
    attempted_at = "2026-10-08T00:00:01.000Z"
    private_migration_version = 987654321
    private_archive_bytes = 987654321987654321
    backup_status = api.temp_root / "data" / "backup-status.json"
    backup_status.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "operation": "backup",
                "attempted_at": last_success_at,
                "result": "succeeded",
                "migration_version": private_migration_version,
                "archive_bytes": private_archive_bytes,
                "failure_category": None,
                "last_success_at": last_success_at,
            }
        ),
        encoding="utf-8",
    )
    backup_status.chmod(0o600)
    expected_backup_timestamp = int(
        datetime.fromisoformat(last_success_at.replace("Z", "+00:00")).timestamp()
    )
    successful_backup_metrics = api.request(
        "GET", "/api/v1/admin/metrics", token=account["access_token"]
    )
    assert successful_backup_metrics.status == 200
    successful_exposition = successful_backup_metrics.body.decode("utf-8")
    assert (
        f"atermius_backup_last_success_timestamp_seconds {expected_backup_timestamp}\n"
        in successful_exposition
    )
    assert str(private_migration_version) not in successful_exposition
    assert str(private_archive_bytes) not in successful_exposition

    backup_status.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "operation": "backup",
                "attempted_at": attempted_at,
                "result": "failed",
                "migration_version": None,
                "archive_bytes": None,
                "failure_category": "backup_failed",
                "last_success_at": last_success_at,
            }
        ),
        encoding="utf-8",
    )
    backup_status.chmod(0o600)

    response = api.request(
        "GET", "/api/v1/admin/metrics", token=account["access_token"]
    )
    assert response.status == 200
    assert response.headers.get_content_type() == "text/plain"
    assert "version=0.0.4" in response.headers.get("Content-Type", "")
    assert response.headers.get("Cache-Control") == "no-store"
    assert response.headers.get("X-Content-Type-Options") == "nosniff"

    exposition = response.body.decode("utf-8")
    expected_series = {
        'atermius_accounts{status="active"}',
        'atermius_accounts{status="deleting"}',
        'atermius_accounts{status="disabled"}',
        "atermius_devices_active",
        'atermius_vaults{state="active"}',
        'atermius_vaults{state="deleting"}',
        "atermius_blob_stored_bytes",
        "atermius_upload_reserved_bytes",
        'atermius_object_delete_queue{state="pending"}',
        'atermius_object_delete_queue{state="retry_wait"}',
        'atermius_object_delete_queue{state="quarantined"}',
        'atermius_mobile_push_send_results_total{provider="apns",outcome="accepted"}',
        'atermius_mobile_push_send_results_total{provider="apns",outcome="invalid_token"}',
        'atermius_mobile_push_send_results_total{provider="apns",outcome="retryable_failure"}',
        'atermius_mobile_push_send_results_total{provider="fcm_v1",outcome="accepted"}',
        'atermius_mobile_push_send_results_total{provider="fcm_v1",outcome="invalid_token"}',
        'atermius_mobile_push_send_results_total{provider="fcm_v1",outcome="retryable_failure"}',
        "atermius_backup_last_success_timestamp_seconds",
        "atermius_vault_quota_bytes",
        "atermius_ssh_relay_enabled",
    }
    sample_lines = [line for line in exposition.splitlines() if line and not line.startswith("#")]
    assert len(sample_lines) == len(expected_series)
    actual_series = set()
    sample_values = {}
    for line in sample_lines:
        match = re.fullmatch(r"(atermius_[a-z_]+(?:\{[^}\n]+\})?) ([0-9]+)", line)
        assert match, f"invalid or non-numeric Prometheus sample: {line!r}"
        actual_series.add(match.group(1))
        sample_values[match.group(1)] = int(match.group(2))
    assert actual_series == expected_series
    assert sample_values['atermius_object_delete_queue{state="pending"}'] == 2
    assert sample_values['atermius_object_delete_queue{state="retry_wait"}'] == 1
    assert sample_values['atermius_object_delete_queue{state="quarantined"}'] == 1
    assert (
        sample_values["atermius_backup_last_success_timestamp_seconds"]
        == expected_backup_timestamp
    )
    metric_families = {series.split("{", 1)[0] for series in expected_series}
    help_families = {
        line.split(" ", 3)[2]
        for line in exposition.splitlines()
        if line.startswith("# HELP ")
    }
    type_families = {
        line.split(" ", 3)[2]
        for line in exposition.splitlines()
        if line.startswith("# TYPE ")
    }
    assert help_families == type_families == metric_families
    expected_types = {
        family: "counter" if family == "atermius_mobile_push_send_results_total" else "gauge"
        for family in metric_families
    }
    actual_types = {
        line.split(" ", 3)[2]: line.split(" ", 3)[3]
        for line in exposition.splitlines()
        if line.startswith("# TYPE ")
    }
    assert actual_types == expected_types
    assert "reset on process restart" in exposition
    assert "not device receipt or sync" in exposition

    # These gauges use fixed label values only; no account, device, Vault,
    # host, request or caller-controlled identifiers enter the scrape output.
    serialized = exposition.lower()
    for forbidden in (
        "username",
        "vault_id",
        "device_id",
        "hostname",
        "host_id",
        "host_name",
        "request_id",
        "envelope",
        "provider-error-secret-marker",
        attempted_at,
        str(private_migration_version),
        str(private_archive_bytes),
        *[
            private_value
            for queue_id, _, _, _, marker, store_id in queue_fixtures
            for private_value in (queue_id, marker, store_id)
        ],
    ):
        assert forbidden not in serialized

    credential_path = "/api/v1/admin/metrics-credential"
    status = api.request("GET", credential_path, token=account["access_token"])
    assert status.status == 200
    assert status.json().get("active") is False
    assert status.json().get("updated_at") is None

    first_rotation = api.request(
        "POST", credential_path, token=account["access_token"]
    )
    assert first_rotation.status == 200
    first_body = first_rotation.json()
    assert set(first_body) == {"credential", "created_at"}
    first_credential = first_body.get("credential")
    if not isinstance(first_credential, str) or not re.fullmatch(
        r"atm_[A-Za-z0-9_-]{43}", first_credential
    ):
        pytest.fail("scrape rotation returned an invalid credential shape")
    assert isinstance(first_body.get("created_at"), str)

    scrape = api.request("GET", "/api/v1/admin/metrics", token=first_credential)
    assert scrape.status == 200
    assert scrape.body.decode("utf-8") == exposition
    assert scrape.headers.get("Cache-Control") == "no-store"

    # The synthetic filesystem rows would correctly fail the server's startup
    # object-store identity check (this test server uses the SQLite backend).
    # Remove them after verifying the aggregate values and before restart tests.
    with closing(sqlite3.connect(api.temp_root / "data" / "atermius.db", timeout=15)) as db:
        with db:
            db.executemany(
                "DELETE FROM object_delete_queue WHERE queue_id=?",
                [(queue_id,) for queue_id, *_ in queue_fixtures],
            )

    credential_scope = api.request(
        "GET", "/api/v1/admin/overview", token=first_credential
    )
    assert credential_scope.status == 401
    assert (credential_scope.json().get("error") or {}).get("code") == "AUTH_REQUIRED"
    for method, raw_body in (("POST", b"{}"), ("DELETE", b"unexpected")):
        invalid_body = api.request(
            method,
            credential_path,
            token=account["access_token"],
            raw_body=raw_body,
            content_type="application/json",
        )
        assert invalid_body.status == 400
        assert (invalid_body.json().get("error") or {}).get("code") == "INVALID_REQUEST"
        assert api.request(
            "GET", "/api/v1/admin/metrics", token=first_credential
        ).status == 200

    if api.started_by_suite:
        api.stop_managed_server()
        api.start_managed_server()
    restarted_status = api.request(
        "GET", credential_path, token=account["access_token"]
    )
    assert restarted_status.status == 200
    assert restarted_status.json().get("active") is True
    assert api.request(
        "GET", "/api/v1/admin/metrics", token=first_credential
    ).status == 200

    second_rotation = api.request(
        "POST", credential_path, token=account["access_token"]
    )
    assert second_rotation.status == 200
    second_credential = second_rotation.json().get("credential")
    if not isinstance(second_credential, str) or not re.fullmatch(
        r"atm_[A-Za-z0-9_-]{43}", second_credential
    ):
        pytest.fail("scrape rotation returned an invalid credential shape")
    assert api.request(
        "GET", "/api/v1/admin/metrics", token=first_credential
    ).status == 401
    assert api.request(
        "GET", "/api/v1/admin/metrics", token=second_credential
    ).status == 200

    revoked = api.request(
        "DELETE", credential_path, token=account["access_token"]
    )
    assert revoked.status == 200
    assert revoked.json() == {"revoked": True}
    final_status = api.request(
        "GET", credential_path, token=account["access_token"]
    )
    assert final_status.status == 200
    assert final_status.json().get("active") is False
    assert api.request(
        "GET", "/api/v1/admin/metrics", token=second_credential
    ).status == 401
