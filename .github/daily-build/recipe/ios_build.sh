#!/usr/bin/env bash
# Daily iOS device build (CI, macos-15), explicitly UNSIGNED:
# `flutter build ios --release --no-codesign`, packaged as Payload/Runner.app
# in a zip named *.unsigned.ipa. It cannot be installed until someone re-signs
# it with their own Apple identity and provisioning profile; there is no
# App Store/TestFlight step (not requested).
#
# Env: ATERMIUS_SOURCE_SHA ATERMIUS_RELEASE_TAG ATERMIUS_OUT, flutter on PATH.
set -euo pipefail
: "${ATERMIUS_SOURCE_SHA:?}" "${ATERMIUS_RELEASE_TAG:?}" "${ATERMIUS_OUT:?}" "${RUNNER_TEMP:?}"
ROOT="$(git rev-parse --show-toplevel)"
TOOLS="$ROOT/.github/daily-build"
META="$RUNNER_TEMP/meta"
die() { echo "::error::$*" >&2; exit 1; }
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$ATERMIUS_SOURCE_SHA" ]] || die "checkout is not the claimed source"
mkdir -p "$ATERMIUS_OUT" "$META"

defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks -int 2
xcodebuild -version > "$META/xcode-version.txt"
python3 -I "$TOOLS/recipe/flutter_sdk.py" verify --out "$META/flutter-version.json"

ENGINE_OUT="$ROOT/apps/client/native/desktop/build/ios/bundle"
bash "$ROOT/apps/client/native/desktop/apple/build_engine.sh" \
  --platform ios \
  --deps "$RUNNER_TEMP/rdp-deps" \
  --work "$RUNNER_TEMP/rdp-work-ios" \
  --out "$ENGINE_OUT" \
  --jobs 2
cp "$ENGINE_OUT/engine-manifest.json" "$META/engine-manifest.json"

cd "$ROOT/apps/client"
flutter config --no-analytics >/dev/null
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub --target lib/main.dart

app="$ROOT/apps/client/build/ios/iphoneos/Runner.app"
[[ -f "$app/Info.plist" ]] || die "Runner.app missing"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
[[ -f "$app/$exe" ]] || die "app executable missing"
for required in \
  Frameworks/Flutter.framework \
  Frameworks/App.framework \
  Frameworks/atermius_rdp.framework/atermius_rdp \
  atermius_rdp_licenses/FreeRDP-LICENSE \
  atermius_rdp_licenses/OpenSSL-LICENSE.txt; do
  [[ -e "$app/$required" ]] || die "app lacks $required"
done
lipo -archs "$app/$exe" > "$META/archs.txt"
if codesign -dv "$app" > "$META/codesign.txt" 2>&1; then
  echo "::warning::Runner.app carries a code signature although --no-codesign was used"
fi
git -C "$ROOT" diff --quiet HEAD || { echo "::warning::the build modified tracked files:"; git -C "$ROOT" diff --stat HEAD; }

version_name="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/apps/client/pubspec.yaml")"
name="atermius-ios-${version_name}-${ATERMIUS_RELEASE_TAG#daily-}.unsigned.ipa"
stage="$RUNNER_TEMP/ipa-stage"
rm -rf "$stage"
mkdir -p "$stage/Payload"
/usr/bin/ditto "$app" "$stage/Payload/Runner.app"
(cd "$stage" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$ATERMIUS_OUT/$name")
python3 -I - "$META" "$app/Info.plist" <<'PY'
import json, plistlib, sys
from pathlib import Path
meta, plist = Path(sys.argv[1]), plistlib.load(open(sys.argv[2], "rb"))
info = {
    "xcode": meta.joinpath("xcode-version.txt").read_text().split("\n")[:2],
    "archs": meta.joinpath("archs.txt").read_text().split(),
    "bundle_id": plist.get("CFBundleIdentifier"), "short_version": plist.get("CFBundleShortVersionString"),
    "build": plist.get("CFBundleVersion"), "minimum_os": plist.get("MinimumOSVersion"),
    "codesign": meta.joinpath("codesign.txt").read_text().strip().splitlines()[:3],
}
meta.joinpath("ios.json").write_text(json.dumps(info, indent=2))
PY
python3 -I "$TOOLS/release_tool.py" evidence --platform ios --out-dir "$ATERMIUS_OUT" --artifact "$name" \
  --meta "version_name=$version_name" --meta "entry_point=lib/main.dart" --meta "build_workers=2" \
  --meta "signing=UNSIGNED (flutter build ios --no-codesign)" \
  --meta "rdp_engine=embedded atermius_rdp.framework (FreeRDP 3.33.0 + OpenSSL 3.5.9)" \
  --attach "flutter=$META/flutter-version.json" --attach "ios=$META/ios.json" --attach "engine_manifest=$META/engine-manifest.json" \
  --note "UNSIGNED iOS device build (Payload/Runner.app). It cannot be installed as is: re-sign it with your own Apple Developer identity and provisioning profile first." \
  --note "Includes embedded iOS RDP engine atermius_rdp.framework (FreeRDP 3.33.0 + OpenSSL 3.5.9) with licenses in atermius_rdp_licenses." \
  --note "Not an App Store/TestFlight build; no Apple signing was requested or configured." >/dev/null
ls -l "$ATERMIUS_OUT"
