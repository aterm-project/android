#!/usr/bin/env bash
# Daily macOS release app (CI, macos-15). Uses the repository's macOS runner
# project as is (SwiftPM plugins, ad-hoc "Sign to Run Locally" identity "-").
# Not notarized and not Developer ID signed; no native RDP engine on macOS.
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

# xcodebuild compiles with one task per core by default; cap it at 2 for this job.
defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks -int 2
xcodebuild -version > "$META/xcode-version.txt"
python3 -I "$TOOLS/recipe/flutter_sdk.py" verify --out "$META/flutter-version.json"
cd "$ROOT/apps/client"
flutter config --no-analytics >/dev/null
flutter pub get --enforce-lockfile
flutter build macos --release --no-pub --target lib/main.dart

shopt -s nullglob
apps=("$ROOT"/apps/client/build/macos/Build/Products/Release/*.app)
[[ ${#apps[@]} -eq 1 ]] || die "expected one .app, found ${#apps[@]}"
app="${apps[0]}"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
[[ -x "$app/Contents/MacOS/$exe" ]] || die "app executable missing"
for required in Contents/Frameworks/FlutterMacOS.framework Contents/Frameworks/App.framework; do
  [[ -e "$app/$required" ]] || die "app lacks $required"
done
[[ -n "$(find "$app/Contents/Frameworks" -maxdepth 1 -iname '*pty*' -print -quit)" ]] || die "app lacks the flutter_pty framework"
lipo -archs "$app/Contents/MacOS/$exe" > "$META/archs.txt"
codesign --verify --deep --strict "$app" || die "ad-hoc code signature does not verify"
codesign -dv --verbose=2 "$app" 2> "$META/codesign.txt" || true
git -C "$ROOT" diff --quiet HEAD || { echo "::warning::the build modified tracked files:"; git -C "$ROOT" diff --stat HEAD; }

version_name="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/apps/client/pubspec.yaml")"
name="atermius-desktop-macos-${version_name}-${ATERMIUS_RELEASE_TAG#daily-}.adhoc-signed.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$ATERMIUS_OUT/$name"
python3 -I - "$META" <<'PY'
import json, sys
from pathlib import Path
meta = Path(sys.argv[1])
info = {
    "xcode": meta.joinpath("xcode-version.txt").read_text().split("\n")[:2],
    "archs": meta.joinpath("archs.txt").read_text().split(),
    "codesign": [l for l in meta.joinpath("codesign.txt").read_text().splitlines()
                 if l.startswith(("Identifier=", "Format=", "Signature=", "TeamIdentifier=", "CodeDirectory"))],
}
meta.joinpath("macos.json").write_text(json.dumps(info, indent=2))
PY
python3 -I "$TOOLS/release_tool.py" evidence --platform macos --out-dir "$ATERMIUS_OUT" --artifact "$name" \
  --meta "version_name=$version_name" --meta "entry_point=lib/main.dart" --meta "build_workers=2" \
  --meta "signing=ad-hoc (identity '-'), not notarized" \
  --meta "rdp_engine=not built for macOS (Windows-only native engine in this repository)" \
  --attach "flutter=$META/flutter-version.json" --attach "macos=$META/macos.json" \
  --note "Ad-hoc signed and NOT notarized: Gatekeeper blocks the first launch until it is allowed in System Settings > Privacy & Security." \
  --note "No native RDP engine on macOS in this repository." >/dev/null
ls -l "$ATERMIUS_OUT"
