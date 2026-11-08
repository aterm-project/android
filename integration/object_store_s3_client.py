"""Python control client for the shared Node loopback S3 fixture."""

from __future__ import annotations

import base64
import json
import os
import secrets
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_SCRIPT = ROOT / "integration" / "web" / "opaque_object_store_fixture.cjs"
FIXTURE_MAX_OBJECT_BYTES = 64 * 1024 * 1024


class LoopbackS3Process:
    """Starts and controls the same fake imported by browser acceptance."""

    def __init__(
        self, *, bucket: str, temp_dir: Path, session_token: str | None = None
    ) -> None:
        node = shutil.which("node")
        if not node:
            raise RuntimeError("Node.js is required for the shared loopback S3 fixture")
        self.bucket = bucket
        self.region = "us-east-1"
        self.access_key_id = "atermius-fixture-access"
        self.secret_access_key = secrets.token_urlsafe(32)
        self.session_token = session_token
        self.control_token = secrets.token_urlsafe(32)
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("ATERMIUS_") and not key.startswith("AWS_")
        }
        environment.update(
            {
                "ATERMIUS_S3_FIXTURE_BUCKET": bucket,
                "ATERMIUS_S3_FIXTURE_REGION": self.region,
                "ATERMIUS_S3_FIXTURE_ACCESS_KEY_ID": self.access_key_id,
                "ATERMIUS_S3_FIXTURE_SECRET_ACCESS_KEY": self.secret_access_key,
                "ATERMIUS_S3_FIXTURE_CONTROL_TOKEN": self.control_token,
                "ATERMIUS_S3_FIXTURE_MAX_OBJECT_BYTES": str(FIXTURE_MAX_OBJECT_BYTES),
            }
        )
        if self.session_token is not None:
            environment["ATERMIUS_S3_FIXTURE_SESSION_TOKEN"] = self.session_token
        self._process = subprocess.Popen(
            [node, str(FIXTURE_SCRIPT), "--standalone"],
            cwd=ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.endpoint_url = ""
        self.control_url = ""
        self._closed = False
        self._wait_ready(temp_dir)

    def _wait_ready(self, temp_dir: Path) -> None:
        # Standalone mode emits exactly one fixed-shape readiness line. No key,
        # object data, credentials, or private paths are included in it.
        assert self._process.stdout is not None
        deadline = time.monotonic() + 10
        line = ""
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                break
            try:
                import select

                readable, _, _ = select.select([self._process.stdout], [], [], 0.1)
                if readable:
                    line = self._process.stdout.readline()
                    break
            except (OSError, ValueError):
                break
        try:
            ready = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            self.close(force=True)
            raise RuntimeError("shared loopback S3 fixture did not start") from None
        if ready.get("ready") is not True:
            self.close(force=True)
            raise RuntimeError("shared loopback S3 fixture readiness response was invalid")
        self.endpoint_url = str(ready.get("endpointUrl") or "")
        self.control_url = str(ready.get("controlUrl") or "")
        if not (
            self.endpoint_url.startswith("http://127.0.0.1:")
            and self.control_url == self.endpoint_url + "/__atermius_fixture__/control"
        ):
            self.close(force=True)
            raise RuntimeError("shared S3 fixture endpoint was not strict loopback")

    def _control(self, action: str, **fields: Any) -> dict[str, Any]:
        request = urllib.request.Request(
            self.control_url,
            data=json.dumps(
                {"action": action, **fields}, separators=(",", ":")
            ).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "X-Atermius-Fixture-Token": self.control_token,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                result = json.loads(response.read().decode("utf-8"))
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
            raise RuntimeError("shared S3 fixture control call failed") from None
        if not isinstance(result, dict):
            raise RuntimeError("shared S3 fixture returned an invalid control response")
        return result

    def inject_fault(
        self, operation: str, mode: str, *, key: str | None = None, count: int = 1
    ) -> None:
        self._control(
            "inject_fault",
            operation=operation,
            mode=mode,
            count=count,
            **({"key": key} if key is not None else {}),
        )

    def seed_object(self, key: str, body: bytes, *, sha256: str | None = None) -> None:
        self._control(
            "seed_object",
            key=key,
            body_base64=base64.b64encode(body).decode("ascii"),
            **({"sha256": sha256} if sha256 is not None else {}),
        )

    def corrupt_object(self, key: str) -> None:
        self._control("corrupt_object", key=key)

    def remove_object(self, key: str) -> bool:
        return bool(self._control("remove_object", key=key).get("removed"))

    def object_info(self, key: str) -> dict[str, Any]:
        result = self._control("get_object", key=key)
        return result

    def snapshot(self) -> dict[str, Any]:
        return self._control("stats")

    def request_count(self, method: str, *, key: str | None = None) -> int:
        result = self._control(
            "request_count",
            method=method.upper(),
            **({"key": key} if key is not None else {}),
        )
        return int(result.get("count", -1))

    def close(self, *, force: bool = False) -> None:
        if self._closed:
            return
        self._closed = True
        if self._process.poll() is not None:
            return
        if not force:
            try:
                self._control("shutdown")
            except RuntimeError:
                pass
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self._process.pid, signal.SIGTERM)
            except (AttributeError, ProcessLookupError):
                self._process.terminate()
            try:
                self._process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self._process.pid, signal.SIGKILL)
                except (AttributeError, ProcessLookupError):
                    self._process.kill()
                self._process.wait(timeout=3)
        if self._process.stdout:
            self._process.stdout.close()
        if self._process.stderr:
            # Diagnostics are intentionally not copied into pytest output.
            self._process.stderr.close()

    def __enter__(self) -> "LoopbackS3Process":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()
