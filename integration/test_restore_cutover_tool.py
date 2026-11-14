"""Focused, mocked coverage for the offline restore cutover coordinator."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import sqlite3
import stat
import sys
import urllib.error
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))
import restore_cutover as cutover  # noqa: E402


PROJECT = "cutover-unit"
SOURCE_VOLUME = "cutover-source-volume"
TARGET_VOLUME = "cutover-target-volume"
JOB_ID = str(uuid.uuid4())
INSTANCE_ID = str(uuid.uuid4())
SPACE_ID = str(uuid.uuid4())
SOURCE_GENERATION = str(uuid.uuid4())
TARGET_GENERATION = str(uuid.uuid4())
HEALTH_URL = "http://127.0.0.1:18888"


class FakeDocker:
    def __init__(self, env_file: Path, source_mountpoint: Path):
        self.env_file = env_file
        self.source_mountpoint = source_mountpoint
        self.volumes = {SOURCE_VOLUME, TARGET_VOLUME}
        self.target_entries = {"rollback-control"}
        self.running: str | None = "source"
        self.installed = False
        self.install_calls = 0
        self.create_calls = 0
        self.stop_calls = 0
        self.start_source_calls = 0
        self.start_target_calls = 0
        self.fail_install = False
        self.fail_target_health = False
        self.last_install_command: list[str] | None = None
        self.last_target_up_command: list[str] | None = None
        self.checkpoint_calls = 0
        self.fail_checkpoint = False
        self.checkpoint_leaves_wal = False
        self.checkpoint_output = (
            "Database checkpointed and verified offline (93 tables, 1204 rows; encrypted). "
            "No -wal, -shm or -journal sidecar remains.\n"
        )
        self.last_checkpoint_command: list[str] | None = None
        self.last_checkpoint_env: dict[str, str] | None = None

    def _env_values(self) -> dict[str, str]:
        values: dict[str, str] = {}
        for line in self.env_file.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"')
        return values

    def _compose_config(self, command: list[str], env: dict[str, str]) -> dict[str, object]:
        file_values = self._env_values()
        volume_name = env.get(cutover.DATA_VOLUME_KEY, file_values.get(cutover.DATA_VOLUME_KEY, "atermius-data"))
        data_dir = env.get(cutover.DATA_DIR_KEY, file_values.get(cutover.DATA_DIR_KEY, "/data"))
        database_url = env.get(cutover.DATABASE_URL_KEY, file_values.get(cutover.DATABASE_URL_KEY, cutover.SOURCE_SETTINGS[cutover.DATABASE_URL_KEY]))
        project = PROJECT
        project_at = command.index("--project-name") + 1
        project = command[project_at]
        return {
            "name": project,
            "services": {
                "server": {
                    "volumes": [{"type": "volume", "source": "server-data", "target": "/data"}],
                    "environment": {
                        cutover.DATA_DIR_KEY: data_dir,
                        cutover.DATABASE_URL_KEY: database_url,
                    },
                }
            },
            "volumes": {"server-data": {"name": volume_name}},
        }

    def run(self, command: list[str], *, env: dict[str, str], capture_output: bool, text: bool,
            timeout: int, check: bool = False) -> subprocess_result:
        assert capture_output and text and not check
        if command[:3] == ["docker", "volume", "ls"]:
            return subprocess_result(0, "\n".join(sorted(self.volumes)) + "\n", "")
        if command[:3] == ["docker", "volume", "create"]:
            self.create_calls += 1
            name = command[-1]
            self.volumes.add(name)
            return subprocess_result(0, name + "\n", "")
        if command[:3] == ["docker", "volume", "inspect"]:
            name = command[-1]
            if name != SOURCE_VOLUME:
                return subprocess_result(1, "", "not found")
            return subprocess_result(0, f"{name}|local|{self.source_mountpoint}\n", "")
        assert command[:2] == ["docker", "compose"]
        if "config" in command:
            return subprocess_result(0, json.dumps(self._compose_config(command, env)), "")
        if "stop" in command:
            self.stop_calls += 1
            self.running = None
            return subprocess_result(0, "", "")
        if "run" in command:
            script = command[-1]
            if "database-checkpoint" in script:
                return self._server_checkpoint(command, env)
            if "/target/restored" in script and "install-restore-stage" not in script:
                # Target path presence is the only mutable data in the target volume.
                return subprocess_result(1 if self.installed else 0, "", "")
            if "install-restore-stage" in script:
                self.install_calls += 1
                self.last_install_command = command
                if self.fail_install:
                    return subprocess_result(1, "", "sensitive installer diagnostic")
                self.installed = True
                self.target_entries.add("restored")
                return subprocess_result(
                    0,
                    f"Restore stage installed at /target/restored with generation {TARGET_GENERATION}. "
                    "The source volume was not changed.",
                    "",
                )
            raise AssertionError(f"unhandled compose run script: {script}")
        if "up" in command:
            volume_name = env.get(cutover.DATA_VOLUME_KEY)
            if volume_name == TARGET_VOLUME:
                self.start_target_calls += 1
                self.running = "target"
                self.last_target_up_command = command
            elif volume_name == SOURCE_VOLUME:
                self.start_source_calls += 1
                self.running = "source"
            else:
                raise AssertionError(f"unexpected selected volume {volume_name!r}")
            return subprocess_result(0, "", "")
        raise AssertionError(f"unhandled command: {command!r}")


def _fake_server_checkpoint(runtime: "FakeDocker", command: list[str], env: dict[str, str]) -> "subprocess_result":
    """Emulate `atermius-server database-checkpoint --server-stopped`."""
    runtime.checkpoint_calls += 1
    runtime.last_checkpoint_command = command
    runtime.last_checkpoint_env = {key: env[key] for key in cutover.ENV_KEYS if key in env}
    if runtime.running is not None:
        return subprocess_result(1, "", "SERVER_RUNNING")
    # Like the server, take the runtime lock exclusively: the coordinator
    # must not hold it while the containerized command runs.
    descriptor = os.open(runtime.source_mountpoint / "server.lock", os.O_RDWR)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return subprocess_result(1, "", "SERVER_RUNNING: sensitive lock diagnostic")
        if runtime.fail_checkpoint:
            return subprocess_result(1, "", "DATABASE_KEY_INVALID: sensitive checkpoint diagnostic")
        if not runtime.checkpoint_leaves_wal:
            for suffix in ("-wal", "-shm"):
                with contextlib.suppress(FileNotFoundError):
                    (runtime.source_mountpoint / f"atermius.db{suffix}").unlink()
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)
    return subprocess_result(0, runtime.checkpoint_output, "")


FakeDocker._server_checkpoint = _fake_server_checkpoint  # type: ignore[attr-defined]


class subprocess_result:
    def __init__(self, returncode: int, stdout: str, stderr: str):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class FakeResponse:
    def __init__(self, payload: dict[str, str]):
        self.status = 200
        self._payload = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, limit: int) -> bytes:
        return self._payload[:limit]


class FakeOpener:
    def __init__(self, runtime: FakeDocker):
        self.runtime = runtime

    def open(self, request, timeout: int):
        assert timeout == cutover.HTTP_TIMEOUT_SECONDS
        if self.runtime.running is None:
            raise urllib.error.URLError("offline")
        if request.full_url.endswith("/health/ready"):
            if self.runtime.running == "target" and self.runtime.fail_target_health:
                return FakeResponse({"status": "starting"})
            return FakeResponse({"status": "ready"})
        assert request.full_url.endswith("/api/v1/instance")
        if self.runtime.running == "target" and self.runtime.fail_target_health:
            return FakeResponse({"invalid": "not an identity"})
        generation = TARGET_GENERATION if self.runtime.running == "target" else SOURCE_GENERATION
        return FakeResponse({
            "instance_id": INSTANCE_ID,
            "server_space_id": SPACE_ID,
            "generation": generation,
        })


class FakeTime:
    def __init__(self):
        self.now = 0.0

    def monotonic(self) -> float:
        self.now += 0.25
        return self.now

    def sleep(self, amount: float) -> None:
        self.now += amount


@pytest.fixture
def harness(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# Keep this unrelated secret unchanged.\n"
        "PRIVATE_SENTINEL=do-not-copy-to-journal-or-output\n"
        f"{cutover.DATA_VOLUME_KEY}={SOURCE_VOLUME}\n"
        f"{cutover.DATA_DIR_KEY}=/data\n"
        f"{cutover.DATABASE_URL_KEY}={cutover.SOURCE_SETTINGS[cutover.DATABASE_URL_KEY]}\n",
        encoding="utf-8",
    )
    os.chmod(env_file, 0o600)
    compose_file = tmp_path / "compose.yaml"
    compose_file.write_text("services: {}\n", encoding="utf-8")
    journal = tmp_path / "state" / "cutover.json"
    journal.parent.mkdir(mode=0o700)
    source_mountpoint = tmp_path / "source-volume"
    source_mountpoint.mkdir(mode=0o700)
    os.chmod(source_mountpoint, 0o700)
    lock_file = source_mountpoint / "server.lock"
    lock_file.write_bytes(b"")
    os.chmod(lock_file, 0o600)
    database = source_mountpoint / "atermius.db"
    connection = sqlite3.connect(database)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("CREATE TABLE IF NOT EXISTS source_marker (value TEXT NOT NULL)")
    connection.execute("INSERT INTO source_marker(value) VALUES ('source-intact')")
    connection.commit()
    connection.close()
    os.chmod(database, 0o600)
    monkeypatch.setattr(cutover, "SERVICE_DATA_UID", os.getuid())
    runtime = FakeDocker(env_file, source_mountpoint)
    fake_time = FakeTime()
    monkeypatch.setattr(cutover.subprocess, "run", runtime.run)
    monkeypatch.setattr(cutover.urllib.request, "build_opener", lambda *_args, **_kwargs: FakeOpener(runtime))
    monkeypatch.setattr(cutover.time, "monotonic", fake_time.monotonic)
    monkeypatch.setattr(cutover.time, "sleep", fake_time.sleep)
    params = dict(
        project=PROJECT,
        env_file_arg=str(env_file),
        compose_args=[str(compose_file)],
        job=JOB_ID,
        target=TARGET_VOLUME,
        health_url_arg=HEALTH_URL,
        journal_arg=str(journal),
        health_timeout=3,
    )
    return SimpleNamespace(env_file=env_file, compose_file=compose_file, journal=journal, runtime=runtime, params=params)


def test_happy_apply_updates_only_data_settings_and_keeps_target_volume_entries(harness):
    result = cutover._apply(**harness.params)

    assert result["state"] == "committed"
    assert result["source_volume"] == SOURCE_VOLUME
    assert result["target_volume"] == TARGET_VOLUME
    assert result["installed_generation"] == TARGET_GENERATION
    assert result["target_generation"] == TARGET_GENERATION
    assert result["source_checkpointed_at"]
    assert harness.runtime.create_calls == 0  # Existing target volume is reused.
    assert harness.runtime.target_entries == {"rollback-control", "restored"}
    assert "PRIVATE_SENTINEL=do-not-copy-to-journal-or-output" in harness.env_file.read_text()
    env = harness.env_file.read_text()
    assert f"{cutover.DATA_VOLUME_KEY}={TARGET_VOLUME}" in env
    assert f"{cutover.DATA_DIR_KEY}=/data/restored" in env
    assert f"{cutover.DATABASE_URL_KEY}={cutover.TARGET_SETTINGS[cutover.DATABASE_URL_KEY]}" in env
    assert stat.S_IMODE(harness.journal.stat().st_mode) == 0o600
    journal_raw = harness.journal.read_text()
    assert "do-not-copy-to-journal-or-output" not in journal_raw
    assert "sensitive installer diagnostic" not in journal_raw
    assert harness.runtime.last_install_command is not None
    assert f"{TARGET_VOLUME}:/target" in harness.runtime.last_install_command
    assert harness.runtime.last_target_up_command is not None
    assert any(item.endswith("target.compose.yaml") for item in harness.runtime.last_target_up_command)

    status = cutover._status(str(harness.journal))
    assert status["state"] == "committed"
    assert "health_url" not in status
    replay = cutover._apply(**harness.params)
    assert replay["state"] == "committed"
    assert harness.runtime.install_calls == 1


def test_cli_apply_status_and_rollback_use_safe_json_summaries(harness, capsys: pytest.CaptureFixture[str]):
    args = [
        "apply", "--project-name", PROJECT, "--env-file", str(harness.env_file),
        "--compose-file", str(harness.compose_file), "--restore-job-id", JOB_ID,
        "--target-volume", TARGET_VOLUME, "--health-url", HEALTH_URL,
        "--journal", str(harness.journal), "--health-timeout-seconds", "3",
    ]
    assert cutover.main(args) == 0
    applied_stdout = capsys.readouterr().out
    applied = json.loads(applied_stdout)
    assert applied["state"] == "committed"
    assert "source_checkpointed_at" in applied
    assert "PRIVATE_SENTINEL" not in applied_stdout
    assert "do-not-copy-to-journal-or-output" not in applied_stdout
    assert str(harness.env_file) not in applied_stdout
    assert HEALTH_URL not in applied_stdout

    assert cutover.main(["status", "--journal", str(harness.journal)]) == 0
    status_stdout = capsys.readouterr().out
    assert json.loads(status_stdout)["state"] == "committed"
    assert HEALTH_URL not in status_stdout

    assert cutover.main(["rollback", "--journal", str(harness.journal)]) == 0
    rollback_stdout = capsys.readouterr().out
    assert json.loads(rollback_stdout)["state"] == "rolled_back"


def test_unhealthy_target_is_stopped_and_source_is_restored(harness):
    harness.runtime.fail_target_health = True

    with pytest.raises(cutover.CutoverError, match="target_health_timeout"):
        cutover._apply(**harness.params)

    journal = json.loads(harness.journal.read_text())
    assert journal["state"] == "rolled_back"
    assert journal["last_error_code"] == "target_health_timeout"
    assert harness.runtime.running == "source"
    assert harness.runtime.start_source_calls == 1
    env = harness.env_file.read_text()
    assert f"{cutover.DATA_VOLUME_KEY}={SOURCE_VOLUME}" in env
    assert f"{cutover.DATA_DIR_KEY}=/data" in env
    assert f"{cutover.DATABASE_URL_KEY}={cutover.SOURCE_SETTINGS[cutover.DATABASE_URL_KEY]}" in env
    assert harness.runtime.target_entries == {"rollback-control", "restored"}


def test_apply_creates_target_volume_only_when_missing(harness):
    harness.runtime.volumes.remove(TARGET_VOLUME)
    result = cutover._apply(**harness.params)
    assert result["state"] == "committed"
    assert harness.runtime.create_calls == 1
    assert TARGET_VOLUME in harness.runtime.volumes


def test_explicit_rollback_and_replay_restore_original_effective_configuration(harness):
    cutover._apply(**harness.params)
    rolled_back = cutover._rollback(str(harness.journal))
    assert rolled_back["state"] == "rolled_back"
    assert harness.runtime.running == "source"
    env = harness.env_file.read_text()
    assert f"{cutover.DATA_VOLUME_KEY}={SOURCE_VOLUME}" in env
    assert f"{cutover.DATA_DIR_KEY}=/data" in env
    assert f"{cutover.DATABASE_URL_KEY}={cutover.SOURCE_SETTINGS[cutover.DATABASE_URL_KEY]}" in env
    assert harness.runtime.volumes == {SOURCE_VOLUME, TARGET_VOLUME}
    assert harness.runtime.target_entries == {"rollback-control", "restored"}
    starts = harness.runtime.start_source_calls
    assert cutover._rollback(str(harness.journal))["state"] == "rolled_back"
    assert harness.runtime.start_source_calls == starts


def test_interrupted_rollback_is_resumed_by_explicit_rollback(harness, monkeypatch: pytest.MonkeyPatch):
    cutover._apply(**harness.params)
    stop = cutover._compose_stop

    def crash_before_stop(record, env_file, compose_files):
        raise KeyboardInterrupt()

    monkeypatch.setattr(cutover, "_compose_stop", crash_before_stop)
    with pytest.raises(KeyboardInterrupt):
        cutover._rollback(str(harness.journal))
    record = json.loads(harness.journal.read_text())
    assert record["state"] == "rolling_back"
    assert harness.runtime.running == "target"

    monkeypatch.setattr(cutover, "_compose_stop", stop)
    replay = cutover._rollback(str(harness.journal))
    assert replay["state"] == "rolled_back"
    assert harness.runtime.running == "source"
    assert harness.runtime.volumes == {SOURCE_VOLUME, TARGET_VOLUME}


def test_apply_resumes_a_durably_recorded_automatic_rollback(harness, monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    sidecar_target = tmp_path / "untrusted-sidecar"
    sidecar_target.write_bytes(b"not a sqlite sidecar")
    (harness.runtime.source_mountpoint / "atermius.db-wal").symlink_to(sidecar_target)
    save = cutover._save_journal

    def persist_then_interrupt(path, record):
        save(path, record)
        if record["state"] == "rolling_back":
            raise KeyboardInterrupt()

    monkeypatch.setattr(cutover, "_save_journal", persist_then_interrupt)
    with pytest.raises(KeyboardInterrupt):
        cutover._apply(**harness.params)
    record = json.loads(harness.journal.read_text())
    assert record["state"] == "rolling_back"

    monkeypatch.setattr(cutover, "_save_journal", save)
    resumed = cutover._apply(**harness.params)
    assert resumed["state"] == "rolled_back"
    assert harness.runtime.running == "source"
    assert harness.runtime.install_calls == 0


def test_interrupted_target_start_is_resumed_idempotently(harness, monkeypatch: pytest.MonkeyPatch):
    start_target = cutover._start_target

    def crash_after_durable_target_start_state(record, env_file, compose_files):
        raise KeyboardInterrupt()

    monkeypatch.setattr(cutover, "_start_target", crash_after_durable_target_start_state)
    with pytest.raises(KeyboardInterrupt):
        cutover._apply(**harness.params)
    record = json.loads(harness.journal.read_text())
    assert record["state"] == "target_starting"
    assert record["installed_generation"] == TARGET_GENERATION
    assert harness.runtime.running is None

    monkeypatch.setattr(cutover, "_start_target", start_target)
    resumed = cutover._apply(**harness.params)
    assert resumed["state"] == "committed"
    assert harness.runtime.install_calls == 1
    assert harness.runtime.start_target_calls == 1


def test_source_sidecars_fail_closed_and_restart_source(harness, tmp_path: Path):
    sidecar_target = tmp_path / "untrusted-sidecar"
    sidecar_target.write_bytes(b"not a sqlite sidecar")
    (harness.runtime.source_mountpoint / "atermius.db-wal").symlink_to(sidecar_target)

    with pytest.raises(cutover.CutoverError, match="source_sidecar_unsafe"):
        cutover._apply(**harness.params)

    record = json.loads(harness.journal.read_text())
    assert record["state"] == "rolled_back"
    assert record["source_checkpointed_at"] is None
    assert harness.runtime.install_calls == 0
    assert harness.runtime.running == "source"
    assert f"{cutover.DATA_VOLUME_KEY}={SOURCE_VOLUME}" in harness.env_file.read_text()


def test_journal_symlink_and_unsafe_mode_are_rejected(harness, tmp_path: Path):
    target = tmp_path / "outside.json"
    target.write_text("{}", encoding="utf-8")
    os.chmod(target, 0o600)
    link = tmp_path / "link.json"
    link.symlink_to(target)
    with pytest.raises(cutover.CutoverError, match="unsafe_file"):
        cutover._status(str(link))

    unsafe = harness.journal.parent / "unsafe.json"
    unsafe.write_text("{}", encoding="utf-8")
    os.chmod(unsafe, 0o644)
    with pytest.raises(cutover.CutoverError, match="journal_permissions"):
        cutover._load_journal(unsafe)


def test_env_symlink_is_rejected_before_compose_or_volume_mutation(harness, tmp_path: Path):
    link = tmp_path / "env-link"
    link.symlink_to(harness.env_file)
    params = {**harness.params, "env_file_arg": str(link)}
    with pytest.raises(cutover.CutoverError, match="unsafe_file"):
        cutover._apply(**params)
    assert harness.runtime.stop_calls == 0
    assert harness.runtime.create_calls == 0


def test_compose_mount_resolution_uses_physical_volume_and_rejects_bind_or_ambiguous_sources():
    config = {
        "name": PROJECT,
        "services": {
            "server": {
                "volumes": [{"type": "volume", "source": "server-data", "target": "/data"}],
                "environment": dict(cutover.SOURCE_SETTINGS),
            }
        },
        "volumes": {"server-data": {"name": SOURCE_VOLUME}},
    }
    assert cutover._source_volume(config) == SOURCE_VOLUME

    bind_config = json.loads(json.dumps(config))
    bind_config["services"]["server"]["volumes"][0]["type"] = "bind"
    with pytest.raises(cutover.CutoverError, match="compose_data_mount_not_named"):
        cutover._source_volume(bind_config)

    ambiguous_config = json.loads(json.dumps(config))
    ambiguous_config["services"]["server"]["volumes"].append(
        {"type": "volume", "source": "other-data", "target": "/data"}
    )
    with pytest.raises(cutover.CutoverError, match="compose_data_mount_ambiguous"):
        cutover._source_volume(ambiguous_config)


def test_environment_duplicate_managed_setting_is_rejected_without_write(harness):
    before = harness.env_file.read_bytes()
    with harness.env_file.open("a", encoding="utf-8") as stream:
        stream.write(f"{cutover.DATA_DIR_KEY}=/another-path\n")
    changed = harness.env_file.read_bytes()
    with pytest.raises(cutover.CutoverError, match="env_duplicate_data_setting"):
        cutover._atomic_update_env(
            {},
            harness.env_file,
            {cutover.DATA_VOLUME_KEY: TARGET_VOLUME, **cutover.TARGET_SETTINGS},
        )
    assert harness.env_file.read_bytes() == changed
    assert before != changed


ENCRYPTED_HEADER = bytes(range(16))  # SQLCipher files start with a random salt


def _make_source_encrypted(harness, monkeypatch: pytest.MonkeyPatch, *, with_wal: bool = True) -> bytes:
    """Replace the fixture database with an opaque SQLCipher-like file.

    Python's sqlite3 has no SQLCipher: the coordinator must never open this
    file with it, so any attempt fails the test.
    """
    source = harness.runtime.source_mountpoint
    database = source / "atermius.db"
    for suffix in ("-wal", "-shm"):
        with contextlib.suppress(FileNotFoundError):
            (source / f"atermius.db{suffix}").unlink()
    payload = ENCRYPTED_HEADER + os.urandom(4096 - len(ENCRYPTED_HEADER))
    database.write_bytes(payload)
    os.chmod(database, 0o600)
    if with_wal:
        for suffix in ("-wal", "-shm"):
            sidecar = source / f"atermius.db{suffix}"
            sidecar.write_bytes(os.urandom(512))
            os.chmod(sidecar, 0o600)

    def no_host_sqlite(*_args, **_kwargs):
        raise AssertionError("the coordinator opened an encrypted database with host sqlite3")

    monkeypatch.setattr(cutover.sqlite3, "connect", no_host_sqlite)
    return payload


def test_plaintext_source_is_checkpointed_on_the_host_without_a_server_command(harness):
    result = cutover._apply(**harness.params)
    assert result["state"] == "committed"
    assert harness.runtime.checkpoint_calls == 0


def test_encrypted_source_is_checkpointed_inside_the_server_image(harness, monkeypatch: pytest.MonkeyPatch):
    payload = _make_source_encrypted(harness, monkeypatch)

    result = cutover._apply(**harness.params)

    assert result["state"] == "committed"
    assert result["source_checkpointed_at"]
    assert harness.runtime.checkpoint_calls == 1
    assert harness.runtime.install_calls == 1
    command = harness.runtime.last_checkpoint_command
    assert command is not None
    assert command[-1] == "/usr/local/bin/atermius-server database-checkpoint --server-stopped"
    assert command[command.index("--entrypoint") + 1] == "/bin/sh"
    assert "--no-deps" in command and "--rm" in command
    # The command runs against the recorded source volume and data layout,
    # with the deployment's own key configuration from the env file.
    assert harness.runtime.last_checkpoint_env == {
        cutover.DATA_VOLUME_KEY: SOURCE_VOLUME, **cutover.SOURCE_SETTINGS,
    }
    source = harness.runtime.source_mountpoint
    assert not (source / "atermius.db-wal").exists()
    assert not (source / "atermius.db-shm").exists()
    # The host never rewrote the encrypted source file.
    assert (source / "atermius.db").read_bytes() == payload
    journal_raw = harness.journal.read_text()
    assert "sensitive" not in journal_raw
    assert "tables" not in journal_raw


@pytest.mark.parametrize(
    ("setting", "expected"),
    [
        ("fail_checkpoint", "source_checkpoint_failed"),
        ("checkpoint_leaves_wal", "source_sidecar_remains"),
        ("bad_receipt", "source_checkpoint_receipt_invalid"),
    ],
)
def test_encrypted_source_checkpoint_failures_fail_closed_and_restart_source(
    harness, monkeypatch: pytest.MonkeyPatch, setting: str, expected: str
):
    _make_source_encrypted(harness, monkeypatch)
    if setting == "bad_receipt":
        harness.runtime.checkpoint_output = "Database checkpointed and verified offline (1 tables, 1 rows; plaintext).\n"
    else:
        setattr(harness.runtime, setting, True)

    with pytest.raises(cutover.CutoverError, match=expected):
        cutover._apply(**harness.params)

    record = json.loads(harness.journal.read_text())
    assert record["state"] == "rolled_back"
    assert record["last_error_code"] == expected
    assert record["source_checkpointed_at"] is None
    assert harness.runtime.checkpoint_calls == 1
    assert harness.runtime.install_calls == 0
    assert harness.runtime.running == "source"
    assert f"{cutover.DATA_VOLUME_KEY}={SOURCE_VOLUME}" in harness.env_file.read_text()
    assert "sensitive" not in harness.journal.read_text()


def test_encrypted_source_with_unsafe_sidecar_is_rejected_before_the_server_command(
    harness, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    _make_source_encrypted(harness, monkeypatch, with_wal=False)
    sidecar_target = tmp_path / "untrusted-sidecar"
    sidecar_target.write_bytes(b"not a sqlite sidecar")
    (harness.runtime.source_mountpoint / "atermius.db-wal").symlink_to(sidecar_target)

    with pytest.raises(cutover.CutoverError, match="source_sidecar_unsafe"):
        cutover._apply(**harness.params)

    assert harness.runtime.checkpoint_calls == 0
    assert harness.runtime.install_calls == 0
    assert harness.runtime.running == "source"
