"""Black-box acceptance for bounded account-invitation history retention."""

from __future__ import annotations

import datetime as dt
import hashlib
import sqlite3
import subprocess
import uuid

import pytest

from conftest import ROOT, server_binary_path
from test_account_deletion import _db_path


def _issue(api, token: str, username: str, ttl: int):
    return api.request(
        "POST",
        "/api/v1/admin/account-invitations",
        token=token,
        json_body={"username": username, "expires_in_seconds": ttl},
    )


def _run_invitation_maintenance(api, retention_days: int) -> subprocess.CompletedProcess[str]:
    if not api.admin_env:
        pytest.skip("invitation retention acceptance needs the suite-owned SQLite server")
    executable = server_binary_path()
    command = (
        [str(executable), "maintenance"]
        if executable.is_file()
        else [
            "cargo",
            "run",
            "--quiet",
            "--locked",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            "maintenance",
        ]
    )
    environment = api.admin_env.copy()
    environment["ATERMIUS_AUDIT_RETENTION_DAYS"] = str(retention_days)
    return subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def test_maintenance_prunes_terminal_invitation_history_in_bounded_passes(api, account):
    if not api.admin_env or not api.temp_root:
        pytest.skip("invitation retention acceptance needs the suite-owned disposable server")

    admin_token = account["access_token"]
    db_path = _db_path(api)
    before = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=100", token=admin_token
    )
    assert before.status == 200
    baseline_total = before.json()["total"]

    audited = _issue(
        api,
        admin_token,
        f"retention-audit-{uuid.uuid4().hex}@example.test",
        2_592_000,
    )
    assert audited.status == 201
    audited_invitation_id = audited.json()["invitation"]["invitation_id"]
    now = dt.datetime.now(dt.timezone.utc)
    old = (now - dt.timedelta(days=3)).isoformat()
    cutoff = (now - dt.timedelta(days=1)).isoformat()
    recently_terminal = (now - dt.timedelta(hours=12)).isoformat()
    future = (now + dt.timedelta(days=7)).isoformat()
    created_old = (now - dt.timedelta(days=400)).isoformat()

    stale_rows = []
    for index in range(2500):
        invitation_id = str(uuid.uuid4())
        category = index % 3
        consumed_at = old if category == 0 else None
        revoked_at = old if category == 1 else None
        expires_at = old if category == 2 else future
        stale_rows.append(
            (
                invitation_id,
                hashlib.sha256(f"stale-{index}-{uuid.uuid4()}".encode()).hexdigest(),
                f"old-{index}-{uuid.uuid4().hex}@example.test",
                created_old,
                expires_at,
                consumed_at,
                revoked_at,
            )
        )

    retained_ids = {
        "recently-consumed": str(uuid.uuid4()),
        "recently-revoked": str(uuid.uuid4()),
        "recently-expired": str(uuid.uuid4()),
        "pending": str(uuid.uuid4()),
    }
    retained_rows = [
        (
            retained_ids["recently-consumed"],
            hashlib.sha256(uuid.uuid4().bytes).hexdigest(),
            "recently-consumed@example.test",
            created_old,
            future,
            recently_terminal,
            None,
        ),
        (
            retained_ids["recently-revoked"],
            hashlib.sha256(uuid.uuid4().bytes).hexdigest(),
            "recently-revoked@example.test",
            created_old,
            future,
            None,
            recently_terminal,
        ),
        (
            retained_ids["recently-expired"],
            hashlib.sha256(uuid.uuid4().bytes).hexdigest(),
            "recently-expired@example.test",
            created_old,
            recently_terminal,
            None,
            None,
        ),
        (
            retained_ids["pending"],
            hashlib.sha256(uuid.uuid4().bytes).hexdigest(),
            "pending-retained@example.test",
            created_old,
            future,
            None,
            None,
        ),
    ]

    with sqlite3.connect(db_path) as database:
        database.execute(
            "UPDATE account_invitations SET consumed_at=? WHERE invitation_id=?",
            (old, audited_invitation_id),
        )
        database.executemany(
            "INSERT INTO account_invitations("
            "invitation_id,token_hash,username,created_at,expires_at,consumed_at,revoked_at"
            ") VALUES(?,?,?,?,?,?,?)",
            stale_rows,
        )
        database.executemany(
            "INSERT INTO account_invitations("
            "invitation_id,token_hash,username,created_at,expires_at,consumed_at,revoked_at"
            ") VALUES(?,?,?,?,?,?,?)",
            retained_rows,
        )
        audit_event_id = database.execute(
            "SELECT MAX(event_id) FROM audit_events "
            "WHERE action='instance.account_invitation_issued'"
        ).fetchone()[0]
        stale_count = database.execute(
            "SELECT COUNT(*) FROM account_invitations WHERE "
            "(consumed_at IS NOT NULL AND consumed_at < ?) OR "
            "(revoked_at IS NOT NULL AND revoked_at < ?) OR "
            "(consumed_at IS NULL AND revoked_at IS NULL AND expires_at < ?)",
            (cutoff, cutoff, cutoff),
        ).fetchone()[0]
    assert stale_count == 2501

    first_pass = _run_invitation_maintenance(api, retention_days=1)
    assert first_pass.returncode == 0, first_pass.stderr
    after_first = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=100", token=admin_token
    )
    assert after_first.status == 200
    assert after_first.json()["total"] == baseline_total + 505
    with sqlite3.connect(db_path) as database:
        assert database.execute(
            "SELECT COUNT(*) FROM audit_events WHERE event_id=?", (audit_event_id,)
        ).fetchone()[0] == 1

    second_pass = _run_invitation_maintenance(api, retention_days=1)
    assert second_pass.returncode == 0, second_pass.stderr
    after_second = api.request(
        "GET", "/api/v1/admin/account-invitations?limit=100", token=admin_token
    )
    assert after_second.status == 200
    assert after_second.json()["total"] == baseline_total + 4
    listed = {item["invitation_id"]: item for item in after_second.json()["invitations"]}
    expected_statuses = {
        retained_ids["recently-consumed"]: "consumed",
        retained_ids["recently-revoked"]: "revoked",
        retained_ids["recently-expired"]: "expired",
        retained_ids["pending"]: "pending",
    }
    for invitation_id, expected_status in expected_statuses.items():
        assert listed[invitation_id]["status"] == expected_status
    assert audited_invitation_id not in listed
    with sqlite3.connect(db_path) as database:
        assert database.execute(
            "SELECT COUNT(*) FROM account_invitations WHERE "
            "(consumed_at IS NOT NULL AND consumed_at < ?) OR "
            "(revoked_at IS NOT NULL AND revoked_at < ?) OR "
            "(consumed_at IS NULL AND revoked_at IS NULL AND expires_at < ?)",
            (cutoff, cutoff, cutoff),
        ).fetchone()[0] == 0
        assert database.execute(
            "SELECT COUNT(*) FROM audit_events WHERE event_id=?", (audit_event_id,)
        ).fetchone()[0] == 1
