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
APP="dist/清财.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Qingcai" "$APP/Contents/MacOS/Qingcai"
cp "$BIN_DIR/QingcaiGateway" "$APP/Contents/Helpers/QingcaiGateway"
codesign --force --sign - "$APP/Contents/Helpers/QingcaiGateway"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f dist/AppIcon.icns ]]; then
  if [[ -n "$QINGCAI_SDK_PATH" ]]; then
    swift -sdk "$QINGCAI_SDK_PATH" scripts/make-icon.swift
  else
    swift scripts/make-icon.swift
  fi
fi
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Qingcai-$QINGCAI_VERSION-mac-$(uname -m).zip"
echo "已生成：$PWD/$APP"
