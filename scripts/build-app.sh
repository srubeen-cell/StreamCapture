#!/bin/bash
# Builds StreamCapture.app into ./build. Needs Xcode 16+ (or its Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/StreamCapture.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/StreamCapture" "$APP/Contents/MacOS/StreamCapture"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS can remember the Screen Recording permission.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
