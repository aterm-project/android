"""Static deployment acceptance for the local-first Compose defaults."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_compose_default_security_and_auth_limit_configuration() -> None:
    """DEPLOY-01: rendered Compose config exposes safe, documented defaults."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered deployment configuration")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and ("unknown flag" in result.stderr.lower() or "unknown shorthand" in result.stderr.lower()):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose config failed: {result.stderr[-2000:]}"
    rendered = json.loads(result.stdout)
    service = rendered["services"]["server"]
    config = service["environment"]

    expected = {
        "ATERMIUS_REGISTRATION_OPEN": "false",
        "ATERMIUS_RELAY_ENABLED": "false",
        "ATERMIUS_RELAY_ALLOW_PORTS": "",
        "ATERMIUS_HISTORY_RETENTION_DAYS": "90",
        "ATERMIUS_VAULT_DELETION_GRACE_SECONDS": "604800",
        "ATERMIUS_AUDIT_RETENTION_DAYS": "365",
        "ATERMIUS_OBJECT_GC_GRACE_SECONDS": "604800",
        "ATERMIUS_MAX_VAULTS_PER_USER": "50",
        "ATERMIUS_MAX_MEMBERS_PER_VAULT": "100",
        "ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES": "10000",
        "ATERMIUS_ADMIN_USERNAMES": "",
        "ATERMIUS_AUTH_RATE_WINDOW_SECONDS": "900",
        "ATERMIUS_AUTH_LOGIN_USER_LIMIT": "12",
        "ATERMIUS_AUTH_LOGIN_PAIR_LIMIT": "8",
        "ATERMIUS_AUTH_LOGIN_IP_LIMIT": "3000",
        "ATERMIUS_AUTH_PRELOGIN_USER_LIMIT": "30",
        "ATERMIUS_AUTH_PRELOGIN_PAIR_LIMIT": "20",
        "ATERMIUS_AUTH_PRELOGIN_IP_LIMIT": "6000",
        "ATERMIUS_AUTH_REGISTER_USER_LIMIT": "3",
        "ATERMIUS_AUTH_REGISTER_PAIR_LIMIT": "3",
        "ATERMIUS_AUTH_REGISTER_IP_LIMIT": "60",
    }
    assert {key: config.get(key) for key in expected} == expected
    assert "ATERMIUS_BACKUP_ARCHIVE_DIR" not in config
    assert "ATERMIUS_BACKUP_KEY_FILE" not in config
    assert "ATERMIUS_MFA_ENCRYPTION_KEY_FILE" not in config
    assert "ATERMIUS_OBJECT_STORE_BACKEND" not in config
    assert "ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT" not in config
    assert not any(volume.get("target") in {"/backups", "/backup-key", "/mfa-key/atermius-mfa.key"} for volume in service["volumes"])
    assert any(port.get("host_ip") == "127.0.0.1" and port.get("target") == 8080 for port in service["ports"])
    assert rendered["volumes"]["server-data"]["name"] == "atermius-data"
    healthcheck_command = [str(part) for part in service["healthcheck"]["test"]]
    assert any("atermius-server" in part for part in healthcheck_command)
    assert any("healthcheck" in part for part in healthcheck_command)

    override_env = dict(env)
    override_env["ATERMIUS_MAX_VAULTS_PER_USER"] = "77"
    override_env["ATERMIUS_MAX_MEMBERS_PER_VAULT"] = "333"
    override_env["ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES"] = "777"
    override_result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=override_env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert override_result.returncode == 0, (
        f"docker compose override config failed: {override_result.stderr[-2000:]}"
    )
    override_config = json.loads(override_result.stdout)["services"]["server"]["environment"]
    assert override_config["ATERMIUS_MAX_VAULTS_PER_USER"] == "77"
    assert override_config["ATERMIUS_MAX_MEMBERS_PER_VAULT"] == "333"
    assert override_config["ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES"] == "777"


def test_compose_mfa_overlay_mounts_only_the_owner_key_read_only() -> None:
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered MFA overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env["ATERMIUS_MFA_KEY_HOST_DIR"] = "/srv/atermius-mfa-key"
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.mfa.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and ("unknown flag" in result.stderr.lower() or "unknown shorthand" in result.stderr.lower()):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose MFA overlay failed: {result.stderr[-2000:]}"
    rendered = json.loads(result.stdout)
    service = rendered["services"]["server"]
    assert service["environment"]["ATERMIUS_MFA_ENCRYPTION_KEY_FILE"] == "/mfa-key/atermius-mfa.key"
    mounts = {volume["target"]: volume for volume in service["volumes"]}
    assert mounts["/mfa-key/atermius-mfa.key"]["source"] == "/srv/atermius-mfa-key/atermius-mfa.key"
    assert mounts["/mfa-key/atermius-mfa.key"]["read_only"] is True


def test_compose_fcm_overlay_mounts_service_account_read_only() -> None:
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered FCM overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env["ATERMIUS_FCM_SERVICE_ACCOUNT_HOST_FILE"] = "/srv/atermius-fcm/service-account.json"
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.push-fcm.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose FCM overlay failed: {result.stderr[-2000:]}"
    service = json.loads(result.stdout)["services"]["server"]
    assert service["environment"]["ATERMIUS_FCM_SERVICE_ACCOUNT_FILE"] == (
        "/run/secrets/atermius-fcm-service-account.json"
    )
    credential_mount = {
        volume["target"]: volume for volume in service["volumes"]
    }["/run/secrets/atermius-fcm-service-account.json"]
    assert credential_mount["source"] == "/srv/atermius-fcm/service-account.json"
    assert credential_mount["read_only"] is True


def test_compose_apns_overlay_mounts_owner_key_read_only() -> None:
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered APNs overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_APNS_PRIVATE_KEY_HOST_FILE": "/srv/atermius-apns/AuthKey_0123456789.p8",
            "ATERMIUS_APNS_TEAM_ID": "ABCDEFGHIJ",
            "ATERMIUS_APNS_KEY_ID": "0123456789",
            "ATERMIUS_APNS_TOPIC": "com.example.atermius",
            "ATERMIUS_APNS_USE_SANDBOX": "true",
        }
    )
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.push-apns.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose APNs overlay failed: {result.stderr[-2000:]}"
    service = json.loads(result.stdout)["services"]["server"]
    config = service["environment"]
    assert config["ATERMIUS_APNS_PRIVATE_KEY_FILE"] == "/run/secrets/atermius-apns-auth-key.p8"
    assert config["ATERMIUS_APNS_TEAM_ID"] == "ABCDEFGHIJ"
    assert config["ATERMIUS_APNS_KEY_ID"] == "0123456789"
    assert config["ATERMIUS_APNS_TOPIC"] == "com.example.atermius"
    assert config["ATERMIUS_APNS_USE_SANDBOX"] == "true"
    key_mount = {
        volume["target"]: volume for volume in service["volumes"]
    }["/run/secrets/atermius-apns-auth-key.p8"]
    assert key_mount["source"] == "/srv/atermius-apns/AuthKey_0123456789.p8"
    assert key_mount["read_only"] is True
    overlay = yaml.safe_load((ROOT / "deploy/compose.push-apns.yaml").read_text(encoding="utf-8"))
    assert overlay["services"]["server"]["volumes"][0]["bind"]["create_host_path"] is False


def test_compose_caddy_edge_removes_origin_port_and_probes_https_readiness() -> None:
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the Caddy edge overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_CADDY_DOMAIN": "atermius.example.test",
            "ATERMIUS_CADDY_ACME_EMAIL": "admin@example.test",
            "ATERMIUS_PUBLIC_ORIGIN": "https://atermius.example.test",
        }
    )
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.caddy.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
        or "!reset" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json` or !reset")
    assert result.returncode == 0, f"docker compose Caddy overlay failed: {result.stderr[-2000:]}"

    rendered = json.loads(result.stdout)
    server = rendered["services"]["server"]
    edge = rendered["services"]["edge"]
    assert server.get("ports", []) == [], "edge mode must not publish the origin port"
    assert "8080" in server.get("expose", [])
    assert edge["image"] == "caddy:2.11.7-alpine"
    assert {port["target"] for port in edge["ports"]} == {80, 443}
    assert all(port["published"] for port in edge["ports"])
    assert edge["environment"]["ATERMIUS_CADDY_DOMAIN"] == "atermius.example.test"
    assert edge["environment"]["ATERMIUS_CADDY_ACME_EMAIL"] == "admin@example.test"
    assert edge["healthcheck"]["test"][0] == "CMD-SHELL"
    health_probe = " ".join(edge["healthcheck"]["test"]).lower()
    assert "https://" in health_probe and "/health/ready" in health_probe
    assert "$${atermius_caddy_domain}" in health_probe
    assert {network for network in server["networks"]} >= {"default", "caddy-backend"}
    assert set(edge["networks"]) == {"caddy-backend"}, (
        "edge must not join the default network, which may contain unrelated services"
    )

    caddyfile = (ROOT / "deploy" / "Caddyfile").read_text(encoding="utf-8")
    assert "{$ATERMIUS_CADDY_DOMAIN}" in caddyfile
    assert "reverse_proxy server:8080" in caddyfile
    assert "X-Forwarded-For/Proto/Host" in caddyfile
    assert "health_uri /health/ready" in caddyfile


def test_compose_fcm_and_apns_overlays_can_be_enabled_together() -> None:
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate combined push overlays")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_FCM_SERVICE_ACCOUNT_HOST_FILE": "/srv/atermius-fcm/service-account.json",
            "ATERMIUS_APNS_PRIVATE_KEY_HOST_FILE": "/srv/atermius-apns/AuthKey_0123456789.p8",
            "ATERMIUS_APNS_TEAM_ID": "ABCDEFGHIJ",
            "ATERMIUS_APNS_KEY_ID": "0123456789",
            "ATERMIUS_APNS_TOPIC": "com.example.atermius",
        }
    )
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.push-fcm.yaml",
            "-f",
            "deploy/compose.push-apns.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"combined push overlays failed: {result.stderr[-2000:]}"
    service = json.loads(result.stdout)["services"]["server"]
    config = service["environment"]
    assert config["ATERMIUS_FCM_SERVICE_ACCOUNT_FILE"] == (
        "/run/secrets/atermius-fcm-service-account.json"
    )
    assert config["ATERMIUS_APNS_PRIVATE_KEY_FILE"] == "/run/secrets/atermius-apns-auth-key.p8"
    assert config["ATERMIUS_APNS_USE_SANDBOX"] == "false"
    mounts = {volume["target"]: volume for volume in service["volumes"]}
    assert mounts["/run/secrets/atermius-fcm-service-account.json"]["source"] == (
        "/srv/atermius-fcm/service-account.json"
    )
    assert mounts["/run/secrets/atermius-fcm-service-account.json"]["read_only"] is True
    assert mounts["/run/secrets/atermius-apns-auth-key.p8"]["source"] == (
        "/srv/atermius-apns/AuthKey_0123456789.p8"
    )
    assert mounts["/run/secrets/atermius-apns-auth-key.p8"]["read_only"] is True


def test_apns_deployment_docs_describe_private_key_and_fixed_host_contract() -> None:
    env_example = (ROOT / "deploy/.env.example").read_text(encoding="utf-8")
    readme = (ROOT / "deploy/README.md").read_text(encoding="utf-8")
    overlay = yaml.safe_load(
        (ROOT / "deploy/compose.push-apns.yaml").read_text(encoding="utf-8")
    )
    assert set(overlay["services"]["server"]["environment"]) == {
        "ATERMIUS_APNS_PRIVATE_KEY_FILE",
        "ATERMIUS_APNS_TEAM_ID",
        "ATERMIUS_APNS_KEY_ID",
        "ATERMIUS_APNS_TOPIC",
        "ATERMIUS_APNS_USE_SANDBOX",
    }
    for name in (
        "ATERMIUS_APNS_PRIVATE_KEY_HOST_FILE",
        "ATERMIUS_APNS_TEAM_ID",
        "ATERMIUS_APNS_KEY_ID",
        "ATERMIUS_APNS_TOPIC",
        "ATERMIUS_APNS_USE_SANDBOX",
    ):
        assert name in env_example
    for required in (
        "P-256",
        "`.p8`",
        "owner-only",
        "mode `0600`",
        "UID `10001`",
        "exactly 10 ASCII letters or digits",
        "validated bundle identifier",
        "api.sandbox.push.apple.com",
        "api.push.apple.com",
        "when unset or false",
        "compose.push-apns.yaml",
        "compose.push-fcm.yaml",
    ):
        assert required in readme
    assert "APNs token registration/sending remains unsupported" not in readme
    assert "-----BEGIN " not in env_example


def test_compose_backup_overlay_mounts_only_the_opt_in_paths() -> None:
    """Backup key and archive paths are explicit and separate from default mounts."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered backup overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.backup.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and ("unknown flag" in result.stderr.lower() or "unknown shorthand" in result.stderr.lower()):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose backup overlay failed: {result.stderr[-2000:]}"
    rendered = json.loads(result.stdout)
    service = rendered["services"]["server"]
    config = service["environment"]
    assert config["ATERMIUS_BACKUP_ARCHIVE_DIR"] == "/backups"
    assert config["ATERMIUS_BACKUP_KEY_FILE"] == "/backup-key/atermius-backup.key"
    mounts = {volume["target"]: volume for volume in service["volumes"]}
    assert mounts["/backups"]["source"] == "/srv/atermius-backups"
    assert mounts["/backups"].get("read_only") is not True
    assert mounts["/backup-key"]["source"] == "/srv/atermius-backup-key"
    assert mounts["/backup-key"]["read_only"] is True


def test_compose_object_store_s3_overlay_mounts_credentials_read_only() -> None:
    """User-object S3 stays opt-in and separate from encrypted archive replication."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered object-store overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_OBJECT_STORE_S3_BUCKET": "atermius-user-objects",
            "ATERMIUS_OBJECT_STORE_S3_REGION": "us-east-1",
            "ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_HOST_FILE": "/srv/atermius-object-store-s3/credentials.json",
            "ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL": "https://s3.example.test",
            "ATERMIUS_OBJECT_STORE_S3_PREFIX": "atermius/production",
        }
    )
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.object-store-s3.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, f"docker compose object-store overlay failed: {result.stderr[-2000:]}"
    rendered = json.loads(result.stdout)
    service = rendered["services"]["server"]
    config = service["environment"]
    assert config["ATERMIUS_OBJECT_STORE_BACKEND"] == "s3"
    assert config["ATERMIUS_OBJECT_STORE_S3_BUCKET"] == "atermius-user-objects"
    assert config["ATERMIUS_OBJECT_STORE_S3_REGION"] == "us-east-1"
    assert config["ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE"] == "/run/secrets/atermius-object-store-s3.json"
    assert config["ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL"] == "https://s3.example.test"
    assert config["ATERMIUS_OBJECT_STORE_S3_PREFIX"] == "atermius/production"
    assert not any(key.startswith("ATERMIUS_BACKUP_S3_") for key in config)
    mounts = {volume["target"]: volume for volume in service["volumes"]}
    credential_mount = mounts["/run/secrets/atermius-object-store-s3.json"]
    assert credential_mount["source"] == "/srv/atermius-object-store-s3/credentials.json"
    assert credential_mount["read_only"] is True


def test_compose_object_store_filesystem_overlay_uses_separate_named_volume() -> None:
    """Filesystem objects use a dedicated persistent volume, separate from /data."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the rendered filesystem overlay")

    volume_name = "atermius-filesystem-acceptance-volume"
    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env["ATERMIUS_OBJECT_STORE_FILESYSTEM_VOLUME_NAME"] = volume_name
    result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.object-store-filesystem.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0 and (
        "unknown flag" in result.stderr.lower()
        or "unknown shorthand" in result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert result.returncode == 0, (
        f"docker compose filesystem object-store overlay failed: {result.stderr[-2000:]}"
    )
    rendered = json.loads(result.stdout)
    service = rendered["services"]["server"]
    config = service["environment"]
    assert config["ATERMIUS_OBJECT_STORE_BACKEND"] == "filesystem"
    assert config["ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"] == "/object-store"
    assert not any(key.startswith("ATERMIUS_OBJECT_STORE_S3_") for key in config)
    assert not any(key.startswith("ATERMIUS_BACKUP_S3_") for key in config)
    mounts = {volume["target"]: volume for volume in service["volumes"]}
    object_mount = mounts["/object-store"]
    assert object_mount["source"] == "object-store-data"
    assert object_mount.get("read_only") is not True
    assert mounts["/data"]["source"] != object_mount["source"]
    assert rendered["volumes"]["object-store-data"]["name"] == volume_name

    # A fresh named volume inherits the image's mount-point metadata. The
    # runtime image must prepare this directory for the service UID because
    # object-store startup rejects a root-owned or shared-writable mount.
    dockerfile = (ROOT / "server" / "Dockerfile").read_text(encoding="utf-8")
    assert "mkdir -p /data /object-store /app/web" in dockerfile
    assert "chmod 0700 /data /object-store" in dockerfile
    assert "chown -R aterm:aterm /data /object-store /app" in dockerfile
    assert "USER aterm" in dockerfile


def test_compose_prometheus_overlay_is_opt_in_and_private() -> None:
    """Prometheus stays opt-in, uses a private scrape network and loopback UI."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the Prometheus overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    base = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if base.returncode != 0 and (
        "unknown flag" in base.stderr.lower() or "unknown shorthand" in base.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert base.returncode == 0, f"docker compose default config failed: {base.stderr[-2000:]}"
    base_config = json.loads(base.stdout)
    assert set(base_config["services"]) == {"server"}
    assert "ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR" not in (
        base_config["services"]["server"].get("environment", {})
    )

    env.update(
        {
            "ATERMIUS_PROMETHEUS_HOST_PORT": "19090",
            "ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR": "/srv/atermius-prometheus-secrets",
        }
    )
    overlay = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.prometheus.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if overlay.returncode != 0 and (
        "unknown flag" in overlay.stderr.lower() or "unknown shorthand" in overlay.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert overlay.returncode == 0, f"docker compose Prometheus overlay failed: {overlay.stderr[-2000:]}"
    rendered = json.loads(overlay.stdout)
    assert set(rendered["services"]) == {"server", "prometheus"}
    server = rendered["services"]["server"]
    prometheus = rendered["services"]["prometheus"]

    assert prometheus["image"] == "prom/prometheus:v3.14.0"
    assert prometheus["user"] == "65534:65534"
    assert prometheus["read_only"] is True
    assert "ALL" in prometheus["cap_drop"]
    assert "--web.enable-lifecycle" not in prometheus["command"]
    assert prometheus["networks"] == {"default": None, "metrics": None}
    assert server["networks"] == {"default": None, "metrics": None}
    assert rendered["networks"]["metrics"]["internal"] is True

    ports = prometheus["ports"]
    assert len(ports) == 1
    assert ports[0]["host_ip"] == "127.0.0.1"
    assert ports[0]["target"] == 9090
    assert ports[0]["published"] == "19090"

    mounts = {volume["target"]: volume for volume in prometheus["volumes"]}
    assert mounts["/etc/prometheus/prometheus.yml"]["read_only"] is True
    alert_mount = mounts["/etc/prometheus/atermius-alerts.yml"]
    assert alert_mount["read_only"] is True
    assert Path(alert_mount["source"]).name == "atermius-alerts.yml"
    credentials = mounts["/run/atermius-secrets"]
    assert credentials["source"] == "/srv/atermius-prometheus-secrets/"
    assert credentials["read_only"] is True
    assert mounts["/prometheus"]["type"] == "volume"
    assert mounts["/prometheus"]["source"] == "prometheus-data"
    assert rendered["volumes"]["prometheus-data"]["name"].endswith("_prometheus-data")
    assert rendered["volumes"]["prometheus-data"]["name"] != rendered["volumes"]["server-data"]["name"]
    assert not any(key.startswith("ATERMIUS_PROMETHEUS_") for key in prometheus.get("environment", {}))

    prometheus_config = yaml.safe_load((ROOT / "deploy/prometheus/prometheus.yml").read_text())
    assert prometheus_config["global"]["evaluation_interval"] == "15s"
    assert prometheus_config["rule_files"] == ["/etc/prometheus/atermius-alerts.yml"]
    rules = yaml.safe_load((ROOT / "deploy/prometheus/atermius-alerts.yml").read_text())
    alert = rules["groups"][0]["rules"][0]
    assert alert["alert"] == "AtermiusMetricsScrapeUnavailable"
    assert alert["expr"] == 'up{job="atermius"} == 0'
    assert alert["for"] == "30s"
    assert alert["labels"] == {"severity": "warning"}
    assert alert["annotations"]["summary"] == "Atermius metrics scrape unavailable"


def test_compose_alertmanager_overlay_uses_protected_webhook_file() -> None:
    """Alertmanager delivery is opt-in and the webhook URL stays out of config/env."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the Alertmanager overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    base = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if base.returncode != 0 and (
        "unknown flag" in base.stderr.lower() or "unknown shorthand" in base.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert base.returncode == 0, f"docker compose default config failed: {base.stderr[-2000:]}"
    assert set(json.loads(base.stdout)["services"]) == {"server"}

    env.update(
        {
            "ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR": "/srv/atermius-prometheus-secrets",
            "ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR": "/srv/atermius-alertmanager-secrets",
        }
    )
    rendered_result = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.prometheus.yaml",
            "-f",
            "deploy/compose.alertmanager.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if rendered_result.returncode != 0 and (
        "unknown flag" in rendered_result.stderr.lower()
        or "unknown shorthand" in rendered_result.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert rendered_result.returncode == 0, (
        f"docker compose Alertmanager overlay failed: {rendered_result.stderr[-2000:]}"
    )
    rendered = json.loads(rendered_result.stdout)
    assert set(rendered["services"]) == {"server", "prometheus", "alertmanager"}

    prometheus = rendered["services"]["prometheus"]
    alertmanager = rendered["services"]["alertmanager"]
    assert prometheus["image"] == "prom/prometheus:v3.14.0"
    assert prometheus["networks"] == {
        "default": None,
        "metrics": None,
        "alertmanager": None,
    }
    assert alertmanager["image"] == "prom/alertmanager:v0.34.1"
    assert alertmanager["user"] == "65534:65534"
    assert alertmanager["read_only"] is True
    assert "ALL" in alertmanager["cap_drop"]
    assert "no-new-privileges:true" in alertmanager["security_opt"]
    assert alertmanager["networks"] == {
        "alertmanager": None,
        "alertmanager-egress": None,
    }
    assert rendered["services"]["server"]["networks"] == {
        "default": None,
        "metrics": None,
    }
    assert rendered["networks"]["alertmanager"]["internal"] is True
    assert rendered["networks"]["alertmanager-egress"]["driver"] == "bridge"
    assert not alertmanager.get("ports")
    assert alertmanager["depends_on"]["prometheus"]["condition"] == "service_started"
    assert not alertmanager.get("environment")

    prometheus_mounts = {volume["target"]: volume for volume in prometheus["volumes"]}
    alert_prometheus_config = prometheus_mounts["/etc/prometheus/prometheus.yml"]
    assert alert_prometheus_config["read_only"] is True
    assert Path(alert_prometheus_config["source"]).name == "prometheus-alertmanager.yml"
    alertmanager_mounts = {volume["target"]: volume for volume in alertmanager["volumes"]}
    alertmanager_config_mount = alertmanager_mounts["/etc/alertmanager/alertmanager.yml"]
    assert alertmanager_config_mount["read_only"] is True
    assert Path(alertmanager_config_mount["source"]).name == "alertmanager.yml"
    webhook_secrets = alertmanager_mounts["/run/atermius-alertmanager-secrets"]
    assert webhook_secrets["source"] == "/srv/atermius-alertmanager-secrets/"
    assert webhook_secrets["read_only"] is True
    assert alertmanager_mounts["/alertmanager"]["source"] == "alertmanager-data"
    assert rendered["volumes"]["alertmanager-data"]["name"].endswith("_alertmanager-data")
    assert rendered["volumes"]["alertmanager-data"]["name"] != rendered["volumes"]["prometheus-data"]["name"]

    prometheus_config = yaml.safe_load(
        (ROOT / "deploy/prometheus/prometheus-alertmanager.yml").read_text(encoding="utf-8")
    )
    assert prometheus_config["alerting"]["alertmanagers"] == [
        {"static_configs": [{"targets": ["alertmanager:9093"]}]}
    ]
    assert prometheus_config["rule_files"] == ["/etc/prometheus/atermius-alerts.yml"]
    assert prometheus_config["scrape_configs"][0]["job_name"] == "atermius"
    assert prometheus_config["scrape_configs"][0]["authorization"]["credentials_file"] == (
        "/run/atermius-secrets/metrics-token"
    )
    default_prometheus_config = yaml.safe_load(
        (ROOT / "deploy/prometheus/prometheus.yml").read_text(encoding="utf-8")
    )
    assert "alerting" not in default_prometheus_config
    assert {key: value for key, value in prometheus_config.items() if key != "alerting"} == (
        default_prometheus_config
    )

    alertmanager_config = yaml.safe_load(
        (ROOT / "deploy/alertmanager/alertmanager.yml").read_text(encoding="utf-8")
    )
    assert alertmanager_config["route"]["receiver"] == "discard"
    assert alertmanager_config["route"]["group_by"] == ["alertname"]
    routes = alertmanager_config["route"]["routes"]
    assert len(routes) == 1
    assert routes[0]["receiver"] == "aterm-webhook"
    assert routes[0]["matchers"] == [
        'alertname="AtermiusMetricsScrapeUnavailable"'
    ]
    webhook_receiver = next(
        receiver
        for receiver in alertmanager_config["receivers"]
        if receiver["name"] == "aterm-webhook"
    )
    webhook_configs = webhook_receiver["webhook_configs"]
    assert len(webhook_configs) == 1
    assert webhook_configs[0] == {
        "url_file": "/run/atermius-alertmanager-secrets/webhook-url",
        "send_resolved": True,
    }
    serialized_configs = json.dumps([prometheus_config, alertmanager_config])
    assert "webhook-url" in serialized_configs
    assert "url_file" in serialized_configs
    assert '"url"' not in serialized_configs
    assert "ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR" not in alertmanager.get("environment", {})

    compose_source = (ROOT / "deploy/compose.alertmanager.yaml").read_text(encoding="utf-8")
    assert '${ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR:?Set in deploy/.env}/' in compose_source
    assert "${ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR:-" not in compose_source
    compose_overlay = yaml.safe_load(compose_source)
    secret_mount = next(
        volume
        for volume in compose_overlay["services"]["alertmanager"]["volumes"]
        if volume.get("target") == "/run/atermius-alertmanager-secrets"
    )
    assert secret_mount["bind"]["create_host_path"] is False


def test_compose_grafana_overlay_is_opt_in_and_restricted() -> None:
    """Grafana stays optional, authenticated, read-only, and loopback-only."""
    docker = shutil.which("docker")
    if not docker:
        pytest.skip("Docker Compose is required to validate the Grafana overlay")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    env.update(
        {
            "ATERMIUS_PROMETHEUS_HOST_PORT": "19090",
            "ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR": "/srv/atermius-prometheus-secrets",
            "ATERMIUS_GRAFANA_HOST_PORT": "13000",
            "ATERMIUS_GRAFANA_ADMIN_PASSWORD_HOST_DIR": "/srv/atermius-grafana-secrets",
        }
    )
    base = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if base.returncode != 0 and (
        "unknown flag" in base.stderr.lower() or "unknown shorthand" in base.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert base.returncode == 0, f"docker compose default config failed: {base.stderr[-2000:]}"
    assert set(json.loads(base.stdout)["services"]) == {"server"}

    rendered = subprocess.run(
        [
            docker,
            "compose",
            "--env-file",
            "deploy/.env.example",
            "-f",
            "deploy/compose.yaml",
            "-f",
            "deploy/compose.prometheus.yaml",
            "-f",
            "deploy/compose.grafana.yaml",
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if rendered.returncode != 0 and (
        "unknown flag" in rendered.stderr.lower() or "unknown shorthand" in rendered.stderr.lower()
    ):
        pytest.skip("installed Docker Compose does not support `config --format json`")
    assert rendered.returncode == 0, f"docker compose Grafana overlay failed: {rendered.stderr[-2000:]}"
    config = json.loads(rendered.stdout)
    assert set(config["services"]) == {"server", "prometheus", "grafana"}
    grafana = config["services"]["grafana"]

    assert grafana["image"] == "grafana/grafana:13.2.3"
    assert grafana["user"] == "472:0"
    assert grafana["read_only"] is True
    assert "ALL" in grafana["cap_drop"]
    assert "no-new-privileges:true" in grafana["security_opt"]
    assert grafana["networks"] == {"default": None, "metrics": None}
    assert grafana["depends_on"]["prometheus"]["condition"] == "service_started"
    assert grafana["environment"]["GF_SECURITY_ADMIN_PASSWORD__FILE"] == (
        "/run/atermius-secrets/admin-password"
    )
    assert grafana["environment"]["GF_AUTH_ANONYMOUS_ENABLED"] == "false"
    assert grafana["environment"]["GF_USERS_ALLOW_SIGN_UP"] == "false"
    assert grafana["environment"]["GF_PLUGINS_PREINSTALL_AUTO_UPDATE"] == "false"
    assert not any(
        key in grafana["environment"]
        for key in ("GF_SECURITY_ADMIN_PASSWORD", "GF_SECURITY_ADMIN_PASSWORD__FILE_CONTENT")
    )
    assert not any("metrics-token" in volume.get("source", "") for volume in grafana["volumes"])
    ports = grafana["ports"]
    assert len(ports) == 1
    assert ports[0]["host_ip"] == "127.0.0.1"
    assert ports[0]["target"] == 3000
    assert ports[0]["published"] == "13000"

    mounts = {volume["target"]: volume for volume in grafana["volumes"]}
    assert mounts["/etc/grafana/provisioning"]["read_only"] is True
    assert mounts["/etc/grafana/dashboards"]["read_only"] is True
    password_mount = mounts["/run/atermius-secrets"]
    assert password_mount["source"] == "/srv/atermius-grafana-secrets/"
    assert password_mount["read_only"] is True
    assert mounts["/var/lib/grafana"]["type"] == "volume"
    assert mounts["/var/lib/grafana"]["source"] == "grafana-data"
    assert config["volumes"]["grafana-data"]["name"].endswith("_grafana-data")
    assert config["volumes"]["grafana-data"]["name"] != config["volumes"]["prometheus-data"]["name"]
    assert config["volumes"]["grafana-data"]["name"] != config["volumes"]["server-data"]["name"]

    datasource_config = yaml.safe_load(
        (ROOT / "deploy/grafana/provisioning/datasources/atermius-prometheus.yaml").read_text()
    )
    datasource = datasource_config["datasources"][0]
    assert datasource["uid"] == "atermius-prometheus"
    assert datasource["url"] == "http://prometheus:9090"
    assert datasource["editable"] is False
    assert "secureJsonData" not in datasource
    dashboard_provider = yaml.safe_load(
        (ROOT / "deploy/grafana/provisioning/dashboards/atermius.yaml").read_text()
    )["providers"][0]
    assert dashboard_provider["updateIntervalSeconds"] > 10
    assert dashboard_provider["allowUiUpdates"] is False
    assert dashboard_provider["options"]["path"] == "/etc/grafana/dashboards"

    dashboard = json.loads(
        (ROOT / "deploy/grafana/dashboards/atermius-instance-overview.json").read_text()
    )
    assert dashboard["uid"] == "atermius-instance-overview"
    queries = {
        target["expr"] for panel in dashboard["panels"] for target in panel["targets"]
    }
    assert queries == {
        "atermius_accounts",
        "atermius_vaults",
        "atermius_devices_active",
        "atermius_ssh_relay_enabled",
        "atermius_blob_stored_bytes",
        "atermius_upload_reserved_bytes",
        "atermius_vault_quota_bytes",
        'up{job="atermius"}',
        'sum(ALERTS{job="atermius",alertstate="firing"}) or vector(0)',
    }
    assert len(dashboard["panels"]) == 9
    serialized = json.dumps(dashboard)
    assert "metrics-token" not in serialized
    assert "secureJsonData" not in serialized
