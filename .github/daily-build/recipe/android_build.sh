#!/usr/bin/env bash
# Daily Android release APK (CI). Normal entry point lib/main.dart, one APK for
# arm64-v8a + x86_64, with this repository's embedded RDP engine built by
# apps/client/native/desktop/android/build_engine.sh (pinned OpenSSL/FreeRDP
# from deps.lock) and required by Gradle (-Patermius.requireRdpEngine=true).
# There is no fallback to a local guacd and no engine is taken from a cache
# other than the exact-key work directory of the same recipe.
#
# The APK produced here is signed by Gradle with the runner's throwaway debug
# key and is NOT distributable; android_sign.sh re-signs it with the project's
# stable key in a separate job without Gradle/plugin code.
#
# Env: ATERMIUS_SOURCE_SHA ATERMIUS_QUOTA_DATE ATERMIUS_RELEASE_TAG
#      ATERMIUS_VERSION_CODE ATERMIUS_OUT ATERMIUS_ENGINE_DEPS ATERMIUS_ENGINE_WORK
#      ANDROID_NDK_ROOT (android_toolchain.sh), flutter on PATH.
set -euo pipefail
: "${ATERMIUS_SOURCE_SHA:?}" "${ATERMIUS_QUOTA_DATE:?}" "${ATERMIUS_RELEASE_TAG:?}" "${ATERMIUS_VERSION_CODE:?}"
: "${ATERMIUS_OUT:?}" "${ATERMIUS_ENGINE_DEPS:?}" "${ATERMIUS_ENGINE_WORK:?}" "${ANDROID_NDK_ROOT:?}" "${RUNNER_TEMP:?}"
JOBS=2
ROOT="$(git rev-parse --show-toplevel)"
TOOLS="$ROOT/.github/daily-build"
ENGINE_DIR="$ROOT/apps/client/native/desktop/android"
ENGINE_OUT="$RUNNER_TEMP/rdp-engine-out"
META="$RUNNER_TEMP/android-meta"
die() { echo "::error::$*" >&2; exit 1; }

[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$ATERMIUS_SOURCE_SHA" ]] || die "checkout is not the claimed source"
[[ "$ATERMIUS_VERSION_CODE" =~ ^[0-9]{10}$ ]] || die "invalid version code"
rm -rf "$ENGINE_OUT" "$META"
mkdir -p "$ATERMIUS_OUT" "$ATERMIUS_ENGINE_DEPS" "$ATERMIUS_ENGINE_WORK" "$META"

echo "::group::Official engine sources (deps.lock)"
while read -r sha file url _license; do
  [[ -z "$sha" || "$sha" == \#* ]] && continue
  [[ "$url" =~ ^https://github\.com/(openssl/openssl|FreeRDP/FreeRDP)/releases/download/ ]] || die "unexpected source URL $url"
  target="$ATERMIUS_ENGINE_DEPS/$file"
  if [[ ! -f "$target" ]] || [[ "$(sha256sum "$target" | cut -d' ' -f1)" != "$sha" ]]; then
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 -o "$target.part" "$url"
    [[ "$(sha256sum "$target.part" | cut -d' ' -f1)" == "$sha" ]] || die "$file digest mismatch"
    mv "$target.part" "$target"
  fi
  echo "$sha  $file"
done < "$ENGINE_DIR/deps.lock"
echo "::endgroup::"

echo "::group::RDP engine (build_engine.sh, $JOBS jobs)"
bash "$ENGINE_DIR/build_engine.sh" --deps "$ATERMIUS_ENGINE_DEPS" --work "$ATERMIUS_ENGINE_WORK" \
  --out "$ENGINE_OUT" --abi arm64-v8a --abi x86_64 --jobs "$JOBS"
for abi in arm64-v8a x86_64; do
  [[ -f "$ENGINE_OUT/jniLibs/$abi/libatermius_rdp.so" ]] || die "engine missing for $abi"
done
cp "$ENGINE_OUT/engine-manifest.json" "$META/engine-manifest.json"
echo "::endgroup::"

echo "::group::Flutter release APK"
python3 -I "$TOOLS/recipe/flutter_sdk.py" verify --out "$META/flutter-version.json"
cd "$ROOT/apps/client"
flutter config --no-analytics >/dev/null
flutter pub get --enforce-lockfile
ATERMIUS_ANDROID_RDP_ENGINE_DIR="$ENGINE_OUT" flutter build apk --release --no-pub \
  --target lib/main.dart --target-platform android-arm64,android-x64 \
  --build-number "$ATERMIUS_VERSION_CODE" \
  --android-project-arg=atermius.requireRdpEngine=true \
  --android-project-arg="atermius.rdpEngineDir=$ENGINE_OUT"
apk="$ROOT/apps/client/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$apk" ]] || die "release APK not produced"
git -C "$ROOT" diff --quiet HEAD || { echo "::warning::the build modified tracked files:"; git -C "$ROOT" diff --stat HEAD; }
echo "::endgroup::"

echo "::group::APK checks"
python3 -I "$ROOT/integration/native/android_apk_abi_check.py" "$apk" \
  --target-platform android-arm64,android-x64 --mode release --require-lib libatermius_rdp.so \
  | tee "$META/abi-check.txt"
python3 -I "$TOOLS/release_tool.py" inspect-apk --apk "$apk" --abis arm64-v8a,x86_64 \
  --engine-out "$ENGINE_OUT" --json-out "$META/apk-inspection.json" >/dev/null
echo "::endgroup::"

version_name="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/apps/client/pubspec.yaml")"
name="atermius-android-${version_name}-${ATERMIUS_RELEASE_TAG#daily-}-arm64-x86_64.debugsigned-intermediate.apk"
cp "$apk" "$ATERMIUS_OUT/$name"
python3 -I "$TOOLS/release_tool.py" evidence --platform android-intermediate --out-dir "$ATERMIUS_OUT" \
  --artifact "$name" \
  --meta "version_name=$version_name" --meta "version_code=$ATERMIUS_VERSION_CODE" \
  --meta "entry_point=lib/main.dart" --meta "abis=arm64-v8a,x86_64" \
  --meta "ndk_revision=$ATERMIUS_NDK_REVISION" --meta "build_workers=$JOBS" \
  --meta "rdp_engine=required (atermius.requireRdpEngine=true)" \
  --attach "flutter=$META/flutter-version.json" --attach "engine_manifest=$META/engine-manifest.json" \
  --attach "apk_inspection=$META/apk-inspection.json" \
  --note "Intermediate only: signed by the CI runner's throwaway debug key; never published." >/dev/null
ls -l "$ATERMIUS_OUT"
