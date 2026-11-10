#!/usr/bin/env python3
"""Daily build gate: UTC-day build quota + success baseline, stored in git refs.

Standard library only; drives the git CLI. The same file is used by the four
Atermius client repositories (android, desktop, ios, web) and is exercised
offline by tests/test_daily_gate.py against local bare repositories.

Policy (adjust here or through the CLI flags the workflow passes; see README.md)
------------------------------------------------------------------------------
* Checkpoint: the workflow's ``schedule`` trigger (cron ``0 0 * * *``, UTC).
  GitHub starts scheduled runs at or after that minute -- usually minutes late,
  sometimes much later, occasionally not at all under load. The quota day is
  therefore the UTC date *when the gate runs*, never the cron time.
* Quota: ``--daily-quota`` build attempts per UTC day (default 1) per quota
  remote (default: this repository, i.e. "each client repository once a day").
  A real build attempt consumes a slot whether it later succeeds or fails; a
  gate run that only checks and skips consumes nothing.
* Change detection: a fingerprint over the product/packaging input files of
  the default-branch tip (rules in ``.github/daily-build/inputs.txt`` *of that
  tip*), compared with the fingerprint stored in the success baseline. It never
  looks at workflow-run history, so test-only CI runs or skipped gates cannot
  be mistaken for a build.
* Baseline: moved only by ``advance``, which the publish job calls after the
  artifacts were compiled AND published.

State (refs on the state remote; quota refs may live on a separate remote)
-------------------------------------------------------------------------
  <ns>/quota/<YYYY-MM-DD>/<slot>  one claim record per build attempt; created
                                  by an atomic compare-and-swap push that
                                  requires the ref to be absent; never moved.
  <ns>/baseline                   last build that was compiled and published;
                                  updated only by compare-and-swap.

A record is a commit object whose tree is the source tree (so it changes no
file relative to its first parent), whose first parent is the source commit
(keeping it reachable even if the branch is rewritten) and, for the baseline,
whose second parent is the previous baseline record. The message is a title
line followed by one JSON document.

Exit status: 0 decision made (build or skip) / command succeeded,
             1 refused (precondition, verification or infrastructure error),
             3 refused because runner clock and GitHub Date disagree (retry).
"""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = "atermius-daily-build/1"
DEFAULT_NAMESPACE = "refs/atermius-ci/daily-build"
DEFAULT_RULES = ".github/daily-build/inputs.txt"
CI_DEFINITION_DIR = ".github"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NAMESPACE_RE = re.compile(r"^refs/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
MAX_SKEW_DEFAULT = 120
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"


class GateError(Exception):
    """Refusal: configuration, verification or infrastructure problem."""


class ClockError(GateError):
    """Refusal because the quota day is ambiguous; retrying shortly is safe."""


# --------------------------------------------------------------------------- git


def _git_env() -> dict[str, str]:
    env = dict(os.environ)
    env.update(GIT_TERMINAL_PROMPT="0", LC_ALL="C", GIT_OPTIONAL_LOCKS="0")
    return env


def git(repo: Path, *args: str, check: bool = True, stdin: str | None = None,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["git", "-c", "core.quotepath=off", *args], cwd=repo, input=stdin,
        capture_output=True, text=True, env=env or _git_env(),
    )
    if check and proc.returncode != 0:
        raise GateError(f"git {args[0]} failed ({proc.returncode}): {proc.stderr.strip()[-600:]}")
    return proc


def ls_remote(repo: Path, remote: str, patterns: list[str]) -> dict[str, str]:
    out = git(repo, "ls-remote", remote, *patterns).stdout
    refs: dict[str, str] = {}
    for line in out.splitlines():
        sha, _, name = line.partition("\t")
        if HEX40.match(sha) and name:
            refs[name] = sha
    return refs


def remote_default_branch(repo: Path, remote: str) -> str:
    out = git(repo, "ls-remote", "--symref", remote, "HEAD").stdout
    for line in out.splitlines():
        if line.startswith("ref: ") and line.endswith("\tHEAD"):
            ref = line[5:].split("\t", 1)[0]
            if ref.startswith("refs/heads/"):
                return ref[len("refs/heads/"):]
    raise GateError("cannot determine the remote default branch (ls-remote --symref HEAD)")


def has_object(repo: Path, sha: str, kind: str = "commit") -> bool:
    return git(repo, "cat-file", "-e", f"{sha}^{{{kind}}}", check=False).returncode == 0


def fetch_shas(repo: Path, remote: str, shas: list[str]) -> None:
    missing = [s for s in dict.fromkeys(shas) if s and not has_object(repo, s)]
    if missing:
        git(repo, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--depth=1", remote, *missing)


def tree_of(repo: Path, rev: str, path: str = "") -> str | None:
    proc = git(repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{tree}}" if not path else f"{rev}:{path}",
               check=False)
    out = proc.stdout.strip()
    return out if proc.returncode == 0 and HEX40.match(out) else None


def cas_push(repo: Path, remote: str, ref: str, new: str, expect: str | None) -> str:
    """Atomic compare-and-swap of a remote ref. Returns "ok" or "conflict".

    ``expect=None`` means the ref must not exist. git sends the expected old
    value in the push command and the receiving side applies the update under
    its ref lock only if the current value still matches, so concurrent jobs
    cannot both win.
    """
    lease = f"--force-with-lease={ref}:{expect or ''}"
    proc = git(repo, "push", "--porcelain", "--no-verify", remote, lease, f"{new}:{ref}", check=False)
    if proc.returncode == 0:
        return "ok"
    current = ls_remote(repo, remote, [ref]).get(ref)
    if current == new:
        return "ok"  # applied, but the client did not see the acknowledgement
    if current != expect:
        return "conflict"
    raise GateError(f"push to {ref} failed: {(proc.stderr or proc.stdout).strip()[-600:]}")


# ------------------------------------------------------------------ input rules


def glob_regex(pattern: str) -> re.Pattern[str]:
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


class Rules:
    """``+ glob`` includes, ``- glob`` excludes; the last matching rule wins;
    unmatched paths are excluded. Globs are anchored at the repository root:
    ``*``/``?`` stay within one path segment, ``**`` crosses segments."""

    def __init__(self, text: str):
        self.version = "1"
        self.rules: list[tuple[bool, str, re.Pattern[str]]] = []
        for number, raw in enumerate(text.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("version "):
                self.version = line.split(None, 1)[1].strip()
                continue
            sign, _, pattern = line.partition(" ")
            pattern = pattern.strip()
            if sign not in "+-" or len(sign) != 1 or not pattern or pattern.startswith("/") or ".." in pattern.split("/"):
                raise GateError(f"inputs rule line {number} is invalid: {raw!r}")
            self.rules.append((sign == "+", pattern, glob_regex(pattern)))
        if not any(include for include, _, _ in self.rules):
            raise GateError("inputs rules include nothing")

    def canonical(self) -> str:
        return "version " + self.version + "\n" + "".join(
            ("+ " if inc else "- ") + pat + "\n" for inc, pat, _ in self.rules)

    def match(self, path: str) -> bool:
        selected = False
        for include, _, regex in self.rules:
            if regex.match(path):
                selected = include
        return selected


def tree_entries(repo: Path, rev: str) -> dict[str, tuple[str, str, str]]:
    out = git(repo, "ls-tree", "-r", "-z", "--full-tree", rev).stdout
    entries = {}
    for item in out.split("\0"):
        if not item:
            continue
        meta, _, path = item.partition("\t")
        mode, kind, oid = meta.split()
        entries[path] = (mode, kind, oid)
    return entries


def load_rules(repo: Path, rev: str, rules_path: str) -> Rules:
    proc = git(repo, "show", f"{rev}:{rules_path}", check=False)
    if proc.returncode != 0:
        raise GateError(f"{rules_path} is missing at {rev[:12]}")
    return Rules(proc.stdout)


def fingerprint(repo: Path, rev: str, rules_path: str = DEFAULT_RULES) -> dict:
    rules = load_rules(repo, rev, rules_path)
    selected = {p: e for p, e in tree_entries(repo, rev).items() if rules.match(p)}
    if not selected:
        raise GateError("inputs rules select no file")
    digest = hashlib.sha256()
    digest.update(f"{SCHEMA}\n{rules.canonical()}\n".encode())
    for path in sorted(selected):
        mode, kind, oid = selected[path]
        digest.update(f"{mode} {kind} {oid}\t{path}\n".encode())
    return {
        "fingerprint": digest.hexdigest(),
        "input_files": len(selected),
        "rules_sha256": hashlib.sha256(rules.canonical().encode()).hexdigest(),
        "_entries": selected,
        "_rules": rules,
    }


def changed_inputs(repo: Path, old_rev: str, new_entries: dict, rules: Rules) -> list[str]:
    old = {p: e for p, e in tree_entries(repo, old_rev).items() if rules.match(p)}
    return sorted(p for p in set(old) | set(new_entries) if old.get(p) != new_entries.get(p))


# --------------------------------------------------------------------- records


def utc_iso(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_record(repo: Path, source: str, parents: list[str], payload: dict, when: dt.datetime) -> str:
    tree = tree_of(repo, source)
    if not tree:
        raise GateError(f"source commit {source[:12]} is not available locally")
    title = f"atermius daily-build {payload['kind']} {payload.get('quota_date', '')}".rstrip()
    message = title + "\n\n" + json.dumps(payload, indent=2, sort_keys=True) + "\n"
    stamp = f"{int(when.timestamp())} +0000"
    env = _git_env()
    env.update(GIT_AUTHOR_NAME=BOT_NAME, GIT_AUTHOR_EMAIL=BOT_EMAIL, GIT_AUTHOR_DATE=stamp,
               GIT_COMMITTER_NAME=BOT_NAME, GIT_COMMITTER_EMAIL=BOT_EMAIL, GIT_COMMITTER_DATE=stamp)
    args = ["commit-tree", "--no-gpg-sign", tree]
    for parent in parents:
        args += ["-p", parent]
    sha = git(repo, *args, "-F", "-", stdin=message, env=env).stdout.strip()
    if not HEX40.match(sha):
        raise GateError("commit-tree returned no object id")
    return sha


def read_record(repo: Path, sha: str, kind: str) -> dict:
    raw = git(repo, "cat-file", "commit", sha).stdout
    _, _, message = raw.partition("\n\n")
    _, _, body = message.partition("\n\n")
    try:
        data = json.loads(body)
    except ValueError as error:
        raise GateError(f"{kind} record {sha[:12]} is not valid JSON: {error}") from None
    if not isinstance(data, dict) or data.get("schema") != SCHEMA or data.get("kind") != kind:
        raise GateError(f"{kind} record {sha[:12]} has an unexpected schema/kind")
    for key in ("source_sha", "fingerprint"):
        if not isinstance(data.get(key), str) or not (HEX40 if key == "source_sha" else HEX64).match(data[key]):
            raise GateError(f"{kind} record {sha[:12]} has an invalid {key}")
    return data


# ------------------------------------------------------------------------ clock


def resolve_now(now_arg: str | None, server_date: str | None, max_skew: int) -> tuple[dt.datetime, str]:
    """The runner clock (UTC) decides the quota day. A fresh GitHub server Date
    header, when given, must be within ``max_skew`` seconds AND on the same UTC
    date; otherwise the gate refuses (ClockError) instead of guessing a day."""
    if now_arg:  # tests and replays
        moment = dt.datetime.fromisoformat(now_arg.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            raise GateError("--now needs an explicit UTC offset")
        local = moment.astimezone(dt.timezone.utc)
    else:
        local = dt.datetime.now(dt.timezone.utc)
    if not server_date:
        return local, "runner-clock"
    try:
        server = email.utils.parsedate_to_datetime(server_date).astimezone(dt.timezone.utc)
    except (TypeError, ValueError):
        raise ClockError(f"unparseable server Date header {server_date!r}") from None
    skew = abs((server - local).total_seconds())
    if skew > max_skew:
        raise ClockError(f"runner clock differs from the GitHub server Date by {skew:.0f}s (> {max_skew}s); "
                         "refusing to pick a quota day")
    if server.date() != local.date():
        raise ClockError(f"runner UTC date {local.date()} and GitHub server date {server.date()} disagree "
                         "(midnight boundary or cached Date); refusing to pick a quota day")
    return local, "runner-clock+github-date"


def test_sync() -> None:
    """Offline race tests only: ATERMIUS_GATE_TEST_SYNC=<dir>:<n> makes n gate
    processes rendezvous right before they try to claim."""
    spec = os.environ.get("ATERMIUS_GATE_TEST_SYNC")
    if not spec:
        return
    directory, _, count = spec.rpartition(":")
    Path(directory, f"{os.getpid()}.ready").touch()
    deadline = time.monotonic() + 30
    while len(list(Path(directory).glob("*.ready"))) < int(count):
        if time.monotonic() > deadline:
            raise GateError("test rendezvous timed out")
        time.sleep(0.01)


# ----------------------------------------------------------------------- output


def emit(result: dict, github_output: str | None, summary: str | None) -> None:
    public = {k: v for k, v in result.items() if not k.startswith("_")}
    print(json.dumps(public, indent=2, sort_keys=True))
    if github_output:
        keys = ("build", "reason", "source_sha", "short_sha", "quota_date", "quota_slot", "claim_ref",
                "claim_record", "claim_run_attempt", "fingerprint", "baseline_record", "version_code",
                "release_tag")
        with open(github_output, "a", encoding="utf-8") as handle:
            for key in keys:
                value = result.get(key)
                value = "" if value is None else str(value).lower() if isinstance(value, bool) else str(value)
                if "\n" in value or "\r" in value:
                    raise GateError(f"output {key} contains a newline")
                handle.write(f"{key}={value}\n")
    if summary:
        lines = [f"### Daily build gate: {'BUILD' if result.get('build') else 'skip'} ({result.get('reason')})", "",
                 "| key | value |", "| --- | --- |"]
        for key in ("quota_date", "clock_source", "event", "source_sha", "quota_used_before", "daily_quota",
                    "inputs_changed", "input_files", "fingerprint", "baseline_source_sha", "claim_ref",
                    "release_tag", "detail"):
            if result.get(key) not in (None, ""):
                lines.append(f"| {key} | `{str(result[key]).replace('|', '/')}` |")
        changed = result.get("changed_inputs") or []
        if changed:
            lines += ["", f"Changed inputs ({result.get('changed_input_count')}, first {len(changed)}):", ""]
            lines += [f"- `{p}`" for p in changed]
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------- commands


def validate_common(args: argparse.Namespace) -> None:
    if not NAMESPACE_RE.match(args.namespace) or args.namespace.startswith(("refs/heads/", "refs/pull/")):
        raise GateError(f"invalid state namespace {args.namespace!r}")
    if args.branch and not BRANCH_RE.match(args.branch):
        raise GateError("invalid --branch")


def cmd_fingerprint(args: argparse.Namespace) -> int:
    info = fingerprint(Path(args.repo), args.rev, args.rules)
    print(json.dumps({k: v for k, v in info.items() if not k.startswith("_")}, indent=2, sort_keys=True))
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    validate_common(args)
    repo = Path(args.repo)
    quota_remote = args.quota_remote or args.remote
    if not 1 <= args.daily_quota <= 9:
        raise GateError("--daily-quota must be 1..9")
    now, clock = resolve_now(args.now, args.server_date, args.max_skew)
    date = now.date().isoformat()
    result: dict = {
        "schema": SCHEMA, "build": False, "reason": None, "checked_at": utc_iso(now), "clock_source": clock,
        "quota_date": date, "daily_quota": args.daily_quota, "event": args.event, "run_id": args.run_id,
        "run_attempt": args.run_attempt, "repository": args.repository,
    }

    def skip(reason: str, detail: str = "") -> int:
        result.update(reason=reason, detail=detail)
        emit(result, args.github_output, args.summary)
        return 0

    branch = remote_default_branch(repo, args.remote)
    if args.branch and args.branch != branch:
        raise GateError(f"configured release branch {args.branch!r} is not the remote default {branch!r}")
    if args.ref != f"refs/heads/{branch}":
        return skip("not-default-branch", f"{args.ref} is not refs/heads/{branch}; release builds only run from it")

    ns = args.namespace
    quota_prefix = f"{ns}/quota/{date}/"
    patterns = [f"refs/heads/{branch}", f"{ns}/baseline"]
    if quota_remote == args.remote:
        patterns.append(quota_prefix + "*")
    refs = ls_remote(repo, args.remote, patterns)
    quota_refs = refs if quota_remote == args.remote else ls_remote(repo, quota_remote, [quota_prefix + "*"])
    used = sorted(r for r in quota_refs if r.startswith(quota_prefix))
    tip = refs.get(f"refs/heads/{branch}")
    if not tip:
        raise GateError(f"remote branch {branch} not found")
    baseline_sha = refs.get(f"{ns}/baseline")
    fetch_shas(repo, args.remote, [tip] + ([baseline_sha] if baseline_sha else []))
    result.update(source_sha=tip, short_sha=tip[:12], quota_used_before=len(used))

    # The jobs of this run use the scripts of the commit they build; refuse if
    # the CI definition of the tip differs from the one this run was started with.
    if args.run_sha != tip:
        if not has_object(repo, args.run_sha):
            raise GateError(f"run commit {args.run_sha[:12]} is not available locally")
        if tree_of(repo, args.run_sha, CI_DEFINITION_DIR) != tree_of(repo, tip, CI_DEFINITION_DIR):
            return skip("ci-definition-changed",
                        f"{CI_DEFINITION_DIR}/ differs between this run ({args.run_sha[:12]}) and {branch} "
                        f"({tip[:12]}); the next checkpoint uses the new definition")

    info = fingerprint(repo, tip, args.rules)
    result.update(fingerprint=info["fingerprint"], input_files=info["input_files"])
    baseline = read_record(repo, baseline_sha, "baseline") if baseline_sha else None
    result["baseline_record"] = baseline_sha or ""
    if baseline:
        result["baseline_source_sha"] = baseline["source_sha"]
        changed = changed_inputs(repo, baseline_sha, info["_entries"], info["_rules"])
        result.update(changed_input_count=len(changed), changed_inputs=changed[:50])
        result["inputs_changed"] = baseline["fingerprint"] != info["fingerprint"]
        if not result["inputs_changed"]:
            return skip("no-input-changes",
                        f"inputs of {tip[:12]} equal the last successful build of {baseline['source_sha'][:12]}")
    else:
        result["inputs_changed"] = True

    if len(used) >= args.daily_quota:
        return skip("quota-used", f"{len(used)}/{args.daily_quota} build attempt(s) already claimed for {date} "
                                  f"UTC; the next checkpoint is {date} + 1 day 00:00 UTC")

    missing = [name for name in args.require_env if not os.environ.get(name)]
    if missing:
        raise GateError("release prerequisites are not configured: " + ", ".join(missing)
                        + " (see .github/daily-build/README.md); nothing was claimed")

    payload = {
        "schema": SCHEMA, "kind": "quota", "repository": args.repository, "quota_date": date,
        "claimed_at": utc_iso(now), "clock_source": clock, "branch": branch, "source_sha": tip,
        "fingerprint": info["fingerprint"], "input_files": info["input_files"],
        "rules_sha256": info["rules_sha256"], "baseline_before": baseline_sha or None,
        "run_id": args.run_id, "run_attempt": args.run_attempt, "event": args.event,
        "workflow": args.workflow, "daily_quota": args.daily_quota,
    }
    test_sync()
    taken = {int(r.rsplit("/", 1)[1]) for r in used if r.rsplit("/", 1)[1].isdigit()}
    for slot in range(1, args.daily_quota + 1):
        if slot in taken:
            continue
        payload["slot"] = slot
        record = make_record(repo, tip, [tip], payload, now)
        ref = f"{quota_prefix}{slot}"
        if cas_push(repo, quota_remote, ref, record, None) == "ok":
            compact = date.replace("-", "")
            result.update(
                build=True, reason="claimed", quota_slot=slot, claim_ref=ref, claim_record=record,
                claim_run_attempt=args.run_attempt, version_code=int(compact) * 100 + slot,
                release_tag=f"daily-{compact}.{slot}-{tip[:12]}",
                detail=f"claimed {ref}; this attempt counts for {date} UTC whether it succeeds or fails")
            emit(result, args.github_output, args.summary)
            return 0
    return skip("quota-used-race", f"another run claimed the last free slot for {date} at the same time")


def verify_claim(repo: Path, remote: str, args: argparse.Namespace) -> dict:
    if not DATE_RE.match(args.quota_date) or not HEX40.match(args.claim_record):
        raise GateError("invalid --quota-date/--claim-record")
    ref = f"{args.namespace}/quota/{args.quota_date}/{args.slot}"
    current = ls_remote(repo, remote, [ref]).get(ref)
    if current != args.claim_record:
        raise GateError(f"{ref} is {current or 'absent'}, not this run's claim {args.claim_record[:12]}")
    fetch_shas(repo, remote, [current])
    record = read_record(repo, current, "quota")
    mismatch = [k for k, v in (("run_id", args.run_id), ("run_attempt", args.run_attempt),
                               ("source_sha", args.source_sha)) if v and str(record.get(k)) != str(v)]
    if mismatch:
        raise GateError(f"claim {ref} belongs to another run/attempt/source ({', '.join(mismatch)}); "
                        "a re-run never builds or publishes again")
    return record


def cmd_check_claim(args: argparse.Namespace) -> int:
    validate_common(args)
    record = verify_claim(Path(args.repo), args.quota_remote or args.remote, args)
    print(json.dumps({"claim": "valid", "source_sha": record["source_sha"], "quota_date": record["quota_date"],
                      "run_id": record["run_id"], "run_attempt": record["run_attempt"]}, sort_keys=True))
    return 0


def cmd_advance(args: argparse.Namespace) -> int:
    validate_common(args)
    repo = Path(args.repo)
    claim = verify_claim(repo, args.quota_remote or args.remote, args)
    source = claim["source_sha"]
    artifacts = json.loads(Path(args.artifacts).read_text(encoding="utf-8"))
    if not isinstance(artifacts, list) or not artifacts or not all(
            isinstance(a, dict) and isinstance(a.get("name"), str) and HEX64.match(str(a.get("sha256", "")))
            for a in artifacts):
        raise GateError("--artifacts must be a non-empty JSON list of {name, sha256, size}")
    if not has_object(repo, source):
        fetch_shas(repo, args.remote, [source])
    now, clock = resolve_now(args.now, None, MAX_SKEW_DEFAULT)
    ref = f"{args.namespace}/baseline"
    expect = None if args.expect_baseline in ("", "none") else args.expect_baseline
    ours = (claim["quota_date"], int(claim.get("slot", 1)))
    for _ in range(3):
        current = ls_remote(repo, args.remote, [ref]).get(ref)
        if current != expect:
            if current:
                fetch_shas(repo, args.remote, [current])
                other = read_record(repo, current, "baseline")
                if (other.get("quota_date", ""), int(other.get("slot", 1))) >= ours:
                    print(json.dumps({"baseline": "superseded", "current": current,
                                      "current_quota_date": other.get("quota_date")}, sort_keys=True))
                    return 0
            expect = current
        if expect:
            fetch_shas(repo, args.remote, [expect])  # parent 2 of the new record
        payload = {
            "schema": SCHEMA, "kind": "baseline", "repository": claim.get("repository"),
            "quota_date": claim["quota_date"], "slot": claim.get("slot", 1), "source_sha": source,
            "fingerprint": claim["fingerprint"], "input_files": claim.get("input_files"),
            "claim_record": args.claim_record, "run_id": claim["run_id"], "run_attempt": claim["run_attempt"],
            "release_tag": args.release_tag, "release_url": args.release_url, "published_at": utc_iso(now),
            "previous_baseline": expect, "artifacts": artifacts,
        }
        parents = [source] + ([expect] if expect else [])
        record = make_record(repo, source, parents, payload, now)
        if cas_push(repo, args.remote, ref, record, expect) == "ok":
            print(json.dumps({"baseline": "advanced", "record": record, "source_sha": source,
                              "previous": expect}, sort_keys=True))
            return 0
    raise GateError("baseline changed concurrently three times; not advanced")


def cmd_status(args: argparse.Namespace) -> int:
    validate_common(args)
    repo = Path(args.repo)
    refs = ls_remote(repo, args.remote, [f"{args.namespace}/baseline", f"{args.namespace}/quota/*"])
    status: dict = {"baseline": None, "quota": sorted(r.split("/quota/", 1)[1] for r in refs if "/quota/" in r)[-14:]}
    baseline = refs.get(f"{args.namespace}/baseline")
    if baseline:
        fetch_shas(repo, args.remote, [baseline])
        record = read_record(repo, baseline, "baseline")
        status["baseline"] = {k: record.get(k) for k in ("source_sha", "quota_date", "release_tag", "published_at")}
    print(json.dumps(status, indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", default=".")
        p.add_argument("--remote", default="origin", help="state remote (baseline; quota unless --quota-remote)")
        p.add_argument("--quota-remote", default="", help="optional separate remote for quota refs (shared quota)")
        p.add_argument("--namespace", default=DEFAULT_NAMESPACE)
        p.add_argument("--branch", default="", help="expected release branch (must be the remote default)")

    p = sub.add_parser("fingerprint")
    p.add_argument("--repo", default=".")
    p.add_argument("--rev", default="HEAD")
    p.add_argument("--rules", default=DEFAULT_RULES)
    p.set_defaults(func=cmd_fingerprint)

    p = sub.add_parser("gate")
    common(p)
    p.add_argument("--rules", default=DEFAULT_RULES)
    p.add_argument("--ref", required=True)
    p.add_argument("--run-sha", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--run-attempt", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--workflow", default="")
    p.add_argument("--repository", default="")
    p.add_argument("--daily-quota", type=int, default=1)
    p.add_argument("--server-date", default="", help="HTTP Date header from the GitHub API")
    p.add_argument("--max-skew", type=int, default=MAX_SKEW_DEFAULT)
    p.add_argument("--now", default="", help="override the clock (tests)")
    p.add_argument("--require-env", action="append", default=[])
    p.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    p.set_defaults(func=cmd_gate)

    for name, func in (("check-claim", cmd_check_claim), ("advance", cmd_advance)):
        p = sub.add_parser(name)
        common(p)
        p.add_argument("--quota-date", required=True)
        p.add_argument("--slot", type=int, default=1)
        p.add_argument("--claim-record", required=True)
        p.add_argument("--run-id", required=True)
        p.add_argument("--run-attempt", required=True)
        p.add_argument("--source-sha", default="")
        if name == "advance":
            p.add_argument("--expect-baseline", required=True, help="baseline record seen by the gate, or 'none'")
            p.add_argument("--release-tag", required=True)
            p.add_argument("--release-url", default="")
            p.add_argument("--artifacts", required=True, help="JSON file: [{name, sha256, size}]")
            p.add_argument("--now", default="")
        p.set_defaults(func=func)

    p = sub.add_parser("status")
    common(p)
    p.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    for key in ("run_sha", "claim_record"):
        value = getattr(args, key, None)
        if value is not None and not HEX40.match(value):
            parser.error(f"--{key.replace('_', '-')} must be a 40-hex commit id")
    try:
        return args.func(args)
    except ClockError as error:
        print(f"::warning::daily-build gate refused: {error}", file=sys.stderr)
        return 3
    except GateError as error:
        print(f"::error::daily-build gate refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
