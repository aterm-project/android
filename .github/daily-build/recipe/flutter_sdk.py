#!/usr/bin/env python3
"""Pinned Flutter SDK for the daily build: install (macOS/Windows) and verify.

  flutter_sdk.py install --dest DIR          download + verify + extract the
                                             official archive for this runner
  flutter_sdk.py verify --out FILE           check `flutter --version --machine`
                                             against the pin, write it as JSON

Linux keeps using tools/install_flutter_linux.sh (same archive digest).
Archive digests: linux from tools/install_flutter_linux.sh; windows from the
earlier root windows-runtime CI; macos-arm64 verified by root against the
official releases_macos.json on 2026-11-10. Every archive must match its pin
AND the official release index entry (revision, channel, version, Dart).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

PIN = {
    "version": "3.47.5",
    "revision": "6a19cca56475dbfba1478ee68d7bd0c2ef891da1",
    "dart": "3.13.4",
    "archives": {
        "linux-x64": ("stable/linux/flutter_linux_3.47.5-stable.tar.xz",
                      "2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb"),
        "windows-x64": ("stable/windows/flutter_windows_3.47.5-stable.zip",
                        "0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8"),
        "macos-arm64": ("stable/macos/flutter_macos_arm64_3.47.5-stable.zip",
                        "d4dd908b5f8f65515831b6d68ae33307a813f2b68947dded7a1994ee5ea7cead"),
    },
}
BASE = "https://storage.googleapis.com/flutter_infra_release/releases"


def runner_key() -> str:
    system = {"Darwin": "macos", "Windows": "windows", "Linux": "linux"}[platform.system()]
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x64"
    return f"{system}-{arch}"


def download(url: str, target: Path) -> str:
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=120) as response, target.open("wb") as handle:
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
            handle.write(chunk)
    return digest.hexdigest()


def install(dest: Path) -> dict:
    key = runner_key()
    if key not in PIN["archives"] or key == "linux-x64":
        raise SystemExit(f"no installer path for {key} (Linux uses tools/install_flutter_linux.sh)")
    archive, pinned = PIN["archives"][key]
    flutter = dest / "flutter" / "bin" / ("flutter.bat" if key.startswith("windows") else "flutter")
    if flutter.exists():
        return {"archive": archive, "cached": True}
    index_name = {"macos": "releases_macos.json", "windows": "releases_windows.json"}[key.split("-")[0]]
    with urllib.request.urlopen(f"{BASE}/{index_name}", timeout=60) as response:
        index = json.load(response)
    entries = [r for r in index.get("releases", []) if r.get("archive") == archive]
    if len(entries) != 1:
        raise SystemExit(f"official {index_name} does not list exactly one {archive}")
    entry = entries[0]
    if (entry.get("hash"), entry.get("channel"), entry.get("version")) != (PIN["revision"], "stable", PIN["version"]) \
            or not str(entry.get("dart_sdk_version", "")).startswith(PIN["dart"]):
        raise SystemExit(f"official {index_name} entry does not match the pinned revision/version/Dart")
    if not pinned:
        raise SystemExit(f"no pinned archive digest for {key}")
    if entry.get("sha256") != pinned:
        raise SystemExit("official index digest differs from the pinned archive digest")
    expected = pinned
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest) as tmp:
        target = Path(tmp) / Path(archive).name
        actual = download(f"{BASE}/{archive}", target)
        if actual != expected:
            raise SystemExit(f"archive SHA-256 {actual} != expected {expected}")
        if key.startswith("macos"):
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(target), str(dest)], check=True)  # keeps symlinks/modes
        else:
            import zipfile  # Windows: no symlinks/modes to keep; extractall drops absolute/.. members
            with zipfile.ZipFile(target) as archive_file:
                archive_file.extractall(dest)
    return {"archive": archive, "sha256": actual, "cached": False}


def verify(out: Path) -> dict:
    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    if not flutter:
        raise SystemExit("flutter is not on PATH")
    text = subprocess.run([flutter, "--version", "--machine"], check=True, capture_output=True, text=True,
                          env={**os.environ, "FLUTTER_SUPPRESS_ANALYTICS": "true"}).stdout
    data = json.loads(text[text.index("{"):])
    if data.get("frameworkVersion") != PIN["version"] or data.get("frameworkRevision") != PIN["revision"] \
            or not str(data.get("dartSdkVersion", "")).startswith(PIN["dart"]):
        raise SystemExit(f"Flutter toolchain mismatch: {data.get('frameworkVersion')} "
                         f"{data.get('frameworkRevision')} Dart {data.get('dartSdkVersion')}")
    out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("install")
    p.add_argument("--dest", required=True)
    p = sub.add_parser("verify")
    p.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.command == "install":
        result = install(Path(args.dest))
        github_path = os.environ.get("GITHUB_PATH")
        if github_path:
            with open(github_path, "a", encoding="utf-8") as handle:
                handle.write(str(Path(args.dest) / "flutter" / "bin") + "\n")
    else:
        result = verify(Path(args.out))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
