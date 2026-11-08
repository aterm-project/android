#!/usr/bin/env python3
"""Exercise a disposable Android install through its real accessibility UI.

This is a bounded LocalVault acceptance, not account sync or physical-device
coverage. It never clears an existing application's data. Synthetic secrets
stay in memory; screenshots, UI dumps and private database bytes are not saved.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import secrets
import shlex
import subprocess
import tarfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path


PACKAGE = "com.atermius.aterm_client"
COMPONENT = f"{PACKAGE}/.MainActivity"


class Android:
    def __init__(self, serial: str):
        self.serial = serial

    def run(self, *args: str, timeout: float = 15, check: bool = True) -> bytes:
        try:
            result = subprocess.run(
                ["adb", "-s", self.serial, *args],
                capture_output=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("ADB operation exceeded its timeout") from None
        if check and result.returncode:
            # Do not include arguments or output: they can contain fixture data.
            raise RuntimeError(f"ADB operation failed with code {result.returncode}")
        return result.stdout

    def shell(self, *args: str, timeout: float = 15) -> str:
        return self.run("shell", shlex.join(args), timeout=timeout).decode()

    def ui(self) -> ET.Element:
        # Long waits can outlast the VM's display timeout. Wake only for this
        # observation; do not change the user's global display settings.
        self.shell("input", "keyevent", "224")
        data = self.run("exec-out", "uiautomator", "dump", "/dev/tty", timeout=20)
        start = data.find(b"<?xml")
        end = data.find(b"</hierarchy>")
        if start < 0 or end < 0:
            raise RuntimeError("Android accessibility hierarchy is unavailable")
        return ET.fromstring(data[start : end + len(b"</hierarchy>")])

    @staticmethod
    def labels(node: ET.Element) -> tuple[str, ...]:
        return tuple(node.get(key, "") for key in ("text", "content-desc", "hint"))

    def find(self, label: str, *, prefix: bool = False, contains: bool = False, edit: bool = False) -> ET.Element:
        candidates = []
        for node in self.ui().iter("node"):
            if edit and node.get("class") != "android.widget.EditText":
                continue
            if node.get("enabled") == "false":
                continue
            if any(label in value if contains else value.startswith(label) if prefix else value == label for value in self.labels(node)):
                candidates.append(node)
        if len(candidates) != 1:
            raise LookupError(f"Expected one accessible control; found {len(candidates)}")
        return candidates[0]

    def wait(self, label: str, *, prefix: bool = False, contains: bool = False, edit: bool = False, timeout: float = 35) -> ET.Element:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                return self.find(label, prefix=prefix, contains=contains, edit=edit)
            except (LookupError, RuntimeError, subprocess.TimeoutExpired):
                time.sleep(0.3)
        raise TimeoutError("Expected Android UI state did not appear")

    def tap_node(self, node: ET.Element) -> None:
        bounds = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if bounds is None:
            raise RuntimeError("Accessible control has invalid bounds")
        x1, y1, x2, y2 = map(int, bounds.groups())
        if x2 <= x1 or y2 <= y1:
            raise RuntimeError("Accessible control has empty bounds")
        self.shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))

    def tap(self, label: str, *, prefix: bool = False, contains: bool = False) -> None:
        self.tap_node(self.wait(label, prefix=prefix, contains=contains))

    def fill(self, label: str, value: str) -> None:
        if re.fullmatch(r"[A-Za-z0-9._/-]+", value) is None:
            raise ValueError("This runner accepts only shell-safe synthetic input")
        self.tap_node(self.wait(label, edit=True))
        deadline = time.monotonic() + 10
        while self.wait(label, edit=True).get("focused") != "true":
            if time.monotonic() >= deadline:
                raise RuntimeError("Synthetic input target did not receive focus")
        # Android can return from tap before Flutter has consumed the focus
        # change. Waiting for accessibility focus prevents a lost first key.
        self.shell("input", "text", value)
        control = self.wait(label, edit=True)
        actual = control.get("text", "")
        if control.get("password") == "true":
            if len(actual) != len(value):
                raise RuntimeError("Synthetic secret input length did not match")
        elif actual != value:
            raise RuntimeError("Synthetic field input did not match exactly")
        # Escape can dismiss the whole Flutter dialog on hardware-keyboard
        # devices. Back is used only while Android reports the IME as visible.
        ime = self.shell("dumpsys", "input_method")
        if "mInputShown=true" in ime or "isInputViewShown=true" in ime:
            self.shell("input", "keyevent", "4")

    def launch(self) -> None:
        self.shell("input", "keyevent", "224")
        self.shell("wm", "dismiss-keyguard")
        self.shell("am", "start", "-W", "-n", COMPONENT, timeout=25)

    def private_files(self) -> dict[str, bytes]:
        archive = self.run("exec-out", "run-as", PACKAGE, "tar", "cf", "-", ".", timeout=30)
        files = {}
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar:
                if not member.isfile():
                    continue
                # A debug Flutter install extracts its kernel blob here; it can
                # exceed 64 MiB before the app has persisted any user records.
                if member.size > 128 * 1024 * 1024:
                    raise RuntimeError("Private file exceeded the acceptance scan bound")
                stream = tar.extractfile(member)
                if stream is None:
                    raise RuntimeError("Cannot inspect a private file")
                files[member.name] = stream.read()
        return files


def stage(value: str) -> None:
    print(f"android-local-profile-stage: {value}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--reuse-owned-install", action="store_true", help="Use only for an install created by this acceptance task")
    parser.add_argument("--clear-owned-data-after", action="store_true", help="After successful checks, clear only this task-created install's synthetic data and keep the APK installed")
    args = parser.parse_args()
    device = Android(args.serial)
    if device.run("get-state").strip() != b"device":
        raise RuntimeError("The requested Android device is not authorized")
    existing = device.shell("pm", "path", PACKAGE).strip()
    if existing and not args.reuse_owned_install:
        raise RuntimeError("Refusing to replace an existing application without an explicit task-owned-install flag")

    marker = secrets.token_hex(12)
    password = f"AndroidProfile{marker}9"
    host_name = f"android-host-{marker}"
    host_address = f"android-{marker}.example.test"
    host_user = f"au-{marker[:10]}"
    sentinels = [password, host_name, host_address, host_user]

    stage("install")
    install = device.run("install", "-r", str(args.apk.resolve()), timeout=120)
    if b"Success" not in install:
        raise RuntimeError("APK installation did not report success")
    device.shell("am", "force-stop", PACKAGE)
    stage("launch")
    device.launch()
    device.tap("Open locally")
    stage("create-profile")
    device.fill("主密码（至少 12 个字符）", password)
    device.tap("创建并解锁")
    device.wait("添加 Host", timeout=60)
    stage("create-host")
    device.tap("添加 Host")
    device.fill("名称", host_name)
    device.fill("主机名或 IP", host_address)
    device.fill("SSH 用户名", host_user)
    device.tap("保存加密 Host")
    device.wait("添加 Host")
    device.wait(host_name, prefix=True)

    stage("force-stop-and-inspect-storage")
    device.shell("am", "force-stop", PACKAGE)
    files = device.private_files()
    sqlite_files = [name for name, data in files.items() if data.startswith(b"SQLite format 3\0")]
    if len(sqlite_files) < 2:
        raise RuntimeError("Expected separate catalog and LocalVault SQLite databases")
    if any(secret.encode() in data for secret in sentinels for data in files.values()):
        raise RuntimeError("Synthetic plaintext was found in app-private persistence")

    stage("relaunch-and-unlock")
    device.launch()
    device.tap("Open locally")
    # A previously accepted test profile may also exist in a reused install.
    # The current flow requires exactly one profile so it cannot unlock an
    # unrelated profile by relying on display order.
    device.tap("本地配置 · ", prefix=True)
    device.fill("本地配置主密码", password)
    device.tap("解锁本地配置")
    device.wait(host_name, prefix=True, timeout=60)
    device.tap("锁定配置")
    device.wait("创建并解锁")
    device.shell("am", "force-stop", PACKAGE)

    final_state = "force_stopped_locked_test_profile"
    if args.clear_owned_data_after:
        stage("clear-task-owned-test-data")
        if device.shell("pm", "clear", PACKAGE).strip() != "Success":
            raise RuntimeError("Task-owned fixture cleanup failed")
        device.launch()
        device.tap("Open locally")
        device.wait("还没有本地配置", prefix=True)
        device.shell("am", "force-stop", PACKAGE)
        final_state = "force_stopped_clean_install"

    result = {
        "schema": 1,
        "scenario": "android-local-profile-host-restart",
        "apk_sha256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
        "android_release": device.shell("getprop", "ro.build.version.release").strip(),
        "android_sdk": device.shell("getprop", "ro.build.version.sdk").strip(),
        "abi_list": device.shell("getprop", "ro.product.cpu.abilist").strip(),
        "package": PACKAGE,
        "preexisting_task_owned_install": bool(existing),
        "installed": True,
        "startup_ui": True,
        "local_profile_create": True,
        "host_create": True,
        "force_stop_relaunch_unlock": True,
        "host_decryption_after_restart": True,
        "private_file_count": len(files),
        "sqlite_database_count": len(sqlite_files),
        "plaintext_marker_matches": 0,
        "task_owned_test_data_cleared": args.clear_owned_data_after,
        "final_app_state": final_state,
        "limits": ["debug APK", "one x86_64 virtual device", "LocalVault Host create only", "not account sync, hardware keystore, SSH or SFTP acceptance"],
    }
    args.result.parent.mkdir(parents=True, exist_ok=True)
    args.result.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    stage("passed")


if __name__ == "__main__":
    main()
