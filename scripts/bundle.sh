#!/bin/zsh
# Build BonView.app into ./build (ad-hoc signed, for local use).
#   scripts/bundle.sh                              → build/BonView.app (release)
#   CONFIG=debug scripts/bundle.sh
#   BUNDLE_ID=io.github.yourname.BonView scripts/bundle.sh
#   APP=/path/to/BonView.app scripts/bundle.sh        (another output location)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
# Build the bundled FFmpeg first unless another one was chosen with FFMPEG_PREFIX.
if [[ -z "${FFMPEG_PREFIX:-}" ]]; then
  scripts/build_ffmpeg.sh
  export FFMPEG_PREFIX="$PWD/build/ffmpeg"
fi
swift build -c "$CONFIG" --product BonView 2>&1 | grep -v "ld: warning" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BonView"
[[ -x "$BIN" ]] || { echo "build failed" >&2; exit 1; }

APP=${APP:-build/BonView.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BonView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Copy the @rpath FFmpeg dylibs the binary (and they themselves) load into Contents/Frameworks.
# A Homebrew FFmpeg has absolute install names; then nothing is copied and the app needs Homebrew.
rpath_libs() { otool -L "$1" | awk 'NR > 1 && $1 ~ /^@rpath\/lib(av|sw)/ { sub("@rpath/", "", $1); print $1 }'; }
typeset -U libs; libs=($(rpath_libs "$BIN"))
for (( i = 1; i <= ${#libs}; i++ )); do libs+=($(rpath_libs "$FFMPEG_PREFIX/lib/${libs[i]}")); done
if (( ${#libs} )); then
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/FFmpeg"
  for lib in $libs; do
    cp "$FFMPEG_PREFIX/lib/$lib" "$APP/Contents/Frameworks/$lib"
    codesign --force --sign - "$APP/Contents/Frameworks/$lib" >/dev/null 2>&1
  done
  cp "$FFMPEG_PREFIX"/share/licenses/* "$APP/Contents/Resources/FFmpeg/" 2>/dev/null || true
  [[ -f "$FFMPEG_PREFIX/.version" ]] && cp "$FFMPEG_PREFIX/.version" "$APP/Contents/Resources/FFmpeg/VERSION"
  # Only load the bundled copies (and don't ship the build machine's path).
  install_name_tool -delete_rpath "$FFMPEG_PREFIX/lib" "$APP/Contents/MacOS/BonView" 2>/dev/null || true
else
  echo "note: FFmpeg ($FFMPEG_PREFIX) is not @rpath-linked; the app uses it from that location" >&2
fi
if [[ -n "${BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
