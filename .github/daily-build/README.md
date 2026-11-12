# Daily build (one build attempt per UTC day)

`.github/workflows/daily-build.yml` builds release artifacts of this repository at most once per
UTC day, only from the default branch, and only when product/packaging inputs changed since the
last build that was **compiled and published**. Push/PR checks (`checks.yml`) are unaffected.

## When a build happens

| Trigger | Behaviour |
| --- | --- |
| `schedule` cron `0 0 * * *` (checkpoint) | Gate runs. GitHub starts scheduled runs at or after 00:00 UTC (often minutes late, sometimes much later, occasionally dropped under load); the cron does **not** guarantee a start to the second. |
| `workflow_dispatch` (no inputs) | Same gate, same quota. Dispatch from another branch only reports `not-default-branch`. |
| Re-run of a run | "Re-run all jobs" re-runs the gate: same UTC day ⇒ `quota-used`. "Re-run failed jobs" keeps the old gate result, so every build/sign/publish job is skipped (`claim_run_attempt != run_attempt`). |
| push / PR | Never builds here (only `checks.yml`). |

Gate decision (`daily_gate.py gate`, first match wins):

1. ref is not the remote default branch → skip `not-default-branch`;
2. `.github/` of the run commit differs from the branch tip → skip `ci-definition-changed` (all jobs use the scripts of the commit they build);
3. input fingerprint of the **tip** equals the baseline's → skip `no-input-changes`;
4. a claim already exists for today's UTC date → skip `quota-used`;
5. a required setting is missing (Android: signing cert pin) → **fail, nothing claimed**;
6. atomic claim of `quota/<date>/1` → **build**; losing the race → skip `quota-used-race`.

Skips exit 0 and consume nothing. The UTC day comes from the runner clock; a fresh, cache-busted
GitHub API `Date` header must be within 120 s **and** on the same UTC date, otherwise the gate exits 3
(nothing claimed) and the step retries 4× / 30 s, then fails.

## State (git refs, not caches/artifacts)

All state is in the repository itself under `refs/atermius-ci/daily-build/` (hidden from branch and
tag lists; `contents: write` of the gate/publish jobs only):

| Ref | Written by | Meaning |
| --- | --- | --- |
| `quota/<YYYY-MM-DD>/<slot>` | gate, compare-and-swap "must not exist" | one build attempt of that UTC day; never moved; a failed build still counts |
| `baseline` | publish, compare-and-swap on the value the gate saw | last build that compiled **and** published; chained to the previous baseline |

Each ref points at a record commit: tree = source tree (no file changes), parent 1 = source commit,
parent 2 (baseline) = previous baseline, message = JSON (source SHA, input fingerprint, run id/attempt,
release tag, artifact SHA-256 list). `git push --force-with-lease=<ref>:<expected>` makes the receiving
side apply the update only if the ref still has the expected value, so concurrent runs cannot both
claim a day or both move the baseline. Nothing depends on Actions caches, artifacts or run history.

Inspect: `git fetch origin 'refs/atermius-ci/*:refs/atermius-ci/*'` then
`python3 -I .github/daily-build/daily_gate.py status`.
Force a rebuild at the next checkpoint: delete the `baseline` ref. Old `quota/*` refs may be deleted
after a few days (only today's date is read).

## Release builds (published GitHub Releases)

Publishing a GitHub Release (or pre-release) whose tag is not `daily-*` attaches the Windows ZIP
(with `atermius_rdp.dll`), Linux tar.gz, macOS ad-hoc signed ZIP (with `libatermius_rdp.dylib`),
the engine licenses inside them, `evidence-*.json` and `SHA256SUMS` to **that** release. Manual
releases are built immediately: they neither check nor consume the daily quota, and the
once-a-day cron is unaffected.

| Workflow | Runs | Permissions |
| --- | --- | --- |
| `release-trigger.yml` | `release: published`; skips `daily-*`; no checkout; validates tag/id, then `gh workflow run release-build.yml --ref main` | `actions: write` |
| `release-build.yml` `prepare` | main only; `release_build.py prepare` | `contents: read` |
| `release-build.yml` `build` | the daily `build` matrix steps unchanged (`max-parallel: 2`) | `contents: read`, no persisted credentials |
| `release-build.yml` `publish` | `release_build.py publish` (REST API, no git push) | `contents: write` |

Trust: a `release` event runs the workflow file **of the tagged commit**, which may be unreviewed
(any writer can tag any commit, including a commit fetched from a fork's pull request: forks share
the object store). That workflow gets no checkout and no secrets and can only dispatch the
main-branch definition. `prepare` (main definition) treats the tag and release id as untrusted
strings (regex-checked, passed through env, never interpolated into scripts), requires a published
non-draft release whose id matches, peels the tag (annotated or lightweight) to **one** commit, and
refuses unless that commit is an ancestor of `main` and carries the same `recipe/` and
`release_tool.py` as the running workflow; every later job uses only that commit id. Forks cannot
dispatch upstream workflows; their own release events run in the fork.

Publication targets the release **id** from `prepare`: before and after uploading, the id must still
own the tag, the release must be published, and the tag must still resolve to the built commit.
Existing assets: identical name+size+SHA-256 digest ⇒ kept; same name in state `open` (interrupted
upload) ⇒ deleted and re-uploaded; same name with other content ⇒ refused before any change; other
names are never touched. `SHA256SUMS` is uploaded last; when it and every `evidence-<platform>.json`
are attached, a new dispatch skips as `already-published`. Resume with **Re-run failed jobs**:
successful platforms and their packages are reused (artifact names carry no attempt number). A full
re-run or new dispatch rebuilds, and its bytes may differ from assets already attached.

Manual start: Actions → Release build → Run workflow on `main` with the tag (needed for tags at
commits that predate `release-trigger.yml`). GitHub's "immutable releases" setting must stay off.
The Android repository additionally allocates its versionCode here; desktop builds have none.

## Inputs

`inputs.txt` (read from the commit being considered) selects product and packaging files; the
fingerprint is SHA-256 over their path/mode/blob ids plus the normalised rules. Tests, docs, `*.md`,
integration probes, gate/publish scripts and `checks.yml` are not inputs; the build scripts in
`recipe/`, `daily-build.yml` and the SDK installers are. Changing the rules causes one rebuild.

## Jobs and permissions

Workflow default `permissions: {}`; concurrency group per repository, never cancelling.

| Job | Permissions | Runs |
| --- | --- | --- |
| gate | `contents: write` | checkout + `daily_gate.py` only (claim ref push) |
| build (compiles) | `contents: read`, `persist-credentials: false` | Flutter/Gradle/CMake, plugin code |
| publish | `contents: write` | `publish.sh`: check claim, verify evidence/SHA-256, `gh release create`, advance baseline |

Actions are pinned to commit SHAs (checkout `11bd719…` v4.2.2, cache `5a3ec84…` v4.2.3,
upload-artifact `ea165f8…` v4.6.2, download-artifact `d3f86a1…` v4.3.0, verified by root via the GitHub
API). No `pull_request_target`, no dispatch inputs, no `${{ }}` inside `run:` scripts.

Build parallelism is capped at 2 per job (Gradle workers, CMake/Ninja/make, MSBuild, Xcode compile
tasks); matrices use `max-parallel: 2`.

## Output

A GitHub **pre-release** `daily-<YYYYMMDD>.<slot>-<sha12>` targeting the built commit, containing the
artifacts, `evidence-<platform>.json` (toolchain, runner image, checks, file digests) and `SHA256SUMS`.
The tag/release is never overwritten. Workflow artifacts (14 days) are only transport between jobs.
If publishing fails after the release was created, the baseline is not advanced and the next
checkpoint rebuilds (the extra release can be deleted by hand).

## Adjusting the policy

* Attempts per day: `ATERMIUS_DAILY_QUOTA` in the workflow `env` (1–9; slots `quota/<date>/1..N`).
* One quota shared by all four client repositories: `daily_gate.py gate --quota-remote <url>`
  (implemented and tested). It needs a common state repository and a token with `contents: write`
  on it, i.e. a new secret; not wired in because the policy is undecided.
* State namespace: `ATERMIUS_DAILY_NAMESPACE`; release branch: `ATERMIUS_RELEASE_BRANCH` (must be
  the default branch).

## Tests (offline)

```sh
python3 -I .github/daily-build/tests/test_daily_gate.py -v     # real git remotes, races, re-runs, UTC days
python3 -I .github/daily-build/tests/test_release_tool.py -v   # packaging/evidence + policy lint
python3 -I .github/daily-build/tests/test_release_build.py -v  # release prepare/publish, shared allocator, workflow policy
python3 -I .github/daily-build/tests/lint_workflows.py         # pin/permission/guard policy (actionlint still primary)
actionlint -shellcheck= .github/workflows/*.yml
```

## Desktop specifics

Matrix (max 2 in parallel, fail-fast off): `windows-2022`, `ubuntu-24.04`, `macos-15`. One failing
platform fails the day's attempt; nothing is published and the baseline stays.

* Windows (`recipe/desktop_windows.ps1`): VS 2022 + C++ x64 + ATL preflight (the repository's
  `build_rdp_windows.ps1` generates for VS 2022); vcpkg `openssl`/`zlib` `x64-windows-static-md`
  from the runner's vcpkg (commit and package versions recorded; binary cache keyed by vcpkg
  commit); `build_rdp_windows.ps1 -Workers 2`; Firebase C++ SDK digest-checked (13.12.0 pinned);
  `flutter build windows --release`; portable ZIP of the runtime files with `atermius_rdp.dll`
  (checked identical to the engine just built), `data/licenses/desktop/*` and the flutter_pty DLL.
  Not code-signed.
* Linux (`recipe/desktop_linux.sh`): packages per docs, `flutter build linux --release`, tar.gz of
  `bundle/` (flutter_pty library checked). No native RDP engine exists for Linux in this repository.
* macOS (`recipe/desktop_macos.sh`): `flutter build macos --release` with the repository's runner
  (ad-hoc identity `-`), `codesign --verify --deep --strict`, ZIP via `ditto`. Not notarized; no
  native RDP engine for macOS in this repository.
* Flutter SDK on macOS/Windows: `recipe/flutter_sdk.py` (official archive; Windows digest pinned,
  macOS `d4dd908b…` pinned; both must also match the official index entry for revision `6a19cca…`).
