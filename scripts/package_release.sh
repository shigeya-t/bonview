#!/bin/zsh
# Package a release into build/release/ (nothing is uploaded):
#   BonView-<version>-macOS-<arch>.zip   the app, with the bundled LGPL FFmpeg
#   ffmpeg-<ffmpeg version>.tar.xz       the unmodified FFmpeg source of those dylibs (LGPL §6)
#   FFmpeg-SOURCE.txt                    where the source and the build settings are
#   SHA256SUMS.txt
# Attach every file in build/release/ to the GitHub release; the command is printed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -z "${FFMPEG_PREFIX:-}" ]] || { echo "unset FFMPEG_PREFIX: releases must bundle scripts/build_ffmpeg.sh's FFmpeg" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || echo "warning: the working tree has uncommitted changes" >&2

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCH=$(uname -m)
COMMIT=$(git rev-parse --short HEAD)
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

APP="$OUT/BonView.app" scripts/bundle.sh >/dev/null
FFV=$(<build/ffmpeg/.version)
[[ -d "$OUT/BonView.app/Contents/Frameworks" ]] || { echo "FFmpeg was not bundled" >&2; exit 1; }

ZIP="BonView-$VERSION-macOS-$ARCH.zip"
ditto -c -k --keepParent "$OUT/BonView.app" "$OUT/$ZIP"
rm -rf "$OUT/BonView.app"
cp "build/ffmpeg-src/ffmpeg-$FFV.tar.xz" "$OUT/"

cat > "$OUT/FFmpeg-SOURCE.txt" <<EOF
BonView $VERSION (commit $COMMIT) bundles FFmpeg $FFV as dynamic libraries in
BonView.app/Contents/Frameworks, used under the GNU Lesser General Public License 2.1 or later.

- Source: ffmpeg-$FFV.tar.xz in this release (unmodified; also at https://ffmpeg.org/releases/).
- Build settings: scripts/build_ffmpeg.sh in the BonView source at this release's tag
  (https://github.com/shigeya-t/bonview).
- The libraries may be replaced with your own build of the same major versions; re-sign the app
  afterwards (codesign --force --sign - BonView.app).
- License text: BonView.app/Contents/Resources/Licenses/FFmpeg/COPYING.LGPLv2.1
EOF

(cd "$OUT" && shasum -a 256 "$ZIP" "ffmpeg-$FFV.tar.xz" FFmpeg-SOURCE.txt > SHA256SUMS.txt)
ls -l "$OUT"
echo
echo "To publish (after tagging v$VERSION):"
echo "  gh release create v$VERSION $OUT/* --title \"BonView $VERSION\""
