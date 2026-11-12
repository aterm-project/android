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
| `version-code` | gate (Android) and release `prepare`, compare-and-swap | last allocated Android versionCode; chained (see Release builds) |
| `release/<id>` | release `prepare`, compare-and-swap "must not exist" | versionCode and source commit of one published release |

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

Publishing a GitHub Release (or pre-release) whose tag is not `daily-*` attaches the signed APK,
`evidence-android.json` and `SHA256SUMS` to **that** release. Manual releases are built immediately:
they neither check nor consume the daily quota, and the once-a-day cron is unaffected.

| Workflow | Runs | Permissions |
| --- | --- | --- |
| `release-trigger.yml` | `release: published`; skips `daily-*`; no checkout; validates tag/id, then `gh workflow run release-build.yml --ref main` | `actions: write` |
| `release-build.yml` `prepare` | main only; `release_build.py prepare` | `contents: write` (versionCode refs) |
| `release-build.yml` `build` | the daily `build` steps unchanged (`android_build.sh`, RDP engine, licenses) | `contents: read`, no persisted credentials |
| `release-build.yml` `sign` | the daily `sign` steps unchanged (`daily-release` environment, certificate pin) | `contents: read` |
| `release-build.yml` `publish` | `release_build.py publish` (REST API, no git push) | `contents: write` |

Trust: a `release` event runs the workflow file **of the tagged commit**, which may be unreviewed
(any writer can tag any commit, including a commit fetched from a fork's pull request: forks share
the object store). That workflow therefore gets no secrets and no checkout and can only dispatch the
main-branch definition. `prepare` (main definition) treats the tag and release id as untrusted strings
(regex-checked, passed through env, never interpolated into scripts), requires a published non-draft
release whose id matches, peels the tag (annotated or lightweight) to **one** commit, and refuses
unless that commit is an ancestor of `main` and carries the same `recipe/` and `release_tool.py` as the
running workflow. Every later job uses only that commit id. The signing environment keeps its
deployment policy (`main` only): the dispatched run's ref is `main`, so no tag pattern is needed and
a tag-triggered or fork workflow can never read the key. Forks cannot dispatch upstream workflows,
and their own release events run in the fork without these secrets.

Publication targets the release **id** from `prepare`: before and after uploading, the id must still
own the tag, the release must be published, and the tag must still resolve to the built commit (a
moved tag or a replacement release is refused). Existing assets: identical name+size+SHA-256 digest
⇒ kept; same name in state `open`/`starter` (interrupted upload) ⇒ that asset is deleted and
re-uploaded; same name with other content or an unknown state ⇒ refused before any change; other
names are never touched. `SHA256SUMS` is uploaded last. A new dispatch skips as `already-published`
only after verifying the attached `SHA256SUMS` (digest-checked download; a storage redirect is
followed without the token), every listed asset's digest, and that `evidence-android.json` belongs to
this tag and commit (the release's versionCode binding is checked first); otherwise it builds, and
publish refuses stale assets of the same name. To resume after a failure use **Re-run failed jobs**: successful jobs,
their outputs and their packages are reused (artifact names carry no attempt number), so the
upload is byte-identical. A full re-run or a new dispatch reuses the release's versionCode but
rebuilds, and its bytes may differ from assets already attached.

Manual start: Actions → Release build → Run workflow on `main` with the tag (needed for tags
created at commits that predate `release-trigger.yml`). GitHub's "immutable releases" setting must
stay off for the repository, otherwise assets cannot be added after publication.

### versionCode allocator

`refs/atermius-ci/daily-build/version-code` is a compare-and-swap counter shared by the daily gate
(`gate --version-allocator`) and release builds:
`code = max(last + 1, YYYYMMDD*100 + highest quota slot claimed today + 1, YYYYMMDD*100 + 1)`.
Without manual releases the daily code stays `YYYYMMDD*100 + slot`; a manual release before or after
the cron on the same day gets the next code, and the next day starts above all of them, so every
build installs over every earlier one. Release builds stop at `YYYYMMDD*100 + 90`, leaving 91–99 for
daily attempts; a refused allocation changes nothing. Each release id records its code once in
`refs/atermius-ci/daily-build/release/<id>` (re-runs reuse it; a moved tag is refused). Each record
commit is chained to the previous one. Do **not** delete `version-code` or `release/*` refs: the
date floor would still exceed earlier days, but same-day codes could repeat.

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
| sign (Android) | `contents: read`, environment `daily-release` | `apksigner` only, no Gradle/plugin code |
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
python3 -I .github/daily-build/tests/test_android_toolchain.py -v # shared SDK NDK install/reuse and stale-cache refusal
python3 -I .github/daily-build/tests/test_release_build.py -v  # release prepare/publish, versionCode allocator, workflow policy
python3 -I .github/daily-build/tests/lint_workflows.py         # pin/permission/guard policy (actionlint still primary)
actionlint -shellcheck= .github/workflows/*.yml
```

## Android specifics

* `resume-publication.yml` is a manual, main-only recovery for original run 42875528747.
  It verifies that only publication failed, checks the original quota/run/attempt/source and
  signed-artifact provenance, and publishes the already signed APK. It neither compiles nor
  signs, needs no signing secrets, and does not claim another daily build. The optional v4
  `.idsig` is quarantined with its hash recorded; the APK and original evidence stay byte-identical.
  Normal signing explicitly disables the unused v4 sidecar. Recovery has the same concurrency
  group as the daily build and cannot overwrite an existing release.
  For GitHub's historical-commit tag permission restriction, an administrator may create the
  original source tag first. Recovery checks its peeled commit against the full artifact source
  SHA and uses `--verify-tag`; normal daily publication still refuses pre-existing tags.
  A recovery retry verifies an existing published release's complete asset list, sizes and
  hashes without modifying or re-uploading assets, then finishes its original baseline.
  If GitHub refuses the historical-workflow baseline push, an administrator can run the same
  guarded `daily_gate.py advance` with the original claim and verified artifact manifest; the
  recovery task verifies the completed publication and leaves the equal/newer baseline intact.
* The native engine and Gradle use the same pinned NDK under `ANDROID_HOME/ndk/<revision>`;
  the cache restores that exact SDK package directory. No second private SDK is installed.
  Before restoring tools, the disposable GitHub-hosted Linux runner removes unused .NET,
  Haskell and CodeQL installations. Before Gradle, the build reports disk usage and requires
  8 GiB free for native-library transforms, AOT output and APK packaging.
* `recipe/android_build.sh`: `build_engine.sh` (deps.lock official OpenSSL 3.5.9 / FreeRDP 3.33.0
  tarballs, SHA-256 checked, NDK pin read from the script, `--jobs 2`) → engine bundle →
  `flutter build apk --release --target lib/main.dart --target-platform android-arm64,android-x64
  --build-number <YYYYMMDD><slot> -Patermius.requireRdpEngine=true` with
  `ATERMIUS_ANDROID_RDP_ENGINE_DIR`. Checks: `integration/native/android_apk_abi_check.py`
  (`--require-lib libatermius_rdp.so`), packaged engine byte-identical to this run's engine, both
  license files present.
* The engine work directory is cached only under an exact key covering every file of
  `apps/client/native/desktop`, the ABIs, NDK revision, CMake/Ninja/Perl versions and runner image
  (no restore-keys), so a stale engine is never reused.
* versionCode from the shared allocator (above): `YYYYMMDD*100 + slot` (e.g. 2026111001) when no
  manual release was built that day, otherwise the next free code; always monotonic.
* Signing happens in a separate job without Gradle/plugin code: the Gradle output (runner debug
  key, never published) is re-signed by `apksigner` with the project's stable key, then
  `zipalign -c -P 16 4` and `apksigner verify --print-certs` must show exactly one signer equal to
  `ATERMIUS_ANDROID_SIGNING_CERT_SHA256`. A different key fails the build instead of producing an
  APK that cannot update existing installs.

| Name | Kind | Content |
| --- | --- | --- |
| `ATERMIUS_ANDROID_KEYSTORE_B64` | environment secret | base64 of the existing keystore (JKS/PKCS12) |
| `ATERMIUS_ANDROID_KEYSTORE_PASSWORD` | environment secret | keystore password |
| `ATERMIUS_ANDROID_KEY_ALIAS` | environment secret | key alias |
| `ATERMIUS_ANDROID_KEY_PASSWORD` | environment secret | key password (empty ⇒ keystore password) |
| `ATERMIUS_ANDROID_SIGNING_CERT_SHA256` | repository variable | expected signer certificate SHA-256 |

The four secrets live in the `daily-release` environment (deployment branches: `main` only, no
reviewers), referenced only by the `sign` job, so workflows on other branches cannot read the key.
The variable is repository-scoped because the gate checks it before claiming; without it the gate
fails and claims nothing.
