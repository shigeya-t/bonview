#!/bin/zsh
# Package a release into build/release/ (nothing is uploaded):
#   BonView-<version>-macOS-<arch>.zip   the app, with the bundled LGPL FFmpeg
#   ffmpeg-<ffmpeg version>.tar.xz       the unmodified FFmpeg source of those dylibs (LGPL §6)
#   FFmpeg-SOURCE.txt                    where the source and the build settings are
#   SHA256SUMS.txt
# Attach every file in build/release/ to the GitHub release; the command is printed at the end.
#
# Signing and notarization (so Gatekeeper opens the downloaded app without warnings):
#   SIGN_IDENTITY   codesign identity; default: the first "Developer ID Application" in the keychain,
#                   else ad-hoc ("-") with a warning (Gatekeeper then blocks the downloaded app).
#   Notary credentials, required with a Developer ID identity (NOTARIZE=0 skips notarization):
#     NOTARY_PROFILE=name                         from `xcrun notarytool store-credentials name …`
#     NOTARY_KEY=AuthKey_X.p8 NOTARY_KEY_ID=X NOTARY_ISSUER=uuid   App Store Connect API key (CI)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -z "${FFMPEG_PREFIX:-}" ]] || { echo "unset FFMPEG_PREFIX: releases must bundle scripts/build_ffmpeg.sh's FFmpeg" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || echo "warning: the working tree has uncommitted changes" >&2

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Developer ID Application: .*\)"$/\1/p' | head -1)
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
NOTARY_ARGS=()
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "warning: no Developer ID identity; the app is ad-hoc signed and Gatekeeper will block it after download" >&2
elif [[ "${NOTARIZE:-1}" == 0 ]]; then
  echo "warning: NOTARIZE=0; the app is signed but not notarized" >&2
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  echo "set NOTARY_PROFILE (or NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER) to notarize, or NOTARIZE=0 to skip" >&2
  exit 1
fi
export SIGN_IDENTITY

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
if (( ${#NOTARY_ARGS} )); then
  echo "Notarizing (this usually takes a few minutes)…"
  ditto -c -k --keepParent "$OUT/BonView.app" "$OUT/notarize.zip"
  RESULT=$(xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY_ARGS[@]}" --wait --output-format json)
  rm -f "$OUT/notarize.zip"
  STATUS=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' <<<"$RESULT")
  if [[ "$STATUS" != Accepted ]]; then
    echo "notarization failed: $RESULT" >&2
    SUBMISSION=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' <<<"$RESULT")
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" "${NOTARY_ARGS[@]}" >&2
    exit 1
  fi
  xcrun stapler staple "$OUT/BonView.app"
  spctl --assess --type execute -v "$OUT/BonView.app"
fi
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
  afterwards (codesign --force --deep --sign - BonView.app); the app is then no longer notarized.
- License text: BonView.app/Contents/Resources/Licenses/FFmpeg/COPYING.LGPLv2.1
EOF

(cd "$OUT" && shasum -a 256 "$ZIP" "ffmpeg-$FFV.tar.xz" FFmpeg-SOURCE.txt > SHA256SUMS.txt)
ls -l "$OUT"
echo
if [[ "$SIGN_IDENTITY" == "-" ]]; then echo "Signature: ad-hoc (not for distribution)"
elif (( ${#NOTARY_ARGS} )); then echo "Signature: $SIGN_IDENTITY, notarized and stapled"
else echo "Signature: $SIGN_IDENTITY (not notarized)"; fi
echo
echo "To publish (after tagging v$VERSION):"
echo "  gh release create v$VERSION $OUT/* --title \"BonView $VERSION\""
