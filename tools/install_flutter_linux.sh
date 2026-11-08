#!/usr/bin/env bash
set -euo pipefail
task_sdk="${RUNNER_TEMP:-/tmp}/aterminal-flutter-3.47.5"
if [ ! -x "$task_sdk/flutter/bin/flutter" ]; then
  mkdir -p "$task_sdk"
  curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz \
    --output "$task_sdk/flutter.tar.xz"
  (cd "$task_sdk"; echo '2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb  flutter.tar.xz' | sha256sum --check -)
  tar -xJf "$task_sdk/flutter.tar.xz" -C "$task_sdk"
fi
if [ -n "${GITHUB_PATH:-}" ]; then echo "$task_sdk/flutter/bin" >> "$GITHUB_PATH"; fi
echo "Flutter SDK: $task_sdk/flutter"
