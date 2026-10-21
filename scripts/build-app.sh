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

# Sign with a stable identity so macOS keeps the Screen Recording permission across
# rebuilds. An ad-hoc signature is tied to the exact binary, so every rebuild would
# look like a new app and the permission would have to be granted again.
ID="${SIGN_IDENTITY:-}"
if [ -z "$ID" ]; then
    ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -z "$ID" ] && security find-identity -v -p codesigning | grep -q '"StreamCapture Local Signing"'; then
    ID="StreamCapture Local Signing"
fi
if [ -z "$ID" ]; then
    echo "warning: no signing identity found; signing ad-hoc." >&2
    echo "warning: Screen Recording permission will need re-granting after every rebuild." >&2
    echo "warning: set SIGN_IDENTITY or run scripts/make-signing-cert.sh to fix this." >&2
    ID="-"
fi
codesign --force --deep --sign "$ID" --identifier local.streamcapture.app "$APP"
echo "Signed with: $ID"

echo "Built $APP"
echo "Run it with: open \"$APP\""
