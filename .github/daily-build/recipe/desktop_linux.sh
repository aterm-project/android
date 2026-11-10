#!/usr/bin/env bash
# Daily Linux x64 release bundle (CI, ubuntu-24.04). Packages
# apps/client/build/linux/x64/release/bundle as a .tar.gz. This repository has
# no native RDP engine for Linux (docs/INSTALLATION*.md); none is claimed.
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

echo "::group::Build dependencies (docs/INSTALLATION.en.md)"
sudo apt-get update -qq
sudo apt-get install -y -qq clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev >/dev/null
# flutter runs `ninja` without -j; cap the compiler fan-out at 2 for this job.
mkdir -p "$RUNNER_TEMP/ci-bin"
printf '#!/bin/sh\nexec /usr/bin/ninja -j2 "$@"\n' > "$RUNNER_TEMP/ci-bin/ninja"
chmod +x "$RUNNER_TEMP/ci-bin/ninja"
export PATH="$RUNNER_TEMP/ci-bin:$PATH"
echo "::endgroup::"

python3 -I "$TOOLS/recipe/flutter_sdk.py" verify --out "$META/flutter-version.json"
cd "$ROOT/apps/client"
flutter config --no-analytics >/dev/null
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub --target lib/main.dart
bundle="$ROOT/apps/client/build/linux/x64/release/bundle"
[[ -x "$bundle/aterm_client" ]] || die "aterm_client executable missing"
for required in lib/libflutter_linux_gtk.so lib/libapp.so data/icudtl.dat data/flutter_assets/AssetManifest.bin; do
  [[ -e "$bundle/$required" ]] || die "bundle lacks $required"
done
compgen -G "$bundle/lib/*pty*.so" >/dev/null || die "bundle lacks the flutter_pty library"
git -C "$ROOT" diff --quiet HEAD || { echo "::warning::the build modified tracked files:"; git -C "$ROOT" diff --stat HEAD; }

version_name="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/apps/client/pubspec.yaml")"
name="atermius-desktop-linux-x64-${version_name}-${ATERMIUS_RELEASE_TAG#daily-}.tar.gz"
python3 -I "$TOOLS/release_tool.py" archive --src "$bundle" --out "$ATERMIUS_OUT/$name" --prefix atermius-linux-x64
(cd "$bundle" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$META/bundle-files.sha256"
python3 -I - "$META/bundle-files.sha256" "$META/bundle-files.json" <<'PY'
import json, sys
rows = [line.split(None, 1) for line in open(sys.argv[1]) if line.strip()]
json.dump([{"path": p.strip()[2:], "sha256": h} for h, p in rows], open(sys.argv[2], "w"), indent=1)
PY
python3 -I "$TOOLS/release_tool.py" evidence --platform linux-x64 --out-dir "$ATERMIUS_OUT" --artifact "$name" \
  --meta "version_name=$version_name" --meta "entry_point=lib/main.dart" --meta "build_workers=2" \
  --meta "rdp_engine=not built for Linux (Windows-only native engine in this repository)" \
  --attach "flutter=$META/flutter-version.json" --attach "bundle_files=$META/bundle-files.json" \
  --note "Relocatable release bundle (tar.gz): keep lib/ and data/ next to aterm_client." \
  --note "Runtime needs GTK 3, libsecret and an unlocked Secret Service keyring in the desktop session." \
  --note "No native RDP engine on Linux (see docs/REMOTE-DESKTOP.md for the gateway path)." >/dev/null
ls -l "$ATERMIUS_OUT"
