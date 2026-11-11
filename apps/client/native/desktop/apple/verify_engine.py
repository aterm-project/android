#!/usr/bin/env python3
"""Verify Mach-O exports & dynamic library dependencies for Apple RDP engines."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ALLOWED_DYLIB_PREFIXES = (
    "@rpath/",
    "/System/Library/Frameworks/",
    "/usr/lib/",
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_macho(binary: Path) -> dict:
    if not binary.is_file():
        raise SystemExit(f"verify_engine: missing binary {binary}")
    archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    otool = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()
    deps = []
    for line in otool[1:]:
        stripped = line.strip()
        if not stripped or stripped.endswith(":"):
            continue
        lib = stripped.split(" (", 1)[0].strip()
        if not lib.startswith(ALLOWED_DYLIB_PREFIXES):
            raise SystemExit(f"verify_engine: forbidden non-system dependency in {binary}: {lib}")
        deps.append(lib)

    nm_out = subprocess.check_output(["nm", "-gU", str(binary)], text=True).splitlines()
    exports = []
    for line in nm_out:
        parts = line.split()
        if not parts:
            continue
        sym = parts[-1]
        if not sym.startswith("_aterm_rdp_"):
            raise SystemExit(f"verify_engine: unexpected exported symbol in {binary}: {sym}")
        exports.append(sym)
    for required in ("_aterm_rdp_create_ex", "_aterm_rdp_features", "_aterm_rdp_set_home", "_aterm_rdp_free"):
        if required not in exports:
            raise SystemExit(f"verify_engine: missing required symbol {required} in {binary}")
    return {
        "path": binary.name,
        "sha256": sha256_file(binary),
        "archs": archs,
        "dependencies": sorted(set(deps)),
        "exported_symbol_count": len(set(exports)),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=["macos", "ios"], required=True)
    ap.add_argument("--out", required=False, default=None)
    ap.add_argument("--binary", action="append", required=False, default=None)
    ap.add_argument("--source", action="append", default=[])
    args = ap.parse_args()

    native_desktop_dir = Path(__file__).resolve().parent.parent
    default_bundle_dir = native_desktop_dir / "build" / args.platform / "bundle"
    out_dir = Path(args.out) if args.out else default_bundle_dir

    if args.binary:
        binaries = [Path(b) for b in args.binary]
    elif args.platform == "macos":
        binaries = [out_dir / "libatermius_rdp.dylib"]
    else:
        xcf = out_dir / "atermius_rdp.xcframework"
        binaries = [
            xcf / "ios-arm64" / "atermius_rdp.framework" / "atermius_rdp",
            xcf / "ios-arm64-simulator" / "atermius_rdp.framework" / "atermius_rdp",
        ]

    records = [verify_macho(b) for b in binaries]
    manifest_path = out_dir / "engine-manifest.json"
    sources = dict(item.split("=", 1) for item in args.source)
    if not sources and manifest_path.is_file():
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(existing.get("sources"), dict):
                sources = existing["sources"]
        except Exception:
            pass

    if args.out or not manifest_path.is_file():
        manifest = {
            "platform": args.platform,
            "sources": sources,
            "binaries": records,
        }
        out_dir.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"Verified {len(records)} Apple RDP engine slice(s) ({args.platform}) -> OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
