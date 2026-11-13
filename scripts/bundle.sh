#!/bin/zsh
# Build BonView.app into ./build (ad-hoc signed, for local use).
#   scripts/bundle.sh                              → build/BonView.app (release)
#   CONFIG=debug scripts/bundle.sh
#   BUNDLE_ID=io.github.yourname.BonView scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --product BonView 2>&1 | grep -v "ld: warning" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BonView"
[[ -x "$BIN" ]] || { echo "build failed" >&2; exit 1; }

APP=build/BonView.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BonView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
