#!/usr/bin/env bash
# Toolchain for the daily Android build on a GitHub-hosted ubuntu-24.04 runner.
#
# * JDK 17 from the runner image (AGP 9.1 / project targets Java 17).
# * Android NDK: the exact revision pinned by build_engine.sh (NDK_PIN), installed
#   by sdkmanager (package checksums verified by sdkmanager) into a private SDK
#   root under RUNNER_TEMP that the workflow caches by revision.
# * build-tools (apksigner/zipalign for the signing job), ninja, CMake >= 3.28.
# * Gradle limited to 2 workers and a 4 GB heap (private-repository runners
#   have ~7-8 GB RAM; the project gradle.properties asks for 8 GB).
#
# Writes JAVA_HOME / ANDROID_NDK_ROOT / ATERMIUS_* to GITHUB_ENV.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${ANDROID_HOME:?}"
BUILD_TOOLS=36.0.0
ENGINE_SCRIPT=apps/client/native/desktop/android/build_engine.sh

ndk="$(sed -n 's/^NDK_PIN=\([0-9][0-9.]*\).*/\1/p' "$ENGINE_SCRIPT")"
[[ "$ndk" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::cannot read NDK_PIN from $ENGINE_SCRIPT"; exit 1; }

java_home="${JAVA_HOME_17_X64:-}"
[[ -x "$java_home/bin/java" ]] || { echo "::error::JDK 17 not found on this runner image"; exit 1; }

sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
[[ -x "$sdkmanager" ]] || { echo "::error::sdkmanager not found under ANDROID_HOME"; exit 1; }
export JAVA_HOME="$java_home"
yes | "$sdkmanager" --licenses >/dev/null || true
"$sdkmanager" --install "build-tools;$BUILD_TOOLS" >/dev/null

ndk_sdk="$RUNNER_TEMP/android-ndk"
ndk_root="$ndk_sdk/ndk/$ndk"
if [[ ! -f "$ndk_root/source.properties" ]]; then
  mkdir -p "$ndk_sdk"
  cp -R "$ANDROID_HOME/licenses" "$ndk_sdk/"
  "$sdkmanager" --sdk_root="$ndk_sdk" --install "ndk;$ndk" >/dev/null
fi
revision="$(sed -n 's/^Pkg.Revision *= *//p' "$ndk_root/source.properties")"
[[ "$revision" == "$ndk" ]] || { echo "::error::NDK revision $revision != pinned $ndk"; exit 1; }

if ! command -v ninja >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq ninja-build >/dev/null
fi
cmake_version="$(cmake --version | sed -n 's/^cmake version //p')"
printf '%s\n3.28\n' "$cmake_version" | sort -V -C -r || { echo "::error::CMake >= 3.28 required"; exit 1; }

mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.workers.max=2
org.gradle.parallel=false
org.gradle.daemon=false
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8
kotlin.compiler.execution.strategy=in-process
EOF

{
  echo "JAVA_HOME=$java_home"
  echo "ANDROID_NDK_ROOT=$ndk_root"
  echo "ATERMIUS_NDK_REVISION=$ndk"
  echo "ATERMIUS_BUILD_TOOLS=$ANDROID_HOME/build-tools/$BUILD_TOOLS"
} >> "$GITHUB_ENV"
echo "JDK $("$java_home/bin/java" -version 2>&1 | head -1); NDK $revision; CMake $cmake_version; ninja $(ninja --version)"
