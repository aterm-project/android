#!/usr/bin/env bash
# Publish one claimed daily build, then (and only then) advance the baseline.
#
#   publish.sh RELEASE_DIR
#
# 1. check-claim: the quota ref still holds this run's claim for this attempt
#    and source (a re-run never publishes);
# 2. assemble: every evidence-<platform>.json belongs to this claim/run and
#    every listed file matches its SHA-256; writes SHA256SUMS and notes;
# 3. gh release create (gh uploads to a draft and publishes it when all assets
#    are up); refuses if the tag or release already exists;
# 4. compare the published assets with the local list;
# 5. advance the baseline by compare-and-swap.
# A failure anywhere leaves the baseline untouched, so the next checkpoint
# rebuilds; the claim keeps today's quota used.
set -euo pipefail
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}" "${GITHUB_SERVER_URL:?}"
: "${ATERMIUS_SOURCE_SHA:?}" "${ATERMIUS_QUOTA_DATE:?}" "${ATERMIUS_QUOTA_SLOT:?}" "${ATERMIUS_CLAIM_RECORD:?}"
: "${ATERMIUS_RELEASE_TAG:?}" "${ATERMIUS_PLATFORMS:?}" "${ATERMIUS_DAILY_NAMESPACE:?}" "${ATERMIUS_RELEASE_TITLE:?}"
: "${RUNNER_TEMP:?}"
dir="$1"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$RUNNER_TEMP/publish"
die() { echo "::error::$*" >&2; exit 1; }
[[ "$ATERMIUS_RELEASE_TAG" =~ ^daily-[0-9]{8}\.[1-9]-[0-9a-f]{12}$ ]] || die "invalid release tag"
rm -rf "$work"
mkdir -p "$work"
# A publication-only recovery preserves the original build/claim provenance.
# GITHUB_RUN_ID remains the actual recovery action; no build or signing reruns.
artifact_run_id="${ATERMIUS_ARTIFACT_RUN_ID:-$GITHUB_RUN_ID}"
artifact_run_attempt="${ATERMIUS_ARTIFACT_RUN_ATTEMPT:-$GITHUB_RUN_ATTEMPT}"
[[ "$artifact_run_id" =~ ^[0-9]+$ && "$artifact_run_attempt" =~ ^[1-9][0-9]*$ ]] || die "invalid artifact run identity"
claim_args=(--namespace "$ATERMIUS_DAILY_NAMESPACE" --quota-date "$ATERMIUS_QUOTA_DATE" --slot "$ATERMIUS_QUOTA_SLOT"
            --claim-record "$ATERMIUS_CLAIM_RECORD" --run-id "$artifact_run_id" --run-attempt "$artifact_run_attempt"
            --source-sha "$ATERMIUS_SOURCE_SHA")

python3 -I "$TOOLS/daily_gate.py" check-claim "${claim_args[@]}"
python3 -I "$TOOLS/release_tool.py" assemble --dir "$dir" --platforms "$ATERMIUS_PLATFORMS" \
  --source-sha "$ATERMIUS_SOURCE_SHA" --quota-date "$ATERMIUS_QUOTA_DATE" --release-tag "$ATERMIUS_RELEASE_TAG" \
  --run-id "$artifact_run_id" --run-attempt "$artifact_run_attempt" --repository "$GITHUB_REPOSITORY" \
  --run-url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$artifact_run_id" \
  --sums-out "$work/SHA256SUMS" --notes-out "$work/notes.md" --artifacts-out "$work/artifacts.json"
if [[ "$artifact_run_id" != "$GITHUB_RUN_ID" ]]; then
  printf '\nPublication recovered without rebuilding or re-signing: %s/%s/actions/runs/%s\n' \
    "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" >> "$work/notes.md"
fi
cp "$work/SHA256SUMS" "$dir/SHA256SUMS"

if git ls-remote --exit-code origin "refs/tags/$ATERMIUS_RELEASE_TAG" >/dev/null 2>&1; then
  die "tag $ATERMIUS_RELEASE_TAG already exists; refusing to reuse it"
fi
if gh release view "$ATERMIUS_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  die "release $ATERMIUS_RELEASE_TAG already exists; refusing to overwrite it"
fi
mapfile -t assets < <(find "$dir" -maxdepth 1 -type f -print | LC_ALL=C sort)
gh release create "$ATERMIUS_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --target "$ATERMIUS_SOURCE_SHA" \
  --title "$ATERMIUS_RELEASE_TITLE" --notes-file "$work/notes.md" --prerelease --latest=false "${assets[@]}"

gh release view "$ATERMIUS_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets,url,isDraft,tagName \
  > "$work/published.json"
python3 -I - "$work/published.json" "$dir" "$ATERMIUS_RELEASE_TAG" <<'PY'
import hashlib, json, sys
from pathlib import Path
published, directory, tag = json.load(open(sys.argv[1])), Path(sys.argv[2]), sys.argv[3]
if published.get("isDraft") or published.get("tagName") != tag:
    sys.exit("::error::release is still a draft or has another tag")
remote = {a["name"]: a for a in published.get("assets", [])}
local = {p.name: p for p in directory.iterdir() if p.is_file()}
if set(remote) != set(local):
    sys.exit(f"::error::published assets {sorted(remote)} != local {sorted(local)}")
for name, path in local.items():
    asset = remote[name]
    if asset.get("size") != path.stat().st_size:
        sys.exit(f"::error::{name}: published size differs")
    digest = str(asset.get("digest") or "")
    if digest.startswith("sha256:") and digest[7:] != hashlib.sha256(path.read_bytes()).hexdigest():
        sys.exit(f"::error::{name}: published digest differs")
print(f"published {len(local)} assets: {published.get('url')}")
PY
url="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$work/published.json")"

python3 -I "$TOOLS/daily_gate.py" advance "${claim_args[@]}" \
  --expect-baseline "${ATERMIUS_BASELINE_RECORD:-none}" --release-tag "$ATERMIUS_RELEASE_TAG" \
  --release-url "$url" --artifacts "$work/artifacts.json"
{
  echo "### Published $ATERMIUS_RELEASE_TAG"
  echo
  echo "$url"
  echo
  echo '```'
  cat "$work/SHA256SUMS"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
