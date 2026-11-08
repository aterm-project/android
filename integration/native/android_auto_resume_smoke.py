#!/usr/bin/env python3
"""Bounded real-UI native resume proof with preservation of preexisting data.

Requires an empty local catalog, no Vault/account DB, and no prior secure-store
preferences. It keeps baseline data only in memory and restores those exact
bytes. It never pm-clears the app. The synthetic password is never persisted.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import secrets
import shlex
import sqlite3
import subprocess
import time
import uuid

from android_local_profile_smoke import Android, PACKAGE


CATALOG = "app_flutter/atermius_profile_catalog.sqlite"


def data_names(device: Android) -> list[str]:
    names = device.shell("run-as", PACKAGE, "find", ".", "-type", "f").splitlines()
    result = []
    for raw in names:
        name = raw.removeprefix("./")
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\n" in name:
            raise RuntimeError("Unsafe app-private path")
        if name.startswith(("cache/", "code_cache/", "app_flutter/flutter_assets/", "app_flutter/res_timestamp")):
            continue
        result.append(name)
    return sorted(result)


def read_data(device: Android, names: list[str]) -> dict[str, bytes]:
    result = {}
    for name in names:
        value = device.run("exec-out", "run-as", PACKAGE, "cat", name)
        if len(value) > 2 * 1024 * 1024:
            raise RuntimeError("Data snapshot exceeded its acceptance bound")
        result[name] = value
    return result


def catalog_count(data: bytes) -> int:
    return len(catalog_profiles(data))


def catalog_profiles(data: bytes) -> list[tuple[str, str, str]]:
    database = sqlite3.connect(":memory:")
    try:
        database.deserialize(data)
        rows = database.execute("SELECT profile_id, local_data_domain_id, local_vault_id FROM local_profile_catalog ORDER BY profile_id").fetchall()
        for row in rows:
            if any(str(uuid.UUID(value)) != value for value in row):
                raise RuntimeError("Catalog identifier is not canonical")
        return rows
    finally:
        database.close()


def write_data(device: Android, name: str, value: bytes) -> None:
    device.shell("run-as", PACKAGE, "mkdir", "-p", str(PurePosixPath(name).parent))
    command = shlex.join(["run-as", PACKAGE, "sh", "-c", f"cat > {shlex.quote(name)}"])
    result = subprocess.run(
        ["adb", "-s", device.serial, "shell", "-T", command],
        input=value, capture_output=True, timeout=20,
    )
    if result.returncode:
        raise RuntimeError("Restoring baseline app data failed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    device = Android(args.serial)
    # Caller first checks the VM has no recent user activity. Refuse any actual
    # account/profile material independently before installing or stopping it.
    names = data_names(device)
    if CATALOG not in names or any(".sqlite" in name and name != CATALOG for name in names):
        raise RuntimeError("This proof requires an existing empty local catalog with no other databases")
    if any(name.startswith("shared_prefs/") for name in names):
        raise RuntimeError("Refusing to replace or restore preexisting secure-store preferences")
    baseline = read_data(device, names)
    if catalog_count(baseline[CATALOG]) != 0:
        raise RuntimeError("User profiles exist; stop before modifying the installation")
    marker = secrets.token_hex(12)
    password = f"AndroidResume{marker}9"
    host_name = f"resume-host-{marker}"
    host_address = f"resume-{marker}.example.test"
    host_user = f"resume-{marker[:8]}"
    restore_probe = f"files/.android-resume-restore-{marker}"
    result = {
        "schema": 1,
        "scenario": "android-native-local-secure-resume",
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": args.source_sha256,
        "apk_sha256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "ui_helper_sha256": hashlib.sha256(Path(Android.ui.__code__.co_filename).read_bytes()).hexdigest(),
        "baseline_profile_count": 0,
        "baseline_data_file_count": len(baseline),
        "baseline_catalog_sha256": hashlib.sha256(baseline[CATALOG]).hexdigest(),
        "close_method": "Home then Android am kill of background process; no explicit lock or force-stop during resume proof",
        "passed": False,
        "checks": {},
        "limits": ["one x86_64 LineageOS virtual device", "debug APK", "local profile only; cloud account auto-unlock not exercised", "no hardware-backed security strength claim", "existing transfer evidence reused; no transfer rerun"],
    }
    checks = result["checks"]
    current_stage = "install"
    owned_profile = None

    def stage(value: str) -> None:
        nonlocal current_stage
        current_stage = value
        print(f"android-auto-resume-stage: {value}", flush=True)

    def close_background_process() -> None:
        previous = device.run("shell", f"pidof {PACKAGE}", check=False).strip()
        if not previous:
            raise RuntimeError("No application process exists before close")
        device.shell("input", "keyevent", "3")
        time.sleep(1)
        device.shell("am", "kill", PACKAGE)
        deadline = time.monotonic() + 10
        while device.run("shell", f"pidof {PACKAGE}", check=False).strip():
            if time.monotonic() >= deadline:
                raise RuntimeError("Android did not reclaim the background process")
            time.sleep(0.2)

    try:
        stage("verify-binary-restoration")
        probe_bytes = bytes(range(256))
        write_data(device, restore_probe, probe_bytes)
        if read_data(device, [restore_probe])[restore_probe] != probe_bytes:
            raise RuntimeError("Binary baseline restoration transport did not round-trip")
        device.shell("run-as", PACKAGE, "rm", "--", restore_probe)
        stage("install")
        install = device.run("install", "-r", str(args.apk.resolve()), timeout=120)
        if b"Success" not in install:
            raise RuntimeError("APK installation failed")
        # Installation may preserve a task, so close it before the first run.
        device.shell("am", "force-stop", PACKAGE)
        device.launch()
        tree = device.ui()
        if any("Open locally" in device.labels(node) for node in tree.iter("node")):
            device.tap("Open locally")
        device.wait("还没有本地配置", prefix=True)
        stage("create-owned-profile-and-host")
        device.fill("主密码（至少 12 个字符）", password)
        device.tap("创建并解锁")
        device.wait("添加 Host", timeout=60)
        profiles = catalog_profiles(read_data(device, [CATALOG])[CATALOG])
        if len(profiles) != 1:
            raise RuntimeError("Cannot uniquely identify the newly created fixture profile")
        owned_profile = profiles[0]
        device.tap("添加 Host")
        device.fill("Display name", host_name)
        device.fill("Hostname or IP", host_address)
        device.fill("SSH username", host_user)
        device.tap("Save encrypted host")
        device.wait("添加 Host")
        device.wait(host_name, prefix=True)
        checks["synthetic_profile_and_host_created"] = True

        stage("background-close-and-automatic-resume")
        close_background_process()
        device.launch()
        # Deliberately do not press a workspace choice, choose a profile or
        # enter its password. The saved Host must be visible directly.
        device.wait(host_name, prefix=True, timeout=60)
        device.wait("添加 Host")
        checks["cross_process_auto_resume_without_chooser_or_password"] = True

        stage("explicit-lock-forgets-resume")
        device.tap("工作区菜单")
        device.tap("锁定配置")
        device.wait("创建并解锁")
        close_background_process()
        device.launch()
        device.wait("创建并解锁", timeout=60)
        device.wait("本地配置 · ", prefix=True)
        tree = device.ui()
        labels = [label for node in tree.iter("node") for label in device.labels(node)]
        if any(host_name in label or label == "添加 Host" for label in labels):
            raise RuntimeError("Explicitly locked profile resumed without authentication")
        device.tap("本地配置 · ", prefix=True)
        device.wait("本地配置主密码", edit=True)
        checks["explicit_lock_prevents_resume_after_process_restart"] = True
        checks["manual_unlock_required_after_explicit_lock"] = True
        device.shell("am", "force-stop", PACKAGE)
        persisted = read_data(device, data_names(device))
        sentinels = [password, host_name, host_address, host_user]
        if any(secret.encode() in data for secret in sentinels for data in persisted.values()):
            raise RuntimeError("Synthetic sensitive plaintext found in app-private data")
        checks["plaintext_fixture_marker_matches"] = 0
        result["passed"] = True
    except Exception as error:
        result["failed_stage"] = current_stage
        result["failure_type"] = type(error).__name__
        # Keep no screenshots or raw UI content containing fixture data.
        raise
    finally:
        stage("restore-baseline-data")
        device.shell("am", "force-stop", PACKAGE)
        try:
            current = data_names(device)
            profiles = catalog_profiles(read_data(device, [CATALOG])[CATALOG])
            expected_profiles = [] if owned_profile is None else [owned_profile]
            if profiles != expected_profiles:
                result["cleanup_preserved_unexpected_catalog"] = True
                raise RuntimeError("Catalog changed beyond the owned fixture; preserving all data")
            allowed_new = {CATALOG + suffix for suffix in ("-journal", "-wal", "-shm")}
            allowed_new.add(restore_probe)
            resume_key = "atermius.local-profile-resume.v1"
            allowed_new.add(f"files/local-resume-{hashlib.sha256(resume_key.encode()).hexdigest()}.revoked")
            for preference in ("FlutterSecureStorage", "FlutterSecureKeyStorage", "FlutterSecureStorageConfiguration:FlutterSecureStorage", "FlutterSecureStorageConfiguration"):
                allowed_new.update({f"shared_prefs/{preference}.xml", f"shared_prefs/{preference}.xml.bak"})
            if owned_profile is not None:
                profile_id, domain_id, vault_id = owned_profile
                vault = f"app_flutter/atermius_local_vault_{profile_id}.sqlite"
                allowed_new.update(vault + suffix for suffix in ("", "-journal", "-wal", "-shm"))
                scope = hashlib.sha256(f"{domain_id}\0{vault_id}".encode()).hexdigest()
                lock = hashlib.sha256(f"atermius.known-host-auth.v1.{scope}".encode()).hexdigest()
                allowed_new.add(f"files/coordination/{lock}.lock")
            unknown = set(current) - baseline.keys() - allowed_new
            if unknown:
                result["cleanup_preserved_unowned_files"] = sorted(hashlib.sha256(name.encode()).hexdigest() for name in unknown)
                raise RuntimeError("Unexpected new files are preserved for ownership review")
            for name in current:
                if name not in baseline:
                    device.shell("run-as", PACKAGE, "rm", "--", name)
            for name, data in baseline.items():
                if name not in current or read_data(device, [name])[name] != data:
                    write_data(device, name, data)
            restored = read_data(device, data_names(device))
            if restored != baseline:
                raise RuntimeError("Baseline bytes did not restore exactly")
            result["cleanup"] = {
                "baseline_data_restored_exactly": True,
                "final_profile_count": catalog_count(restored[CATALOG]),
                "new_data_files_remaining": 0,
                "pm_clear_used": False,
                "updated_apk_retained": True,
                "app_force_stopped": True,
            }
        except Exception:
            result["passed"] = False
            result["cleanup_failed"] = True
            raise
        finally:
            args.result.parent.mkdir(parents=True, exist_ok=True)
            args.result.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    stage("passed")


if __name__ == "__main__":
    main()
