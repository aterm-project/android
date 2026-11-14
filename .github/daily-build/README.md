# CI of the Atermius monorepo: checks, daily builds, release builds

This repository (`aterm-project/atermius`, formerly `aterm-project/android`) holds the Flutter client
(`apps/client` with the `android/ ios/ macos/ windows/ linux/ web/` runners), the shared `packages/`
and `protocol/`, and the Rust `server/`. Before the merge each of the five repositories `android`,
`desktop`, `ios`, `web` and `server` had its own `.github/`. This directory is the one shared toolkit
that replaces the four client copies; every platform-specific part is selected by a `--platform`
argument (`android`, `desktop`, `ios`, `web`) and per-platform files.

## Workflows

| Workflow | Trigger | Replaces |
| --- | --- | --- |
| `checks-server.yml` | push / PR on `server/**`, `deploy/**`, `protocol/**` | server `checks.yml` (cargo test) |
| `checks-android.yml` | push / PR on shared client paths + Android paths | android `checks.yml` (Flutter tests, APK ABI checker self-test) |
| `checks-desktop.yml` | push / PR on shared client paths + desktop paths | desktop `checks.yml` (Flutter tests) |
| `checks-ios.yml` | push / PR on shared client paths + iOS paths | ios `checks.yml` (Flutter tests) |
| `checks-web.yml` | push / PR on shared client paths + Web paths | web `checks.yml` (Flutter tests, pinned-nginx runtime check) |
| `checks-ci.yml` | push / PR on `.github/**` (+ the Android NDK pin) | toolkit tests that android/desktop `checks.yml` ran, plus `lint_workflows.py` |
| `daily-android.yml` | cron `0 0 * * *`, dispatch | android `daily-build.yml` (signed APK) |
| `daily-desktop.yml` | cron `0 0 * * *`, dispatch | desktop `daily-build.yml` (Windows, macOS, Linux) |
| `daily-ios.yml` | cron `0 0 * * *`, dispatch | ios `daily-build.yml` (unsigned IPA) |
| `daily-web.yml` | cron `0 0 * * *`, dispatch | web `daily-build.yml` (static bundle) |
| `release-trigger.yml` | release published | android + desktop `release-trigger.yml` |
| `release-android.yml` | dispatch (by the trigger) | android `release-build.yml` |
| `release-desktop.yml` | dispatch (by the trigger) | desktop `release-build.yml` |
| `resume-publication.yml` | manual | android `resume-publication.yml` (one pre-merge run) |

### Check path filters

| Change under | Runs |
| --- | --- |
| `apps/client/lib/**`, `apps/client/test/**`, `apps/client/pubspec.*`, `apps/client/l10n.yaml`, `packages/**`, `tools/install_flutter_linux.sh` | all four client checks |
| `protocol/**` | all four client checks and the server checks (server tests read `protocol/test-vectors`, `protocol/sync-fixtures`) |
| `apps/client/android/**`, `apps/client/native/desktop/android/**`, `integration/native/android_*` | Android |
| `apps/client/{windows,macos,linux}/**`, `integration/native/**` (other than `android_*`), `scripts/build_macos.sh` | desktop |
| `apps/client/ios/**`, `scripts/build_ios.sh` | iOS |
| `apps/client/native/desktop/*` (shared RDP engine sources) | Android, desktop, iOS |
| `apps/client/native/desktop/apple/**` | desktop, iOS |
| `apps/client/web/**`, `tools/verify_cloud_proxy.py`, `Dockerfile`, `.dockerignore` | Web |
| `deploy/nginx.conf` | Web and server |
| `server/**`, `deploy/**` | server |
| `.github/**` | CI toolkit checks (and a check workflow's own file runs that check) |

GitHub does not evaluate path filters for tag pushes, so a pushed tag still runs every check, as
it did in each repository before. `tests/test_inputs.py` pins this table. Path-filtered workflows
cannot be required status checks (a PR that does not touch their paths would wait forever); see
"Cutover".

## Daily builds (one build attempt per platform per UTC day)

Each `daily-<platform>.yml` builds release artifacts of that platform at most once per UTC day, only
from the default branch, and only when that platform's product/packaging inputs changed since its
last build that was **compiled and published**. The four platforms are independent: separate
concurrency groups, quota, baseline, input rules and release tags. A build of one platform never
consumes, reads or moves another platform's state.

| Platform | Inputs | State namespace | Daily tag |
| --- | --- | --- | --- |
| android | `inputs/android.txt` | `refs/atermius-ci/daily-build/android` | `android-daily-<YYYYMMDD>.<slot>-<sha12>` |
| desktop | `inputs/desktop.txt` | `refs/atermius-ci/daily-build/desktop` | `desktop-daily-<YYYYMMDD>.<slot>-<sha12>` |
| ios | `inputs/ios.txt` | `refs/atermius-ci/daily-build/ios` | `ios-daily-<YYYYMMDD>.<slot>-<sha12>` |
| web | `inputs/web.txt` | `refs/atermius-ci/daily-build/web` | `web-daily-<YYYYMMDD>.<slot>-<sha12>` |

Asset names keep their pre-merge form (`atermius-android-0.1.0-20261114.1-<sha12>-arm64-x86_64.apk`):
the recipes drop the `<platform>-daily-` / `<platform>-` prefix of the tag.

| Trigger | Behaviour |
| --- | --- |
| `schedule` cron `0 0 * * *` (checkpoint) | Gate runs. GitHub starts scheduled runs at or after 00:00 UTC (often minutes late, sometimes much later, occasionally dropped under load); the cron does **not** guarantee a start to the second. |
| `workflow_dispatch` (no inputs) | Same gate, same quota. Dispatch from another branch only reports `not-default-branch`. |
| Re-run of a run | "Re-run all jobs" re-runs the gate: same UTC day ⇒ `quota-used`. "Re-run failed jobs" keeps the old gate result, so every build/sign/publish job is skipped (`claim_run_attempt != run_attempt`). |
| push / PR | Never builds here (only the checks). |

Gate decision (`daily_gate.py gate --platform <p>`, first match wins):

1. ref is not the remote default branch → skip `not-default-branch`;
2. `.github/` of the run commit differs from the branch tip → skip `ci-definition-changed` (all jobs use the scripts of the commit they build);
3. input fingerprint of the **tip** (rules `inputs/<p>.txt`) equals the platform's baseline → skip `no-input-changes`;
4. a claim already exists for today's UTC date in the platform's namespace (Android: or in the pre-merge namespace, see below) → skip `quota-used`;
5. a required setting is missing (Android: signing cert pin) → **fail, nothing claimed**;
6. atomic claim of `<ns>/quota/<date>/1` → **build**; losing the race → skip `quota-used-race`.

Skips exit 0 and consume nothing. The UTC day comes from the runner clock; a fresh, cache-busted
GitHub API `Date` header must be within 120 s **and** on the same UTC date, otherwise the gate exits 3
(nothing claimed) and the step retries 4× / 30 s, then fails. The gate refuses a namespace whose
last segment is not its `--platform`, and `publish.sh` refuses a tag that is not
`<platform>-daily-<date>.<slot>-<sha12>` of exactly the claim it publishes.

### Inputs

`inputs/<platform>.txt` (read from the commit being considered) selects product and packaging files;
the fingerprint is SHA-256 over their path/mode/blob ids plus the normalised rules. Shared client
code (`apps/client/**` apart from tests, integration probes and tools; `packages/**`; the Flutter
installer; `recipe/flutter_sdk.py`) is an input of every platform. Each runner directory, engine
recipe, `recipe/<platform>_*` and `daily-<platform>.yml` is an input only of its platform (the
shared RDP engine sources of Android, desktop and iOS; `apple/` of desktop and iOS;
`integration/native/build_rdp_windows.ps1` of desktop; `deploy/nginx.conf` of Web). Tests, docs,
`*.md`, `protocol/`, `server/`, gate/publish scripts and the check workflows are not inputs.
Changing a rules file causes one rebuild of that platform. Before the merge the four repositories
selected exactly the same files (verified against the merged tree; only files that arrived in
shared directories from sibling repositories are new).

### State (git refs, not caches/artifacts)

All state is in the repository under `refs/atermius-ci/daily-build/<platform>/` (hidden from branch
and tag lists; `contents: write` of the gate/publish/prepare jobs only):

| Ref | Written by | Meaning |
| --- | --- | --- |
| `<ns>/quota/<YYYY-MM-DD>/<slot>` | gate, compare-and-swap "must not exist" | one build attempt of that UTC day; never moved; a failed build still counts |
| `<ns>/baseline` | publish, compare-and-swap on the value the gate saw | last build that compiled **and** published; chained to the previous baseline |
| `android/version-code` | Android gate and release `prepare`, compare-and-swap | last allocated Android versionCode; chained |
| `android/release/<id>` | Android release `prepare`, compare-and-swap "must not exist" | versionCode and source commit of one published release |

Each ref points at a record commit: tree = source tree (no file changes), parent 1 = source commit,
parent 2 (baseline) = previous baseline, message = JSON (platform, source SHA, input fingerprint, run
id/attempt, release tag, artifact SHA-256 list). `git push --force-with-lease=<ref>:<expected>` makes
the receiving side apply the update only if the ref still has the expected value, so concurrent runs
cannot both claim a day or both move the baseline. Nothing depends on Actions caches, artifacts or
run history.

Inspect: `git fetch origin 'refs/atermius-ci/*:refs/atermius-ci/*'` then
`python3 -I .github/daily-build/daily_gate.py status --platform android`.
Force a rebuild of one platform at the next checkpoint: delete its `baseline` ref. Old `quota/*`
refs may be deleted after a few days (only today's date is read).

### Pre-merge state (Android)

The monorepo is the renamed android repository, so its pre-merge state stays at the old,
unprefixed namespace `refs/atermius-ci/daily-build/{baseline,quota/*,version-code,exceptions/*}`.
Nothing writes there any more except `resume-publication.yml`. `daily-android.yml` and
`release-android.yml` pass it as `--legacy-namespace`, **read only**: a claim of the current UTC day
there counts against Android's quota, and its `version-code` record (and `release/<id>` bindings)
are honoured, so the cutover day can neither build Android twice nor repeat a versionCode. From the
day after the cutover it has no effect (all later codes are above it by date) and the argument may be
removed. Desktop, iOS and Web state stays in their archived repositories; the first monorepo
checkpoint builds every platform once (no baseline yet, and the rules changed anyway).

## Release builds (published GitHub Releases)

Release tags are namespaced like daily tags. Publishing a release whose tag is

* `android-<anything>` (not `android-daily-*`) attaches the signed APK, `evidence-android.json` and
  `SHA256SUMS` (`release-android.yml`);
* `desktop-<anything>` (not `desktop-daily-*`) attaches the Windows ZIP, macOS ZIP, Linux tar.gz,
  their evidence and `SHA256SUMS` (`release-desktop.yml`);
* anything else (`ios-*`, `web-*`, `server-*`, an unprefixed `v1.2.3`) builds nothing; the trigger
  only leaves a warning. Daily tags (`<platform>-daily-*`, pre-merge `daily-*`) are skipped.

Manual releases are built immediately: they neither check nor consume the daily quota. Each release
build attaches to exactly one release with its own `SHA256SUMS`, which is why one release carries
one platform's packages.

| Workflow | Runs | Permissions |
| --- | --- | --- |
| `release-trigger.yml` | `release: published`; skips daily tags; no checkout; validates tag/id, then `gh workflow run release-<platform>.yml --ref main` | `actions: write` |
| `release-<platform>.yml` `prepare` | main only; `release_build.py prepare --platform <p>` | Android `contents: write` (versionCode refs), desktop `contents: read` |
| `release-<platform>.yml` `build` | the daily `build` steps unchanged | `contents: read`, no persisted credentials |
| `release-android.yml` `sign` | the daily `sign` steps unchanged (`daily-release` environment, certificate pin) | `contents: read` |
| `release-<platform>.yml` `publish` | `release_build.py publish --platform <p>` (REST API, no git push) | `contents: write` |

Trust: a `release` event runs the workflow file **of the tagged commit**, which may be unreviewed
(any writer can tag any commit, including a commit fetched from a fork's pull request: forks share
the object store). That workflow therefore gets no secrets and no checkout and can only dispatch the
main-branch definition. `prepare` (main definition) treats the tag and release id as untrusted
strings (regex-checked, passed through env, never interpolated into scripts), requires the tag to be
`<platform>-*` and not a daily tag, requires a published non-draft release whose id matches, peels
the tag (annotated or lightweight) to **one** commit, and refuses unless that commit is an ancestor
of `main` and carries the same `release_tool.py` and the same **platform** recipe files
(`recipe/<platform>_*`, `recipe/flutter_sdk.py`) as the running workflow; a change to another
platform's recipe does not block the release. Every later job uses only that commit id. The signing
environment keeps its deployment policy (`main` only): the dispatched run's ref is `main`, so no tag
pattern is needed and a tag-triggered or fork workflow can never read the key.

Publication targets the release **id** from `prepare`: before and after uploading, the id must still
own the tag, the release must be published, and the tag must still resolve to the built commit.
Existing assets: identical name+size+SHA-256 digest ⇒ kept; same name in state `open`/`starter`
(interrupted upload) ⇒ deleted and re-uploaded; same name with other content or an unknown state ⇒
refused before any change; other names are never touched. `SHA256SUMS` is uploaded last. A new
dispatch skips as `already-published` only after verifying the attached `SHA256SUMS`, every listed
asset's digest, and that each `evidence-*.json` belongs to this tag and commit (the Android release's
versionCode binding is checked first). To resume after a failure use **Re-run failed jobs**:
successful jobs and their packages are reused. A full re-run or a new dispatch reuses the release's
versionCode but rebuilds.

Manual start: Actions → Release build (Android|desktop) → Run workflow on `main` with the tag. Tags at
commits from before the merge cannot be built (their recipe differs; their own `release-trigger.yml`
would dispatch the removed `release-build.yml`). GitHub's "immutable releases" setting must stay off,
otherwise assets cannot be added after publication.

### versionCode allocator (Android)

`refs/atermius-ci/daily-build/android/version-code` is a compare-and-swap counter shared by the daily
gate (`gate --version-allocator`) and Android release builds:
`code = max(last + 1, pre-merge last + 1, YYYYMMDD*100 + highest quota slot claimed today + 1, YYYYMMDD*100 + 1)`.
Without manual releases the daily code stays `YYYYMMDD*100 + slot`; a manual release before or after
the cron on the same day gets the next code, and the next day starts above all of them, so every
build installs over every earlier one. Release builds stop at `YYYYMMDD*100 + 90`, leaving 91–99 for
daily attempts; a refused allocation changes nothing. Each release id records its code once in
`android/release/<id>` (re-runs reuse it; a moved tag is refused). Do **not** delete `version-code` or
`release/*` refs: the date floor would still exceed earlier days, but same-day codes could repeat.

## Jobs and permissions

Workflow default `permissions: {}` (checks: `contents: read`); concurrency group per platform and
repository, never cancelling (`daily-build-<platform>-…`, `release-build-<platform>-…-<tag>`).

| Job | Permissions | Runs |
| --- | --- | --- |
| gate | `contents: write` | checkout + `daily_gate.py` only (claim ref push) |
| build (compiles) | `contents: read`, `persist-credentials: false` | Flutter/Gradle/CMake/Xcode/MSBuild, plugin code |
| sign (Android) | `contents: read`, environment `daily-release` | `apksigner` only, no Gradle/plugin code |
| publish | `contents: write` | `publish.sh`: check claim, verify evidence/SHA-256, `gh release create`, advance baseline |

Actions are pinned to commit SHAs (checkout `11bd719…` v4.2.2 and `11d5960…` v4 in the checks, cache
`5a3ec84…` v4.2.3, upload-artifact `ea165f8…` v4.6.2, download-artifact `d3f86a1…` v4.3.0). No
`pull_request_target`, no dispatch inputs outside the release builds, no `${{ }}` inside `run:`
scripts. Build parallelism is capped at 2 per job; matrices use `max-parallel: 2`.

## Output

A GitHub **pre-release** `<platform>-daily-<YYYYMMDD>.<slot>-<sha12>` targeting the built commit,
containing the artifacts, `evidence-<target>.json` (toolchain, runner image, checks, file digests)
and `SHA256SUMS`; never marked latest. The tag/release is never overwritten. Workflow artifacts are
only transport between jobs. If publishing fails after the release was created, the baseline is not
advanced and the next checkpoint rebuilds (the extra release can be deleted by hand).

## Adjusting the policy

* Attempts per day: `ATERMIUS_DAILY_QUOTA` in the platform's workflow `env` (1–9; slots `quota/<date>/1..N`).
* One quota shared by several platforms or repositories: `daily_gate.py gate --quota-remote <url>`
  (implemented and tested, not wired in).
* State namespace `ATERMIUS_DAILY_NAMESPACE` (must end in `/<platform>`), input rules
  `ATERMIUS_DAILY_RULES`, release branch `ATERMIUS_RELEASE_BRANCH` (must be the default branch);
  `lint_workflows.py` checks each workflow uses its own platform's values.

## Platform specifics

### Android

* `recipe/android_build.sh`: `build_engine.sh` (deps.lock official OpenSSL 3.5.9 / FreeRDP 3.33.0
  tarballs, SHA-256 checked, NDK pin read from the script, `--jobs 2`) → engine bundle →
  `flutter build apk --release --target-platform android-arm64,android-x64 --build-number <versionCode>
  -Patermius.requireRdpEngine=true`. Checks: `integration/native/android_apk_abi_check.py`,
  packaged engine byte-identical to this run's engine, both license files present.
* The engine and Gradle share the pinned NDK under `ANDROID_HOME/ndk/<revision>` (cached by
  revision). The engine work directory is cached only under an exact key covering the engine
  sources and Android recipe (not the Apple recipe), ABIs, NDK, CMake/Ninja/Perl and runner image.
* Signing happens in a separate job without Gradle/plugin code: the Gradle output (runner debug key,
  never published) is re-signed by `apksigner` with the project's stable key, then
  `zipalign -c -P 16 4` and `apksigner verify --print-certs` must show exactly one signer equal to
  `ATERMIUS_ANDROID_SIGNING_CERT_SHA256`.

| Name | Kind | Content |
| --- | --- | --- |
| `ATERMIUS_ANDROID_KEYSTORE_B64` | `daily-release` environment secret | base64 of the existing keystore (JKS/PKCS12) |
| `ATERMIUS_ANDROID_KEYSTORE_PASSWORD` | `daily-release` environment secret | keystore password |
| `ATERMIUS_ANDROID_KEY_ALIAS` | `daily-release` environment secret | key alias |
| `ATERMIUS_ANDROID_KEY_PASSWORD` | `daily-release` environment secret | key password (empty ⇒ keystore password) |
| `ATERMIUS_ANDROID_SIGNING_CERT_SHA256` | repository variable | expected signer certificate SHA-256 |

The environment's deployment branches are `main` only, no reviewers; only the `sign` jobs use it.
The variable is repository-scoped because the gate checks it before claiming.

* `resume-publication.yml` is a manual, main-only recovery for the pre-merge run 42875528747 (it
  succeeded on 2026-11-10; a rerun only re-verifies). It verifies that only publication failed,
  checks the original quota claim in the pre-merge namespace, run, attempt, source and the signed
  artifact, and publishes the already signed APK under its original `daily-*` tag. It neither
  compiles nor signs, needs no signing secrets, and does not claim another daily build. It accepts
  the repository under its old and new name. `publish.sh` accepts a `daily-*` tag only in such a
  recovery (artifact run ≠ current run). The source artifact expires 14 days after 2026-11-10.

### Desktop

Matrix (max 2 in parallel, fail-fast off): `windows-2022`, `ubuntu-24.04`, `macos-15`. One failing
platform fails the day's attempt; nothing is published and the baseline stays.

* Windows (`recipe/desktop_windows.ps1`): VS 2022 + ATL preflight, vcpkg `openssl`/`zlib`
  `x64-windows-static-md`, `integration/native/build_rdp_windows.ps1 -Workers 2`, Firebase C++ SDK
  digest-checked, `flutter build windows --release`, portable ZIP with `atermius_rdp.dll`. Not
  code-signed.
* Linux (`recipe/desktop_linux.sh`): `flutter build linux --release`, tar.gz of `bundle/`. No native
  RDP engine for Linux.
* macOS (`recipe/desktop_macos.sh`): Apple engine (`native/desktop/apple/build_engine.sh --platform
  macos`), `flutter build macos --release`, ad-hoc signature verified, ZIP via `ditto`. Not notarized.

### iOS

`recipe/ios_build.sh` on `macos-15`: Apple engine (`--platform ios`), `flutter build ios --release
--no-codesign`, packaged as `Payload/Runner.app` in `*.unsigned.ipa`. It is **unsigned** and cannot
be installed until someone re-signs it; no App Store/TestFlight step.

### Web

`recipe/web_build.sh`: `flutter build web --release --no-web-resources-cdn`, then
`tools/verify_cloud_proxy.py` serves that build through the pinned deployment nginx image (headers,
CSP, API proxy, WebSocket). The tarball contains `web/` and `deploy/nginx.conf`. `checks-web.yml`
keeps the nginx/proxy check on every relevant push/PR against the checked-in web shell without
compiling.

Flutter SDK: Linux via `tools/install_flutter_linux.sh`; macOS/Windows via `recipe/flutter_sdk.py`
(official archives, digests pinned and checked against the official index entry).

## Cutover

1. Merge the monorepo into `aterm-project/android` `main` with this `.github/`, then rename the
   repository to `aterm-project/atermius`. Its `daily-release` environment (four secrets, deployment
   branch `main`), the variable `ATERMIUS_ANDROID_SIGNING_CERT_SHA256`, releases, tags, Actions
   history and `refs/atermius-ci/*` move with it. No new secret, variable or environment is needed.
2. Archive `aterm-project/desktop`, `ios`, `web`, `server` (this disables their schedules). Disable
   their `Daily build` workflows first if the cutover is not done before 00:00 UTC; a platform that
   built in its old repository on the cutover day can build once more in the monorepo that day
   (Android cannot, see "Pre-merge state").
3. Keep "Immutable releases" off; keep the default `GITHUB_TOKEN` permission read-only (workflows
   request what they need).
4. Branch protection / rulesets: do not require the path-filtered `… checks / check` jobs (they do
   not run for unrelated changes). If required checks are wanted, add an always-running aggregate
   job first.
5. Actions cache: the five repositories used about 21 GB of caches (limit 10 GB per repository);
   expect more cache evictions (slower, never wrong: every cache is exact-key or digest-checked).

## Tests (offline)

```sh
python3 -I .github/daily-build/tests/lint_workflows.py           # pin/permission/guard/platform policy
python3 -I .github/daily-build/tests/test_inputs.py -v           # path → platform routing (inputs, check filters)
python3 -I .github/daily-build/tests/test_daily_gate.py -v       # real git remotes, races, re-runs, UTC days, platforms
python3 -I .github/daily-build/tests/test_release_tool.py -v     # packaging/evidence + policy lint
python3 -I .github/daily-build/tests/test_release_build.py -v    # release prepare/publish, versionCode allocator, workflows
python3 -I .github/daily-build/tests/test_android_toolchain.py -v # shared SDK NDK install/reuse (needs the repository tree)
python3 -I .github/daily-build/tests/test_resume_publication.py -v
actionlint -shellcheck= .github/workflows/*.yml
```
