#!/usr/bin/env bash
# Daily Web static bundle (CI, ubuntu-24.04): the same command as the
# Dockerfile/docs (`flutter build web --release --no-web-resources-cdn`), then
# tools/verify_cloud_proxy.py serves the built output through the pinned
# deployment nginx (headers, CSP, API proxy, WebSocket upgrade) before
# packaging web/ + deploy/nginx.conf as a .tar.gz.
#
# Env: ATERMIUS_SOURCE_SHA ATERMIUS_RELEASE_TAG ATERMIUS_OUT, flutter on PATH, Docker.
set -euo pipefail
: "${ATERMIUS_SOURCE_SHA:?}" "${ATERMIUS_RELEASE_TAG:?}" "${ATERMIUS_OUT:?}" "${RUNNER_TEMP:?}"
ROOT="$(git rev-parse --show-toplevel)"
TOOLS="$ROOT/.github/daily-build"
META="$RUNNER_TEMP/meta"
die() { echo "::error::$*" >&2; exit 1; }
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$ATERMIUS_SOURCE_SHA" ]] || die "checkout is not the claimed source"
mkdir -p "$ATERMIUS_OUT" "$META"

python3 -I "$TOOLS/recipe/flutter_sdk.py" verify --out "$META/flutter-version.json"
cd "$ROOT/apps/client"
flutter config --no-analytics >/dev/null
flutter pub get --enforce-lockfile
flutter build web --release --no-pub --no-web-resources-cdn --target lib/main.dart
web="$ROOT/apps/client/build/web"
for required in index.html main.dart.js flutter_bootstrap.js share-bootstrap.js; do
  [[ -f "$web/$required" ]] || die "web build lacks $required"
done
git -C "$ROOT" diff --quiet HEAD || { echo "::warning::the build modified tracked files:"; git -C "$ROOT" diff --stat HEAD; }

cd "$ROOT"
python3 -I tools/verify_cloud_proxy.py --web-root "$web" > "$META/cloud-proxy.json"

stage="$RUNNER_TEMP/web-stage"
rm -rf "$stage"
mkdir -p "$stage/deploy"
cp -R "$web" "$stage/web"
cp deploy/nginx.conf "$stage/deploy/nginx.conf"
version_name="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/apps/client/pubspec.yaml")"
name="atermius-web-${version_name}-${ATERMIUS_RELEASE_TAG#daily-}.tar.gz"
python3 -I "$TOOLS/release_tool.py" archive --src "$stage" --out "$ATERMIUS_OUT/$name" --prefix atermius-web
python3 -I "$TOOLS/release_tool.py" evidence --platform web --out-dir "$ATERMIUS_OUT" --artifact "$name" \
  --meta "version_name=$version_name" --meta "entry_point=lib/main.dart" \
  --meta "flutter_build=web --release --no-web-resources-cdn" \
  --attach "flutter=$META/flutter-version.json" --attach "cloud_proxy=$META/cloud-proxy.json" \
  --note "Static bundle: serve web/ with deploy/nginx.conf (the CI served this exact build through the pinned nginx image and checked headers, CSP, API proxy and WebSocket upgrade)." \
  --note "No CDN resources: CanvasKit and fonts are bundled." >/dev/null
ls -l "$ATERMIUS_OUT"
