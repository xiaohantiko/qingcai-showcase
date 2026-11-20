#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
QINGCAI_VERSION="1.1.0"
QINGCAI_SDK_PATH="${QINGCAI_SDK:-}"
if [[ -z "$QINGCAI_SDK_PATH" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  QINGCAI_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
# Native builder keeps Command Line Tools installations usable without a full Xcode.
qingcai_build() {
  if [[ -n "$QINGCAI_SDK_PATH" ]]; then
    swift build --build-system native --sdk "$QINGCAI_SDK_PATH" "$@"
  else
    swift build --build-system native "$@"
  fi
}
qingcai_build --product Qingcai -c "$CONFIGURATION"
qingcai_build --product QingcaiGateway -c "$CONFIGURATION"
BIN_DIR="$(qingcai_build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p dist/.packaging.noindex
STAGE="$(mktemp -d "$PWD/dist/.packaging.noindex/build.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/清财公开版.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Qingcai" "$APP/Contents/MacOS/Qingcai"
cp "$BIN_DIR/QingcaiGateway" "$APP/Contents/Helpers/QingcaiGateway"
codesign --force --sign - "$APP/Contents/Helpers/QingcaiGateway"
cp scripts/Info.plist "$APP/Contents/Info.plist"
ICON="dist/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
  if [[ -n "$QINGCAI_SDK_PATH" ]]; then
    swift -sdk "$QINGCAI_SDK_PATH" scripts/make-icon.swift "$STAGE"
  else
    swift scripts/make-icon.swift "$STAGE"
  fi
  ICON="$STAGE/AppIcon.icns"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ZIP="Qingcai-$QINGCAI_VERSION-mac-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$ZIP"
unzip -tq "$STAGE/$ZIP"
mv -f "$STAGE/$ZIP" "dist/$ZIP"
printf '已生成 %s\n' "$PWD/dist/$ZIP"

# The hosted release job independently repackages and smoke-tests this signed bundle.
if [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
      "${GITHUB_REPOSITORY:-}" == xiaohantiko/qingcai-showcase &&
      "${GITHUB_WORKFLOW:-}" == 'Build and publish verified installers' ]]; then
  ci_app="dist/清财公开版.app"
  if [[ -e "$ci_app" || -L "$ci_app" ]]; then
    echo "公开发布任务需要干净的构建目录。" >&2
    exit 1
  fi
  mv "$APP" "$ci_app"
fi
