#!/usr/bin/env python3
"""Verify Android RDP engine libraries and write engine-manifest.json.

For each ABI's ``jniLibs/<abi>/libatermius_rdp.so`` this rejects a library
that would not load or would not behave as the Dart FFI bindings expect:

* ELF class/machine must match the ABI and the file must be a shared object;
* every exported ``aterm_rdp_*`` entry point used by lib/desktop/direct/rdp_io.dart
  and WinPR's ``JNI_OnLoad`` (run by System.loadLibrary to record the JavaVM)
  must be defined, and nothing else may be exported (static FreeRDP/OpenSSL
  symbols stay hidden so they cannot interpose on other libraries);
* only Android system libraries may be NEEDED (no undeclared .so to package);
* every PT_LOAD segment must be aligned for 16 KB page devices.

Standard library only; reads ELF metadata with the NDK's llvm-readelf.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ABI_ELF = {"arm64-v8a": ("ELF64", "AArch64"), "x86_64": ("ELF64", "Advanced Micro Devices X86-64")}
REQUIRED_EXPORTS = frozenset(
    {
        "aterm_rdp_features",
        "aterm_rdp_create",
        "aterm_rdp_create_ex",
        "aterm_rdp_connect",
        "aterm_rdp_error",
        "aterm_rdp_rejected_certificate",
        "aterm_rdp_poll",
        "aterm_rdp_frame",
        "aterm_rdp_frame_ex",
        "aterm_rdp_pointer",
        "aterm_rdp_key",
        "aterm_rdp_mouse",
        "aterm_rdp_resize",
        "aterm_rdp_can_resize",
        "aterm_rdp_paste",
        "aterm_rdp_clipboard",
        "aterm_rdp_offer_files",
        "aterm_rdp_file_response",
        "aterm_rdp_remote_files",
        "aterm_rdp_request_file",
        "aterm_rdp_next_event",
        "aterm_rdp_free",
        "aterm_rdp_set_home",
        "JNI_OnLoad",
    }
)
SYSTEM_LIBRARIES = frozenset({"libc.so", "libm.so", "libdl.so", "liblog.so", "libz.so"})
MIN_PAGE_ALIGN = 16384


def readelf(tool: str, *args: str) -> str:
    return subprocess.run([tool, "--wide", *args], check=True, capture_output=True, text=True).stdout


def check_library(tool: str, path: Path, abi: str) -> tuple[list[str], dict]:
    errors: list[str] = []
    header = readelf(tool, "--file-header", str(path))
    elf_class = re.search(r"Class:\s+(\S+)", header)
    machine = re.search(r"Machine:\s+(.+)", header)
    elf_type = re.search(r"Type:\s+(\S+)", header)
    expected = ABI_ELF[abi]
    if not elf_class or not machine or (elf_class.group(1), machine.group(1).strip()) != expected:
        errors.append(f"{abi}: ELF class/machine does not match {expected}")
    if not elf_type or elf_type.group(1) != "DYN":
        errors.append(f"{abi}: not a shared object")

    needed = sorted(set(re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", readelf(tool, "--dynamic", str(path)))))
    extra = [lib for lib in needed if lib not in SYSTEM_LIBRARIES]
    if extra:
        errors.append(f"{abi}: depends on non-system libraries {extra}")

    exports: set[str] = set()
    for line in readelf(tool, "--dyn-syms", str(path)).splitlines():
        fields = line.split()
        # Num: Value Size Type Bind Vis Ndx Name
        if len(fields) >= 8 and fields[0].endswith(":") and fields[6] != "UND":
            if fields[4] in ("GLOBAL", "WEAK") and fields[5] == "DEFAULT":
                exports.add(fields[7].split("@")[0])
    missing = sorted(REQUIRED_EXPORTS - exports)
    unexpected = sorted(
        name for name in exports if not name.startswith("aterm_rdp_") and name != "JNI_OnLoad"
    )
    if missing:
        errors.append(f"{abi}: missing exports {missing}")
    if unexpected:
        errors.append(f"{abi}: exports non-engine symbols ({len(unexpected)}, e.g. {unexpected[:5]})")

    # Type Offset VirtAddr PhysAddr FileSiz MemSiz Flg Align; Flg may contain
    # spaces ("R E"), so the alignment is the last field.
    aligns = [
        int(line.split()[-1], 16)
        for line in readelf(tool, "--program-headers", str(path)).splitlines()
        if line.split()[:1] == ["LOAD"]
    ]
    if not aligns or min(aligns) < MIN_PAGE_ALIGN:
        errors.append(f"{abi}: PT_LOAD alignment {aligns} below {MIN_PAGE_ALIGN}")

    data = path.read_bytes()
    return errors, {
        "path": f"jniLibs/{abi}/{path.name}",
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "needed": needed,
        "exports": sorted(exports),
        "load_align": min(aligns) if aligns else None,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--readelf", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--abi", action="append", required=True, choices=sorted(ABI_ELF))
    parser.add_argument("--ndk-revision", required=True)
    parser.add_argument("--api", required=True, type=int)
    parser.add_argument("--source", action="append", default=[], help="file=sha256 of a verified input")
    args = parser.parse_args(argv)

    errors: list[str] = []
    libraries = {}
    for abi in args.abi:
        path = args.out / "jniLibs" / abi / "libatermius_rdp.so"
        if not path.is_file():
            errors.append(f"{abi}: {path} missing")
            continue
        problems, info = check_library(args.readelf, path, abi)
        errors.extend(problems)
        libraries[abi] = info
    licenses = sorted(p.name for p in (args.out / "assets/licenses/atermius_rdp").glob("*"))
    for name in ("FreeRDP-LICENSE", "OpenSSL-LICENSE.txt"):
        if name not in licenses:
            errors.append(f"license file {name} missing")
    manifest = {
        "engine": "libatermius_rdp.so",
        "abis": libraries,
        "android_api": args.api,
        "ndk_revision": args.ndk_revision,
        "sources": dict(item.split("=", 1) for item in args.source),
        "features": "config_v1, file_clipboard, multimon (no drive/printer/smartcard/audio/camera/usb)",
        "licenses": licenses,
        "ok": not errors,
        "errors": errors,
    }
    (args.out / "engine-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for error in errors:
        print(f"verify_engine: {error}", file=sys.stderr)
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
