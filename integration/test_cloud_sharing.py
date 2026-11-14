"""Black-box acceptance for cloud organizations, Host sharing and temporary links.

Runs a disposable server against a private Docker stack (label
``cloud-implementation``, loopback-published guacd only):

* real ``guacamole/guacd:1.6.0``
* a real OpenSSH 10 server (throwaway container, synthetic fixture account)
* a real xrdp server (TLS, pinned snakeoil certificate)

Mocks are not used for connectivity: the SSH tests type into the target shell
through the gateway and verify the side effect inside the target container.
All secrets are synthetic sentinels; no real credentials are used.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from conftest import ROOT, ApiClient, SigningKey, b64url, jcs, prepare_web_root, server_binary_path, unb64url
from test_acceptance import (
    _issue_account_invitation,
    _membership_member,
    _new_account_registration,
    _signed_key_envelope,
    _signed_membership,
)

nacl_public = pytest.importorskip("nacl.public")
nacl_bindings = pytest.importorskip("nacl.bindings")
nacl_signing = pytest.importorskip("nacl.signing")
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.kdf.hkdf import HKDF  # noqa: E402

LABEL = "cloud-implementation=20261108"
GUACD_IMAGE = "guacamole/guacd:1.6.0"
SSHD_IMAGE = "cloud-implementation-sshd:20261108"
XRDP_IMAGE = "aterm-desktop-test:20261106"
FIXTURE_PASSWORD = "SENTINEL-FIXTURE-PASSWORD-91c"
SENTINEL_NOTE = "SENTINEL-DISPLAY-TITLE-55e"


def _docker(*args: str, check: bool = True) -> str:
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise AssertionError(f"docker {args[0]} failed: {result.stderr[-800:]}")
    return result.stdout.strip()


def _wait_port(host: str, port: int, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError:
            time.sleep(0.3)
    raise AssertionError(f"{host}:{port} did not open")


@dataclass
class Stack:
    network: str
    subnet: str
    ssh_ip: str
    xrdp_ip: str
    guacd_port: int
    ssh_fingerprint: str
    rdp_fingerprint: str
    containers: list[str]


@pytest.fixture(scope="module")
def stack():
    if not shutil.which("docker"):
        pytest.skip("Docker is required for the live gateway fixture")
    for image in (GUACD_IMAGE, SSHD_IMAGE, XRDP_IMAGE):
        if not _docker("images", "-q", image):
            pytest.skip(f"fixture image {image} is not available locally")
    suffix = uuid.uuid4().hex[:8]
    network = f"cloudimpl-{suffix}"
    _docker("network", "create", "--label", LABEL, network)
    containers: list[str] = []
    try:
        subnet = _docker("network", "inspect", network, "--format", "{{(index .IPAM.Config 0).Subnet}}")
        ssh = f"cloudimpl-sshd-{suffix}"
        xrdp = f"cloudimpl-xrdp-{suffix}"
        guacd = f"cloudimpl-guacd-{suffix}"
        _docker("run", "-d", "--rm", "--label", LABEL, "--name", ssh, "--network", network, SSHD_IMAGE)
        containers.append(ssh)
        _docker(
            "run", "-d", "--rm", "--label", LABEL, "--name", xrdp, "--network", network, XRDP_IMAGE,
            "sh", "-c",
            "sed -i 's/^security_layer=.*/security_layer=tls/' /etc/xrdp/xrdp.ini; "
            "Xvfb :99 -screen 0 1024x768x24 & sleep 1; DISPLAY=:99 xterm -geometry 100x35+0+0 -e sh & "
            "x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -quiet & exec xrdp --nodaemon",
        )
        containers.append(xrdp)
        _docker("run", "-d", "--rm", "--label", LABEL, "--name", guacd, "--network", network,
                "-p", "127.0.0.1::4822", GUACD_IMAGE)
        containers.append(guacd)
        ssh_ip = _docker("inspect", ssh, "--format", f"{{{{(index .NetworkSettings.Networks \"{network}\").IPAddress}}}}")
        xrdp_ip = _docker("inspect", xrdp, "--format", f"{{{{(index .NetworkSettings.Networks \"{network}\").IPAddress}}}}")
        guacd_port = int(_docker("port", guacd, "4822/tcp").rsplit(":", 1)[1])
        _wait_port(ssh_ip, 2222)
        _wait_port(xrdp_ip, 3389)
        _wait_port("127.0.0.1", guacd_port)
        fingerprint = _docker("exec", ssh, "ssh-keygen", "-lf", "/etc/ssh/ssh_host_ed25519_key.pub").split()[1]
        rdp = _docker("exec", xrdp, "openssl", "x509", "-in", "/etc/xrdp/cert.pem", "-noout", "-fingerprint", "-sha256")
        rdp_fingerprint = rdp.split("=", 1)[1].replace(":", "").lower()
        yield Stack(network, subnet, ssh_ip, xrdp_ip, guacd_port, fingerprint, rdp_fingerprint, containers)
    finally:
        for name in containers:
            _docker("rm", "-f", name, check=False)
        _docker("network", "rm", network, check=False)


@dataclass(repr=False)
class Account:
    account_id: str
    device_id: str
    username: str
    access_token: str
    signing_key: SigningKey
    encryption_public_key: str
    encryption_private: Any
    vault_id: str
    vault: dict = field(default_factory=dict)
    device_seq: int = 0

    def __repr__(self) -> str:  # never echo credentials in failures
        return f"<Account {self.username} [REDACTED]>"


@dataclass(repr=False)
class World:
    api: ApiClient
    base_url: str
    instance: dict
    owner: Account
    member: Account
    stack: Stack
    database: Path
    log_path: Path
    key_file: Path
    data_dir: Path
    observed: list[bytes] = field(default_factory=list)
    secrets: dict[str, str] = field(default_factory=dict)
    # Exact browser origin: a loopback TLS terminator in front of base_url
    # (`__Host-` cookies require HTTPS, exactly as in production).
    origin: str = ""

    def __repr__(self) -> str:
        return f"<World {self.base_url} [REDACTED]>"


class TlsTerminator:
    """Loopback TLS → plain TCP forwarder with a throwaway self-signed cert."""

    def __init__(self, backend_port: int, directory: Path):
        import ssl
        cert, key = directory / "cert.pem", directory / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                        "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", str(key), "-out", str(cert)],
                       check=True, capture_output=True)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.backend_port = backend_port
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(64)
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _pipe(self, source, target) -> None:
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                target.sendall(data)
        except OSError:
            pass
        finally:
            for sock in (source, target):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def _serve(self, client) -> None:
        try:
            tls = self.context.wrap_socket(client, server_side=True)
            backend = socket.create_connection(("127.0.0.1", self.backend_port))
        except OSError:
            client.close()
            return
        threading.Thread(target=self._pipe, args=(tls, backend), daemon=True).start()
        self._pipe(backend, tls)

    def _accept(self) -> None:
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def close(self) -> None:
        self.listener.close()


def _kill(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, 15)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, 9)
        process.wait(timeout=5)


def _register(api: ApiClient, tmp: Path, username: str, *, bootstrap: str | None) -> Account:
    account_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    private = nacl_public.PrivateKey.generate()
    encryption_public_key = b64url(bytes(private.public_key))
    signer = SigningKey(tmp, f"device-{uuid.uuid4().hex[:6]}")
    registration = _new_account_registration(account_id, username, device_id, encryption_public_key, signer)
    if bootstrap:
        registration["bootstrap_token"] = bootstrap
    else:
        registration["instance_invitation_token"] = _issue_account_invitation(api, username)
    response = api.request("POST", "/api/v1/auth/register", json_body=registration)
    assert response.status in (200, 201), response.body[:300]
    body = response.json()
    vault = body["vaults"][0]
    return Account(account_id, device_id, username, body["access_token"], signer,
                   encryption_public_key, private, vault.get("vault_id") or vault.get("id"), vault)


@pytest.fixture(scope="module")
def world(stack: Stack, tmp_path_factory: pytest.TempPathFactory):
    cargo = shutil.which("cargo")
    if not cargo:
        pytest.skip("Cargo is required to launch the isolated server")
    tmp = tmp_path_factory.mktemp("cloud-sharing")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    base_url = f"http://127.0.0.1:{port}"
    data_dir = tmp / "data"
    data_dir.mkdir(mode=0o700)
    key_dir = tmp / "gateway-key"
    key_dir.mkdir(mode=0o700)
    key_file = key_dir / "share-gateway.key"
    database_url = f"sqlite://{data_dir / 'atermius.db'}?mode=rwc"
    web_root, _ = prepare_web_root(tmp)
    tls = TlsTerminator(port, tmp)
    origin = f"https://127.0.0.1:{tls.port}"
    env = os.environ.copy()
    env.update({
        "ATERMIUS_BIND": f"127.0.0.1:{port}",
        "ATERMIUS_DATA_DIR": str(data_dir),
        "ATERMIUS_DATABASE_URL": database_url,
        "ATERMIUS_REGISTRATION_OPEN": "false",
        "ATERMIUS_PUBLIC_ORIGIN": origin,
        "ATERMIUS_WEB_DIR": str(web_root),
        "ATERMIUS_ADMIN_USERNAMES": "cloud-owner@example.test",
        "ATERMIUS_GUACD_ADDRESS": f"127.0.0.1:{stack.guacd_port}",
        "ATERMIUS_SHARE_LINKS_ENABLED": "true",
        "ATERMIUS_SHARE_GATEWAY_KEY_FILE": str(key_file),
        "ATERMIUS_SHARE_ALLOW_CIDRS": stack.subnet,
        "ATERMIUS_SHARE_ALLOW_PORTS": "2222,3389",
        # Every guest in this module is 127.0.0.1. The failure limit (5/min)
        # and global limits keep their production values.
        "ATERMIUS_SHARE_REDEEM_IP_LIMIT_PER_MINUTE": "200",
        # Verbose logging makes the sentinel leak scan meaningful.
        "RUST_LOG": "debug",
        "CARGO_TERM_COLOR": "never",
    })
    manifest = ROOT / "server" / "Cargo.toml"
    bootstrap = subprocess.run(
        [cargo, "run", "--quiet", "--locked", "--manifest-path", str(manifest), "--", "bootstrap"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=900, check=False,
    )
    assert bootstrap.returncode == 0, "bootstrap failed"
    token = re.findall(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", bootstrap.stdout)[-1]
    log_path = tmp / "server.log"
    log = log_path.open("wb")
    process = subprocess.Popen([str(server_binary_path(env)), "serve"], cwd=ROOT, env=env,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    api = ApiClient(base_url)
    api.admin_env = env
    api.temp_root = tmp
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                if api.request("GET", "/health/ready").status == 200:
                    break
            except OSError:
                pass
            assert process.poll() is None, "server exited during startup"
            time.sleep(0.2)
        instance = api.request("GET", "/api/v1/instance").json()
        owner = _register(api, tmp, "cloud-owner@example.test", bootstrap=token)
        member = _register(api, tmp, f"cloud-member-{uuid.uuid4().hex[:6]}@example.test", bootstrap=None)
        yield World(api, base_url, instance, owner, member, stack,
                    data_dir / "atermius.db", log_path, key_file, data_dir, origin=origin)
    finally:
        tls.close()
        _kill(process)
        log.close()


# ---------------------------------------------------------------------------
# Client-side protocol helpers (mirror the Flutter client implementation)
# ---------------------------------------------------------------------------

def hkdf(ikm: bytes, salt: bytes, info: Any) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt or None, info=jcs(info)).derive(ikm)


def link_material(link_id: str, secret_version: int = 1) -> dict[str, Any]:
    secret = os.urandom(32)
    redeem = hkdf(secret, b"", ["atermius", "share-link-redeem", 1])
    display_key = hkdf(secret, link_id.encode(), ["atermius", "share-link-display", 1, link_id, secret_version])
    return {
        "secret": secret,
        "fragment": "s1." + b64url(secret),
        "redeem_token": b64url(redeem),
        "display_key": display_key,
    }


def display_envelope(key: bytes, link_id: str, secret_version: int, plaintext: dict) -> str:
    nonce = os.urandom(24)
    aad = jcs({"format": "atermius-share-display-v1", "link_id": link_id, "secret_version": secret_version})
    sealed = nacl_bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(jcs(plaintext), aad, nonce, key)
    return "v1." + b64url(nonce) + "." + b64url(sealed)


def open_display(key: bytes, link_id: str, secret_version: int, envelope: str) -> dict:
    _, nonce, sealed = envelope.split(".")
    aad = jcs({"format": "atermius-share-display-v1", "link_id": link_id, "secret_version": secret_version})
    return json.loads(nacl_bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(unb64url(sealed), aad, unb64url(nonce), key))


def verified_gateway_key(world: World) -> dict:
    response = world.api.request("GET", "/api/v1/share-gateway/keys")
    assert response.status == 200
    key = response.json()["keys"][0]
    payload = json.loads(key["signed_payload"])
    assert payload["format"] == "atermius-share-gateway-key-v1"
    assert payload["instance_id"] == world.instance["instance_id"]
    assert payload["public_key"] == key["public_key"] and payload["key_id"] == key["key_id"]
    nacl_signing.VerifyKey(unb64url(world.instance["signing_public_key"])).verify(
        key["signed_payload"].encode(), unb64url(key["signature"]))
    return key


def push_host(world: World, owner: Account, *, record_id: str | None = None, base: str | None = None) -> tuple[str, str]:
    record_id = record_id or str(uuid.uuid4())
    revision_id = str(uuid.uuid4())
    owner.device_seq += 1
    listed = world.api.request("GET", "/api/v1/vaults", token=owner.access_token).json()
    for vault in listed.get("vaults", []):
        if (vault.get("vault_id") or vault.get("id")) == owner.vault_id:
            owner.vault = vault
    header = {
        "wire_version": 1,
        "server_space_id": world.instance["server_space_id"],
        "vault_id": owner.vault_id,
        "record_id": record_id,
        "revision_id": revision_id,
        "base_revision_id": base,
        "op_id": str(uuid.uuid4()),
        "device_id": owner.device_id,
        "device_seq": str(owner.device_seq),
        "key_epoch": str(owner.vault.get("active_key_epoch", "1")),
        "membership_version": str(owner.vault.get("membership_version", "1")),
        "record_schema": 1,
        "operation": "update" if base else "create",
        "crypto_suite": "atermius-vault-v1",
        "kdf_salt": b64url(os.urandom(32)),
    }
    signed = {"header": header, "nonce": b64url(os.urandom(24)), "ciphertext": b64url(os.urandom(64))}
    envelope = {**signed, "signature": b64url(owner.signing_key.sign(jcs(signed)))}
    generation = world.api.request("GET", "/api/v1/instance").json()["generation"]
    response = world.api.request("POST", f"/api/v1/vaults/{owner.vault_id}/sync/push", token=owner.access_token, json_body={
        "protocol_version": 1, "server_generation": str(generation), "vault_id": owner.vault_id,
        "device_id": owner.device_id, "batch_id": str(uuid.uuid4()), "operations": [envelope]})
    assert response.status == 200, response.body[:400]
    return record_id, revision_id


def push_as(world: World, writer: Account, vault_id: str, vault: dict):
    """Pushes an opaque record as `writer` into `vault_id` (any member)."""
    writer.device_seq += 1
    header = {
        "wire_version": 1, "server_space_id": world.instance["server_space_id"], "vault_id": vault_id,
        "record_id": str(uuid.uuid4()), "revision_id": str(uuid.uuid4()), "base_revision_id": None,
        "op_id": str(uuid.uuid4()), "device_id": writer.device_id, "device_seq": str(writer.device_seq),
        "key_epoch": str(vault.get("active_key_epoch", "1")), "membership_version": str(vault.get("membership_version", "1")),
        "record_schema": 1, "operation": "create", "crypto_suite": "atermius-vault-v1", "kdf_salt": b64url(os.urandom(32)),
    }
    signed = {"header": header, "nonce": b64url(os.urandom(24)), "ciphertext": b64url(os.urandom(64))}
    envelope = {**signed, "signature": b64url(writer.signing_key.sign(jcs(signed)))}
    generation = world.api.request("GET", "/api/v1/instance").json()["generation"]
    return world.api.request("POST", f"/api/v1/vaults/{vault_id}/sync/push", token=writer.access_token, json_body={
        "protocol_version": 1, "server_generation": str(generation), "vault_id": vault_id,
        "device_id": writer.device_id, "batch_id": str(uuid.uuid4()), "operations": [envelope]})


def seal_capsule(world: World, owner: Account, host_id: str, revision: str, *, protocol: str,
                 target: str, port: int, identity: str | None, username: str, password: str,
                 rdp_security: str | None = None) -> dict:
    key = verified_gateway_key(world)
    inner = {
        "format": "atermius-gateway-capsule-inner-v1",
        "vault_id": owner.vault_id, "host_record_id": host_id, "host_revision_id": revision,
        "gateway_key_id": key["key_id"], "record_kind": "host", "protocol": protocol,
        "target_host": target, "target_port": port, "username": username, "password": password,
        "host_identity": identity,
    }
    if protocol == "ssh":
        inner["ssh_host_key_algorithm"] = "ssh-ed25519"
    if rdp_security:
        inner["rdp_security"] = rdp_security
    sealed = nacl_public.SealedBox(nacl_public.PublicKey(unb64url(key["public_key"]))).encrypt(jcs(inner))
    header = {
        "format": "atermius-gateway-capsule-v1",
        "vault_id": owner.vault_id, "host_record_id": host_id, "host_revision_id": revision,
        "gateway_key_id": key["key_id"], "protocol": protocol, "target_host": target, "target_port": port,
        "host_identity": identity,
        "sealed_sha256": b64url(hashlib.sha256(bytes(sealed)).digest()),
        "sealer_user_id": owner.account_id, "sealer_device_id": owner.device_id,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    header["signature"] = b64url(owner.signing_key.sign(jcs(header)))
    return {"header": header, "sealed": b64url(bytes(sealed))}


def share_host(world: World, protocol: str = "ssh", *, identity: str | None = None, rdp_security: str | None = "tls") -> str:
    owner = world.owner
    host_id, revision = push_host(world, owner)
    if protocol == "ssh":
        body = seal_capsule(world, owner, host_id, revision, protocol="ssh", target=world.stack.ssh_ip, port=2222,
                            identity=identity or world.stack.ssh_fingerprint, username="fixture", password=FIXTURE_PASSWORD)
    else:
        body = seal_capsule(world, owner, host_id, revision, protocol="rdp", target=world.stack.xrdp_ip, port=3389,
                            identity=identity or world.stack.rdp_fingerprint, username="na", password="na",
                            rdp_security=rdp_security)
    response = world.api.request("PUT", f"/api/v1/vaults/{owner.vault_id}/hosts/{host_id}/gateway-capsule",
                                 token=owner.access_token, json_body=body)
    assert response.status == 200, response.body[:400]
    return host_id


def create_link(world: World, host_ids: list[str], **options: Any) -> dict:
    link_id = str(uuid.uuid4())
    material = link_material(link_id)
    targets = [{"target_id": str(uuid.uuid4()), "host_record_id": host} for host in host_ids]
    envelope = display_envelope(material["display_key"], link_id, 1, {
        "title": SENTINEL_NOTE, "targets": [{"target_id": t["target_id"], "label": "fixture"} for t in targets]})
    body = {"link_id": link_id, "redeem_token": material["redeem_token"], "display_envelope": envelope,
            "targets": targets, **options}
    response = world.api.request("POST", f"/api/v1/vaults/{world.owner.vault_id}/share-links",
                                 token=world.owner.access_token, json_body=body)
    assert response.status == 201, response.body[:400]
    link = response.json()
    world.secrets[f"fragment-{link_id}"] = material["fragment"]
    world.secrets[f"redeem-{link_id}"] = material["redeem_token"]
    return {**link, **material, "targets_request": targets}


class Guest:
    """A browser-like guest: cookie jar of one host-only cookie, exact Origin."""

    def __init__(self, world: World):
        self.world = world
        self.cookie: str | None = None
        self.slug: str | None = None

    def request(self, method: str, path: str, body: Any = None, *, origin: str | None = None,
                marker: bool = True, content_type: str = "application/json", extra: dict | None = None):
        headers = {"Accept": "application/json"}
        if origin is None:
            origin = self.world.origin
        if origin:
            headers["Origin"] = origin
        if marker:
            headers["X-Atermius-Guest"] = "v1"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = content_type
        if self.cookie:
            headers["Cookie"] = f"__Host-atermius-guest={self.cookie}"
        headers.update(extra or {})
        request = urllib.request.Request(self.world.base_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                status, response_headers, payload = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            status, response_headers, payload = error.code, error.headers, error.read()
        self.world.observed.append(str(response_headers).encode() + payload)
        cookie = response_headers.get("Set-Cookie")
        if cookie and cookie.startswith("__Host-atermius-guest="):
            value = cookie.split(";", 1)[0].split("=", 1)[1]
            self.cookie = value or None
            if value:
                self.world.secrets[f"cookie-{len(self.world.secrets)}"] = value
        try:
            parsed = json.loads(payload) if payload else None
        except json.JSONDecodeError:
            parsed = None
        return status, response_headers, parsed

    def redeem(self, link: dict):
        self.slug = link["slug"]
        return self.request("POST", "/api/v1/guest/redeem", {"slug": link["slug"], "redeem_token": link["redeem_token"]})

    def ticket(self, target_id: str):
        status, _, body = self.request("POST", "/api/v1/guest/connections", {"slug": self.slug, "target_id": target_id})
        if status == 200:
            self.world.secrets[f"ticket-{len(self.world.secrets)}"] = body["ticket"]
        return status, body


def instruction(*values: Any) -> bytes:
    return (",".join(f"{len(str(v))}.{v}" for v in values) + ";").encode()


def parse_instructions(buffer: bytearray) -> list[list[str]]:
    result = []
    while True:
        text = buffer.decode("utf-8", errors="ignore")
        values, pos = [], 0
        try:
            while True:
                dot = text.index(".", pos)
                length = int(text[pos:dot])
                start = dot + 1
                values.append(text[start:start + length])
                end = start + length
                if end >= len(text):
                    raise ValueError
                if text[end] == ";":
                    consumed = len(text[:end + 1].encode())
                    del buffer[:consumed]
                    result.append(values)
                    break
                pos = end + 1
        except ValueError:
            return result


class GatewaySocket:
    def __init__(self, world: World, guest: Guest | None, *, origin: str | None = None, cookie: bool = True,
                 path: str = "/gateway/v1/connect"):
        parsed = urllib.parse.urlsplit(world.base_url)
        self.conn = socket.create_connection((parsed.hostname, parsed.port), timeout=10)
        self.reader = self.conn.makefile("rb")
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {path} HTTP/1.1", f"Host: {parsed.netloc}", "Upgrade: websocket",
            "Connection: Upgrade", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13",
            f"Origin: {origin or world.origin}",
        ]
        if cookie and guest is not None and guest.cookie:
            lines.append(f"Cookie: __Host-atermius-guest={guest.cookie}")
        self.conn.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        self.status = int(self.reader.readline().split()[1])
        while self.reader.readline() not in (b"\r\n", b""):
            pass
        self.frames: list[tuple[int, bytes]] = []
        self.instructions: list[list[str]] = []
        self.close_code: int | None = None
        self.close_reason = ""
        self.closed_at: float | None = None
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.world = world

    def send(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        size = len(payload)
        header = bytes((0x80 | opcode,))
        if size < 126:
            header += bytes((0x80 | size,))
        elif size <= 0xFFFF:
            header += bytes((0x80 | 126,)) + struct.pack("!H", size)
        else:
            header += bytes((0x80 | 127,)) + struct.pack("!Q", size)
        with self._lock:
            self.conn.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self) -> tuple[int, bytes]:
        first, second = self.reader.read(2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", self.reader.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.reader.read(8))[0]
        payload = b""
        while len(payload) < size:
            chunk = self.reader.read(size - len(payload))
            if not chunk:
                raise EOFError
            payload += chunk
        self.world.observed.append(payload)
        return first & 0x0F, payload

    def text(self, value: dict) -> None:
        self.send(1, json.dumps(value).encode())

    def authenticate(self, ticket: str, width: int = 1024, height: int = 768) -> dict:
        self.text({"type": "authenticate", "ticket": ticket})
        opcode, payload = self.receive()
        if opcode == 8:
            self._record_close(payload)
            return {}
        assert opcode == 1
        hello = json.loads(payload)
        assert hello["type"] == "authenticated"
        self.text({"type": "open", "width": width, "height": height})
        return hello

    def _record_close(self, payload: bytes) -> None:
        self.close_code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1005
        self.close_reason = payload[2:].decode(errors="replace")
        self.closed_at = time.monotonic()

    def pump(self) -> None:
        """Background reader: answers guacd sync instructions like a client."""
        def run() -> None:
            try:
                while True:
                    opcode, payload = self.receive()
                    if opcode == 8:
                        self._record_close(payload)
                        return
                    if opcode == 2:
                        self._buffer.extend(payload)
                        for values in parse_instructions(self._buffer):
                            self.instructions.append(values)
                            if values[0] == "sync":
                                self.send(2, instruction("sync", values[1]))
            except (EOFError, OSError, ValueError):
                if self.closed_at is None:
                    self.closed_at = time.monotonic()
        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()

    def wait_for(self, predicate, timeout: float = 20) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.1)
        return predicate()

    def type(self, text: str) -> None:
        for char in text:
            keysym = 0xFF0D if char == "\n" else ord(char)
            self.send(2, instruction("key", keysym, 1) + instruction("key", keysym, 0))
            time.sleep(0.02)

    def close(self) -> None:
        try:
            self.send(8, struct.pack("!H", 1000))
        except OSError:
            pass
        self.conn.close()


def _target_file_exists(world: World, path: str) -> bool:
    container = next(name for name in world.stack.containers if "sshd" in name)
    return subprocess.run(["docker", "exec", container, "test", "-f", path]).returncode == 0


def _open_session(world: World, link: dict, guest: Guest | None = None) -> tuple[Guest, GatewaySocket]:
    guest = guest or Guest(world)
    status, _, view = guest.redeem(link)
    assert status == 200, view
    status, ticket = guest.ticket(view["targets"][0]["target_id"])
    assert status == 200, ticket
    ws = GatewaySocket(world, guest)
    assert ws.status == 101
    hello = ws.authenticate(ticket["ticket"])
    assert hello, f"gateway refused: {ws.close_code} {ws.close_reason}"
    ws.pump()
    return guest, ws


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_capabilities_gateway_key_and_key_file_isolation(world: World) -> None:
    caps = world.instance["capabilities"]
    for capability in ("organizations", "share_links", "share_gateway_ssh", "share_gateway_rdp"):
        assert capability in caps
    assert "share_gateway_vnc" not in caps, "VNC stays unadvertised unless explicitly enabled"
    key = verified_gateway_key(world)
    assert oct(world.key_file.stat().st_mode & 0o777) == "0o600"
    assert not str(world.key_file).startswith(str(world.data_dir)), "gateway key never lives in the backed-up data dir"
    private = world.key_file.read_bytes()
    assert private not in world.database.read_bytes()
    assert key["public_key"] == b64url(bytes(nacl_public.PrivateKey(private).public_key))


def test_live_ssh_session_types_into_real_target_and_revocation_closes_it(world: World) -> None:
    host = share_host(world, "ssh")
    link = create_link(world, [host], slug=f"live-{uuid.uuid4().hex[:8]}", max_redemptions=2)
    # Page GET never redeems and does not reveal whether the slug exists.
    page = urllib.request.urlopen(world.base_url + f"/s/{link['slug']}", timeout=10)
    unknown = urllib.request.urlopen(world.base_url + "/s/no-such-link-here", timeout=10)
    assert page.status == unknown.status == 200 and page.read() == unknown.read()
    assert page.headers["Cache-Control"] == "no-store" and page.headers["Referrer-Policy"] == "no-referrer"
    current = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                token=world.owner.access_token).json()
    assert current["redemptions"] == 0

    guest = Guest(world)
    status, headers, view = guest.redeem(link)
    assert status == 200
    cookie = headers["Set-Cookie"]
    assert all(part in cookie for part in ("__Host-atermius-guest=", "Secure", "HttpOnly", "SameSite=Strict", "Path=/"))
    assert "Domain" not in cookie
    # The guest decrypts the display envelope locally with the fragment key.
    assert open_display(link["display_key"], link["link_id"], 1, view["display_envelope"])["title"] == SENTINEL_NOTE
    assert "fixture" not in json.dumps(view["targets"]) and "password" not in json.dumps(view)
    # Refresh restores the session without consuming a redemption.
    status, _, again = guest.request("GET", f"/api/v1/guest/session?slug={guest.slug}")
    assert status == 200 and again["link_id"] == link["link_id"]

    target_id = view["targets"][0]["target_id"]
    # WebSocket Origin and cookie domain checks.
    assert GatewaySocket(world, guest, origin="https://evil.example").status == 403
    assert GatewaySocket(world, guest, cookie=False).status == 401
    status, ticket = guest.ticket(target_id)
    assert status == 200
    ws = GatewaySocket(world, guest)
    assert ws.status == 101
    hello = ws.authenticate(ticket["ticket"])
    assert hello["permissions"] == {"clipboard_to_remote": False, "clipboard_from_remote": False, "view_only": False}
    ws.pump()
    assert ws.wait_for(lambda: any(v[0] == "ready" for v in ws.instructions)), (ws.close_code, ws.close_reason)
    assert ws.wait_for(lambda: sum(v[0] == "img" for v in ws.instructions) >= 2, 20), "terminal never rendered"
    time.sleep(1.5)
    marker = f"/tmp/guest-was-here-{uuid.uuid4().hex[:6]}"
    ws.type(f"touch {marker}\n")
    assert ws.wait_for(lambda: _target_file_exists(world, marker), 15), "input did not reach the real SSH target"
    # Replay of a consumed ticket is refused.
    replay = GatewaySocket(world, guest)
    assert replay.authenticate(ticket["ticket"]) == {} and replay.close_code == 4401
    # Owner sees the live connection with metadata only.
    activity = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/activity",
                                 token=world.owner.access_token).json()
    assert activity["sessions"][0]["live_connections"] == 1
    assert activity["connections"][0]["protocol"] == "ssh"
    # Revocation closes the active socket within the documented bound.
    started = time.monotonic()
    revoked = world.api.request("POST", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/revoke",
                                token=world.owner.access_token, json_body={})
    assert revoked.status == 200
    assert ws.wait_for(lambda: ws.closed_at is not None, 5)
    assert ws.close_code == 4403, (ws.close_code, ws.close_reason)
    assert ws.closed_at - started <= 3.0, f"revocation took {ws.closed_at - started:.2f}s"
    ws.close()
    # The revoked link's guest session and URL are dead.
    assert guest.request("GET", f"/api/v1/guest/session?slug={guest.slug}")[0] in (401, 404)
    assert Guest(world).redeem(link)[0] == 404


def test_view_only_link_blocks_input_on_the_server_side(world: World) -> None:
    host = share_host(world, "ssh")
    link = create_link(world, [host], view_only=True)
    _, ws = _open_session(world, link)
    assert ws.wait_for(lambda: sum(v[0] == "img" for v in ws.instructions) >= 2, 20)
    time.sleep(1.5)
    marker = f"/tmp/view-only-violation-{uuid.uuid4().hex[:6]}"
    ws.type(f"touch {marker}\n")
    time.sleep(3)
    assert not _target_file_exists(world, marker), "view-only guest input reached the target"
    assert ws.close_code is None, "view-only input is dropped, not a protocol violation"
    ws.close()


def test_narrowing_and_owner_termination_close_active_sessions(world: World) -> None:
    host = share_host(world, "ssh")
    link = create_link(world, [host], clipboard_to_remote=True, max_redemptions=2)
    _, ws = _open_session(world, link)
    assert ws.wait_for(lambda: any(v[0] == "ready" for v in ws.instructions))
    started = time.monotonic()
    updated = world.api.request("PUT", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                token=world.owner.access_token,
                                json_body={"expected_revision": link["revision"], "clipboard_to_remote": False})
    assert updated.status == 200
    assert ws.wait_for(lambda: ws.closed_at is not None, 5) and ws.close_code == 4403
    assert ws.closed_at - started <= 3.0
    ws.close()
    # Owner terminates a second guest's session.
    guest, ws = _open_session(world, link)
    assert ws.wait_for(lambda: any(v[0] == "ready" for v in ws.instructions))
    activity = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/activity",
                                 token=world.owner.access_token).json()
    live = next(s for s in activity["sessions"] if s["active"] and s["live_connections"] == 1)
    started = time.monotonic()
    terminated = world.api.request(
        "POST", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/guest-sessions/{live['guest_session_id']}/terminate",
        token=world.owner.access_token, json_body={})
    assert terminated.status == 200
    assert ws.wait_for(lambda: ws.closed_at is not None, 5) and ws.close_code == 4403
    assert ws.closed_at - started <= 3.0
    ws.close()


def test_wrong_host_key_fails_closed_before_guacd(world: World) -> None:
    wrong = "SHA256:" + base64.b64encode(hashlib.sha256(b"not the fixture key").digest()).decode().rstrip("=")
    host = share_host(world, "ssh", identity=wrong)
    link = create_link(world, [host])
    guest = Guest(world)
    _, _, view = guest.redeem(link)
    _, ticket = guest.ticket(view["targets"][0]["target_id"])
    ws = GatewaySocket(world, guest)
    hello = ws.authenticate(ticket["ticket"])
    assert hello
    ws.pump()
    assert ws.wait_for(lambda: ws.closed_at is not None, 15)
    assert ws.close_code == 4502 and "host_key" in ws.close_reason
    assert not any(v[0] == "ready" for v in ws.instructions)


def test_live_rdp_session_with_pinned_certificate(world: World) -> None:
    host = share_host(world, "rdp", rdp_security="tls")
    link = create_link(world, [host])
    _, ws = _open_session(world, link)
    assert ws.wait_for(lambda: any(v[0] == "ready" for v in ws.instructions), 20), (ws.close_code, ws.close_reason)
    assert ws.wait_for(lambda: any(v[0] in ("img", "size") for v in ws.instructions[1:]), 20), "no RDP frame"
    ws.close()
    # A wrong certificate pin never yields a desktop.
    bad = share_host(world, "rdp", identity="00" * 32, rdp_security="tls")
    _, ws = _open_session(world, create_link(world, [bad]))
    ws.wait_for(lambda: ws.closed_at is not None, 20)
    assert not any(v[0] == "img" for v in ws.instructions), "desktop rendered despite a wrong certificate pin"
    ws.close()


def test_cross_tenant_and_role_boundaries_through_real_handlers(world: World) -> None:
    owner, member = world.owner, world.member
    host = share_host(world, "ssh")
    link = create_link(world, [host])
    # Member cannot read, manage or substitute the owner's Vault resources.
    for method, path, body in [
        ("GET", f"/api/v1/vaults/{owner.vault_id}/share-links", None),
        ("GET", f"/api/v1/vaults/{owner.vault_id}/share-links/{link['link_id']}", None),
        ("POST", f"/api/v1/vaults/{owner.vault_id}/share-links/{link['link_id']}/revoke", {}),
        ("GET", f"/api/v1/vaults/{owner.vault_id}/share-capsules", None),
        ("DELETE", f"/api/v1/vaults/{owner.vault_id}/hosts/{host}/gateway-capsule", None),
    ]:
        response = world.api.request(method, path, token=member.access_token, json_body=body)
        assert response.status == 404, (path, response.status)
    # Owner's link ID through the member's own Vault path → 404 as well.
    response = world.api.request("GET", f"/api/v1/vaults/{member.vault_id}/share-links/{link['link_id']}", token=member.access_token)
    assert response.status == 404
    # Member creating a link with the owner's Host in the member's Vault → 404.
    material = link_material(str(uuid.uuid4()))
    response = world.api.request("POST", f"/api/v1/vaults/{member.vault_id}/share-links", token=member.access_token, json_body={
        "link_id": str(uuid.uuid4()), "redeem_token": material["redeem_token"], "display_envelope": "x",
        "targets": [{"target_id": str(uuid.uuid4()), "host_record_id": host}]})
    assert response.status == 404
    # Guest credentials never work on Bearer routes, and vice versa.
    guest = Guest(world)
    assert guest.redeem(link)[0] == 200
    response = urllib.request.Request(world.base_url + f"/api/v1/vaults/{owner.vault_id}/share-links",
                                      headers={"Cookie": f"__Host-atermius-guest={guest.cookie}"})
    with pytest.raises(urllib.error.HTTPError) as error:
        urllib.request.urlopen(response, timeout=10)
    assert error.value.code == 401
    assert guest.request("GET", f"/api/v1/guest/session?slug={guest.slug}", extra={"Authorization": f"Bearer {owner.access_token}"})[0] == 400
    # CSRF: no marker / form content type / foreign origin all rejected without state change.
    assert guest.request("POST", "/api/v1/guest/logout", {}, marker=False)[0] == 403
    assert guest.request("POST", "/api/v1/guest/logout", {}, content_type="text/plain")[0] == 415
    assert guest.request("POST", "/api/v1/guest/logout", {}, origin="https://evil.example")[0] == 403
    assert guest.request("GET", f"/api/v1/guest/session?slug={guest.slug}")[0] == 200


def test_organization_join_grant_and_owner_consented_key_delivery(world: World) -> None:
    owner, member, api = world.owner, world.member, world.api
    org = api.request("POST", "/api/v1/orgs", token=owner.access_token, json_body={"name": f"Ops {uuid.uuid4().hex[:4]}"})
    assert org.status == 201
    org_id = org.json()["org_id"]
    # Non-admin accounts cannot create organizations by default.
    assert api.request("POST", "/api/v1/orgs", token=member.access_token, json_body={"name": "Nope"}).status == 403
    invite = api.request("POST", f"/api/v1/orgs/{org_id}/invitations", token=owner.access_token,
                         json_body={"role": "member", "intended_username": member.username}).json()
    world.secrets["org-invite"] = invite["token"]
    assert api.request("POST", "/api/v1/org-invitations/inspect", token=member.access_token,
                       json_body={"token": invite["token"]}).json()["role"] == "member"
    joined = api.request("POST", "/api/v1/org-invitations/accept", token=member.access_token, json_body={"token": invite["token"]})
    assert joined.status == 200 and joined.json()["vault_keys_pending"] is True
    team = api.request("POST", f"/api/v1/orgs/{org_id}/teams", token=owner.access_token, json_body={"name": "SRE"}).json()
    assert api.request("PUT", f"/api/v1/orgs/{org_id}/teams/{team['team_id']}/members", token=owner.access_token,
                       json_body={"user_ids": [member.account_id], "expected_revision": 1}).status == 200
    assert api.request("PUT", f"/api/v1/vaults/{owner.vault_id}/organization", token=owner.access_token,
                       json_body={"org_id": org_id}).status == 200
    granted = api.request("PUT", f"/api/v1/vaults/{owner.vault_id}/grants/team/{team['team_id']}", token=owner.access_token,
                          json_body={"role": "editor", "expected_grants_revision": 1})
    assert granted.status == 200 and granted.json()["key_distribution"] == "pending_owner_confirmation"
    # Before the recipient publishes a device card the owner cannot proceed.
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    assert dist["pending_additions"][0]["status"] == "waiting_for_device"
    # Recipient publishes its own signed share card (public keys only).
    card = {"format": "atermius-vault-share-request-v1", "account_id": member.account_id,
            "instance_id": world.instance["instance_id"], "device": {
                "device_id": member.device_id, "name": "pytest", "signing_public_key": b64url(member.signing_key.public_key),
                "encryption_public_key": member.encryption_public_key,
                "signature": b64url(member.signing_key.sign(jcs({
                    "account_id": member.account_id, "device_id": member.device_id,
                    "signing_public_key": b64url(member.signing_key.public_key),
                    "encryption_public_key": member.encryption_public_key})))}}
    forged = json.loads(json.dumps(card))
    forged["device"]["encryption_public_key"] = b64url(os.urandom(32))
    assert api.request("PUT", "/api/v1/cloud/device-card", token=member.access_token, json_body={"card": forged}).status == 422
    assert api.request("PUT", "/api/v1/cloud/device-card", token=member.access_token, json_body={"card": card}).status == 200
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    pending = dist["pending_additions"][0]
    assert pending["status"] == "waiting_for_owner" and pending["device_cards"][0]["card"]["device"]["device_id"] == member.device_id
    # Still no key material for the member: only the owner can create it.
    with sqlite3.connect(world.database) as db:
        assert db.execute("SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=? AND recipient_user_id=?",
                          (owner.vault_id, member.account_id)).fetchone()[0] == 0
    # Owner confirms: existing signed invitation (manifest v2 + key envelope) …
    membership_chain = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/membership", token=owner.access_token).json()
    latest = membership_chain["manifests"][-1]
    assert latest["membership_version"] == 1
    membership = _signed_membership(
        owner.vault_id, 2, latest["digest"], 1,
        [_membership_member(owner.account_id, "owner", owner.encryption_public_key),
         _membership_member(member.account_id, "editor", member.encryption_public_key)],
        owner.device_id, owner.signing_key)
    issued = api.request("POST", f"/api/v1/vaults/{owner.vault_id}/invitations", token=owner.access_token, json_body={
        "role": "editor", "recipient_device_id": member.device_id,
        "recipient_encryption_public_key": member.encryption_public_key,
        "key_envelope": _signed_key_envelope(owner.vault_id, member.device_id, 1, 2, owner.signing_key),
        "membership": membership})
    assert issued.status in (200, 201), issued.body[:300]
    invitation = issued.json()
    world.secrets["vault-invite"] = invitation["token"]
    # … and seals the invitation token to the recipient device.
    sealed = nacl_public.SealedBox(nacl_public.PublicKey(unb64url(member.encryption_public_key))).encrypt(invitation["token"].encode())
    delivered = api.request("POST", f"/api/v1/vaults/{owner.vault_id}/key-deliveries", token=owner.access_token, json_body={
        "invitation_id": invitation["invitation_id"], "recipient_device_id": member.device_id, "sealed_token": b64url(bytes(sealed))})
    assert delivered.status == 201
    with sqlite3.connect(world.database) as db:
        assert invitation["token"].encode() not in b"".join(
            str(row).encode() for row in db.execute("SELECT * FROM cloud_key_deliveries"))
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    assert dist["pending_additions"][0]["status"] == "waiting_for_recipient"
    # Recipient opens the delivery and accepts through the existing endpoint.
    deliveries = api.request("GET", "/api/v1/cloud/key-deliveries", token=member.access_token).json()["deliveries"]
    token = nacl_public.SealedBox(member.encryption_private).decrypt(unb64url(deliveries[0]["sealed_token"])).decode()
    assert token == invitation["token"]
    accepted = api.request("POST", "/api/v1/invitations/accept", token=member.access_token, json_body={"token": token})
    assert accepted.status == 200, accepted.body[:300]
    assert api.request("POST", f"/api/v1/cloud/key-deliveries/{deliveries[0]['delivery_id']}/opened", token=member.access_token).status == 200
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    assert dist["pending_additions"] == [] and dist["rotation_required"] is False

    # --- R4.1: the ACCEPTED grant-derived member is restricted immediately,
    # with union semantics over the remaining grants.
    def changes() -> int:
        return api.request("GET", f"/api/v1/vaults/{owner.vault_id}/changes?limit=10", token=member.access_token).status
    assert changes() == 200
    team2 = api.request("POST", f"/api/v1/orgs/{org_id}/teams", token=owner.access_token, json_body={"name": "Viewers"}).json()
    assert api.request("PUT", f"/api/v1/orgs/{org_id}/teams/{team2['team_id']}/members", token=owner.access_token,
                       json_body={"user_ids": [member.account_id], "expected_revision": 1}).status == 200
    revision = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/grants", token=owner.access_token).json()["grants_revision"]
    assert api.request("PUT", f"/api/v1/vaults/{owner.vault_id}/grants/team/{team2['team_id']}", token=owner.access_token,
                       json_body={"role": "viewer", "expected_grants_revision": revision}).status == 200
    # Leaving the editor team keeps the viewer grant: reads continue, writes stop now.
    assert api.request("PUT", f"/api/v1/orgs/{org_id}/teams/{team['team_id']}/members", token=owner.access_token,
                       json_body={"user_ids": [], "expected_revision": 2}).status == 200
    assert changes() == 200
    shared = next(v for v in api.request("GET", "/api/v1/vaults", token=member.access_token).json()["vaults"]
                  if v["vault_id"] == owner.vault_id)
    assert shared["can_write"] is False
    write = push_as(world, member, owner.vault_id, shared)
    assert write.status == 403 and write.json()["error"]["code"] == "VAULT_READ_ONLY"
    # An open sync-notification socket is told to resync within the bound
    # when the last grant goes, and the resync is refused.
    ticket = api.request("POST", "/api/v1/notifications/tickets", token=member.access_token).json()["ticket"]
    ws = GatewaySocket(world, None, path="/api/v1/notifications")
    assert ws.status == 101
    ws.text({"type": "authenticate", "ticket": ticket})
    assert json.loads(ws.receive()[1])["type"] == "ready"
    started = time.monotonic()
    assert api.request("PUT", f"/api/v1/orgs/{org_id}/teams/{team2['team_id']}/members", token=owner.access_token,
                       json_body={"user_ids": [], "expected_revision": 2}).status == 200
    ws.conn.settimeout(4)
    frame = json.loads(ws.receive()[1])
    assert frame["type"] == "sync_required" and time.monotonic() - started <= 3.0
    ws.close()
    assert changes() == 404, "no grant left: access is blocked before any key rotation"
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    assert dist["pending_removals"][0]["server_access"] == "blocked"
    # Restoring a grant restores access (server enforcement follows grants).
    assert api.request("PUT", f"/api/v1/orgs/{org_id}/teams/{team['team_id']}/members", token=owner.access_token,
                       json_body={"user_ids": [member.account_id], "expected_revision": 3}).status == 200
    assert changes() == 200
    # Removing the member from the organization is immediately visible as a
    # required rotation (the E2E key can only be revoked by the key holder).
    removed = api.request("DELETE", f"/api/v1/orgs/{org_id}/members/{member.account_id}", token=owner.access_token)
    assert removed.status == 200
    dist = api.request("GET", f"/api/v1/vaults/{owner.vault_id}/key-distribution", token=owner.access_token).json()
    assert dist["rotation_required"] is True and dist["pending_removals"][0]["user_id"] == member.account_id
    # The removed member no longer sees the organization or the Vault.
    assert api.request("GET", f"/api/v1/orgs/{org_id}", token=member.access_token).status == 404
    assert changes() == 404


def test_selected_host_sharing_vault_isolates_h1_from_h2(world: World, tmp_path_factory: pytest.TempPathFactory) -> None:
    """R2.2: sharing H1 through a dedicated Vault never exposes H2."""
    api, owner = world.api, world.owner
    recipient = _register(api, tmp_path_factory.mktemp("h1h2"), f"cloud-h1h2-{uuid.uuid4().hex[:6]}@example.test", bootstrap=None)
    # Source (personal) Vault holds H1 and H2.
    h1, _ = push_host(world, owner)
    h2, _ = push_host(world, owner)
    # Dedicated sharing Vault created by the owner's client with a copy of H1 only.
    from conftest import initial_vault
    material = initial_vault(account_id=owner.account_id, vault_id=str(uuid.uuid4()), device_id=owner.device_id,
                             encryption_public_key=owner.encryption_public_key, signer=owner.signing_key)
    created = api.request("POST", "/api/v1/vaults", token=owner.access_token, json_body={
        "vault_id": material["vault_id"], "name_envelope": material["name_envelope"],
        "key_envelope": material["key_envelope"], "membership": material["membership"]})
    assert created.status in (200, 201), created.body[:200]
    shared_id = material["vault_id"]
    shared = {"active_key_epoch": "1", "membership_version": "1"}
    h1_copy = push_as(world, owner, shared_id, shared)
    assert h1_copy.status == 200, h1_copy.body[:200]
    # Recipient is invited to the sharing Vault only (signed manifest + key envelope).
    membership = _signed_membership(
        shared_id, 2, api.request("GET", f"/api/v1/vaults/{shared_id}/membership", token=owner.access_token).json()["manifests"][-1]["digest"], 1,
        [_membership_member(owner.account_id, "owner", owner.encryption_public_key),
         _membership_member(recipient.account_id, "viewer", recipient.encryption_public_key)],
        owner.device_id, owner.signing_key)
    invite = api.request("POST", f"/api/v1/vaults/{shared_id}/invitations", token=owner.access_token, json_body={
        "role": "viewer", "recipient_device_id": recipient.device_id,
        "recipient_encryption_public_key": recipient.encryption_public_key,
        "key_envelope": _signed_key_envelope(shared_id, recipient.device_id, 1, 2, owner.signing_key),
        "membership": membership})
    assert invite.status in (200, 201), invite.body[:200]
    world.secrets["h1h2-invite"] = invite.json()["token"]
    assert api.request("POST", "/api/v1/invitations/accept", token=recipient.access_token,
                       json_body={"token": invite.json()["token"]}).status == 200
    # Recipient reads the sharing Vault: exactly one record (the H1 copy).
    changes = api.request("GET", f"/api/v1/vaults/{shared_id}/changes?limit=100", token=recipient.access_token)
    assert changes.status == 200
    body = json.dumps(changes.json())
    def record_ids(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "record_id" and isinstance(item, str):
                    yield item
                else:
                    yield from record_ids(item)
        elif isinstance(value, list):
            for item in value:
                yield from record_ids(item)
    records = set(record_ids(changes.json()))
    assert h1 not in body and h2 not in body, "source record IDs never appear in the sharing Vault"
    assert len(records) == 1, records
    # The source Vault (with H1 and H2) stays unreadable for the recipient.
    assert api.request("GET", f"/api/v1/vaults/{owner.vault_id}/changes?limit=10", token=recipient.access_token).status == 404
    listed = api.request("GET", "/api/v1/vaults", token=recipient.access_token).json()["vaults"]
    assert owner.vault_id not in {v["vault_id"] for v in listed} and shared_id in {v["vault_id"] for v in listed}


HEADLESS = Path.home() / ".cache/ms-playwright/chromium_headless_shell-1169/chrome-linux/headless_shell"


class Cdp:
    """Minimal Chrome DevTools Protocol client over a raw WebSocket."""

    def __init__(self, ws_url: str):
        parsed = urllib.parse.urlsplit(ws_url)
        self.conn = socket.create_connection((parsed.hostname, parsed.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.conn.sendall((f"GET {parsed.path} HTTP/1.1\r\nHost: {parsed.netloc}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buffer = b""
        while b"\r\n\r\n" not in self.buffer:
            self.buffer += self.conn.recv(4096)
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        assert b" 101 " in head.split(b"\r\n")[0]
        self.next_id = 0
        self.events: list[dict] = []

    def _send(self, payload: bytes) -> None:
        mask = os.urandom(4)
        size = len(payload)
        if size < 126:
            length = bytes((0x80 | size,))
        elif size <= 0xFFFF:
            length = bytes((0x80 | 126,)) + struct.pack("!H", size)
        else:
            length = bytes((0x80 | 127,)) + struct.pack("!Q", size)
        self.conn.sendall(b"\x81" + length + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _need(self, count: int) -> bytes:
        while len(self.buffer) < count:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise EOFError
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _recv(self) -> dict:
        first, second = self._need(2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", self._need(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self._need(8))[0]
        return json.loads(self._need(size))

    def _ready(self, wait: float) -> bool:
        import select
        return bool(self.buffer) or bool(select.select([self.conn], [], [], wait)[0])

    def call(self, method: str, **params):
        self.next_id += 1
        ident = self.next_id
        self._send(json.dumps({"id": ident, "method": method, "params": params}).encode())
        while True:
            message = self._recv()
            if message.get("id") == ident:
                return message.get("result", {})
            self.events.append(message)

    def eval(self, expression: str):
        result = self.call("Runtime.evaluate", expression=expression, returnByValue=True, awaitPromise=True)
        return result.get("result", {}).get("value")

    def drain(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self._ready(0.2):
                self.events.append(self._recv())

    def click_semantics(self, label: str, timeout: float = 30) -> bool:
        script = ("(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click();"
                  " const nodes = [...document.querySelectorAll('[role=button]'), ...document.querySelectorAll('flt-semantics')];"
                  f" const n = nodes.find(e => (e.textContent || e.getAttribute('aria-label') || '').trim() === {json.dumps(label)});"
                  " if (!n) return false; n.click(); return true; })()")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.eval(script):
                return True
            self.drain(0.5)
        return False


def test_real_browser_guest_flow_clears_fragment_and_never_auto_redeems(world: World, tmp_path_factory: pytest.TempPathFactory) -> None:
    if not HEADLESS.exists():
        pytest.skip("no local Chromium headless shell")
    web_index = ROOT / "apps" / "client" / "build" / "web" / "index.html"
    if not web_index.exists() or b"share-bootstrap.js" not in web_index.read_bytes():
        pytest.skip("Flutter Web release build with share-bootstrap.js is required")
    host = share_host(world, "ssh")
    link = create_link(world, [host])
    profile = tmp_path_factory.mktemp("chromium")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    browser = subprocess.Popen([str(HEADLESS), "--headless", "--no-sandbox", "--disable-gpu", "--use-gl=swiftshader", "--lang=en-US", "--accept-lang=en-US", "--ignore-certificate-errors",
                                f"--remote-debugging-port={port}", f"--user-data-dir={profile}", "about:blank"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                               env={**os.environ, "LANG": "en_US.UTF-8"})
    try:
        deadline = time.monotonic() + 20
        target = None
        while time.monotonic() < deadline and target is None:
            try:
                pages = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read())
                target = next(p for p in pages if p.get("type") == "page")
            except Exception:
                time.sleep(0.3)
        assert target, "browser did not start"
        cdp = Cdp(target["webSocketDebuggerUrl"])
        cdp.call("Network.enable")
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")
        # The headless shell reports no navigator.languages; give it the
        # locale every real browser provides.
        cdp.call("Emulation.setLocaleOverride", locale="en-US")
        cdp.call("Network.setUserAgentOverride", userAgent="Mozilla/5.0 (X11; Linux x86_64) Chrome/136.0 Safari/537.36",
                 acceptLanguage="en-US")
        url = f"{world.origin}/s/{link['slug']}#{link['fragment']}"
        cdp.call("Page.navigate", url=url)
        cdp.drain(3)
        assert cdp.eval("location.hash") == "", "fragment must be removed from the address bar"
        assert cdp.eval("location.pathname") == f"/s/{link['slug']}"
        history = cdp.call("Page.getNavigationHistory")["entries"]
        assert all(link["fragment"][3:] not in entry["url"] for entry in history), "no history entry keeps the secret"
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not cdp.eval("!!document.querySelector('flutter-view, flt-glass-pane')"):
            cdp.drain(0.5)
        if not cdp.eval("!!document.querySelector('flutter-view, flt-glass-pane')"):
            problems = [
                (e["method"], (e["params"].get("exceptionDetails", {}).get("exception", {}).get("description") or json.dumps(e["params"]))[:600]) for e in cdp.events
                if e.get("method") in ("Runtime.exceptionThrown", "Network.loadingFailed", "Log.entryAdded")
                or (e.get("method") == "Runtime.consoleAPICalled" and e["params"].get("type") in ("error", "warning"))
                or (e.get("method") == "Network.responseReceived" and e["params"]["response"]["status"] >= 400)
            ]
            pytest.fail(f"Flutter did not start: {problems[:12]}")
        requests = [e["params"]["request"] for e in cdp.events if e.get("method") == "Network.requestWillBeSent"]
        assert requests, "no network activity was observed"
        secret = link["fragment"][3:]
        for request in requests:
            assert secret not in request["url"] and secret not in json.dumps(request.get("headers", {}))
            assert link["redeem_token"] not in request["url"]
        # Page load alone never redeems.
        current = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                    token=world.owner.access_token).json()
        assert current["redemptions"] == 0
        # Deliberate click on Continue redeems exactly once, without the secret on the wire.
        # Continue is only offered when the app received the secret.
        assert cdp.click_semantics("Continue", timeout=60), "Continue button not found"
        cdp.drain(4)
        taken = cdp.eval("window.atermiusTakeShareFragment()")
        assert taken is None, "the secret is handed to the app once and not kept in the page"
        current = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                    token=world.owner.access_token).json()
        assert current["redemptions"] == 1
        posted = [e["params"]["request"] for e in cdp.events if e.get("method") == "Network.requestWillBeSent"
                  and e["params"]["request"]["url"].endswith("/api/v1/guest/redeem")]
        assert posted and secret not in json.dumps(posted)
        cookies = cdp.call("Network.getCookies", urls=[world.origin])["cookies"]
        blocked = [b.get("blockedReasons") for e in cdp.events if e.get("method") == "Network.responseReceivedExtraInfo"
                   for b in e["params"].get("blockedCookies", [])]
        guest_cookie = next((c for c in cookies if c["name"] == "__Host-atermius-guest"), None)
        assert guest_cookie is not None, f"guest cookie not stored; blocked={blocked}"
        assert guest_cookie["httpOnly"] and guest_cookie["secure"] and guest_cookie["sameSite"] == "Strict"
        assert cdp.eval("document.cookie").find("atermius-guest") < 0, "HttpOnly cookie is not readable by scripts"
        world.secrets["browser-cookie"] = guest_cookie["value"]
        # R6.3: the live cookie for link A must not show or connect A under
        # another link's address or an unknown address (no fragment).
        other = create_link(world, [host])
        has_button = "!![...document.querySelectorAll('[role=button]')].find(e => (e.textContent||'').trim() === 'Connect')"
        for address in (other["slug"], "no-such-address"):
            cdp.call("Page.navigate", url=f"{world.origin}/s/{address}")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not cdp.eval("!!document.querySelector('flutter-view, flt-glass-pane')"):
                cdp.drain(0.5)
            cdp.eval("(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); })()")
            cdp.drain(4)
            assert not cdp.eval(has_button), f"link A must not be offered under /s/{address}"
        cdp.call("Page.navigate", url=f"{world.origin}/s/{link['slug']}")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not cdp.eval("!!document.querySelector('flutter-view, flt-glass-pane')"):
            cdp.drain(0.5)
        current = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                    token=world.owner.access_token).json()
        assert current["redemptions"] == 1, "same-address refresh never spends an opening"
        # No connection until the guest clicks Connect; then a live gateway session.
        activity = lambda: world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/activity",
                                             token=world.owner.access_token).json()
        assert activity()["connections"] == []
        cdp.drain(2)
        nodes = cdp.eval("JSON.stringify([...document.querySelectorAll('flt-semantics')].filter(e => (e.textContent||'').includes('Connect')).map(e => [e.getAttribute('role'), e.getAttribute('aria-disabled'), e.getAttribute('flt-tappable'), (e.textContent||'').slice(0,60)]))")
        assert cdp.click_semantics("Connect", timeout=60), f"Connect button not found: {nodes}"
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline and not any(c["ended_at"] is None for c in activity()["connections"]):
            time.sleep(0.5)
        live = [c for c in activity()["connections"] if c["ended_at"] is None]
        if not live:
            requests = [e["params"]["request"]["url"] for e in cdp.events if e.get("method") == "Network.requestWillBeSent"]
            sockets = [json.dumps(e["params"])[:300] for e in cdp.events if e.get("method", "").startswith("Network.webSocket")]
            errors = [(e["params"].get("exceptionDetails", {}).get("exception", {}).get("description") or "")[:300]
                      for e in cdp.events if e.get("method") == "Runtime.exceptionThrown"]
            pytest.fail(f"no live connection: activity={activity()['connections']} requests={requests[-6:]} ws={sockets[:4]} errors={errors[:3]}")
        assert live[0]["protocol"] == "ssh"
        cdp.drain(5)
        assert activity()["connections"][0]["bytes_to_guest"] > 1000, "rendered terminal frames reached the browser"
        # Revocation ends the browser's session within the bound.
        started = time.monotonic()
        world.api.request("POST", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}/revoke",
                          token=world.owner.access_token, json_body={})
        while time.monotonic() - started < 5 and any(c["ended_at"] is None for c in activity()["connections"]):
            time.sleep(0.2)
        assert all(c["ended_at"] is not None for c in activity()["connections"])
        assert time.monotonic() - started <= 3.5
    finally:
        try:
            os.killpg(browser.pid, 15)
        except ProcessLookupError:
            pass
        browser.wait(timeout=10)


def test_rate_limits_return_retry_after_without_consuming(world: World) -> None:
    host = share_host(world, "ssh")
    link = create_link(world, [host])
    guest = Guest(world)
    codes = []
    for _ in range(7):
        status, headers, _ = guest.request("POST", "/api/v1/guest/redeem", {"slug": link["slug"], "redeem_token": b64url(os.urandom(32))})
        codes.append(status)
    # Earlier modules' failed redemptions from 127.0.0.1 may already count.
    first_limited = codes.index(429)
    assert 1 <= first_limited <= 5 and set(codes[:first_limited]) == {404} and codes[-1] == 429
    status, headers, _ = guest.request("POST", "/api/v1/guest/redeem", {"slug": link["slug"], "redeem_token": link["redeem_token"]})
    assert status == 429 and int(headers["Retry-After"]) >= 1
    current = world.api.request("GET", f"/api/v1/vaults/{world.owner.vault_id}/share-links/{link['link_id']}",
                                token=world.owner.access_token).json()
    assert current["redemptions"] == 0


def test_zz_sentinel_secrets_absent_from_logs_audit_headers_and_frames(world: World) -> None:
    """G9: run last, after every flow above produced tokens, cookies and tickets."""
    log = world.log_path.read_bytes()
    with sqlite3.connect(world.database) as db:
        audit = "\n".join(str(row) for row in db.execute("SELECT * FROM cloud_audit_events")).encode()
        audit += "\n".join(str(row) for row in db.execute("SELECT * FROM audit_events")).encode()
    database = world.database.read_bytes()
    wal = world.database.with_name(world.database.name + "-wal")
    if wal.exists():
        database += wal.read_bytes()
    observed = b"\n".join(world.observed)
    guacd = next(name for name in world.stack.containers if "guacd" in name)
    guacd_log = subprocess.run(["docker", "logs", guacd], capture_output=True, timeout=60)
    guacd_log = guacd_log.stdout + guacd_log.stderr
    assert b"guacd" in guacd_log or len(guacd_log) > 0, "guacd log was captured"
    sentinels = {
        "host password": FIXTURE_PASSWORD,
        "display plaintext": SENTINEL_NOTE,
        **world.secrets,
    }
    assert len(sentinels) > 8
    for label, value in sentinels.items():
        needle = value.encode()
        assert needle not in log, f"{label} leaked into server logs"
        assert needle not in audit, f"{label} leaked into audit rows"
        assert needle not in guacd_log, f"{label} leaked into guacd logs"
        assert needle not in database, f"{label} stored in plaintext"
        if not label.startswith(("cookie", "ticket", "org-invite", "vault-invite")):
            assert needle not in observed, f"{label} returned to a guest/client response or WS frame"
    assert FIXTURE_PASSWORD.encode() not in observed and b"fixture" not in b"".join(
        frame for frame in world.observed if frame.startswith(b"{"))
