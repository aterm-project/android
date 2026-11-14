#!/usr/bin/env python3
"""Offline policy lint for the monorepo's GitHub workflows (needs PyYAML).

Not a replacement for actionlint (run it too: see README.md); it enforces the
rules this CI design depends on:

* every `uses:` is pinned to a full commit SHA from the verified pin list;
* no pull_request_target / workflow_run triggers; workflow_dispatch inputs only
  on the release builds (release_tag, release_id);
* no `${{ ... }}` expression inside any `run:` script (values go through env);
* workflow-level permissions are empty or read-only; write scopes only on the
  daily gate/publish jobs, the release prepare/publish jobs, the release
  trigger (actions: write) and the manual main-only publication recovery job,
  never on a job that compiles code;
* compile and signing jobs check out with persist-credentials: false; matrices
  have max-parallel <= 2; every job has a timeout;
* contexts unavailable at job level (runner, steps, env) are not used in
  jobs.<id>.env / jobs.<id>.if; step references point to existing step ids;
* per platform (android, desktop, ios, web) daily-<platform>.yml runs on cron
  "0 0 * * *" + workflow_dispatch only, with its own non-cancelling
  concurrency group, ATERMIUS_PLATFORM / namespace / input rules of exactly
  that platform, the gate called with --platform, build/publish jobs guarded
  by the gate's build flag and claim attempt, and secrets only in a sign job;
* release-trigger.yml (release published) has one checkout-free job with
  actions: write only that skips daily tags (<platform>-daily-*, daily-*) and
  dispatches exactly the release-<platform>.yml workflows that exist;
  release-<platform>.yml takes only release_tag/release_id, every job is
  main-only, contents: write only on prepare/publish, the untrusted inputs
  reach only the prepare step's env, and secrets only the sign job;
* checks-*.yml: identical push / pull_request path filters that include the
  workflow itself; every client platform's checks include the shared client
  paths.

  python3 -I .github/daily-build/tests/lint_workflows.py [--root REPO]
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("daily_gate", HERE.parent / "daily_gate.py")
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

PINS = {
    "actions/checkout": {"11bd71901bbe5b1630ceea73d27597364c9af683", "11d5960a326750d5838078e36cf38b85af677262"},
    "actions/upload-artifact": {"ea165f8d65b6e75b540449e92b4886f43607fa02"},
    "actions/download-artifact": {"d3f86a106a0bac45b974a628896c90dbdf5c8093"},
    "actions/cache": {"5a3ec84eff668545956fd18022155c47e93e2684"},
}
WRITE_JOBS = {"gate", "publish"}
RELEASE_JOBS = {"prepare", "build", "sign", "publish"}
RELEASE_INPUTS = {"release_tag": True, "release_id": False}  # name -> required
MAIN_ONLY = "github.ref == 'refs/heads/main'"
DAILY_SKIPS = ("!startsWith(github.event.release.tag_name, 'daily-')",
               "!contains(github.event.release.tag_name, '-daily-')")
# Changes here run every client platform's checks (monorepo path-filter policy).
SHARED_CLIENT_PATHS = ("apps/client/lib/**", "apps/client/test/**", "apps/client/pubspec.*", "packages/**",
                       "protocol/**")
SERVER_PATHS = ("server/**", "deploy/**")
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
FILE_RE = re.compile(r"^(daily|release|checks)-([a-z0-9-]+)\.ya?ml$")


def triggers(doc: dict):
    # PyYAML (YAML 1.1) parses the key `on` as boolean True.
    return doc.get("on", doc.get(True))


def kind_of(name: str) -> tuple[str, str]:
    """(kind, platform) from the file name: daily/release/checks-<x>.yml, release-trigger.yml, ..."""
    if name in ("release-trigger.yml", "resume-publication.yml"):
        return name.split(".")[0], "android" if name.startswith("resume") else ""
    match = FILE_RE.match(name)
    return (match.group(1), match.group(2)) if match else ("other", "")


def run_text(job: dict) -> str:
    return "\n".join(str(step.get("run", "")) for step in job.get("steps") or [])


def lint_file(path: Path) -> list[str]:
    errors: list[str] = []
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    name = path.name
    kind, platform = kind_of(name)
    on = triggers(doc)
    events = [on] if isinstance(on, str) else list(on or [])
    env = doc.get("env") or {}
    jobs = doc.get("jobs") or {}
    for bad in ("pull_request_target", "workflow_run"):
        if bad in events:
            errors.append(f"{name}: trigger {bad} is not allowed")
    daily = kind == "daily"
    release_build = kind == "release" and platform != ""
    release_trigger = kind == "release-trigger"
    recovery = kind == "resume-publication"
    checks = kind == "checks"
    if (daily or release_build) and platform not in gate.PLATFORMS:
        errors.append(f"{name}: unknown platform {platform!r} (expected {', '.join(gate.PLATFORMS)})")
    if isinstance(on, dict) and isinstance(on.get("workflow_dispatch"), dict) and on["workflow_dispatch"].get("inputs"):
        inputs = on["workflow_dispatch"]["inputs"]
        if not release_build or set(on) != {"workflow_dispatch"} or not isinstance(inputs, dict) \
                or set(inputs) != set(RELEASE_INPUTS) or any(
                    (inputs[k] or {}).get("type") != "string" or bool((inputs[k] or {}).get("required")) != req
                    for k, req in RELEASE_INPUTS.items()):
            errors.append(f"{name}: workflow_dispatch must not take inputs "
                          "(only release-<platform>.yml: string release_tag (required), release_id)")
    if daily or release_build:
        expected = {"ATERMIUS_PLATFORM": platform, "ATERMIUS_DAILY_NAMESPACE": gate.platform_namespace(platform)}
        if daily:
            expected["ATERMIUS_DAILY_RULES"] = gate.platform_rules(platform)
        for key, value in expected.items():
            if env.get(key) != value:
                errors.append(f"{name}: env {key} must be {value!r} (got {env.get(key)!r})")
        conc = doc.get("concurrency") or {}
        if not conc.get("group") or conc.get("cancel-in-progress") is not False:
            errors.append(f"{name}: needs a non-cancelling concurrency group")
        if f"-{platform}-" not in str(conc.get("group", "")):
            errors.append(f"{name}: concurrency group must name the platform ({platform})")
        targets = ",".join(gate.PLATFORMS.get(platform, ()))
        for job_id, job in jobs.items():
            text = run_text(job)
            for script in ("daily_gate.py gate", "release_build.py prepare", "release_build.py publish"):
                if script in text and '--platform "$ATERMIUS_PLATFORM"' not in text:
                    errors.append(f"{name}:{job_id}: {script} must get --platform \"$ATERMIUS_PLATFORM\"")
            if "release_build.py" in text and f"--platforms {targets}" not in text:
                errors.append(f"{name}:{job_id}: release_build.py needs --platforms {targets}")
            platforms_env = (job.get("env") or {}).get("ATERMIUS_PLATFORMS")
            if platforms_env is not None and str(platforms_env) != targets:
                errors.append(f"{name}:{job_id}: ATERMIUS_PLATFORMS must be {targets}")
            if "secrets." in yaml.safe_dump(job) and job_id != "sign":
                errors.append(f"{name}:{job_id}: secrets are only for the sign job")
            if "environment" in job and job_id != "sign":
                errors.append(f"{name}:{job_id}: deployment environments are only for the sign job")
    if release_build:
        if not isinstance(on, dict) or set(on) != {"workflow_dispatch"}:
            errors.append(f"{name}: release build must be started only by workflow_dispatch")
        if not {"prepare", "build", "publish"} <= set(jobs) or not set(jobs) <= RELEASE_JOBS:
            errors.append(f"{name}: jobs must be prepare, build, [sign,] publish")
        for job_id, job in jobs.items():
            text = yaml.safe_dump({k: v for k, v in job.items() if k != "steps"}) + "".join(
                yaml.safe_dump({k: v for k, v in step.items() if k != "env" or job_id != "prepare"})
                for step in job.get("steps") or [])
            if re.search(r"\binputs\.|github\.event", text):
                errors.append(f"{name}:{job_id}: dispatch inputs may only reach the prepare step env")
    if release_trigger:
        job = jobs.get("dispatch") or {}
        if on != {"release": {"types": ["published"]}} or set(jobs) != {"dispatch"}:
            errors.append(f"{name}: must run only on release published with one dispatch job")
        if job.get("permissions") != {"actions": "write"} or any(s.get("uses") for s in job.get("steps") or []) \
                or not all(skip in str(job.get("if", "")) for skip in DAILY_SKIPS) \
                or "secrets." in yaml.safe_dump(job):
            errors.append(f"{name}: dispatch job needs the daily-* and *-daily-* skips, actions: write only, "
                          "no actions/secrets")
    top = doc.get("permissions")
    if top not in ({}, "read-all") and not (isinstance(top, dict) and set(top.values()) <= {"read", "none"}):
        errors.append(f"{name}: workflow-level permissions must be empty or read-only")
    if recovery:
        if not isinstance(on, dict) or on != {"workflow_dispatch": {}}:
            errors.append(f"{name}: recovery must be manual only, without inputs")
        if set(jobs) != {"publish"}:
            errors.append(f"{name}: recovery may contain only the publication job")
        job_env = (jobs.get("publish") or {}).get("env") or {}
        if job_env.get("ATERMIUS_DAILY_NAMESPACE") != gate.LEGACY_NAMESPACE or job_env.get("ATERMIUS_PLATFORM") != "android":
            errors.append(f"{name}: recovery works on the pre-monorepo android claim ({gate.LEGACY_NAMESPACE})")
    if daily:
        if not isinstance(on, dict) or set(on) != {"schedule", "workflow_dispatch"} \
                or on["schedule"] != [{"cron": "0 0 * * *"}]:
            errors.append(f"{name}: must run only on cron '0 0 * * *' and workflow_dispatch")
        if "gate" not in jobs:
            errors.append(f"{name}: gate job missing")
    if checks:
        filters = [(on or {}).get(event) if isinstance(on, dict) else None for event in ("push", "pull_request")]
        paths = [(f or {}).get("paths") if isinstance(f, dict) else None for f in filters]
        if not paths[0] or paths[0] != paths[1]:
            errors.append(f"{name}: push and pull_request need the same non-empty paths filter")
        elif not any(gate.glob_regex(str(x)).match(f".github/workflows/{name}") for x in paths[0]
                     if not str(x).startswith("!")):
            errors.append(f"{name}: its paths filter must include the workflow file itself")
        elif platform in gate.PLATFORMS and not set(SHARED_CLIENT_PATHS) <= set(paths[0]):
            errors.append(f"{name}: client checks must run for the shared client paths {list(SHARED_CLIENT_PATHS)}")
        elif platform == "server" and not set(SERVER_PATHS) <= set(paths[0]):
            errors.append(f"{name}: server checks must run for {list(SERVER_PATHS)}")
    for job_id, job in jobs.items():
        where = f"{name}:{job_id}"
        if "timeout-minutes" not in job:
            errors.append(f"{where}: timeout-minutes missing")
        perms = job.get("permissions", top)
        writes = sorted(k for k, v in (perms or {}).items() if v == "write") if isinstance(perms, dict) else []
        release_writer = (release_build and job_id in {"prepare", "publish"} and writes == ["contents"]) or \
            (release_trigger and job_id == "dispatch" and writes == ["actions"])
        if release_build and (MAIN_ONLY not in str(job.get("if", "")) or (
                job_id != "prepare" and "needs.prepare.outputs.build == 'true'" not in str(job.get("if", "")))):
            errors.append(f"{where}: must be main-only and guarded by the prepare build flag")
        if perms == "write-all" or (writes and not ((daily and job_id in WRITE_JOBS) or (recovery and job_id == "publish")
                                                    or release_writer)):
            errors.append(f"{where}: write permission {writes or perms} not allowed on this job")
        if daily and job_id in WRITE_JOBS and writes not in ([], ["contents"]):
            errors.append(f"{where}: only contents: write is allowed, got {writes}")
        if recovery and (perms != {"contents": "write", "actions": "read"} or
                         str(job.get("if", "")) != MAIN_ONLY):
            errors.append(f"{where}: recovery needs main-only guard, contents:write and actions:read only")
        if daily and job_id != "gate":
            guard = str(job.get("if", ""))
            if "needs.gate.outputs.build == 'true'" not in guard or \
                    "needs.gate.outputs.claim_run_attempt == github.run_attempt" not in guard:
                errors.append(f"{where}: must be guarded by the gate build flag and claim attempt")
        strategy = job.get("strategy") or {}
        if strategy.get("matrix") is not None and not (isinstance(strategy.get("max-parallel"), int)
                                                      and strategy["max-parallel"] <= 2):
            errors.append(f"{where}: matrix needs max-parallel <= 2")
        for key in ("env", "if"):
            text = yaml.safe_dump(job.get(key, "")) if key == "env" else str(job.get(key, ""))
            for expr in EXPR.findall(text) if key == "env" else [text]:
                if re.search(r"\b(runner|steps|env|job)\.", expr):
                    errors.append(f"{where}: {key} uses a context unavailable at job level: {expr.strip()}")
        step_ids = set()
        compiles = (daily and job_id not in WRITE_JOBS) or (release_build and job_id != "prepare")
        for index, step in enumerate(job.get("steps") or []):
            label = f"{where}:step{index + 1}"
            run = step.get("run")
            if run is not None and "${{" in run:
                errors.append(f"{label}: expression inside run: (pass it through env)")
            uses = step.get("uses")
            if uses:
                action, _, ref = uses.partition("@")
                if not re.fullmatch(r"[0-9a-f]{40}", ref):
                    errors.append(f"{label}: {uses} is not pinned to a commit SHA")
                elif action in PINS and ref not in PINS[action]:
                    errors.append(f"{label}: {uses} is not a verified pin")
                elif action not in PINS:
                    errors.append(f"{label}: action {action} is not in the verified pin list")
                with_ = step.get("with") or {}
                if action == "actions/checkout" and compiles and job_id != "sign" \
                        and with_.get("persist-credentials") is not False:
                    errors.append(f"{label}: compile jobs must use persist-credentials: false")
                if action == "actions/checkout" and job_id == "sign" and with_.get("persist-credentials") is not False:
                    errors.append(f"{label}: signing job must use persist-credentials: false")
            for expr in EXPR.findall(yaml.safe_dump(step)):
                for ref_id in re.findall(r"steps\.([A-Za-z0-9_-]+)\.", expr):
                    if ref_id not in step_ids:
                        errors.append(f"{label}: references unknown/later step id {ref_id}")
                if "secrets." in expr and not (step.get("env") and any("secrets." in str(v) for v in step["env"].values())):
                    errors.append(f"{label}: secrets may only be passed through step env")
            if step.get("id"):
                step_ids.add(step["id"])
        for value in (job.get("outputs") or {}).values():
            for ref_id in re.findall(r"steps\.([A-Za-z0-9_-]+)\.", str(value)):
                if ref_id not in step_ids:
                    errors.append(f"{where}: output references unknown step id {ref_id}")
    return errors


def lint_repo(files: list[Path]) -> list[str]:
    """Rules across files: one daily workflow per platform with distinct concurrency groups, the
    recovery in the Android daily group, and the release trigger dispatching exactly the release
    builds that exist."""
    errors: list[str] = []
    docs = {f.name: yaml.safe_load(f.read_text(encoding="utf-8")) for f in files}
    groups = {}
    for name, doc in docs.items():
        if kind_of(name)[0] == "daily":
            groups[name] = str((doc.get("concurrency") or {}).get("group", ""))
    for platform in gate.PLATFORMS:
        if f"daily-{platform}.yml" not in docs:
            errors.append(f"daily-{platform}.yml is missing")
    if len(set(groups.values())) != len(groups):
        errors.append(f"daily workflows share a concurrency group: {groups}")
    recovery = docs.get("resume-publication.yml")
    if recovery is not None and str((recovery.get("concurrency") or {}).get("group")) != groups.get("daily-android.yml"):
        errors.append("resume-publication.yml must share the concurrency group of daily-android.yml")
    releases = sorted(n for n in docs if kind_of(n)[0] == "release" and kind_of(n)[1])
    trigger = docs.get("release-trigger.yml")
    if releases and trigger is None:
        errors.append("release-trigger.yml is missing")
    if trigger is not None:
        script = run_text((trigger.get("jobs") or {}).get("dispatch") or {})
        dispatched = sorted(set(re.findall(r"\brelease-[a-z0-9]+\.yml\b", script)))
        if dispatched != releases:
            errors.append(f"release-trigger.yml dispatches {dispatched}, but the release builds are {releases}")
        for name in releases:
            platform = kind_of(name)[1]
            if f"{platform}-?*) workflow={name} ;;" not in script:
                errors.append(f"release-trigger.yml must route {platform}-* tags to {name}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    files = sorted(Path(args.root, ".github", "workflows").glob("*.y*ml"))
    errors = [e for f in files for e in lint_file(f)] + lint_repo(files)
    for error in errors:
        print(error)
    print(f"{len(files)} workflow file(s), {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
