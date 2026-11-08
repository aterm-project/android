"""Black-box coverage for the offline, old-key-authenticated instance rotation."""

from __future__ import annotations

import base64
import hashlib
import shutil
import subprocess

import pytest

from conftest import ROOT, ApiClient, jcs, redact_secrets, verify_ed25519, server_binary_path


def _run_cli(api: ApiClient, *arguments: str) -> subprocess.CompletedProcess[str]:
    executable = server_binary_path()
    if executable.is_file():
        command = [str(executable), *arguments]
    else:
        cargo = shutil.which("cargo")
        if not cargo:
            pytest.skip("instance key rotation requires Cargo or the debug server binary")
        command = [
            cargo,
            "run",
            "--quiet",
            "--manifest-path",
            str(ROOT / "server" / "Cargo.toml"),
            "--",
            *arguments,
        ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=api.admin_env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return result


def test_operator_rotates_instance_key_with_a_verifiable_transition(api: ApiClient) -> None:
    if not api.started_by_suite or not api.admin_env:
        pytest.skip("instance-key rotation requires a suite-owned disposable server")

    before_response = api.request("GET", "/api/v1/instance")
    assert before_response.status == 200
    before = before_response.json()
    assert isinstance(before.get("signing_public_key"), str)
    assert before.get("signing_public_key")
    assert before.get("signing_key_transitions") == []

    running = _run_cli(api, "rotate-instance-key", "--server-stopped")
    assert running.returncode != 0
    running_error = redact_secrets(running.stdout + "\n" + running.stderr)
    assert "SERVER_RUNNING" in running_error

    api.stop_managed_server()
    try:
        rotated = _run_cli(api, "rotate-instance-key", "--server-stopped")
        if rotated.returncode != 0:
            safe_output = redact_secrets(rotated.stdout + "\n" + rotated.stderr)
            pytest.fail(f"instance key rotation command failed: {safe_output[-2000:]}")
    finally:
        api.start_managed_server()

    after_response = api.request("GET", "/api/v1/instance")
    assert after_response.status == 200
    after = after_response.json()
    assert after["instance_id"] == before["instance_id"]
    assert after["server_space_id"] == before["server_space_id"]
    assert after["generation"] != before["generation"]
    assert after["signing_public_key"] != before["signing_public_key"]
    public_key_bytes = base64.urlsafe_b64decode(
        after["signing_public_key"] + "=" * (-len(after["signing_public_key"]) % 4)
    )
    fingerprint = base64.b64encode(hashlib.sha256(public_key_bytes).digest())
    fingerprint = fingerprint.decode("ascii").rstrip("=")
    assert f"New public-key fingerprint: SHA256:{fingerprint}" in rotated.stdout
    assert after["signing_public_key"] not in rotated.stdout

    chain = after["signing_key_transitions"]
    assert len(chain) == 1
    transition = chain[0]
    assert transition["format"] == "atermius-instance-key-transition-v1"
    assert transition["instance_id"] == before["instance_id"]
    assert transition["from_public_key"] == before["signing_public_key"]
    assert transition["to_public_key"] == after["signing_public_key"]
    unsigned = {key: value for key, value in transition.items() if key != "signature"}
    assert verify_ed25519(
        before["signing_public_key"], jcs(unsigned), transition["signature"]
    )

    # Restart persistence is part of the key transition contract, not just the
    # immediate response from an in-memory operator command.
    api.stop_managed_server()
    api.start_managed_server()
    persisted = api.request("GET", "/api/v1/instance").json()
    assert persisted["signing_public_key"] == after["signing_public_key"]
    assert persisted["signing_key_transitions"] == chain
