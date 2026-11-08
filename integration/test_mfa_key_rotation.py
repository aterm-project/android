"""Black-box acceptance for the offline MFA seed encryption key rotation CLI."""

from __future__ import annotations

import base64
import json
import os
import sqlite3
import tempfile
from pathlib import Path

from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_encrypt,
)

from conftest import ROOT
from test_backup_cli import (
    _free_port,
    _isolated_env,
    _run_cli,
    _server_binary,
    _start_server,
    _stop_server,
)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _envelope(key: bytes, user_id: str, seed: bytes) -> str:
    nonce = os.urandom(24)
    aad = b"atermius/mfa-totp-seed/v1\0" + user_id.encode("utf-8")
    ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(seed, aad, nonce, key)
    return json.dumps(
        {"version": 1, "nonce": _b64url(nonce), "ciphertext": _b64url(ciphertext)},
        separators=(",", ":"),
    )


def _write_key(path: Path, key: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as key_file:
        key_file.write(key)
        key_file.flush()
        os.fsync(key_file.fileno())


def _mfa_snapshot(database_path: Path) -> tuple[list[tuple], list[tuple]]:
    with sqlite3.connect(database_path) as db:
        mfa = db.execute(
            "SELECT user_id,totp_seed_envelope,enabled_at,last_totp_step,"
            "pending_seed_envelope,pending_expires_at,pending_credential_version "
            "FROM auth_mfa ORDER BY user_id"
        ).fetchall()
        recovery = db.execute(
            "SELECT code_id,user_id,salt,code_hash,created_at,consumed_at "
            "FROM auth_mfa_recovery_codes ORDER BY code_id"
        ).fetchall()
    return mfa, recovery


def _insert_test_mfa_state(database_path: Path, old_key: bytes) -> dict[tuple[str, str], bytes]:
    user_seeds = {
        "rotation-active-user": (bytes(range(20)), bytes(range(20, 40))),
        "rotation-pending-user": (None, bytes(range(40, 60))),
    }
    with sqlite3.connect(database_path) as db:
        for user_id, (active_seed, pending_seed) in user_seeds.items():
            db.execute(
                "INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)",
                (user_id, f"{user_id}@example.test", "2026-01-01T00:00:00Z"),
            )
            db.execute(
                "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step,"
                "pending_seed_envelope,pending_expires_at,pending_credential_version) "
                "VALUES(?,?,?,?,?,?,?)",
                (
                    user_id,
                    _envelope(old_key, user_id, active_seed) if active_seed else None,
                    100 if active_seed else None,
                    987 if active_seed else None,
                    _envelope(old_key, user_id, pending_seed),
                    200,
                    3,
                ),
            )
        db.execute(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at,consumed_at) "
            "VALUES(?,?,?,?,?,?)",
            (
                "rotation-recovery-code",
                "rotation-active-user",
                "s" * 22,
                "h" * 64,
                100,
                None,
            ),
        )
    return {
        (user_id, seed_name): seed
        for user_id, (active, pending) in user_seeds.items()
        for seed_name, seed in (("active", active), ("pending", pending))
        if seed is not None
    }


def _decrypt_envelope(key: bytes, user_id: str, envelope_text: str) -> bytes:
    envelope = json.loads(envelope_text)
    nonce = base64.urlsafe_b64decode(envelope["nonce"] + "==")
    ciphertext = base64.urlsafe_b64decode(envelope["ciphertext"] + "==")
    aad = b"atermius/mfa-totp-seed/v1\0" + user_id.encode("utf-8")
    return crypto_aead_xchacha20poly1305_ietf_decrypt(ciphertext, aad, nonce, key)


def test_offline_mfa_key_rotation_is_atomic_and_preserves_non_envelope_state() -> None:
    executable = _server_binary()
    with tempfile.TemporaryDirectory(prefix="atermius-mfa-key-rotation-") as temp:
        data_dir = Path(temp) / "data"
        data_dir.mkdir(mode=0o700)
        os.chmod(data_dir, 0o700)
        database_path = data_dir / "atermius.db"
        old_key = bytes([0x35]) * 32
        wrong_key = bytes([0x19]) * 32
        new_key = bytes([0xA2]) * 32
        old_key_path = Path(temp) / "old-mfa.key"
        wrong_key_path = Path(temp) / "wrong-mfa.key"
        new_key_path = Path(temp) / "new-mfa.key"
        _write_key(old_key_path, old_key)
        _write_key(wrong_key_path, wrong_key)
        _write_key(new_key_path, new_key)

        port = _free_port()
        env = _isolated_env(data_dir, port)
        env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = str(old_key_path)
        base_url = f"http://127.0.0.1:{port}"
        log_path = Path(temp) / "server.log"
        process = None
        log_handle = None
        try:
            process, log_handle, _api = _start_server(
                executable, env, base_url, log_path, old_key.hex(), wrong_key.hex(), new_key.hex()
            )
            seeds = _insert_test_mfa_state(database_path, old_key)
            before_mfa, before_recovery = _mfa_snapshot(database_path)

            running_result = _run_cli(
                executable,
                env,
                "rotate-mfa-key",
                "--old-key-file",
                str(old_key_path),
                "--new-key-file",
                str(new_key_path),
                "--server-stopped",
            )
            assert running_result.returncode != 0
            assert "SERVER_RUNNING" in running_result.stderr + running_result.stdout
            assert _mfa_snapshot(database_path) == (before_mfa, before_recovery)
            _stop_server(process)
            process = None
            if log_handle:
                log_handle.close()
                log_handle = None

            wrong_key_result = _run_cli(
                executable,
                env,
                "rotate-mfa-key",
                "--old-key-file",
                str(wrong_key_path),
                "--new-key-file",
                str(new_key_path),
                "--server-stopped",
            )
            assert wrong_key_result.returncode != 0
            assert old_key.hex() not in wrong_key_result.stdout + wrong_key_result.stderr
            assert new_key.hex() not in wrong_key_result.stdout + wrong_key_result.stderr
            assert _mfa_snapshot(database_path) == (before_mfa, before_recovery)

            result = _run_cli(
                executable,
                env,
                "rotate-mfa-key",
                "--old-key-file",
                str(old_key_path),
                "--new-key-file",
                str(new_key_path),
                "--server-stopped",
            )
            assert result.returncode == 0, result.stderr[-4000:]
            assert "1 active and 2 pending" in result.stdout
            assert old_key.hex() not in result.stdout + result.stderr
            assert new_key.hex() not in result.stdout + result.stderr

            after_mfa, after_recovery = _mfa_snapshot(database_path)
            assert before_recovery == after_recovery
            before_by_user = {row[0]: row for row in before_mfa}
            after_by_user = {row[0]: row for row in after_mfa}
            assert before_by_user.keys() == after_by_user.keys()
            for user_id, before in before_by_user.items():
                after = after_by_user[user_id]
                assert before[2:4] == after[2:4]
                assert before[5:] == after[5:]
                for index, seed_name in ((1, "active"), (4, "pending")):
                    old_envelope = before[index]
                    new_envelope = after[index]
                    if old_envelope is None:
                        assert new_envelope is None
                        continue
                    assert new_envelope != old_envelope
                    assert _decrypt_envelope(new_key, user_id, new_envelope) == seeds[
                        (user_id, seed_name)
                    ]
                    try:
                        _decrypt_envelope(old_key, user_id, new_envelope)
                    except Exception:
                        pass
                    else:
                        raise AssertionError("rotated envelope still decrypts with the old key")
        finally:
            _stop_server(process)
            if log_handle:
                log_handle.close()
