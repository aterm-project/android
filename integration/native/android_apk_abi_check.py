#!/usr/bin/env python3
"""Reject Flutter APKs that advertise an ABI they cannot run on.

Android installs an APK on any device whose ABI has a ``lib/<abi>/`` directory.
If a plugin ships ``.so`` files for an ABI that Flutter did not build (for
example ``armeabi-v7a`` in a ``--target-platform android-arm64,android-x64``
build), the APK advertises that ABI but crashes at start because
``libflutter.so``/``libapp.so`` are missing there.

For every advertised ABI this checks:

* ``libflutter.so`` (engine) is present;
* AOT builds (release/profile, no ``kernel_blob.bin``): ``libapp.so`` is present;
  JIT/debug builds: ``kernel_blob.bin`` and the VM/isolate snapshots are present;
* every Dart native asset recorded in ``assets/flutter_assets/NativeAssetsManifest.json``
  for that target is packaged, and the set of native-asset targets equals the
  set of advertised ABIs;
* every ``.so`` is an ELF shared object for the directory's architecture;
* no ABI outside Flutter's supported set (armeabi-v7a, arm64-v8a, x86_64).

Optional ``--target-platform`` (Flutter names) or ``--abis`` require an exact
ABI set, and ``--mode`` requires debug (JIT) or release/profile (AOT).
``--require-lib NAME`` (repeatable) requires that library in every advertised
ABI, e.g. ``libatermius_rdp.so`` for the embedded RDP engine.

Read-only, standard library only; never installs, signs or extracts to disk.
Exit status: 0 complete, 1 incomplete/mismatched, 2 unreadable input.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

# Flutter SDK FlutterPluginConstants.PLATFORM_ARCH_MAP.
PLATFORM_ABI = {
    "android-arm": "armeabi-v7a",
    "android-arm64": "arm64-v8a",
    "android-x64": "x86_64",
}
# NativeAssetsManifest.json target keys -> ABI.
NATIVE_TARGET_ABI = {
    "android_arm": "armeabi-v7a",
    "android_arm64": "arm64-v8a",
    "android_x64": "x86_64",
}
# ABI -> (ELF class, e_machine): 1 = 32-bit, 2 = 64-bit; EM_ARM, EM_AARCH64, EM_X86_64.
ABI_ELF = {
    "armeabi-v7a": (1, 40),
    "arm64-v8a": (2, 183),
    "x86_64": (2, 62),
}
ASSETS = "assets/flutter_assets/"
JIT_FILES = ("kernel_blob.bin", "vm_snapshot_data", "isolate_snapshot_data")


def _elf_problem(data: bytes, abi: str) -> str | None:
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return "not an ELF file"
    elf_class, endian = data[4], data[5]
    if endian != 1:
        return "not little-endian"
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_type != 3:
        return f"ELF type {e_type} is not a shared object"
    expected = ABI_ELF.get(abi)
    if expected and (elf_class, e_machine) != expected:
        return f"ELF class/machine {elf_class}/{e_machine} does not match {abi}"
    return None


def check_apk(path: Path, abis: set[str] | None = None, mode: str | None = None,
              require: tuple[str, ...] = ()) -> dict:
    errors: list[str] = []
    libraries: dict[str, list[str]] = {}
    with zipfile.ZipFile(path) as apk:
        names = set(apk.namelist())
        for info in apk.infolist():
            parts = info.filename.split("/")
            if len(parts) != 3 or parts[0] != "lib" or not parts[2]:
                continue
            abi, library = parts[1], parts[2]
            libraries.setdefault(abi, []).append(library)
            if library.endswith(".so"):
                with apk.open(info) as handle:
                    problem = _elf_problem(handle.read(20), abi)
                if problem:
                    errors.append(f"lib/{abi}/{library}: {problem}")
        manifest_targets: dict[str, list[str]] = {}
        if ASSETS + "NativeAssetsManifest.json" in names:
            try:
                manifest = json.loads(apk.read(ASSETS + "NativeAssetsManifest.json"))
                for target, assets in (manifest.get("native-assets") or {}).items():
                    files = []
                    for asset in assets.values():
                        if isinstance(asset, list) and len(asset) == 2 and asset[0] == "absolute":
                            files.append(asset[1])
                    manifest_targets[target] = files
            except (ValueError, AttributeError) as error:
                errors.append(f"NativeAssetsManifest.json unreadable: {error}")
    jit = ASSETS + "kernel_blob.bin" in names
    build = "jit" if jit else "aot"
    advertised = {abi for abi, libs in libraries.items() if any(l.endswith(".so") for l in libs)}

    for abi in sorted(advertised - set(ABI_ELF)):
        errors.append(f"{abi}: ABI is not supported by Flutter")
    for abi in sorted(advertised):
        present = set(libraries[abi])
        missing = ["libflutter.so"] if "libflutter.so" not in present else []
        if not jit and "libapp.so" not in present:
            missing.append("libapp.so")
        if missing:
            kind = "plugin-only ABI" if not {"libflutter.so", "libapp.so"} & present else "incomplete ABI"
            errors.append(f"{abi}: {kind}, missing {', '.join(missing)}")
        absent = [name for name in require if name not in present]
        if absent:
            errors.append(f"{abi}: required library missing: {', '.join(absent)}")
    if jit:
        for name in JIT_FILES:
            if ASSETS + name not in names:
                errors.append(f"debug/JIT build missing {ASSETS}{name}")
    if not advertised:
        errors.append("no native libraries packaged")

    native_abis: set[str] = set()
    for target, files in manifest_targets.items():
        abi = NATIVE_TARGET_ABI.get(target)
        if abi is None:
            errors.append(f"NativeAssetsManifest target {target} is not an Android Flutter target")
            continue
        native_abis.add(abi)
        for name in files:
            if name not in libraries.get(abi, []):
                errors.append(f"{abi}: native asset {name} from {target} is not packaged")
    if manifest_targets:
        for abi in sorted(advertised - native_abis):
            errors.append(f"{abi}: packaged but Dart native assets were not built for it")
        for abi in sorted(native_abis - advertised):
            errors.append(f"{abi}: native assets built but ABI not packaged")

    if abis is not None and advertised != abis:
        errors.append(
            f"ABIs {sorted(advertised)} do not match expected {sorted(abis)}")
    if mode == "debug" and not jit:
        errors.append("expected a debug (JIT) build but kernel_blob.bin is absent")
    if mode in ("release", "profile") and jit:
        errors.append(f"expected a {mode} (AOT) build but kernel_blob.bin is present")

    return {
        "apk": str(path),
        "ok": not errors,
        "build": build,
        "abis": {abi: sorted(libraries[abi]) for abi in sorted(libraries)},
        "native_asset_targets": sorted(manifest_targets),
        "errors": errors,
    }


def _parse_expected(args: argparse.Namespace) -> set[str] | None:
    if args.target_platform:
        result = set()
        for platform in args.target_platform.split(","):
            if platform not in PLATFORM_ABI:
                raise SystemExit(f"Invalid platform: {platform}")
            result.add(PLATFORM_ABI[platform])
        return result
    if args.abis:
        result = set(args.abis.split(","))
        unknown = result - set(ABI_ELF)
        if unknown:
            raise SystemExit(f"Unsupported ABI: {', '.join(sorted(unknown))}")
        return result
    return None


def _elf(abi: str) -> bytes:
    elf_class, machine = ABI_ELF[abi]
    return b"\x7fELF" + bytes([elf_class, 1, 1]) + bytes(9) + struct.pack("<HH", 3, machine) + bytes(44)


def _fake_apk(path: Path, libs: dict[str, list[str]], jit: bool = False,
              native: dict[str, list[str]] | None = None, raw: dict[str, bytes] | None = None) -> Path:
    with zipfile.ZipFile(path, "w") as apk:
        for abi, names in libs.items():
            for name in names:
                apk.writestr(f"lib/{abi}/{name}", _elf(abi) if abi in ABI_ELF else b"\x7fELF")
        if jit:
            for name in JIT_FILES:
                apk.writestr(ASSETS + name, b"x")
        if native is not None:
            apk.writestr(ASSETS + "NativeAssetsManifest.json", json.dumps({
                "format-version": [1, 0, 0],
                "native-assets": {t: {f"package:x/{n}": ["absolute", n] for n in ns}
                                  for t, ns in native.items()}}))
        for name, data in (raw or {}).items():
            apk.writestr(name, data)
    return path


def self_test() -> int:
    engine = ["libflutter.so", "libapp.so"]
    plugin = ["libdartjni.so", "libflutter_pty.so"]
    assets = ["libsodium.so", "libsqlite3.so"]
    full = engine + plugin + assets
    cases = [
        ("release arm64+x64 complete", True, {"abis": {"arm64-v8a", "x86_64"}, "mode": "release"},
         dict(libs={"arm64-v8a": full, "x86_64": full},
              native={"android_arm64": assets, "android_x64": assets})),
        ("plugin-only armeabi-v7a (the reported defect)", False, {},
         dict(libs={"arm64-v8a": full, "x86_64": full, "armeabi-v7a": plugin},
              native={"android_arm64": assets, "android_x64": assets})),
        ("same defect with expected ABIs", False, {"abis": {"arm64-v8a", "x86_64"}},
         dict(libs={"arm64-v8a": full, "x86_64": full, "armeabi-v7a": plugin},
              native={"android_arm64": assets, "android_x64": assets})),
        ("debug x64 only", True, {"abis": {"x86_64"}, "mode": "debug"},
         dict(libs={"x86_64": ["libflutter.so"] + plugin + assets}, jit=True,
              native={"android_x64": assets})),
        ("debug with plugin-only arm ABIs", False, {"mode": "debug"},
         dict(libs={"x86_64": ["libflutter.so"] + plugin + assets,
                    "arm64-v8a": plugin, "armeabi-v7a": plugin}, jit=True,
              native={"android_x64": assets})),
        ("release missing libapp", False, {},
         dict(libs={"arm64-v8a": ["libflutter.so"] + plugin}, native={})),
        ("missing native asset", False, {},
         dict(libs={"arm64-v8a": engine + ["libsodium.so"]},
              native={"android_arm64": assets})),
        ("native asset target not packaged", False, {},
         dict(libs={"arm64-v8a": engine + assets},
              native={"android_arm64": assets, "android_x64": assets})),
        ("unsupported x86", False, {},
         dict(libs={"arm64-v8a": engine, "x86": engine})),
        ("wrong ELF machine", False, {},
         dict(libs={"arm64-v8a": engine},
              raw={"lib/arm64-v8a/libextra.so": _elf("x86_64")})),
        ("all three ABIs, default build", True, {"abis": {"armeabi-v7a", "arm64-v8a", "x86_64"}},
         dict(libs={"armeabi-v7a": full, "arm64-v8a": full, "x86_64": full},
              native={"android_arm": assets, "android_arm64": assets, "android_x64": assets})),
        ("expected mode mismatch", False, {"mode": "release"},
         dict(libs={"x86_64": ["libflutter.so"]}, jit=True)),
        ("RDP engine in both ABIs", True,
         {"abis": {"arm64-v8a", "x86_64"}, "require": ("libatermius_rdp.so",)},
         dict(libs={"arm64-v8a": full + ["libatermius_rdp.so"],
                    "x86_64": full + ["libatermius_rdp.so"]},
              native={"android_arm64": assets, "android_x64": assets})),
        ("RDP engine missing in x86_64", False, {"require": ("libatermius_rdp.so",)},
         dict(libs={"arm64-v8a": full + ["libatermius_rdp.so"], "x86_64": full},
              native={"android_arm64": assets, "android_x64": assets})),
        ("RDP engine wrong ELF machine", False, {"require": ("libatermius_rdp.so",)},
         dict(libs={"arm64-v8a": full},
              native={"android_arm64": assets},
              raw={"lib/arm64-v8a/libatermius_rdp.so": _elf("x86_64")})),
    ]
    failed = 0
    with tempfile.TemporaryDirectory() as root:
        for index, (name, expected, options, spec) in enumerate(cases):
            report = check_apk(_fake_apk(Path(root, f"{index}.apk"), **spec), **options)
            status = "ok" if report["ok"] == expected else "FAIL"
            failed += status == "FAIL"
            print(f"{status}: {name} -> ok={report['ok']} {report['errors']}")
    print(f"{len(cases) - failed}/{len(cases)} self-test cases passed")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apk", type=Path, nargs="*")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--target-platform", help="Flutter platforms, e.g. android-arm64,android-x64")
    group.add_argument("--abis", help="exact ABI set, e.g. arm64-v8a,x86_64")
    parser.add_argument("--mode", choices=("debug", "profile", "release"))
    parser.add_argument("--require-lib", action="append", default=[], metavar="NAME",
                        help="library required in every advertised ABI (repeatable)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.apk:
        parser.error("an APK path is required")
    expected = _parse_expected(args)
    status = 0
    for path in args.apk:
        try:
            report = check_apk(path, expected, args.mode, tuple(args.require_lib))
        except (OSError, zipfile.BadZipFile) as error:
            print(json.dumps({"apk": str(path), "ok": False, "errors": [str(error)]}))
            status = max(status, 2)
            continue
        print(json.dumps(report, indent=2))
        if not report["ok"]:
            status = max(status, 1)
    return status


if __name__ == "__main__":
    sys.exit(main())
