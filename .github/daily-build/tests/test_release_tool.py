#!/usr/bin/env python3
"""Offline tests for release_tool.py and lint_workflows.py (stdlib + PyYAML).

  python3 -I .github/daily-build/tests/test_release_tool.py -v
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "release_tool.py"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rt = load("release_tool", TOOL)
lint = load("lint_workflows", HERE / "lint_workflows.py")

APKSIGNER_OK = """Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
Verified using v3.1 scheme (APK Signature Scheme v3.1): false
Verified using v4 scheme (APK Signature Scheme v4): false
Verified for SourceStamp: false
Number of signers: 1
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
Signer #1 certificate SHA-256 digest: AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12
Signer #1 certificate SHA-1 digest: 0000000000000000000000000000000000000000
"""

ENV = {"ATERMIUS_SOURCE_SHA": "a" * 40, "ATERMIUS_QUOTA_DATE": "2026-11-10",
       "ATERMIUS_RELEASE_TAG": "daily-20261110.1-aaaaaaaaaaaa", "GITHUB_REPOSITORY": "aterm-project/test",
       "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1"}


class ReleaseToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-tool-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *args, check=True):
        proc = subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True,
                              env={**os.environ, **ENV})
        if check and proc.returncode:
            raise AssertionError(proc.stderr)
        return proc

    def make_apk(self, abis=("arm64-v8a", "x86_64"), engine=b"engine", licenses=True, v1=False) -> Path:
        apk = self.tmp / "app.apk"
        with zipfile.ZipFile(apk, "w") as z:
            for abi in abis:
                z.writestr(f"lib/{abi}/libflutter.so", b"f")
                z.writestr(f"lib/{abi}/libatermius_rdp.so", engine + abi.encode())
            if licenses:
                z.writestr("assets/licenses/atermius_rdp/FreeRDP-LICENSE", b"apache")
                z.writestr("assets/licenses/atermius_rdp/OpenSSL-LICENSE.txt", b"apache")
            if v1:
                z.writestr("META-INF/CERT.RSA", b"sig")
        return apk

    def make_engine_out(self, engine=b"engine") -> Path:
        out = self.tmp / "engine"
        for abi in ("arm64-v8a", "x86_64"):
            (out / "jniLibs" / abi).mkdir(parents=True, exist_ok=True)
            (out / "jniLibs" / abi / "libatermius_rdp.so").write_bytes(engine + abi.encode())
        return out

    def test_inspect_apk_accepts_matching_engine(self):
        report = rt.inspect_apk(self.make_apk(), ["arm64-v8a", "x86_64"], self.make_engine_out(),
                                "libatermius_rdp.so", "licenses/atermius_rdp")
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["v1_signature_entries"], [])

    def test_inspect_apk_rejects_stale_engine_extra_abi_missing_licenses(self):
        engine_out = self.make_engine_out(b"new-engine")
        report = rt.inspect_apk(self.make_apk(abis=("arm64-v8a", "x86_64", "armeabi-v7a"), licenses=False, v1=True),
                                ["arm64-v8a", "x86_64"], engine_out, "libatermius_rdp.so", "licenses/atermius_rdp")
        text = "\n".join(report["errors"])
        self.assertIn("!= expected", text)
        self.assertIn("not the library built by this run", text)
        self.assertIn("FreeRDP-LICENSE missing", text)
        self.assertEqual(report["v1_signature_entries"], ["META-INF/CERT.RSA"])

    def test_parse_apksigner(self):
        info = rt.parse_apksigner(APKSIGNER_OK)
        self.assertTrue(info["verified"])
        self.assertEqual(info["signers"], [{"index": 1, "sha256": "ab12" * 16}])
        self.assertEqual(info["number_of_signers"], 1)
        self.assertEqual((info["schemes"]["v1"], info["schemes"]["v2"], info["schemes"]["v3"]), (False, True, True))
        self.assertFalse(rt.parse_apksigner("DOES NOT VERIFY\nERROR: x\n")["verified"])

    def test_archives_are_deterministic_and_keep_modes(self):
        src = self.tmp / "bundle"
        (src / "lib").mkdir(parents=True)
        (src / "app").write_text("#!/bin/sh\n")
        (src / "app").chmod(0o755)
        (src / "lib" / "a.so").write_bytes(b"so")
        (src / "data.txt").write_text("d")
        first = rt.archive_dir(src, self.tmp / "one.tar.gz", "atermius")
        os.utime(src / "data.txt", (1, 1))
        second = rt.archive_dir(src, self.tmp / "two.tar.gz", "atermius")
        self.assertEqual(first["sha256"], second["sha256"])
        with tarfile.open(self.tmp / "one.tar.gz") as tar:
            members = {m.name: m for m in tar.getmembers()}
        self.assertEqual(members["atermius/app"].mode, 0o755)
        self.assertEqual(members["atermius/data.txt"].mode, 0o644)
        self.assertEqual({m.uid for m in members.values()}, {0})
        z1 = rt.archive_dir(src, self.tmp / "one.zip", "atermius")
        z2 = rt.archive_dir(src, self.tmp / "two.zip", "atermius")
        self.assertEqual(z1["sha256"], z2["sha256"])
        (src / "link").symlink_to("data.txt")
        with self.assertRaises(rt.ToolError):
            rt.archive_dir(src, self.tmp / "three.zip", "atermius")

    def release_dir(self) -> Path:
        out = self.tmp / "release"
        out.mkdir()
        (out / "atermius-test-0.1.0.apk").write_bytes(b"apk")
        self.cli("evidence", "--platform", "android", "--out-dir", str(out), "--artifact", "atermius-test-0.1.0.apk",
                 "--meta", "version_name=0.1.0", "--note", "signed")
        return out

    def assemble(self, out: Path, **overrides):
        args = {"dir": str(out), "platforms": "android", "source-sha": "a" * 40, "quota-date": "2026-11-10",
                "release-tag": ENV["ATERMIUS_RELEASE_TAG"], "run-id": "42", "run-attempt": "1",
                "repository": "aterm-project/test", "run-url": "https://example.invalid/run",
                "sums-out": str(self.tmp / "SHA256SUMS"), "notes-out": str(self.tmp / "notes.md"),
                "artifacts-out": str(self.tmp / "artifacts.json")}
        args.update(overrides)
        return self.cli("assemble", *[x for k, v in args.items() for x in (f"--{k}", v)], check=False)

    def test_assemble_happy_path(self):
        out = self.release_dir()
        proc = self.assemble(out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        sums = (self.tmp / "SHA256SUMS").read_text()
        self.assertIn(hashlib.sha256(b"apk").hexdigest() + "  atermius-test-0.1.0.apk", sums)
        self.assertIn("evidence-android.json", sums)
        artifacts = json.loads((self.tmp / "artifacts.json").read_text())
        self.assertEqual({a["name"] for a in artifacts}, {"atermius-test-0.1.0.apk", "evidence-android.json"})
        self.assertIn("signed", (self.tmp / "notes.md").read_text())

    def test_assemble_rejects_tampering_and_foreign_evidence(self):
        out = self.release_dir()
        (out / "atermius-test-0.1.0.apk").write_bytes(b"tampered")
        self.assertIn("does not match", self.assemble(out).stderr)
        out2 = self.tmp / "r2"
        shutil.copytree(out, out2)
        (out2 / "atermius-test-0.1.0.apk").write_bytes(b"apk")
        self.assertIn("does not belong", self.assemble(out2, **{"source-sha": "b" * 40}).stderr)
        self.assertIn("does not belong", self.assemble(out2, **{"run-attempt": "2"}).stderr)
        self.assertIn("expected exactly", self.assemble(out2, platforms="android,web").stderr)
        (out2 / "stray.bin").write_bytes(b"x")
        self.assertIn("unexpected files", self.assemble(out2).stderr)


WORKFLOW_OK = """
name: Daily build
on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch: {}
permissions: {}
concurrency:
  group: daily
  cancel-in-progress: false
jobs:
  gate:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      contents: write
    outputs:
      build: ${{ steps.gate.outputs.build }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - id: gate
        run: echo build=true >> "$GITHUB_OUTPUT"
  build:
    needs: gate
    if: needs.gate.outputs.build == 'true' && needs.gate.outputs.claim_run_attempt == github.run_attempt
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      SHA: ${{ needs.gate.outputs.source_sha }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false
      - run: echo "$SHA"
"""


class LintTests(unittest.TestCase):
    def check(self, text: str) -> list[str]:
        directory = Path(tempfile.mkdtemp(prefix="lint-test-"))
        try:
            (directory / "daily-build.yml").write_text(text)
            return lint.lint_file(directory / "daily-build.yml")
        finally:
            shutil.rmtree(directory)

    def test_good_workflow_passes(self):
        self.assertEqual(self.check(WORKFLOW_OK), [])

    def test_violations_are_reported(self):
        cases = {
            'run: echo "${{ github.event.head_commit.message }}"': ('run: echo "$SHA"', "expression inside run"),
            "actions/checkout@v4\n        with:": (
                "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n        with:", "not pinned"),
            "SHA: ${{ runner.temp }}": ("SHA: ${{ needs.gate.outputs.source_sha }}", "unavailable at job level"),
            "contents: write\n    env:": ("contents: read\n    env:", "write permission"),
            "if: needs.gate.outputs.build == 'true'\n": (
                "if: needs.gate.outputs.build == 'true' && needs.gate.outputs.claim_run_attempt == github.run_attempt\n",
                "guarded by the gate"),
            "persist-credentials: true": ("persist-credentials: false", "persist-credentials: false"),
            "  pull_request_target: {}\n  workflow_dispatch: {}": ("  workflow_dispatch: {}", "pull_request_target"),
            "cancel-in-progress: true": ("cancel-in-progress: false", "non-cancelling"),
        }
        for bad, (good, message) in cases.items():
            text = WORKFLOW_OK.replace(good, bad, 1)
            self.assertNotEqual(text, WORKFLOW_OK, bad)
            self.assertTrue(any(message in e for e in self.check(text)), (bad, self.check(text)))

    def test_matrix_parallelism_and_dispatch_inputs(self):
        text = WORKFLOW_OK.replace("    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    permissions:\n      contents: read",
                                   "    strategy:\n      max-parallel: 3\n      matrix:\n        os: [a, b, c]\n"
                                   "    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    permissions:\n      contents: read")
        self.assertTrue(any("max-parallel" in e for e in self.check(text)))
        text = WORKFLOW_OK.replace("workflow_dispatch: {}", "workflow_dispatch:\n    inputs:\n      ref: {type: string}")
        self.assertTrue(any("inputs" in e for e in self.check(text)))


if __name__ == "__main__":
    unittest.main()
