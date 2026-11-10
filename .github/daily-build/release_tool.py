#!/usr/bin/env python3
"""Packaging evidence and release assembly for the daily build (stdlib only).

  inspect-apk     check an APK: ABIs, embedded RDP engine identical to the
                  engine build output, engine licenses, leftover v1 signatures
  apksigner-certs parse `apksigner verify --print-certs -v` output
  archive         deterministic .tar.gz / .zip of a directory
  evidence        write evidence-<platform>.json (artifact digests + metadata)
  assemble        verify all evidence for one claim, write SHA256SUMS,
                  release notes and the artifact list stored in the baseline
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import stat
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

SCHEMA = "atermius-daily-build-evidence/1"
FIXED_MTIME = 1762646400  # 2025-11-09T00:00:00Z, as build_engine.sh SOURCE_DATE_EPOCH
V1_SIGNATURE = re.compile(r"^META-INF/[^/]+\.(SF|RSA|DSA|EC)$", re.IGNORECASE)
ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,150}$")


class ToolError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ------------------------------------------------------------------- android


def inspect_apk(apk: Path, abis: list[str], engine_out: Path | None, require_lib: str,
                license_dir: str) -> dict:
    errors: list[str] = []
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        libs: dict[str, list[str]] = {}
        for name in names:
            parts = name.split("/")
            if len(parts) == 3 and parts[0] == "lib" and parts[2].endswith(".so"):
                libs.setdefault(parts[1], []).append(parts[2])
        if sorted(libs) != sorted(abis):
            errors.append(f"APK native ABIs {sorted(libs)} != expected {sorted(abis)}")
        engine = {}
        for abi in abis:
            entry = f"lib/{abi}/{require_lib}"
            if entry not in names:
                errors.append(f"{entry} missing")
                continue
            packaged = hashlib.sha256(archive.read(entry)).hexdigest()
            engine[abi] = {"apk_sha256": packaged}
            if engine_out is not None:
                built = engine_out / "jniLibs" / abi / require_lib
                if not built.is_file():
                    errors.append(f"engine output {built} missing")
                else:
                    engine[abi]["built_sha256"] = sha256_file(built)
                    if engine[abi]["built_sha256"] != packaged:
                        errors.append(f"{entry} is not the library built by this run")
        licenses = sorted(n for n in names if n.startswith(f"assets/{license_dir}/") and not n.endswith("/"))
        for required in ("FreeRDP-LICENSE", "OpenSSL-LICENSE.txt"):
            if f"assets/{license_dir}/{required}" not in names:
                errors.append(f"license assets/{license_dir}/{required} missing")
        v1 = sorted(n for n in names if V1_SIGNATURE.match(n))
    return {"apk": apk.name, "sha256": sha256_file(apk), "size": apk.stat().st_size, "abis": sorted(libs),
            "native_libraries": {k: sorted(v) for k, v in sorted(libs.items())}, "rdp_engine": engine,
            "licenses": licenses, "v1_signature_entries": v1, "errors": errors}


def parse_apksigner(text: str) -> dict:
    schemes = {}
    for match in re.finditer(r"^Verified using (v[0-9.]+) scheme \([^)]*\): (true|false)$",
                             text, re.MULTILINE):
        schemes[match.group(1)] = match.group(2) == "true"
    signers = re.findall(r"^Signer #(\d+) certificate SHA-256 digest: ([0-9a-fA-F]{64})$", text, re.MULTILINE)
    count = re.search(r"^Number of signers: (\d+)$", text, re.MULTILINE)
    return {"verified": text.lstrip().startswith("Verifies"), "schemes": schemes,
            "signers": [{"index": int(i), "sha256": d.lower()} for i, d in signers],
            "number_of_signers": int(count.group(1)) if count else None}


# ------------------------------------------------------------------ archives


def _walk(src: Path) -> list[Path]:
    items = []
    for root, dirs, files in os.walk(src, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            items.append(Path(root) / name)
    return sorted(set(items), key=lambda p: p.relative_to(src).as_posix())


def archive_dir(src: Path, out: Path, prefix: str) -> dict:
    if not src.is_dir():
        raise ToolError(f"{src} is not a directory")
    if not ASSET_NAME.match(out.name) or not re.match(r"^[A-Za-z0-9._-]+$", prefix):
        raise ToolError("invalid archive or prefix name")
    count = 0
    if out.name.endswith(".tar.gz"):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for path in _walk(src):
                info = tar.gettarinfo(str(path), arcname=f"{prefix}/{path.relative_to(src).as_posix()}")
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = FIXED_MTIME
                if info.isdir():
                    info.mode = 0o755
                elif info.isfile():
                    info.mode = 0o755 if info.mode & 0o111 else 0o644
                if info.isfile():
                    with path.open("rb") as handle:
                        tar.addfile(info, handle)
                else:
                    tar.addfile(info)
                count += 1
        with out.open("wb") as handle, gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0) as gz:
            gz.write(raw.getvalue())
    elif out.name.endswith(".zip"):
        with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in _walk(src):
                if path.is_symlink():
                    raise ToolError(f"symlink {path} cannot be stored in a zip (use ditto/tar)")
                if path.is_dir():
                    continue
                info = zipfile.ZipInfo(f"{prefix}/{path.relative_to(src).as_posix()}", (2025, 11, 9, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = ((0o755 if os.access(path, os.X_OK) else 0o644) | stat.S_IFREG) << 16
                with path.open("rb") as handle:
                    archive.writestr(info, handle.read())
                count += 1
    else:
        raise ToolError("archive name must end with .tar.gz or .zip")
    return {"archive": out.name, "entries": count, "sha256": sha256_file(out), "size": out.stat().st_size}


# ------------------------------------------------------------------ evidence


def parse_pairs(pairs: list[str]) -> dict[str, str]:
    result = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep or not re.match(r"^[a-z][a-z0-9_]{0,60}$", key):
            raise ToolError(f"invalid key=value {pair!r}")
        result[key] = value
    return result


def write_evidence(args: argparse.Namespace) -> dict:
    out = Path(args.out_dir)
    artifacts = []
    for name in args.artifact:
        path = out / name
        if not ASSET_NAME.match(name) or not path.is_file():
            raise ToolError(f"artifact {name!r} missing from {out} or badly named")
        artifacts.append({"name": name, "sha256": sha256_file(path), "size": path.stat().st_size})
    attachments = {}
    for key, value in parse_pairs(args.attach).items():
        attachments[key] = json.loads(Path(value).read_text(encoding="utf-8"))
    env = os.environ
    evidence = {
        "schema": SCHEMA, "platform": args.platform, "status": "built",
        "source_sha": env.get("ATERMIUS_SOURCE_SHA"), "quota_date": env.get("ATERMIUS_QUOTA_DATE"),
        "release_tag": env.get("ATERMIUS_RELEASE_TAG"), "repository": env.get("GITHUB_REPOSITORY"),
        "run_id": env.get("GITHUB_RUN_ID"), "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "job": env.get("GITHUB_JOB"), "runner": {"os": env.get("RUNNER_OS"), "arch": env.get("RUNNER_ARCH"),
                                                 "image": env.get("ImageOS"), "image_version": env.get("ImageVersion")},
        "artifacts": artifacts, "metadata": parse_pairs(args.meta), "notes": args.note, "attachments": attachments,
    }
    target = out / f"evidence-{args.platform}.json"
    target.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return evidence


def assemble(args: argparse.Namespace) -> dict:
    root = Path(args.dir)
    evidence_files = sorted(root.glob("evidence-*.json"))
    platforms = sorted(p.stem[len("evidence-"):] for p in evidence_files)
    expected = sorted(x for x in args.platforms.split(",") if x)
    if platforms != expected:
        raise ToolError(f"evidence for {platforms}, expected exactly {expected}")
    listed: dict[str, dict] = {}
    sections = []
    for path in evidence_files:
        data = json.loads(path.read_text(encoding="utf-8"))
        checks = {"schema": SCHEMA, "source_sha": args.source_sha, "quota_date": args.quota_date,
                  "release_tag": args.release_tag, "run_id": args.run_id, "run_attempt": args.run_attempt}
        wrong = [k for k, v in checks.items() if str(data.get(k)) != str(v)]
        if wrong or data.get("status") != "built":
            raise ToolError(f"{path.name} does not belong to this claim/run ({', '.join(wrong) or 'status'})")
        for item in data["artifacts"]:
            name = item["name"]
            file = root / name
            if name in listed or not ASSET_NAME.match(name) or not file.is_file():
                raise ToolError(f"artifact {name} duplicated, badly named or missing")
            if sha256_file(file) != item["sha256"] or file.stat().st_size != item["size"]:
                raise ToolError(f"artifact {name} does not match its evidence digest")
            listed[name] = {"name": name, "sha256": item["sha256"], "size": item["size"],
                            "platform": data["platform"]}
        sections.append(data)
    allowed = set(listed) | {p.name for p in evidence_files}
    extra = sorted(p.name for p in root.iterdir() if p.name not in allowed)
    if extra:
        raise ToolError(f"unexpected files in release directory: {extra}")
    for path in evidence_files:
        listed[path.name] = {"name": path.name, "sha256": sha256_file(path), "size": path.stat().st_size,
                             "platform": "evidence"}
    sums = "".join(f"{v['sha256']}  {k}\n" for k, v in sorted(listed.items()))
    Path(args.sums_out).write_text(sums, encoding="utf-8")
    Path(args.artifacts_out).write_text(json.dumps(sorted(listed.values(), key=lambda x: x["name"]), indent=2) + "\n",
                                        encoding="utf-8")
    lines = [
        f"Automated daily build of `{args.source_sha}` ({args.repository}), quota day {args.quota_date} UTC.",
        "", f"Workflow run: {args.run_url}", "",
        "Built only because product/packaging inputs changed since the previous published daily build. "
        "Every file below is listed in `SHA256SUMS`; `evidence-*.json` records the toolchain, runner image and "
        "checks for each platform.", "",
    ]
    for data in sections:
        lines.append(f"### {data['platform']}")
        for item in data["artifacts"]:
            lines.append(f"- `{item['name']}` — sha256 `{item['sha256']}`, {item['size']} bytes")
        for note in data.get("notes") or []:
            lines.append(f"- {note}")
        lines.append("")
    Path(args.notes_out).write_text("\n".join(lines), encoding="utf-8")
    return {"files": len(listed), "platforms": platforms}


# ---------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("inspect-apk")
    p.add_argument("--apk", required=True)
    p.add_argument("--abis", default="arm64-v8a,x86_64")
    p.add_argument("--engine-out", default="")
    p.add_argument("--require-lib", default="libatermius_rdp.so")
    p.add_argument("--license-dir", default="licenses/atermius_rdp")
    p.add_argument("--json-out", default="")

    p = sub.add_parser("apksigner-certs")
    p.add_argument("--text", required=True)

    p = sub.add_parser("archive")
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--prefix", required=True)

    p = sub.add_parser("evidence")
    p.add_argument("--platform", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--artifact", action="append", default=[])
    p.add_argument("--meta", action="append", default=[])
    p.add_argument("--note", action="append", default=[])
    p.add_argument("--attach", action="append", default=[], help="key=path-to-json")

    p = sub.add_parser("assemble")
    for name in ("dir", "platforms", "source-sha", "quota-date", "release-tag", "run-id", "run-attempt",
                 "repository", "run-url", "sums-out", "notes-out", "artifacts-out"):
        p.add_argument(f"--{name}", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "inspect-apk":
            report = inspect_apk(Path(args.apk), [a for a in args.abis.split(",") if a],
                                 Path(args.engine_out) if args.engine_out else None, args.require_lib,
                                 args.license_dir)
            text = json.dumps(report, indent=2, sort_keys=True)
            if args.json_out:
                Path(args.json_out).write_text(text + "\n", encoding="utf-8")
            print(text)
            return 1 if report["errors"] else 0
        if args.command == "apksigner-certs":
            print(json.dumps(parse_apksigner(Path(args.text).read_text(encoding="utf-8")), sort_keys=True))
            return 0
        if args.command == "archive":
            print(json.dumps(archive_dir(Path(args.src), Path(args.out), args.prefix), sort_keys=True))
            return 0
        if args.command == "evidence":
            print(json.dumps(write_evidence(args), indent=2, sort_keys=True))
            return 0
        print(json.dumps(assemble(args), sort_keys=True))
        return 0
    except (ToolError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"::error::release_tool {args.command}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
