#!/usr/bin/env bash
# Cache key for the Android RDP engine work directory (OpenSSL/FreeRDP objects).
# Exact-match only (no restore-keys): it covers every file of the engine recipe
# and sources (build_engine.sh flags, deps.lock digests, engine C/CMake files,
# verify_engine.py), the ABI list, the NDK revision and the host build tools.
# build_engine.sh reuses an existing OpenSSL prefix without re-checking its
# flags, so a partial/stale restore must never happen.
set -euo pipefail
: "${ANDROID_NDK_ROOT:?}" "${GITHUB_OUTPUT:?}"
key="$(
  {
    echo "recipe=atermius-android-rdp-engine/1"
    echo "abis=arm64-v8a,x86_64"
    # The Apple engine recipe (macOS/iOS) shares this directory in the monorepo but is not
    # part of the Android engine build.
    git ls-files -s -- apps/client/native/desktop ':(exclude)apps/client/native/desktop/apple'
    sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_ROOT/source.properties"
    cmake --version | head -1
    echo "ninja $(ninja --version)"
    perl -e 'print "perl $^V\n"'
    echo "image=${ImageOS:-unknown}"
  } | sha256sum | cut -c1-32
)"
echo "key=android-rdp-engine-$key" >> "$GITHUB_OUTPUT"
echo "engine work cache key: android-rdp-engine-$key"
