"""Mocked safety and recovery acceptance for PostgreSQL offline cutover."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import urllib.error
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))
import pg_restore_cutover as cutover  # noqa: E402


PROJECT_JOB = str(uuid.uuid4())
INSTANCE_ID = str(uuid.uuid4())
SPACE_ID = str(uuid.uuid4())
SOURCE_GENERATION = str(uuid.uuid4())
STAGE_GENERATION = str(uuid.uuid4())
ARCHIVE_ID = str(uuid.uuid4())
OBJECT_STORE_ID = str(uuid.uuid4())
BINDING_ID = str(uuid.uuid4())
SIGNING_PUBLIC = "A" * 43
SECRET = "CUTOVER_PRIVATE_SENTINEL_942d779c"
SOURCE_URL = f"postgresql://cutover:{SECRET}@127.0.0.1:5432/source_db?sslmode=disable"
STAGE_URL = f"postgresql://cutover:{SECRET}@127.0.0.1:5432/stage_db?sslmode=disable"
NEXT_URL = f"postgresql://cutover:{SECRET}@127.0.0.1:5432/next_db?sslmode=disable"


class CommandResult:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = ""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class FakeResponse:
    def __init__(self, payload: dict[str, object]):
        self.status = 200
        self.body = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, size: int) -> bytes:
        return self.body[:size]


class FakeOpener:
    def __init__(self, runtime: "FakeCompose"):
        self.runtime = runtime

    def open(self, request, timeout: int):
        assert timeout == cutover.HTTP_TIMEOUT_SECONDS
        if not self.runtime.running:
            raise urllib.error.URLError("private fake detail")
        active = self.runtime.active_is_stage()
        if request.full_url.endswith("/health/ready"):
            if active and self.runtime.fail_stage_health:
                return FakeResponse({"status": "starting"})
            return FakeResponse({"status": "ready"})
        assert request.full_url.endswith("/api/v1/instance")
        if active and self.runtime.fail_stage_identity:
            return FakeResponse({"malformed": "private fake detail"})
        return FakeResponse({
            "instance_id": INSTANCE_ID,
            "server_space_id": SPACE_ID,
            "generation": STAGE_GENERATION if active else SOURCE_GENERATION,
            "signing_public_key": SIGNING_PUBLIC,
        })


class FakeCompose:
    def __init__(self, env_path: Path, archive_root: Path):
        self.env_path = env_path
        self.archive_root = archive_root
        self.running = True
        self.fail_stage_health = False
        self.fail_stage_identity = False
        self.fail_activation = False
        self.activation_payload_override: dict[str, object] | None = None
        self.config_files_override: str | None = None
        self.activated = False
        self.rollback_fenced = False
        self.activation_calls = 0
        self.stop_calls = 0
        self.docker_context = "default"
        self.docker_endpoint = "unix:///var/run/docker.sock"
        self.up_calls: list[list[str]] = []
        self.commands: list[list[str]] = []
        self.container_env = self._environment_items()
        self.container_mounts = self._mounts()

    def values(self) -> dict[str, str]:
        raw = self.env_path.read_bytes()
        return cutover._parse_env(raw)[2]

    def active_is_stage(self) -> bool:
        return self.values()[cutover.PG_URL_KEY] == STAGE_URL

    def config(self) -> dict[str, object]:
        values = self.values()
        return {
            "services": {
                "server": {
                    "deploy": {"replicas": 1},
                    "environment": {
                        cutover.BACKEND_KEY: "postgres",
                        cutover.PG_URL_KEY: values[cutover.PG_URL_KEY],
                        cutover.PG_SCHEMA_KEY: values[cutover.PG_SCHEMA_KEY],
                        cutover.RESTORE_TARGET_KEY: values[cutover.RESTORE_TARGET_KEY],
                        cutover.SIGNING_KEY_FILE_KEY: values[cutover.SIGNING_KEY_FILE_KEY],
                        cutover.RATE_KEY_FILE_KEY: values[cutover.RATE_KEY_FILE_KEY],
                        cutover.OBJECT_BACKEND_KEY: values[cutover.OBJECT_BACKEND_KEY],
                        cutover.OBJECT_ROOT_KEY: values[cutover.OBJECT_ROOT_KEY],
                    cutover.BACKUP_ARCHIVE_DIR_KEY: "/backups",
                    "ATERMIUS_BACKUP_KEY_FILE": "/backup-key/atermius-backup.key",
                },
                    "volumes": [{
                        "type": "volume",
                        "source": "server-data",
                        "target": "/data",
                        "read_only": False,
                    }, {
                        "type": "bind",
                        "source": str(self.archive_root),
                        "target": "/backups",
                        "read_only": False,
                    }, {
                        "type": "bind",
                        "source": values["ATERMIUS_BACKUP_KEY_HOST_DIR"],
                        "target": "/backup-key",
                        "read_only": True,
                    }, {
                        "type": "bind",
                        "source": values[cutover.SIGNING_KEY_HOST_FILE_KEY],
                        "target": cutover.SOURCE_SIGNING_KEY_CONTAINER_PATH,
                        "read_only": True,
                        "bind": {"create_host_path": False},
                    }, {
                        "type": "bind",
                        "source": values[cutover.RATE_KEY_HOST_FILE_KEY],
                        "target": cutover.SOURCE_RATE_KEY_CONTAINER_PATH,
                        "read_only": True,
                        "bind": {"create_host_path": False},
                    }, {
                        "type": "volume",
                        "source": "object-store-data",
                        "target": "/object-store",
                        "read_only": False,
                    }],
                }
            },
            "volumes": {
                "server-data": {"name": values["ATERMIUS_DATA_VOLUME_NAME"]},
                "object-store-data": {"name": values["ATERMIUS_OBJECT_STORE_FILESYSTEM_VOLUME_NAME"]},
            },
        }

    def _environment_items(self) -> list[str]:
        environment = self.config()["services"]["server"]["environment"]
        return [f"{key}={value}" for key, value in environment.items()]

    def _mounts(self) -> list[dict[str, object]]:
        volumes = self.config()["services"]["server"]["volumes"]
        result = []
        for volume in volumes:
            target = volume["target"]
            volume_name = (
                "atermius-test-data" if target == "/data" else "atermius-object-store"
            )
            result.append({
                "Type": volume["type"],
                "Source": volume["source"] if volume["type"] == "bind" else f"/var/lib/docker/volumes/{volume_name}/_data",
                "Name": volume_name if volume["type"] == "volume" else "",
                "Destination": target,
                "RW": not volume["read_only"],
            })
        return result

    def _inspection(self) -> dict[str, object]:
        expected = ",".join(str(path) for path in cutover.COMPOSE_FILES)
        return {
            "Config": {
                "Labels": {"com.docker.compose.project.config_files": self.config_files_override or expected},
                "Env": list(self.container_env),
            },
            "Mounts": list(self.container_mounts),
        }

    def run(self, command: list[str], *, env: dict[str, str], capture_output: bool,
            text: bool, timeout: int, check: bool = False, cwd: Path | None = None) -> CommandResult:
        assert capture_output and text and not check
        assert cwd is not None
        self.commands.append(list(command))
        assert not any(key.startswith("ATERMIUS_") for key in env)
        if command[:3] == ["docker", "context", "show"]:
            return CommandResult(stdout=self.docker_context + "\n")
        if command[:3] == ["docker", "context", "inspect"]:
            return CommandResult(stdout=json.dumps(self.docker_endpoint))
        if "config" in command:
            return CommandResult(stdout=json.dumps(self.config()))
        if "inspect" in command:
            return CommandResult(stdout=json.dumps(self._inspection()))
        if "ps" in command:
            if "--all" in command:
                return CommandResult(stdout="a" * 64 + "\n")
            return CommandResult(stdout="a" * 64 + "\n" if self.running else "")
        if "stop" in command:
            assert command[-1] == cutover.SERVICE
            self.stop_calls += 1
            self.running = False
            return CommandResult()
        if "up" in command:
            assert command[-1] == cutover.SERVICE
            self.up_calls.append(command)
            self.running = True
            self.container_env = self._environment_items()
            self.container_mounts = self._mounts()
            return CommandResult()
        if "run" in command:
            if command[-3:] == ["fence-pg-restore-stage-rollback", "--job-id", PROJECT_JOB]:
                if self.activated:
                    status = "activated"
                    timestamp = None
                else:
                    status = "already_fenced" if self.rollback_fenced else "fenced"
                    self.rollback_fenced = True
                    timestamp = "2026-10-10T12:00:00.000Z"
                return CommandResult(stdout=json.dumps({
                    "status": status,
                    "job_id": PROJECT_JOB,
                    "target_database_name": "stage_db",
                    "target_database_oid": 49103,
                    "schema": "atermius",
                    "generation": STAGE_GENERATION,
                    "object_store_id": OBJECT_STORE_ID,
                    "restored_objects": 1,
                    "rollback_timestamp": timestamp,
                }))
            assert command[-3:] == ["activate-pg-restore-stage", "--job-id", PROJECT_JOB]
            self.activation_calls += 1
            if self.fail_activation or self.rollback_fenced:
                return CommandResult(1, "", "private SQL diagnostic and URL " + SECRET)
            already = self.activated
            self.activated = True
            status = "already_activated" if already else "activated"
            payload: dict[str, object] = {
                "job_id": PROJECT_JOB,
                "status": status,
                "target_database_name": "stage_db",
                "target_database_oid": 49103,
                "schema": "atermius",
                "generation": STAGE_GENERATION,
                "object_store_id": OBJECT_STORE_ID,
                "restored_objects": 1,
                "activation_timestamp": "2026-10-10T12:00:00.000Z",
            }
            if self.activation_payload_override is not None:
                payload.update(self.activation_payload_override)
            return CommandResult(stdout=json.dumps(payload))
        raise AssertionError("unhandled fake compose command")


def _env_text(archive_root: Path) -> str:
    key_root = archive_root.parent / "pg-keys"
    backup_key_root = archive_root.parent / "backup-key"
    return (
        "# unrelated comment is preserved\n"
        f"PRIVATE_SENTINEL={SECRET}\n"
        "ATERMIUS_HOST_PORT=18888\n"
        f"{cutover.ARCHIVE_HOST_KEY}='{archive_root}'\n"
        "ATERMIUS_DATA_VOLUME_NAME=atermius-test-data\n"
        f"ATERMIUS_BACKUP_KEY_HOST_DIR='{backup_key_root}'\n"
        f"{cutover.BACKEND_KEY}=postgres\n"
        f"{cutover.PG_URL_KEY}='{SOURCE_URL}'\n"
        f"{cutover.PG_SCHEMA_KEY}=atermius\n"
        f"{cutover.RESTORE_TARGET_KEY}='{STAGE_URL}'\n"
        f"{cutover.NEXT_TARGET_KEY}='{NEXT_URL}'\n"
        f"{cutover.SIGNING_KEY_FILE_KEY}={cutover.SOURCE_SIGNING_KEY_CONTAINER_PATH}\n"
        f"{cutover.RATE_KEY_FILE_KEY}={cutover.SOURCE_RATE_KEY_CONTAINER_PATH}\n"
        f"{cutover.SIGNING_KEY_HOST_FILE_KEY}='{key_root / 'instance-ed25519.key'}'\n"
        f"{cutover.RATE_KEY_HOST_FILE_KEY}='{key_root / 'auth-rate-limit.key'}'\n"
        f"{cutover.OBJECT_BACKEND_KEY}=filesystem\n"
        f"{cutover.OBJECT_ROOT_KEY}=/object-store\n"
        "ATERMIUS_OBJECT_STORE_FILESYSTEM_VOLUME_NAME=atermius-object-store\n"
    )


@pytest.fixture
def harness(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    deploy = tmp_path / "deploy"
    deploy.mkdir(mode=0o700)
    env_file = deploy / ".env"
    env_file.write_text(_env_text(tmp_path / "archives"), encoding="utf-8")
    os.chmod(env_file, 0o600)
    archive = tmp_path / "archives"
    archive.mkdir(mode=0o700)
    key_root = tmp_path / "pg-keys"
    key_root.mkdir(mode=0o700)
    backup_key_root = tmp_path / "backup-key"
    backup_key_root.mkdir(mode=0o700)
    for key_name in ("instance-ed25519.key", "auth-rate-limit.key"):
        key_path = key_root / key_name
        key_path.write_bytes(b"s" * 32)
        os.chmod(key_path, 0o600)
    stage = archive / "restore-staging" / f"atermius-pg-restore-{PROJECT_JOB}"
    stage.mkdir(mode=0o700, parents=True)
    object_root = stage / "object-store"
    object_root.mkdir(mode=0o700)
    (object_root / "00").mkdir(mode=0o700)
    (object_root / "00" / "object.bin").write_bytes(b"opaque-stage-object")
    os.chmod(object_root / "00" / "object.bin", 0o600)
    for name in ("instance-ed25519.key", "auth-rate-limit.key"):
        path = stage / name
        path.write_bytes(b"k" * 32)
        os.chmod(path, 0o600)
    receipt = {
        "format_version": 1,
        "job_id": PROJECT_JOB,
        "archive_id": ARCHIVE_ID,
        "archive_sha256": hashlib.sha256(b"encrypted archive").hexdigest(),
        "generation": STAGE_GENERATION,
        "schema": "atermius",
        "object_store_id": OBJECT_STORE_ID,
        "restored_objects": 1,
        "binding_id": BINDING_ID,
        "target_fingerprint": hashlib.sha256(STAGE_URL.encode()).hexdigest(),
        "target_database_oid": 49103,
        "target_database_name": "stage_db",
    }
    receipt_file = stage / "postgres-restore-receipt.json"
    receipt_file.write_text(json.dumps(receipt, separators=(",", ":")), encoding="utf-8")
    os.chmod(receipt_file, 0o600)
    for path in (archive, key_root, stage, object_root, object_root / "00", receipt_file):
        os.chmod(path, 0o700 if path.is_dir() else 0o600)
    compose_files = []
    for name in ("compose.yaml", "compose.backup.yaml", "compose.object-store-filesystem.yaml", "compose.postgres.yaml"):
        path = deploy / name
        path.write_text("services: {}\n", encoding="utf-8")
        compose_files.append(path)
    state_dir = deploy / ".pg-restore-cutover"
    monkeypatch.setattr(cutover, "ROOT", tmp_path)
    monkeypatch.setattr(cutover, "DEPLOY", deploy)
    monkeypatch.setattr(cutover, "ENV_FILE", env_file)
    monkeypatch.setattr(cutover, "JOURNAL_DIR", state_dir)
    monkeypatch.setattr(cutover, "COMPOSE_FILES", tuple(compose_files))
    monkeypatch.setattr(cutover, "SERVICE_UID", os.getuid())
    runtime = FakeCompose(env_file, archive)
    monkeypatch.setattr(cutover.subprocess, "run", runtime.run)
    monkeypatch.setattr(cutover.urllib.request, "build_opener", lambda *_args, **_kwargs: FakeOpener(runtime))
    monkeypatch.setattr(cutover.time, "sleep", lambda _seconds: None)
    fake_clock = SimpleNamespace(value=0.0)

    def monotonic() -> float:
        fake_clock.value += 0.25
        return fake_clock.value

    monkeypatch.setattr(cutover.time, "monotonic", monotonic)
    return SimpleNamespace(
        env_file=env_file,
        archive=archive,
        stage=stage,
        receipt=receipt,
        state_dir=state_dir,
        runtime=runtime,
    )


def _apply(harness, **kwargs):
    return cutover.apply(
        PROJECT_JOB,
        confirm_ingress_drained=True,
        confirm_writers_stopped=True,
        timeout_seconds=2,
        **kwargs,
    )


def test_apply_transitions_only_server_and_writes_redacted_private_state(harness):
    result = _apply(harness)
    assert result == {"state": "committed", "job_id": PROJECT_JOB, "generation": STAGE_GENERATION, "ingress_action": "untouched"}
    env = cutover._parse_env(harness.env_file.read_bytes())[2]
    stage_container = f"/backups/restore-staging/atermius-pg-restore-{PROJECT_JOB}"
    assert env[cutover.PG_URL_KEY] == STAGE_URL
    assert env[cutover.RESTORE_TARGET_KEY] == NEXT_URL
    assert env[cutover.OBJECT_ROOT_KEY] == stage_container + "/object-store"
    assert env[cutover.SIGNING_KEY_FILE_KEY] == stage_container + "/instance-ed25519.key"
    assert env[cutover.RATE_KEY_FILE_KEY] == stage_container + "/auth-rate-limit.key"
    assert harness.runtime.stop_calls == 1
    assert len(harness.runtime.up_calls) == 1
    assert harness.runtime.activation_calls == 1
    assert all("down" not in command and "volume" not in command for command in harness.runtime.commands)
    journal_path = harness.state_dir / f"{PROJECT_JOB}.json"
    journal = journal_path.read_text(encoding="utf-8")
    assert stat.S_IMODE(journal_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(harness.state_dir.stat().st_mode) == 0o700
    assert SECRET not in journal
    assert SOURCE_URL not in journal and STAGE_URL not in journal and NEXT_URL not in journal
    assert '"instance_id"' in journal  # Identity DTO fields are non-secret.
    assert INSTANCE_ID in journal and SPACE_ID in journal and SIGNING_PUBLIC in journal
    assert "PRIVATE_SENTINEL" in harness.env_file.read_text(encoding="utf-8")
    assert result["ingress_action"] == "untouched"


def test_health_failure_restores_source_and_uses_next_empty_restore_target(harness):
    harness.runtime.fail_stage_health = True
    with pytest.raises(cutover.CutoverError, match="HEALTH_NOT_READY"):
        _apply(harness)
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    assert values[cutover.PG_URL_KEY] == SOURCE_URL
    assert values[cutover.RESTORE_TARGET_KEY] == NEXT_URL
    assert harness.runtime.running
    assert harness.runtime.active_is_stage() is False
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    assert journal["phase"] == "rolled_back"
    assert harness.runtime.activation_calls == 0


def test_identity_mismatch_before_activation_rolls_back_source(harness):
    harness.runtime.fail_stage_identity = True
    with pytest.raises(cutover.CutoverError, match="HEALTH_RESPONSE_INVALID|INSTANCE_IDENTITY_INVALID"):
        _apply(harness)
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    assert values[cutover.PG_URL_KEY] == SOURCE_URL
    assert values[cutover.RESTORE_TARGET_KEY] == NEXT_URL
    assert harness.runtime.running and not harness.runtime.active_is_stage()
    assert harness.runtime.activation_calls == 0


def test_activate_uncertain_is_never_rolled_back_and_recover_is_idempotent(harness, monkeypatch):
    # Simulate the marker commit succeeding but the journal's committed write
    # failing, which leaves durable phase=activating for recovery.
    original_write = cutover._write_journal
    failed = {"once": False}

    def fail_committed_once(path, journal):
        if journal.get("phase") == "committed" and not failed["once"]:
            failed["once"] = True
            raise cutover.CutoverError("JOURNAL_WRITE_FAILED")
        return original_write(path, journal)

    monkeypatch.setattr(cutover, "_write_journal", fail_committed_once)
    with pytest.raises(cutover.CutoverError, match="JOURNAL_WRITE_FAILED"):
        _apply(harness)
    durable = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    assert durable["phase"] == "activating"
    assert harness.runtime.activated
    monkeypatch.setattr(cutover, "_write_journal", original_write)
    with pytest.raises(cutover.CutoverError, match="ACTIVATION_STATE_UNCERTAIN"):
        cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)
    recovered = cutover.recover(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True, timeout_seconds=2)
    assert recovered["state"] == "committed"
    assert recovered["ingress_action"] == "untouched"
    assert harness.runtime.activation_calls == 2
    assert harness.runtime.activated
    assert cutover.recover(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True, timeout_seconds=2) == recovered
    assert harness.runtime.activation_calls == 2


def test_activation_cli_failure_marks_uncertain_without_source_rollback(harness, capsys):
    harness.runtime.fail_activation = True
    assert cutover.main([
        "apply", "--job-id", PROJECT_JOB,
        "--confirm-ingress-drained", "--confirm-all-pg-writers-stopped",
        "--health-timeout-seconds", "2",
    ]) == 2
    captured = capsys.readouterr()
    assert SECRET not in captured.out + captured.err
    assert "private SQL diagnostic" not in captured.out + captured.err
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    assert values[cutover.PG_URL_KEY] == STAGE_URL
    assert journal["phase"] == "activation_uncertain"
    assert harness.runtime.running and harness.runtime.active_is_stage()
    assert len(harness.runtime.up_calls) == 1  # No second source restart/rollback after activation may have committed.


def test_activation_binding_mismatch_stays_uncertain_without_rollback(harness, capsys):
    # Model a successful CLI process whose binding receipt does not match the
    # staged receipt. The marker may already exist, so the coordinator must
    # preserve the stage configuration and require operator recovery.
    harness.runtime.activation_payload_override = {"target_database_oid": 49104}
    assert cutover.main([
        "apply", "--job-id", PROJECT_JOB,
        "--confirm-ingress-drained", "--confirm-all-pg-writers-stopped",
        "--health-timeout-seconds", "2",
    ]) == 2
    captured = capsys.readouterr()
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    assert journal["phase"] == "activation_uncertain"
    assert journal["last_error_code"] == "ACTIVATION_RECEIPT_INVALID"
    assert values[cutover.PG_URL_KEY] == STAGE_URL
    assert harness.runtime.running and harness.runtime.active_is_stage()
    assert harness.runtime.activation_calls == 1
    assert harness.runtime.stop_calls == 1
    assert len(harness.runtime.up_calls) == 1
    assert SECRET not in captured.out + captured.err
    assert "49104" not in captured.out + captured.err
    with pytest.raises(cutover.CutoverError, match="ACTIVATION_STATE_UNCERTAIN"):
        cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)
    assert harness.runtime.activation_calls == 1
    assert len(harness.runtime.up_calls) == 1


def test_out_of_band_activation_marker_prevents_source_rollback(harness):
    original = cutover._read_env(cutover.ENV_FILE)
    receipt, _host_stage, stage_container = cutover._read_receipt(PROJECT_JOB, original.values)
    source_identity = cutover._read_source_identity(cutover._health_base(original.values))
    updates, _urls = cutover._stage_values(original.values, receipt, stage_container)
    staged = cutover._stage_env_bytes(original.raw, updates)
    rollback_env = cutover._rollback_values(original.raw, NEXT_URL)
    with cutover._locked_state(PROJECT_JOB) as (journal_path, backup_path, _):
        cutover._backup_original_env(backup_path, original)
        journal = cutover._journal_new(
            PROJECT_JOB, receipt, source_identity, original.raw, staged,
            rollback_env, cutover._compose_hash(),
        )
        cutover._write_journal(journal_path, journal)
        cutover._atomic_replace(cutover.ENV_FILE, staged, mode=0o600, owner_uid=os.geteuid())
        cutover._set_phase(journal_path, journal, "stage_verified")
    harness.runtime.container_env = harness.runtime._environment_items()
    harness.runtime.activated = True  # Model activation through the standalone CLI.

    with pytest.raises(cutover.CutoverError, match="ACTIVATION_STATE_UNCERTAIN"):
        cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)

    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    assert values[cutover.PG_URL_KEY] == STAGE_URL
    assert journal["phase"] == "activation_uncertain"
    assert harness.runtime.running and harness.runtime.active_is_stage()
    assert harness.runtime.up_calls
    assert harness.runtime.activation_calls == 0
    recovered = cutover.recover(
        PROJECT_JOB,
        confirm_ingress_drained=True,
        confirm_writers_stopped=True,
        timeout_seconds=2,
    )
    assert recovered["state"] == "committed"
    assert harness.runtime.activated


def test_apply_rejects_running_container_with_stale_source_pg_config(harness):
    harness.runtime.container_env = [
        f"{cutover.PG_URL_KEY}={STAGE_URL}" if entry.startswith(f"{cutover.PG_URL_KEY}=") else entry
        for entry in harness.runtime.container_env
    ]
    with pytest.raises(cutover.CutoverError, match="COMPOSE_RUNTIME_CONFIG_MISMATCH"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not (harness.state_dir / f"{PROJECT_JOB}.json").exists()


def test_apply_rejects_running_container_with_different_object_store_mount(harness):
    for mount in harness.runtime.container_mounts:
        if mount["Destination"] == "/object-store":
            mount["Name"] = "atermius-unexpected-object-store"
    with pytest.raises(cutover.CutoverError, match="COMPOSE_RUNTIME_CONFIG_MISMATCH"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not (harness.state_dir / f"{PROJECT_JOB}.json").exists()


@pytest.mark.parametrize(
    ("target", "field", "value"),
    [
        ("/data", "Name", "atermius-unexpected-data"),
        ("/backup-key", "Source", "/tmp/unexpected-backup-key"),
    ],
)
def test_apply_rejects_running_container_with_different_critical_mount(
    harness, target, field, value
):
    for mount in harness.runtime.container_mounts:
        if mount["Destination"] == target:
            mount[field] = value
    with pytest.raises(cutover.CutoverError, match="COMPOSE_RUNTIME_CONFIG_MISMATCH"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not (harness.state_dir / f"{PROJECT_JOB}.json").exists()


def test_apply_rejects_remote_docker_context_before_side_effects(harness):
    harness.runtime.docker_endpoint = "ssh://deploy@example.invalid"
    with pytest.raises(cutover.CutoverError, match="COMPOSE_REMOTE_CONTEXT_UNSUPPORTED"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not harness.state_dir.exists()


def test_apply_rejects_remote_docker_host_before_side_effects(harness, monkeypatch):
    monkeypatch.setenv("DOCKER_HOST", "tcp://docker.example.invalid:2376")
    with pytest.raises(cutover.CutoverError, match="COMPOSE_REMOTE_CONTEXT_UNSUPPORTED"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not harness.state_dir.exists()


def test_apply_rejects_local_docker_host_that_differs_from_pinned_context(
    harness, monkeypatch
):
    monkeypatch.setenv("DOCKER_HOST", "unix:///run/user/1000/docker.sock")
    with pytest.raises(cutover.CutoverError, match="COMPOSE_CONTEXT_MISMATCH"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not harness.state_dir.exists()


def test_explicit_rollback_before_activation_restores_source_but_never_stage_url(harness):
    # Construct the durable, pre-activation stage_verified phase as if the
    # coordinator process stopped after identity verification.
    original = cutover._read_env(cutover.ENV_FILE)
    receipt, _host_stage, stage_container = cutover._read_receipt(PROJECT_JOB, original.values)
    source_identity = cutover._read_source_identity(cutover._health_base(original.values))
    updates, _urls = cutover._stage_values(original.values, receipt, stage_container)
    staged = cutover._stage_env_bytes(original.raw, updates)
    rollback = cutover._rollback_values(original.raw, NEXT_URL)
    with cutover._locked_state(PROJECT_JOB) as (journal_path, backup_path, _):
        cutover._backup_original_env(backup_path, original)
        journal = cutover._journal_new(PROJECT_JOB, receipt, source_identity, original.raw, staged, rollback, cutover._compose_hash())
        cutover._write_journal(journal_path, journal)
        cutover._atomic_replace(cutover.ENV_FILE, staged, mode=0o600, owner_uid=os.geteuid())
        cutover._set_phase(journal_path, journal, "stage_verified")
    harness.runtime.running = False
    result = cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)
    assert result["state"] == "rolled_back"
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    assert values[cutover.PG_URL_KEY] == SOURCE_URL
    assert values[cutover.RESTORE_TARGET_KEY] == NEXT_URL
    assert harness.runtime.running and not harness.runtime.active_is_stage()


def test_recover_resumes_interrupted_rollback_phase(harness, monkeypatch):
    original = cutover._read_env(cutover.ENV_FILE)
    receipt, _host_stage, stage_container = cutover._read_receipt(PROJECT_JOB, original.values)
    source_identity = cutover._read_source_identity(cutover._health_base(original.values))
    updates, _urls = cutover._stage_values(original.values, receipt, stage_container)
    staged = cutover._stage_env_bytes(original.raw, updates)
    rollback = cutover._rollback_values(original.raw, NEXT_URL)
    with cutover._locked_state(PROJECT_JOB) as (journal_path, backup_path, _):
        cutover._backup_original_env(backup_path, original)
        journal = cutover._journal_new(PROJECT_JOB, receipt, source_identity, original.raw, staged, rollback, cutover._compose_hash())
        cutover._write_journal(journal_path, journal)
        cutover._atomic_replace(cutover.ENV_FILE, staged, mode=0o600, owner_uid=os.geteuid())
        cutover._set_phase(journal_path, journal, "stage_verified")

    # Simulate process death after the source server has started but before the
    # journal can leave rolling_back. A fresh recover must repeat the safe
    # restore/start/identity checks and finish durably.
    original_verifier = cutover._verify_source_after_rollback

    def interrupt_after_source_start(_base, _identity):
        raise SystemExit("simulated process interruption")

    monkeypatch.setattr(cutover, "_verify_source_after_rollback", interrupt_after_source_start)
    with pytest.raises(SystemExit, match="simulated process interruption"):
        cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    values = cutover._parse_env(harness.env_file.read_bytes())[2]
    assert journal["phase"] == "rolling_back"
    assert values[cutover.PG_URL_KEY] == SOURCE_URL
    assert values[cutover.RESTORE_TARGET_KEY] == NEXT_URL
    assert harness.runtime.running and not harness.runtime.active_is_stage()
    monkeypatch.setattr(cutover, "_verify_source_after_rollback", original_verifier)
    recovered = cutover.recover(PROJECT_JOB, confirm_ingress_drained=True,
                                confirm_writers_stopped=True, timeout_seconds=2)
    assert recovered["state"] == "rolled_back"
    assert json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())["phase"] == "rolled_back"
    assert harness.runtime.running and not harness.runtime.active_is_stage()


def test_recover_restarts_staged_server_after_stage_verified_crash(harness):
    original = cutover._read_env(cutover.ENV_FILE)
    receipt, _host_stage, stage_container = cutover._read_receipt(PROJECT_JOB, original.values)
    source_identity = cutover._read_source_identity(cutover._health_base(original.values))
    updates, _urls = cutover._stage_values(original.values, receipt, stage_container)
    staged = cutover._stage_env_bytes(original.raw, updates)
    rollback = cutover._rollback_values(original.raw, NEXT_URL)
    with cutover._locked_state(PROJECT_JOB) as (journal_path, backup_path, _):
        cutover._backup_original_env(backup_path, original)
        journal = cutover._journal_new(PROJECT_JOB, receipt, source_identity, original.raw, staged, rollback, cutover._compose_hash())
        cutover._write_journal(journal_path, journal)
        cutover._atomic_replace(cutover.ENV_FILE, staged, mode=0o600, owner_uid=os.geteuid())
        cutover._set_phase(journal_path, journal, "stage_verified")
    harness.runtime.running = False
    harness.runtime.container_env = harness.runtime._environment_items()

    recovered = cutover.recover(PROJECT_JOB, confirm_ingress_drained=True,
                                confirm_writers_stopped=True, timeout_seconds=2)
    assert recovered["state"] == "committed"
    assert harness.runtime.running and harness.runtime.active_is_stage()
    assert len(harness.runtime.up_calls) == 1
    assert harness.runtime.activation_calls == 1


def test_rollback_refuses_to_overwrite_unrecognized_env_during_recovery(harness):
    original = cutover._read_env(cutover.ENV_FILE)
    receipt, _host_stage, stage_container = cutover._read_receipt(PROJECT_JOB, original.values)
    source_identity = cutover._read_source_identity(cutover._health_base(original.values))
    updates, _urls = cutover._stage_values(original.values, receipt, stage_container)
    staged = cutover._stage_env_bytes(original.raw, updates)
    rollback = cutover._rollback_values(original.raw, NEXT_URL)
    with cutover._locked_state(PROJECT_JOB) as (journal_path, backup_path, _):
        cutover._backup_original_env(backup_path, original)
        journal = cutover._journal_new(PROJECT_JOB, receipt, source_identity, original.raw, staged, rollback, cutover._compose_hash())
        cutover._write_journal(journal_path, journal)
        cutover._atomic_replace(cutover.ENV_FILE, staged, mode=0o600, owner_uid=os.geteuid())
        cutover._set_phase(journal_path, journal, "stage_verified")

    operator_change = original.raw + b"UNRELATED_DEPLOYMENT_SETTING=preserve-me\n"
    cutover._atomic_replace(cutover.ENV_FILE, operator_change, mode=0o600, owner_uid=os.geteuid())
    harness.runtime.running = False
    with pytest.raises(cutover.CutoverError, match="ENV_CHANGED"):
        cutover.rollback(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=True)
    journal = json.loads((harness.state_dir / f"{PROJECT_JOB}.json").read_text())
    assert journal["phase"] == "rollback_pending"
    assert harness.env_file.read_bytes() == operator_change
    assert harness.runtime.up_calls == []
    assert not harness.runtime.running


def test_apply_recovers_matching_orphan_env_backup_and_rejects_conflict(harness):
    original = cutover._read_env(harness.env_file)
    harness.state_dir.mkdir(mode=0o700)
    matching_backup = harness.state_dir / f"{PROJECT_JOB}.env.original"
    cutover._atomic_create(matching_backup, original.raw, mode=0o600)
    result = _apply(harness)
    assert result["state"] == "committed"
    assert harness.runtime.activated


def test_apply_fails_closed_on_conflicting_orphan_env_backup(harness):
    original = cutover._read_env(harness.env_file)
    harness.state_dir.mkdir(mode=0o700)
    backup = harness.state_dir / f"{PROJECT_JOB}.env.original"
    cutover._atomic_create(backup, original.raw + b"# different original\n", mode=0o600)
    with pytest.raises(cutover.CutoverError, match="ENV_BACKUP_CONFLICT"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not (harness.state_dir / f"{PROJECT_JOB}.json").exists()
    assert harness.env_file.read_bytes() == original.raw


def test_env_replace_is_atomic_and_rejects_concurrent_change(harness):
    before = harness.env_file.read_bytes()
    changed = before + b"# next\n"
    with pytest.raises(cutover.CutoverError, match="ENV_CHANGED"):
        cutover._atomic_replace(harness.env_file, changed, mode=0o600, owner_uid=os.geteuid(), expected_sha256="0" * 64)
    assert harness.env_file.read_bytes() == before
    cutover._atomic_replace(harness.env_file, changed, mode=0o600, owner_uid=os.geteuid(), expected_sha256=hashlib.sha256(before).hexdigest())
    assert harness.env_file.read_bytes() == changed
    assert stat.S_IMODE(harness.env_file.stat().st_mode) == 0o600


def test_missing_confirmation_and_noncanonical_job_fail_before_side_effects(harness):
    with pytest.raises(cutover.CutoverError, match="OPERATOR_CONFIRMATION_REQUIRED"):
        cutover.apply(PROJECT_JOB, confirm_ingress_drained=True, confirm_writers_stopped=False)
    with pytest.raises(cutover.CutoverError, match="JOB_ID_INVALID"):
        cutover.apply(PROJECT_JOB.upper(), confirm_ingress_drained=True, confirm_writers_stopped=True)
    assert harness.runtime.stop_calls == 0
    assert not harness.state_dir.exists()


def test_current_container_with_additional_compose_overlay_is_rejected(harness):
    expected = ",".join(str(path) for path in cutover.COMPOSE_FILES)
    harness.runtime.config_files_override = expected + ",/deploy/compose.mfa.yaml"
    with pytest.raises(cutover.CutoverError, match="COMPOSE_CONFIG_FILES_MISMATCH"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0
    assert not (harness.state_dir / f"{PROJECT_JOB}.json").exists()


def test_unsafe_env_and_stage_receipt_inputs_fail_closed(harness):
    os.chmod(harness.env_file, 0o644)
    with pytest.raises(cutover.CutoverError, match="UNSAFE_FILE_MODE"):
        cutover._read_env(harness.env_file)
    os.chmod(harness.env_file, 0o600)

    receipt_path = harness.stage / "postgres-restore-receipt.json"
    receipt_path.unlink()
    receipt_path.symlink_to(harness.stage / "missing-receipt-target")
    with pytest.raises(cutover.CutoverError, match="SYMLINK_REJECTED"):
        cutover._read_receipt(PROJECT_JOB, cutover._read_env(harness.env_file).values)
    receipt_path.unlink()
    receipt_path.write_text(json.dumps({**harness.receipt, "target_database_oid": -1}), encoding="utf-8")
    os.chmod(receipt_path, 0o600)
    with pytest.raises(cutover.CutoverError, match="RESTORE_RECEIPT_INVALID"):
        cutover._read_receipt(PROJECT_JOB, cutover._read_env(harness.env_file).values)


def test_unexpected_stage_root_entry_is_rejected_before_compose_mutation(harness):
    (harness.stage / "operator-note.txt").write_text("unexpected", encoding="utf-8")
    with pytest.raises(cutover.CutoverError, match="RESTORE_STAGE_CONTENTS_INVALID"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0


def test_receipt_generation_equal_to_source_is_rejected_before_compose_mutation(harness):
    receipt = {**harness.receipt, "generation": SOURCE_GENERATION}
    receipt_path = harness.stage / "postgres-restore-receipt.json"
    receipt_path.write_text(json.dumps(receipt, separators=(",", ":")), encoding="utf-8")
    os.chmod(receipt_path, 0o600)
    with pytest.raises(cutover.CutoverError, match="RESTORE_GENERATION_NOT_ROTATED"):
        _apply(harness)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.up_calls == []
    assert harness.runtime.activation_calls == 0


def test_host_key_files_reject_wrong_mode_and_symlinks(harness):
    values = cutover._read_env(harness.env_file).values
    signing_key = Path(values[cutover.SIGNING_KEY_HOST_FILE_KEY])
    os.chmod(signing_key, 0o644)
    with pytest.raises(cutover.CutoverError, match="UNSAFE_FILE_MODE"):
        cutover._validate_source_key_files(values, source_paths_are_active=True)
    os.chmod(signing_key, 0o600)

    real_key = signing_key.with_name("signing-key-real")
    signing_key.rename(real_key)
    signing_key.symlink_to(real_key)
    with pytest.raises(cutover.CutoverError, match="SYMLINK_REJECTED"):
        cutover._validate_source_key_files(values, source_paths_are_active=True)


def test_host_bind_and_receipt_target_fingerprint_are_bound(harness):
    env = cutover._read_env(harness.env_file)
    wrong_fingerprint = dict(env.values)
    wrong_fingerprint[cutover.RESTORE_TARGET_KEY] = STAGE_URL + "&application_name=wrong"
    with pytest.raises(cutover.CutoverError, match="RESTORE_TARGET_RECEIPT_MISMATCH"):
        cutover._read_receipt(PROJECT_JOB, wrong_fingerprint)
    # A mount path that differs from the configured host archive is rejected.
    harness.runtime.archive_root = harness.archive.parent
    with pytest.raises(cutover.CutoverError, match="COMPOSE_BACKUP_MOUNT_MISMATCH"):
        cutover._validate_compose(
            env.values,
            expected_pg_url=SOURCE_URL,
            expected_restore_url=STAGE_URL,
            expected_object_root="/object-store",
            expected_signing_file=env.values[cutover.SIGNING_KEY_FILE_KEY],
            expected_rate_file=env.values[cutover.RATE_KEY_FILE_KEY],
        )


def test_journal_and_cli_output_never_contain_database_secrets(harness, capsys):
    assert cutover.main([
        "apply", "--job-id", PROJECT_JOB,
        "--confirm-ingress-drained", "--confirm-all-pg-writers-stopped",
        "--health-timeout-seconds", "2",
    ]) == 0
    captured = capsys.readouterr()
    journal = (harness.state_dir / f"{PROJECT_JOB}.json").read_text(encoding="utf-8")
    assert SECRET not in captured.out and SECRET not in captured.err
    assert SECRET not in journal
    assert SOURCE_URL not in journal and STAGE_URL not in journal and NEXT_URL not in journal
    assert "private SQL diagnostic" not in captured.out + captured.err
    assert harness.runtime.activated
