#!/usr/bin/env bash
# Builds "build/iPad Live.app".
# Needs a Mac running macOS 14 (Sonoma) or later, plus Xcode or the Command Line Tools
# (install those with: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="iPad Live"
EXECUTABLE="iPadLive"
CONFIGURATION="${CONFIGURATION:-release}"
# "-" signs the app ad hoc, which is all you need to run it on your own Mac.
# Set SIGN_IDENTITY to a "Developer ID Application: ..." identity to share it with others.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# The hardened runtime blocks other code from injecting into the app and borrowing its
# camera permission. Set HARDENED_RUNTIME=0 only to rule it out while troubleshooting.
HARDENED_RUNTIME="${HARDENED_RUNTIME:-1}"
ENTITLEMENTS="Resources/iPadLive.entitlements"
APP="build/${APP_NAME}.app"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: iPad Live is a Mac app; build it on a Mac." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "error: Swift isn't installed. Run: xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling (${CONFIGURATION})"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$HARDENED_RUNTIME" == "1" ]]; then
  SIGN_ARGS+=(--options runtime --entitlements "$ENTITLEMENTS")
else
  echo "warning: signing WITHOUT the hardened runtime (HARDENED_RUNTIME=0)" >&2
fi
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp) # a secure timestamp is required for notarization
fi
codesign "${SIGN_ARGS[@]}" "$APP"

echo
echo "Built: $APP"
