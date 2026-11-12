#!/usr/bin/env python3
"""Offline tests for release_build.py and the shared versionCode allocator.

Real git remotes (file://, as in test_daily_gate.py) for tags, ancestry and
compare-and-swap refs; an in-memory fake of the GitHub release API for
publication; a localhost HTTP server for the REST client itself.

  python3 -I .github/daily-build/tests/test_release_build.py -v
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(HERE))

import daily_gate as gate  # noqa: E402
import release_build as rb  # noqa: E402
import release_tool as tool  # noqa: E402

spec = importlib.util.spec_from_file_location("test_daily_gate", HERE / "test_daily_gate.py")
tdg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tdg)
run, NS = tdg.run, tdg.NS
DAY1, DAY2 = "2026-11-10T08:00:00Z", "2026-11-11T00:05:00Z"
REPO = "aterm-project/android"


class FakeGitHub:
    """In-memory release API with the methods release_build.py uses."""

    repository = REPO

    def __init__(self):
        self.releases: dict[int, dict] = {}
        self.release_assets: dict[int, list[dict]] = {}
        self.tags: dict[str, str] = {}
        self.calls: list[tuple] = []
        self.last_date = ""
        self.fail_upload: str | None = None
        self._next = 1000

    def add_release(self, rid: int, tag: str, sha: str, draft: bool = False) -> dict:
        self.releases[rid] = {"id": rid, "tag_name": tag, "draft": draft, "prerelease": False,
                              "published_at": None if draft else "2026-11-10T07:00:00Z",
                              "html_url": f"https://github.com/{REPO}/releases/tag/{tag}",
                              "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/{rid}/assets{{?name,label}}"}
        self.release_assets.setdefault(rid, [])
        self.tags[tag] = sha
        return self.releases[rid]

    def add_asset(self, rid: int, name: str, data: bytes, state: str = "uploaded") -> dict:
        self._next += 1
        asset = {"id": self._next, "name": name, "size": len(data), "state": state,
                 "digest": f"sha256:{hashlib.sha256(data).hexdigest()}" if state == "uploaded" else None}
        self.release_assets[rid].append(asset)
        return asset

    def release(self, rid):
        return dict(self.releases[rid]) if rid in self.releases else None

    def release_by_tag(self, tag):
        found = [r for r in self.releases.values() if r["tag_name"] == tag]
        return dict(found[-1]) if found else None

    def assets(self, rid):
        return [dict(a) for a in self.release_assets.get(rid, [])]

    def tag_commit(self, tag):
        return self.tags.get(tag)

    def delete_asset(self, asset_id):
        self.calls.append(("delete", asset_id))
        for assets in self.release_assets.values():
            assets[:] = [a for a in assets if a["id"] != asset_id]

    def upload_asset(self, release, path):
        rb.upload_endpoint(release, REPO, "https://api.github.com")
        self.calls.append(("upload", path.name))
        rid = release["id"]
        if any(a["name"] == path.name for a in self.release_assets[rid]):
            raise rb.ReleaseError("422 already_exists")
        if self.fail_upload == path.name:
            self.add_asset(rid, path.name, b"", state="open")
            raise rb.ReleaseError("upload interrupted")
        return self.add_asset(rid, path.name, path.read_bytes())


class GitEnv(tdg.Env):
    def full_clone(self) -> Path:
        self.clones += 1
        path = self.root / f"full{self.clones}"
        run(["git", "clone", "--quiet", "--no-tags", self.url, str(path)], self.root)
        return path

    def tag(self, name: str, sha: str, annotated: bool = True) -> None:
        args = ["git", "tag", "-f"] + (["-a", "-m", f"release {name}"] if annotated else []) + [name, sha]
        run(args, self.author)
        run(["git", "push", "--quiet", "-f", "origin", f"refs/tags/{name}"], self.author)


def prepare_args(workspace: Path, tag: str, rid: str = "", *, now: str = DAY1, run_sha: str = "",
                 ref: str = "refs/heads/main", allocator: bool = True, platforms: str = "android"):
    head = run(["git", "rev-parse", "HEAD"], workspace).stdout.strip()
    return argparse.Namespace(
        repo=str(workspace), remote="origin", namespace=NS, branch="main", rules=gate.DEFAULT_RULES,
        platforms=platforms, version_allocator=allocator, max_skew=120, now=now, server_date="",
        release_tag=tag, release_id=rid, ref=ref, run_sha=run_sha or head, run_id="900", run_attempt="1",
        repository=REPO)


class AllocatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-build-test-"))
        self.env = GitEnv(self.tmp)
        self.api = FakeGitHub()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def daily(self, now, run_id, allocator=True):
        extra = ["--version-allocator"] if allocator else []
        code, out, result = self.env.gate(now, run_id=run_id, extra=extra)
        self.assertEqual(code, 0, result)
        return out

    def release(self, rid, tag, now=DAY1):
        sha = self.env.head()
        self.env.tag(tag, sha)
        self.api.add_release(rid, tag, sha)
        return rb.prepare(prepare_args(self.env.full_clone(), tag, str(rid), now=now), self.api)

    def test_daily_alone_keeps_the_legacy_code_and_records_it(self):
        out = self.daily(DAY1, "1")
        self.assertEqual(out["version_code"], "2026111001")
        refs = self.env.remote_refs()
        self.assertIn(f"{NS}/version-code", refs)
        self.assertIn(f"{NS}/quota/2026-11-10/1", refs)

    def test_manual_release_before_and_after_daily_stays_monotonic(self):
        first = self.release(11, "v1.0.0", now="2026-11-10T00:01:00Z")  # before the late cron start
        out = self.daily("2026-11-10T00:20:00Z", "1")
        self.env.commit({"apps/client/lib/main.dart": "// 2\n"}, "fix")
        second = self.release(12, "v1.0.1", now="2026-11-10T09:00:00Z")
        third = self.release(13, "v1.0.2", now="2026-11-10T23:00:00Z")
        self.env.commit({"apps/client/lib/main.dart": "// 3\n"}, "next")
        nextday = self.daily(DAY2, "2")
        codes = [first["version_code"], int(out["version_code"]), second["version_code"],
                 third["version_code"], int(nextday["version_code"])]
        self.assertEqual(codes, [2026111001, 2026111002, 2026111003, 2026111004, 2026111101])
        # manual releases never touch the daily quota: the cron still claims its single slot
        self.assertEqual(out["quota_slot"], "1")
        self.assertEqual(nextday["quota_slot"], "1")
        self.assertEqual(sorted(r for r in self.env.remote_refs() if "/quota/" in r),
                         [f"{NS}/quota/2026-11-10/1", f"{NS}/quota/2026-11-11/1"])

    def test_release_after_legacy_daily_without_allocator_is_above_it(self):
        out = self.daily(DAY1, "1", allocator=False)
        self.assertEqual(out["version_code"], "2026111001")
        self.assertNotIn(f"{NS}/version-code", self.env.remote_refs())
        self.assertEqual(self.release(21, "v2.0.0")["version_code"], 2026111002)

    def test_same_release_reuses_its_code_and_moved_tag_is_refused(self):
        first = self.release(31, "v3.0.0")
        again = rb.prepare(prepare_args(self.env.full_clone(), "v3.0.0", "31", now="2026-11-10T10:00:00Z"), self.api)
        self.assertEqual((again["version_code"], again["version_record"], again["build_date"]),
                         (first["version_code"], first["version_record"], first["build_date"]))
        allocator = self.env.remote_refs()[f"{NS}/version-code"]
        self.env.commit({"apps/client/lib/main.dart": "// moved\n"}, "moved")
        self.env.tag("v3.0.0", self.env.head())
        self.api.tags["v3.0.0"] = self.env.head()
        with self.assertRaisesRegex(rb.ReleaseError, "already built from"):
            rb.prepare(prepare_args(self.env.full_clone(), "v3.0.0", "31"), self.api)
        self.assertEqual(self.env.remote_refs()[f"{NS}/version-code"], allocator)

    def test_release_cap_keeps_codes_for_the_daily_build(self):
        workspace = self.env.full_clone()
        sha = self.env.head()
        now = gate.resolve_now(DAY1, None, 120)[0]
        info = gate.fingerprint(workspace, sha)
        body = {"schema": gate.SCHEMA, "kind": "version-code", "version_code": 2026111089, "quota_date": "2026-11-10",
                "source_sha": sha, "fingerprint": info["fingerprint"]}
        seed = gate.make_record(workspace, sha, [sha], body, now)
        self.assertEqual(gate.cas_push(workspace, "origin", f"{NS}/version-code", seed, None), "ok")
        self.assertEqual(self.release(41, "v4.0.0")["version_code"], 2026111090)
        with self.assertRaisesRegex(gate.GateError, "no Android versionCode left"):
            self.release(42, "v4.0.1")
        self.assertNotIn(f"{NS}/release/42", self.env.remote_refs())
        self.assertEqual(self.daily(DAY1, "5")["version_code"], "2026111091")

    def test_concurrent_allocations_are_unique(self):
        sha = self.env.head()
        now = gate.resolve_now(DAY1, None, 120)[0]
        clones = [self.env.full_clone() for _ in range(4)]
        codes, errors = [], []

        def worker(path):
            try:
                codes.append(gate.allocate_version_code(path, "origin", NS, "2026-11-10", sha, "ab" * 32,
                                                        {"purpose": "test"}, now, max_slot=90)[0])
            except Exception as error:  # noqa: BLE001 - reported below
                errors.append(error)

        threads = [threading.Thread(target=worker, args=(c,)) for c in clones]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(sorted(codes), [2026111001, 2026111002, 2026111003, 2026111004])

    def test_corrupt_allocator_refuses(self):
        workspace = self.env.full_clone()
        run(["git", "push", "--quiet", "origin", f"HEAD:{NS}/version-code"], workspace)
        code, _, result = self.env.gate(DAY1, extra=["--version-allocator"])
        self.assertEqual(code, 1)
        self.assertIn("version-code record", result["stderr"])
        self.assertNotIn(f"{NS}/quota/2026-11-10/1", self.env.remote_refs())  # nothing claimed


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-prepare-test-"))
        self.env = GitEnv(self.tmp)
        self.api = FakeGitHub()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def publish_release(self, rid, tag, sha=None, annotated=True, draft=False):
        sha = sha or self.env.head()
        self.env.tag(tag, sha, annotated)
        self.api.add_release(rid, tag, sha, draft=draft)
        return sha

    def test_annotated_and_lightweight_tags_resolve_to_the_commit(self):
        for rid, tag, annotated in ((1, "v1.0.0", True), (2, "v1.0.1-rc.1+b2", False)):
            sha = self.publish_release(rid, tag, annotated=annotated)
            out = rb.prepare(prepare_args(self.env.full_clone(), tag, str(rid)), self.api)
            self.assertEqual((out["build"], out["source_sha"], out["release_id"]), (True, sha, rid))

    def test_older_main_commit_with_the_same_recipe_is_allowed(self):
        old = self.env.head()
        self.env.commit({"apps/client/lib/main.dart": "// newer\n"}, "newer")
        self.publish_release(3, "v0.9.0", sha=old)
        self.assertEqual(rb.prepare(prepare_args(self.env.full_clone(), "v0.9.0"), self.api)["source_sha"], old)

    def test_tag_off_main_is_refused_before_any_allocation(self):
        base = self.env.head()
        side = self.env.commit({"apps/client/lib/main.dart": "// untrusted\n"}, "side", branch="topic")
        run(["git", "reset", "--quiet", "--hard", base], self.env.author)
        self.publish_release(4, "v9.9.9", sha=side)
        with self.assertRaisesRegex(rb.ReleaseError, "is not on main"):
            rb.prepare(prepare_args(self.env.full_clone(), "v9.9.9", "4"), self.api)
        self.assertEqual(self.env.remote_refs(), {})

    def test_recipe_change_between_tag_and_workflow_is_refused(self):
        old = self.env.head()
        self.env.commit({".github/daily-build/recipe/build.sh": "echo new\n"}, "recipe")
        self.publish_release(5, "v1.1.0", sha=old)
        with self.assertRaisesRegex(rb.ReleaseError, "current build recipe"):
            rb.prepare(prepare_args(self.env.full_clone(), "v1.1.0"), self.api)

    def test_untrusted_tag_and_id_values_are_rejected(self):
        workspace = self.env.full_clone()
        for tag in ("daily-20261110.1-abcdef012345", "v1;id", "$(id)", "a/b", "../x", "v1..2", "x.lock", "-v1",
                    "v1 2", "v1\nv2", ""):
            with self.subTest(tag=tag), self.assertRaises(rb.ReleaseError):
                rb.prepare(prepare_args(workspace, tag), self.api)
        self.publish_release(6, "v6.0.0")
        for rid in ("0", "-1", "6 ", "6;7", "abc"):
            with self.subTest(rid=rid), self.assertRaises(rb.ReleaseError):
                rb.prepare(prepare_args(workspace, "v6.0.0", rid), self.api)

    def test_release_state_checks(self):
        self.publish_release(7, "v7.0.0", draft=True)
        workspace = self.env.full_clone()
        with self.assertRaisesRegex(rb.ReleaseError, "draft"):
            rb.prepare(prepare_args(workspace, "v7.0.0"), self.api)
        self.publish_release(8, "v8.0.0")
        with self.assertRaisesRegex(rb.ReleaseError, "release replaced"):
            rb.prepare(prepare_args(workspace, "v8.0.0", "99"), self.api)
        with self.assertRaisesRegex(rb.ReleaseError, "no published release"):
            rb.prepare(prepare_args(workspace, "v404"), self.api)
        self.api.add_release(9, "v-no-tag", self.env.head())
        with self.assertRaisesRegex(rb.ReleaseError, "does not exist"):
            rb.prepare(prepare_args(workspace, "v-no-tag"), self.api)

    def test_only_from_main_with_full_history(self):
        self.publish_release(10, "v10.0.0")
        with self.assertRaisesRegex(rb.ReleaseError, "only from refs/heads/main"):
            rb.prepare(prepare_args(self.env.full_clone(), "v10.0.0", ref="refs/tags/v10.0.0"), self.api)
        shallow = self.env.runner_clone()
        with self.assertRaisesRegex(rb.ReleaseError, "full commit history"):
            rb.prepare(prepare_args(shallow, "v10.0.0"), self.api)

    def test_complete_publication_skips_without_allocating(self):
        self.publish_release(11, "v11.0.0")
        self.api.add_asset(11, "evidence-android.json", b"{}")
        self.api.add_asset(11, "SHA256SUMS", b"x")
        out = rb.prepare(prepare_args(self.env.full_clone(), "v11.0.0"), self.api)
        self.assertEqual((out["build"], out["reason"]), (False, "already-published"))
        self.assertEqual(self.env.remote_refs(), {})

    def test_desktop_prepare_needs_no_allocator_or_write(self):
        self.publish_release(12, "v12.0.0")
        out = rb.prepare(prepare_args(self.env.full_clone(), "v12.0.0", allocator=False,
                                      platforms="linux-x64,macos,windows-x64"), self.api)
        self.assertTrue(out["build"])
        self.assertNotIn("version_code", out)
        self.assertEqual(self.env.remote_refs(), {})

    def test_cli_reads_untrusted_values_from_env_and_writes_single_line_outputs(self):
        self.publish_release(13, "v13.0.0")
        workspace = self.env.full_clone()
        output = workspace / "out.txt"
        env = {"ATERMIUS_RELEASE_TAG": "v13.0.0", "ATERMIUS_RELEASE_ID": "13", "GITHUB_REF": "refs/heads/main",
               "GITHUB_SHA": self.env.head(), "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1",
               "GITHUB_REPOSITORY": REPO, "GH_TOKEN": "t"}
        with mock.patch.dict(os.environ, env), mock.patch.object(rb, "GitHub", return_value=self.api):
            code = rb.main(["prepare", "--repo", str(workspace), "--platforms", "android", "--version-allocator",
                            "--now", DAY1, "--github-output", str(output), "--summary", ""])
        self.assertEqual(code, 0)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual((outputs["build"], outputs["release_tag"], outputs["version_code"]),
                         ("true", "v13.0.0", "2026111001"))


class PublishTests(unittest.TestCase):
    SHA = "c0ffee" + "0" * 34

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-publish-test-"))
        self.api = FakeGitHub()
        self.release = self.api.add_release(50, "v5.0.0", self.SHA)
        self.unrelated = self.api.add_asset(50, "notes-by-maintainer.pdf", b"human upload")
        self.unrelated_open = self.api.add_asset(50, "other-interrupted.bin", b"", state="open")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def packages(self, name="out", source=None, payload=b"signed apk bytes"):
        out = self.tmp / name
        out.mkdir()
        apk = "atermius-android-1.0.0-v5.0.0-arm64-x86_64.apk"
        (out / apk).write_bytes(payload)
        env = {"ATERMIUS_SOURCE_SHA": source or self.SHA, "ATERMIUS_QUOTA_DATE": "2026-11-10",
               "ATERMIUS_RELEASE_TAG": "v5.0.0", "GITHUB_RUN_ID": "77", "GITHUB_RUN_ATTEMPT": "2"}
        with mock.patch.dict(os.environ, env):
            tool.write_evidence(argparse.Namespace(out_dir=str(out), artifact=[apk], platform="android",
                                                   meta=[], note=[], attach=[]))
        return out

    def publish(self, out, run_id="77"):
        args = argparse.Namespace(dir=str(out), work=str(self.tmp / f"work-{out.name}"), platforms="android",
                                  release_tag="v5.0.0", release_id="50", source_sha=self.SHA,
                                  build_date="2026-11-10", run_id=run_id, run_url="https://example.invalid/run")
        return rb.publish(args, self.api)

    def names(self):
        return sorted(a["name"] for a in self.api.release_assets[50])

    def test_fresh_publication_adds_packages_and_sums_last(self):
        result = self.publish(self.packages())
        uploads = [c[1] for c in self.api.calls if c[0] == "upload"]
        self.assertEqual(uploads[-1], "SHA256SUMS")
        self.assertEqual(sorted(uploads), ["SHA256SUMS", "atermius-android-1.0.0-v5.0.0-arm64-x86_64.apk",
                                           "evidence-android.json"])
        self.assertIn("notes-by-maintainer.pdf", self.names())
        self.assertIn("other-interrupted.bin", self.names())  # unrelated assets are never touched
        self.assertNotIn("delete", [c[0] for c in self.api.calls])
        self.assertEqual(result["identical"], [])
        self.assertTrue(rb.publication_complete(self.api.assets(50), ["android"]))

    def test_rerun_with_the_same_packages_changes_nothing(self):
        out = self.packages()
        self.publish(out)
        self.api.calls.clear()
        result = self.publish(out)
        self.assertEqual(self.api.calls, [])
        self.assertEqual(len(result["identical"]), 3)

    def test_interrupted_upload_is_replaced_on_resume(self):
        out = self.packages()
        self.api.fail_upload = "evidence-android.json"
        with self.assertRaisesRegex(rb.ReleaseError, "interrupted"):
            self.publish(out)
        self.assertFalse(rb.publication_complete(self.api.assets(50), ["android"]))
        self.api.fail_upload = None
        self.api.calls.clear()
        result = self.publish(out)
        self.assertEqual(result["replaced_partial"], ["evidence-android.json"])
        self.assertEqual([c[0] for c in self.api.calls], ["delete", "upload", "upload"])
        self.assertIn("other-interrupted.bin", self.names())
        self.assertTrue(rb.publication_complete(self.api.assets(50), ["android"]))

    def test_different_existing_asset_is_refused_before_any_change(self):
        self.api.add_asset(50, "atermius-android-1.0.0-v5.0.0-arm64-x86_64.apk", b"another build")
        before = self.names()
        with self.assertRaisesRegex(rb.ReleaseError, "different assets"):
            self.publish(self.packages())
        self.assertEqual((self.api.calls, self.names()), ([], before))

    def test_asset_without_digest_is_not_assumed_identical(self):
        asset = self.api.add_asset(50, "evidence-android.json", b"{}")
        asset["digest"] = None
        with self.assertRaisesRegex(rb.ReleaseError, "different assets"):
            self.publish(self.packages())

    def test_replaced_release_moved_tag_or_draft_are_refused(self):
        out = self.packages()
        self.api.add_release(51, "v5.0.0", self.SHA)  # tag now belongs to a replacement release
        with self.assertRaisesRegex(rb.ReleaseError, "replacement"):
            self.publish(out)
        del self.api.releases[51]
        self.api.tags["v5.0.0"] = "d" * 40
        with self.assertRaisesRegex(rb.ReleaseError, "no longer points"):
            self.publish(out)
        self.api.tags["v5.0.0"] = self.SHA
        self.api.releases[50]["draft"] = True
        with self.assertRaisesRegex(rb.ReleaseError, "draft"):
            self.publish(out)
        self.assertEqual([c for c in self.api.calls if c[0] != "noop"], [])

    def test_evidence_of_another_source_or_run_is_refused(self):
        with self.assertRaisesRegex(tool.ToolError, "does not belong"):
            self.publish(self.packages(source="e" * 40))
        with self.assertRaisesRegex(tool.ToolError, "does not belong"):
            self.publish(self.packages(name="out2"), run_id="78")
        self.assertEqual(self.api.calls, [])

    def test_upload_endpoint_must_address_this_release(self):
        good = {"id": 50, "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/50/assets{{?name,label}}"}
        self.assertTrue(rb.upload_endpoint(good, REPO, "https://api.github.com").endswith("/50/assets"))
        for url in (f"http://uploads.github.com/repos/{REPO}/releases/50/assets",
                    f"https://evil.example/repos/{REPO}/releases/50/assets",
                    f"https://uploads.github.com/repos/{REPO}/releases/51/assets",
                    "https://uploads.github.com/repos/other/repo/releases/50/assets"):
            with self.subTest(url=url), self.assertRaises(rb.ReleaseError):
                rb.upload_endpoint({"id": 50, "upload_url": url}, REPO, "https://api.github.com")


class _Handler(http.server.BaseHTTPRequestHandler):
    routes: dict = {}
    seen: list = []

    def do_GET(self):  # noqa: N802
        type(self).seen.append((self.path, self.headers.get("Authorization")))
        status, body, headers = type(self).routes.get(self.path, (404, {"message": "Not Found"}, {}))
        data = json.dumps(body).encode()
        self.send_response(status)
        for key, value in {"Content-Type": "application/json", **headers}.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.api = rb.GitHub(REPO, "secret-token", f"http://127.0.0.1:{self.server.server_port}")
        _Handler.seen = []

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_tag_peeling_pagination_404_and_no_credentialed_redirect(self):
        base = f"/repos/{REPO}"
        _Handler.routes = {
            f"{base}/git/ref/tags/v1.0.0": (200, {"object": {"type": "tag", "sha": "a" * 40}}, {}),
            f"{base}/git/tags/{'a' * 40}": (200, {"object": {"type": "commit", "sha": "b" * 40}}, {}),
            f"{base}/releases/tags/v1%2Bx": (200, {"id": 5, "tag_name": "v1+x"}, {}),
            f"{base}/releases/5/assets?per_page=100&page=1": (200, [{"name": str(i)} for i in range(100)], {}),
            f"{base}/releases/5/assets?per_page=100&page=2": (200, [{"name": "last"}], {}),
            f"{base}/releases/6": (302, {}, {"Location": "http://127.0.0.1:1/elsewhere"}),
        }
        self.assertEqual(self.api.tag_commit("v1.0.0"), "b" * 40)
        self.assertEqual(self.api.release_by_tag("v1+x")["id"], 5)
        self.assertIsNotNone(gate.email.utils.parsedate_to_datetime(self.api.last_date))  # server Date kept
        self.assertEqual(len(self.api.assets(5)), 101)
        self.assertIsNone(self.api.release_by_tag("missing"))
        with self.assertRaisesRegex(rb.ReleaseError, "302"):
            self.api.release(6)
        self.assertTrue(all(auth == "Bearer secret-token" for _, auth in _Handler.seen))


class WorkflowTests(unittest.TestCase):
    ROOT = HERE.parents[2]

    def setUp(self):
        import yaml  # noqa: PLC0415 - PyYAML is only needed for the workflow tests
        self.yaml = yaml
        spec_lint = importlib.util.spec_from_file_location("lint_workflows", HERE / "lint_workflows.py")
        self.lint = importlib.util.module_from_spec(spec_lint)
        spec_lint.loader.exec_module(self.lint)

    def load(self, name):
        return self.yaml.safe_load((self.ROOT / ".github/workflows" / name).read_text())

    def test_release_build_reuses_the_daily_build_steps(self):
        daily, release = self.load("daily-build.yml"), self.load("release-build.yml")
        normalise = {"needs.gate.outputs.source_sha": "needs.prepare.outputs.source_sha"}

        def steps(doc, artifact_names):
            text = json.dumps(doc["jobs"]["build"]["steps"])
            for old, new in {**normalise, **artifact_names}.items():
                text = text.replace(old, new)
            data = json.loads(text)
            for step in data:
                if str(step.get("uses", "")).startswith("actions/upload-artifact"):
                    step["with"].pop("retention-days", None)
            return data

        names = {"android-intermediate-${{ github.run_attempt }}": "release-android-intermediate",
                 "desktop-${{ matrix.platform }}-${{ github.run_attempt }}": "release-desktop-${{ matrix.platform }}"}
        self.assertEqual(steps(release, {}), steps(daily, names))
        self.assertEqual(release["jobs"]["build"].get("strategy"), daily["jobs"]["build"].get("strategy"))
        if "sign" in daily["jobs"]:
            dsign = json.dumps(daily["jobs"]["sign"]["steps"]).replace("needs.gate.", "needs.prepare.").replace(
                "android-intermediate-${{ github.run_attempt }}", "release-android-intermediate").replace(
                "android-release-${{ github.run_attempt }}", "release-android-signed")
            rsign = json.loads(json.dumps(release["jobs"]["sign"]["steps"]))
            dsign = json.loads(dsign)
            for step in dsign + rsign:
                if str(step.get("uses", "")).startswith("actions/upload-artifact"):
                    step["with"].pop("retention-days", None)
            self.assertEqual(rsign, dsign)
            self.assertEqual(release["jobs"]["sign"]["environment"], daily["jobs"]["sign"]["environment"])

    def test_policy_lint_accepts_the_repository_and_rejects_widening(self):
        for name in ("release-build.yml", "release-trigger.yml", "daily-build.yml"):
            self.assertEqual(self.lint.lint_file(self.ROOT / ".github/workflows" / name), [], name)
        build = (self.ROOT / ".github/workflows/release-build.yml").read_text()
        trigger = (self.ROOT / ".github/workflows/release-trigger.yml").read_text()
        daily = (self.ROOT / ".github/workflows/daily-build.yml").read_text()
        cases = [
            ("release-build.yml", build, "    if: github.ref == 'refs/heads/main' && needs.prepare.outputs.build == 'true'\n",
             "    if: needs.prepare.outputs.build == 'true'\n", "main-only"),
            ("release-build.yml", build, "      release_id:\n", "      extra:\n        type: string\n      release_id:\n",
             "must not take inputs"),
            ("release-build.yml", build, "on:\n  workflow_dispatch:\n", "on:\n  push: {}\n  workflow_dispatch:\n",
             "only by workflow_dispatch"),
            ("release-build.yml", build, "    permissions:\n      contents: read\n    env:\n",
             "    permissions:\n      contents: write\n    env:\n", "write permission"),  # compile job
            ("release-build.yml", build, "      ATERMIUS_RELEASE_ID: ${{ needs.prepare.outputs.release_id }}\n",
             "      ATERMIUS_RELEASE_ID: ${{ inputs.release_id }}\n", "inputs may only reach"),
            ("release-build.yml", build, "          GH_TOKEN: ${{ github.token }}\n        run: |\n          python3",
             "          GH_TOKEN: ${{ secrets.X }}\n        run: |\n          python3", "secrets are only"),
            ("release-build.yml", build, "cancel-in-progress: false", "cancel-in-progress: true", "concurrency"),
            ("release-trigger.yml", trigger, "      actions: write", "      actions: write\n      contents: write",
             "write permission"),
            ("release-trigger.yml", trigger, "    if: ${{ !startsWith(github.event.release.tag_name, 'daily-') }}\n",
             "", "daily-* skip"),
            ("release-trigger.yml", trigger, "    types: [published]", "    types: [published, edited]",
             "release published"),
            ("daily-build.yml", daily, "  workflow_dispatch: {}",
             "  workflow_dispatch:\n    inputs:\n      release_tag:\n        type: string", "must not take inputs"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            for name, original, old, new, error in cases:
                with self.subTest(name=name, error=error):
                    self.assertIn(old, original)
                    candidate = Path(directory) / name
                    candidate.write_text(original.replace(old, new, 1))
                    problems = self.lint.lint_file(candidate)
                    self.assertTrue(any(error in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
