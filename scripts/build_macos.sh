#!/usr/bin/env bash
# Atermius macOS 一键工程化构建与打包脚本
# 产物输出目录: desktop/dist/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/apps/client"
ENGINE_SCRIPT="$CLIENT_DIR/native/desktop/apple/build_engine.sh"
VERIFY_SCRIPT="$CLIENT_DIR/native/desktop/apple/verify_engine.py"
ENGINE_DYLIB="$CLIENT_DIR/native/desktop/build/macos/bundle/libatermius_rdp.dylib"
DIST_DIR="$REPO_ROOT/dist"

# 优先挂载工作区锁定的工具链 (.tooling) 与 ~/.local/bin
if [ -d "$WORKSPACE_ROOT/.tooling/flutter-sdk/flutter/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/flutter-sdk/flutter/bin:$PATH"
fi
if [ -d "$WORKSPACE_ROOT/.tooling/venv/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/venv/bin:$PATH"
fi
if [ -d "$WORKSPACE_ROOT/.tooling/ruby-env/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/ruby-env/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"

BUILD_MODE="release"
FORCE_ADHOC=0
SKIP_DMG=0
REBUILD_ENGINE=0
SIGN_IDENTITY="${ATERMIUS_MACOS_SIGN_IDENTITY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) BUILD_MODE="debug"; shift ;;
    --profile) BUILD_MODE="profile"; shift ;;
    --release) BUILD_MODE="release"; shift ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    --rebuild-engine) REBUILD_ENGINE=1; shift ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/build_macos.sh [options]
  --release              Build Release app, .zip and .dmg (default)
  --profile              Build Profile app
  --debug                Build Debug app
  --adhoc                Sign bundle with ad-hoc identity (-)
  --sign-identity <id>   Sign bundle with explicit certificate name or SHA-1
  --skip-dmg             Skip .dmg creation in Release mode
  --rebuild-engine       Force rebuild of OpenSSL + FreeRDP native dylib
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "==> [1/5] Checking native FreeRDP engine (macOS arm64)..."
if [ "$REBUILD_ENGINE" -eq 1 ] || [ ! -f "$ENGINE_DYLIB" ]; then
  bash "$ENGINE_SCRIPT" --platform macos
fi
python3 "$VERIFY_SCRIPT" --platform macos

echo "==> [2/5] Resolving locked Flutter dependencies..."
cd "$CLIENT_DIR"
flutter pub get --enforce-lockfile

echo "==> [3/5] Building Atermius macOS ($BUILD_MODE)..."
flutter build macos "--$BUILD_MODE"

CONFIG_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${BUILD_MODE:0:1}")${BUILD_MODE:1}"
APP_BUNDLE="$CLIENT_DIR/build/macos/Build/Products/$CONFIG_CAP/Atermius.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: Expected app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

# 校验原生引擎与 C ABI 导出符号
if [ ! -f "$APP_BUNDLE/Contents/Frameworks/libatermius_rdp.dylib" ]; then
  echo "error: libatermius_rdp.dylib was not embedded into $APP_BUNDLE" >&2
  exit 1
fi
for sym in \
  _aterm_macos_free_string \
  _aterm_macos_monitor_layout \
  _aterm_macos_default_printer \
  _aterm_macos_read_clipboard_files \
  _aterm_macos_write_clipboard_files; do
  if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Atermius" | grep -q "$sym"; then
    echo "error: Missing required C ABI symbol $sym in Atermius executable" >&2
    exit 1
  fi
done

echo "==> [4/5] Signing & verifying Atermius.app..."
EXPLICIT_IDENTITY=0
if [ -n "$SIGN_IDENTITY" ]; then
  EXPLICIT_IDENTITY=1
fi

if [ "$FORCE_ADHOC" -eq 1 ]; then
  SIGN_IDENTITY="-"
elif [ -z "$SIGN_IDENTITY" ]; then
  DETECTED_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}' || true)"
  if [ -n "$DETECTED_ID" ]; then
    PROBE_BIN="$(mktemp "${TMPDIR:-/tmp}/atermius-sign-probe.XXXXXX")"
    cp -f "$APP_BUNDLE/Contents/MacOS/Atermius" "$PROBE_BIN"
    if /usr/bin/codesign --force --sign "$DETECTED_ID" --timestamp=none "$PROBE_BIN" >/dev/null 2>&1; then
      SIGN_IDENTITY="$DETECTED_ID"
    else
      echo "    [note] Keychain private key for '$DETECTED_ID' requires interactive GUI authorization in this session; falling back to ad-hoc signing (-)."
      SIGN_IDENTITY="-"
    fi
    rm -f "$PROBE_BIN"
  else
    SIGN_IDENTITY="-"
  fi
fi

if [ "$BUILD_MODE" = "release" ]; then
  ENTITLEMENTS="$CLIENT_DIR/macos/Runner/Release.entitlements"
else
  ENTITLEMENTS="$CLIENT_DIR/macos/Runner/DebugProfile.entitlements"
fi

echo "    Using signing identity: $SIGN_IDENTITY (Explicit=$EXPLICIT_IDENTITY)"
# 由内向外分层签名所有嵌入的动态库和 Framework
find "$APP_BUNDLE/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 | while IFS= read -r -d '' lib; do
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$lib"
done
find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" -print0 | while IFS= read -r -d '' fw; do
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$fw"
done
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/Atermius.app"
ditto "$APP_BUNDLE" "$DIST_DIR/Atermius.app"

if [ "$BUILD_MODE" = "release" ]; then
  echo "==> [5/5] Packaging macOS distribution archives..."
  ZIP_PATH="$DIST_DIR/Atermius-macos-arm64.zip"
  rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/Atermius.app" "$ZIP_PATH"
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")

  if [ "$SKIP_DMG" -eq 0 ]; then
    DMG_PATH="$DIST_DIR/Atermius-macos-arm64.dmg"
    DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/atermius-dmg.XXXXXX")"
    trap 'rm -rf "$DMG_STAGE"' EXIT
    ditto "$DIST_DIR/Atermius.app" "$DMG_STAGE/Atermius.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    rm -f "$DMG_PATH" "$DMG_PATH.sha256"
    hdiutil create -volname "Atermius" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
    rm -rf "$DMG_STAGE"
    trap - EXIT
  fi
fi

echo "==> macOS build complete! Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR"
