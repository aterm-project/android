#!/usr/bin/env python3
"""Installation packages for a published GitHub Release (stdlib only).

  prepare  runs in the main-branch `release-<platform>.yml` (trusted
           definition): validate the dispatched tag / release id (untrusted
           strings; the tag must be `<platform>-...` and not a daily tag),
           require a published release, resolve the tag (annotated tags are
           peeled) to ONE immutable commit, require that commit to be an
           ancestor of the default branch and to carry the same build recipe
           for this platform as the running workflow, and, for Android,
           allocate one versionCode per release from the counter shared with
           the daily gate.
  publish  verify the evidence/SHA-256 of the built packages, then add them to
           exactly that existing published release (by id): identical assets
           are kept, interrupted ("open") uploads of the same name are replaced,
           anything else with the same name is refused before any change; other
           assets are never touched. SHA256SUMS is uploaded last and marks a
           complete publication.

One copy serves the release builds of all platforms of the monorepo (today
android and desktop) and is exercised offline by tests/test_release_build.py
(local git remotes + a fake GitHub API).

Exit status: 0 decided/succeeded, 1 refused, 3 clock disagreement (retry).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import daily_gate as gate  # noqa: E402
import release_tool as tool  # noqa: E402

TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$")
RELEASE_ID_RE = re.compile(r"^[1-9][0-9]{0,15}$")
# Files the source checkout must share with the running workflow: the jobs call
# the recipe of the commit they build (as the daily build does), so its
# interface must be the one this workflow definition was written for. Only this
# platform's recipe files count, so a change to another platform's recipe does
# not block releases of tags created before it.
RECIPE_DIR = ".github/daily-build/recipe"
SHARED_RECIPE_FILES = ("flutter_sdk.py",)
RECIPE_PATHS = (".github/daily-build/release_tool.py",)
SUMS = "SHA256SUMS"
PARTIAL_STATES = {"open", "starter"}  # interrupted uploads as reported by the release assets API
SUMS_LINE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]{0,150})$")


class ReleaseError(gate.GateError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def validate_platform(platform: str, targets: str | None = None) -> str:
    """``platform`` is a known client platform and ``targets`` (``--platforms``) its evidence platforms."""
    require(platform in gate.PLATFORMS, f"unknown platform {platform!r}")
    if targets is not None:
        require(sorted(targets.split(",")) == sorted(gate.PLATFORMS[platform]),
                f"--platforms {targets!r} are not the packages of {platform} ({','.join(gate.PLATFORMS[platform])})")
    return platform


def validate_tag(tag: str, platform: str) -> str:
    require(bool(TAG_RE.match(tag)) and ".." not in tag and not tag.endswith((".", ".lock")),
            "release tag must match [A-Za-z0-9][A-Za-z0-9._+-]{0,99} (no '/', '..', trailing '.' or '.lock')")
    require(not tag.startswith("daily-") and not any(tag.startswith(f"{p}-daily-") for p in gate.PLATFORMS),
            "daily releases (<platform>-daily-*, legacy daily-*) are published by the daily build itself")
    require(tag.startswith(f"{validate_platform(platform)}-") and len(tag) > len(platform) + 1,
            f"{platform} packages are attached only to releases tagged {platform}-*")
    return tag


def recipe_files(repo: Path, rev: str, platform: str) -> dict[str, str]:
    """``{name: "mode oid"}`` of this platform's recipe files (``<platform>_*`` and the shared ones)."""
    proc = gate.git(repo, "ls-tree", "-z", f"{rev}:{RECIPE_DIR}", check=False)
    require(proc.returncode == 0, f"{RECIPE_DIR} is missing at {rev[:12]}")
    files = {}
    for item in proc.stdout.split("\0"):
        meta, _, name = item.partition("\t")
        if name and (name.startswith(f"{platform}_") or name in SHARED_RECIPE_FILES):
            mode, _, oid = meta.split()
            files[name] = f"{mode} {oid}"
    return files


# ------------------------------------------------------------------ GitHub API


class GitHub:
    """Minimal REST client. The token is only sent to the API/uploads host and
    never printed; redirects are not followed with credentials."""

    def __init__(self, repository: str, token: str, api_url: str = "https://api.github.com"):
        require(bool(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)), "invalid repository")
        require(bool(token), "GH_TOKEN is not set")
        self.repository, self._token, self.api_url = repository, token, api_url.rstrip("/")
        self.last_date = ""

    def _request(self, method: str, url: str, data=None, headers: dict | None = None):
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self._token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "atermius-release-build", **(headers or {})})
        opener = urllib.request.build_opener(_NoRedirect)
        try:
            with opener.open(req, timeout=600) as response:
                self.last_date = response.headers.get("Date", "") or self.last_date
                body = response.read()
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            detail = ""
            try:
                detail = str(json.loads(error.read() or b"{}").get("message", ""))[:200]
            except ValueError:
                pass
            if error.code == 404 and method == "GET":
                return 404, None
            raise ReleaseError(f"GitHub API {method} {urllib.parse.urlsplit(url).path} -> {error.code} {detail}") \
                from None

    def get(self, path: str):
        status, data = self._request("GET", f"{self.api_url}/repos/{self.repository}/{path}")
        return data if status == 200 else None

    def release(self, release_id: int):
        return self.get(f"releases/{release_id}")

    def release_by_tag(self, tag: str):
        return self.get(f"releases/tags/{urllib.parse.quote(tag, safe='')}")

    def assets(self, release_id: int) -> list[dict]:
        found: list[dict] = []
        for page in range(1, 51):
            batch = self.get(f"releases/{release_id}/assets?per_page=100&page={page}") or []
            found += batch
            if len(batch) < 100:
                return found
        raise ReleaseError("release has more than 5000 assets")

    def tag_commit(self, tag: str) -> str | None:
        ref = self.get(f"git/ref/tags/{urllib.parse.quote(tag, safe='')}")
        if not ref:
            return None
        obj = ref.get("object") or {}
        for _ in range(5):  # annotated tags (and tags of tags) are peeled
            if obj.get("type") == "commit":
                return obj.get("sha")
            require(obj.get("type") == "tag", f"tag {tag} points to a {obj.get('type')}")
            obj = (self.get(f"git/tags/{obj.get('sha')}") or {}).get("object") or {}
        raise ReleaseError(f"tag {tag} is nested too deeply")

    def download_asset(self, asset: dict, limit: int = 4 << 20) -> bytes:
        """Small asset (SHA256SUMS, evidence) by API; a storage redirect is followed WITHOUT the token.
        The bytes must match the asset's SHA-256 digest."""
        require(isinstance(asset.get("size"), int) and asset["size"] <= limit, f"{asset.get('name')} is too large")
        url = f"{self.api_url}/repos/{self.repository}/releases/assets/{int(asset['id'])}"
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self._token}", "Accept": "application/octet-stream",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "atermius-release-build"})
        try:
            with urllib.request.build_opener(_NoRedirect).open(req, timeout=120) as response:
                data = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location", "") if error.code in (301, 302, 303, 307, 308) else ""
            require(bool(location), f"download of {asset.get('name')} -> {error.code}")
            require(urllib.parse.urlsplit(location).scheme == urllib.parse.urlsplit(self.api_url).scheme,
                    "asset download redirect changes the URL scheme")
            plain = urllib.request.Request(location, headers={"User-Agent": "atermius-release-build"})
            with urllib.request.urlopen(plain, timeout=120) as response:
                data = response.read(limit + 1)
        require(len(data) == asset["size"], f"{asset.get('name')}: downloaded size differs")
        require(asset.get("digest") == f"sha256:{hashlib.sha256(data).hexdigest()}",
                f"{asset.get('name')}: downloaded bytes do not match the asset digest")
        return data

    def delete_asset(self, asset_id: int) -> None:
        self._request("DELETE", f"{self.api_url}/repos/{self.repository}/releases/assets/{int(asset_id)}")

    def upload_asset(self, release: dict, path: Path) -> dict:
        url = upload_endpoint(release, self.repository, self.api_url)
        with path.open("rb") as handle:
            _, data = self._request("POST", f"{url}?name={urllib.parse.quote(path.name, safe='')}", data=handle,
                                    headers={"Content-Type": "application/octet-stream",
                                             "Content-Length": str(path.stat().st_size)})
        return data or {}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # never forward the token elsewhere
        return None


def upload_endpoint(release: dict, repository: str, api_url: str) -> str:
    """The release's own upload URL, checked to address this repository/release."""
    raw = str(release.get("upload_url") or "").split("{", 1)[0]
    parts = urllib.parse.urlsplit(raw)
    api_host = urllib.parse.urlsplit(api_url).hostname or ""
    expected_host = "uploads.github.com" if api_host == "api.github.com" else api_host
    require(parts.scheme == "https" and parts.hostname == expected_host and not parts.query
            and parts.path.endswith(f"/repos/{repository}/releases/{int(release['id'])}/assets"),
            f"unexpected upload URL for release {release.get('id')}")
    return raw


# ---------------------------------------------------------------- shared checks


def check_release(release: dict | None, tag: str, release_id: int | None) -> dict:
    require(release is not None, f"no published release for tag {tag}")
    require(release.get("tag_name") == tag, "release tag differs from the requested tag")
    require(isinstance(release.get("id"), int) and release["id"] > 0, "release has no id")
    require(release_id is None or release["id"] == release_id,
            f"tag {tag} now belongs to release {release['id']}, not {release_id} (release replaced?)")
    require(release.get("draft") is False and bool(release.get("published_at")),
            "release is a draft or unpublished; packages are built only for published releases")
    return release


def publication_gap(api, assets: list[dict], platforms: list[str], tag: str, source: str) -> str | None:
    """None if the release already carries a complete, verified publication of ``source``:
    SHA256SUMS lists every package and evidence file, each attached with that digest, and each
    platform's evidence belongs to this tag and commit and lists only packages in SHA256SUMS.
    Otherwise the first gap found (the caller builds; publish refuses conflicting stale assets)."""
    uploaded: dict[str, dict] = {}
    for asset in assets:
        if asset.get("state") == "uploaded":
            if asset.get("name") in uploaded:
                return f"duplicate asset {asset.get('name')}"
            uploaded[asset.get("name")] = asset
    if SUMS not in uploaded:
        return f"no {SUMS}"
    listed: dict[str, str] = {}
    for line in api.download_asset(uploaded[SUMS]).decode("utf-8", "replace").splitlines():
        match = SUMS_LINE.match(line)
        if not match or match.group(2) in listed:
            return f"{SUMS} is not ours"
        listed[match.group(2)] = match.group(1)
    for name, digest in listed.items():
        if (uploaded.get(name) or {}).get("digest") != f"sha256:{digest}":
            return f"{name} is missing or differs from {SUMS}"
    packages: set[str] = set()
    for platform in platforms:
        name = f"evidence-{platform}.json"
        if name not in listed:
            return f"{name} is not listed in {SUMS}"
        try:
            data = json.loads(api.download_asset(uploaded[name]))
            items = {str(a["name"]): str(a["sha256"]) for a in data["artifacts"]}
        except (ValueError, KeyError, TypeError):
            return f"{name} is not valid evidence"
        if (data.get("schema"), data.get("status"), data.get("platform"), data.get("source_sha"),
                data.get("release_tag")) != (tool.SCHEMA, "built", platform, source, tag):
            return f"{name} belongs to another platform, source or tag"
        if not items or any(listed.get(k) != v for k, v in items.items()):
            return f"packages of {name} are not all attached"
        packages |= set(items)
    if set(listed) != packages | {f"evidence-{p}.json" for p in platforms}:
        return f"{SUMS} lists files that no evidence accounts for"
    return None


def emit(result: dict, github_output: str, summary: str) -> None:
    print(json.dumps(result, indent=2, sort_keys=True))
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            for key in ("build", "reason", "release_id", "release_tag", "source_sha", "short_sha", "build_date",
                        "version_code", "version_record"):
                value = result.get(key)
                value = "" if value is None else str(value).lower() if isinstance(value, bool) else str(value)
                require("\n" not in value and "\r" not in value, f"output {key} contains a newline")
                handle.write(f"{key}={value}\n")
    if summary:
        rows = [f"### Release build: {'BUILD' if result.get('build') else 'skip'} ({result.get('reason')})", "",
                "| key | value |", "| --- | --- |"]
        rows += [f"| {k} | `{result[k]}` |" for k in ("release_tag", "release_id", "source_sha", "build_date",
                                                     "version_code", "detail") if result.get(k) not in (None, "")]
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(rows) + "\n")


# ---------------------------------------------------------------------- prepare


def resolve_tag(repo: Path, remote: str, tag: str, branch: str) -> tuple[str, str]:
    refs = gate.ls_remote(repo, remote, [f"refs/heads/{branch}", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"])
    tip, direct = refs.get(f"refs/heads/{branch}"), refs.get(f"refs/tags/{tag}")
    require(bool(tip), f"remote branch {branch} not found")
    require(bool(direct), f"tag {tag} does not exist")
    source = refs.get(f"refs/tags/{tag}^{{}}", direct)  # ls-remote peels annotated tags to the final object
    gate.git(repo, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, tip, source)
    kind = gate.git(repo, "cat-file", "-t", source).stdout.strip()
    require(kind == "commit", f"tag {tag} resolves to a {kind}, not a commit")
    return source, tip


def prepare(args: argparse.Namespace, api) -> dict:
    validate_platform(args.platform, args.platforms)
    gate.validate_common(args)
    repo = Path(args.repo)
    tag = validate_tag(args.release_tag, args.platform)
    release_id = None
    if args.release_id:
        require(bool(RELEASE_ID_RE.match(args.release_id)), "release id must be a positive integer")
        release_id = int(args.release_id)
    branch = gate.remote_default_branch(repo, args.remote)
    require(not args.branch or args.branch == branch, f"release branch {args.branch!r} is not the default {branch!r}")
    require(args.ref == f"refs/heads/{branch}", f"release builds run only from refs/heads/{branch}, not {args.ref}")
    require(gate.git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() == "false",
            "prepare needs the full commit history (actions/checkout fetch-depth: 0)")

    release = check_release(api.release_by_tag(tag), tag, release_id)
    now, clock = gate.resolve_now(args.now, args.server_date or api.last_date, args.max_skew)
    date = now.date().isoformat()
    source, tip = resolve_tag(repo, args.remote, tag, branch)
    require(gate.git(repo, "merge-base", "--is-ancestor", source, tip, check=False).returncode == 0,
            f"tag {tag} -> {source[:12]} is not on {branch} ({tip[:12]}); only reviewed commits are built and signed")
    if not gate.has_object(repo, args.run_sha):
        gate.fetch_shas(repo, args.remote, [args.run_sha])
    for path in RECIPE_PATHS:
        require(gate.tree_of(repo, source, path) == gate.tree_of(repo, args.run_sha, path),
                f"{path} of {tag} ({source[:12]}) differs from this workflow's ({args.run_sha[:12]}); "
                f"tag a commit with the current build recipe")
    require(recipe_files(repo, source, args.platform) == recipe_files(repo, args.run_sha, args.platform),
            f"the {args.platform} recipe in {RECIPE_DIR} of {tag} ({source[:12]}) differs from this workflow's "
            f"({args.run_sha[:12]}); tag a commit with the current build recipe")
    result = {"build": True, "reason": "build", "release_id": release["id"], "release_tag": tag,
              "source_sha": source, "short_sha": source[:12], "build_date": date, "clock_source": clock,
              "prerelease": bool(release.get("prerelease")), "branch_tip": tip}

    # The release's recorded binding (Android) is checked before anything else may skip.
    bound = release_binding(repo, args, release["id"], tag, source) if args.version_allocator else None
    gap = publication_gap(api, api.assets(release["id"]), args.platforms.split(","), tag, source)
    if gap is None:
        result.update(build=False, reason="already-published",
                      detail=f"verified packages, evidence and {SUMS} of {source[:12]} are already attached")
        return result
    result["detail"] = f"publication incomplete: {gap}"
    if args.version_allocator:
        result.update(bound or allocate_release_version(repo, args, release["id"], tag, source, date, now))
    return result


def release_binding(repo: Path, args: argparse.Namespace, release_id: int, tag: str, source: str) -> dict | None:
    """The versionCode/source recorded for this release id, if any; a moved tag is refused.
    A binding made before the monorepo merge (legacy namespace) is honoured, never rewritten."""
    refs = [f"{ns}/release/{release_id}" for ns in [args.namespace] + list(getattr(args, "legacy_namespace", None) or [])]
    found = gate.ls_remote(repo, args.remote, refs)
    sha = next((found[r] for r in refs if found.get(r)), None)
    if not sha:
        return None
    gate.fetch_shas(repo, args.remote, [sha])
    record = gate.read_record(repo, sha, "release-build")
    require(record.get("release_tag") == tag and record.get("source_sha") == source,
            f"release {release_id} was already built from {record.get('release_tag')} "
            f"({str(record.get('source_sha'))[:12]}); its tag now resolves to {source[:12]}. "
            "Publish a new release instead of moving a tag.")
    return {"version_code": record["version_code"], "version_record": sha, "build_date": record["quota_date"]}


def allocate_release_version(repo: Path, args: argparse.Namespace, release_id: int, tag: str, source: str,
                             date: str, now) -> dict:
    """One versionCode per release id: a re-dispatch or re-run reuses it."""
    ref = f"{args.namespace}/release/{release_id}"

    def existing() -> dict | None:
        return release_binding(repo, args, release_id, tag, source)

    info = gate.fingerprint(repo, source, args.rules)
    payload = {"purpose": "release", "platform": args.platform, "repository": args.repository,
               "release_id": release_id, "release_tag": tag, "run_id": args.run_id, "run_attempt": args.run_attempt}
    code, _ = gate.allocate_version_code(repo, args.remote, args.namespace, date, source, info["fingerprint"],
                                         payload, now, max_slot=gate.RELEASE_MAX_SLOT,
                                         legacy_namespaces=tuple(getattr(args, "legacy_namespace", None) or []))
    body = {**payload, "schema": gate.SCHEMA, "kind": "release-build", "quota_date": date, "source_sha": source,
            "fingerprint": info["fingerprint"], "version_code": code, "allocated_at": gate.utc_iso(now),
            "nonce": os.urandom(16).hex()}
    record = gate.make_record(repo, source, [source], body, now)
    if gate.cas_push(repo, args.remote, ref, record, None) == "ok":
        return {"version_code": code, "version_record": record, "build_date": date}
    found = existing()  # a concurrent run for the same release won; use its code (ours is a harmless gap)
    require(found is not None, f"{ref} changed concurrently")
    return found


# ---------------------------------------------------------------------- publish


def plan_uploads(local: list[Path], remote_assets: list[dict]) -> tuple[list[Path], list[dict], list[str], list[str]]:
    """Returns (to_upload, partial_to_delete, identical, conflicts) for files named like an existing asset."""
    by_name: dict[str, list[dict]] = {}
    for asset in remote_assets:
        by_name.setdefault(asset.get("name"), []).append(asset)
    upload, delete, identical, conflicts = [], [], [], []
    for path in local:
        same = by_name.get(path.name, [])
        done = [a for a in same if a.get("state") == "uploaded"]
        if done:
            asset = done[0]
            digest = tool.sha256_file(path)
            if len(done) == 1 and asset.get("size") == path.stat().st_size and asset.get("digest") == f"sha256:{digest}":
                identical.append(path.name)
            else:
                conflicts.append(path.name)
            continue
        if any(a.get("state") not in PARTIAL_STATES for a in same):
            conflicts.append(path.name)  # unknown state: never deleted
            continue
        delete += same  # confirmed interrupted uploads of exactly this name
        upload.append(path)
    return upload, delete, identical, conflicts


def verify_published(remote_assets: list[dict], local: list[Path]) -> None:
    remote = {a.get("name"): a for a in remote_assets if a.get("state") == "uploaded"}
    for path in local:
        asset = remote.get(path.name)
        require(asset is not None, f"{path.name} is not attached to the release")
        require(asset.get("size") == path.stat().st_size, f"{path.name}: published size differs")
        digest = str(asset.get("digest") or "")
        require(not digest or digest == f"sha256:{tool.sha256_file(path)}", f"{path.name}: published digest differs")


def check_target(api, release_id: int, tag: str, source: str) -> dict:
    release = check_release(api.release(release_id), tag, release_id)
    by_tag = api.release_by_tag(tag)
    require(by_tag is not None and by_tag.get("id") == release_id,
            f"tag {tag} no longer belongs to release {release_id}; refusing to publish into a replacement")
    require(api.tag_commit(tag) == source, f"tag {tag} no longer points to the built commit {source[:12]}")
    return release


def publish(args: argparse.Namespace, api) -> dict:
    validate_platform(args.platform, args.platforms)
    tag = validate_tag(args.release_tag, args.platform)
    require(bool(RELEASE_ID_RE.match(args.release_id)), "invalid release id")
    require(bool(gate.HEX40.match(args.source_sha)), "invalid source sha")
    release_id = int(args.release_id)
    root = Path(args.dir)
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    (root / SUMS).unlink(missing_ok=True)
    tool.assemble(argparse.Namespace(
        dir=str(root), platforms=args.platforms, source_sha=args.source_sha, quota_date=args.build_date,
        release_tag=tag, run_id=args.run_id, run_attempt="*", repository=api.repository,
        run_url=args.run_url, sums_out=str(work / SUMS), notes_out=str(work / "notes.md"),
        artifacts_out=str(work / "artifacts.json"), kind="release"))
    (root / SUMS).write_bytes((work / SUMS).read_bytes())
    files = sorted((p for p in root.iterdir() if p.is_file() and p.name != SUMS), key=lambda p: p.name)
    local = files + [root / SUMS]  # SHA256SUMS last: its presence marks a complete publication

    release = check_target(api, release_id, tag, args.source_sha)
    upload, delete, identical, conflicts = plan_uploads(local, api.assets(release_id))
    require(not conflicts, "release already has different assets named " + ", ".join(sorted(conflicts))
            + "; nothing was changed. Re-run only the failed jobs (reuses the signed packages) or remove "
              "those assets by hand.")
    for asset in delete:
        print(f"replacing interrupted upload {asset.get('name')} (state {asset.get('state')})")
        api.delete_asset(asset["id"])
    for path in upload:
        print(f"uploading {path.name} ({path.stat().st_size} bytes)")
        api.upload_asset(release, path)
    final = check_target(api, release_id, tag, args.source_sha)
    verify_published(api.assets(release_id), local)
    return {"release": final.get("html_url"), "release_id": release_id, "uploaded": [p.name for p in upload],
            "identical": identical, "replaced_partial": [a.get("name") for a in delete],
            "sha256sums": (work / SUMS).read_text(encoding="utf-8")}


# ------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    env = os.environ

    p = sub.add_parser("prepare")
    p.add_argument("--repo", default=".")
    p.add_argument("--remote", default="origin")
    p.add_argument("--platform", required=True, help="client platform: " + ", ".join(gate.PLATFORMS))
    p.add_argument("--namespace", default="", help="default refs/atermius-ci/daily-build/<platform>")
    p.add_argument("--legacy-namespace", action="append", default=[],
                   help="pre-monorepo namespace: read-only versionCode floor and release bindings (Android)")
    p.add_argument("--branch", default="")
    p.add_argument("--rules", default="", help="default .github/daily-build/inputs/<platform>.txt")
    p.add_argument("--platforms", required=True)
    p.add_argument("--version-allocator", action="store_true")
    p.add_argument("--max-skew", type=int, default=gate.MAX_SKEW_DEFAULT)
    p.add_argument("--now", default="")
    p.add_argument("--server-date", default="")
    p.add_argument("--github-output", default=env.get("GITHUB_OUTPUT", ""))
    p.add_argument("--summary", default=env.get("GITHUB_STEP_SUMMARY", ""))

    p = sub.add_parser("publish")
    p.add_argument("--platform", required=True, help="client platform: " + ", ".join(gate.PLATFORMS))
    p.add_argument("--dir", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--platforms", required=True)

    args = parser.parse_args(argv)
    # Untrusted dispatch values and run identity come only from the environment.
    args.release_tag = env.get("ATERMIUS_RELEASE_TAG", "")
    args.release_id = env.get("ATERMIUS_RELEASE_ID", "")
    args.ref, args.run_sha = env.get("GITHUB_REF", ""), env.get("GITHUB_SHA", "")
    args.run_id, args.run_attempt = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "")
    args.repository = env.get("GITHUB_REPOSITORY", "")
    try:
        api = GitHub(args.repository, env.get("GH_TOKEN", ""), env.get("GITHUB_API_URL", "https://api.github.com"))
        if args.command == "prepare":
            require(bool(gate.HEX40.match(args.run_sha)), "GITHUB_SHA is not a commit id")
            emit(prepare(args, api), args.github_output, args.summary)
            return 0
        args.source_sha, args.build_date = env.get("ATERMIUS_SOURCE_SHA", ""), env.get("ATERMIUS_BUILD_DATE", "")
        args.run_url = f"{env.get('GITHUB_SERVER_URL', '')}/{args.repository}/actions/runs/{args.run_id}"
        result = publish(args, api)
        print(json.dumps({k: v for k, v in result.items() if k != "sha256sums"}, indent=2, sort_keys=True))
        if env.get("GITHUB_STEP_SUMMARY"):
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write(f"### Packages attached to {args.release_tag}\n\n{result['release']}\n\n```\n"
                             f"{result['sha256sums']}```\n")
        return 0
    except gate.ClockError as error:
        print(f"::warning::release build refused: {error}", file=sys.stderr)
        return 3
    except (gate.GateError, tool.ToolError, OSError, ValueError) as error:
        print(f"::error::release build refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
