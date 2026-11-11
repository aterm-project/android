#!/usr/bin/env bash
# Reproducible Apple (macOS / iOS) build of the embedded RDP engine.
#
# Links FreeRDP 3.33.0, WinPR and OpenSSL 3.5.9 statically into a self-contained
# Mach-O dynamic library / XCFramework whose only exported symbols are
# `_aterm_rdp_*` (apple/exports.txt).
#
# Usage:
#   build_engine.sh --platform macos --deps DIR --work DIR --out DIR [--jobs 4]
#   build_engine.sh --platform ios   --deps DIR --work DIR --out DIR [--jobs 4]
#
# Output (macos):
#   OUT/libatermius_rdp.dylib
#   OUT/licenses/{FreeRDP-LICENSE,OpenSSL-LICENSE.txt,...}
#   OUT/engine-manifest.json
#
# Output (ios):
#   OUT/atermius_rdp.xcframework (ios-arm64 + ios-arm64-simulator)
#   OUT/licenses/{FreeRDP-LICENSE,OpenSSL-LICENSE.txt,...}
#   OUT/engine-manifest.json
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SRC="$(cd "$HERE/.." && pwd)"
LOCK_FILE="$HERE/deps.lock"
PLATFORM="" DEPS="" WORK="" OUT="" JOBS=4
MACOS_MIN="12.0"
IOS_MIN="15.0"

die() { echo "build_engine(apple): $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --deps) DEPS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

[[ "$PLATFORM" == "macos" || "$PLATFORM" == "ios" ]] || die "--platform must be macos or ios"
: "${DEPS:=$ENGINE_SRC/build/src-cache}"
: "${WORK:=$ENGINE_SRC/build/$PLATFORM/work}"
: "${OUT:=$ENGINE_SRC/build/$PLATFORM/bundle}"
CMAKE="${CMAKE:-$(command -v cmake || true)}"
[[ -n "$CMAKE" ]] || die "cmake not found on PATH"
if command -v ninja >/dev/null 2>&1; then
  CMAKE_GEN="Ninja"
else
  CMAKE_GEN="Unix Makefiles"
fi

mkdir -p "$DEPS" "$WORK" "$OUT"
DEPS="$(cd "$DEPS" && pwd)"
WORK="$(cd "$WORK" && pwd)"
OUT="$(cd "$OUT" && pwd)"

OPENSSL_TAR="openssl-3.5.9.tar.gz"
FREERDP_TAR="freerdp-3.33.0.tar.gz"

verify_or_download() {
  while read -r sha file url _license; do
    [[ -z "$sha" || "$sha" == \#* ]] && continue
    local target="$DEPS/$file"
    if [[ ! -f "$target" ]]; then
      echo "== Downloading $file from official release..."
      curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 -o "$target.part" "$url"
      mv "$target.part" "$target"
    fi
    local actual
    actual="$(shasum -a 256 "$target" | awk '{print $1}')"
    [[ "$actual" == "$sha" ]] || die "$file SHA-256 $actual != pinned $sha"
  done < "$LOCK_FILE"
}
verify_or_download

OPENSSL_SHA="$(awk '$2=="openssl-3.5.9.tar.gz"{print $1}' "$LOCK_FILE")"
FREERDP_SHA="$(awk '$2=="freerdp-3.33.0.tar.gz"{print $1}' "$LOCK_FILE")"

extract_once() {
  local tarfile="$1" sha="$2" dest_parent="$3" top_dir="$4"
  local marker="$dest_parent/$top_dir/.atermius-source-sha256"
  if [[ -f "$marker" && "$(cat "$marker")" == "$sha" ]]; then return; fi
  rm -rf "${dest_parent:?}/$top_dir"
  mkdir -p "$dest_parent"
  tar -xzf "$DEPS/$tarfile" -C "$dest_parent"
  [[ -d "$dest_parent/$top_dir" ]] || die "$tarfile did not contain $top_dir/"
  echo "$sha" > "$marker"
}

extract_once "$FREERDP_TAR" "$FREERDP_SHA" "$WORK/src" "freerdp-3.33.0"
FREERDP_SRC="$WORK/src/freerdp-3.33.0"

build_openssl_slice() {
  local slice="$1" ossl_target="$2" sdk_name="$3" min_flag="$4"
  local ossl_src="$WORK/$slice/src"
  local ossl_prefix="$WORK/$slice/openssl"
  if [[ -f "$ossl_prefix/lib/libcrypto.a" ]]; then return; fi
  echo "== Building OpenSSL 3.5.9 ($slice)"
  extract_once "$OPENSSL_TAR" "$OPENSSL_SHA" "$ossl_src" "openssl-3.5.9"
  rm -rf "$ossl_prefix"
  (
    cd "$ossl_src/openssl-3.5.9"
    if [[ "$sdk_name" == "macosx" ]]; then
      export CC="xcrun -sdk macosx clang"
      ./Configure "$ossl_target" \
        no-shared no-module no-tests no-docs no-ui-console \
        -fPIC -fvisibility=hidden "$min_flag" \
        --prefix="$ossl_prefix" --libdir=lib
    else
      export CROSS_TOP="$(xcrun --sdk "$sdk_name" --show-sdk-platform-path)/Developer"
      export CROSS_SDK="$(basename "$(xcrun --sdk "$sdk_name" --show-sdk-path)")"
      ./Configure "$ossl_target" \
        no-shared no-module no-tests no-docs no-ui-console \
        -fPIC -fvisibility=hidden "$min_flag" \
        --prefix="$ossl_prefix" --libdir=lib
    fi
    make -j"$JOBS" build_libs
    make install_dev
  )
}

build_engine_slice() {
  local slice="$1" sys_name="$2" sdk_name="$3" arch="$4" min_ver="$5"
  local ossl_prefix="$WORK/$slice/openssl"
  local build_dir="$WORK/$slice/engine"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  echo "== Building FreeRDP 3.33.0 + atermius_rdp ($slice)"

  local extra_cmake=()
  if [[ "$sys_name" == "iOS" ]]; then
    extra_cmake+=(
      -DCMAKE_SYSTEM_NAME=iOS
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      -DIOS_TARGET_SDK="$min_ver"
    )
  fi

  PKG_CONFIG_LIBDIR="$ossl_prefix/lib/pkgconfig" PKG_CONFIG_PATH="" PKG_CONFIG_SYSROOT_DIR="" \
  "$CMAKE" -G "$CMAKE_GEN" -S "$ENGINE_SRC" -B "$build_dir" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_ver" \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_C_VISIBILITY_PRESET=hidden \
    -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
    -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_FREERDP="$FREERDP_SRC" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENSSL_ROOT_DIR="$ossl_prefix" \
    -DOPENSSL_INCLUDE_DIR="$ossl_prefix/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$ossl_prefix/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$ossl_prefix/lib/libssl.a" \
    -DCMAKE_FIND_ROOT_PATH="$ossl_prefix;$sdk_path" \
    -DATERMIUS_RDP_DEVICES=ON \
    -DATERMIUS_RDP_PRINTER=OFF \
    -DATERMIUS_RDP_SMARTCARD=OFF \
    -DATERMIUS_RDP_AUDIO=OFF \
    -DATERMIUS_RDP_CAMERA=OFF \
    -DATERMIUS_RDP_USB=OFF \
    ${extra_cmake[@]+"${extra_cmake[@]}"}

  "$CMAKE" --build "$build_dir" --target atermius_rdp -j "$JOBS"
}

write_framework_bundle() {
  local dylib_src="$1" fw_dir="$2" min_os="$3" supported_platform="$4"
  rm -rf "$fw_dir"
  mkdir -p "$fw_dir"
  cp "$dylib_src" "$fw_dir/atermius_rdp"
  install_name_tool -id "@rpath/atermius_rdp.framework/atermius_rdp" "$fw_dir/atermius_rdp"
  xcrun strip -x "$fw_dir/atermius_rdp"
  cat > "$fw_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>atermius_rdp</string>
  <key>CFBundleIdentifier</key>
  <string>com.atermius.atermClient.rdp</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>atermius_rdp</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>3.33.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>${supported_platform}</string>
  </array>
  <key>MinimumOSVersion</key>
  <string>${min_os}</string>
</dict>
</plist>
PLIST
}

VERIFIED_BINARIES=()

if [[ "$PLATFORM" == "macos" ]]; then
  build_openssl_slice "macos-arm64" "darwin64-arm64-cc" "macosx" "-mmacosx-version-min=$MACOS_MIN"
  build_engine_slice "macos-arm64" "Darwin" "macosx" "arm64" "$MACOS_MIN"
  cp "$WORK/macos-arm64/engine/libatermius_rdp.dylib" "$OUT/libatermius_rdp.dylib"
  install_name_tool -id "@rpath/libatermius_rdp.dylib" "$OUT/libatermius_rdp.dylib"
  xcrun strip -x "$OUT/libatermius_rdp.dylib"
  codesign --force --sign - "$OUT/libatermius_rdp.dylib"
  VERIFIED_BINARIES+=("$OUT/libatermius_rdp.dylib")
  FIRST_OSSL="$WORK/macos-arm64/src/openssl-3.5.9"
else
  build_openssl_slice "ios-arm64" "ios64-xcrun" "iphoneos" "-mios-version-min=$IOS_MIN"
  build_engine_slice "ios-arm64" "iOS" "iphoneos" "arm64" "$IOS_MIN"

  build_openssl_slice "ios-sim-arm64" "iossimulator-arm64-xcrun" "iphonesimulator" "-mios-simulator-version-min=$IOS_MIN"
  build_engine_slice "ios-sim-arm64" "iOS" "iphonesimulator" "arm64" "$IOS_MIN"

  FW_DEV="$WORK/stage/iphoneos/atermius_rdp.framework"
  FW_SIM="$WORK/stage/iphonesimulator/atermius_rdp.framework"
  write_framework_bundle "$WORK/ios-arm64/engine/libatermius_rdp.dylib" "$FW_DEV" "$IOS_MIN" "iPhoneOS"
  write_framework_bundle "$WORK/ios-sim-arm64/engine/libatermius_rdp.dylib" "$FW_SIM" "$IOS_MIN" "iPhoneSimulator"

  rm -rf "$OUT/atermius_rdp.xcframework"
  xcodebuild -create-xcframework \
    -framework "$FW_DEV" \
    -framework "$FW_SIM" \
    -output "$OUT/atermius_rdp.xcframework"

  VERIFIED_BINARIES+=(
    "$OUT/atermius_rdp.xcframework/ios-arm64/atermius_rdp.framework/atermius_rdp"
    "$OUT/atermius_rdp.xcframework/ios-arm64-simulator/atermius_rdp.framework/atermius_rdp"
  )
  FIRST_OSSL="$WORK/ios-arm64/src/openssl-3.5.9"
fi

# Apache-2.0 section 4: ship each upstream LICENSE and any NOTICE file.
NOTICES="$OUT/licenses"
rm -rf "$NOTICES"
mkdir -p "$NOTICES"
cp "$FREERDP_SRC/LICENSE" "$NOTICES/FreeRDP-LICENSE"
cp "$FIRST_OSSL/LICENSE.txt" "$NOTICES/OpenSSL-LICENSE.txt"
for pair in "FreeRDP:$FREERDP_SRC" "OpenSSL:$FIRST_OSSL"; do
  for notice in "${pair#*:}"/NOTICE*; do
    if [[ -f "$notice" ]]; then cp "$notice" "$NOTICES/${pair%%:*}-$(basename "$notice")"; fi
  done
done

python3 -I "$HERE/verify_engine.py" \
  --platform "$PLATFORM" \
  --out "$OUT" \
  --source "$OPENSSL_TAR=$OPENSSL_SHA" \
  --source "$FREERDP_TAR=$FREERDP_SHA" \
  "${VERIFIED_BINARIES[@]/#/--binary=}"
