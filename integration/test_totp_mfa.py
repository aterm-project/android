"""Black-box acceptance for password + TOTP/recovery-code MFA."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import time
import uuid
from pathlib import Path

import pytest

from conftest import ApiClient
from test_account_deletion import _db_path, _register_account


def _error_code(response) -> str | None:
    body = response.json() or {}
    return (body.get("error") or {}).get("code")


def _login(api: ApiClient, account: dict):
    return api.request(
        "POST",
        "/api/v1/auth/login",
        json_body={
            "username": account["username"],
            "login_verifier": account["login_verifier"],
            "device_id": account["device_id"],
        },
    )


def _totp(secret: str, step: int) -> str:
    key = base64.b32decode(secret)
    digest = hmac.new(key, step.to_bytes(8, "big"), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    number = int.from_bytes(digest[offset : offset + 4], "big") & 0x7FFFFFFF
    return f"{number % 1_000_000:06d}"


def _step() -> int:
    return int(time.time()) // 30


def _session_count(database: Path, account_id: str) -> int:
    with sqlite3.connect(database) as connection:
        return connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE user_id=?", (account_id,)
        ).fetchone()[0]


def _login_mfa(api: ApiClient, challenge_id: str, *, totp_code: str | None = None, recovery_code: str | None = None):
    body = {"challenge_id": challenge_id}
    if totp_code is not None:
        body["totp_code"] = totp_code
    if recovery_code is not None:
        body["recovery_code"] = recovery_code
    return api.request("POST", "/api/v1/auth/login/mfa", json_body=body)


def test_totp_enrollment_replay_single_use_and_recovery_login(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    assert account.get("account_id")
    database = _db_path(api)
    user = _register_account(
        api, f"totp-mfa-{uuid.uuid4().hex[:12]}@example.test", tmp_path, "totp-mfa"
    )
    starting_sessions = _session_count(database, user["account_id"])

    setup_response = api.request(
        "POST",
        "/api/v1/auth/mfa/totp/setup",
        token=user["access_token"],
        json_body={"current_login_verifier": user["login_verifier"]},
    )
    assert setup_response.status == 200, _error_code(setup_response)
    setup = setup_response.json()
    secret = setup["secret"]
    assert re.fullmatch(r"[A-Z2-7]{32}", secret)
    assert setup["provisioning_uri"].startswith("otpauth://totp/")
    assert re.search(r"(?:\?|&)secret=" + re.escape(secret) + r"(?:&|$)", setup["provisioning_uri"])
    assert setup["expires_at"].endswith("Z")

    # Confirm on the immediately previous time step, then use a fresh step for
    # each subsequent successful TOTP action without sleeping across a period.
    confirm_step = _step()
    confirmed = None
    for _ in range(3):
        confirm_step = _step()
        confirmed = api.request(
            "POST",
            "/api/v1/auth/mfa/totp/confirm",
            token=user["access_token"],
            json_body={
                "current_login_verifier": user["login_verifier"],
                "totp_code": _totp(secret, confirm_step - 1),
            },
        )
        if confirmed.status == 200:
            break
        assert confirmed.status == 401, _error_code(confirmed)
    assert confirmed is not None and confirmed.status == 200, _error_code(confirmed)
    initial_codes = confirmed.json()["recovery_codes"]
    assert len(initial_codes) == 10
    assert all(re.fullmatch(r"[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}", code) for code in initial_codes)

    # Confirmation used confirm_step - 1. Use the current step for rotation,
    # then reserve the next step for login; each remains distinct and inside
    # the server's ±1 validation window even when requests run back-to-back.
    rotate_step = confirm_step
    rotated = api.request(
        "POST",
        "/api/v1/auth/mfa/recovery-codes",
        token=user["access_token"],
        json_body={
            "current_login_verifier": user["login_verifier"],
            "totp_code": _totp(secret, rotate_step),
        },
    )
    assert rotated.status == 200, _error_code(rotated)
    recovery_codes = rotated.json()["recovery_codes"]
    assert len(recovery_codes) == 10 and len(set(recovery_codes)) == 10
    assert set(recovery_codes).isdisjoint(initial_codes)

    status = api.request("GET", "/api/v1/auth/mfa", token=user["access_token"])
    assert status.status == 200
    assert status.json() == {"enabled": True, "recovery_codes_remaining": 10}

    # A consumed step cannot be replayed to a different step-up action.
    replay_disable = api.request(
        "DELETE",
        "/api/v1/auth/mfa/totp",
        token=user["access_token"],
        json_body={
            "current_login_verifier": user["login_verifier"],
            "totp_code": _totp(secret, rotate_step),
        },
    )
    assert replay_disable.status == 401 and _error_code(replay_disable) == "REAUTH_REQUIRED"
    assert api.request("GET", "/api/v1/auth/mfa", token=user["access_token"]).json() == {
        "enabled": True,
        "recovery_codes_remaining": 10,
    }

    login_challenge = _login(api, user)
    assert login_challenge.status == 202, _error_code(login_challenge)
    challenge = login_challenge.json()
    assert set(challenge) == {"mfa_required", "challenge_id", "expires_at", "methods"}
    assert challenge["mfa_required"] is True
    assert challenge["methods"] == ["totp", "recovery_code"]
    assert challenge["expires_at"].endswith("Z")
    assert _session_count(database, user["account_id"]) == starting_sessions
    with sqlite3.connect(database) as connection:
        challenge_row = connection.execute(
            "SELECT user_id,device_id,credential_version,attempt_count,consumed_at "
            "FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
            (hashlib.sha256(challenge["challenge_id"].encode()).hexdigest(),),
        ).fetchone()
        current_version = connection.execute(
            "SELECT credential_version FROM auth_credentials WHERE user_id=?",
            (user["account_id"],),
        ).fetchone()[0]
    assert challenge_row == (user["account_id"], user["device_id"], current_version, 0, None)

    login_step = rotate_step + 1
    authenticated = _login_mfa(
        api, challenge["challenge_id"], totp_code=_totp(secret, login_step)
    )
    assert authenticated.status == 200, _error_code(authenticated)
    session = authenticated.json()
    assert {"account_id", "device_id", "access_token", "refresh_token", "expires_in", "vaults"} == set(session)
    assert session["device_id"] == user["device_id"]
    assert _session_count(database, user["account_id"]) == starting_sessions + 1

    replay_challenge = _login(api, user)
    assert replay_challenge.status == 202
    replayed = _login_mfa(
        api, replay_challenge.json()["challenge_id"], totp_code=_totp(secret, login_step)
    )
    assert replayed.status == 401 and _error_code(replayed) == "AUTH_REQUIRED"
    with sqlite3.connect(database) as connection:
        attempts, consumed_at = connection.execute(
            "SELECT attempt_count,consumed_at FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
            (hashlib.sha256(replay_challenge.json()["challenge_id"].encode()).hexdigest(),),
        ).fetchone()
    assert attempts == 1 and consumed_at is None

    # Rotation invalidated the first set, and a recovery code can complete the
    # same password challenge after an invalid or replayed factor attempt.
    recovered = _login_mfa(
        api,
        replay_challenge.json()["challenge_id"],
        recovery_code=recovery_codes[0].lower(),
    )
    assert recovered.status == 200, _error_code(recovered)
    reuse_challenge = _login(api, user)
    assert reuse_challenge.status == 202
    reused = _login_mfa(
        api, reuse_challenge.json()["challenge_id"], recovery_code=recovery_codes[0]
    )
    assert reused.status == 401 and _error_code(reused) == "AUTH_REQUIRED"

    # Password recovery codes remain a usable second factor when the operator
    # key is absent, while TOTP and setup fail closed with a safe 503.
    if not api.started_by_suite or not api.server_env:
        pytest.skip("MFA key outage acceptance requires the suite-owned disposable server")
    setup_only_account = _register_account(
        api,
        f"totp-key-outage-{uuid.uuid4().hex[:12]}@example.test",
        tmp_path,
        "totp-key-outage",
    )
    env = api.server_env
    key_path = env.pop("ATERMIUS_MFA_ENCRYPTION_KEY_FILE")
    api.stop_managed_server()
    try:
        api.start_managed_server()
        setup_without_key = api.request(
            "POST",
            "/api/v1/auth/mfa/totp/setup",
            token=setup_only_account["access_token"],
            json_body={"current_login_verifier": setup_only_account["login_verifier"]},
        )
        assert setup_without_key.status == 503
        assert _error_code(setup_without_key) == "MFA_KEY_UNAVAILABLE"

        challenge_without_key = _login(api, user)
        assert challenge_without_key.status == 202
        before_outage_attempt = _session_count(database, user["account_id"])
        unavailable_totp = _login_mfa(
            api,
            challenge_without_key.json()["challenge_id"],
            totp_code=_totp(secret, _step() + 1),
        )
        assert unavailable_totp.status == 503
        assert _error_code(unavailable_totp) == "MFA_KEY_UNAVAILABLE"
        with sqlite3.connect(database) as connection:
            outage_attempts, outage_consumed = connection.execute(
                "SELECT attempt_count,consumed_at FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
                (hashlib.sha256(challenge_without_key.json()["challenge_id"].encode()).hexdigest(),),
            ).fetchone()
        assert outage_attempts == 0 and outage_consumed is None
        recovered_without_key = _login_mfa(
            api,
            challenge_without_key.json()["challenge_id"],
            recovery_code=recovery_codes[1],
        )
        assert recovered_without_key.status == 200, _error_code(recovered_without_key)
        assert _session_count(database, user["account_id"]) == before_outage_attempt + 1
    finally:
        api.stop_managed_server()
        env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = key_path
        api.start_managed_server()

    with sqlite3.connect(database) as connection:
        enabled, remaining = connection.execute(
            "SELECT (SELECT COUNT(*) FROM auth_mfa WHERE user_id=? AND enabled_at IS NOT NULL), "
            "(SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=? AND consumed_at IS NULL)",
            (user["account_id"], user["account_id"]),
        ).fetchone()
    assert enabled == 1 and remaining == 8

    # Server-side tables contain only the encrypted seed and salted hashes.
    database_artifacts = [database, Path(str(database) + "-wal"), Path(str(database) + "-shm")]
    persisted = b"".join(path.read_bytes() for path in database_artifacts if path.exists())
    assert secret.encode() not in persisted
    assert all(code.encode() not in persisted for code in initial_codes + recovery_codes)
    with sqlite3.connect(database) as connection:
        stored_seed, code_hashes = connection.execute(
            "SELECT m.totp_seed_envelope,group_concat(c.code_hash, ',') "
            "FROM auth_mfa m JOIN auth_mfa_recovery_codes c ON c.user_id=m.user_id "
            "WHERE m.user_id=? GROUP BY m.user_id",
            (user["account_id"],),
        ).fetchone()
    assert secret not in stored_seed
    assert all(code.replace("-", "") not in code_hashes for code in recovery_codes)

    audit_response = api.request(
        "GET", "/api/v1/audit?limit=200", token=user["access_token"]
    )
    assert audit_response.status == 200, _error_code(audit_response)
    audit_events = audit_response.json()["events"]
    audited_mfa = [
        event
        for event in audit_events
        if event["action"]
        in {
            "auth.mfa_login_challenge_created",
            "auth.mfa_totp_enabled",
            "auth.mfa_recovery_codes_rotated",
        }
    ]
    required_actions = {
        "auth.mfa_login_challenge_created",
        "auth.mfa_totp_enabled",
        "auth.mfa_recovery_codes_rotated",
    }
    assert required_actions <= {event["action"] for event in audited_mfa}
    expected_event_keys = {
        "event_id",
        "scope",
        "vault_id",
        "actor_user_id",
        "actor_device_id",
        "action",
        "resource_type",
        "resource_id",
        "result",
        "occurred_at",
        "source",
    }
    assert all(set(event) == expected_event_keys for event in audited_mfa)
    assert all(
        event["scope"] == "account"
        and event["vault_id"] is None
        and event["actor_user_id"] == user["account_id"]
        and event["resource_type"] == "account"
        and event["resource_id"] == user["account_id"]
        and event["result"] == "success"
        and event["source"] == "api"
        for event in audited_mfa
    )
    serialized_mfa_events = json.dumps(audited_mfa, sort_keys=True)
    sensitive_markers = [
        secret,
        user["username"],
        user["login_verifier"],
        *initial_codes,
        *recovery_codes,
        challenge["challenge_id"],
        replay_challenge.json()["challenge_id"],
        reuse_challenge.json()["challenge_id"],
        challenge_without_key.json()["challenge_id"],
        authenticated.json()["access_token"],
        authenticated.json()["refresh_token"],
        recovered.json()["access_token"],
        recovered.json()["refresh_token"],
    ]
    assert all(marker not in serialized_mfa_events for marker in sensitive_markers)


def test_fifth_bad_factor_consumes_challenge_and_rate_limit_counter_persists(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    assert account.get("account_id")
    database = _db_path(api)
    user = _register_account(
        api, f"totp-attempt-limit-{uuid.uuid4().hex[:12]}@example.test", tmp_path, "totp-attempt-limit"
    )
    setup = api.request(
        "POST",
        "/api/v1/auth/mfa/totp/setup",
        token=user["access_token"],
        json_body={"current_login_verifier": user["login_verifier"]},
    ).json()
    secret = setup["secret"]
    confirmed = None
    for _ in range(3):
        step = _step()
        confirmed = api.request(
            "POST",
            "/api/v1/auth/mfa/totp/confirm",
            token=user["access_token"],
            json_body={
                "current_login_verifier": user["login_verifier"],
                "totp_code": _totp(secret, step - 1),
            },
        )
        if confirmed.status == 200:
            break
        assert confirmed.status == 401
    assert confirmed is not None and confirmed.status == 200

    challenge = _login(api, user)
    assert challenge.status == 202
    now_step = _step()
    valid_codes = {_totp(secret, step) for step in range(now_step - 1, now_step + 2)}
    bad_code = next(
        f"{number:06d}" for number in range(1_000_000) if f"{number:06d}" not in valid_codes
    )
    sessions_before = _session_count(database, user["account_id"])
    for attempt in range(1, 6):
        response = _login_mfa(api, challenge.json()["challenge_id"], totp_code=bad_code)
        assert response.status == 401 and _error_code(response) == "AUTH_REQUIRED"
        with sqlite3.connect(database) as connection:
            count, consumed_at = connection.execute(
                "SELECT attempt_count,consumed_at FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
                (hashlib.sha256(challenge.json()["challenge_id"].encode()).hexdigest(),),
            ).fetchone()
        assert count == attempt
    assert consumed_at is not None
    assert _session_count(database, user["account_id"]) == sessions_before

    sixth_attempt = _login_mfa(api, challenge.json()["challenge_id"], totp_code=bad_code)
    assert sixth_attempt.status == 401 and _error_code(sixth_attempt) == "AUTH_REQUIRED"
    with sqlite3.connect(database) as connection:
        count_after, = connection.execute(
            "SELECT attempt_count FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
            (hashlib.sha256(challenge.json()["challenge_id"].encode()).hexdigest(),),
        ).fetchone()
        persisted_limiter = connection.execute(
            "SELECT COUNT(*) FROM auth_rate_limits WHERE endpoint='mfa_login' AND scope='user' AND subject_hash<>''"
        ).fetchone()[0]
    assert count_after == 5
    assert persisted_limiter >= 1

    expired_id = str(uuid.uuid4())
    expired_hash = hashlib.sha256(expired_id.encode()).hexdigest()
    with sqlite3.connect(database) as connection:
        credential_version, = connection.execute(
            "SELECT credential_version FROM auth_credentials WHERE user_id=?",
            (user["account_id"],),
        ).fetchone()
        connection.execute(
            "INSERT INTO auth_mfa_login_challenges "
            "(challenge_id_hash,user_id,device_id,credential_version,expires_at) "
            "VALUES(?,?,?,?,?)",
            (
                expired_hash,
                user["account_id"],
                user["device_id"],
                credential_version,
                int(time.time()) - 1,
            ),
        )
    expired = _login_mfa(
        api, expired_id, recovery_code=confirmed.json()["recovery_codes"][0]
    )
    assert expired.status == 401 and _error_code(expired) == "AUTH_REQUIRED"
    assert _session_count(database, user["account_id"]) == sessions_before
    with sqlite3.connect(database) as connection:
        expired_attempts, expired_consumed = connection.execute(
            "SELECT attempt_count,consumed_at FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
            (expired_hash,),
        ).fetchone()
    assert expired_attempts == 0 and expired_consumed is None

    # Seed five valid, unexpired challenge rows to exercise the server-side
    # cap without exhausting the independent password-login bucket first.
    stale_id = str(uuid.uuid4())
    outstanding_ids = [stale_id] + [str(uuid.uuid4()) for _ in range(4)]
    stale_hash = hashlib.sha256(stale_id.encode()).hexdigest()
    expires_at = int(time.time()) + 300
    with sqlite3.connect(database) as connection:
        credential_version, = connection.execute(
            "SELECT credential_version FROM auth_credentials WHERE user_id=?",
            (user["account_id"],),
        ).fetchone()
        for challenge_id in outstanding_ids:
            connection.execute(
                "INSERT INTO auth_mfa_login_challenges "
                "(challenge_id_hash,user_id,device_id,credential_version,expires_at) "
                "VALUES(?,?,?,?,?)",
                (
                    hashlib.sha256(challenge_id.encode()).hexdigest(),
                    user["account_id"],
                    user["device_id"],
                    credential_version,
                    expires_at,
                ),
            )
    over_cap = _login(api, user)
    assert over_cap.status == 429 and int(over_cap.headers["retry-after"]) >= 1
    with sqlite3.connect(database) as connection:
        active_count = connection.execute(
            "SELECT COUNT(*) FROM auth_mfa_login_challenges "
            "WHERE user_id=? AND consumed_at IS NULL AND expires_at>?",
            (user["account_id"], int(time.time())),
        ).fetchone()[0]
    assert active_count == 5

    # A server-side credential rotation invalidates a previously issued
    # challenge even though its password proof and second factor are valid.
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE auth_mfa_login_challenges SET credential_version=? WHERE challenge_id_hash=?",
            (credential_version + 1, stale_hash),
        )
    stale = _login_mfa(api, stale_id, recovery_code=confirmed.json()["recovery_codes"][0])
    assert stale.status == 401 and _error_code(stale) == "AUTH_REQUIRED"
    with sqlite3.connect(database) as connection:
        stale_attempts, stale_consumed = connection.execute(
            "SELECT attempt_count,consumed_at FROM auth_mfa_login_challenges WHERE challenge_id_hash=?",
            (stale_hash,),
        ).fetchone()
    assert stale_attempts == 0 and stale_consumed is not None


def test_totp_enable_disable_audit_events_contain_metadata_only(
    api: ApiClient,
    account: dict,
    writable_server: None,
    tmp_path: Path,
) -> None:
    assert account.get("account_id")
    user = _register_account(
        api,
        f"totp-audit-{uuid.uuid4().hex[:12]}@example.test",
        tmp_path,
        "totp-audit",
    )
    setup = api.request(
        "POST",
        "/api/v1/auth/mfa/totp/setup",
        token=user["access_token"],
        json_body={"current_login_verifier": user["login_verifier"]},
    )
    assert setup.status == 200, _error_code(setup)
    secret = setup.json()["secret"]

    confirmed = None
    confirm_step = _step()
    for _ in range(3):
        confirm_step = _step()
        confirmed = api.request(
            "POST",
            "/api/v1/auth/mfa/totp/confirm",
            token=user["access_token"],
            json_body={
                "current_login_verifier": user["login_verifier"],
                "totp_code": _totp(secret, confirm_step - 1),
            },
        )
        if confirmed.status == 200:
            break
        assert confirmed.status == 401 and _error_code(confirmed) == "REAUTH_REQUIRED"
    assert confirmed is not None and confirmed.status == 200, _error_code(confirmed)
    recovery_codes = confirmed.json()["recovery_codes"]

    disabled = api.request(
        "DELETE",
        "/api/v1/auth/mfa/totp",
        token=user["access_token"],
        json_body={
            "current_login_verifier": user["login_verifier"],
            "totp_code": _totp(secret, _step() + 1),
        },
    )
    assert disabled.status == 200, _error_code(disabled)
    assert disabled.json() == {"enabled": False, "recovery_codes_remaining": 0}

    audit = api.request(
        "GET", "/api/v1/audit?limit=200", token=user["access_token"]
    )
    assert audit.status == 200, _error_code(audit)
    actions = {
        "auth.mfa_totp_enabled",
        "auth.mfa_totp_disabled",
    }
    events = [event for event in audit.json()["events"] if event["action"] in actions]
    assert {event["action"] for event in events} == actions
    expected_event_keys = {
        "event_id",
        "scope",
        "vault_id",
        "actor_user_id",
        "actor_device_id",
        "action",
        "resource_type",
        "resource_id",
        "result",
        "occurred_at",
        "source",
    }
    assert all(set(event) == expected_event_keys for event in events)
    assert all(
        event["scope"] == "account"
        and event["vault_id"] is None
        and event["actor_user_id"] == user["account_id"]
        and event["actor_device_id"] == user["device_id"]
        and event["resource_type"] == "account"
        and event["resource_id"] == user["account_id"]
        and event["result"] == "success"
        and event["source"] == "api"
        for event in events
    )
    serialized = json.dumps(events, sort_keys=True)
    assert all(
        marker not in serialized
        for marker in [
            secret,
            user["username"],
            user["login_verifier"],
            user["access_token"],
            *recovery_codes,
        ]
    )
