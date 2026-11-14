"""End-to-end acceptance for the optional Grafana metrics dashboard."""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import stat
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url, redact_secrets
from test_acceptance import _new_account_registration
from test_compose_prometheus import (
    CREDENTIAL_PATH,
    PROMETHEUS_FILE,
    PROMETHEUS_UID,
    _compose_available,
    _diagnostic,
    _docker_names,
    _free_port,
    _get_json,
    _write_credential,
)


COMPOSE_FILE = ROOT / "deploy" / "compose.yaml"
GRAFANA_FILE = ROOT / "deploy" / "compose.grafana.yaml"
GRAFANA_UID = 472
GRAFANA_USER = "admin"
GRAFANA_DASHBOARD_UID = "atermius-instance-overview"
FIRING_ALERTS_QUERY = 'sum(ALERTS{job="atermius",alertstate="firing"}) or vector(0)'


def _compose(
    project: str,
    env_file: Path,
    env: dict[str, str],
    *args: str,
    extra_files: tuple[Path, ...] = (),
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
        "--file",
        str(GRAFANA_FILE),
    ]
    for path in extra_files:
        command.extend(("--file", str(path)))
    command.extend(args)
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _write_admin_password(secret_dir: Path, password: str) -> Path:
    destination = secret_dir / "admin-password"
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o400)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(password.encode("ascii"))
            output.flush()
            os.fsync(output.fileno())
        os.chown(destination, GRAFANA_UID, 0)
        os.chmod(destination, 0o400)
    finally:
        if destination.exists():
            metadata = destination.stat()
            assert stat.S_IMODE(metadata.st_mode) == 0o400
            assert metadata.st_uid == GRAFANA_UID and metadata.st_gid == 0
    return destination


def _grafana_json(
    base_url: str,
    path: str,
    *,
    password: str | None = None,
    body: dict[str, Any] | None = None,
    timeout: float = 5,
) -> tuple[int, dict[str, Any]]:
    headers = {"Accept": "application/json"}
    if password is not None:
        basic = base64.b64encode(f"{GRAFANA_USER}:{password}".encode("ascii")).decode("ascii")
        headers["Authorization"] = f"Basic {basic}"
    encoded_body = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        encoded_body = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(base_url + path, data=encoded_body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        try:
            payload = json.loads(error.read())
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        return error.code, payload


def _wait_grafana_ready(base_url: str, timeout: float = 90) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            status, body = _get_json(base_url + "/api/health")
            if status == 200 and body.get("database") == "ok":
                return True
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(0.25)
    return False


def _grafana_proxy_query(
    base_url: str,
    password: str,
    expression: str,
    *,
    at: float | None = None,
) -> list[dict[str, Any]]:
    now_ms = int((at if at is not None else time.time()) * 1000)
    payload = {
        "from": str(now_ms - 300_000),
        "to": str(now_ms),
        "queries": [
            {
                "datasource": {"type": "prometheus", "uid": "atermius-prometheus"},
                "expr": expression,
                "format": "time_series",
                "instant": True,
                "intervalMs": 1000,
                "maxDataPoints": 1000,
                "range": False,
                "refId": "A",
            }
        ],
    }
    status, body = _grafana_json(
        base_url,
        "/api/ds/query",
        password=password,
        body=payload,
    )
    query_result = (body.get("results") or {}).get("A")
    if status != 200 or not isinstance(query_result, dict) or query_result.get("status") != 200:
        safe_body = redact_secrets(json.dumps(body, sort_keys=True), password or "")[:500]
        raise AssertionError(
            f"Grafana datasource query returned HTTP {status}, response={safe_body}"
        )
    frames = query_result.get("frames")
    assert isinstance(frames, list), "Grafana datasource query returned malformed frames"
    result: list[dict[str, Any]] = []
    for frame in frames:
        schema = frame.get("schema") or {}
        fields = schema.get("fields") or []
        values = (frame.get("data") or {}).get("values") or []
        time_index = next(
            (index for index, field in enumerate(fields) if field.get("name") == "Time"),
            None,
        )
        value_indexes = [
            index
            for index, field in enumerate(fields)
            if field.get("type") == "number" and index < len(values)
        ]
        timestamps = values[time_index] if time_index is not None and time_index < len(values) else []
        for value_index in value_indexes:
            sample_values = values[value_index]
            labels = (fields[value_index].get("labels") or {}).copy()
            labels.pop("__name__", None)
            for index, sample_value in enumerate(sample_values):
                timestamp = timestamps[index] if index < len(timestamps) else now_ms
                timestamp = float(timestamp)
                if timestamp > 10_000_000_000:
                    timestamp /= 1000
                result.append(
                    {
                        "metric": labels,
                        "value": [str(timestamp), str(sample_value)],
                    }
                )
    return result


def _wait_grafana_scalar(
    base_url: str,
    password: str,
    expression: str,
    expected: float,
    *,
    timeout: float = 100,
) -> None:
    deadline = time.monotonic() + timeout
    last_result: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        try:
            last_result = _grafana_proxy_query(base_url, password, expression)
            if len(last_result) == 1 and float(last_result[0]["value"][1]) == expected:
                return
        except (AssertionError, OSError, urllib.error.URLError, json.JSONDecodeError, ValueError, KeyError):
            pass
        time.sleep(0.5)
    pytest.fail(
        f"Grafana query did not reach {expected:g}: {expression}; "
        f"observed {last_result[:2]!r}"
    )


def _dashboard_payload(base_url: str, password: str) -> tuple[dict[str, Any], dict[str, Any]]:
    status, body = _grafana_json(
        base_url,
        f"/api/dashboards/uid/{GRAFANA_DASHBOARD_UID}",
        password=password,
    )
    assert status == 200, "provisioned Grafana dashboard was not available"
    dashboard = body.get("dashboard")
    assert isinstance(dashboard, dict), "Grafana dashboard response was malformed"
    return dashboard, body.get("meta") or {}


def test_grafana_dashboard_provisions_queries_and_survives_recreation(tmp_path: Path) -> None:
    """GRAFANA-COMPOSE: provision the dashboard and query real private metrics."""
    _compose_available()

    tag = uuid.uuid4().hex[:14]
    project = f"atermius-grafana-{tag}"
    server_volume = f"{project}-server-data"
    prometheus_volume = f"{project}_prometheus-data"
    grafana_volume = f"{project}_grafana-data"
    existing_volumes = _docker_names("volume", "ls", "--quiet")
    assert not {server_volume, prometheus_volume, grafana_volume} & existing_volumes

    work_dir = tmp_path / "grafana-acceptance"
    work_dir.mkdir(mode=0o700)
    prometheus_secret_dir = work_dir / "prometheus-secrets"
    grafana_secret_dir = work_dir / "grafana-secrets"
    prometheus_secret_dir.mkdir(mode=0o750)
    grafana_secret_dir.mkdir(mode=0o750)
    try:
        os.chown(prometheus_secret_dir, 0, PROMETHEUS_UID)
        os.chown(grafana_secret_dir, 0, 0)
    except PermissionError:
        shutil.rmtree(work_dir, ignore_errors=True)
        pytest.skip("Docker host cannot provision the pinned collectors' secret-file ownership")
    os.chmod(prometheus_secret_dir, 0o750)
    os.chmod(grafana_secret_dir, 0o750)

    env_file = work_dir / "compose.env"
    server_port = _free_port()
    prometheus_port = _free_port()
    grafana_port = _free_port()
    assert len({server_port, prometheus_port, grafana_port}) == 3
    server_url = f"http://127.0.0.1:{server_port}"
    grafana_url = f"http://127.0.0.1:{grafana_port}"
    username = f"grafana-admin-{tag}@example.test"
    admin_password = "AtermiusGrafana-" + uuid.uuid4().hex + "-acceptance"
    password_path = _write_admin_password(grafana_secret_dir, admin_password)
    env_file.write_text(
        "\n".join(
            [
                f"ATERMIUS_HOST_PORT={server_port}",
                f"ATERMIUS_DATA_VOLUME_NAME={server_volume}",
                "ATERMIUS_DATA_DIR=/data",
                "ATERMIUS_DATABASE_URL=sqlite:///data/atermius.db?mode=rwc",
                f"ATERMIUS_PUBLIC_ORIGIN={server_url}",
                f"ATERMIUS_ADMIN_USERNAMES={username}",
                f"ATERMIUS_PROMETHEUS_HOST_PORT={prometheus_port}",
                f"ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR={prometheus_secret_dir}",
                f"ATERMIUS_GRAFANA_HOST_PORT={grafana_port}",
                f"ATERMIUS_GRAFANA_ADMIN_PASSWORD_HOST_DIR={grafana_secret_dir}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    os.chmod(env_file, 0o600)
    compose_env = {key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")}
    secrets: list[str] = [admin_password]
    extra_files: tuple[Path, ...] = ()

    try:
        prebuilt_image = os.environ.get("ATERMIUS_COMPOSE_TEST_IMAGE")
        if prebuilt_image:
            image_override = work_dir / "image.compose.yaml"
            image_override.write_text(
                "services:\n  server:\n    image: \"${ATERMIUS_IMAGE}\"\n",
                encoding="utf-8",
            )
            os.chmod(image_override, 0o600)
            compose_env["ATERMIUS_IMAGE"] = prebuilt_image
            extra_files = (image_override,)

        started = _compose(
            project,
            env_file,
            compose_env,
            "up",
            "-d",
            "--build",
            "server",
            extra_files=extra_files,
            timeout=1200,
        )
        assert started.returncode == 0, "Compose server startup failed:\n" + _diagnostic(started, *secrets)

        api = ApiClient(server_url)
        ready_deadline = time.monotonic() + 180
        while time.monotonic() < ready_deadline:
            try:
                if api.request("GET", "/health/ready").status == 200:
                    break
            except OSError:
                pass
            time.sleep(0.25)
        else:
            logs = _compose(project, env_file, compose_env, "logs", "--no-color", "server", extra_files=extra_files)
            pytest.fail("Compose server did not become ready:\n" + _diagnostic(logs, *secrets))

        bootstrapped = _compose(
            project,
            env_file,
            compose_env,
            "exec",
            "-T",
            "server",
            "/usr/local/bin/atermius-server",
            "bootstrap",
            extra_files=extra_files,
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

        signer = SigningKey(work_dir, "grafana-admin")
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

        created = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert created.status == 200, "Prometheus credential creation failed"
        scrape_credential = created.json().get("credential")
        assert isinstance(scrape_credential, str) and re.fullmatch(
            r"atm_[A-Za-z0-9_-]{43}", scrape_credential
        ), "Prometheus credential response had an invalid shape"
        secrets.append(scrape_credential)
        _write_credential(prometheus_secret_dir, scrape_credential)
        del created, scrape_credential

        rendered = _compose(
            project,
            env_file,
            compose_env,
            "config",
            "--format",
            "json",
            extra_files=extra_files,
        )
        assert rendered.returncode == 0, "rendered Compose config failed"
        for secret in secrets:
            assert secret not in rendered.stdout, "Compose config exposed secret material"
        config = json.loads(rendered.stdout)
        assert set(config["services"]) == {"server", "prometheus", "grafana"}
        grafana_service = config["services"]["grafana"]
        assert grafana_service["environment"]["GF_SECURITY_ADMIN_PASSWORD__FILE"] == (
            "/run/atermius-secrets/admin-password"
        )
        assert str(password_path) not in rendered.stdout
        assert admin_password not in rendered.stdout

        rule_check = _compose(
            project,
            env_file,
            compose_env,
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "/bin/promtool",
            "prometheus",
            "check",
            "rules",
            "/etc/prometheus/atermius-alerts.yml",
            extra_files=extra_files,
        )
        assert rule_check.returncode == 0, "Prometheus alert rule validation failed:\n" + _diagnostic(
            rule_check, *secrets
        )

        started_metrics = _compose(
            project,
            env_file,
            compose_env,
            "up",
            "-d",
            "prometheus",
            "grafana",
            extra_files=extra_files,
        )
        assert started_metrics.returncode == 0, "collector startup failed:\n" + _diagnostic(
            started_metrics, *secrets
        )
        if not _wait_grafana_ready(grafana_url):
            logs = _compose(
                project,
                env_file,
                compose_env,
                "logs",
                "--no-color",
                "prometheus",
                "grafana",
                extra_files=extra_files,
            )
            pytest.fail("Grafana did not become ready:\n" + _diagnostic(logs, *secrets))
        health_status, health = _get_json(grafana_url + "/api/health")
        assert health_status == 200 and health.get("version") == "13.2.3", (
            "Grafana runtime version does not match the pinned Compose image"
        )

        unauthenticated_status, _ = _grafana_json(
            grafana_url,
            f"/api/dashboards/uid/{GRAFANA_DASHBOARD_UID}",
        )
        assert unauthenticated_status == 401, "Grafana dashboard API is reachable without login"

        datasource_status, datasource = _grafana_json(
            grafana_url,
            "/api/datasources/uid/atermius-prometheus",
            password=admin_password,
        )
        assert datasource_status == 200, "Grafana Prometheus datasource was not provisioned"
        assert datasource.get("type") == "prometheus"
        assert datasource.get("url") == "http://prometheus:9090"
        assert datasource.get("isDefault") is True
        assert datasource.get("readOnly") is True

        dashboard, metadata = _dashboard_payload(grafana_url, admin_password)
        assert dashboard.get("title") == "Atermius Instance Overview"
        assert metadata.get("folderTitle") == "Atermius"
        assert dashboard.get("editable") is False
        panels = dashboard.get("panels")
        assert isinstance(panels, list) and len(panels) == 9
        expected_queries = {
            "atermius_accounts",
            "atermius_vaults",
            "atermius_devices_active",
            "atermius_ssh_relay_enabled",
            "atermius_blob_stored_bytes",
            "atermius_upload_reserved_bytes",
            "atermius_vault_quota_bytes",
            'up{job="atermius"}',
            FIRING_ALERTS_QUERY,
        }
        actual_queries = {
            target.get("expr")
            for panel in panels
            for target in panel.get("targets", [])
        }
        assert actual_queries == expected_queries, "dashboard does not cover the fixed metrics set"
        assert all(
            panel.get("datasource", {}).get("uid") == "atermius-prometheus"
            for panel in panels
        ), "dashboard panel references an unexpected datasource"

        deadline = time.monotonic() + 90
        metric_sample: list[dict[str, Any]] = []
        last_query_error = "no query attempted"
        while time.monotonic() < deadline:
            try:
                metric_sample = _grafana_proxy_query(
                    grafana_url,
                    admin_password,
                    'atermius_accounts{status="active"}',
                )
                if metric_sample:
                    break
            except (AssertionError, OSError, urllib.error.URLError, json.JSONDecodeError) as error:
                last_query_error = f"{type(error).__name__}: {str(error)[:500]}"
            time.sleep(0.5)
        assert metric_sample, f"Grafana could not query the live Prometheus datasource ({last_query_error})"
        assert metric_sample[0].get("metric", {}).get("status") == "active"
        assert metric_sample[0].get("value", [None, None])[1] == "1"
        saved_timestamp = float(metric_sample[0]["value"][0])

        samples = {
            expression: _grafana_proxy_query(grafana_url, admin_password, expression)
            for expression in sorted(expected_queries - {'up{job="atermius"}'})
        }
        assert all(samples.values()), "one or more dashboard queries returned no samples"
        for expression, result in samples.items():
            assert all(float(sample["value"][1]) >= 0 for sample in result)
            if expression == FIRING_ALERTS_QUERY:
                assert len(result) == 1 and result[0].get("metric") == {}
                assert float(result[0]["value"][1]) == 0
                continue
            expected_labels = {"instance", "job"}
            if expression == "atermius_accounts":
                expected_labels.add("status")
            elif expression == "atermius_vaults":
                expected_labels.add("state")
            assert all(set(sample["metric"]) == expected_labels for sample in result), (
                "Grafana query exposed a label outside the fixed aggregate metric schema"
            )
        scrape_status = _grafana_proxy_query(
            grafana_url,
            admin_password,
            'up{job="atermius"}',
        )
        assert scrape_status and scrape_status[0].get("value", [None, None])[1] == "1"
        assert set(scrape_status[0]["metric"]) == {"instance", "job"}

        revoked = api.request("DELETE", CREDENTIAL_PATH, token=admin_token)
        assert revoked.status == 200, "Prometheus scrape credential revocation failed"
        assert api.request("GET", "/api/v1/admin/metrics", token=secrets[-1]).status == 401, (
            "revoked scrape credential still reads metrics"
        )
        _wait_grafana_scalar(grafana_url, admin_password, FIRING_ALERTS_QUERY, 1)

        recreated_credential = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert recreated_credential.status == 200, "Prometheus scrape credential recreation failed"
        new_scrape_credential = recreated_credential.json().get("credential")
        assert isinstance(new_scrape_credential, str) and re.fullmatch(
            r"atm_[A-Za-z0-9_-]{43}", new_scrape_credential
        ), "recreated Prometheus credential had an invalid shape"
        secrets.append(new_scrape_credential)
        _write_credential(prometheus_secret_dir, new_scrape_credential)
        del new_scrape_credential, recreated_credential, revoked
        _wait_grafana_scalar(grafana_url, admin_password, 'up{job="atermius"}', 1)
        _wait_grafana_scalar(grafana_url, admin_password, FIRING_ALERTS_QUERY, 0)

        recreated = _compose(
            project,
            env_file,
            compose_env,
            "up",
            "-d",
            "--force-recreate",
            "grafana",
            extra_files=extra_files,
        )
        assert recreated.returncode == 0, "Grafana recreation failed:\n" + _diagnostic(
            recreated, *secrets
        )
        assert _wait_grafana_ready(grafana_url), "recreated Grafana did not become ready"
        recreated_dashboard, _ = _dashboard_payload(grafana_url, admin_password)
        assert recreated_dashboard.get("uid") == GRAFANA_DASHBOARD_UID
        persisted = _grafana_proxy_query(
            grafana_url,
            admin_password,
            'atermius_accounts{status="active"}',
            at=saved_timestamp,
        )
        assert persisted and float(persisted[0]["value"][0]) == saved_timestamp, (
            "historical Prometheus sample was unavailable through Grafana after recreation"
        )

        logs = _compose(
            project,
            env_file,
            compose_env,
            "logs",
            "--no-color",
            "prometheus",
            "grafana",
            extra_files=extra_files,
        )
        assert logs.returncode == 0, "could not read collector service logs"
        for secret in secrets:
            assert secret not in logs.stdout and secret not in logs.stderr, (
                "collector logs exposed secret material"
            )
        assert username not in logs.stdout and username not in logs.stderr, (
            "Grafana collector logs exposed the fixture account identifier"
        )
        dashboard_json = json.dumps(dashboard, sort_keys=True)
        assert username not in dashboard_json
        assert all(secret not in dashboard_json for secret in secrets)
        assert datasource.get("secureJsonFields") in (None, {})
        assert username not in json.dumps(datasource, sort_keys=True)
    finally:
        try:
            cleanup = _compose(
                project,
                env_file,
                compose_env,
                "down",
                "--volumes",
                "--remove-orphans",
                extra_files=extra_files,
                timeout=180,
            )
            assert cleanup.returncode == 0, "disposable Grafana Compose cleanup failed"
            remaining_volumes = _docker_names("volume", "ls", "--quiet")
            assert not {server_volume, prometheus_volume, grafana_volume} & remaining_volumes, (
                "disposable Compose volumes remain after cleanup"
            )
            remaining_containers = _docker_names(
                "ps",
                "--all",
                "--quiet",
                "--filter",
                f"label=com.docker.compose.project={project}",
            )
            assert not remaining_containers, "disposable Compose containers remain after cleanup"
            remaining_networks = _docker_names(
                "network",
                "ls",
                "--filter",
                f"label=com.docker.compose.project={project}",
                "--format",
                "{{.Name}}",
            )
            assert not remaining_networks, "disposable Compose networks remain after cleanup"
        finally:
            shutil.rmtree(work_dir, ignore_errors=False)
