#!/usr/bin/env bash
# Re-sign the daily APK with the project's stable Android signing key, outside
# Gradle (no plugin/build code runs in this job), so installed builds keep
# upgrading in place (`adb install -r` / package installer update) instead of
# requiring an uninstall that would delete app data.
#
# Secrets of the `daily-release` environment (deployment branches: main only):
#   ATERMIUS_ANDROID_KEYSTORE_B64       base64 of the existing keystore file (JKS or PKCS12)
#   ATERMIUS_ANDROID_KEYSTORE_PASSWORD  keystore password
#   ATERMIUS_ANDROID_KEY_ALIAS          key alias
#   ATERMIUS_ANDROID_KEY_PASSWORD       key password (optional; defaults to the keystore password)
# Variable (not secret):
#   ATERMIUS_ANDROID_SIGNING_CERT_SHA256  expected signer certificate SHA-256 (hex, colons allowed);
#                                         a different key fails the job instead of breaking upgrades.
#
# Usage: android_sign.sh INPUT_DIR OUTPUT_DIR   (directories with evidence-android-intermediate.json)
set -euo pipefail
: "${RUNNER_TEMP:?}" "${ATERMIUS_BUILD_TOOLS:?}"
in_dir="$1" out_dir="$2"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "::error::$*" >&2; exit 1; }
for name in ATERMIUS_ANDROID_KEYSTORE_B64 ATERMIUS_ANDROID_KEYSTORE_PASSWORD ATERMIUS_ANDROID_KEY_ALIAS \
            ATERMIUS_ANDROID_SIGNING_CERT_SHA256; do
  [[ -n "${!name:-}" ]] || die "$name is not configured (see .github/daily-build/README.md)"
done
expected="$(printf '%s' "$ATERMIUS_ANDROID_SIGNING_CERT_SHA256" | tr -d ': ' | tr 'A-F' 'a-f')"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "ATERMIUS_ANDROID_SIGNING_CERT_SHA256 is not a SHA-256 digest"

evidence="$in_dir/evidence-android-intermediate.json"
intermediate="$(python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1]))["artifacts"]; assert len(a)==1; print(a[0]["name"])' "$evidence")"
[[ "$intermediate" == *.debugsigned-intermediate.apk ]] || die "unexpected intermediate $intermediate"
final="${intermediate%.debugsigned-intermediate.apk}.apk"
mkdir -p "$out_dir"

python3 -I "$TOOLS/release_tool.py" inspect-apk --apk "$in_dir/$intermediate" \
  --json-out "$RUNNER_TEMP/intermediate-inspection.json" >/dev/null
python3 -I - "$RUNNER_TEMP/intermediate-inspection.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
if report["v1_signature_entries"]:
    sys.exit(f"::error::intermediate APK carries v1 signature files {report['v1_signature_entries']}; "
             "re-signing would leave them behind")
PY

secret_dir="$RUNNER_TEMP/release-signing"
umask 077
rm -rf "$secret_dir"
mkdir -p "$secret_dir"
trap 'rm -rf "$secret_dir"' EXIT
printf '%s' "$ATERMIUS_ANDROID_KEYSTORE_B64" | base64 --decode > "$secret_dir/keystore"
key_pass=(--key-pass env:ATERMIUS_ANDROID_KEYSTORE_PASSWORD)
[[ -n "${ATERMIUS_ANDROID_KEY_PASSWORD:-}" ]] && key_pass=(--key-pass env:ATERMIUS_ANDROID_KEY_PASSWORD)
"$ATERMIUS_BUILD_TOOLS/apksigner" sign --ks "$secret_dir/keystore" --ks-key-alias "$ATERMIUS_ANDROID_KEY_ALIAS" \
  --ks-pass env:ATERMIUS_ANDROID_KEYSTORE_PASSWORD "${key_pass[@]}" \
  --out "$out_dir/$final" "$in_dir/$intermediate"
rm -rf "$secret_dir"

"$ATERMIUS_BUILD_TOOLS/zipalign" -c -P 16 4 "$out_dir/$final" || die "signed APK is not 16 KB page aligned"
"$ATERMIUS_BUILD_TOOLS/apksigner" verify --verbose --print-certs "$out_dir/$final" > "$RUNNER_TEMP/apksigner-verify.txt"
python3 -I "$TOOLS/release_tool.py" apksigner-certs --text "$RUNNER_TEMP/apksigner-verify.txt" > "$RUNNER_TEMP/signing.json"
python3 -I - "$RUNNER_TEMP/signing.json" "$expected" <<'PY'
import json, sys
info, expected = json.load(open(sys.argv[1])), sys.argv[2]
digests = [s["sha256"] for s in info["signers"]]
if not info["verified"] or digests != [expected] or info["number_of_signers"] != 1:
    sys.exit(f"::error::signed APK signer {digests} != expected [{expected}] or verification failed")
if not (info["schemes"].get("v2") or info["schemes"].get("v3")):
    sys.exit("::error::neither APK Signature Scheme v2 nor v3 verified")
PY
python3 -I "$TOOLS/release_tool.py" inspect-apk --apk "$out_dir/$final" \
  --json-out "$RUNNER_TEMP/final-inspection.json" >/dev/null

cp "$evidence" "$RUNNER_TEMP/build-evidence.json"
python3 -I "$TOOLS/release_tool.py" evidence --platform android --out-dir "$out_dir" --artifact "$final" \
  --meta "signer_cert_sha256=$expected" --meta "signing=apksigner (stable project key), v2/v3 verified" \
  --meta "abis=arm64-v8a,x86_64" --meta "entry_point=lib/main.dart" \
  --attach "build=$RUNNER_TEMP/build-evidence.json" --attach "signature=$RUNNER_TEMP/signing.json" \
  --attach "apk_inspection=$RUNNER_TEMP/final-inspection.json" \
  --note "Signed with the project's stable key (certificate SHA-256 $expected); installs over earlier builds signed with the same key without uninstalling." \
  --note "Contains arm64-v8a and x86_64 only, with the embedded RDP engine (FreeRDP/OpenSSL licenses under assets/licenses/atermius_rdp)." \
  >/dev/null
ls -l "$out_dir"
