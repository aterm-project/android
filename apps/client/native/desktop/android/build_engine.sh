#!/usr/bin/env bash
# Reproducible Android build of the embedded RDP engine (libatermius_rdp.so).
#
# One self-contained shared library per ABI: the Atermius engine
# (../atermius_rdp.c) with FreeRDP 3.33.0 and OpenSSL 3.5 LTS linked
# statically; only Android system libraries stay dynamic. The app loads it
# through dart:ffi from the APK (no local daemon, no viewer app).
#
# Never downloads. Official tarballs listed in deps.lock must already be in
# --deps; each is verified against its pinned SHA-256 before extraction.
#
#   build_engine.sh --deps DIR --work DIR --out DIR [--abi arm64-v8a] [--abi x86_64] [--jobs 2]
#
# Environment:
#   ANDROID_NDK_ROOT | ANDROID_NDK_HOME | ANDROID_HOME (ndk/28.2.13676358)  NDK r28+
#   ATERMIUS_COMPILER_LOCK  optional flock file wrapped around each compile step
#   CMAKE (>= 3.28, default: cmake on PATH)
#
# Output (consumed by android/app/build.gradle.kts via atermius.rdpEngineDir):
#   OUT/jniLibs/<abi>/libatermius_rdp.so
#   OUT/assets/licenses/atermius_rdp/{FreeRDP,OpenSSL}-LICENSE*
#   OUT/engine-manifest.json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SRC="$(cd "$HERE/.." && pwd)"
LOCK_FILE="$HERE/deps.lock"
API_LEVEL=24 # Flutter's default minSdk for this app
NDK_PIN=28.2.13676358
DEPS="" WORK="" OUT="" JOBS=2
ABIS=()

die() { echo "build_engine: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deps) DEPS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --abi) ABIS+=("$2"); shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$DEPS" && -n "$WORK" && -n "$OUT" ]] || die "--deps, --work and --out are required"
[[ ${#ABIS[@]} -gt 0 ]] || ABIS=(arm64-v8a x86_64)
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "invalid --jobs"
for abi in "${ABIS[@]}"; do
  case "$abi" in arm64-v8a|x86_64) ;; *) die "unsupported ABI $abi" ;; esac
done

NDK="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
if [[ -z "$NDK" && -n "${ANDROID_HOME:-}" ]]; then NDK="$ANDROID_HOME/ndk/$NDK_PIN"; fi
[[ -f "$NDK/build/cmake/android.toolchain.cmake" ]] || die "Android NDK not found (set ANDROID_NDK_ROOT)"
NDK_REVISION="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties")"
[[ "${NDK_REVISION%%.*}" -ge 28 ]] || die "NDK r28 or newer required (found $NDK_REVISION)"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CMAKE="${CMAKE:-cmake}"
cmake_version="$("$CMAKE" --version | sed -n 's/^cmake version //p')"
printf '%s\n3.28\n' "$cmake_version" | sort -V -C -r || die "CMake >= 3.28 required (found $cmake_version)"

mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd)" OUT="$(cd "$OUT" && pwd)" DEPS="$(cd "$DEPS" && pwd)"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
# Fixed timestamps and source paths so rebuilds of the same inputs match.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1762646400}"
PREFIX_MAP="-ffile-prefix-map=$WORK=/atermius-build -ffile-prefix-map=$ENGINE_SRC=/atermius-engine"

locked() {
  if [[ -n "${ATERMIUS_COMPILER_LOCK:-}" ]]; then flock "$ATERMIUS_COMPILER_LOCK" "$@"; else "$@"; fi
}

# --- verified sources --------------------------------------------------------
declare -A SHA URL
while read -r sha file url license; do
  [[ -z "$sha" || "$sha" == \#* ]] && continue
  SHA[$file]="$sha"; URL[$file]="$url"
done < "$LOCK_FILE"
OPENSSL_TAR=openssl-3.5.9.tar.gz FREERDP_TAR=freerdp-3.33.0.tar.gz
for file in "$OPENSSL_TAR" "$FREERDP_TAR"; do
  [[ -f "$DEPS/$file" ]] || die "missing $DEPS/$file (official source: ${URL[$file]})"
  actual="$(sha256sum "$DEPS/$file" | cut -d' ' -f1)"
  [[ "$actual" == "${SHA[$file]}" ]] || die "$file SHA-256 $actual != pinned ${SHA[$file]}"
done

extract() { # tarball destination-parent expected-top-dir
  local marker="$2/$3/.atermius-source-sha256"
  if [[ -f "$marker" && "$(cat "$marker")" == "${SHA[$1]}" ]]; then return; fi
  rm -rf "${2:?}/$3"
  mkdir -p "$2"
  tar -xzf "$DEPS/$1" -C "$2" --no-same-owner
  [[ -d "$2/$3" ]] || die "$1 did not contain $3/"
  echo "${SHA[$1]}" > "$marker"
}
extract "$FREERDP_TAR" "$WORK/src" freerdp-3.33.0
FREERDP_SRC="$WORK/src/freerdp-3.33.0"

declare -A OPENSSL_TARGET=([arm64-v8a]=android-arm64 [x86_64]=android-x86_64)

for abi in "${ABIS[@]}"; do
  echo "== $abi"
  # --- OpenSSL (static, in-tree build per ABI) -------------------------------
  ossl_src="$WORK/$abi/src"
  ossl_prefix="$WORK/$abi/openssl"
  if [[ ! -f "$ossl_prefix/lib/libcrypto.a" ]]; then
    extract "$OPENSSL_TAR" "$ossl_src" openssl-3.5.9
    rm -rf "$ossl_prefix"
    (
      cd "$ossl_src/openssl-3.5.9"
      export ANDROID_NDK_ROOT="$NDK" PATH="$TOOLCHAIN/bin:$PATH"
      # no-module: the legacy provider is compiled into libcrypto (no .so
      # provider to load at run time). WinPR also uses its own MD4/RC4.
      locked ./Configure "${OPENSSL_TARGET[$abi]}" -D__ANDROID_API__=$API_LEVEL \
        no-shared no-module no-tests no-docs no-ui-console -fPIC $PREFIX_MAP \
        --prefix="$ossl_prefix" --libdir=lib
      locked make -j"$JOBS" build_libs
      locked make install_dev
    )
  fi

  # --- FreeRDP + engine --------------------------------------------------------
  build="$WORK/$abi/engine"
  # Configure probes the compilers, so it runs under the lock as well.
  # pkg-config may only see the Android OpenSSL, never the build host's .pc
  # files (FindOpenSSL would otherwise add host link flags).
  PKG_CONFIG_LIBDIR="$ossl_prefix/lib/pkgconfig" PKG_CONFIG_PATH="" PKG_CONFIG_SYSROOT_DIR="" \
  locked "$CMAKE" -G Ninja -S "$ENGINE_SRC" -B "$build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API_LEVEL" -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_FREERDP="$FREERDP_SRC" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR="$ossl_prefix" \
    -DOPENSSL_INCLUDE_DIR="$ossl_prefix/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$ossl_prefix/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$ossl_prefix/lib/libssl.a" \
    -DCMAKE_FIND_ROOT_PATH="$ossl_prefix" \
    -DATERMIUS_RDP_DEVICES=ON -DATERMIUS_RDP_PRINTER=OFF -DATERMIUS_RDP_SMARTCARD=OFF \
    -DATERMIUS_RDP_AUDIO=OFF -DATERMIUS_RDP_CAMERA=OFF -DATERMIUS_RDP_USB=OFF \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
    -DWITH_OPENSLES=OFF -DWITH_AAUDIO=OFF -DWITH_MEDIACODEC=OFF
  locked "$CMAKE" --build "$build" --target atermius_rdp -j "$JOBS"

  dest="$OUT/jniLibs/$abi"
  mkdir -p "$dest"
  "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded -o "$dest/libatermius_rdp.so" "$build/libatermius_rdp.so"

  # On-device negative-path probe (adb only; not packaged in the APK).
  probe="$OUT/probe/$abi"
  mkdir -p "$probe"
  declare -A PROBE_TARGET=([arm64-v8a]=aarch64-linux-android [x86_64]=x86_64-linux-android)
  locked "$TOOLCHAIN/bin/clang" --target="${PROBE_TARGET[$abi]}$API_LEVEL" -O2 -Wall -Werror \
    $PREFIX_MAP -Wl,-z,max-page-size=16384 -o "$probe/jni_probe" "$HERE/jni_probe.c"
done

# Apache-2.0 section 4: ship each upstream LICENSE and any NOTICE file.
notices="$OUT/assets/licenses/atermius_rdp"
rm -rf "$notices"
mkdir -p "$notices"
first_ossl="$WORK/${ABIS[0]}/src/openssl-3.5.9"
cp "$FREERDP_SRC/LICENSE" "$notices/FreeRDP-LICENSE"
cp "$first_ossl/LICENSE.txt" "$notices/OpenSSL-LICENSE.txt"
for pair in "FreeRDP:$FREERDP_SRC" "OpenSSL:$first_ossl"; do
  for notice in "${pair#*:}"/NOTICE*; do
    if [[ -f "$notice" ]]; then cp "$notice" "$notices/${pair%%:*}-$(basename "$notice")"; fi
  done
done

python3 -I "$HERE/verify_engine.py" --readelf "$TOOLCHAIN/bin/llvm-readelf" \
  --out "$OUT" --ndk-revision "$NDK_REVISION" --api "$API_LEVEL" \
  --source "$OPENSSL_TAR=${SHA[$OPENSSL_TAR]}" --source "$FREERDP_TAR=${SHA[$FREERDP_TAR]}" \
  "${ABIS[@]/#/--abi=}"
