#!/usr/bin/env bash
# Atermius iOS 一键工程化构建与打包脚本
# 支持模拟器 (.app)、免签分发包 (.unsigned.ipa) 与本地开发证书真机签名构建
# 产物输出目录: ios/dist/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/apps/client"
ENGINE_SCRIPT="$CLIENT_DIR/native/desktop/apple/build_engine.sh"
VERIFY_SCRIPT="$CLIENT_DIR/native/desktop/apple/verify_engine.py"
XCFRAMEWORK_DIR="$CLIENT_DIR/native/desktop/build/ios/bundle/atermius_rdp.xcframework"
DIST_DIR="$REPO_ROOT/dist"

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
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

RUN_SIMULATOR=0
RUN_UNSIGNED_IPA=0
RUN_DEVICE_SIGNED=0
REBUILD_ENGINE=0
TEAM_ID="${ATERMIUS_IOS_TEAM_ID:-HATJS45WQL}"
BUNDLE_ID="${ATERMIUS_IOS_BUNDLE_ID:-}"

if [ $# -eq 0 ]; then
  RUN_SIMULATOR=1
  RUN_UNSIGNED_IPA=1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --simulator) RUN_SIMULATOR=1; shift ;;
    --unsigned-ipa) RUN_UNSIGNED_IPA=1; shift ;;
    --device) RUN_DEVICE_SIGNED=1; shift ;;
    --all)
      RUN_SIMULATOR=1
      RUN_UNSIGNED_IPA=1
      shift
      ;;
    --rebuild-engine) REBUILD_ENGINE=1; shift ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/build_ios.sh [options]
  --simulator            Build iOS Simulator app bundle (arm64)
  --unsigned-ipa         Build Release iOS app (--no-codesign) and package .unsigned.ipa
  --device               Build signed iOS device app & .ipa with Apple Development team
  --all                  Build both --simulator and --unsigned-ipa (default)
  --team-id <TEAM_ID>    Override DEVELOPMENT_TEAM (default: HATJS45WQL)
  --bundle-id <ID>       Override PRODUCT_BUNDLE_IDENTIFIER for device signing
  --rebuild-engine       Force rebuild of OpenSSL + FreeRDP XCFramework
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "==> [1/4] Checking native FreeRDP XCFramework (iOS device + simulator)..."
if [ "$REBUILD_ENGINE" -eq 1 ] || [ ! -d "$XCFRAMEWORK_DIR" ]; then
  bash "$ENGINE_SCRIPT" --platform ios
fi
python3 "$VERIFY_SCRIPT" --platform ios

echo "==> [2/4] Resolving locked Flutter & CocoaPods dependencies..."
cd "$CLIENT_DIR"
flutter pub get --enforce-lockfile

mkdir -p "$DIST_DIR"

if [ "$RUN_SIMULATOR" -eq 1 ]; then
  echo "==> [3/4] Building iOS Simulator app (arm64)..."
  flutter build ios --simulator --debug
  SIM_APP="$CLIENT_DIR/build/ios/iphonesimulator/Runner.app"
  if [ ! -f "$SIM_APP/Frameworks/atermius_rdp.framework/atermius_rdp" ]; then
    echo "error: atermius_rdp.framework missing in simulator build $SIM_APP" >&2
    exit 1
  fi
  rm -rf "$DIST_DIR/Atermius-iphonesimulator.app"
  ditto "$SIM_APP" "$DIST_DIR/Atermius-iphonesimulator.app"
  SIM_ZIP="$DIST_DIR/Atermius-iphonesimulator-arm64.zip"
  rm -f "$SIM_ZIP" "$SIM_ZIP.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/Atermius-iphonesimulator.app" "$SIM_ZIP"
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$SIM_ZIP")" > "$(basename "$SIM_ZIP").sha256")
fi

if [ "$RUN_UNSIGNED_IPA" -eq 1 ]; then
  echo "==> [3/4] Building Release unsigned iOS device package (.unsigned.ipa)..."
  flutter build ios --release --no-codesign
  DEV_APP="$CLIENT_DIR/build/ios/iphoneos/Runner.app"
  if [ ! -f "$DEV_APP/Frameworks/atermius_rdp.framework/atermius_rdp" ]; then
    echo "error: atermius_rdp.framework missing in device build $DEV_APP" >&2
    exit 1
  fi
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/atermius-ipa.XXXXXX")"
  mkdir -p "$STAGE_DIR/Payload"
  cp -RP "$DEV_APP" "$STAGE_DIR/Payload/Runner.app"
  IPA_PATH="$DIST_DIR/Atermius-ios-unsigned.ipa"
  rm -f "$IPA_PATH" "$IPA_PATH.sha256"
  (cd "$STAGE_DIR" && /usr/bin/zip -qry "$IPA_PATH" Payload)
  rm -rf "$STAGE_DIR"
  if ! /usr/bin/unzip -l "$IPA_PATH" | grep -q "Payload/Runner.app/Info.plist"; then
    echo "error: Malformed IPA structure in $IPA_PATH (missing Payload/Runner.app/Info.plist)" >&2
    exit 1
  fi
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$IPA_PATH")" > "$(basename "$IPA_PATH").sha256")
fi

if [ "$RUN_DEVICE_SIGNED" -eq 1 ]; then
  echo "==> [3/4] Building signed Release iOS device app (Team: $TEAM_ID)..."
  flutter build ios --release --config-only
  XCODE_ARGS=(
    -workspace "$CLIENT_DIR/ios/Runner.xcworkspace"
    -scheme Runner
    -configuration Release
    -sdk iphoneos
    -derivedDataPath "$CLIENT_DIR/build/ios_signed_derived"
    -allowProvisioningUpdates
    "DEVELOPMENT_TEAM=$TEAM_ID"
  )
  if [ -n "$BUNDLE_ID" ]; then
    XCODE_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
  fi
  xcodebuild "${XCODE_ARGS[@]}" build
  SIGNED_APP="$CLIENT_DIR/build/ios_signed_derived/Build/Products/Release-iphoneos/Runner.app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$SIGNED_APP"
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/atermius-signed-ipa.XXXXXX")"
  mkdir -p "$STAGE_DIR/Payload"
  cp -RP "$SIGNED_APP" "$STAGE_DIR/Payload/Runner.app"
  SIGNED_IPA="$DIST_DIR/Atermius-ios-signed.ipa"
  rm -f "$SIGNED_IPA" "$SIGNED_IPA.sha256"
  (cd "$STAGE_DIR" && /usr/bin/zip -qry "$SIGNED_IPA" Payload)
  rm -rf "$STAGE_DIR"
  if ! /usr/bin/unzip -l "$SIGNED_IPA" | grep -q "Payload/Runner.app/Info.plist"; then
    echo "error: Malformed IPA structure in $SIGNED_IPA" >&2
    exit 1
  fi
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$SIGNED_IPA")" > "$(basename "$SIGNED_IPA").sha256")
fi

echo "==> [4/4] iOS build complete! Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR"
