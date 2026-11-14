"""Disposable Compose acceptance for the optional Alertmanager webhook path."""

from __future__ import annotations

import json
import ipaddress
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from conftest import ApiClient, ROOT, SigningKey, b64url
from test_acceptance import _new_account_registration
from test_compose_prometheus import (
    CREDENTIAL_PATH,
    METRICS_PATH,
    _compose_available,
    _diagnostic,
    _docker_names,
    _free_port,
    _prometheus_query,
    _wait_prometheus_ready,
    _wait_up,
    _wait_up_after,
    _write_credential,
)


COMPOSE_FILE = ROOT / "deploy" / "compose.yaml"
PROMETHEUS_FILE = ROOT / "deploy" / "compose.prometheus.yaml"
ALERTMANAGER_FILE = ROOT / "deploy" / "compose.alertmanager.yaml"
PROMETHEUS_UID = 65534
ALERTMANAGER_UID = 65534
ALERTMANAGER_CONFIG = "/etc/alertmanager/alertmanager.yml"
ALERTMANAGER_SECRET_FILE = "/run/atermius-alertmanager-secrets/webhook-url"
METRICS_ALERT = "AtermiusMetricsScrapeUnavailable"
ALLOWED_ALERT_LABELS = {"alertname", "severity", "job", "instance"}
ALLOWED_ANNOTATION_LABELS = {"summary", "description"}
EXPECTED_ALERT_LABELS = {
    "alertname": METRICS_ALERT,
    "instance": "server:8080",
    "job": "atermius",
    "severity": "warning",
}
EXPECTED_ALERT_ANNOTATIONS = {
    "summary": "Atermius metrics scrape unavailable",
    "description": (
        "Prometheus has failed to scrape the Atermius metrics endpoint for at least 30 seconds. "
        "Check service readiness and the protected scrape credential file."
    ),
}
ALLOWED_NOTIFICATION_REASONS = {
    "first notification",
    "new alerts added",
    "some alerts resolved",
    "all alerts resolved",
    "repeat interval elapsed",
    "unknown",
}
SENSITIVE_KEY_PARTS = (
    "account",
    "vault",
    "credential",
    "request",
    "email",
    "username",
    "device",
    "token",
    "secret",
)
ALLOWED_WEBHOOK_TOP_LEVEL = {
    "receiver",
    "status",
    "alerts",
    "groupLabels",
    "commonLabels",
    "commonAnnotations",
    "externalURL",
    "version",
    "groupKey",
    "truncatedAlerts",
    "notification_reason",
    "routeLabels",
}
ALLOWED_ALERT_FIELDS = {
    "status",
    "labels",
    "annotations",
    "startsAt",
    "endsAt",
    "generatorURL",
    "fingerprint",
    "silenceURL",
    "dashboardURL",
    "panelURL",
}


def _assert_absent(value: str, text: str, message: str) -> None:
    """Check sensitive text without letting pytest print the value on failure."""
    if value in text:
        pytest.fail(message, pytrace=False)


def _assert_nonempty_string(value: Any, message: str) -> None:
    """Validate token shape while keeping malformed token contents out of failures."""
    if not isinstance(value, str) or not value:
        pytest.fail(message, pytrace=False)


def _assert_scrape_token(value: Any, message: str) -> None:
    if not isinstance(value, str) or re.fullmatch(r"atm_[A-Za-z0-9_-]{43}", value) is None:
        pytest.fail(message, pytrace=False)


def _compose(
    project: str,
    env_file: Path,
    env: dict[str, str],
    override_file: Path,
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
        "--file",
        str(ALERTMANAGER_FILE),
        "--file",
        str(override_file),
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


def _docker_host_gateway() -> str:
    result = subprocess.run(
        [
            "docker",
            "network",
            "inspect",
            "bridge",
            "--format",
            "{{(index .IPAM.Config 0).Gateway}}",
        ],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        pytest.skip("Docker bridge gateway is unavailable for the isolated webhook stub")
    try:
        gateway = ipaddress.ip_address(result.stdout.strip())
    except ValueError:
        pytest.skip("Docker bridge gateway is not a valid IP address")
    if gateway.version != 4:
        pytest.skip("webhook host-gateway acceptance requires an IPv4 Docker bridge")
    return str(gateway)


def _write_webhook_url(secret_dir: Path, value: str) -> Path:
    destination = secret_dir / "webhook-url"
    temporary = secret_dir / f".webhook-url.{uuid.uuid4().hex}.next"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o400)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(value.encode("ascii") + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.chown(temporary, ALERTMANAGER_UID, ALERTMANAGER_UID)
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
    assert metadata.st_uid == ALERTMANAGER_UID and metadata.st_gid == ALERTMANAGER_UID
    return destination


def _sensitive_key_present(value: Any) -> bool:
    if isinstance(value, dict):
        for key, nested in value.items():
            lowered = str(key).lower()
            if any(fragment in lowered for fragment in SENSITIVE_KEY_PARTS):
                return True
            if _sensitive_key_present(nested):
                return True
    elif isinstance(value, list):
        return any(_sensitive_key_present(item) for item in value)
    return False


def _sensitive_field_categories(value: Any) -> set[str]:
    """Return only fixed, safe categories; never retain arbitrary field names."""
    categories: set[str] = set()
    if isinstance(value, dict):
        for key, nested in value.items():
            lowered = str(key).lower()
            for category in ("account", "vault", "credential", "request"):
                if category in lowered:
                    categories.add(category)
            categories.update(_sensitive_field_categories(nested))
    elif isinstance(value, list):
        for nested in value:
            categories.update(_sensitive_field_categories(nested))
    return categories


def _unexpected_field_categories(value: dict[str, Any]) -> list[str]:
    categories: set[str] = set()
    if set(value) - ALLOWED_WEBHOOK_TOP_LEVEL:
        categories.add("topLevel")
    if value.get("routeLabels", {}) != {}:
        categories.add("routeLabels")
    alerts = value.get("alerts")
    if not isinstance(alerts, list):
        categories.add("alertsShape")
        return sorted(categories)
    for field, allowed in (
        ("groupLabels", ALLOWED_ALERT_LABELS),
        ("commonLabels", ALLOWED_ALERT_LABELS),
        ("commonAnnotations", ALLOWED_ANNOTATION_LABELS),
    ):
        labels = value.get(field)
        if (
            not isinstance(labels, dict)
            or set(labels) - allowed
            or any(not isinstance(label_value, str) for label_value in labels.values())
        ):
            categories.add(field)
    for alert in alerts:
        if not isinstance(alert, dict):
            categories.add("alertShape")
            continue
        if set(alert) - ALLOWED_ALERT_FIELDS:
            categories.add("alert")
        labels = alert.get("labels")
        annotations = alert.get("annotations")
        if (
            not isinstance(labels, dict)
            or set(labels) - ALLOWED_ALERT_LABELS
            or any(not isinstance(label_value, str) for label_value in labels.values())
        ):
            categories.add("alertLabels")
        if (
            not isinstance(annotations, dict)
            or set(annotations) - ALLOWED_ANNOTATION_LABELS
            or any(not isinstance(annotation, str) for annotation in annotations.values())
        ):
            categories.add("alertAnnotations")
    return sorted(categories)


class _WebhookRecorder:
    """Local stub stores a strict, non-secret projection of each webhook."""

    def __init__(self, path_token: str, fixture_markers: list[str], bind_host: str) -> None:
        self.path_token = path_token
        # Keep the caller-owned list so tokens and IDs created after server
        # startup are also checked without retaining any arbitrary payload.
        self.fixture_markers = fixture_markers
        self._lock = threading.Lock()
        self._events: list[dict[str, Any]] = []
        recorder = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, _format: str, *_args: object) -> None:
                # Never emit the secret URL path or request headers to test logs.
                return

            def _reply(self, status: int) -> None:
                payload = b"ok\n"
                self.send_response(status)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                if self.path != f"/{recorder.path_token}":
                    recorder._append({"wrongPath": True})
                    self._reply(404)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    self._reply(400)
                    return
                if length < 1 or length > 1_048_576:
                    self._reply(413)
                    return
                raw = self.rfile.read(length)
                try:
                    payload = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    recorder._append({"malformed": True})
                    self._reply(400)
                    return
                if not isinstance(payload, dict):
                    recorder._append({"malformed": True})
                    self._reply(400)
                    return

                alerts = payload.get("alerts")
                safe_alerts: list[dict[str, Any]] = []
                if isinstance(alerts, list):
                    for alert in alerts:
                        if not isinstance(alert, dict):
                            continue
                        labels = alert.get("labels")
                        annotations = alert.get("annotations")
                        safe_labels = labels if isinstance(labels, dict) else {}
                        safe_annotations = annotations if isinstance(annotations, dict) else {}
                        safe_alerts.append(
                            {
                                "status": alert.get("status")
                                if alert.get("status") in {"firing", "resolved"}
                                else "unexpected",
                                "labelsMatch": safe_labels == EXPECTED_ALERT_LABELS,
                                "labelKeysAllowed": set(safe_labels) <= ALLOWED_ALERT_LABELS,
                                "annotationsMatch": safe_annotations == EXPECTED_ALERT_ANNOTATIONS,
                                "annotationKeysAllowed": set(safe_annotations)
                                <= ALLOWED_ANNOTATION_LABELS,
                            }
                        )

                raw_text = raw.decode("utf-8", errors="replace")
                event = {
                    "receiverMatches": payload.get("receiver") == "aterm-webhook",
                    "notificationReasonAllowed": payload.get("notification_reason")
                    in ALLOWED_NOTIFICATION_REASONS,
                    "routeLabelsEmpty": payload.get("routeLabels", {}) == {},
                    "status": payload.get("status")
                    if payload.get("status") in {"firing", "resolved"}
                    else "unexpected",
                    "alerts": safe_alerts,
                    "groupLabelsMatch": payload.get("groupLabels") == {"alertname": METRICS_ALERT},
                    "commonLabelsMatch": payload.get("commonLabels") == EXPECTED_ALERT_LABELS,
                    "commonAnnotationsMatch": payload.get("commonAnnotations")
                    == EXPECTED_ALERT_ANNOTATIONS,
                    "sensitiveFieldPresent": _sensitive_key_present(payload),
                    "sensitiveFieldCategoriesPresent": sorted(
                        _sensitive_field_categories(payload)
                    ),
                    "unexpectedFieldCategories": _unexpected_field_categories(payload),
                    "fixtureMarkerPresent": any(marker in raw_text for marker in recorder.fixture_markers),
                    "secretPathPresentInBody": recorder.path_token in raw_text,
                }
                recorder._append(event)
                self._reply(200)

        self.server = ThreadingHTTPServer((bind_host, 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = int(self.server.server_address[1])

    def _append(self, event: dict[str, Any]) -> None:
        with self._lock:
            self._events.append(event)

    def snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._events)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive(), "local webhook recorder did not stop"


def _wait_for_alert_status(
    recorder: _WebhookRecorder,
    expected: str,
    *,
    timeout: float = 210,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        events = recorder.snapshot()
        matching = [
            event
            for event in events
            if event.get("status") == expected
            and event.get("receiverMatches") is True
            and len(event.get("alerts", [])) == 1
            and event["alerts"][0].get("labelsMatch") is True
        ]
        if matching:
            return matching[-1]
        time.sleep(0.25)
    pytest.fail(f"Alertmanager did not deliver a {expected} notification for the fixed scrape alert")


def _assert_safe_alert(event: dict[str, Any], expected_status: str) -> None:
    assert event.get("receiverMatches") is True, "Alertmanager used an unexpected fixed receiver"
    assert event.get("notificationReasonAllowed") is True
    assert event.get("routeLabelsEmpty") is True
    assert event.get("status") == expected_status
    assert event.get("sensitiveFieldPresent") is False, "webhook contained a sensitive field name"
    assert event.get("sensitiveFieldCategoriesPresent") == [], (
        "webhook contained an account, Vault, credential, or request field"
    )
    assert event.get("unexpectedFieldCategories") == [], (
        "webhook contained an unapproved field category: "
        f"{event.get('unexpectedFieldCategories')}"
    )
    assert event.get("fixtureMarkerPresent") is False, "webhook contained a fixture account or credential marker"
    assert event.get("secretPathPresentInBody") is False, "webhook body repeated the secret URL path"
    assert len(event.get("alerts", [])) == 1, "fixed rule notification had an unexpected alert count"
    assert event.get("groupLabelsMatch") is True
    assert event.get("commonLabelsMatch") is True
    assert event.get("commonAnnotationsMatch") is True
    alert = event["alerts"][0]
    assert alert.get("status") == expected_status
    assert alert.get("labelsMatch") is True, (
        "webhook alert labels were not the fixed low-cardinality rule labels"
    )
    assert alert.get("labelKeysAllowed") is True
    assert alert.get("annotationsMatch") is True, "webhook alert annotations were not fixed"
    assert alert.get("annotationKeysAllowed") is True


def _docker_resource_names(kind: str, project: str) -> set[str]:
    label = f"label=com.docker.compose.project={project}"
    if kind == "containers":
        command = ["docker", "ps", "--all", "--quiet", "--filter", label]
    elif kind == "networks":
        command = ["docker", "network", "ls", "--filter", label, "--format", "{{.Name}}"]
    elif kind == "volumes":
        command = ["docker", "volume", "ls", "--filter", label, "--format", "{{.Name}}"]
    else:
        raise ValueError(f"unsupported Docker resource kind: {kind}")
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, f"could not inspect disposable Docker {kind}s"
    return set(result.stdout.splitlines())


def test_compose_alertmanager_posts_fixed_firing_and_resolved_alerts(tmp_path: Path) -> None:
    """ALERTMANAGER-COMPOSE: verify delivery, resolution, privacy, and cleanup."""
    _compose_available()
    assert ALERTMANAGER_FILE.is_file(), "Alertmanager Compose overlay is missing"
    host_gateway = _docker_host_gateway()

    tag = uuid.uuid4().hex[:14]
    project = f"atermius-am-{tag}"
    server_volume = f"{project}-server-data"
    prometheus_volume = f"{project}_prometheus-data"
    alertmanager_volume = f"{project}_alertmanager-data"
    existing_volumes = _docker_names("volume", "ls", "--quiet")
    assert not ({server_volume, prometheus_volume, alertmanager_volume} & existing_volumes)

    work_dir = tmp_path / "alertmanager-acceptance"
    work_dir.mkdir(mode=0o700)
    try:
        os.chmod(work_dir, 0o700)
        secret_dir = work_dir / "alertmanager-secrets"
        secret_dir.mkdir(mode=0o750)
        try:
            os.chown(secret_dir, 0, ALERTMANAGER_UID)
        except PermissionError:
            shutil.rmtree(work_dir, ignore_errors=True)
            pytest.skip("Docker host cannot provision Alertmanager secret-file ownership")
        os.chmod(secret_dir, 0o750)

        env_file = work_dir / "compose.env"
        override_file = work_dir / "test-host-gateway.compose.yaml"
        port = _free_port()
        prometheus_port = _free_port()
        assert prometheus_port != port
        base_url = f"http://127.0.0.1:{port}"
        prometheus_url = f"http://127.0.0.1:{prometheus_port}"
        username = f"alertmanager-admin-{tag}@example.test"
        url_path_token = f"hook-{uuid.uuid4().hex}"
        webhook_url_path = f"/{url_path_token}"

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
                    f"ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR={secret_dir}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        os.chmod(env_file, 0o600)
        override_file.write_text(
            "services:\n  alertmanager:\n    extra_hosts:\n"
            "      - \"host.docker.internal:host-gateway\"\n",
            encoding="utf-8",
        )
        os.chmod(override_file, 0o600)

        compose_env = {
            key: value for key, value in os.environ.items() if not key.startswith("ATERMIUS_")
        }
    except BaseException:
        shutil.rmtree(work_dir, ignore_errors=True)
        raise

    fixture_markers: list[str] = [username]
    secrets: list[str] = [webhook_url_path, url_path_token, username]
    compose_secret_values: list[str] = [webhook_url_path, url_path_token]
    webhook_recorder: _WebhookRecorder | None = None
    try:
        webhook_recorder = _WebhookRecorder(url_path_token, fixture_markers, host_gateway)
        webhook_url = f"http://host.docker.internal:{webhook_recorder.port}/{url_path_token}"
        fixture_markers.extend((webhook_url, webhook_url_path, url_path_token))
        secrets.append(webhook_url)
        compose_secret_values.append(webhook_url)
        _write_webhook_url(secret_dir, webhook_url)

        prebuilt_image = os.environ.get("ATERMIUS_COMPOSE_TEST_IMAGE")
        if prebuilt_image:
            image_override = work_dir / "image.compose.yaml"
            image_override.write_text(
                "services:\n  server:\n    image: \"${ATERMIUS_IMAGE}\"\n",
                encoding="utf-8",
            )
            os.chmod(image_override, 0o600)
            compose_env["ATERMIUS_IMAGE"] = prebuilt_image
            # Keep the test-only host-gateway override and the supported local
            # server image override in the same final Compose file.
            override_file.write_text(
                "services:\n  server:\n    image: \"${ATERMIUS_IMAGE}\"\n"
                "  alertmanager:\n    extra_hosts:\n"
                "      - \"host.docker.internal:host-gateway\"\n",
                encoding="utf-8",
            )

        def compose(*args: str, timeout: int = 180) -> subprocess.CompletedProcess[str]:
            return _compose(project, env_file, compose_env, override_file, *args, timeout=timeout)

        rendered = compose("config", "--format", "json")
        assert rendered.returncode == 0, "rendered Compose config failed"
        for secret in compose_secret_values:
            _assert_absent(secret, rendered.stdout, "rendered Compose config exposed webhook URL material")
        rendered_config = json.loads(rendered.stdout)
        assert {"server", "prometheus", "alertmanager"} <= set(rendered_config["services"])
        alertmanager_service = rendered_config["services"]["alertmanager"]
        assert alertmanager_service["user"] == f"{ALERTMANAGER_UID}:{ALERTMANAGER_UID}"
        assert alertmanager_service["image"] == "prom/alertmanager:v0.34.1"
        assert str(secret_dir) in json.dumps(alertmanager_service)
        assert ALERTMANAGER_SECRET_FILE not in rendered.stdout, (
            "rendered Compose config exposed the protected URL-file path"
        )
        alertmanager_mount_targets = {
            mount.get("target")
            for mount in alertmanager_service.get("volumes", [])
            if isinstance(mount, dict)
        }
        assert ALERTMANAGER_CONFIG in alertmanager_mount_targets
        assert "/run/atermius-alertmanager-secrets" in alertmanager_mount_targets
        service_networks = {
            name: set(service.get("networks", {}))
            for name, service in rendered_config["services"].items()
        }
        assert {"default", "metrics"} <= service_networks["server"]
        assert not ({"alertmanager", "alertmanager-egress"} & service_networks["server"]), (
            "server was attached to an Alertmanager network"
        )
        assert service_networks["prometheus"] == {"default", "metrics", "alertmanager"}
        assert service_networks["alertmanager"] == {"alertmanager", "alertmanager-egress"}
        assert rendered_config["networks"]["alertmanager"].get("internal") is True
        assert rendered_config["networks"]["alertmanager-egress"].get("internal") is not True

        started_server = compose("up", "-d", "--build", "server", timeout=1200)
        assert started_server.returncode == 0, "Compose server startup failed:\n" + _diagnostic(
            started_server, *secrets
        )
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
        assert bootstrapped.returncode == 0, "Compose bootstrap failed:\n" + _diagnostic(
            bootstrapped, *secrets
        )
        candidates = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            bootstrapped.stdout,
        )
        assert candidates, "Compose bootstrap did not return its one-time token"
        bootstrap_token = candidates[-1]
        secrets.append(bootstrap_token)
        compose_secret_values.append(bootstrap_token)
        fixture_markers.append(bootstrap_token)
        del bootstrapped, candidates

        signer = SigningKey(work_dir, "alertmanager-admin")
        account_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        fixture_markers.extend((account_id, device_id))
        secrets.extend((account_id, device_id))
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
        _assert_nonempty_string(admin_token, "Compose admin registration returned an invalid session token")
        secrets.append(admin_token)
        compose_secret_values.append(admin_token)
        fixture_markers.append(admin_token)
        del bootstrap_token, registration, registered

        created = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert created.status == 200, "initial Prometheus credential creation failed"
        scrape_token = created.json().get("credential")
        _assert_scrape_token(scrape_token, "initial Prometheus credential had an invalid shape")
        secrets.append(scrape_token)
        compose_secret_values.append(scrape_token)
        fixture_markers.append(scrape_token)
        credentials_dir = work_dir / "prometheus-secrets"
        credentials_dir.mkdir(mode=0o750)
        os.chown(credentials_dir, 0, PROMETHEUS_UID)
        os.chmod(credentials_dir, 0o750)
        _write_credential(credentials_dir, scrape_token)
        # Use a separate protected bind directory for Prometheus. The webhook
        # URL remains in its own mounted directory and never enters Compose env.
        env_file.write_text(
            env_file.read_text(encoding="utf-8").replace(
                f"ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR={secret_dir}",
                f"ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR={credentials_dir}",
            ),
            encoding="utf-8",
        )
        os.chmod(env_file, 0o600)

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
        assert config_check.returncode == 0, "Prometheus config validation failed:\n" + _diagnostic(
            config_check, *secrets
        )
        rules_check = compose(
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "/bin/promtool",
            "prometheus",
            "check",
            "rules",
            "/etc/prometheus/atermius-alerts.yml",
        )
        assert rules_check.returncode == 0, "Prometheus alert rules validation failed:\n" + _diagnostic(
            rules_check, *secrets
        )
        alertmanager_check = compose(
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "/bin/amtool",
            "alertmanager",
            "check-config",
            ALERTMANAGER_CONFIG,
        )
        assert alertmanager_check.returncode == 0, "Alertmanager config validation failed:\n" + _diagnostic(
            alertmanager_check, *secrets
        )

        # Confirm that even after installing the scrape credential, the actual
        # webhook URL/value is absent from the interpolated Compose document.
        rendered = compose("config", "--format", "json")
        assert rendered.returncode == 0, "rendered Compose config failed after secret setup"
        for secret in compose_secret_values:
            _assert_absent(secret, rendered.stdout, "rendered Compose config exposed secret material")
        _assert_absent(webhook_url, rendered.stdout, "rendered Compose config exposed the webhook URL")
        _assert_absent(url_path_token, rendered.stdout, "rendered Compose config exposed the webhook URL path")

        metrics_started = compose("up", "-d", "prometheus", "alertmanager")
        assert metrics_started.returncode == 0, "metrics/Alertmanager startup failed:\n" + _diagnostic(
            metrics_started, *secrets
        )
        if not _wait_prometheus_ready(prometheus_url):
            logs = compose("logs", "--no-color", "prometheus", "alertmanager")
            pytest.fail("Prometheus did not become ready:\n" + _diagnostic(logs, *secrets))
        _wait_up(prometheus_url, "1")
        initial_alerts = _prometheus_query(prometheus_url, 'ALERTS{alertname="AtermiusMetricsScrapeUnavailable"}')
        assert not [
            sample
            for sample in initial_alerts
            if sample.get("metric", {}).get("alertstate") == "firing"
        ], "scrape alert fired before credential revocation"

        revoked = api.request("DELETE", CREDENTIAL_PATH, token=admin_token)
        assert revoked.status == 200, "Prometheus credential revocation failed"
        assert api.request("GET", METRICS_PATH, token=scrape_token).status == 401, (
            "revoked scrape credential still reads metrics"
        )
        _wait_up(prometheus_url, "0")
        firing = _wait_for_alert_status(webhook_recorder, "firing")
        _assert_safe_alert(firing, "firing")

        replacement = api.request("POST", CREDENTIAL_PATH, token=admin_token)
        assert replacement.status == 200, "replacement Prometheus credential creation failed"
        replacement_token = replacement.json().get("credential")
        _assert_scrape_token(replacement_token, "replacement Prometheus credential had an invalid shape")
        secrets.append(replacement_token)
        compose_secret_values.append(replacement_token)
        fixture_markers.append(replacement_token)
        _write_credential(credentials_dir, replacement_token)
        replacement_installed_at = time.time()
        del replacement, revoked
        assert api.request("GET", METRICS_PATH, token=replacement_token).status == 200
        assert api.request("GET", METRICS_PATH, token=scrape_token).status == 401, (
            "credential recovery unexpectedly revalidated the revoked token"
        )
        _wait_up_after(prometheus_url, "1", replacement_installed_at)
        resolved = _wait_for_alert_status(webhook_recorder, "resolved")
        _assert_safe_alert(resolved, "resolved")

        notifications = webhook_recorder.snapshot()
        assert not any(event.get("wrongPath") or event.get("malformed") for event in notifications), (
            "Alertmanager sent a malformed notification or used an unexpected endpoint"
        )
        assert any(event.get("status") == "firing" for event in notifications)
        assert any(event.get("status") == "resolved" for event in notifications), (
            "Alertmanager did not send the resolved notification after credential recovery"
        )

        logs = compose("logs", "--no-color", "server", "prometheus", "alertmanager")
        assert logs.returncode == 0, "could not read disposable Compose service logs"
        for secret in secrets:
            _assert_absent(
                secret,
                logs.stdout + logs.stderr,
                "server, Prometheus, or Alertmanager logs exposed credential material",
            )
        _assert_absent(webhook_url, logs.stdout + logs.stderr, "container logs exposed the protected webhook URL")
        _assert_absent(url_path_token, logs.stdout + logs.stderr, "container logs exposed the protected webhook URL path")
        _assert_absent(username, logs.stdout + logs.stderr, "container logs exposed the fixture account identifier")

    finally:
        cleanup_errors: list[str] = []
        cleanup: subprocess.CompletedProcess[str] | None = None
        try:
            cleanup = _compose(
                project,
                env_file,
                compose_env,
                override_file,
                "down",
                "--volumes",
                "--remove-orphans",
                timeout=180,
            )
            if cleanup.returncode != 0:
                cleanup_errors.append("Compose project cleanup returned an error")
        except Exception:
            cleanup_errors.append("Compose project cleanup could not be completed")

        if webhook_recorder is not None:
            try:
                webhook_recorder.close()
            except Exception:
                cleanup_errors.append("local webhook recorder did not stop cleanly")

        # Compose normally removes everything. These label-scoped fallbacks
        # also handle a partially failed `up`/`down`; each resource class is
        # attempted even if another cleanup operation fails.
        for kind, remove_prefix in (
            ("containers", ["docker", "rm", "--force"]),
            ("networks", ["docker", "network", "rm"]),
            ("volumes", ["docker", "volume", "rm", "--force"]),
        ):
            try:
                leftovers = _docker_resource_names(kind, project)
                if leftovers:
                    removed = subprocess.run(
                        [*remove_prefix, *sorted(leftovers)],
                        capture_output=True,
                        text=True,
                        timeout=30,
                        check=False,
                    )
                    if removed.returncode != 0:
                        cleanup_errors.append(f"disposable Compose {kind} removal failed")
            except Exception:
                cleanup_errors.append(f"disposable Compose {kind} cleanup could not be completed")

        try:
            all_volumes = _docker_names("volume", "ls", "--quiet")
            named_leftovers = {
                name
                for name in (server_volume, prometheus_volume, alertmanager_volume)
                if name in all_volumes
            }
            if named_leftovers:
                removed = subprocess.run(
                    ["docker", "volume", "rm", "--force", *sorted(named_leftovers)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                if removed.returncode != 0:
                    cleanup_errors.append("disposable named-volume removal failed")
        except Exception:
            cleanup_errors.append("disposable named-volume cleanup could not be completed")

        for kind in ("containers", "networks", "volumes"):
            try:
                if _docker_resource_names(kind, project):
                    cleanup_errors.append(f"disposable Compose {kind} remain after cleanup")
            except Exception:
                cleanup_errors.append(f"could not verify disposable Compose {kind} cleanup")
        try:
            all_volumes = _docker_names("volume", "ls", "--quiet")
            if {server_volume, prometheus_volume, alertmanager_volume} & all_volumes:
                cleanup_errors.append("disposable Compose volumes remain after cleanup")
        except Exception:
            cleanup_errors.append("could not verify disposable volume cleanup")

        shutil.rmtree(work_dir, ignore_errors=True)
        if work_dir.exists():
            cleanup_errors.append("disposable Compose temporary files remain after cleanup")
        if cleanup_errors:
            cleanup_summary = "; ".join(cleanup_errors)
            active_error = sys.exc_info()[1]
            if active_error is None:
                pytest.fail(cleanup_summary)
            elif hasattr(active_error, "add_note"):
                active_error.add_note("Cleanup also reported: " + cleanup_summary)
            else:
                print("Cleanup also reported: " + cleanup_summary, file=sys.stderr)
