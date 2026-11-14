#!/usr/bin/env python3
"""Offline tests for daily_gate.py (stdlib unittest; needs only git).

Each test builds a private bare "origin" repository (file:// URL, so pushes go
through real receive-pack with its ref locking and old-value checks) and runs
the gate CLI from fresh shallow clones, the way GitHub runners do. The origin
has the monorepo shape: two client platforms (android, desktop) with their own
runner directories, input rules and state namespaces.

  python3 -I .github/daily-build/tests/test_daily_gate.py -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "daily_gate.py"
ROOT_NS = "refs/atermius-ci/daily-build"
LEGACY_NS = ROOT_NS  # the pre-monorepo android namespace
NS = f"{ROOT_NS}/android"
DESKTOP_NS = f"{ROOT_NS}/desktop"

spec = importlib.util.spec_from_file_location("daily_gate", GATE)
gate_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate_module)

RULES = """\
# test rules (same shape as the real inputs/android.txt)
version 1
+ apps/client/**
- apps/client/test/**
- apps/client/integration/**
- apps/client/windows/**
- **/*.md
+ packages/**
- packages/*/test/**
+ .github/workflows/daily-android.yml
+ .github/daily-build/recipe/android_*
+ .github/daily-build/recipe/flutter_sdk.py
+ tools/install_flutter_linux.sh
"""
DESKTOP_RULES = """\
# test rules (same shape as the real inputs/desktop.txt)
version 1
+ apps/client/**
- apps/client/test/**
- apps/client/integration/**
- apps/client/android/**
- **/*.md
+ packages/**
- packages/*/test/**
+ .github/workflows/daily-desktop.yml
+ .github/daily-build/recipe/desktop_*
+ .github/daily-build/recipe/flutter_sdk.py
+ tools/install_flutter_linux.sh
"""

BASE_FILES = {
    "README.md": "readme\n",
    "docs/GUIDE.md": "guide\n",
    "apps/client/lib/main.dart": "void main() {}\n",
    "apps/client/pubspec.lock": "lock: 1\n",
    "apps/client/README.md": "client readme\n",
    "apps/client/test/widget_test.dart": "// test\n",
    "apps/client/integration/native/probe.c": "int x;\n",
    "packages/xterm/lib/xterm.dart": "// xterm\n",
    "packages/xterm/test/xterm_test.dart": "// t\n",
    "packages/xterm/LICENSE": "MIT\n",
    "apps/client/android/app/build.gradle.kts": "// android runner\n",
    "apps/client/windows/runner/main.cpp": "// windows runner\n",
    ".github/workflows/daily-android.yml": "name: daily android\n",
    ".github/workflows/daily-desktop.yml": "name: daily desktop\n",
    ".github/workflows/checks-android.yml": "name: checks\n",
    ".github/daily-build/inputs/android.txt": RULES,
    ".github/daily-build/inputs/desktop.txt": DESKTOP_RULES,
    ".github/daily-build/daily_gate.py": "# gate\n",
    ".github/daily-build/recipe/android_build.sh": "echo build\n",
    ".github/daily-build/recipe/desktop_linux.sh": "echo desktop\n",
    ".github/daily-build/recipe/flutter_sdk.py": "# sdk\n",
    "tools/install_flutter_linux.sh": "echo sdk\n",
}

DAY1 = "2026-11-10T00:07:13Z"
DAY1_LATE = "2026-11-10T23:59:59Z"
DAY2 = "2026-11-11T00:00:00Z"
DAY3 = "2026-11-12T00:12:00Z"


def run(cmd, cwd, check=True, env=None):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if check and proc.returncode:
        raise AssertionError(f"{cmd} failed: {proc.stderr}\n{proc.stdout}")
    return proc


class Env:
    """A private origin plus an author clone used to push product commits."""

    def __init__(self, root: Path):
        self.root = root
        self.origin = root / "origin.git"
        run(["git", "init", "--quiet", "--bare", "-b", "main", str(self.origin)], root)
        run(["git", "config", "uploadpack.allowReachableSHA1InWant", "true"], self.origin)
        self.url = self.origin.resolve().as_uri()
        self.author = root / "author"
        run(["git", "init", "--quiet", "-b", "main", str(self.author)], root)
        for key, value in (("user.name", "Dev"), ("user.email", "dev@example.invalid"), ("commit.gpgsign", "false")):
            run(["git", "config", key, value], self.author)
        run(["git", "remote", "add", "origin", self.url], self.author)
        self.commit(BASE_FILES, "initial")
        self.clones = 0

    def commit(self, files: dict[str, str | None], message: str, branch: str = "main") -> str:
        for path, content in files.items():
            target = self.author / path
            if content is None:
                target.unlink()
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
        run(["git", "add", "-A"], self.author)
        run(["git", "commit", "--quiet", "-m", message], self.author)
        run(["git", "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}"], self.author)
        return self.head()

    def head(self) -> str:
        return run(["git", "rev-parse", "HEAD"], self.author).stdout.strip()

    def runner_clone(self, sha: str | None = None) -> Path:
        """Fresh shallow checkout like actions/checkout (depth 1)."""
        self.clones += 1
        path = self.root / f"runner{self.clones}"
        run(["git", "clone", "--quiet", "--depth", "1", "--no-tags", self.url, str(path)], self.root)
        if sha:
            run(["git", "fetch", "--quiet", "--depth", "1", "origin", sha], path)
            run(["git", "checkout", "--quiet", "--detach", sha], path)
        return path

    def remote_refs(self, prefix: str = NS) -> dict[str, str]:
        out = run(["git", "ls-remote", self.url, prefix + "/*"], self.root).stdout
        return {line.split("\t")[1]: line.split("\t")[0] for line in out.splitlines()}

    def gate(self, now: str, *, run_id: str = "100", attempt: str = "1", event: str = "schedule",
             ref: str = "refs/heads/main", run_sha: str | None = None, extra: list[str] | None = None,
             env: dict | None = None, workspace: Path | None = None, check: bool = True,
             platform: str = "android") -> tuple[int, dict, dict]:
        run_sha = run_sha or self.head()
        workspace = workspace or self.runner_clone(run_sha)
        output = workspace / "gh_output.txt"
        output.write_text("")
        cmd = [sys.executable, "-I", str(GATE), "gate", "--repo", str(workspace), "--branch", "main",
               "--platform", platform,
               "--ref", ref, "--run-sha", run_sha, "--run-id", run_id, "--run-attempt", attempt,
               "--event", event, "--repository", "aterm-project/test", "--workflow", f"daily-{platform}.yml",
               "--now", now, "--github-output", str(output), "--summary", str(workspace / "summary.md")]
        proc = run(cmd + (extra or []), workspace, check=False, env={**os.environ, **(env or {})})
        if check and proc.returncode not in (0, 1, 3):
            raise AssertionError(proc.stderr)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        result = json.loads(proc.stdout) if proc.stdout.strip().startswith("{") else {"stderr": proc.stderr}
        return proc.returncode, outputs, result

    def advance(self, outputs: dict, *, run_id: str = "100", attempt: str = "1", now: str = DAY1,
                expect: str | None = None, check: bool = True, platform: str = "android") -> subprocess.CompletedProcess:
        workspace = self.runner_clone(outputs["source_sha"])
        artifacts = workspace / "artifacts.json"
        artifacts.write_text(json.dumps([{"name": "app.apk", "sha256": "ab" * 32, "size": 1}]))
        cmd = [sys.executable, "-I", str(GATE), "advance", "--repo", str(workspace), "--platform", platform,
               "--quota-date", outputs["quota_date"], "--slot", outputs["quota_slot"],
               "--claim-record", outputs["claim_record"], "--run-id", run_id, "--run-attempt", attempt,
               "--source-sha", outputs["source_sha"],
               "--expect-baseline", expect if expect is not None else (outputs["baseline_record"] or "none"),
               "--release-tag", outputs["release_tag"], "--artifacts", str(artifacts), "--now", now]
        return run(cmd, workspace, check=check)


def seed_legacy(env: Env, date: str, slot: int, version_code: int | None) -> None:
    """Records like the pre-monorepo android gate left them under refs/atermius-ci/daily-build."""
    workspace = env.runner_clone()
    sha = env.head()
    now = gate_module.resolve_now(f"{date}T00:05:00Z", None, 120)[0]
    info = gate_module.fingerprint(workspace, sha, ".github/daily-build/inputs/android.txt")
    quota = {"schema": gate_module.SCHEMA, "kind": "quota", "quota_date": date, "slot": slot, "source_sha": sha,
             "fingerprint": info["fingerprint"], "repository": "aterm-project/android", "run_id": "1",
             "run_attempt": "1"}
    record = gate_module.make_record(workspace, sha, [sha], quota, now)
    if gate_module.cas_push(workspace, "origin", f"{LEGACY_NS}/quota/{date}/{slot}", record, None) != "ok":
        raise AssertionError("legacy quota seed failed")
    if version_code:
        body = {"schema": gate_module.SCHEMA, "kind": "version-code", "version_code": version_code,
                "quota_date": date, "source_sha": sha, "fingerprint": info["fingerprint"]}
        record = gate_module.make_record(workspace, sha, [sha], body, now)
        ref = f"{LEGACY_NS}/version-code"
        if gate_module.cas_push(workspace, "origin", ref, record, env.remote_refs(ref).get(ref)) != "ok":
            raise AssertionError("legacy version-code seed failed")


class GateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="daily-gate-test-"))
        self.env = Env(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def build_and_publish(self, now: str, run_id: str) -> dict:
        code, out, _ = self.env.gate(now, run_id=run_id)
        self.assertEqual((code, out["build"]), (0, "true"), out)
        self.env.advance(out, run_id=run_id, now=now)
        return out

    # 1 first build
    def test_first_build_claims_and_reports_release_identity(self):
        code, out, result = self.env.gate(DAY1)
        self.assertEqual(code, 0)
        self.assertEqual(out["build"], "true")
        self.assertEqual(out["reason"], "claimed")
        self.assertEqual(out["quota_date"], "2026-11-10")
        self.assertEqual(out["baseline_record"], "")
        self.assertEqual(out["version_code"], "2026111001")
        self.assertEqual(out["release_tag"], f"android-daily-20261110.1-{self.env.head()[:12]}")
        refs = self.env.remote_refs()
        self.assertEqual(list(refs), [f"{NS}/quota/2026-11-10/1"])
        self.assertNotIn(f"{NS}/baseline", refs)  # the gate never moves the baseline
        record = run(["git", "cat-file", "commit", refs[f"{NS}/quota/2026-11-10/1"]], self.env.author,
                     check=False)
        self.assertEqual(record.returncode, 128)  # record objects only live on the remote

    # 2 same-day repeat triggers (schedule / dispatch / re-run all jobs)
    def test_second_trigger_same_utc_day_is_skipped(self):
        self.env.gate(DAY1)
        self.env.commit({"apps/client/lib/main.dart": "void main() { print(1); }\n"}, "feature")
        for event, run_id, attempt in (("workflow_dispatch", "101", "1"), ("schedule", "100", "2")):
            code, out, result = self.env.gate(DAY1_LATE, run_id=run_id, attempt=attempt, event=event)
            self.assertEqual((code, out["build"], out["reason"]), (0, "false", "quota-used"), result)
        self.assertEqual(len(self.env.remote_refs()), 1)

    # 3 failed build (claimed, never published) is retried at the next checkpoint
    def test_failed_attempt_counts_and_is_retried_next_day(self):
        code, first, _ = self.env.gate(DAY1)
        # build failed: no advance. Same day again -> quota used even without new commits.
        _, again, _ = self.env.gate(DAY1_LATE, run_id="101", event="workflow_dispatch")
        self.assertEqual(again["reason"], "quota-used")
        _, retry, _ = self.env.gate(DAY2, run_id="102")
        self.assertEqual((retry["build"], retry["reason"], retry["source_sha"]), ("true", "claimed", first["source_sha"]))
        self.assertEqual(retry["quota_date"], "2026-11-11")

    # 4 no change after a successful build
    def test_no_input_change_after_success_is_skipped_without_claim(self):
        self.build_and_publish(DAY1, "100")
        code, out, result = self.env.gate(DAY2, run_id="101")
        self.assertEqual((code, out["build"], out["reason"]), (0, "false", "no-input-changes"))
        self.assertNotIn(f"{NS}/quota/2026-11-11/1", self.env.remote_refs())

    # 5 docs-only, test-only, README-only and gate-script-only changes are not build inputs
    def test_docs_tests_readme_and_gate_changes_do_not_build(self):
        self.build_and_publish(DAY1, "100")
        changes = [
            {"README.md": "new readme\n"}, {"docs/GUIDE.md": "new\n"}, {"apps/client/README.md": "x\n"},
            {"apps/client/test/widget_test.dart": "// new test\n"}, {"packages/xterm/test/xterm_test.dart": "//\n"},
            {"apps/client/integration/native/probe.c": "int y;\n"}, {".github/daily-build/daily_gate.py": "# v2\n"},
            {".github/workflows/checks-android.yml": "name: checks2\n"}, {"docs/NEW.md": "added\n"},
            # another platform's runner, recipe, rules and daily workflow are not android inputs
            {"apps/client/windows/runner/main.cpp": "// v2\n"}, {".github/daily-build/recipe/desktop_linux.sh": "#\n"},
            {".github/daily-build/inputs/desktop.txt": DESKTOP_RULES + "+ protocol/**\n"},
            {".github/workflows/daily-desktop.yml": "name: daily desktop v2\n"},
        ]
        for number, change in enumerate(changes):
            self.env.commit(change, f"non-input {number}")
            code, out, result = self.env.gate(DAY2, run_id=str(200 + number))
            self.assertEqual(out["reason"], "no-input-changes", (change, result))
        self.assertNotIn(f"{NS}/quota/2026-11-11/1", self.env.remote_refs())

    def test_product_and_packaging_changes_build(self):
        cases = [
            {"apps/client/lib/main.dart": "void main() { run(); }\n"}, {"apps/client/pubspec.lock": "lock: 2\n"},
            {"packages/xterm/lib/xterm.dart": "// v2\n"}, {"packages/xterm/LICENSE": "MIT 2\n"},
            {".github/daily-build/recipe/android_build.sh": "echo build2\n"}, {"tools/install_flutter_linux.sh": "echo 2\n"},
            {"apps/client/lib/extra.dart": "// added\n"}, {"apps/client/lib/extra.dart": None},
        ]
        day = 11
        self.build_and_publish(f"2026-11-{day - 1}T00:05:00Z", "1")
        for number, change in enumerate(cases):
            self.env.commit(change, f"input {number}")
            out = self.build_and_publish(f"2026-11-{day + number}T00:05:00Z", str(10 + number))
            self.assertEqual(out["reason"], "claimed")

    def test_changed_inputs_listed_against_baseline(self):
        self.build_and_publish(DAY1, "100")
        self.env.commit({"apps/client/lib/main.dart": "void main() { a(); }\n", "README.md": "x\n"}, "mixed")
        _, out, result = self.env.gate(DAY2, run_id="101")
        self.assertEqual(result["changed_inputs"], ["apps/client/lib/main.dart"])
        self.assertTrue(result["inputs_changed"])

    # 6 UTC day boundary
    def test_utc_day_boundary(self):
        _, a, _ = self.env.gate("2026-11-10T23:59:59Z", run_id="1")
        _, b, _ = self.env.gate("2026-11-11T00:00:00Z", run_id="2")
        self.assertEqual((a["quota_date"], b["quota_date"]), ("2026-11-10", "2026-11-11"))
        self.assertEqual((a["build"], b["build"]), ("true", "true"))
        # A +08:00 local clock at 07:59 is still the previous UTC day.
        _, c, _ = self.env.gate("2026-11-12T07:59:00+08:00", run_id="3")
        self.assertEqual((c["quota_date"], c["reason"]), ("2026-11-11", "quota-used"))

    def test_runner_clock_decides_and_server_date_must_agree(self):
        _, out, _ = self.env.gate("2026-11-11T00:03:00Z", extra=["--server-date", "Wed, 11 Nov 2026 00:03:40 GMT"])
        self.assertEqual((out["quota_date"], out["build"]), ("2026-11-11", "true"))
        cases = (
            # stale/cached Date from before midnight while the runner is past it
            ("2026-11-12T00:00:30Z", "Wed, 11 Nov 2026 23:59:50 GMT", "disagree"),
            # runner clock still before midnight while GitHub is past it
            ("2026-11-12T23:59:50Z", "Fri, 13 Nov 2026 00:00:20 GMT", "disagree"),
            ("2026-11-12T01:00:00Z", "Thu, 12 Nov 2026 01:05:00 GMT", "differs"),
            ("2026-11-12T01:00:00Z", "not a date", "unparseable"),
        )
        for now, header, message in cases:
            code, out, result = self.env.gate(now, run_id=now, extra=["--server-date", header])
            self.assertEqual(code, 3, (now, header, result))
            self.assertIn(message, result["stderr"])
            self.assertEqual(out, {})  # nothing decided, nothing claimed
        self.assertEqual([r for r in self.env.remote_refs() if "/2026-11-12/" in r or "/2026-11-13/" in r], [])

    # 7 failure, then more pushes on the same day: wait for the next checkpoint and build the latest tip
    def test_failed_day_then_push_waits_and_next_day_builds_latest(self):
        _, first, _ = self.env.gate(DAY1)
        latest = self.env.commit({"apps/client/lib/main.dart": "void main() { fix(); }\n"}, "fix")
        _, same_day, _ = self.env.gate(DAY1_LATE, run_id="101", event="workflow_dispatch")
        self.assertEqual(same_day["reason"], "quota-used")
        # The 00:00 run of day 2 was triggered with an older commit; it still builds the tip.
        _, next_day, _ = self.env.gate(DAY2, run_id="102", run_sha=first["source_sha"])
        self.assertEqual((next_day["build"], next_day["source_sha"]), ("true", latest))

    # 8 concurrency: runners race for one slot. Two contenders per round (the
    # workspace's 2-worker limit), both released only after each saw the slot
    # free, so the atomic push is what decides; repeated on several days.
    def test_concurrent_claims_only_one_wins(self):
        count = 2
        for round_number, day in enumerate(("2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13")):
            self.env.commit({"apps/client/lib/main.dart": f"// round {round_number}\n"}, f"r{round_number}")
            sync = self.tmp / f"sync{round_number}"
            sync.mkdir()
            workspaces = [self.env.runner_clone(self.env.head()) for _ in range(count)]
            results: list = [None] * count

            def worker(index: int) -> None:
                results[index] = self.env.gate(f"{day}T00:03:00Z", run_id=f"5{round_number}{index}",
                                               workspace=workspaces[index],
                                               env={"ATERMIUS_GATE_TEST_SYNC": f"{sync}:{count}"})

            threads = [threading.Thread(target=worker, args=(i,)) for i in range(count)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(60)
            builds = [r for r in results if r and r[1].get("build") == "true"]
            self.assertEqual(len(builds), 1, results)
            losers = [r[1]["reason"] for r in results if r[1].get("build") == "false"]
            self.assertEqual(losers, ["quota-used-race"] * (count - 1))
            refs = {k: v for k, v in self.env.remote_refs().items() if f"/quota/{day}/" in k}
            self.assertEqual(list(refs), [f"{NS}/quota/{day}/1"])
            self.assertEqual(refs[f"{NS}/quota/{day}/1"], builds[0][1]["claim_record"])

    def test_cas_push_semantics(self):
        workspace = self.env.runner_clone()
        head = self.env.head()
        ref = f"{NS}/test"
        self.assertEqual(gate_module.cas_push(workspace, "origin", ref, head, None), "ok")
        self.assertEqual(gate_module.cas_push(workspace, "origin", ref, head, None), "ok")  # already ours
        other = self.env.commit({"README.md": "other\n"}, "other")
        run(["git", "fetch", "--quiet", "--depth", "1", "origin", other], workspace)
        self.assertEqual(gate_module.cas_push(workspace, "origin", ref, other, None), "conflict")
        self.assertEqual(gate_module.cas_push(workspace, "origin", ref, other, "0" * 40), "conflict")
        self.assertEqual(gate_module.cas_push(workspace, "origin", ref, other, head), "ok")
        self.assertEqual(self.env.remote_refs()[ref], other)

    # 9 re-runs: only the claiming attempt may build/publish
    def test_check_claim_rejects_rerun_attempt_and_other_runs(self):
        _, out, _ = self.env.gate(DAY1, run_id="300", attempt="1")
        workspace = self.env.runner_clone()
        base = [sys.executable, "-I", str(GATE), "check-claim", "--repo", str(workspace), "--platform", "android",
                "--quota-date", out["quota_date"], "--slot", out["quota_slot"], "--claim-record", out["claim_record"],
                "--source-sha", out["source_sha"]]
        ok = run(base + ["--run-id", "300", "--run-attempt", "1"], workspace, check=False)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        for run_id, attempt in (("300", "2"), ("301", "1")):
            bad = run(base + ["--run-id", run_id, "--run-attempt", attempt], workspace, check=False)
            self.assertEqual(bad.returncode, 1)
            self.assertIn("re-run never builds", bad.stderr)
        rerun = self.env.advance(out, run_id="300", attempt="2", check=False)
        self.assertEqual(rerun.returncode, 1)
        self.assertNotIn(f"{NS}/baseline", self.env.remote_refs())

    def test_rerun_on_a_later_day_is_a_new_daily_attempt_on_the_tip(self):
        _, first, _ = self.env.gate(DAY1, run_id="400", attempt="1")
        _, rerun, _ = self.env.gate(DAY2, run_id="400", attempt="2", run_sha=first["source_sha"])
        self.assertEqual((rerun["build"], rerun["claim_run_attempt"]), ("true", "2"))

    # 10 only a published build advances the baseline; CAS protects it
    def test_baseline_only_moves_on_advance_and_is_chained(self):
        first = self.build_and_publish(DAY1, "100")
        refs = self.env.remote_refs()
        b1 = refs[f"{NS}/baseline"]
        self.env.commit({"apps/client/lib/main.dart": "void main() { v2(); }\n"}, "v2")
        _, second, _ = self.env.gate(DAY2, run_id="101")
        self.assertEqual(second["baseline_record"], b1)
        self.assertEqual(self.env.remote_refs()[f"{NS}/baseline"], b1)  # unchanged while building
        self.env.advance(second, run_id="101", now=DAY2)
        b2 = self.env.remote_refs()[f"{NS}/baseline"]
        workspace = self.env.runner_clone()
        run(["git", "fetch", "--quiet", "origin", b2], workspace)
        parents = run(["git", "rev-list", "--parents", "-n", "1", b2], workspace).stdout.split()[1:]
        self.assertEqual(parents, [second["source_sha"], b1])
        diff = run(["git", "diff", "--name-only", second["source_sha"], b2], workspace).stdout
        self.assertEqual(diff, "")  # records never change files
        record = gate_module.read_record(workspace, b2, "baseline")
        self.assertEqual((record["release_tag"], record["previous_baseline"]), (second["release_tag"], b1))
        self.assertNotEqual(first["source_sha"], second["source_sha"])

    def test_publish_after_main_moved_on_pushes_from_shallow_clone(self):
        _, out, _ = self.env.gate(DAY1, run_id="7")
        self.env.commit({"apps/client/lib/main.dart": "// landed during the build\n"}, "later")
        proc = self.env.advance(out, run_id="7")  # source is no longer the branch tip
        self.assertIn('"advanced"', proc.stdout)
        workspace = self.env.runner_clone()
        baseline = self.env.remote_refs()[f"{NS}/baseline"]
        run(["git", "fetch", "--quiet", "--depth", "1", "origin", baseline], workspace)
        self.assertEqual(gate_module.read_record(workspace, baseline, "baseline")["source_sha"], out["source_sha"])
        _, nxt, result = self.env.gate(DAY2, run_id="8")
        self.assertEqual((nxt["build"], result["changed_inputs"]), ("true", ["apps/client/lib/main.dart"]))

    def test_advance_does_not_overwrite_a_newer_baseline(self):
        _, old, _ = self.env.gate(DAY1, run_id="1")
        self.env.commit({"apps/client/lib/main.dart": "void main() { n(); }\n"}, "n")
        newer = self.build_and_publish(DAY2, "2")
        newest = self.env.remote_refs()[f"{NS}/baseline"]
        proc = self.env.advance(old, run_id="1", now=DAY2)  # a late publish of day 1
        self.assertIn('"superseded"', proc.stdout)
        self.assertEqual(self.env.remote_refs()[f"{NS}/baseline"], newest)
        self.assertNotEqual(old["source_sha"], newer["source_sha"])

    def test_skip_never_advances_baseline(self):
        self.build_and_publish(DAY1, "1")
        before = self.env.remote_refs()
        for day in ("2026-11-11T00:01:00Z", "2026-11-12T00:01:00Z"):
            _, out, _ = self.env.gate(day, run_id=day)
            self.assertEqual(out["build"], "false")
        self.assertEqual(self.env.remote_refs(), before)

    # 11 trigger hygiene
    def test_non_default_branch_dispatch_is_skipped(self):
        sha = self.env.commit({"apps/client/lib/main.dart": "// feature\n"}, "f", branch="feature")
        code, out, _ = self.env.gate(DAY1, ref="refs/heads/feature", event="workflow_dispatch", run_sha=sha)
        self.assertEqual((code, out["reason"]), (0, "not-default-branch"))
        self.assertEqual(self.env.remote_refs(), {})

    def test_ci_definition_changed_since_trigger_is_skipped(self):
        old = self.env.head()
        self.env.commit({".github/workflows/daily-android.yml": "name: daily v2\n"}, "ci change")
        _, out, _ = self.env.gate(DAY1, run_sha=old)
        self.assertEqual(out["reason"], "ci-definition-changed")
        self.assertEqual(self.env.remote_refs(), {})

    def test_missing_release_prerequisite_refuses_before_claim(self):
        code, out, result = self.env.gate(DAY1, extra=["--require-env", "ATERMIUS_TEST_SIGNING_CERT"],
                                          env={"ATERMIUS_TEST_SIGNING_CERT": ""})
        self.assertEqual(code, 1)
        self.assertIn("ATERMIUS_TEST_SIGNING_CERT", result["stderr"])
        self.assertEqual(self.env.remote_refs(), {})
        code, out, _ = self.env.gate(DAY1, extra=["--require-env", "ATERMIUS_TEST_SIGNING_CERT"],
                                     env={"ATERMIUS_TEST_SIGNING_CERT": "ab" * 32})
        self.assertEqual(out["build"], "true")

    def test_corrupt_baseline_refuses(self):
        workspace = self.env.runner_clone()
        run(["git", "push", "--quiet", "origin", f"HEAD:{NS}/baseline"], workspace)  # plain commit, not a record
        self.env.commit({"apps/client/lib/main.dart": "// c\n"}, "c")
        code, _, result = self.env.gate(DAY1)
        self.assertEqual(code, 1)
        self.assertIn("baseline record", result["stderr"])

    # 12 adjustable policy
    def test_daily_quota_of_two(self):
        outs = [self.env.gate(DAY1, run_id=str(i), extra=["--daily-quota", "2"])[1] for i in range(3)]
        self.assertEqual([o["build"] for o in outs], ["true", "true", "false"])
        self.assertEqual([o.get("quota_slot") for o in outs[:2]], ["1", "2"])
        self.assertEqual(outs[1]["version_code"], "2026111002")

    def test_shared_quota_remote_across_repositories(self):
        shared = self.tmp / "shared.git"
        run(["git", "init", "--quiet", "--bare", "-b", "main", str(shared)], self.tmp)
        other_root = self.tmp / "other"
        other_root.mkdir()
        other = Env(other_root)
        # The shared state repository must contain the source objects records point at.
        for env in (self.env, other):
            run(["git", "push", "--quiet", shared.as_uri(), f"HEAD:refs/sources/{env.root.name}"], env.author)
        extra = ["--quota-remote", shared.as_uri()]
        _, a, _ = self.env.gate(DAY1, extra=extra)
        _, b, _ = other.gate(DAY1, extra=extra)
        self.assertEqual((a["build"], b["build"], b["reason"]), ("true", "false", "quota-used"))

    def test_fingerprint_is_order_and_comment_independent(self):
        rules_a = gate_module.Rules(RULES)
        rules_b = gate_module.Rules("# other comment\n" + RULES + "\n# trailing\n")
        self.assertEqual(rules_a.canonical(), rules_b.canonical())
        self.assertTrue(rules_a.match("apps/client/lib/a/b.dart"))
        self.assertFalse(rules_a.match("apps/client/test/a_test.dart"))
        self.assertFalse(rules_a.match("apps/client/lib/notes.md"))
        self.assertFalse(rules_a.match("docs/x.dart"))
        self.assertTrue(rules_a.match("packages/sqlite3/hook/build.dart"))
        self.assertFalse(rules_a.match("packages/sqlite3/test/a.dart"))
        for bad in ("* x", "+ /abs", "+ a/../b", "+"):
            with self.assertRaises(gate_module.GateError):
                gate_module.Rules(bad)

    def test_rules_change_rebuilds_once(self):
        self.build_and_publish(DAY1, "1")
        self.env.commit({".github/daily-build/inputs/android.txt": RULES + "+ protocol/**\n"}, "rules")
        _, out, _ = self.env.gate(DAY2, run_id="2")
        # inputs.txt sits under .github/, so this run (triggered at the old sha) would skip;
        # it was triggered at the new tip here, so it builds once.
        self.assertEqual(out["reason"], "claimed")

    def test_output_values_are_single_line(self):
        _, out, _ = self.env.gate(DAY1)
        for key, value in out.items():
            self.assertNotIn("\n", value, key)

    # 13 monorepo: one quota, baseline and tag namespace per platform
    def test_platforms_have_separate_quota_baseline_and_tags(self):
        _, android, _ = self.env.gate(DAY1, run_id="1")
        _, desktop, _ = self.env.gate(DAY1, run_id="2", platform="desktop")
        self.assertEqual((android["build"], desktop["build"]), ("true", "true"))  # android's claim is not desktop's
        tip = self.env.head()[:12]
        self.assertEqual((android["release_tag"], desktop["release_tag"]),
                         (f"android-daily-20261110.1-{tip}", f"desktop-daily-20261110.1-{tip}"))
        self.assertEqual(sorted(self.env.remote_refs(ROOT_NS)),
                         sorted([f"{DESKTOP_NS}/quota/2026-11-10/1", f"{NS}/quota/2026-11-10/1"]))
        self.env.advance(android, run_id="1")
        self.env.advance(desktop, run_id="2", platform="desktop")
        self.assertIn(f"{NS}/baseline", self.env.remote_refs())
        self.assertIn(f"{DESKTOP_NS}/baseline", self.env.remote_refs(DESKTOP_NS))
        # a runner change rebuilds only its platform; a shared change rebuilds both
        self.env.commit({"apps/client/android/app/build.gradle.kts": "// v2\n"}, "android runner")
        _, a2, _ = self.env.gate(DAY2, run_id="3")
        _, d2, _ = self.env.gate(DAY2, run_id="4", platform="desktop")
        self.assertEqual((a2["reason"], d2["reason"]), ("claimed", "no-input-changes"))
        self.env.advance(a2, run_id="3", now=DAY2)
        self.env.commit({"apps/client/windows/runner/main.cpp": "// v2\n"}, "windows runner")
        _, a3, _ = self.env.gate(DAY3, run_id="5")
        _, d3, _ = self.env.gate(DAY3, run_id="6", platform="desktop")
        self.assertEqual((a3["reason"], d3["reason"]), ("no-input-changes", "claimed"))
        self.env.advance(d3, run_id="6", now=DAY3, platform="desktop")
        self.env.commit({"apps/client/lib/main.dart": "void main() { shared(); }\n"}, "shared")
        _, a4, _ = self.env.gate("2026-11-13T00:05:00Z", run_id="7")
        _, d4, _ = self.env.gate("2026-11-13T00:05:00Z", run_id="8", platform="desktop")
        self.assertEqual((a4["reason"], d4["reason"]), ("claimed", "claimed"))
        # the advance of one platform never touches the other's baseline
        record = run(["git", "ls-remote", self.env.url, f"{DESKTOP_NS}/baseline"], self.env.root).stdout.split()[0]
        workspace = self.env.runner_clone()
        run(["git", "fetch", "--quiet", "--depth", "1", "origin", record], workspace)
        self.assertEqual(gate_module.read_record(workspace, record, "baseline")["platform"], "desktop")

    def test_namespace_and_rules_must_belong_to_the_platform(self):
        for extra, platform, message in (
                (["--namespace", DESKTOP_NS], "android", "does not belong to platform"),
                (["--namespace", ROOT_NS], "android", "does not belong to platform"),
                ([], "server", "unknown platform"),
                (["--legacy-namespace", NS], "android", "invalid legacy namespace"),
                (["--legacy-namespace", f"{NS}/old"], "android", "invalid legacy namespace")):
            with self.subTest(extra=extra, platform=platform):
                code, _, result = self.env.gate(DAY1, extra=extra, platform=platform)
                self.assertEqual(code, 1, result)
                self.assertIn(message, result["stderr"])
        workspace = self.env.runner_clone()
        proc = run([sys.executable, "-I", str(GATE), "gate", "--repo", str(workspace), "--ref", "refs/heads/main",
                    "--run-sha", self.env.head(), "--run-id", "1", "--run-attempt", "1", "--event", "schedule",
                    "--now", DAY1], workspace, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("needs --platform", proc.stderr)
        self.assertEqual(self.env.remote_refs(ROOT_NS), {})

    def test_check_claim_refuses_another_platforms_claim(self):
        _, out, _ = self.env.gate(DAY1, run_id="9", platform="desktop")
        workspace = self.env.runner_clone()
        base = [sys.executable, "-I", str(GATE), "check-claim", "--repo", str(workspace), "--namespace", DESKTOP_NS,
                "--quota-date", out["quota_date"], "--slot", out["quota_slot"], "--claim-record", out["claim_record"],
                "--run-id", "9", "--run-attempt", "1"]
        self.assertEqual(run(base + ["--platform", "desktop"], workspace, check=False).returncode, 0)
        wrong = run(base + ["--platform", "android"], workspace, check=False)
        self.assertEqual(wrong.returncode, 1)
        self.assertIn("does not belong to platform", wrong.stderr)

    def seed_legacy(self, date: str, slot: int, version_code: int | None) -> None:
        seed_legacy(self.env, date, slot, version_code)

    def test_legacy_namespace_is_a_read_only_floor_on_the_cutover_day(self):
        self.seed_legacy("2026-11-10", 1, 2026111001)
        legacy_before = {k: v for k, v in self.env.remote_refs(ROOT_NS).items() if not k.startswith(NS + "/")}
        extra = ["--legacy-namespace", LEGACY_NS, "--version-allocator"]
        # the pre-merge android repository already built today: no second android build
        _, same_day, result = self.env.gate(DAY1_LATE, extra=extra)
        self.assertEqual((same_day["build"], same_day["reason"]), ("false", "quota-used"), result)
        self.assertEqual(self.env.remote_refs(NS), {})  # nothing allocated or claimed
        # a manual release the same day stays above the legacy daily code
        workspace = self.env.runner_clone()
        now = gate_module.resolve_now(DAY1_LATE, None, 120)[0]
        code, _ = gate_module.allocate_version_code(workspace, "origin", NS, "2026-11-10", self.env.head(), "ab" * 32,
                                                    {"purpose": "release"}, now, max_slot=90,
                                                    legacy_namespaces=(LEGACY_NS,))
        self.assertEqual(code, 2026111002)
        # next day: normal daily code; the legacy refs were never written
        _, next_day, _ = self.env.gate(DAY2, run_id="3", extra=extra)
        self.assertEqual((next_day["build"], next_day["version_code"], next_day["quota_slot"]),
                         ("true", "2026111101", "1"))
        self.assertEqual({k: v for k, v in self.env.remote_refs(ROOT_NS).items() if not k.startswith(NS + "/")},
                         legacy_before)

    def test_without_the_legacy_namespace_the_cutover_day_would_repeat_a_code(self):
        self.seed_legacy("2026-11-10", 1, 2026111001)
        _, unaware, _ = self.env.gate(DAY1_LATE, extra=["--version-allocator"])
        self.assertEqual((unaware["build"], unaware["version_code"]), ("true", "2026111001"))  # why android passes it

    def test_legacy_version_code_floor_without_a_legacy_claim_today(self):
        self.seed_legacy("2026-11-09", 1, 2026111005)  # e.g. a release allocated just before the cutover
        _, out, _ = self.env.gate(DAY1, extra=["--legacy-namespace", LEGACY_NS, "--version-allocator"])
        self.assertEqual((out["build"], out["version_code"]), ("true", "2026111006"))


if __name__ == "__main__":
    unittest.main()
