"""End-to-end acceptance for the optional Prometheus Compose collector."""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url, redact_secrets
from test_acceptance import _new_account_registration


COMPOSE_FILE = ROOT / "deploy" / "compose.yaml"
PROMETHEUS_FILE = ROOT / "deploy" / "compose.prometheus.yaml"
PROMETHEUS_UID = 65534
METRICS_PATH = "/api/v1/admin/metrics"
CREDENTIAL_PATH = "/api/v1/admin/metrics-credential"


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _compose(
    project: str,
    env_file: Path,
    env: dict[str, str],
    *args: str,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    command = [
        "docker",
        "compose",
        "--project-name",
        project,
        "--env-file",
        str(env_file),
        "--file",
        str(COMPOSE_FILE),
        "--file",
        str(PROMETHEUS_FILE),
        *args,
    ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _diagnostic(result: subprocess.CompletedProcess[str], *secrets: str) -> str:
    return redact_secrets(result.stdout + "\n" + result.stderr, *secrets)[-5000:]


def _compose_available() -> None:
    if not shutil.which("docker"):
        pytest.skip("Prometheus Compose acceptance requires the docker CLI")
    try:
        info = subprocess.run(
            ["docker", "info", "--format", "{{.ServerVersion}}"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        compose = subprocess.run(
            ["docker", "compose", "version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pytest.skip("Docker Engine or Compose is unavailable")
    if info.returncode != 0 or compose.returncode != 0:
        pytest.skip("Docker Engine or Compose is unavailable")
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        pytest.skip("real Compose credential acceptance needs root to provision UID-owned secret files")


def _docker_names(*args: str) -> set[str]:
    result = subprocess.run(
        ["docker", *args],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, "could not inspect disposable Docker resources"
    return set(result.stdout.splitlines())


def _write_credential(secret_dir: Path, credential: str) -> Path:
    """Atomically install the scrape value with the pinned image's read access."""
    destination = secret_dir / "metrics-token"
    temporary = secret_dir / f".metrics-token.{uuid.uuid4().hex}.next"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o400)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(credential.encode("ascii") + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.chown(temporary, PROMETHEUS_UID, PROMETHEUS_UID)
        os.chmod(temporary, 0o400)
        os.replace(temporary, destination)
        directory_fd = os.open(secret_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    metadata = destination.stat()
    assert stat.S_IMODE(metadata.st_mode) == 0o400
    assert metadata.st_uid == PROMETHEUS_UID and metadata.st_gid == PROMETHEUS_UID
    return destination


def _get_json(url: str, *, timeout: float = 5) -> tuple[int, dict[str, Any]]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        try:
            payload = json.loads(error.read())
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        return error.code, payload


def _prometheus_query(base_url: str, expression: str, *, at: float | None = None) -> list[dict[str, Any]]:
    params = {"query": expression}
    if at is not None:
        params["time"] = repr(at)
    status, body = _get_json(base_url + "/api/v1/query?" + urllib.parse.urlencode(params))
    assert status == 200 and body.get("status") == "success", "Prometheus query API failed"
    result = (body.get("data") or {}).get("result")
    assert isinstance(result, list), "Prometheus query returned a malformed result"
    return result


def _wait_prometheus_ready(base_url: str, timeout: float = 90) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(base_url + "/-/ready", timeout=3) as response:
                if response.status == 200:
                    return True
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.25)
    return False


def _wait_up(base_url: str, expected: str, timeout: float = 75) -> list[dict[str, Any]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = _prometheus_query(base_url, 'up{job="atermius"}')
            if result and result[0].get("value", [None, None])[1] == expected:
                return result
        except (AssertionError, OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(0.5)
    pytest.fail(f"Prometheus target did not reach up={expected}")


def _wait_up_after(base_url: str, expected: str, not_before: float, timeout: float = 75) -> None:
    """Require a new scrape after the credential file was replaced."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            up = _prometheus_query(base_url, 'up{job="atermius"}')
            scrape_times = _prometheus_query(base_url, 'timestamp(up{job="atermius"})')
            if (
                up
                and up[0].get("value", [None, None])[1] == expected
                and scrape_times
                and float(scrape_times[0]["value"][1]) > not_before
            ):
                return
        except (AssertionError, OSError, urllib.error.URLError, json.JSONDecodeError, ValueError):
            pass
        time.sleep(0.5)
    pytest.fail(f"Prometheus did not complete a post-rotation scrape with up={expected}")


def test_compose_prometheus_scrapes_rotates_revokes_and_persists(tmp_path: Path) -> None:
    """PROM-COMPOSE: exercise auth, file rotation, revocation and TSDB reuse."""
    _compose_available()

    tag = uuid.uuid4().hex[:14]
    project = f"atermius-prom-{tag}"
    server_volume = f"{project}-server-data"
    prometheus_volume = f"{project}_prometheus-data"
    existing_volumes = _docker_names("volume", "ls", "--quiet")
    assert server_volume not in existing_volumes and prometheus_volume not in existing_volumes

    work_dir = tmp_path / "prometheus-acceptance"
    work_dir.mkdir(mode=0o700)
    secret_dir = work_dir / "secrets"
    secret_dir.mkdir(mode=0o750)
    try:
        os.chown(secret_dir, 0, PROMETHEUS_UID)
    except PermissionError:
        shutil.rmtree(work_dir, ignore_errors=True)
        pytest.skip("Docker host cannot provision the Prometheus container's secret-file ownership")
    os.chmod(secret_dir, 0o750)
    env_file = work_dir / "compose.env"
    port = _free_port()
    prometheus_port = _free_port()
    assert prometheus_port != port
    base_url = f"http://127.0.0.1:{port}"
    prometheus_url = f"http://127.0.0.1:{prometheus_port}"
    username = f"prometheus-admin-{tag}@example.test"
    env_file.write_text(
        "\n".join(
            [
                f"ATERMIUS_HOST_PORT={port}",
                f"ATERMIUS_DATA_VOLUME_NAME={server_volume}",
                "ATERMIUS_DATA_DIR=/data",
                "ATERMIUS_DATABASE_URL=sqlite:///data/atermius.db?mode=rwc",
                f"ATERMIUS_PUBLIC_ORIGIN={base_url}",
                f"ATERMIUS_ADMIN_USERNAMES={username}",
                f"ATERMIUS_PROMETHEUS_HOST_PORT={prometheus_port}",
                f"ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR={secret_dir}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    os.chmod(env_file, 0o600)
    compose_env = {
        key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")
    }

    secrets: list[str] = []
    try:
        prebuilt_image = os.environ.get("ATERMIUS_COMPOSE_TEST_IMAGE")
        extra_files: tuple[Path, ...] = ()
        if prebuilt_image:
            image_override = work_dir / "image.compose.yaml"
            image_override.write_text(
                "services:\n  server:\n    image: \"${ATERMIUS_IMAGE}\"\n",
                encoding="utf-8",
            )
            os.chmod(image_override, 0o600)
            compose_env["ATERMIUS_IMAGE"] = prebuilt_image
            extra_files = (image_override,)

        def compose(*args: str, timeout: int = 180) -> subprocess.CompletedProcess[str]:
            if extra_files:
                # Use the standard helper, then append the optional local image override.
                command = [
                    "docker",
                    "compose",
                    "--project-name",
                    project,
                    "--env-file",
                    str(env_file),
                    "--file",
                    str(COMPOSE_FILE),
                    "--file",
                    str(PROMETHEUS_FILE),
                    "--file",
                    str(extra_files[0]),
                    *args,
                ]
                return subprocess.run(
                    command,
                    cwd=ROOT,
                    env=compose_env,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    check=False,
                )
            return _compose(project, env_file, compose_env, *args, timeout=timeout)

        started = compose("up", "-d", "--build", "server", timeout=1200)
        assert started.returncode == 0, "Compose server startup failed:\n" + _diagnostic(started, *secrets)

        api = ApiClient(base_url)
        ready_deadline = time.monotonic() + 180
        while time.monotonic() < ready_deadline:
            try:
                if api.request("GET", "/health/ready").status == 200:
                    break
            except OSError:
                pass
            time.sleep(0.25)
        else:
            logs = compose("logs", "--no-color", "server")
            pytest.fail("Compose server did not become ready:\n" + _diagnostic(logs, *secrets))

        bootstrapped = compose(
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "bootstrap",
        )
        if bootstrapped.returncode != 0:
            pytest.fail("Compose bootstrap failed:\n" + _diagnostic(bootstrapped, *secrets))
        bootstrap_candidates = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            bootstrapped.stdout,
        )
        assert bootstrap_candidates, "Compose bootstrap did not return its one-time token"
        bootstrap_token = bootstrap_candidates[-1]
        secrets.append(bootstrap_token)
        del bootstrapped, bootstrap_candidates

        signer = SigningKey(work_dir, "prometheus-admin")
        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        registration = _new_account_registration(
            account_id,
            username,
            device_id,
            b64url(os.urandom(32)),
            signer,
        )
        registration["bootstrap_token"] = bootstrap_token
        registered = api.request("POST", "/api/v1/auth/register", json_body=registration)
        assert registered.status in (200, 201), "Compose admin registration failed"
        admin_token = registered.json().get("access_token")
        assert isinstance(admin_token, str) and admin_token
        secrets.append(admin_token)
        del bootstrap_token, registration, registered

        first = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert first.status == 200, "initial Prometheus credential creation failed"
        first_credential = first.json().get("credential")
        assert isinstance(first_credential, str) and re.fullmatch(
            r"atm_[A-Za-z0-9_-]{43}", first_credential
        ), "initial Prometheus credential response had an invalid shape"
        secrets.append(first_credential)
        _write_credential(secret_dir, first_credential)
        del first_credential, first

        config_check = compose(
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "/bin/promtool",
            "prometheus",
            "check",
            "config",
            "/etc/prometheus/prometheus.yml",
        )
        assert config_check.returncode == 0, "Prometheus configuration validation failed:\n" + _diagnostic(
            config_check, *secrets
        )

        rendered = compose("config", "--format", "json")
        assert rendered.returncode == 0, "rendered Compose config failed"
        for secret in secrets:
            assert secret not in rendered.stdout, "rendered Compose config exposed credential material"

        started_prometheus = compose("up", "-d", "prometheus")
        assert started_prometheus.returncode == 0, "Prometheus startup failed:\n" + _diagnostic(
            started_prometheus, *secrets
        )
        if not _wait_prometheus_ready(prometheus_url):
            logs = compose("logs", "--no-color", "prometheus")
            pytest.fail("Prometheus did not become ready:\n" + _diagnostic(logs, *secrets))
        initial_up = _wait_up(prometheus_url, "1")
        assert initial_up[0].get("metric", {}).get("job") == "atermius"

        active_accounts = _prometheus_query(
            prometheus_url, 'atermius_accounts{status="active"}'
        )
        assert active_accounts, "fixed account gauge was not stored in Prometheus"
        saved_timestamp = float(active_accounts[0]["value"][0])
        assert active_accounts[0]["value"][1] == "1"
        backup_last_success = _prometheus_query(
            prometheus_url, "atermius_backup_last_success_timestamp_seconds"
        )
        assert backup_last_success, "fixed local backup timestamp gauge was not stored"
        assert backup_last_success[0]["value"][1] == "0"
        all_samples = _prometheus_query(prometheus_url, '{__name__=~"atermius_.*"}')
        target_labels = (("instance", "server:8080"), ("job", "atermius"))
        expected_series = {
            ("atermius_accounts", tuple(sorted((*target_labels, ("status", "active"))))),
            ("atermius_accounts", tuple(sorted((*target_labels, ("status", "deleting"))))),
            ("atermius_accounts", tuple(sorted((*target_labels, ("status", "disabled"))))),
            ("atermius_devices_active", tuple(sorted(target_labels))),
            ("atermius_vaults", tuple(sorted((*target_labels, ("state", "active"))))),
            ("atermius_vaults", tuple(sorted((*target_labels, ("state", "deleting"))))),
            ("atermius_blob_stored_bytes", tuple(sorted(target_labels))),
            ("atermius_upload_reserved_bytes", tuple(sorted(target_labels))),
            (
                "atermius_object_delete_queue",
                tuple(sorted((*target_labels, ("state", "pending")))),
            ),
            (
                "atermius_object_delete_queue",
                tuple(sorted((*target_labels, ("state", "retry_wait")))),
            ),
            (
                "atermius_object_delete_queue",
                tuple(sorted((*target_labels, ("state", "quarantined")))),
            ),
            (
                "atermius_backup_last_success_timestamp_seconds",
                tuple(sorted(target_labels)),
            ),
            ("atermius_vault_quota_bytes", tuple(sorted(target_labels))),
            ("atermius_ssh_relay_enabled", tuple(sorted(target_labels))),
        }
        actual_series = set()
        for sample in all_samples:
            metric = sample.get("metric", {})
            labels = tuple(
                sorted((key, value) for key, value in metric.items() if key != "__name__")
            )
            assert float(sample["value"][1]) >= 0
            actual_series.add((metric.get("__name__"), labels))
        assert actual_series == expected_series, "Prometheus did not store the fixed metrics series set"

        rotated = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert rotated.status == 200, "Prometheus credential rotation failed"
        second_credential = rotated.json().get("credential")
        assert isinstance(second_credential, str) and re.fullmatch(
            r"atm_[A-Za-z0-9_-]{43}", second_credential
        ), "rotated Prometheus credential response had an invalid shape"
        secrets.append(second_credential)
        old_credential_rejected = api.request("GET", METRICS_PATH, token=secrets[-2])
        assert old_credential_rejected.status == 401, "rotation did not reject the prior credential"
        _write_credential(secret_dir, second_credential)
        rotated_at = time.time()
        del second_credential, rotated, old_credential_rejected
        _wait_up_after(prometheus_url, "1", rotated_at)

        revoked = api.request("DELETE", CREDENTIAL_PATH, token=admin_token)
        assert revoked.status == 200, "Prometheus credential revocation failed"
        assert api.request("GET", METRICS_PATH, token=secrets[-1]).status == 401, (
            "revocation did not reject the active credential"
        )
        _wait_up(prometheus_url, "0")

        recreated = compose("up", "-d", "--force-recreate", "prometheus")
        assert recreated.returncode == 0, "Prometheus recreation failed:\n" + _diagnostic(
            recreated, *secrets
        )
        if not _wait_prometheus_ready(prometheus_url):
            logs = compose("logs", "--no-color", "prometheus")
            pytest.fail("recreated Prometheus did not become ready:\n" + _diagnostic(logs, *secrets))
        persisted = _prometheus_query(
            prometheus_url,
            'atermius_accounts{status="active"}',
            at=saved_timestamp,
        )
        assert persisted, "pre-recreation TSDB sample was lost"
        assert float(persisted[0]["value"][0]) == saved_timestamp
        _wait_up(prometheus_url, "0")

        logs = compose("logs", "--no-color", "server", "prometheus")
        assert logs.returncode == 0, "could not read Compose service logs"
        for secret in secrets:
            assert secret not in logs.stdout and secret not in logs.stderr, (
                "server or Prometheus logs exposed credential material"
            )
    finally:
        try:
            cleanup = _compose(
                project,
                env_file,
                compose_env,
                "down",
                "--volumes",
                "--remove-orphans",
                timeout=180,
            )
            assert cleanup.returncode == 0, "disposable Compose project cleanup failed"
            remaining_volumes = _docker_names("volume", "ls", "--quiet")
            assert server_volume not in remaining_volumes and prometheus_volume not in remaining_volumes, (
                "disposable Compose volumes remain after cleanup"
            )
            remaining_containers = _docker_names(
                "ps", "--all", "--quiet", "--filter", f"label=com.docker.compose.project={project}"
            )
            assert not remaining_containers, "disposable Compose containers remain after cleanup"
            remaining_networks = _docker_names(
                "network", "ls", "--filter", f"label=com.docker.compose.project={project}", "--format", "{{.Name}}"
            )
            assert not remaining_networks, "disposable Compose networks remain after cleanup"
        finally:
            shutil.rmtree(work_dir, ignore_errors=False)
