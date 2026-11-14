#!/bin/zsh
# Build BonView.app into ./build (ad-hoc signed by default, for local use).
#   scripts/bundle.sh                              → build/BonView.app (release)
#   CONFIG=debug scripts/bundle.sh
#   BUNDLE_ID=io.github.yourname.BonView scripts/bundle.sh
#   APP=/path/to/BonView.app scripts/bundle.sh        (another output location)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/bundle.sh
#       sign for distribution: hardened runtime + secure timestamp (package_release.sh notarizes it)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SIGN_IDENTITY:--}
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS=(--force --sign -)
else
  # No entitlements: the app is not sandboxed, makes outgoing connections only and needs no JIT.
  # Library validation passes because the bundled dylibs are signed with the same identity.
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi
sign() { codesign "${SIGN_ARGS[@]}" "$1" >/dev/null 2>&1 || { codesign "${SIGN_ARGS[@]}" "$1"; exit 1; }; }

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
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC"
cp LICENSE "$LIC/BonView-LICENSE.txt"
cp Resources/Licenses/* "$LIC/"
if (( ${#libs} )); then
  mkdir -p "$APP/Contents/Frameworks" "$LIC/FFmpeg"
  for lib in $libs; do
    cp "$FFMPEG_PREFIX/lib/$lib" "$APP/Contents/Frameworks/$lib"
    sign "$APP/Contents/Frameworks/$lib"
  done
  cp "$FFMPEG_PREFIX"/share/licenses/* "$LIC/FFmpeg/" 2>/dev/null || true
  FFV=$(cat "$FFMPEG_PREFIX/.version" 2>/dev/null || echo "")
  [[ -n "$FFV" ]] && echo "$FFV" > "$LIC/FFmpeg/VERSION"
  # Only load the bundled copies (and don't ship the build machine's path).
  install_name_tool -delete_rpath "$FFMPEG_PREFIX/lib" "$APP/Contents/MacOS/BonView" 2>/dev/null || true
  FFMPEG_CREDITS="<h3>FFmpeg ${FFV}</h3>
<p>映像・音声のデコードに <a href=\"https://ffmpeg.org/\">FFmpeg</a> を LGPL 2.1 以降で使っています（GPL の部品は含みません）。<br>
Contents/Frameworks の dylib は差し替えられます。ビルド設定は scripts/build_ffmpeg.sh にあります。<br>
ソースは <a href=\"https://github.com/shigeya-t/bonview/releases\">BonView のリリース</a>に同梱しているほか、<a href=\"https://ffmpeg.org/releases/\">ffmpeg.org</a> から入手できます。</p>"
else
  echo "note: FFmpeg ($FFMPEG_PREFIX) is not @rpath-linked; the app uses it from that location" >&2
  FFMPEG_CREDITS="<h3>FFmpeg</h3>
<p>映像・音声のデコードに <a href=\"https://ffmpeg.org/\">FFmpeg</a> を使っています（このビルドには同梱していません）。</p>"
fi
# Credits for the standard About panel (NSApplication reads Contents/Resources/Credits.html).
FFMPEG_CREDITS="$FFMPEG_CREDITS" python3 -c 'import os, sys; sys.stdout.write(open("Resources/Credits.html").read().replace("@FFMPEG@", os.environ["FFMPEG_CREDITS"]))' \
  > "$APP/Contents/Resources/Credits.html"
if [[ -n "${BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
# Nested code (Contents/Frameworks) is already signed; sign the bundle last.
sign "$APP"
codesign --verify --strict "$APP"
echo "$APP"
