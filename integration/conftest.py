"""Black-box fixtures for a disposable Atermius server instance.

The suite has no HTTP client dependency: it uses urllib from the Python
standard library and pytest for collection/reporting.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[1]
_LONG_TOKEN = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])")


def server_binary_path(env: dict[str, str] | None = None) -> Path:
    """Return the debug server binary for Cargo's configured target directory."""
    variables = env if env is not None else os.environ
    target_dir = Path(variables.get("CARGO_TARGET_DIR") or ROOT / "server" / "target")
    if not target_dir.is_absolute():
        target_dir = ROOT / target_dir
    return target_dir / "debug" / "atermius-server"


def redact_secrets(text: str, *secrets: str | None) -> str:
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[REDACTED]")
    return _LONG_TOKEN.sub("[REDACTED_LONG_SECRET]", text)


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("atermius")
    group.addoption("--atermius-base-url", default=None, help="server URL (or ATERMIUS_BASE_URL)")
    group.addoption(
        "--atermius-server-command",
        default=None,
        help="command to start one disposable server for this pytest session",
    )
    group.addoption(
        "--atermius-bootstrap-token",
        default=None,
        help="one-time bootstrap secret from `atermius-server bootstrap`",
    )
    group.addoption(
        "--atermius-allow-mutations",
        action="store_true",
        help="allow writes against an externally supplied base URL; use a throwaway instance",
    )
    group.addoption("--atermius-startup-timeout", type=int, default=120)


@dataclass
class Response:
    status: int
    headers: Any
    body: bytes

    def json(self) -> Any:
        if not self.body:
            return None
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None


class ApiClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.started_by_suite = False

    def request(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        json_body: Any = None,
        raw_body: bytes | None = None,
        content_type: str | None = None,
    ) -> Response:
        headers = {"Accept": "application/json"}
        body = raw_body
        if json_body is not None:
            body = json.dumps(json_body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif content_type:
            headers["Content-Type"] = content_type
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(
            self.base_url + path,
            data=body,
            headers=headers,
            method=method.upper(),
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as result:
                return Response(result.status, result.headers, result.read())
        except urllib.error.HTTPError as error:
            return Response(error.code, error.headers, error.read())


class RedactedAccount(dict[str, Any]):
    """Dict-compatible fixture whose pytest failure representation omits credentials."""

    def __repr__(self) -> str:
        return (
            "<RedactedAccount "
            f"account_id={self.get('account_id')!r} "
            f"device_id={self.get('device_id')!r} "
            f"username={self.get('username')!r} credentials=[REDACTED]>"
        )


class SigningKey:
    """Minimal Ed25519 wrapper around the system OpenSSL command line."""

    def __init__(self, directory: Path, name: str):
        openssl = shutil.which("openssl")
        if not openssl:
            pytest.fail("openssl is required to make real Ed25519 signatures for the black-box fixtures")
        self.openssl = openssl
        self.private_path = directory / f"{name}-private.pem"
        self.public_der_path = directory / f"{name}-public.der"
        subprocess.run(
            [openssl, "genpkey", "-algorithm", "Ed25519", "-out", str(self.private_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            [openssl, "pkey", "-in", str(self.private_path), "-pubout", "-outform", "DER", "-out", str(self.public_der_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        der = self.public_der_path.read_bytes()
        # SubjectPublicKeyInfo for Ed25519 ends in the 32-byte raw public key.
        if len(der) < 32:
            pytest.fail("OpenSSL returned a malformed Ed25519 public key")
        self.public_key = der[-32:]

    def sign(self, message: bytes) -> bytes:
        with tempfile.NamedTemporaryFile(prefix="atermius-sign-") as src, tempfile.NamedTemporaryFile(
            prefix="atermius-sig-"
        ) as dst:
            src.write(message)
            src.flush()
            subprocess.run(
                [
                    self.openssl,
                    "pkeyutl",
                    "-sign",
                    "-rawin",
                    "-inkey",
                    str(self.private_path),
                    "-in",
                    src.name,
                    "-out",
                    dst.name,
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            dst.seek(0)
            return dst.read()


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def unb64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))


def verify_ed25519(public_key: str, message: bytes, signature: str) -> bool:
    """Verify a protocol Ed25519 signature through OpenSSL without crypto packages."""
    openssl = shutil.which("openssl")
    if not openssl:
        pytest.fail("openssl is required to verify Ed25519 signatures in black-box fixtures")
    with tempfile.TemporaryDirectory(prefix="atermius-verify-") as directory:
        root = Path(directory)
        # DER SubjectPublicKeyInfo prefix for an Ed25519 raw 32-byte public key.
        public_der = root / "public.der"
        public_der.write_bytes(bytes.fromhex("302a300506032b6570032100") + unb64url(public_key))
        message_path = root / "message.bin"
        message_path.write_bytes(message)
        signature_path = root / "signature.bin"
        signature_path.write_bytes(unb64url(signature))
        result = subprocess.run(
            [
                openssl,
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                str(public_der),
                "-keyform",
                "DER",
                "-rawin",
                "-in",
                str(message_path),
                "-sigfile",
                str(signature_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0


def jcs(value: Any) -> bytes:
    """Canonical JSON for the ASCII-keyed acceptance fixtures (RFC 8785 shape)."""
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def initial_vault(
    *, account_id: str, vault_id: str, device_id: str, encryption_public_key: str, signer: SigningKey
) -> dict[str, Any]:
    name_envelope = {"version": 1, "nonce": b64url(os.urandom(24)), "ciphertext": b64url(os.urandom(48))}
    envelope = {
        "version": 1,
        "suite": "crypto_box_seal",
        "ciphertext": b64url(os.urandom(48)),
    }
    key_envelope_unsigned = {
        "recipient_device_id": device_id,
        "key_epoch": 1,
        "membership_version": 1,
        "envelope": envelope,
    }
    key_envelope_payload = {"vault_id": vault_id, **key_envelope_unsigned}
    key_envelope = {
        **key_envelope_unsigned,
        "signature": b64url(signer.sign(jcs(key_envelope_payload))),
    }
    manifest_body = {
        "key_epoch": 1,
        "members": [
            {
                "user_id": account_id,
                "role": "owner",
                "state": "active",
                "encryption_key_fingerprint": b64url(
                    hashlib.sha256(unb64url(encryption_public_key)).digest()
                ),
            }
        ],
        "signer_device_id": device_id,
    }
    membership_unsigned = {
        "membership_version": 1,
        "previous_digest": None,
        "manifest": manifest_body,
    }
    membership_payload = {"vault_id": vault_id, **membership_unsigned}
    membership = {
        **membership_unsigned,
        "signature": b64url(signer.sign(jcs(membership_payload))),
    }
    return {
        "vault_id": vault_id,
        "name_envelope": name_envelope,
        "key_epoch": 1,
        "membership_version": 1,
        "key_envelope": key_envelope,
        "membership": membership,
    }


def prepare_web_root(temp_root: Path) -> tuple[Path, bool]:
    """Use the compiled Flutter Web bundle when available, otherwise a handler fixture."""
    compiled = ROOT / "apps" / "client" / "build" / "web"
    if (compiled / "index.html").is_file():
        return compiled, False

    fixture = temp_root / "web"
    fixture.mkdir(parents=True, exist_ok=True)
    (fixture / "index.html").write_text(
        "<!doctype html><html><head><title>Atermius acceptance fixture</title></head>"
        '<body><main id="app">static-handler-fixture</main><script src="/fixture.js"></script></body></html>',
        encoding="utf-8",
    )
    (fixture / "fixture.js").write_text("window.atermiusAcceptanceFixture = true;\n", encoding="utf-8")
    return fixture, True


# Keep related cases in one module on one disposable instance, while preventing
# unrelated modules from inheriting authentication buckets, durable admin
# jobs, scheduled work, and mutated Vault rows from earlier test groups.
@pytest.fixture(scope="module")
def api(pytestconfig: pytest.Config, tmp_path_factory: pytest.TempPathFactory):
    command = pytestconfig.getoption("--atermius-server-command") or os.environ.get("ATERMIUS_SERVER_COMMAND")
    base_url = pytestconfig.getoption("--atermius-base-url") or os.environ.get("ATERMIUS_BASE_URL")
    server_process: subprocess.Popen[bytes] | None = None
    log_handle = None
    temp_root: Path | None = None
    auto_bootstrap_token: str | None = None
    web_root: Path | None = None
    synthetic_web_fixture = False
    admin_env: dict[str, str] | None = None
    serve_command: list[str] | None = None
    server_log_path: Path | None = None
    server_env: dict[str, str] | None = None
    backup_archive_dir: Path | None = None
    backup_key_file: Path | None = None

    if command:
        if not base_url:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            base_url = f"http://127.0.0.1:{port}"
        temp_root = tmp_path_factory.mktemp("atermius-server")
        env = os.environ.copy()
        env["ATERMIUS_BIND"] = urllib.parse.urlparse(base_url).netloc
        env["ATERMIUS_DATA_DIR"] = str(temp_root / "data")
        data_dir = temp_root / "data"
        data_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.chmod(data_dir, 0o700)
        backup_archive_dir = temp_root / "backup-archives"
        backup_archive_dir.mkdir(mode=0o700)
        os.chmod(backup_archive_dir, 0o700)
        backup_key_file = temp_root / "operator-backup.key"
        backup_key_file.write_bytes(os.urandom(32))
        mfa_key_file = temp_root / "operator-mfa.key"
        mfa_key_file.write_bytes(os.urandom(32))
        if os.name == "posix":
            os.chmod(backup_key_file, 0o600)
            os.chmod(mfa_key_file, 0o600)
        env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = str(mfa_key_file)
        env["ATERMIUS_DATABASE_URL"] = f"sqlite://{temp_root / 'data' / 'atermius.db'}?mode=rwc"
        env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(backup_archive_dir)
        env["ATERMIUS_BACKUP_KEY_FILE"] = str(backup_key_file)
        env["ATERMIUS_REGISTRATION_OPEN"] = "false"
        env["ATERMIUS_RELAY_ENABLED"] = "false"
        env["ATERMIUS_ADMIN_USERNAMES"] = "atermius-integration-admin@example.test"
        env["ATERMIUS_PUBLIC_ORIGIN"] = base_url
        web_root, synthetic_web_fixture = prepare_web_root(temp_root)
        env["ATERMIUS_WEB_DIR"] = str(web_root)
        admin_env = env.copy()
        server_env = env.copy()
        serve_command = shlex.split(command)
        server_log_path = temp_root / "server.log"
        log_handle = server_log_path.open("wb")
        server_process = subprocess.Popen(
            serve_command,
            cwd=ROOT,
            env=env,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        client_started_by_suite = True
    elif not base_url:
        cargo_manifest = ROOT / "server" / "Cargo.toml"
        if cargo_manifest.exists() and os.environ.get("ATERMIUS_AUTO_START", "1") != "0":
            cargo = shutil.which("cargo")
            if not cargo:
                pytest.skip("server/Cargo.toml exists but cargo is not installed")
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            base_url = f"http://127.0.0.1:{port}"
            temp_root = tmp_path_factory.mktemp("atermius-server")
            env = os.environ.copy()
            env["ATERMIUS_BIND"] = f"127.0.0.1:{port}"
            env["ATERMIUS_DATA_DIR"] = str(temp_root / "data")
            data_dir = temp_root / "data"
            data_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
            os.chmod(data_dir, 0o700)
            backup_archive_dir = temp_root / "backup-archives"
            backup_archive_dir.mkdir(mode=0o700)
            os.chmod(backup_archive_dir, 0o700)
            backup_key_file = temp_root / "operator-backup.key"
            backup_key_file.write_bytes(os.urandom(32))
            mfa_key_file = temp_root / "operator-mfa.key"
            mfa_key_file.write_bytes(os.urandom(32))
            if os.name == "posix":
                os.chmod(backup_key_file, 0o600)
                os.chmod(mfa_key_file, 0o600)
            env["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] = str(mfa_key_file)
            env["ATERMIUS_DATABASE_URL"] = f"sqlite://{temp_root / 'data' / 'atermius.db'}?mode=rwc"
            env["ATERMIUS_BACKUP_ARCHIVE_DIR"] = str(backup_archive_dir)
            env["ATERMIUS_BACKUP_KEY_FILE"] = str(backup_key_file)
            env["ATERMIUS_REGISTRATION_OPEN"] = "false"
            env["ATERMIUS_RELAY_ENABLED"] = "false"
            env["ATERMIUS_ADMIN_USERNAMES"] = "atermius-integration-admin@example.test"
            env["ATERMIUS_PUBLIC_ORIGIN"] = base_url
            web_root, synthetic_web_fixture = prepare_web_root(temp_root)
            env["ATERMIUS_WEB_DIR"] = str(web_root)
            admin_env = env.copy()
            server_env = env.copy()
            bootstrap_run = subprocess.run(
                [cargo, "run", "--manifest-path", str(cargo_manifest), "--", "bootstrap"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=pytestconfig.getoption("--atermius-startup-timeout"),
            )
            if bootstrap_run.returncode != 0:
                pytest.fail(
                    "server bootstrap command failed:\n"
                    + redact_secrets(bootstrap_run.stdout + "\n" + bootstrap_run.stderr)[-6000:]
                )
            tokens = re.findall(r"[A-Za-z0-9_-]{40,}", bootstrap_run.stdout)
            token_lines = [line.strip() for line in bootstrap_run.stdout.splitlines() if line.strip()]
            if not tokens and not token_lines:
                pytest.fail("server bootstrap command succeeded without printing its one-time setup secret")
            # Bootstrap secrets are 32 random bytes encoded as unpadded base64url.
            secret = tokens[-1] if tokens else token_lines[-1].split()[-1].strip("`'\".,:")
            auto_bootstrap_token = secret
            # Bootstrap builds the executable above; run that process directly
            # so stop/restart integration cases wait on the actual HTTP server
            # PID instead of Cargo's parent process when reusing one SQLite DB.
            serve_binary = server_binary_path(env)
            if not serve_binary.is_file():
                pytest.fail("Cargo bootstrap did not produce the integration server executable")
            serve_command = [str(serve_binary), "serve"]
            server_log_path = temp_root / "server.log"
            log_handle = server_log_path.open("wb")
            server_process = subprocess.Popen(
                serve_command,
                cwd=ROOT,
                env=env,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            client_started_by_suite = True
        else:
            pytest.skip(
                "set ATERMIUS_SERVER_COMMAND to start a disposable server, or ATERMIUS_BASE_URL to target one"
            )
    else:
        client_started_by_suite = False

    client = ApiClient(base_url or "http://127.0.0.1:8080")
    client.started_by_suite = client_started_by_suite
    client.bootstrap_token = auto_bootstrap_token
    client.web_root = web_root
    client.synthetic_web_fixture = synthetic_web_fixture
    client.admin_env = admin_env
    client.temp_root = temp_root
    client.backup_archive_dir = backup_archive_dir
    client.backup_key_file = backup_key_file
    client.server_env = server_env

    def stop_managed_server() -> None:
        nonlocal server_process, log_handle
        if server_process is not None and server_process.poll() is None:
            try:
                os.killpg(server_process.pid, signal.SIGTERM)
            except (AttributeError, ProcessLookupError):
                server_process.terminate()
            try:
                server_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server_process.kill()
                server_process.wait(timeout=5)
        server_process = None
        if log_handle:
            log_handle.close()
            log_handle = None

    def start_managed_server() -> None:
        nonlocal server_process, log_handle
        if not client.started_by_suite or not serve_command or not server_env or not server_log_path:
            raise RuntimeError("server fixture does not own a restartable process")
        if server_process is not None and server_process.poll() is None:
            raise RuntimeError("managed server process is already running")
        log_handle = server_log_path.open("ab")
        server_process = subprocess.Popen(
            serve_command,
            cwd=ROOT,
            env=server_env,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        deadline = time.monotonic() + pytestconfig.getoption("--atermius-startup-timeout")
        last_failure = "server has not responded yet"
        while time.monotonic() < deadline:
            try:
                live = client.request("GET", "/health/live")
                ready = client.request("GET", "/health/ready")
                if live.status == 200 and ready.status == 200:
                    return
                last_failure = f"live={live.status}, ready={ready.status}"
            except (OSError, urllib.error.URLError) as error:
                last_failure = str(error)
            if server_process.poll() is not None:
                last_failure = f"server exited with code {server_process.returncode}"
                break
            time.sleep(0.25)
        details = ""
        if server_log_path.exists():
            details = redact_secrets(
                server_log_path.read_text(errors="replace"), auto_bootstrap_token
            )[-6000:]
        stop_managed_server()
        pytest.fail(f"restarted server did not become ready: {last_failure}\n{details}")

    client.stop_managed_server = stop_managed_server
    client.start_managed_server = start_managed_server
    timeout = pytestconfig.getoption("--atermius-startup-timeout")
    deadline = time.monotonic() + timeout
    last_failure = ""
    while True:
        try:
            live = client.request("GET", "/health/live")
            ready = client.request("GET", "/health/ready")
            if live.status == 200 and ready.status == 200:
                break
            last_failure = f"live={live.status}, ready={ready.status}"
        except (OSError, urllib.error.URLError) as error:
            last_failure = str(error)
        if server_process is not None and server_process.poll() is not None:
            last_failure = f"server exited with code {server_process.returncode}"
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.25)

    if last_failure and (server_process is None or server_process.poll() is not None or time.monotonic() >= deadline):
        details = ""
        if temp_root and (temp_root / "server.log").exists():
            details = redact_secrets(
                (temp_root / "server.log").read_text(errors="replace"), auto_bootstrap_token
            )[-6000:]
        if server_process is not None:
            server_process.terminate()
            server_process.wait(timeout=5)
        pytest.fail(f"server did not become ready within {timeout}s: {last_failure}\n{details}")

    try:
        yield client
    finally:
        if server_process is not None and server_process.poll() is None:
            try:
                os.killpg(server_process.pid, signal.SIGTERM)
            except (AttributeError, ProcessLookupError):
                server_process.terminate()
            try:
                server_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server_process.kill()
                server_process.wait(timeout=5)
        if log_handle:
            log_handle.close()


@pytest.fixture(scope="module")
def instance(api: ApiClient) -> dict[str, Any]:
    response = api.request("GET", "/api/v1/instance")
    assert response.status == 200, f"instance endpoint returned HTTP {response.status}: {response.json()}"
    body = response.json()
    assert isinstance(body, dict)
    assert body.get("instance_id") and body.get("server_space_id")
    assert body.get("generation") is not None
    return body


@pytest.fixture(scope="module")
def writable_server(api: ApiClient, pytestconfig: pytest.Config) -> None:
    started_by_suite = api.started_by_suite
    allowed = pytestconfig.getoption("--atermius-allow-mutations") or os.environ.get(
        "ATERMIUS_ALLOW_MUTATIONS"
    ) == "1"
    if not started_by_suite and not allowed:
        pytest.skip("mutating cases require a suite-started disposable server or --atermius-allow-mutations")


@pytest.fixture(scope="module")
def account(
    api: ApiClient,
    instance: dict[str, Any],
    writable_server: None,
    pytestconfig: pytest.Config,
    tmp_path_factory: pytest.TempPathFactory,
) -> dict[str, Any]:
    if not instance.get("setup_required"):
        pytest.fail("acceptance requires a fresh server database with setup_required=true")
    bootstrap = pytestconfig.getoption("--atermius-bootstrap-token") or getattr(api, "bootstrap_token", None) or os.environ.get(
        "ATERMIUS_BOOTSTRAP_TOKEN"
    )
    if not bootstrap:
        pytest.fail("set ATERMIUS_BOOTSTRAP_TOKEN to the one-time secret printed by `atermius-server bootstrap`")

    key_dir = tmp_path_factory.mktemp("atermius-acceptance-keys")
    signing_key = SigningKey(key_dir, "device-1")
    device_id = str(uuid.uuid4())
    account_id = str(uuid.uuid4())
    signing_public_key = b64url(signing_key.public_key)
    encryption_public_key = b64url(os.urandom(32))
    device_fields = {
        "device_id": device_id,
        "encryption_public_key": encryption_public_key,
        "signing_public_key": signing_public_key,
    }
    signed_device = {
        "account_id": account_id,
        **device_fields,
    }
    # The disposable integration instance allowlists this stable account for
    # black-box administration endpoint coverage.
    username = "atermius-integration-admin@example.test"
    vault_id = str(uuid.uuid4())
    login_verifier = b64url(os.urandom(32))
    envelope = {"version": 1, "nonce": b64url(os.urandom(24)), "ciphertext": b64url(os.urandom(48))}
    request_body = {
        "bootstrap_token": bootstrap,
        "account_id": account_id,
        "username": username,
        "kdf": {
            "id": "argon2id13",
            "salt": b64url(os.urandom(16)),
            "mem_kib": 65536,
            "iterations": 3,
            "parallelism": 1,
            "version": 1,
        },
        "login_verifier": login_verifier,
        "account_key_envelope": envelope,
        "device": {
            **device_fields,
            "name": "pytest-acceptance",
            "signature": b64url(signing_key.sign(jcs(signed_device))),
        },
        "initial_vault": initial_vault(
            account_id=account_id,
            vault_id=vault_id,
            device_id=device_id,
            encryption_public_key=encryption_public_key,
            signer=signing_key,
        ),
    }
    response = api.request("POST", "/api/v1/auth/register", json_body=request_body)
    body = response.json()
    assert response.status in (200, 201), (
        f"registration returned HTTP {response.status}: "
        f"{redact_secrets(response.body.decode('utf-8', errors='replace'), bootstrap)}"
    )
    assert isinstance(body, dict) and body.get("access_token") and body.get("refresh_token")
    assert body.get("account_id") == account_id, "server must adopt the client-generated account ID"
    vaults = body.get("vaults") or []
    assert vaults, f"registration did not create the personal vault: {body}"
    vault = vaults[0]
    returned_vault_id = vault.get("vault_id") or vault.get("id")
    assert returned_vault_id == vault_id, f"registration changed the client-generated vault ID: {vault}"
    return RedactedAccount({
        "username": username,
        "login_verifier": login_verifier,
        "account_id": body.get("account_id"),
        "device_id": body.get("device_id", device_id),
        "access_token": body["access_token"],
        "refresh_token": body["refresh_token"],
        "account_key_envelope": request_body["account_key_envelope"],
        "initial_vault": request_body["initial_vault"],
        "bootstrap_token": bootstrap,
        "vault": vault,
        "vault_id": vault_id,
        "signing_key": signing_key,
        "signing_public_key": signing_public_key,
        "encryption_public_key": encryption_public_key,
        "device_seq": 0,
        "record_ids": set(),
    })


@pytest.fixture(scope="module")
def make_envelope(instance: dict[str, Any], account: dict[str, Any]):
    def build(
        *,
        record_id: str | None = None,
        operation: str = "create",
        base_revision_id: str | None = None,
        revision_id: str | None = None,
        op_id: str | None = None,
        ciphertext: bytes | None = None,
    ) -> dict[str, Any]:
        account["device_seq"] += 1
        record_id = record_id or str(uuid.uuid4())
        revision_id = revision_id or str(uuid.uuid4())
        op_id = op_id or str(uuid.uuid4())
        account["record_ids"].add(record_id)
        vault = account["vault"]
        header = {
            "wire_version": 1,
            "server_space_id": instance["server_space_id"],
            "vault_id": account["vault_id"],
            "record_id": record_id,
            "revision_id": revision_id,
            "base_revision_id": base_revision_id,
            "op_id": op_id,
            "device_id": account["device_id"],
            "device_seq": str(account["device_seq"]),
            "key_epoch": str(vault.get("active_key_epoch", "1")),
            "membership_version": str(vault.get("membership_version", "1")),
            "record_schema": 1,
            "operation": operation,
            "crypto_suite": "atermius-vault-v1",
            "kdf_salt": b64url(os.urandom(32)),
        }
        nonce = b64url(os.urandom(24))
        sealed = b64url(ciphertext or os.urandom(64))
        signed = {"header": header, "nonce": nonce, "ciphertext": sealed}
        return {**signed, "signature": b64url(account["signing_key"].sign(jcs(signed)))}

    return build


@pytest.fixture(scope="module")
def push(api: ApiClient, instance: dict[str, Any], account: dict[str, Any]):
    def submit(*operations: dict[str, Any], batch_id: str | None = None) -> Response:
        # Generation recovery deliberately rotates the live server generation
        # inside IT-19. The module-scoped instance fixture is an identity
        # snapshot from suite startup, so read the current generation for each
        # write. Tests that need to assert stale-generation rejection construct
        # their request body explicitly.
        live_instance = api.request("GET", "/api/v1/instance")
        if live_instance.status != 200:
            raise AssertionError(
                f"instance lookup before push returned HTTP {live_instance.status}"
            )
        current = live_instance.json()
        body = {
            "protocol_version": current.get("protocol_version", 1),
            "server_generation": str(current["generation"]),
            "vault_id": account["vault_id"],
            "device_id": account["device_id"],
            "batch_id": batch_id or str(uuid.uuid4()),
            "operations": list(operations),
        }
        response = api.request(
            "POST",
            f"/api/v1/vaults/{account['vault_id']}/sync/push",
            token=account["access_token"],
            json_body=body,
        )
        # Keep the exact bytes for idempotent retry callers.
        response._request_body = body  # type: ignore[attr-defined]
        return response

    return submit


@pytest.fixture(scope="module")
def changes(api: ApiClient, account: dict[str, Any]):
    def read(*, cursor: str | None = None, limit: int = 500, token: str | None = None) -> Response:
        query = {"limit": str(limit)}
        if cursor:
            query["cursor"] = cursor
        path = f"/api/v1/vaults/{account['vault_id']}/changes?{urllib.parse.urlencode(query)}"
        return api.request("GET", path, token=token or account["access_token"])

    return read
