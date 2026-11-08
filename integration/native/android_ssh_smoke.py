#!/usr/bin/env python3
"""Use an explicitly owned clean Android install against an isolated SSH fixture.

The private fixture JSON must contain address, port, username, password and
host_fingerprint. Credentials and UI dumps remain in memory. This runner never
creates a remote fixture or changes Android/Windows system settings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import secrets
from pathlib import Path
from datetime import datetime, timezone

from android_local_profile_smoke import Android, PACKAGE


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--owned-install-manifest", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    owned = json.loads(args.owned_install_manifest.read_text())
    apk_hash = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    if owned.get("preexisting_install") is not False or owned.get("package") != PACKAGE:
        raise RuntimeError("The manifest must prove that this task created the install")
    if owned.get("serial") != args.serial or owned.get("apk_sha256") != apk_hash:
        raise RuntimeError("The installation ownership manifest does not match this device and APK")
    if args.fixture.stat().st_mode & 0o077:
        raise RuntimeError("Fixture credentials must be in an owner-only file")
    fixture = json.loads(args.fixture.read_text())
    fixture["address"] = fixture.get("address") or fixture.get("host")
    required = ("address", "port", "username", "password", "host_fingerprint")
    if not all(fixture.get(key) for key in required):
        raise RuntimeError("The isolated fixture is missing connection or trust fields")
    if not str(fixture["host_fingerprint"]).startswith("SHA256:"):
        raise RuntimeError("An independently obtained host-key fingerprint is required")
    device = Android(args.serial)
    marker = secrets.token_hex(10)
    master = f"AndroidSsh{marker}9"
    credential_name = f"android-credential-{marker}"
    host_name = f"android-ssh-{marker}"
    edited_name = f"android-edited-{marker}"
    result = {
        "schema": 1,
        "scenario": "android-local-ssh-sftp-host-crud",
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "apk_sha256": apk_hash,
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "ui_helper_sha256": hashlib.sha256(Path(Android.ui.__code__.co_filename).read_bytes()).hexdigest(),
        "passed": False,
        "checks": {},
        "limits": ["debug APK on one x86_64 virtual device", "isolated password-auth SSH fixture", "SFTP list and text read only; no upload/download acceptance", "not account sync or hardware-backed keystore acceptance"],
    }
    checks = result["checks"]
    current_stage = "verify-clean-install"

    def stage(value: str) -> None:
        nonlocal current_stage
        current_stage = value
        print(f"android-ssh-stage: {value}", flush=True)

    def replace(label: str, value: str) -> None:
        control = device.wait(label, edit=True)
        previous = control.get("text", "")
        if len(previous) > 256:
            raise RuntimeError("Editable fixture field exceeds the bounded input length")
        device.tap_node(control)
        # Ctrl+A is not consistently forwarded by Android virtual keyboards.
        # Move to the end and delete the known-length synthetic field instead.
        device.shell("input", "keyevent", "123")
        device.shell("input", "keyevent", *(["67"] * (len(previous) + 1)))
        if device.wait(label, edit=True).get("text", ""):
            raise RuntimeError("Could not clear the synthetic editable field")
        device.fill(label, value)
        if device.wait(label, edit=True).get("text", "") != value:
            raise RuntimeError("Synthetic field replacement did not match the requested value")

    def connect() -> None:
        device.tap("Host 操作")
        device.tap("连接（本机直连）")

    # This proof applies only to a fresh install created by this task, not to
    # any prior user installation. Refuse an existing profile before writing.
    device.shell("am", "force-stop", PACKAGE)
    device.launch()
    device.tap("Open locally")
    device.wait("还没有本地配置", prefix=True)
    try:
        stage("create-profile-and-credential")
        device.fill("主密码（至少 12 个字符）", master)
        device.tap("创建并解锁")
        device.wait("添加 Host", timeout=60)
        device.tap("凭据")
        device.tap("添加凭据")
        device.fill("凭据名称", credential_name)
        device.fill("用户名", fixture["username"])
        device.fill("密码", fixture["password"])
        device.tap("保存加密凭据")
        device.wait("添加凭据")
        device.wait(credential_name, prefix=True)
        checks["credential_create"] = True

        stage("create-and-update-host")
        device.tap("Host")
        device.tap("添加 Host")
        device.fill("名称", host_name)
        device.fill("主机名或 IP", fixture["address"])
        replace("端口", str(fixture["port"]))
        device.fill("SSH 用户名", fixture["username"])
        for label, expected in (("名称", host_name), ("主机名或 IP", fixture["address"]), ("端口", str(fixture["port"])), ("SSH 用户名", fixture["username"])):
            if device.wait(label, edit=True).get("text", "") != expected:
                raise RuntimeError("A Host connection field did not match the requested fixture")
        stage("select-host-credential")
        device.tap("不关联凭据", contains=True)
        device.tap(credential_name, prefix=True)
        device.tap("保存加密 Host")
        device.wait("添加 Host")
        device.wait(host_name, prefix=True)
        stage("edit-host")
        device.tap(host_name, prefix=True)
        replace("名称", edited_name)
        device.tap("保存加密 Host")
        device.wait("添加 Host")
        device.wait(edited_name, prefix=True)
        checks["host_create_update"] = True

        stage("verify-first-seen-host-key")
        connect()
        device.wait("首次连接：未知 SSH 主机密钥", timeout=45)
        labels = [label for node in device.ui().iter("node") for label in device.labels(node)]
        expected = fixture["host_fingerprint"]
        if not any(expected in label for label in labels):
            raise RuntimeError("Displayed host-key fingerprint differs from the isolated server")
        device.tap("核实并信任此密钥")
        device.wait("打开 SFTP 文件浏览器", timeout=45)
        checks["independent_host_key_fingerprint_match"] = True
        checks["verified_host_fingerprint"] = expected
        checks["password_auth_terminal_open"] = True

        stage("sftp-list")
        device.tap("打开 SFTP 文件浏览器")
        device.wait("SFTP · /")
        # A successful directory result from the isolated chroot must contain
        # these entries. Merely opening the SFTP dialog is not acceptance.
        device.wait("bin\n目录", timeout=35)
        device.wait("etc\n目录")
        checks["sftp_root_directory_list"] = True
        if all(fixture.get(key) for key in ("remote_home", "proof_name", "proof_sha256")):
            stage("sftp-home-list-and-text-read")
            device.tap("输入远端路径")
            replace("远端路径", fixture["remote_home"])
            device.tap("打开")
            device.wait(f"SFTP · {fixture['remote_home']}")
            device.wait(fixture["proof_name"], prefix=True)
            device.tap(f"操作 {fixture['proof_name']}")
            device.tap("编辑文本")
            contents = device.wait("Remote file contents", edit=True).get("text", "")
            if hashlib.sha256(contents.encode()).hexdigest() != fixture["proof_sha256"]:
                raise RuntimeError("SFTP text read did not match the independently generated proof hash")
            checks["sftp_text_read_sha256_match"] = True
            device.tap("Cancel")
        device.tap("关闭 SFTP")
        device.tap("断开连接")
        device.wait(edited_name, prefix=True)

        stage("restart-with-encrypted-credential-and-trust")
        device.shell("am", "force-stop", PACKAGE)
        files = device.private_files()
        markers = [master, fixture["password"], fixture["username"], credential_name, host_name, edited_name]
        if any(value.encode() in data for value in markers for data in files.values()):
            raise RuntimeError("Synthetic credential or Host plaintext was found in persistence")
        checks["credential_plaintext_marker_matches"] = 0
        device.launch()
        device.tap("Open locally")
        device.tap("本地配置 · ", prefix=True)
        device.fill("本地配置主密码", master)
        device.tap("解锁本地配置")
        device.wait(edited_name, prefix=True, timeout=60)
        connect()
        device.wait("打开 SFTP 文件浏览器", timeout=45)
        checks["saved_credential_and_trust_reconnect_after_restart"] = True
        device.tap("断开连接")

        stage("delete-host-and-credential")
        device.tap("Host 操作")
        device.tap("删除")
        device.wait("删除 Host？")
        device.tap("删除")
        device.wait("还没有 Host", prefix=True)
        checks["host_delete"] = True
        device.tap("凭据")
        device.tap("凭据操作")
        device.tap("删除凭据")
        device.wait("删除凭据？")
        device.tap("删除")
        device.wait("还没有凭据", prefix=True)
        checks["credential_delete"] = True
        result["passed"] = True
    except Exception as error:
        result["failed_stage"] = current_stage
        # Exception messages / adb arguments may contain fixture secrets.
        result["failure_type"] = type(error).__name__
        # Keep only control labels, never text-field values, and remove the
        # synthetic fixture identifiers before retaining diagnostic evidence.
        try:
            controls = []
            for node in device.ui().iter("node"):
                label = node.get("content-desc", "") or node.get("hint", "")
                if not label:
                    continue
                for value in (master, credential_name, host_name, edited_name, fixture["username"], fixture["password"]):
                    label = label.replace(value, "<synthetic-redacted>")
                controls.append({"class": node.get("class", ""), "label": label})
            result["failure_control_labels"] = controls
            if current_stage.startswith("sftp-"):
                screenshot = args.result.parent / "android-ssh-failure.png"
                screenshot.write_bytes(device.run("exec-out", "screencap", "-p"))
                result["failure_screenshot"] = screenshot.name
                pid = device.shell("pidof", PACKAGE).strip()
                if re.fullmatch(r"\d+", pid):
                    diagnostics = device.run("logcat", "-d", "--pid", pid, "-v", "threadtime").decode(errors="replace")
                    for value in (master, credential_name, host_name, edited_name, fixture["username"], fixture["password"]):
                        diagnostics = diagnostics.replace(value, "<synthetic-redacted>")
                    diagnostics = re.sub(r"http://127\.0\.0\.1:\d+/[^/\s]+/", "<debug-vm-url-redacted>", diagnostics)
                    log = args.result.parent / "android-ssh-failure.log"
                    log.write_text(diagnostics)
                    result["failure_app_log"] = log.name
        except Exception:
            pass
        raise
    finally:
        stage("clear-task-owned-data")
        device.shell("am", "force-stop", PACKAGE)
        if device.shell("pm", "clear", PACKAGE).strip() != "Success":
            result["cleanup_failed"] = True
            result["passed"] = False
        else:
            result["task_owned_test_data_cleared"] = True
        args.result.parent.mkdir(parents=True, exist_ok=True)
        args.result.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    if not result["passed"]:
        raise RuntimeError("Android acceptance or task-owned fixture cleanup failed")
    stage("passed")


if __name__ == "__main__":
    main()
